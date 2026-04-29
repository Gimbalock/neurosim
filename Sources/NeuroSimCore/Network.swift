//
//  Network.swift
//  NeuroSimCore
//
//  Holds the topology (neurons + synapses + per-neuron stimuli) and exposes
//  the combined ODE system to the integrator. The state-vector layout is:
//
//      [ neuron_0 state | neuron_1 state | ... | synapse_0 state | ... ]
//
//  Each call to `rebuildLayout` recomputes offsets after structural edits.
//

import Foundation

public final class Network: DerivativeProvider {
    // MARK: - Topology

    public private(set) var neurons: [HHNeuron] = []
    public private(set) var synapses: [Synapse] = []
    public var stimuli: [UUID: Stimulus] = [:] // keyed by neuron id

    // MARK: - State layout (rebuilt after every structural mutation)

    public private(set) var stateCount: Int = 0
    private var neuronOffset: [UUID: Int] = [:]
    private var synapseOffset: [UUID: Int] = [:]
    private var outgoingByPre: [UUID: [Int]] = [:]   // pre id → indices into `synapses`
    private var incomingByPost: [UUID: [Int]] = [:]  // post id → indices into `synapses`

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

    // MARK: - Layout

    private func rebuildLayout() {
        neuronOffset.removeAll(keepingCapacity: true)
        synapseOffset.removeAll(keepingCapacity: true)
        outgoingByPre.removeAll(keepingCapacity: true)
        incomingByPost.removeAll(keepingCapacity: true)

        var off = 0
        for n in neurons {
            neuronOffset[n.id] = off
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

    /// Build the full initial state vector (resting V on neurons, steady-state
    /// gates, zero synaptic activation).
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

    // MARK: - Index queries (used by the simulator and by the UI plot view)

    public func voltageIndex(of neuronID: UUID) -> Int? {
        neuronOffset[neuronID]
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
        // 1. For each neuron, compute injected current = stimulus + Σ synapse currents
        //    where this neuron is post-synaptic.
        for n in neurons {
            guard let off = neuronOffset[n.id] else { continue }
            let neuronSlice = state[off..<(off + n.stateCount)]
            let vPost = state[off]

            var iInj = stimuli[n.id]?.current(at: time) ?? 0

            // Sum incoming synaptic currents.
            for synIdx in incomingByPost[n.id] ?? [] {
                let syn = synapses[synIdx]
                guard let synOff = synapseOffset[syn.id],
                      let preOff = neuronOffset[syn.preNeuronID] else { continue }
                let vPre = state[preOff]
                let synSlice = state[synOff..<(synOff + syn.stateCount)]
                // currentToPost returns I in the convention "positive = outward
                // from the post compartment", i.e. it goes into Cm dV/dt with
                // a minus sign.  We add to iInj as if it were an external
                // injection, so flip the sign.
                iInj -= syn.currentToPost(state: synSlice, vPre: vPre, vPost: vPost)
            }

            n.writeDerivatives(localState: neuronSlice,
                               iInjected: iInj,
                               into: &output,
                               offset: off)
        }

        // 2. Synapse internal dynamics.
        for syn in synapses {
            guard let synOff = synapseOffset[syn.id],
                  let preOff = neuronOffset[syn.preNeuronID],
                  let postOff = neuronOffset[syn.postNeuronID] else { continue }
            let synSlice = state[synOff..<(synOff + syn.stateCount)]
            let vPre = state[preOff]
            let vPost = state[postOff]
            syn.writeDerivatives(state: synSlice,
                                 vPre: vPre,
                                 vPost: vPost,
                                 into: &output,
                                 offset: synOff)
        }
    }
}
