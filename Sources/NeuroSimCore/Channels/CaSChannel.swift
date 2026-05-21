//
//  CaSChannel.swift
//  NeuroSimCore
//
//  Slow Ca²⁺ channel, I_CaS — stomatogastric ganglion (STG) style.
//
//  Unlike the T-type channel (fast, transient), CaS has NO inactivation gate:
//  it activates at intermediate voltages and stays open throughout the burst
//  plateau, providing a continuous Ca²⁺ influx that gradually builds [Ca²⁺]_i
//  until SK (or BK) is activated and terminates the burst.
//
//  This is the biophysically essential channel for long bursts (10–20 APs) in
//  STG PD/PY neurons (Liu et al. 1998, Prinz et al. 2004).
//
//  One gate: m  (activation, no inactivation — persistent current).
//
//  Kinetics (Liu et al. 1998 / Turrigiano et al. 1995, STG):
//    m∞(V)  = 1 / (1 + exp(-(V + 22) / 8.5))   [half-act at −22 mV]
//    τm(V)  = 10 / (exp((V + 45)/10) + exp(-(V + 45)/35)) + 2.5  ms
//             (clamped to [2.0, 400.0] ms)
//
//  The slow τm (peak ~50 ms near threshold) means CaS does not track
//  individual fast Na⁺ APs — it follows the slow burst envelope only.
//
//  The channel declares species = .calcium so ConcentrationDynamic
//  automatically accumulates [Ca²⁺]_i from its current.
//
//  Default parameters:
//    gMax    =  2.0 mS/cm²  (tune to set burst duration)
//    reversal = +132 mV     (Ca²⁺ reversal, same as CaT/CaL)
//

import Foundation

public final class CaSChannel: IonChannel, HHGated {

    public var name: String = "Ca_S"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV

    /// Ca²⁺ species → contribution added to [Ca²⁺]_i by ConcentrationDynamic.
    public var species: IonSpecies? { .calcium }

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 2.0,
                reversal: Double = 132.0) {
        self.gMax    = gMax
        self.reversal = reversal
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }   // m gate only

    public func initialState(atVoltage v: Double) -> [Double] {
        [resolvedGateInf(0, voltage: v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex]
        return gMax * m * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let m = gates[gates.startIndex]
        output[offset] = (resolvedGateInf(0, voltage: v) - m)
                            / resolvedGateTau(0, voltage: v)
    }

    // MARK: Kinetics

    /// Steady-state activation. Half-activation at −30 mV, slope 8.5 mV.
    ///
    /// Compromise between the original −22 mV (troughs stuck at −40 mV) and
    /// −35 mV (window current too large at −52 mV → sub-threshold stable fixed point).
    ///
    /// At −30 mV: CaS window current at rest (−65 mV) = 3.2 µA/cm² < I_K = 7.4 → no fixed point.
    /// Ca-K oscillation trough settles at −70 mV where Ih (30% active) drives the upswing.
    ///
    ///   At −65 mV: m∞ = 0.016  (tiny — essentially silent between bursts)
    ///   At −52 mV: m∞ = 0.070  (I_CaS < I_K — no sub-threshold fixed point)
    ///   At −30 mV: m∞ = 0.50   (half-activation)
    ///   At  −5 mV: m∞ = 0.950  (plateau — Ca²⁺ influx fully sustained)
    internal static func mInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp(-(v + 30.0) / 8.5))
    }

    /// Time constant — symmetric bell-shaped, peak ~7.5 ms at −45 mV.
    ///
    /// Why symmetric kinetics here:
    ///   The Ca-K oscillation requires I_CaS ≥ I_K at the plateau voltage (−20 to 0 mV)
    ///   to sustain repetitive spiking. Making τm_act slow (>10 ms) means m only reaches
    ///   0.3–0.4 during a 20 ms LTS → I_CaS < I_K → oscillation collapses to a single
    ///   transient. The symmetric formula keeps m near m∞ at all voltages, preserving
    ///   the Ca-K limit cycle while τm (~7 ms) is already faster than K(n⁴) dynamics.
    ///
    /// Inter-spike trough depth (−40 mV) is set by the m∞/n∞ crossover — see notes
    /// in loadPresetPD() for further discussion.
    internal static func tauM(_ v: Double) -> Double {
        let raw = 10.0 / (exp((v + 45.0) / 10.0) + exp(-(v + 45.0) / 35.0)) + 2.5
        return max(2.0, min(400.0, raw))
    }

    // MARK: HHGated

    public var gateNames: [String] { ["m"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.mInf(v) : 0
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.tauM(v) : 1
    }
}
