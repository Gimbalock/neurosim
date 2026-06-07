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

    // MARK: - Network builder sheet
    @Published var showNetworkBuilder = false
    @Published var networkBuilderInitialTab: Int = 0

    // MARK: - Axon builder sheet
    @Published var showAxonBuilder = false

    // MARK: - Neuron canvas color mode

    /// Quantity used to colour neuron circles on the canvas.
    enum NeuronColorMode: String, CaseIterable, Identifiable {
        case voltage = "Potentiel V"
        case atp     = "ATP"
        case naI     = "[Na]ᵢ"
        case kI      = "[K]ᵢ"
        case caI     = "[Ca²⁺]ᵢ"
        var id: String { rawValue }
        var unit: String {
            switch self {
            case .voltage: return "mV"
            case .atp:     return "mM"
            case .naI:     return "mM"
            case .kI:      return "mM"
            case .caI:     return "µM"
            }
        }
    }
    @Published var neuronColorMode: NeuronColorMode = .voltage

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

    // MARK: - Energy traces

    /// One time-stamped metabolic snapshot per neuron (only for neurons with energy enabled).
    struct EnergyPlotPoint {
        let t: Double
        let naI: Double      // [Na]_i mM
        let kI:  Double      // [K]_i  mM
        let naO: Double      // [Na]_o mM
        let kO:  Double      // [K]_o  mM
        let atp: Double      // [ATP]  mM
        let adp: Double      // [ADP]  mM
        let pi:  Double      // [Pi]   mM
        let atpConsumed: Double  // cumulative (mM)
        let eNa: Double      // Nernst E_Na mV
        let eK:  Double      // Nernst E_K  mV
        let pumpRate: Double   // mM/ms instantaneous pump ATP consumption
        let pumpDemand: Double // mM/ms pump demand at unlimited ATP
        let caI: Double      // [Ca²⁺]ᵢ mM
    }

    @Published private(set) var energyTraces: [UUID: [EnergyPlotPoint]] = [:]

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

    // MARK: - Optimisation settings (persisted with the network document)

    @Published var optimSettings: NetworkDocument.OptimSettingsDoc? = nil

    // MARK: - Parameter snapshots ("freeze states")

    /// Named parameter snapshots — each one is a frozen copy of the full
    /// network model at the time the user clicked "Freeze State".
    @Published var snapshots: [NetworkDocument.ModelSnapshot] = []

    /// Create a new named snapshot from the current network parameters.
    func freezeState(name: String) {
        let doc = NetworkDocument.from(network)
        let snap = NetworkDocument.ModelSnapshot(name: name, network: doc)
        snapshots.insert(snap, at: 0)   // newest first
    }

    /// Restore the network parameters from a snapshot, then rebuild the simulator.
    /// The simulation is paused first; warm state is cleared (topology may have changed).
    func restoreSnapshot(_ snapshot: NetworkDocument.ModelSnapshot) {
        pause()
        network = snapshot.network.toNetwork()
        rebuildSimulator()   // clears warm state
        objectWillChange.send()
    }

    /// Delete a snapshot by id.
    func deleteSnapshot(id: UUID) {
        snapshots.removeAll { $0.id == id }
    }

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
        pendingSignalPoints.append([])   // keep parallel array in sync
    }

    func removeSignalTrace(id: UUID) {
        if let idx = signalTraces.firstIndex(where: { $0.id == id }) {
            pendingSignalPoints.remove(at: idx)
        }
        signalTraces.removeAll { $0.id == id }
    }

    /// Remove the trace matching a given signal (used by the picker toggle in "add to group" mode).
    func removeSignalTrace(signal: TracedSignal) {
        if let idx = signalTraces.firstIndex(where: { $0.signal == signal }) {
            pendingSignalPoints.remove(at: idx)
        }
        signalTraces.removeAll { $0.signal == signal }
    }

    func clearSignalTraces() {
        signalTraces.removeAll()
        pendingSignalPoints.removeAll()
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
        pendingSignalPoints = Array(repeating: [], count: signalTraces.count)
    }

    // MARK: - Run state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var simulationTime: Double = 0
    /// Wall-clock duration of the last simulation frame (ms).
    @Published private(set) var frameComputeMs: Double = 0
    /// Simulated ms advanced per wall-clock ms (>1 = faster than real-time).
    @Published private(set) var simToWallRatio: Double = 0
    @Published var dt: Double = 0.05 {
        didSet { simulator.dt = dt }
    }
    @Published var integrationMethod: IntegrationMethod = .rushLarsen {
        didSet { simulator.method = integrationMethod }
    }
    /// Non-nil when the simulation was halted due to numerical divergence.
    @Published private(set) var divergenceError: String? = nil
    @Published var realtimeFactor: Double = 1.0  // 1.0 = real-time; >1 = accelerated

    /// Resting voltage (mV) used when initialising/resetting the simulator.
    /// Defaults to −65 mV (standard HH). Set to −80 mV for T-type-based
    /// pacemakers that need the inactivation gate h_T to be pre-deinactivated.
    var preferredRestingVoltage: Double = -65.0

    // MARK: - Warm-start state

    /// Final state vector captured at the end of the last simulation run.
    /// When non-nil the next `play()` restores this state (V, gates, [ion])
    /// instead of initialising from resting steady state.
    /// Cleared by an explicit `reset()` or by any structural topology change
    /// (adding/removing neurons/channels/compartments).
    private var savedFinalState: [Double]? = nil

    /// True when a warm state is available. Published so the UI can show
    /// the "⚡ warm" indicator and adjust button labels.
    @Published private(set) var hasWarmState: Bool = false

    private var simulator: Simulator
    private var simTimer: Timer?
    /// Prevents overlapping simulation frames if computation exceeds 1/60 s.
    private var frameInFlight = false

    // ── Pending (non-@Published) sample buffers ───────────────────────────────
    // The hot loop writes here every frame (no SwiftUI re-render).
    // `kickFrame` flushes them to the @Published vars at ≤30 fps so Charts
    // and the canvas don't redraw on every simulation step.
    private var pendingTraces:       [UUID: [PlotPoint]]       = [:]
    private var pendingEnergyTraces: [UUID: [EnergyPlotPoint]] = [:]
    /// Parallel to `signalTraces`; only the `.points` array is maintained here.
    private var pendingSignalPoints: [[PlotPoint]]             = []
    private var pendingSimTime:      Double                    = 0
    /// Wall-clock instant of the last display flush (used to throttle to ≤30 fps).
    private var lastDisplayFlush: ContinuousClock.Instant      = .now
    /// Wall-clock instant at the start of the most recent kickFrame() call.
    /// Used to compute actual inter-frame elapsed time, which determines how many
    /// simulation steps to run — this enforces the correct realtimeFactor regardless
    /// of how fast the background task completes (prevents the sim from running ahead
    /// of real-time when self-scheduling is used with fast/simple networks).
    private var lastKickStartTime: ContinuousClock.Instant     = .now

    /// Hard memory cap on a single neuron's trace buffer. Time-based trimming
    /// (`cutoff = simulator.time − plotWindow`) is the primary mechanism;
    /// this is a safety net so a runaway window can't blow up memory.
    /// At stride 4 and dt 0.025 ms a 5 s window holds ~50 000 points.
    private let plotMaxSamples = 100_000
    /// Record one sample every N simulation steps.
    /// stride 4 × dt 0.025 ms = one point every 0.1 ms.
    /// A 200 ms window → 2 000 pts/trace; a 5 s window → 50 000 pts/trace.
    /// Action-potential detail is fully preserved (≥ 20 pts per ~2 ms spike).
    private let plotDownsampleStride: Int = 4

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

    /// Add an NMDA synapse between two neurons.
    /// Features voltage-dependent Mg²⁺ block — acts as coincidence detector
    /// (requires both pre-synaptic input AND post-synaptic depolarisation).
    func addNMDASynapse(from preID: UUID, to postID: UUID, compartmentID: UUID? = nil) {
        guard preID != postID else { return }
        let postNeuron = network.neurons.first { $0.id == postID }
        let targetCompID: UUID? = compartmentID == postNeuron?.somaCompartmentID ? nil : compartmentID
        if network.synapses.contains(where: {
            $0 is NMDASynapse
            && $0.preNeuronID == preID && $0.postNeuronID == postID
            && $0.postCompartmentID == targetCompID
        }) { return }
        network.addSynapse(NMDASynapse(from: preID, to: postID,
                                       onCompartment: targetCompID,
                                       gMax: 0.1, reversal: 0.0, tauDecay: 100.0))
        rebuildSimulator()
    }

    /// Add an AMPA synapse with STDP plasticity between two neurons.
    /// Weight evolves via trace-based STDP: LTP on causal spike pairs,
    /// LTD on anti-causal pairs.
    func addSTDPSynapse(from preID: UUID, to postID: UUID, compartmentID: UUID? = nil) {
        guard preID != postID else { return }
        let postNeuron = network.neurons.first { $0.id == postID }
        let targetCompID: UUID? = compartmentID == postNeuron?.somaCompartmentID ? nil : compartmentID
        if network.synapses.contains(where: {
            $0 is STDPSynapse
            && $0.preNeuronID == preID && $0.postNeuronID == postID
            && $0.postCompartmentID == targetCompID
        }) { return }
        network.addSynapse(STDPSynapse(from: preID, to: postID,
                                       onCompartment: targetCompID,
                                       gMax: 0.1, reversal: 0.0, tauDecay: 5.0))
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
        objectWillChange.send()
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

        objectWillChange.send()          // notify SwiftUI before mutating class properties
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
        // Topology changed → state-vector layout changed → warm state is stale.
        savedFinalState = nil
        hasWarmState    = false
        simulator = Simulator(network: network, dt: dt)
        simulationTime = 0
        seedTraces()
        if wasRunning { play() }
    }

    private func seedTraces() {
        var t: [UUID: [PlotPoint]] = [:]
        for n in network.neurons { t[n.id] = [] }
        traces        = t
        pendingTraces = t
        for i in signalTraces.indices { signalTraces[i].points = [] }
        pendingSignalPoints = Array(repeating: [], count: signalTraces.count)
        var et: [UUID: [EnergyPlotPoint]] = [:]
        for n in network.neurons where n.energyParams.enabled { et[n.id] = [] }
        energyTraces        = et
        pendingEnergyTraces = et
        pendingSimTime      = 0
    }

    // MARK: - Run / pause / reset

    func toggleRunning() { isRunning ? pause() : play() }

    func play() {
        guard !isRunning else { return }
        divergenceError = nil
        // Warm start: restore the final state of the last run so the simulation
        // continues from where it stopped. Stimuli are re-armed to t=0 so they
        // fire on schedule relative to the new window.
        if let ws = savedFinalState {
            simulator.resetToWarmState(ws, fallbackVoltage: preferredRestingVoltage)
        } else {
            simulator.reset(restingVoltage: preferredRestingVoltage)
        }
        simulationTime = 0
        seedTraces()

        isRunning = true
        frameInFlight = false
        simulator.dt = dt
        simulator.method = integrationMethod
        lastDisplayFlush  = .now
        lastKickStartTime = .now   // reset so first frame uses a clean baseline

        // Kick the first frame immediately — no need to wait for the timer's
        // first tick (which could be up to 16 ms away).
        Task { @MainActor [weak self] in self?.kickFrame() }

        // Keep the timer as a fallback heartbeat in case the self-scheduling
        // chain ever breaks (e.g. divergence branch returns early).
        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0,
                                        repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kickFrame() }
        }
    }

    func pause() {
        simTimer?.invalidate()
        simTimer = nil
        isRunning = false
        frameInFlight = false
        // Flush any pending data so views show the last simulated state.
        flushPendingDisplay()
    }

    /// Copy pending (non-@Published) buffers → @Published vars, triggering one
    /// SwiftUI redraw.  Called by the display-throttle inside kickFrame and by pause().
    private func flushPendingDisplay() {
        simulationTime = pendingSimTime
        traces         = pendingTraces
        if !pendingEnergyTraces.isEmpty { energyTraces = pendingEnergyTraces }
        if !pendingSignalPoints.isEmpty && pendingSignalPoints.count == signalTraces.count {
            var st = signalTraces
            for j in st.indices { st[j].points = pendingSignalPoints[j] }
            signalTraces = st   // single @Published write → one SwiftUI re-render
        }
    }

    /// Explicit cold reset: clears the warm state and re-initialises every
    /// neuron to its resting voltage. Use this when you want to start fresh
    /// regardless of the last simulation's final state.
    func reset() {
        pause()
        divergenceError  = nil
        savedFinalState  = nil
        hasWarmState     = false
        simulator.reset(restingVoltage: preferredRestingVoltage)
        simulationTime = 0
        seedTraces()
    }

    /// Simulation driver.
    ///
    /// Architecture (post-optimisation):
    ///  - Background `Task.detached` runs nSteps of integration (no main-thread stall).
    ///  - After each batch the main-actor commit immediately self-reschedules the next
    ///    batch via `Task { @MainActor in kickFrame() }` — no idle gap waiting for the
    ///    60 fps timer tick (which stays as a fallback heartbeat only).
    ///  - Data is accumulated in non-@Published `pending*` buffers every simulation
    ///    frame; the @Published `traces/energyTraces/signalTraces` are flushed at most
    ///    once every 33 ms (~30 fps) so SwiftUI / Charts re-render less often.
    ///  - `frameInFlight` prevents overlapping frames if a batch takes longer than the
    ///    reschedule interval.
    private func kickFrame() {
        guard isRunning, !frameInFlight else { return }

        if simulator.time >= plotWindow {
            // Capture the final state BEFORE pausing so the next play() can
            // warm-start from here. The state is a value-type copy — safe.
            savedFinalState = simulator.state
            hasWarmState    = true
            pause()
            autoscaleGeneration += 1
            return
        }

        // ── Compute how many steps to simulate this frame ──────────────────────
        //
        // Use ACTUAL elapsed wall-clock time since the last kickFrame() call
        // rather than a fixed 16.67 ms nominal frame period.
        //
        // Rationale: with self-scheduling, fast/simple networks can call
        // kickFrame() 700+ times per second.  Each call used to simulate
        // 16.67 ms × realtimeFactor regardless — making a 200 ms simulation
        // complete in ~17 ms wall time (11.6× too fast at realtimeFactor=1).
        // Measuring actual elapsed time makes the simulation self-pacing:
        //
        //   • Fast network (1 neuron, RL):  cycle ≈ 0.10 ms  →  nSteps ≈ 4
        //     700 frames/s × 4 steps × 0.025 ms = 70 ms sim / 70 ms wall ≈ 1× ✓
        //
        //   • Slow network (10 neurons):    cycle ≈ 25 ms   → nSteps ≈ 1000
        //     40 frames/s × 1000 steps × 0.025 ms = 1000 ms sim / 1000 ms wall ≈ 1× ✓
        //
        //   • realtimeFactor = 10:  nSteps = elapsed × 10 / dt  → 10× real-time
        //     (capped by hardware; `simToWallRatio` in the UI shows actual ratio)
        //
        // The cap at 50 ms prevents the first frame after a suspend from
        // trying to catch up all the missed time in one giant batch.
        let kickNow = ContinuousClock.now
        let wallDeltaMs: Double = {
            let e   = kickNow - lastKickStartTime
            let ms  = Double(e.components.seconds)     * 1_000.0
                    + Double(e.components.attoseconds) / 1_000_000_000_000_000.0
            return max(0.0, min(ms, 50.0))
        }()
        lastKickStartTime = kickNow

        let simulatedMsPerFrame = wallDeltaMs * realtimeFactor
        var nSteps = max(1, Int((simulatedMsPerFrame / dt).rounded()))
        let remaining = plotWindow - simulator.time
        nSteps = min(nSteps, max(1, Int((remaining / dt).rounded())))

        // Capture all inputs by value before leaving the main actor.
        let capturedSim  = simulator
        let capturedNet  = network
        let neuronIdx: [(UUID, Int)] = network.neurons.compactMap { n in
            guard let i = network.voltageIndex(of: n.id) else { return nil }
            return (n.id, i)
        }
        let energyNeuronIDs: [UUID] = network.neurons.filter { $0.energyParams.enabled }.map(\.id)
        let capturedSignals = signalTraces.map { $0.signal }
        let stride     = plotDownsampleStride
        let plotWin    = plotWindow
        let maxSamples = plotMaxSamples

        frameInFlight = true
        let wallStart = ContinuousClock.now
        let simulatedMsThisFrame = Double(nSteps) * dt

        Task.detached(priority: .userInitiated) { [weak self] in
            // ── Hot simulation loop — runs on a background thread ─────────────
            var voltSamples: [(UUID, Double, Double)] = []
            voltSamples.reserveCapacity(nSteps * neuronIdx.count)
            var energySamples: [(UUID, Double, SimulationViewModel.EnergyPlotPoint)] = []
            var sigSamples: [[SimulationViewModel.PlotPoint]] =
                capturedSignals.isEmpty ? [] : Array(repeating: [], count: capturedSignals.count)
            var divergeMsg: String? = nil

            outer: for i in 0..<nSteps {
                capturedSim.step()

                for (_, vIdx) in neuronIdx {
                    let v = capturedSim.state[vIdx]
                    if v.isNaN || v.isInfinite || abs(v) > 1_000 {
                        divergeMsg = "Divergence numérique détectée à t=\(String(format: "%.2f", capturedSim.time)) ms. Réduisez dt (recommandé : ≤ 0.05 ms pour HH+RK4)."
                        break outer
                    }
                }

                if i % stride == 0 {
                    let t = capturedSim.time
                    for (id, vIdx) in neuronIdx {
                        voltSamples.append((id, t, capturedSim.state[vIdx]))
                    }
                    // Energy samples — only for neurons with energy tracking enabled.
                    for nid in energyNeuronIDs {
                        if let es = capturedSim.energyStates[nid] {
                            let ep = SimulationViewModel.EnergyPlotPoint(
                                t: t, naI: es.naI, kI: es.kI, naO: es.naO, kO: es.kO,
                                atp: es.atp, adp: es.adp, pi: es.pi,
                                atpConsumed: es.atpConsumedTotal,
                                eNa: es.eNa, eK: es.eK,
                                pumpRate: es.pumpRateLast, pumpDemand: es.pumpDemandLast,
                                caI: es.caI)
                            energySamples.append((nid, t, ep))
                        }
                    }
                    if !capturedSignals.isEmpty {
                        let st = capturedSim.state
                        for (j, sig) in capturedSignals.enumerated() {
                            let v = sig.value(state: st, network: capturedNet, time: t)
                                   ?? sig.energyValue(energyStates: capturedSim.energyStates)
                            if let v { sigSamples[j].append(.init(t: t, v: v)) }
                        }
                    }
                }
            }
            // Freeze mutable vars into immutable lets before the actor hop
            // so the compiler can verify there's no cross-actor mutation.
            let finalTime      = capturedSim.time
            let fVoltSamples   = voltSamples
            let fEnergySamples = energySamples
            let fSigSamples    = sigSamples
            let fDivergeMsg    = divergeMsg
            let elapsed      = ContinuousClock.now - wallStart
            let wallMs       = Double(elapsed.components.seconds) * 1_000.0
                             + Double(elapsed.components.attoseconds) / 1e15
            let ratio        = wallMs > 0 ? simulatedMsThisFrame / wallMs : 0

            // ── Back to main actor: commit samples + throttled display flush ─────
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.frameInFlight = false
                self.frameComputeMs = wallMs
                self.simToWallRatio = ratio

                if let msg = fDivergeMsg {
                    self.divergenceError = msg
                    self.pause()
                    return   // don't reschedule
                }

                let cutoff = finalTime - plotWin
                self.pendingSimTime = finalTime

                // ── Voltage traces → pendingTraces (no @Published write) ──────
                var pt = self.pendingTraces
                for (id, t, v) in fVoltSamples {
                    pt[id, default: []].append(.init(t: t, v: v))
                }
                for id in pt.keys {
                    guard var arr = pt[id], !arr.isEmpty else { continue }
                    var lo = 0, hi = arr.count
                    while lo < hi {
                        let mid = lo + (hi - lo) / 2
                        if arr[mid].t < cutoff { lo = mid + 1 } else { hi = mid }
                    }
                    if lo > 0 { arr.removeSubrange(0..<lo) }
                    if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
                    pt[id] = arr
                }
                self.pendingTraces = pt

                // ── Energy traces → pendingEnergyTraces ───────────────────────
                if !fEnergySamples.isEmpty {
                    var et = self.pendingEnergyTraces
                    for (id, _, ep) in fEnergySamples {
                        et[id, default: []].append(ep)
                    }
                    for id in et.keys {
                        guard var arr = et[id], !arr.isEmpty else { continue }
                        var lo = 0, hi = arr.count
                        while lo < hi {
                            let mid = lo + (hi - lo) / 2
                            if arr[mid].t < cutoff { lo = mid + 1 } else { hi = mid }
                        }
                        if lo > 0 { arr.removeSubrange(0..<lo) }
                        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
                        et[id] = arr
                    }
                    self.pendingEnergyTraces = et
                }

                // ── Signal traces → pendingSignalPoints ───────────────────────
                if !fSigSamples.isEmpty &&
                   fSigSamples.count == self.pendingSignalPoints.count {
                    for j in self.pendingSignalPoints.indices {
                        var arr = self.pendingSignalPoints[j]
                        arr.append(contentsOf: fSigSamples[j])
                        var lo = 0, hi = arr.count
                        while lo < hi {
                            let mid = lo + (hi - lo) / 2
                            if arr[mid].t < cutoff { lo = mid + 1 } else { hi = mid }
                        }
                        if lo > 0 { arr.removeSubrange(0..<lo) }
                        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
                        self.pendingSignalPoints[j] = arr
                    }
                }

                // ── Throttled display flush (~30 fps) ─────────────────────────
                // Charts are expensive to re-render; skip @Published writes that
                // arrive faster than 33 ms apart.
                let now = ContinuousClock.now
                if (now - self.lastDisplayFlush) >= .milliseconds(33) {
                    self.lastDisplayFlush = now
                    self.flushPendingDisplay()
                }

                // ── Self-reschedule immediately (no idle gap waiting for timer) ─
                // This is the key throughput fix: as soon as frame N finishes its
                // background compute + main-actor commit, frame N+1 starts right
                // away instead of waiting up to 16 ms for the next timer tick.
                if self.isRunning {
                    Task { @MainActor [weak self] in self?.kickFrame() }
                }
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

    /// Controls visibility of the WelcomeView overlay.
    /// Set to false as soon as the user picks any action (new / open / import).
    /// Not reset when the network becomes empty (e.g. after deleting all neurons).
    @Published var showWelcomeScreen: Bool = true

    /// Display name shown in the window title bar.
    var documentName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func newNetwork() {
        pause()
        preferredRestingVoltage = -65.0
        network = Network()
        documentURL = nil
        showWelcomeScreen = false
        rebuildSimulator()
    }

    /// Replace the current network with a fully-built one (used by topology builder).
    func replaceNetwork(_ net: Network) {
        pause()
        network = net
        documentURL = nil
        rebuildSimulator()
    }

    // MARK: - Presets

    /// Neurone oscillateur PD du ganglion stomatogastrique — modèle 2 compartiments.
    ///
    /// Architecture :
    ///   • Soma   : oscillateur lent (I_h + I_CaT + I_SK + I_A + I_leak).
    ///              Pas de Na/K rapides → pas de PA dans le soma.
    ///              Le soma oscille librement (~1 Hz) grâce au cycle :
    ///                I_h dépolarise → I_CaT ouvre (spike Ca bas-seuil)
    ///                → Ca²⁺ monte → I_SK s'active → hyperpolarisation
    ///                → I_h se ré-active → cycle suivant.
    ///
    ///   • AIS    : générateur de PA (Na dense + K repolarisateur + Leak).
    ///              Le courant axial du soma dépolarise l'AIS jusqu'au
    ///              seuil Na (~−55 mV) → PA HH classiques à haute fréquence
    ///              (10–50 Hz pendant le burst).
    ///
    ///   • Couplage axial g = 0.05 mS/cm² :
    ///              Pendant le burst (V_soma ≈ −45 mV) :
    ///                I_axial→AIS ≈ 0.05 × 20 = 1 µA/cm² → déclenche PA.
    ///              Pendant un PA (V_AIS ≈ +30 mV) :
    ///                I_retour→soma ≈ 0.05 × 75 = 3.75 µA/cm²
    ///                → déflexion ≈ 4 mV (PA très atténué vu du soma).
    ///
    /// Points d'ajustement :
    ///   - g_h      : fréquence d'oscillation du soma (↑ → + rapide)
    ///   - g_CaT    : amplitude du burst calcique (↑ → bursts + intenses)
    ///   - g_SK/Kd  : durée du burst et profondeur de l'AHP
    ///   - g_axial  : atténuation des PA vus du soma (↓ → + atténués)
    ///   - gMax_Na_AIS : excitabilité de l'AIS (↑ → PA + précoces)
    func loadPresetPD() {
        pause()
        let net = Network()

        // ── SK channel ────────────────────────────────────────────────────
        // Area soma = π·d²·1e-8 = 1.257e-3 cm², Vol = 3.14e-9 L.
        // d[Ca]/dt = I_CaS × area / (2·F·vol) → 0.207 µM/ms @ I=100 µA/cm²
        // [Ca]_ss_burst = 0.207 × 150 = 31 µM.
        // Kd=20 µM → SK fires when [Ca]=20 µM → t=155 ms → ~8 APs @ 50 Hz.
        // (Kd=15 µM → t=99 ms → ~5 APs; Kd=25 µM → t=244 ms → ~12 APs.)
        // Avec half_CaS=−30 mV le point fixe à −52 mV est éliminé (I_K=17>I_CaS=13)
        // → Kd=20 µM est sûr (pas de fixed point via SK).
        let skCh = SKChannel(gMax: 1.5, reversal: -98.0)
        skCh.halfActivation  = 0.020    // 20 µM → burst ~155 ms → ~8–10 PA, AHP profond ✓
        skCh.hillCoefficient = 4
        skCh.tauActivation   = 50.0
        skCh.restingCalcium  = 0.0001

        // ── SOMA : oscillateur T-type (pas de Na/K rapides) ───────────────
        //
        // Pourquoi pas de Na/K dans le soma ?
        //   Na/K créent un point fixe à −55 mV où hInf_T ≈ 0.001 → h_T
        //   définitivement inactivé → plus de LTS possible après le 1er burst.
        //
        // Mécanisme d'oscillation :
        //   1) Ih dépolarise lentement depuis l'AHP vers seuil T-type (~−60 mV)
        //   2) LTS T-type : V monte à ~−30 mV, Ca s'accumule (~20 µM)
        //   3) SK active → AHP → V descend à −85 mV
        //   4) À −85 mV : hInf_T = 0.73, tauH = 310 ms
        //      tauDecay_Ca = 150 ms → SK actif 220 ms → h_T récupère à 37 %
        //   5) Ensuite Ih dépolarise à nouveau → LTS de même amplitude → ✓
        //
        // Clé du bug précédent : tauDecay=30 ms → SK off en 90 ms → V remonte
        // à −65 mV → hInf_T(−65) = 0.018 → h_T ne récupère jamais → extinction.
        // Fix : tauDecay = 150 ms → SK maintient −85 mV pendant 220 ms.
        // ── SOMA : oscillateur STG-style ──────────────────────────────────
        //
        // Architecture basée sur les neurones PD du ganglion stomatogastrique
        // (Liu et al. 1998, Prinz et al. 2004).
        //
        // Canal CaS (I_CaS) — clé de l'oscillation longue :
        //   Contrairement au T-type (transitoire, h→0 en 28 ms à +25 mV), le CaS
        //   n'a PAS de gate d'inactivation. Il reste ouvert tout au long du plateau
        //   dépolarisant et fournit un flux Ca²⁺ CONTINU et GRADUEL.
        //   → [Ca²⁺] monte lentement pendant le burst entier (~200–400 ms).
        //   → SK ne s'active significativement qu'après 10–15 PA.
        //   → Avant CaS, le CaT seul s'inactivait en 28 ms → SK immédiat → 2 PA.
        //
        // Compartiment LARGE (d=200 µm, L=100 µm) :
        //   d[Ca]/dt ∝ 1/d → 10× plus lent qu'avec d=20 µm.
        //   Sans ça, même un petit courant CaS saturerait [Ca²⁺] en quelques ms.
        //
        // Canal K dans le soma :
        //   Nécessaire pour repolariser après chaque spike Ca (sinon V → +132 mV).
        //   Crée des oscillations Ca-K (~30–60 Hz) pendant le burst.
        //   AIS tire 1 PA Na pour chaque oscillation Ca-K → 10–15 PA/burst.
        //
        // SK : Kd relevé à 6 µM → seul activé au pic tardif de [Ca²⁺].
        //   À 1 µM/spike et 50 Hz : Ca_eq = 8 µM → Kd=6 µM atteint en ~10 spikes.

        // CaS channel — override sigmoïd exposé à l'optimiseur et au PD Sweep.
        // L'override permet au sweep de faire varier v½ sans modifier le code canal.
        let casCh = CaSChannel(gMax: 1.0, reversal: 132.0)
        casCh.gateInfOverrides[0] = .sigmoid(lo: 0, hi: 1, vHalf: -30.0, k: 8.5, domain: nil)

        let soma = Compartment(
            name: "soma",
            capacitance: 1.0,
            diameter: 200.0,
            length: 100.0,
            channels: [
                TTypeCalciumChannel(gMax: 1.0,  reversal: 132.0),  // trigger LTS
                casCh,                                              // plateau Ca ← clé
                PotassiumChannel(gMax: 5.0,     reversal: -98.0),  // repolarise Ca-K (IK lent)
                HChannel(gMax: 1.5,             reversal: -43.0),  // plus fort → inter-burst ~500 ms
                ATypeChannel(gMax: 0.5,         reversal: -98.0),
                skCh,
                LeakChannel(gMax: 0.03,         reversal: -60.0),
            ],
            concentrationDynamics: [
                ConcentrationDynamic(ionSymbol: "Ca",
                                     restingConc: 0.0001,
                                     tauDecay: 150.0)
            ]
        )

        // ── AIS : générateur de PA Na standard ───────────────────────────
        //
        // Déclenché par le courant axial lors de chaque oscillation Ca-K du soma.
        // gK=15 (réduit vs 36) : potentiel de repos plus proche de −65 mV
        //   → moins de résistance au courant axial → seuil Na atteint plus facilement.
        // g_axial=0.25 : avec g_total_AIS≈0.5, shift = 0.25×(V_soma+75)/0.5.
        //   V_soma=−10 mV → shift = 0.25×65/0.5 = 32.5 mV → V_AIS=−42 mV → PA ✓
        let ais = Compartment(
            name: "AIS",
            capacitance: 1.0,
            diameter: 5.0,
            length: 10.0,
            channels: [
                SodiumChannel(gMax: 80.0,      reversal:  67.0),
                PotassiumChannel(gMax: 15.0,   reversal: -98.0),
                LeakChannel(gMax: 0.1,         reversal: -65.0),
            ]
        )

        // ── Couplage axial soma ↔ AIS ──────────────────────────────────────
        // g = 0.25 mS/cm² : courant axial suffit à pousser l'AIS au seuil Na
        // pendant les oscillations Ca-K du soma (~−10 mV).
        // PA retour (V_AIS=+50 mV) → bump soma ≈ 0.25×(50−(−10))/(g_total_soma)
        // ≈ petite bosse atténuée visible sur le plateau Ca-K ✓
        let coupling = AxialCoupling(between: soma.id, and: ais.id, conductance: 0.25)

        // ── Neurone 2 compartiments ────────────────────────────────────────
        let neuron = HHNeuron(
            name: "PD soma+AIS",
            compartments: [soma, ais],
            couplings: [coupling],
            soma: soma.id
        )
        neuron.positionX = 300
        neuron.positionY = 250

        net.addNeuron(neuron)
        network     = net
        documentURL = nil
        // hInf_T(−80) = 0.44 → LTS immédiat dès le départ.
        // hInf_T(−65) = 0.018 → canal inactivé → pas d'oscillation sans ça.
        preferredRestingVoltage = -80.0
        showWelcomeScreen = false
        rebuildSimulator()

        // ── Traces par défaut ──────────────────────────────────────────────
        // Soma V(t)  : oscillation lente LTS + bosses PA (~4 mV)
        // AIS  V(t)  : PA complets (~110 mV) à fréquence intra-burst
        // [Ca]i soma : pic pendant LTS → active SK → inter-burst
        clearSignalTraces()
        addSignalTrace(.voltage(neuronID: neuron.id, compartmentID: soma.id))
        addSignalTrace(.voltage(neuronID: neuron.id, compartmentID: ais.id))
        addSignalTrace(.ionConcentration(neuronID: neuron.id,
                                         compartmentID: soma.id,
                                         ionSymbol: "Ca"))
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
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
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
        // Dismiss welcome immediately so the panel can appear even if the
        // overlay was intercepting the key-window state.
        showWelcomeScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
                  ?? NSApp.windows.first(where: \.isVisible)
        if let window {
            panel.beginSheetModal(for: window) { [weak self] result in
                guard result == .OK, let url = panel.url, let self else { return }
                Task { @MainActor in self.loadDocument(from: url) }
            }
        } else {
            panel.begin { [weak self] result in
                guard result == .OK, let url = panel.url, let self else { return }
                Task { @MainActor in self.loadDocument(from: url) }
            }
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
        // Dismiss welcome immediately (same rationale as openNetwork).
        showWelcomeScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
                  ?? NSApp.windows.first(where: \.isVisible)
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] result in
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
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
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
        doc.optimSettings = optimSettings
        // Persist the warm state so the simulation can resume on next open.
        // Only written when it is valid (same stateCount as current network).
        if let ws = savedFinalState, ws.count == network.stateCount {
            doc.warmState = ws
        }
        // Persist parameter snapshots (freeze states).
        if !snapshots.isEmpty {
            doc.snapshots = snapshots
        }
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
        preferredRestingVoltage = -65.0   // reset to standard HH default on file open
        network = doc.toNetwork()
        documentURL = url
        optimSettings = doc.optimSettings
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
        rebuildSimulator()  // clears savedFinalState — restore it below

        // Restore warm state only if it matches the freshly-loaded network's
        // state-vector size. Mismatches (file edited externally, topology
        // mismatch) fall through to a normal cold start.
        if let ws = doc.warmState, ws.count == network.stateCount {
            savedFinalState = ws
            hasWarmState    = true
        }

        // Restore parameter snapshots.
        snapshots = doc.snapshots ?? []
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

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

