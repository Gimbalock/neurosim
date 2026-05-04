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

@MainActor
final class SimulationViewModel: ObservableObject {

    // MARK: - Topology (published so the canvas redraws on changes)

    @Published var network: Network
    @Published var selection: Selection = .none

    enum Selection: Equatable {
        case none
        case neuron(UUID)
        case synapse(UUID)
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

    // MARK: - Run state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var simulationTime: Double = 0
    @Published var dt: Double = 0.01
    @Published var realtimeFactor: Double = 1.0  // 1.0 = real-time; >1 = accelerated

    private var simulator: Simulator
    private var simTimer: Timer?
    /// Hard memory cap on a single neuron's trace buffer. Time-based trimming
    /// (`cutoff = simulator.time − plotWindow`) is the primary mechanism;
    /// this is just a safety net so a runaway window can't blow up memory.
    /// Sized to comfortably hold a 5 s window at current downsample stride.
    private let plotMaxSamples = 100_000
    private let plotDownsampleStride: Int = 5  // store one in N integration steps

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
        case .neuron(let id):  network.removeNeuron(id: id)
        case .synapse(let id): network.removeSynapse(id: id)
        case .none: return
        }
        selection = .none
        rebuildSimulator()
    }

    func addSynapse(from preID: UUID, to postID: UUID) {
        guard preID != postID else { return }
        // Avoid duplicates of the same direction.
        if network.synapses.contains(where: {
            $0.preNeuronID == preID && $0.postNeuronID == postID
        }) { return }
        network.addSynapse(ChemicalSynapse(from: preID, to: postID,
                                           gMax: 0.3, reversal: 0.0,
                                           tauDecay: 6.0))
        rebuildSimulator()
    }

    func setNeuronPosition(_ id: UUID, x: Double, y: Double) {
        guard let n = network.neurons.first(where: { $0.id == id }) else { return }
        n.positionX = x; n.positionY = y
        objectWillChange.send()
    }

    // MARK: - Compartment mutations

    /// Append a new compartment to a neuron and auto-couple it to the
    /// current soma so it isn't electrically floating. Returns the new
    /// compartment so callers can immediately select it in the UI.
    @discardableResult
    func addCompartment(to neuronID: UUID,
                        name: String? = nil,
                        channels: [IonChannel] = [LeakChannel()]) -> Compartment? {
        guard let n = network.neurons.first(where: { $0.id == neuronID }) else { return nil }
        let label = name ?? "dend\(n.compartments.count)"
        let comp = Compartment(name: label, channels: channels)
        n.compartments.append(comp)
        n.axialCouplings.append(
            AxialCoupling(between: n.somaCompartmentID, and: comp.id, conductance: 0.5)
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

    /// Rebuild the simulator after any structural mutation that changes the
    /// state-vector layout.
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
    }

    // MARK: - Run / pause / reset

    func toggleRunning() { isRunning ? pause() : play() }

    func play() {
        guard !isRunning else { return }
        // One-shot semantics: every Run starts a fresh sweep at t = 0 and
        // auto-stops once the plotted window is full. Inline the reset here
        // (rather than calling reset()) to avoid flipping isRunning twice.
        simulator.reset()
        simulationTime = 0
        seedTraces()

        isRunning = true
        simulator.dt = dt
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

        for i in 0..<nSteps {
            simulator.step()
            if i % plotDownsampleStride == 0 {
                for n in network.neurons {
                    if let idx = network.voltageIndex(of: n.id) {
                        newSamples.append((n.id, simulator.time, simulator.state[idx]))
                    }
                }
            }
        }

        simulationTime = simulator.time
        for (id, t, v) in newSamples {
            var arr = traces[id] ?? []
            arr.append(PlotPoint(t: t, v: v))
            let cutoff = simulator.time - plotWindow
            while let first = arr.first, first.t < cutoff { arr.removeFirst() }
            if arr.count > plotMaxSamples {
                arr.removeFirst(arr.count - plotMaxSamples)
            }
            traces[id] = arr
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

    // MARK: - Export

    func exportTracesCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "neurosim_traces.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let neuronIDs = network.neurons.map(\.id)
        let names = network.neurons.map(\.name)
        // Traces share the same time grid (sampled together).
        let baseline = neuronIDs.first.flatMap { traces[$0] } ?? []
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
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
