//
//  TracedSignal.swift
//  NeuroSimCore
//
//  Describes any scalar quantity that can be sampled from the simulation
//  state vector (or computed from it) at each time step.
//
//  Supported signal families:
//    • Voltage V(t) — per compartment
//    • Gate variable x(t) — per channel gate (m, h, n, m_T, h_T, …)
//    • Channel ionic current I(t) — per channel per compartment
//    • Synaptic gating s(t) — for chemical synapses
//    • Synaptic current I_syn(t) — post-synaptic current of any synapse
//    • Stimulus current I_inj(t) — injected current protocol on a compartment
//

import Foundation

public enum TracedSignal: Hashable, Identifiable, Codable {

    /// Membrane voltage of a specific compartment.
    case voltage(neuronID: UUID, compartmentID: UUID)

    /// One gating variable of a channel (gate index in the channel's own
    /// state slice, 0-based).
    case gate(neuronID: UUID, compartmentID: UUID,
              channelIndex: Int, gateIndex: Int)

    /// Instantaneous ionic current of a single channel (computed, not stored
    /// in the state vector).
    case channelCurrent(neuronID: UUID, compartmentID: UUID, channelIndex: Int)

    /// Synaptic gating variable `s` of a ChemicalSynapse.
    case synapticGating(synapseID: UUID)

    /// Post-synaptic current delivered by a synapse to its target compartment.
    case synapticCurrent(synapseID: UUID)

    /// Injected current from the stimulus protocol on a compartment.
    case stimulusCurrent(compartmentID: UUID)

        // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, neuronID, compartmentID, channelIndex, gateIndex, synapseID
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .voltage(n, comp):
            try c.encode("voltage", forKey: .kind)
            try c.encode(n, forKey: .neuronID)
            try c.encode(comp, forKey: .compartmentID)
        case let .gate(n, comp, chIdx, gIdx):
            try c.encode("gate", forKey: .kind)
            try c.encode(n, forKey: .neuronID)
            try c.encode(comp, forKey: .compartmentID)
            try c.encode(chIdx, forKey: .channelIndex)
            try c.encode(gIdx, forKey: .gateIndex)
        case let .channelCurrent(n, comp, chIdx):
            try c.encode("channelCurrent", forKey: .kind)
            try c.encode(n, forKey: .neuronID)
            try c.encode(comp, forKey: .compartmentID)
            try c.encode(chIdx, forKey: .channelIndex)
        case let .synapticGating(s):
            try c.encode("synapticGating", forKey: .kind)
            try c.encode(s, forKey: .synapseID)
        case let .synapticCurrent(s):
            try c.encode("synapticCurrent", forKey: .kind)
            try c.encode(s, forKey: .synapseID)
        case let .stimulusCurrent(comp):
            try c.encode("stimulusCurrent", forKey: .kind)
            try c.encode(comp, forKey: .compartmentID)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "voltage":
            self = .voltage(neuronID:      try c.decode(UUID.self, forKey: .neuronID),
                            compartmentID: try c.decode(UUID.self, forKey: .compartmentID))
        case "gate":
            self = .gate(neuronID:      try c.decode(UUID.self, forKey: .neuronID),
                         compartmentID: try c.decode(UUID.self, forKey: .compartmentID),
                         channelIndex:  try c.decode(Int.self,  forKey: .channelIndex),
                         gateIndex:     try c.decode(Int.self,  forKey: .gateIndex))
        case "channelCurrent":
            self = .channelCurrent(neuronID:      try c.decode(UUID.self, forKey: .neuronID),
                                   compartmentID: try c.decode(UUID.self, forKey: .compartmentID),
                                   channelIndex:  try c.decode(Int.self,  forKey: .channelIndex))
        case "synapticGating":
            self = .synapticGating(synapseID: try c.decode(UUID.self, forKey: .synapseID))
        case "synapticCurrent":
            self = .synapticCurrent(synapseID: try c.decode(UUID.self, forKey: .synapseID))
        case "stimulusCurrent":
            self = .stimulusCurrent(compartmentID: try c.decode(UUID.self, forKey: .compartmentID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "Unknown TracedSignal kind: \(kind)")
        }
    }

    // MARK: - Identifiable

    public var id: String {
        switch self {
        case let .voltage(n, c):             return "v-\(n)-\(c)"
        case let .gate(n, c, ch, g):         return "gate-\(n)-\(c)-\(ch)-\(g)"
        case let .channelCurrent(n, c, ch):  return "ich-\(n)-\(c)-\(ch)"
        case let .synapticGating(s):         return "sg-\(s)"
        case let .synapticCurrent(s):        return "isyn-\(s)"
        case let .stimulusCurrent(c):        return "istim-\(c)"
        }
    }

    // MARK: - Display metadata

    /// Human-readable label built from the network topology.
    public func displayLabel(in network: Network) -> String {
        switch self {

        case let .voltage(nID, cID):
            let n = network.neurons.first { $0.id == nID }
            let c = n?.compartments.first { $0.id == cID }
            let nName = n?.name ?? "?"
            let cName = c?.name ?? "?"
            return "\(nName) · \(cName)  V(t)"

        case let .gate(nID, cID, chIdx, gIdx):
            let n = network.neurons.first { $0.id == nID }
            let c = n?.compartments.first { $0.id == cID }
            let ch = c?.channels[safe: chIdx]
            let nName = n?.name ?? "?"
            let cName = c?.name ?? "?"
            let chName = ch?.name ?? "ch\(chIdx)"
            let gName: String
            if let gated = ch as? HHGated {
                gName = gated.gateNames[safe: gIdx] ?? "gate\(gIdx)"
            } else {
                gName = "gate\(gIdx)"
            }
            return "\(nName) · \(cName) · \(chName)  \(gName)(t)"

        case let .channelCurrent(nID, cID, chIdx):
            let n = network.neurons.first { $0.id == nID }
            let c = n?.compartments.first { $0.id == cID }
            let ch = c?.channels[safe: chIdx]
            let nName = n?.name ?? "?"
            let cName = c?.name ?? "?"
            let chName = ch?.name ?? "ch\(chIdx)"
            return "\(nName) · \(cName) · \(chName)  I(t)"

        case let .synapticGating(sID):
            let s = network.synapses.first { $0.id == sID }
            let preName = network.neurons.first { $0.id == s?.preNeuronID }?.name ?? "?"
            let postName = network.neurons.first { $0.id == s?.postNeuronID }?.name ?? "?"
            return "\(preName)→\(postName)  s(t)"

        case let .synapticCurrent(sID):
            let s = network.synapses.first { $0.id == sID }
            let preName = network.neurons.first { $0.id == s?.preNeuronID }?.name ?? "?"
            let postName = network.neurons.first { $0.id == s?.postNeuronID }?.name ?? "?"
            let arrow = s is GapJunction ? "↔" : "→"
            return "\(preName)\(arrow)\(postName)  I_syn(t)"

        case let .stimulusCurrent(cID):
            let n = network.neurons.first { n in
                n.compartments.contains { $0.id == cID }
            }
            let c = network.compartment(id: cID)
            let nName = n?.name ?? "?"
            let cName = c?.name ?? "?"
            return "\(nName) · \(cName)  I_inj(t)"
        }
    }

    /// Physical unit string for the y-axis label.
    public var unit: String {
        switch self {
        case .voltage:                   return "mV"
        case .gate:                      return ""     // dimensionless [0–1]
        case .channelCurrent:            return "µA/cm²"
        case .synapticGating:            return ""
        case .synapticCurrent:           return "µA/cm²"
        case .stimulusCurrent:           return "µA/cm²"
        }
    }

    /// Suggested fixed y-axis domain, or nil to auto-scale.
    public var suggestedYDomain: ClosedRange<Double>? {
        switch self {
        case .voltage:         return -90...60
        case .gate:            return 0...1
        case .synapticGating:  return 0...1
        default:               return nil    // auto-scale currents
        }
    }

    // MARK: - Value extraction

    /// Sample the signal from the current simulator state. Returns nil when
    /// the required element no longer exists in the network (e.g. after a
    /// topology change before the trace is removed).
    public func value(state: [Double],
                      network: Network,
                      time: Double) -> Double? {
        switch self {

        case let .voltage(_, cID):
            guard let idx = network.voltageIndex(ofCompartment: cID),
                  state.indices.contains(idx)
            else { return nil }
            return state[idx]

        case let .gate(_, cID, chIdx, gIdx):
            guard let idx = network.gateStateIndex(channelIndex: chIdx,
                                                   gateIndex: gIdx,
                                                   inCompartment: cID),
                  state.indices.contains(idx)
            else { return nil }
            return state[idx]

        case let .channelCurrent(_, cID, chIdx):
            guard let comp = network.compartment(id: cID),
                  comp.channels.indices.contains(chIdx),
                  let compStart = network.voltageIndex(ofCompartment: cID),
                  state.indices.contains(compStart)
            else { return nil }
            let v = state[compStart]
            let ch = comp.channels[chIdx]
            var gateStart = compStart + 1
            for i in 0..<chIdx { gateStart += comp.channels[i].stateCount }
            let gateEnd = gateStart + ch.stateCount
            guard state.indices.contains(gateStart) || ch.stateCount == 0 else { return nil }
            let gates = state[gateStart..<gateEnd]
            return ch.current(voltage: v, gates: gates)

        case let .synapticGating(sID):
            guard let off = network.stateOffset(ofSynapse: sID),
                  state.indices.contains(off)
            else { return nil }
            return state[off]

        case let .synapticCurrent(sID):
            guard let info = network.synapseCurrentInfo(id: sID),
                  state.indices.contains(info.vPreIndex),
                  state.indices.contains(info.vPostIndex)
            else { return nil }
            let vPre  = state[info.vPreIndex]
            let vPost = state[info.vPostIndex]
            let off   = info.stateOffset
            let count = info.synapse.stateCount
            let synState = count > 0 ? state[off..<(off + count)] : state[0..<0]
            return info.synapse.currentToPost(state: synState,
                                              vPre: vPre, vPost: vPost)

        case let .stimulusCurrent(cID):
            return network.stimuli[cID]?.current(at: time) ?? 0
        }
    }
}

// MARK: - Safe subscript helpers

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
