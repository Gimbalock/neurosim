//
//  Compartment.swift
//  NeuroSimCore
//
//  A single electrical compartment of a neuron — one membrane patch with its
//  own potential V, capacitance, and set of voltage-gated channels.
//
//  Conceptually, this is what `HHNeuron` was carrying *internally* before
//  Step 1b. Pulling it out lets us assemble multi-compartment neurons:
//  soma + dendritic tree + axon hillock, etc., each compartment plugging
//  into the same RK4 machinery via the shared state vector.
//
//  State layout for one compartment:
//
//      [ V, gate_0_0, gate_0_1, …, gate_1_0, gate_1_1, … ]
//        ↑    └─ channel 0 gates ─┘  └─ channel 1 gates ─┘
//        membrane potential (mV)
//
//  Channels are ordered as in `channels`. Each channel knows how many gating
//  variables it owns via `IonChannel.stateCount` — Compartment just
//  concatenates them. Conventions of the underlying numerics (units, signs)
//  are inherited from HH: V in mV, time in ms, conductance in mS/cm²,
//  current density in µA/cm², capacitance in µF/cm².
//

import Foundation

public final class Compartment: Identifiable {

    public let id: UUID
    public var name: String

    /// Specific membrane capacitance (µF/cm²). 1.0 is the canonical squid
    /// HH default and a reasonable starting point for mammalian neurons too.
    public var capacitance: Double

    /// Voltage-gated channels populating this compartment's membrane.
    /// Order is significant only insofar as it fixes the layout of gates in
    /// the state vector — the physics is symmetric in channel ordering.
    public var channels: [IonChannel]

    public init(id: UUID = UUID(),
                name: String = "compartment",
                capacitance: Double = 1.0,
                channels: [IonChannel] = []) {
        self.id = id
        self.name = name
        self.capacitance = capacitance
        self.channels = channels
    }

    // MARK: - State vector

    /// Total state slots this compartment owns: 1 (V) + Σ channel gate counts.
    public var stateCount: Int {
        1 + channels.reduce(0) { $0 + $1.stateCount }
    }

    /// Initial state at a given resting potential — V at v0, every gate at
    /// its steady-state value α/(α+β) for that V.
    public func initialState(restingVoltage v0: Double = -65.0) -> [Double] {
        var s: [Double] = [v0]
        s.reserveCapacity(stateCount)
        for ch in channels {
            s.append(contentsOf: ch.initialState(atVoltage: v0))
        }
        return s
    }

    /// Total ionic current density (µA/cm²) crossing this compartment's
    /// membrane at the given local state.
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

    /// Writes derivatives for V and every gate this compartment owns, into
    /// `output` starting at `offset`.
    ///
    /// `iInjected` is the *external* current density (µA/cm²) flowing into
    /// the compartment — sum of any stimulus protocol applied here, of
    /// post-synaptic currents (when this compartment is the post-synaptic
    /// target), and of axial currents from coupled neighbouring
    /// compartments. The compartment itself doesn't know about these
    /// sources; it just trusts the caller to have summed them.
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
        // Cm · dV/dt = -I_ionic + I_inj
        output[offset] = (-iIonic + iInjected) / capacitance
    }
}
