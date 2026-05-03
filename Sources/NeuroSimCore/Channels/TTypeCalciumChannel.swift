//
//  TTypeCalciumChannel.swift
//  NeuroSimCore
//
//  Low-threshold T-type Ca²⁺ channel (I_T). Two gates: m (activation, fast)
//  and h (inactivation, slower). Conductance ∝ m² · h. The defining feature
//  of T-type channels is **strong inactivation at rest** — they need to be
//  de-inactivated by hyperpolarisation before they can fire, which is what
//  generates the post-inhibitory rebound bursts seen in thalamocortical
//  relay cells.
//
//  Steady-state and time-constant equations follow Destexhe, Bal, McCormick
//  & Sejnowski (1996), J. Neurophysiol. 76 :2049-2070, the standard
//  reference parameterisation for thalamic T-current. Voltages in mV,
//  time constants in ms, currents in µA/cm².
//
//  Reversal: by default, the divalent Nernst at typical mammalian
//  [Ca²⁺]_in = 100 nM and [Ca²⁺]_out = 2 mM gives E_Ca ≈ +132 mV. This is
//  the value the constructor seeds; it can be overridden, and once the
//  concentration-dynamics layer (Step 2) lands, a Compartment will refresh
//  it on the fly via `updateReversalFromNernst`.
//
//  Note on `gMax`: the Destexhe paper uses ~1.75 mS/cm² for relay cells;
//  here we default to a more modest 0.5 mS/cm² so adding the channel to a
//  classical HH point neuron doesn't dominate the dynamics — bumps the
//  resting potential by ~1 mV without producing sustained low-threshold
//  spikes by itself.
//

import Foundation

public final class TTypeCalciumChannel: IonChannel {

    public var name: String = "Ca_T"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV — overridden by Nernst once concentrations are dynamic
    public var species: IonSpecies? { .calcium }

    public init(gMax: Double = 0.5,
                reversal: Double = IonSpecies.calcium.defaultReversal()) {
        self.gMax = gMax
        self.reversal = reversal
    }

    public var stateCount: Int { 2 } // m, h

    public func initialState(atVoltage v: Double) -> [Double] {
        [Self.mInf(v), Self.hInf(v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        return gMax * m * m * h * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        output[offset]     = (Self.mInf(v) - m) / Self.tauM(v)
        output[offset + 1] = (Self.hInf(v) - h) / Self.tauH(v)
    }

    // MARK: - Steady-state and time-constant equations
    //
    // Exposed as `internal static` so unit tests can inspect them directly
    // without instantiating a channel — keeps the tests honest about the
    // model and easy to compare to published values.

    internal static func mInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp(-(v + 57.0) / 6.2))
    }

    internal static func hInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp((v + 81.0) / 4.0))
    }

    internal static func tauM(_ v: Double) -> Double {
        0.612 + 1.0 / (exp(-(v + 132.0) / 16.7) + exp((v + 16.8) / 18.2))
    }

    internal static func tauH(_ v: Double) -> Double {
        v < -80.0
            ? exp((v + 467.0) / 66.6)
            : exp(-(v + 22.0) / 10.5) + 28.0
    }
}
