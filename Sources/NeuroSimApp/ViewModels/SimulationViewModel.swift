//
//  SimulationViewModel.swift
//  NeuroSimApp
//
//  Owns the Network + Simulator and exposes:
//   - the topology (for the editor)
//   - a downsampled rolling buffer of recent voltages (for the plot)
//   - a selection (for the inspector)
//   - run/pause/reset controls
//
//  The simulation steps run inside a main-thread timer at ~60 Hz. HH is fast
//  enough (≈ 10–50 µs per neuron-step) that this stays responsive even with
//  small networks. Move to a background queue if you push toward 1k+ neurons.
//

import Foundation
import SwiftUI
import Combine
import NeuroSimCore
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared trace colour palette (used by SimulationViewModel + ResultsWindowView)

let kTracePalette: [Color] = [
    .blue, .orange, .green, .red, .purple, .yellow, .teal, .pink
]

@MainActor
final class SimulationViewModel: ObservableObject {

    // MARK: - Topology (published so the canvas redraws on changes)

    @Published var network: Network
    @Published var selection: Selection = .none
    /// Active editing tool. The canvas reads this to decide what mouse
    /// events mean (select/move, drag synapse, click-to-add-neuron, …).
    /// The tool palette in the sidebar binds to this through the VM so
    /// the palette and canvas stay in sync.
    @Published var activeTool: EditorTool = .select

    enum Selection: Equatable {
        case none
        case neuron(UUID)
        case synapse(UUID)
        case compartment(UUID)
    }

    // MARK: - Plot buffer (rolling window of recent samples)

    /// Window length in ms shown in the V(t) plot.
    @Published var plotWindow: Double = 200.0
    /// (time, V) per neuron — capped to ~5 000 samples per neuron.
    @Published private(set) var traces: [UUID: [PlotPoint]] = [:]

    struct PlotPoint: Identifiable, Hashable {
        let t: Double
        let v: Double
        var id: Double { t }
    }

    // MARK: - Signal traces (Results window)

    struct SignalTrace: Identifiable {
        let id: UUID
        var chartGroupID: UUID   // traces sharing this ID are rendered on the same chart
        var signal: TracedSignal
        var label: String
        var points: [PlotPoint]
        var color: Color
    }

    @Published var signalTraces: [SignalTrace] = []
    /// Incremented each time the simulation reaches its natural end (plotWindow).
    /// Chart cards observe this to trigger autoscale.
    @Published private(set) var autoscaleGeneration: Int = 0

    /// Add a new signal. Pass `groupID` to overlay it on an existing chart;
    /// omit (or pass nil) to open it on its own new chart.
    func addSignalTrace(_ signal: TracedSignal, toGroup groupID: UUID? = nil) {
        guard !signalTraces.contains(where: { $0.signal == signal }) else { return }
        let label = signal.displayLabel(in: network)
        // Pick palette color based on the number of existing traces in the target group.
        let countInGroup: Int
        if let gid = groupID {
            countInGroup = signalTraces.filter { $0.chartGroupID == gid }.count
        } else {
            countInGroup = 0
        }
        let color = kTracePalette[countInGroup % kTracePalette.count]
        signalTraces.append(SignalTrace(id: UUID(),
                                        chartGroupID: groupID ?? UUID(),
                                        signal: signal,
                                        label: label,
                                        points: [],
                                        color: color))
    }

    func removeSignalTrace(id: UUID) {
        signalTraces.removeAll { $0.id == id }
    }

    func clearSignalTraces() {
        signalTraces.removeAll()
    }

    // MARK: - Graph config persistence

    private struct GraphConfig: Codable {
        struct Entry: Codable {
            var signal:  TracedSignal
            var groupID: UUID
            var colorR:  Double? = nil
            var colorG:  Double? = nil
            var colorB:  Double? = nil
        }
        var entries: [Entry]
        var plotWindow: Double
    }

    func saveGraphConfig() {
        let entries = signalTraces.map { t -> GraphConfig.Entry in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            NSColor(t.color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            return GraphConfig.Entry(signal: t.signal, groupID: t.chartGroupID,
                                     colorR: Double(r), colorG: Double(g), colorB: Double(b))
        }
        let config = GraphConfig(entries: entries, plotWindow: plotWindow)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "graph_config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadGraphConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(GraphConfig.self, from: data)
        else { return }
        plotWindow = config.plotWindow
        signalTraces = config.entries.enumerated().map { idx, entry in
            let color: Color
            if let r = entry.colorR, let g = entry.colorG, let b = entry.colorB {
                color = Color(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
            } else {
                color = kTracePalette[idx % kTracePalette.count]
            }
            return SignalTrace(id: UUID(),
                        chartGroupID: entry.groupID,
                        signal: entry.signal,
                        label: entry.signal.displayLabel(in: network),
                        points: [],
                        color: color)
        }
    }

    // MARK: - Run state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var simulationTime: Double = 0
    @Published var dt: Double = 0.05 {
        didSet { simulator.dt = dt }
    }
    @Published var integrationMethod: IntegrationMethod = .rushLarsen {
        didSet { simulator.method = integrationMethod }
    }
    /// Non-nil when the simulation was halted due to numerical divergence.
    @Published private(set) var divergenceError: String? = nil
    @Published var realtimeFactor: Double = 1.0  // 1.0 = real-time; >1 = accelerated

    private var simulator: Simulator
    private var simTimer: Timer?
    /// Hard memory cap on a single neuron's trace buffer. Time-based trimming
    /// (`cutoff = simulator.time − plotWindow`) is the primary mechanism;
    /// this is just a safety net so a runaway window can't blow up memory.
    /// Sized to comfortably hold a 5 s window at current downsample stride.
    private let plotMaxSamples = 500_000
    private let plotDownsampleStride: Int = 1

    // MARK: - Init

    init(network: Network) {
        self.network = network
        self.simulator = Simulator(network: network, dt: 0.01)
        seedTraces()
    }

    static func demoNetwork() -> SimulationViewModel {
        let net = Network()
        let n1 = HHNeuron(name: "N1")
        n1.positionX = 200; n1.positionY = 220
        let n2 = HHNeuron(name: "N2")
        n2.positionX = 520; n2.positionY = 220
        net.addNeuron(n1)
        net.addNeuron(n2)
        net.setStimulus(PulseStimulus(start: 10, duration: 80, amplitude: 10),
                        on: n1.id)
        net.addSynapse(ChemicalSynapse(from: n1.id, to: n2.id,
                                       gMax: 0.5, reversal: 0.0, tauDecay: 6.0))
        return SimulationViewModel(network: net)
    }

    // MARK: - Topology mutations

    func addNeuron(at x: Double, y: Double) {
        let n = HHNeuron(name: "N\(network.neurons.count + 1)")
        n.positionX = x; n.positionY = y
        network.addNeuron(n)
        rebuildSimulator()
    }

    func removeSelected() {
        switch selection {
        case .neuron(let id):      network.removeNeuron(id: id)
        case .synapse(let id):     network.removeSynapse(id: id)
        case .compartment, .none:  return
        }
        selection = .none
        rebuildSimulator()
    }

    /// Deep-copy the selected neuron (delegates to Network.duplicateNeuron which has
    /// access to internal NeuroSimCore helpers for channel deep-copying).
    func duplicateSelectedNeuron(withConnections: Bool) {
        guard case .neuron(let id) = selection else { return }
        guard let (newNeuron, compIDMap) = network.duplicateNeuron(id: id) else { return }

        if withConnections {
            let newNeuronID = newNeuron.id
            for syn in network.synapses where syn.preNeuronID == id || syn.postNeuronID == id {
                let newPre  = syn.preNeuronID  == id ? newNeuronID : syn.preNeuronID
                let newPost = syn.postNeuronID == id ? newNeuronID : syn.postNeuronID
                if let chem = syn as? ChemicalSynapse {
                    let newPostComp: UUID? = (chem.postNeuronID == id)
                        ? chem.postCompartmentID.flatMap { compIDMap[$0] }
                        : chem.postCompartmentID
                    network.addSynapse(ChemicalSynapse(
                        from: newPre, to: newPost,
                        onCompartment: newPostComp,
                        gMax: chem.gMax, reversal: chem.reversal,
                        tauDecay: chem.tauDecay, sMax: chem.sMax, weight: chem.weight))
                } else if let gj = syn as? GapJunction {
                    network.addSynapse(GapJunction(
                        from: newPre, to: newPost,
                        conductance: gj.conductance, weight: gj.weight))
                }
            }
        }

        selection = .neuron(newNeuron.id)
        rebuildSimulator()
    }

    /// Add a chemical synapse between two neurons. `reversal` controls
    /// whether it is excitatory (≈ 0 mV) or inhibitory (≈ -75 mV); the
    /// tool palette passes the appropriate value depending on which
    /// synapse tool was active when the user dragged.
    func addSynapse(from preID: UUID, to postID: UUID,
                    compartmentID: UUID? = nil, reversal: Double = 0.0) {
        guard preID != postID else { return }
        // nil compartmentID = soma. Allow multiple N1→N2 synapses on different compartments.
        let postNeuron = network.neurons.first { $0.id == postID }
        let targetCompID: UUID? = compartmentID == postNeuron?.somaCompartmentID ? nil : compartmentID
        if network.synapses.contains(where: {
            $0.preNeuronID == preID && $0.postNeuronID == postID
            && $0.postCompartmentID == targetCompID
        }) { return }
        network.addSynapse(ChemicalSynapse(from: preID, to: postID,
                                           onCompartment: targetCompID,
                                           gMax: 0.3, reversal: reversal,
                                           tauDecay: 6.0))
        rebuildSimulator()
    }

    /// Add an electrical synapse (gap junction) between two neurons.
    /// Model: I = g · (V_pre − V_post), bidirectional. We avoid
    /// duplicates in either direction since gap junctions are symmetric.
    func addGapJunction(from preID: UUID, to postID: UUID, conductance: Double = 0.05) {
        guard preID != postID else { return }
        let alreadyConnected = network.synapses.contains { syn in
            guard syn is GapJunction else { return false }
            return (syn.preNeuronID == preID && syn.postNeuronID == postID)
                || (syn.preNeuronID == postID && syn.postNeuronID == preID)
        }
        if alreadyConnected { return }
        network.addSynapse(GapJunction(from: preID, to: postID,
                                       conductance: conductance))
        rebuildSimulator()
    }

    func setNeuronPosition(_ id: UUID, x: Double, y: Double) {
        guard let n = network.neurons.first(where: { $0.id == id }) else { return }
        n.positionX = x; n.positionY = y
        objectWillChange.send()
    }

    func setCompartmentAngle(_ neuronID: UUID, compartmentID: UUID, angle: Double) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compartmentID })
        else { return }
        comp.displayAngle = angle
        objectWillChange.send()
    }

    // MARK: - Compartment mutations

    /// Create a child compartment off the currently selected compartment or neuron.
    /// Returns the new compartment, or nil if nothing relevant is selected.
    @discardableResult
    func addCompartmentToSelection() -> Compartment? {
        print("[DEBUG] addCompartmentToSelection called, selection=\(selection)")
        switch selection {
        case .compartment(let compID):
            guard let neuron = network.neurons.first(where: { n in
                n.compartments.contains(where: { $0.id == compID })
            }) else { return nil }
            let comp = addCompartment(to: neuron.id, parent: compID)
            if let comp { selection = .compartment(comp.id) }
            return comp
        case .neuron(let neuronID):
            let comp = addCompartment(to: neuronID)
            if let comp { selection = .compartment(comp.id) }
            return comp
        default:
            return nil
        }
    }

    /// Append a new compartment to a neuron and auto-couple it to the
    /// current soma so it isn't electrically floating. Returns the new
    /// compartment so callers can immediately select it in the UI.
    @discardableResult
    func addCompartment(to neuronID: UUID,
                        parent parentID: UUID? = nil,
                        name: String? = nil,
                        channels: [IonChannel] = [LeakChannel()]) -> Compartment? {
        guard let n = network.neurons.first(where: { $0.id == neuronID }) else { return nil }
        let label = name ?? "dend\(n.compartments.count)"
        let comp = Compartment(name: label, channels: channels)
        let attachTo = parentID ?? n.somaCompartmentID
        n.compartments.append(comp)
        n.axialCouplings.append(
            AxialCoupling(between: attachTo, and: comp.id, conductance: 0.5)
        )
        network.notifyStructuralChange()
        rebuildSimulator()
        return comp
    }

    /// Remove a compartment from a neuron (must not be the soma; the neuron
    /// must keep at least one compartment). Drops any couplings touching it,
    /// any stimulus targeting it, and demotes synapses targeting it back to
    /// the soma fallback.
    func removeCompartment(_ compID: UUID, from neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }) else { return }
        guard compID != n.somaCompartmentID else { return }
        guard n.compartments.count > 1 else { return }

        n.compartments.removeAll { $0.id == compID }
        n.axialCouplings.removeAll { $0.involves(compID) }
        network.setStimulus(nil, onCompartment: compID)
        for syn in network.synapses where syn.postCompartmentID == compID {
            syn.postCompartmentID = nil   // gracefully fall back to soma
        }
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    /// Promote a different compartment to be the spike-detection / default-
    /// stim-target soma. The state-vector layout doesn't change, but the
    /// semantics for spike dispatch and back-compat APIs do.
    func setSoma(_ compID: UUID, of neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              n.compartments.contains(where: { $0.id == compID })
        else { return }
        n.somaCompartmentID = compID
        objectWillChange.send()
    }

    func renameCompartment(_ compID: UUID, in neuronID: UUID, to newName: String) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compID })
        else { return }
        comp.name = newName
        objectWillChange.send()
    }

    // MARK: - Axial coupling mutations

    func addCoupling(between aID: UUID,
                     and bID: UUID,
                     in neuronID: UUID,
                     conductance: Double = 0.5) {
        guard aID != bID,
              let n = network.neurons.first(where: { $0.id == neuronID })
        else { return }
        let exists = n.axialCouplings.contains {
            ($0.compartmentA == aID && $0.compartmentB == bID) ||
            ($0.compartmentA == bID && $0.compartmentB == aID)
        }
        if exists { return }
        n.axialCouplings.append(
            AxialCoupling(between: aID, and: bID, conductance: conductance)
        )
        objectWillChange.send()
    }

    func removeCoupling(_ couplingID: UUID, from neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }) else { return }
        n.axialCouplings.removeAll { $0.id == couplingID }
        objectWillChange.send()
    }

    // MARK: - Channel mutations (per compartment)

    /// Append a freshly-instantiated channel of the given kind to a
    /// compartment. Changes the state-vector layout, so the simulator is
    /// rebuilt and traces reseeded.
    func addChannel(_ kind: ChannelKind,
                    toCompartment compID: UUID,
                    in neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compID })
        else { return }
        comp.channels.append(kind.makeInstance())
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    func addCustomChannel(_ definition: CustomChannelDefinition,
                          toCompartment compID: UUID,
                          in neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compID })
        else { return }
        comp.channels.append(CustomChannel(definition: definition))
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    func addIonChannel(_ channel: IonChannel,
                       toCompartment compID: UUID,
                       in neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compID })
        else { return }
        comp.channels.append(channel)
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    func addMODChannel(_ channel: MODImportedChannel,
                       toCompartment compID: UUID,
                       in neuronID: UUID) {
        addIonChannel(channel, toCompartment: compID, in: neuronID)
    }

    func replaceChannel(at index: Int,
                        inCompartment compID: UUID,
                        in neuronID: UUID,
                        with channel: IonChannel) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compID }),
              comp.channels.indices.contains(index)
        else { return }
        comp.channels[index] = channel
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    func removeChannel(at index: Int,
                       fromCompartment compID: UUID,
                       in neuronID: UUID) {
        guard let n = network.neurons.first(where: { $0.id == neuronID }),
              let comp = n.compartments.first(where: { $0.id == compID }),
              comp.channels.indices.contains(index)
        else { return }
        comp.channels.remove(at: index)
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    /// Enable/update concentration tracking for an ion in a compartment.
    /// Rebuilds the simulator (changes state-vector layout).
    func setConcentrationDynamic(_ dyn: ConcentrationDynamic,
                                  inCompartment compID: UUID) {
        guard let comp = network.neurons.flatMap(\.compartments)
                             .first(where: { $0.id == compID }) else { return }
        if let i = comp.concentrationDynamics.firstIndex(where: { $0.ionSymbol == dyn.ionSymbol }) {
            comp.concentrationDynamics[i] = dyn
        } else {
            comp.concentrationDynamics.append(dyn)
        }
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    /// Disable concentration tracking for an ion in a compartment.
    func removeConcentrationDynamic(ionSymbol: String, fromCompartment compID: UUID) {
        guard let comp = network.neurons.flatMap(\.compartments)
                             .first(where: { $0.id == compID }) else { return }
        comp.concentrationDynamics.removeAll { $0.ionSymbol == ionSymbol }
        network.notifyStructuralChange()
        rebuildSimulator()
    }

    /// Rebuild the simulator after any structural mutation that changes the
    /// state-vector layout.
    func rebuildSimulatorPublic() { rebuildSimulator() }

    private func rebuildSimulator() {
        let wasRunning = isRunning
        if wasRunning { pause() }
        simulator = Simulator(network: network, dt: dt)
        simulationTime = 0
        seedTraces()
        if wasRunning { play() }
    }

    private func seedTraces() {
        var t: [UUID: [PlotPoint]] = [:]
        for n in network.neurons { t[n.id] = [] }
        traces = t
        for i in signalTraces.indices { signalTraces[i].points = [] }
    }

    // MARK: - Run / pause / reset

    func toggleRunning() { isRunning ? pause() : play() }

    func play() {
        guard !isRunning else { return }
        divergenceError = nil
        simulator.reset()
        simulationTime = 0
        seedTraces()

        isRunning = true
        simulator.dt = dt
        simulator.method = integrationMethod
        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0,
                                        repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        simTimer?.invalidate()
        simTimer = nil
        isRunning = false
    }

    func reset() {
        pause()
        divergenceError = nil
        simulator.reset()
        simulationTime = 0
        seedTraces()
    }

    /// One UI frame of simulation work. Compute as many `dt` steps as needed
    /// to make the simulated time advance at `realtimeFactor` × wall clock,
    /// capped so the run stops cleanly when `simulationTime` reaches
    /// `plotWindow` (the visualised duration).
    private func tick() {
        // Stop cleanly when the configured run length is reached.
        if simulator.time >= plotWindow {
            pause()
            autoscaleGeneration += 1
            return
        }

        // Target: 1/60 s of wall ≈ realtimeFactor × 16.67 ms simulated.
        let frameDurationMs = 1000.0 / 60.0
        let simulatedMsPerFrame = frameDurationMs * realtimeFactor
        var nSteps = max(1, Int((simulatedMsPerFrame / dt).rounded()))

        // Don't overshoot the plotWindow on the last frame.
        let remaining = plotWindow - simulator.time
        let maxSteps = max(1, Int((remaining / dt).rounded()))
        nSteps = min(nSteps, maxSteps)

        var newSamples: [(UUID, Double, Double)] = []
        newSamples.reserveCapacity(nSteps / plotDownsampleStride * network.neurons.count)

        // Accumulate signal trace points locally to avoid repeated Published mutations.
        var newSignalPoints: [[PlotPoint]] = signalTraces.isEmpty
            ? [] : Array(repeating: [], count: signalTraces.count)

        for i in 0..<nSteps {
            simulator.step()

            // Detect numerical divergence (NaN or |V| > 1000 mV on any compartment).
            let diverged = network.neurons.contains { n in
                guard let idx = network.voltageIndex(of: n.id) else { return false }
                let v = simulator.state[idx]
                return v.isNaN || v.isInfinite || abs(v) > 1_000
            }
            if diverged {
                pause()
                divergenceError = "Divergence numérique détectée à t=\(String(format: "%.2f", simulator.time)) ms. Réduisez dt (recommandé : ≤ 0.05 ms pour HH+RK4)."
                return
            }

            if i % plotDownsampleStride == 0 {
                for n in network.neurons {
                    if let idx = network.voltageIndex(of: n.id) {
                        newSamples.append((n.id, simulator.time, simulator.state[idx]))
                    }
                }
                if !signalTraces.isEmpty {
                    let t  = simulator.time
                    let st = simulator.state
                    for j in signalTraces.indices {
                        if let v = signalTraces[j].signal.value(
                            state: st, network: network, time: t) {
                            newSignalPoints[j].append(PlotPoint(t: t, v: v))
                        }
                    }
                }
            }
        }

        simulationTime = simulator.time
        let cutoff = simulator.time - plotWindow

        for (id, t, v) in newSamples {
            var arr = traces[id] ?? []
            arr.append(PlotPoint(t: t, v: v))
            while let first = arr.first, first.t < cutoff { arr.removeFirst() }
            if arr.count > plotMaxSamples {
                arr.removeFirst(arr.count - plotMaxSamples)
            }
            traces[id] = arr
        }

        for j in signalTraces.indices {
            signalTraces[j].points.append(contentsOf: newSignalPoints[j])
            while let first = signalTraces[j].points.first, first.t < cutoff {
                signalTraces[j].points.removeFirst()
            }
            if signalTraces[j].points.count > plotMaxSamples {
                signalTraces[j].points.removeFirst(
                    signalTraces[j].points.count - plotMaxSamples)
            }
        }
    }

    // MARK: - Stimulus accessors (used by the inspector)

    /// Stimulus on the neuron's **soma** compartment (back-compat helper).
    /// Use `network.stimuli[compartmentID]` for any other compartment.
    func stimulus(for neuronID: UUID) -> Stimulus? {
        guard let n = network.neurons.first(where: { $0.id == neuronID }) else { return nil }
        return network.stimuli[n.somaCompartmentID]
    }

    /// Apply a stimulus to a neuron's soma (back-compat).
    func setStimulus(_ s: Stimulus?, on neuronID: UUID) {
        network.setStimulus(s, on: neuronID)
        objectWillChange.send()
    }

    /// Apply (or remove, when `s == nil`) a stimulus on a specific compartment.
    /// Used by the multi-compartment inspector — lets dendritic/axonal stims
    /// be configured directly from the GUI.
    func setStimulus(_ s: Stimulus?, onCompartment compartmentID: UUID) {
        network.setStimulus(s, onCompartment: compartmentID)
        objectWillChange.send()
    }

    // MARK: - Synaptic noise

    func synapticNoise(forCompartment id: UUID) -> SynapticNoiseParams? {
        network.synapticNoises[id]?.params
    }

    func setSynapticNoise(_ params: SynapticNoiseParams?, onCompartment id: UUID) {
        objectWillChange.send()
        network.setSynapticNoise(params, onCompartment: id)
        rebuildSimulator()
    }

    /// Update noise parameters in-place without resetting the simulator.
    /// Called during live slider edits in the inspector.
    func updateSynapticNoiseParams(_ params: SynapticNoiseParams, forCompartment id: UUID) {
        network.synapticNoises[id]?.params = params
        objectWillChange.send()
    }

    // MARK: - Document (save / load / new)

    /// URL of the file currently open on disk, nil when unsaved.
    @Published private(set) var documentURL: URL?

    /// Display name shown in the window title bar.
    var documentName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func newNetwork() {
        pause()
        network = Network()
        documentURL = nil
        rebuildSimulator()
    }

    func saveNetwork() {
        if let url = documentURL {
            writeDocument(to: url)
        } else {
            saveNetworkAs()
        }
    }

    func saveNetworkAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(documentName).neurosim.json"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                self.documentURL = url
                self.writeDocument(to: url)
            }
        }
    }

    func openNetwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in self.loadDocument(from: url) }
        }
    }

    /// Merge a saved network file into the current network (neurons + synapses + stimuli + noise).
    /// Imported neurons are offset to the right of existing ones so they don't overlap.
    func importNetwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Importer"
        panel.message = "Ajouter un neurone ou un réseau au réseau actuel"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(NetworkDocument.self, from: data) else { return }
            Task { @MainActor in
                let imported = doc.toNetwork()
                let offsetX = (self.network.neurons.map(\.positionX).max() ?? -200) + 200
                for neuron in imported.neurons {
                    neuron.positionX += offsetX
                    self.network.addNeuron(neuron)
                }
                for syn in imported.synapses { self.network.addSynapse(syn) }
                for (compID, stim) in imported.stimuli {
                    self.network.setStimulus(stim, onCompartment: compID)
                }
                for (compID, src) in imported.synapticNoises {
                    self.network.synapticNoises[compID] = src
                }
                self.rebuildSimulator()
            }
        }
    }

    private func writeDocument(to url: URL) {
        var doc = NetworkDocument.from(network)
        doc.graphConfig = NetworkDocument.GraphConfigDoc(
            entries: signalTraces.map { t in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                NSColor(t.color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                return NetworkDocument.GraphConfigDoc.Entry(
                    signal: t.signal, groupID: t.chartGroupID,
                    colorR: Double(r), colorG: Double(g), colorB: Double(b))
            },
            plotWindow: plotWindow
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadDocument(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(NetworkDocument.self, from: data)
        else { return }
        pause()
        network = doc.toNetwork()
        documentURL = url
        if let gc = doc.graphConfig {
            plotWindow = gc.plotWindow
            signalTraces = gc.entries.enumerated().map { idx, entry in
                let color: Color
                if let r = entry.colorR, let g = entry.colorG, let b = entry.colorB {
                    color = Color(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
                } else {
                    color = kTracePalette[idx % kTracePalette.count]
                }
                return SignalTrace(id: UUID(),
                            chartGroupID: entry.groupID,
                            signal: entry.signal,
                            label: entry.signal.displayLabel(in: network),
                            points: [],
                            color: color)
            }
        }
        rebuildSimulator()
    }

    // MARK: - Export

    func exportTracesCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "neurosim_traces.csv"

        let neuronIDs = network.neurons.map(\.id)
        let names     = network.neurons.map(\.name)
        let baseline  = neuronIDs.first.flatMap { traces[$0] } ?? []
        var lines: [String] = []
        lines.append((["t_ms"] + names).joined(separator: ","))
        for (i, p) in baseline.enumerated() {
            var row = [String(format: "%.4f", p.t)]
            for id in neuronIDs {
                let v = traces[id]?[safe: i]?.v ?? .nan
                row.append(String(format: "%.6f", v))
            }
            lines.append(row.joined(separator: ","))
        }
        let csv = lines.joined(separator: "\n")

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

