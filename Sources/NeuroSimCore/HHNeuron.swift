//
//  HHNeuron.swift
//  NeuroSimCore
//
//  A single-compartment Hodgkin-Huxley point neuron whose channel set is
//  user-extensible (add new IonChannel instances at will).
//

import Foundation

public final class HHNeuron: Identifiable {
    public let id: UUID
    public var name: String
    public var capacitance: Double // µF/cm²
    public var channels: [IonChannel]

    /// Position in the network editor canvas (UI-only; ignored by the engine).
    /// Stored as raw doubles so the core stays Foundation-only and Linux-testable.
    public var positionX: Double = 0
    public var positionY: Double = 0

    public init(id: UUID = UUID(),
                name: String = "Neuron",
                capacitance: Double = 1.0,
                channels: [IonChannel]? = nil) {
        self.id = id
        self.name = name
        self.capacitance = capacitance
        self.channels = channels ?? HHNeuron.defaultChannels()
    }

    /// Default channel set: classical squid HH (Na, K, leak).
    public static func defaultChannels() -> [IonChannel] {
        [SodiumChannel(), PotassiumChannel(), LeakChannel()]
    }

    // MARK: - State layout

    /// State vector size for this neuron: 1 (V) + sum of channel gate counts.
    public var stateCount: Int {
        1 + channels.reduce(0) { $0 + $1.stateCount }
    }

    /// Initial state vector (V at resting potential, gates at steady state).
    public func initialState(restingVoltage v0: Double = -65.0) -> [Double] {
        var s: [Double] = [v0]
        s.reserveCapacity(stateCount)
        for ch in channels {
            s.append(contentsOf: ch.initialState(atVoltage: v0))
        }
        return s
    }

    /// Total ionic current (µA/cm²) at given V and gate values.
    /// `localState[0]` is V, the rest are gates in channel order.
    public func ionicCurrent(localState: ArraySlice<Double>) -> Double {
        let v = localState[localState.startIndex]
        var i = 0.0
        var idx = localState.startIndex + 1
        for ch in channels {
            let gates = localState[idx..<(idx + ch.stateCount)]
            i += ch.current(voltage: v, gates: gates)
            idx += ch.stateCount
        }
        return i
    }

    /// Writes derivatives into `output` for indices `[offset, offset + stateCount)`.
    /// `iInjected` is the externally injected current density (µA/cm²) — sum of
    /// stimulus protocol + synaptic input from upstream neurons.
    public func writeDerivatives(localState: ArraySlice<Double>,
                                 iInjected: Double,
                                 into output: inout [Double],
                                 offset: Int) {
        let v = localState[localState.startIndex]
        var iIonic = 0.0
        var src = localState.startIndex + 1
        var dst = offset + 1
        for ch in channels {
            let gates = localState[src..<(src + ch.stateCount)]
            iIonic += ch.current(voltage: v, gates: gates)
            ch.gateDerivatives(voltage: v, gates: gates, into: &output, offset: dst)
            src += ch.stateCount
            dst += ch.stateCount
        }
        // Cm dV/dt = -I_ionic + I_inj
        output[offset] = (-iIonic + iInjected) / capacitance
    }
}
