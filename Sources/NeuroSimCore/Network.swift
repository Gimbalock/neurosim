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
//  Stimuli are still keyed by **neuron ID** and applied to that neuron's
//  soma compartment. Synapses still connect neuron-to-neuron — the
//  post-synaptic current lands on the post neuron's soma. Compartment-level
//  stimulus / synapse targeting can be added later without changing the
//  state-vector layout.
//

import Foundation

public final class Network: DerivativeProvider {

    // MARK: - Topology

    public private(set) var neurons: [HHNeuron] = []
    public private(set) var synapses: [Synapse] = []
    public var stimuli: [UUID: Stimulus] = [:] // keyed by neuron id

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
        neurons.removeAll { $0.id == id }
        synapses.removeAll { $0.preNeuronID == id || $0.postNeuronID == id }
        stimuli.removeValue(forKey: id)
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

    public func setStimulus(_ s: Stimulus?, on neuronID: UUID) {
        if let s = s {
            stimuli[neuronID] = s
        } else {
            stimuli.removeValue(forKey: neuronID)
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

    // MARK: - DerivativeProvider

    public func computeDerivatives(state: [Double],
                                   time: Double,
                                   into output: inout [Double]) {

        // 1. For each neuron, build the soma-injected current
        //    (stimulus + Σ post-synaptic currents arriving on the soma)
        //    and let the neuron write its compartments' derivatives,
        //    handling axial coupling internally.
        for n in neurons {
            guard let off = neuronOffset[n.id],
                  let somaIdx = compartmentOffset[n.somaCompartmentID]
            else { continue }
            let neuronSlice = state[off..<(off + n.stateCount)]
            let vPostSoma = state[somaIdx]

            var iInjSoma = stimuli[n.id]?.current(at: time) ?? 0

            // Sum incoming synaptic currents — they target the soma.
            for synIdx in incomingByPost[n.id] ?? [] {
                let syn = synapses[synIdx]
                guard let synOff = synapseOffset[syn.id],
                      let preNeuron = neurons.first(where: { $0.id == syn.preNeuronID }),
                      let preSomaIdx = compartmentOffset[preNeuron.somaCompartmentID]
                else { continue }
                let vPre = state[preSomaIdx]
                let synSlice = state[synOff..<(synOff + syn.stateCount)]
                // `currentToPost` returns I in the convention "positive =
                // outward from the post compartment". We're adding to
                // iInj (an injection), so flip the sign.
                iInjSoma -= syn.currentToPost(state: synSlice,
                                              vPre: vPre,
                                              vPost: vPostSoma)
            }

            n.writeDerivatives(localState: neuronSlice,
                               somaIInjected: iInjSoma,
                               into: &output,
                               offset: off)
        }

        // 2. Synapse internal dynamics — unchanged. V_pre and V_post are
        //    the soma voltages of the pre/post neurons.
        for syn in synapses {
            guard let synOff = synapseOffset[syn.id],
                  let preNeuron = neurons.first(where: { $0.id == syn.preNeuronID }),
                  let postNeuron = neurons.first(where: { $0.id == syn.postNeuronID }),
                  let preSomaIdx = compartmentOffset[preNeuron.somaCompartmentID],
                  let postSomaIdx = compartmentOffset[postNeuron.somaCompartmentID]
            else { continue }
            let synSlice = state[synOff..<(synOff + syn.stateCount)]
            let vPre = state[preSomaIdx]
            let vPost = state[postSomaIdx]
            syn.writeDerivatives(state: synSlice,
                                 vPre: vPre,
                                 vPost: vPost,
                                 into: &output,
                                 offset: synOff)
        }
    }
}
