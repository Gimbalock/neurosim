//
//  Network.swift
//  NeuroSimCore
//
//  Holds the topology (neurons + synapses + per-neuron stimuli) and exposes
//  the combined ODE system to the integrator.
//
//  State-vector layout, post-Step 1b:
//
//      [ neuron_0 state | neuron_1 state | … | synapse_0 state | … ]
//
//  where each neuron's state is itself the concatenation of its compartments'
//  states, in declaration order. `rebuildLayout()` recomputes both the
//  per-neuron and per-compartment offsets after every structural mutation.
//
//  Stimuli are keyed by **compartment ID** (Step 5+). The convenience
//  `setStimulus(_:on:)` API still takes a neuron ID and routes the stimulus
//  to that neuron's soma — backward-compatible for callers that don't care
//  about dendritic targeting. To stim a specific compartment, use
//  `setStimulus(_:onCompartment:)`.
//
//  Synapses target a specific compartment via `Synapse.postCompartmentID`;
//  when that's `nil` the post neuron's soma is used as the landing point.
//

import Foundation

public final class Network: DerivativeProvider {

    // MARK: - Topology

    public private(set) var neurons: [HHNeuron] = []
    public private(set) var synapses: [Synapse] = []
    /// Stimuli keyed by **compartment ID**. Use `setStimulus(_:on:)` for the
    /// soma-by-default API or `setStimulus(_:onCompartment:)` for explicit
    /// dendritic targeting.
    public var stimuli: [UUID: Stimulus] = [:]

    /// Ornstein-Uhlenbeck synaptic noise sources, keyed by compartment UUID.
    public var synapticNoises: [UUID: SynapticNoiseSource] = [:]

    /// Current simulator timestep — set by Simulator.step() before each integration.
    /// Used by noise sources to advance their OU state correctly.
    internal var simulationDt: Double = 0.05

    // MARK: - State layout (rebuilt after every structural mutation)

    public private(set) var stateCount: Int = 0
    private var neuronOffset: [UUID: Int] = [:]         // start of neuron's slice
    private var compartmentOffset: [UUID: Int] = [:]    // V index of each compartment
    private var synapseOffset: [UUID: Int] = [:]
    private var outgoingByPre: [UUID: [Int]] = [:]      // pre id → indices into `synapses`
    private var incomingByPost: [UUID: [Int]] = [:]     // post id → indices into `synapses`

    public init() {}

    // MARK: - Mutators

    @discardableResult
    public func addNeuron(_ n: HHNeuron) -> HHNeuron {
        neurons.append(n)
        rebuildLayout()
        return n
    }

    public func removeNeuron(id: UUID) {
        // Capture this neuron's compartment IDs before removal so we can
        // also drop any stimuli targeting them (stimuli are keyed by
        // compartment, not neuron).
        let compartmentIDs: Set<UUID> = neurons
            .first(where: { $0.id == id })
            .map { Set($0.compartments.map(\.id)) } ?? []

        neurons.removeAll { $0.id == id }
        synapses.removeAll { $0.preNeuronID == id || $0.postNeuronID == id }
        for cid in compartmentIDs { stimuli.removeValue(forKey: cid) }
        for cid in compartmentIDs { synapticNoises.removeValue(forKey: cid) }
        rebuildLayout()
    }

    @discardableResult
    public func addSynapse(_ s: Synapse) -> Synapse {
        synapses.append(s)
        rebuildLayout()
        return s
    }

    public func removeSynapse(id: UUID) {
        synapses.removeAll { $0.id == id }
        rebuildLayout()
    }

    /// Apply a stimulus to a neuron's **soma** (back-compat shim). Use
    /// `setStimulus(_:onCompartment:)` to target a specific dendrite/axon
    /// compartment instead.
    public func setStimulus(_ s: Stimulus?, on neuronID: UUID) {
        guard let n = neurons.first(where: { $0.id == neuronID }) else { return }
        setStimulus(s, onCompartment: n.somaCompartmentID)
    }

    /// Apply a stimulus to any compartment (soma, dendrite, axon hillock…).
    /// Pass `nil` to remove a previously installed stimulus on that compartment.
    public func setStimulus(_ s: Stimulus?, onCompartment compartmentID: UUID) {
        if let s = s {
            stimuli[compartmentID] = s
        } else {
            stimuli.removeValue(forKey: compartmentID)
        }
    }

    /// Attach (or remove when `nil`) an OU synaptic-noise source to a compartment.
    public func setSynapticNoise(_ params: SynapticNoiseParams?,
                                  onCompartment id: UUID) {
        if let p = params {
            synapticNoises[id] = SynapticNoiseSource(params: p)
        } else {
            synapticNoises.removeValue(forKey: id)
        }
    }

    /// Call this when you've mutated a neuron's compartments or couplings
    /// out-of-band (i.e. without going through the Network's add/remove
    /// methods). It re-derives the state-vector offsets so the integrator
    /// sees the new layout.
    public func notifyStructuralChange() {
        rebuildLayout()
    }

    // MARK: - Layout

    private func rebuildLayout() {
        neuronOffset.removeAll(keepingCapacity: true)
        compartmentOffset.removeAll(keepingCapacity: true)
        synapseOffset.removeAll(keepingCapacity: true)
        outgoingByPre.removeAll(keepingCapacity: true)
        incomingByPost.removeAll(keepingCapacity: true)

        var off = 0
        for n in neurons {
            neuronOffset[n.id] = off
            // Walk the neuron's compartments to record where each
            // compartment's V lives in the global state vector.
            var local = off
            for comp in n.compartments {
                compartmentOffset[comp.id] = local
                local += comp.stateCount
            }
            off += n.stateCount
        }
        for s in synapses {
            synapseOffset[s.id] = off
            off += s.stateCount
        }
        stateCount = off

        for (i, s) in synapses.enumerated() {
            outgoingByPre[s.preNeuronID, default: []].append(i)
            incomingByPost[s.postNeuronID, default: []].append(i)
        }
    }

    /// Build the full initial state vector (resting V on every compartment,
    /// steady-state gates, zero synaptic activation).
    public func initialState(restingVoltage v0: Double = -65.0) -> [Double] {
        var s = [Double](repeating: 0, count: stateCount)
        for n in neurons {
            let init_ = n.initialState(restingVoltage: v0)
            let o = neuronOffset[n.id]!
            for i in 0..<init_.count { s[o + i] = init_[i] }
        }
        for syn in synapses {
            let init_ = syn.initialState()
            let o = synapseOffset[syn.id]!
            for i in 0..<init_.count { s[o + i] = init_[i] }
        }
        return s
    }

    // MARK: - Index queries (used by the simulator and the UI plot view)

    /// V index of a neuron's **soma** compartment in the global state vector.
    /// Backward-compatible with the pre-Step-1b API: existing callers asking
    /// "where is this neuron's V?" still get a meaningful answer.
    public func voltageIndex(of neuronID: UUID) -> Int? {
        guard let n = neurons.first(where: { $0.id == neuronID }) else { return nil }
        return compartmentOffset[n.somaCompartmentID]
    }

    /// V index of any specific compartment (soma, dendrite, axon hillock…)
    /// in the global state vector.
    public func voltageIndex(ofCompartment compartmentID: UUID) -> Int? {
        compartmentOffset[compartmentID]
    }

    public func stateOffset(ofSynapse id: UUID) -> Int? {
        synapseOffset[id]
    }

    public func outgoingSynapses(of neuronID: UUID) -> [Synapse] {
        (outgoingByPre[neuronID] ?? []).map { synapses[$0] }
    }

    // MARK: - State-vector introspection (for the results window)

    /// The compartment with the given ID, searched across all neurons.
    public func compartment(id compartmentID: UUID) -> Compartment? {
        for n in neurons {
            if let c = n.compartments.first(where: { $0.id == compartmentID }) { return c }
        }
        return nil
    }

    /// Global state-vector index of the intracellular concentration of `ionSymbol`
    /// in compartment `compartmentID`. Returns nil if not tracked.
    public func concentrationStateIndex(compartmentID: UUID, ionSymbol: String) -> Int? {
        guard let compStart = compartmentOffset[compartmentID],
              let comp = compartment(id: compartmentID)
        else { return nil }
        let totalGates = comp.channels.reduce(0) { $0 + $1.stateCount }
        guard let i = comp.concentrationDynamics.firstIndex(where: { $0.ionSymbol == ionSymbol })
        else { return nil }
        return compStart + 1 + totalGates + i
    }

    /// Global state-vector index of gate `gateIndex` of channel `channelIndex`
    /// within compartment `compartmentID`. Returns nil if out of range.
    public func gateStateIndex(channelIndex: Int,
                               gateIndex: Int,
                               inCompartment compartmentID: UUID) -> Int? {
        guard let compStart = compartmentOffset[compartmentID],
              let comp = compartment(id: compartmentID),
              comp.channels.indices.contains(channelIndex)
        else { return nil }
        let ch = comp.channels[channelIndex]
        guard gateIndex < ch.stateCount else { return nil }
        var off = compStart + 1
        for i in 0..<channelIndex { off += comp.channels[i].stateCount }
        return off + gateIndex
    }

    /// Info bundle needed to compute a synapse's post-synaptic current from
    /// the global state vector. Returns nil for unknown synapse IDs or when
    /// pre/post neurons can't be resolved.
    public struct SynapseCurrentInfo {
        public let synapse: Synapse
        public let stateOffset: Int   // first slot of this synapse in state[]
        public let vPreIndex: Int     // index of V_pre (soma of pre-neuron)
        public let vPostIndex: Int    // index of V_post (target compartment)
    }

    public func synapseCurrentInfo(id synapseID: UUID) -> SynapseCurrentInfo? {
        guard let syn = synapses.first(where: { $0.id == synapseID }),
              let stateOff = synapseOffset[syn.id],
              let preN = neurons.first(where: { $0.id == syn.preNeuronID }),
              let vPreIdx = compartmentOffset[preN.somaCompartmentID]
        else { return nil }
        let targetCompID = syn.postCompartmentID
            ?? neurons.first(where: { $0.id == syn.postNeuronID })?.somaCompartmentID
        guard let tID = targetCompID,
              let vPostIdx = compartmentOffset[tID]
        else { return nil }
        return SynapseCurrentInfo(synapse: syn, stateOffset: stateOff,
                                  vPreIndex: vPreIdx, vPostIndex: vPostIdx)
    }

    // MARK: - DerivativeProvider

    public func computeDerivatives(state: [Double],
                                   time: Double,
                                   into output: inout [Double]) {

        // 1. Per-neuron pass: build a per-compartment injected-current
        //    dictionary (stimuli + synaptic currents) and let the neuron
        //    write all its compartments' derivatives, handling axial
        //    coupling internally.
        for n in neurons {
            guard let off = neuronOffset[n.id] else { continue }
            let neuronSlice = state[off..<(off + n.stateCount)]

            // 1a. Stimuli on any of this neuron's compartments.
            var iInj: [UUID: Double] = [:]
            for comp in n.compartments {
                if let stim = stimuli[comp.id] {
                    iInj[comp.id, default: 0] += stim.current(at: time)
                }
                // Synaptic noise: voltage-dependent OU conductance injection.
                if let noise = synapticNoises[comp.id],
                   let vIdx  = compartmentOffset[comp.id] {
                    let v = state[vIdx]
                    // Isyn is outward-positive; subtract to get inward injection.
                    iInj[comp.id, default: 0] -= noise.current(at: time,
                                                                voltage: v,
                                                                dt: simulationDt)
                }
            }

            // 1b. Incoming synaptic currents — each lands on the synapse's
            //     postCompartmentID, falling back to the post neuron's soma.
            for synIdx in incomingByPost[n.id] ?? [] {
                let syn = synapses[synIdx]
                guard let synOff = synapseOffset[syn.id],
                      let preNeuron = neurons.first(where: { $0.id == syn.preNeuronID }),
                      let preSomaIdx = compartmentOffset[preNeuron.somaCompartmentID]
                else { continue }
                let targetCompID = syn.postCompartmentID ?? n.somaCompartmentID
                guard let postIdx = compartmentOffset[targetCompID] else { continue }

                let vPre = state[preSomaIdx]
                let vPostTarget = state[postIdx]
                let synSlice = state[synOff..<(synOff + syn.stateCount)]
                // `currentToPost` returns I in the convention "positive =
                // outward from the post compartment". We're adding to an
                // injection, so flip the sign.
                iInj[targetCompID, default: 0] -= syn.currentToPost(
                    state: synSlice, vPre: vPre, vPost: vPostTarget
                )
            }

            n.writeDerivatives(localState: neuronSlice,
                               injectedByCompartment: iInj,
                               into: &output,
                               offset: off)
        }

        // 2. Synapse internal dynamics. V_pre is the pre soma; V_post is
        //    the actual target compartment voltage.
        for syn in synapses {
            guard let synOff = synapseOffset[syn.id],
                  let preNeuron = neurons.first(where: { $0.id == syn.preNeuronID }),
                  let postNeuron = neurons.first(where: { $0.id == syn.postNeuronID }),
                  let preSomaIdx = compartmentOffset[preNeuron.somaCompartmentID]
            else { continue }
            let targetCompID = syn.postCompartmentID ?? postNeuron.somaCompartmentID
            guard let postIdx = compartmentOffset[targetCompID] else { continue }
            let synSlice = state[synOff..<(synOff + syn.stateCount)]
            let vPre = state[preSomaIdx]
            let vPost = state[postIdx]
            syn.writeDerivatives(state: synSlice,
                                 vPre: vPre,
                                 vPost: vPost,
                                 into: &output,
                                 offset: synOff)
        }
    }
}
