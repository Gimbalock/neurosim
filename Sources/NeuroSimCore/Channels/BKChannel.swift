//
//  BKChannel.swift
//  NeuroSimCore
//
//  Large-conductance Ca²⁺- and voltage-activated K⁺ channel (BK, MaxiK, K_Ca1.1).
//
//  BK channels are dual sensors: activation depends on both membrane voltage V
//  and intracellular [Ca²⁺]. The gating is captured here with the simplified
//  Horrigan-Aldrich-style steady-state shift:
//
//      V_half([Ca]) = V0 − S · ln([Ca] / Ca_ref)
//      w∞(V, [Ca]) = 1 / (1 + exp(-(V − V_half) / k))
//      τ_w(V)       = τ_min + τ_max · exp(-(V − V0_τ)² / (2·σ_τ²))
//
//  Default parameters:
//    V0      = −20 mV   (V_half at Ca_ref)
//    S       =  20 mV   (shift per decade of [Ca]): more Ca → easier opening
//    Ca_ref  = 1e-3 mM  (reference [Ca] = 1 µM, mid-range for BK)
//    k       =  15 mV   (slope factor)
//    τ_min   =   1 ms   (fastest time constant at high V)
//    τ_max   =   5 ms   (peak time constant)
//    V0_τ    = −30 mV   (voltage of τ peak)
//    σ_τ     =  30 mV   (width of τ bell)
//    gMax    =  10 mS/cm²  (BK is a high-conductance channel)
//
//  The channel reads "Ca" from the compartment's concentrations dict (mM).
//  If no Ca²⁺ dynamics are tracked, falls back to restingCalcium.
//
//  For the HHGated kinetics preview, gateInf / gateTau are evaluated at
//  restingCalcium so the chart shows the V-dependent curve at that [Ca].
//

import Foundation

public final class BKChannel: IonChannel, HHGated {

    public var name: String = "K_BK"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV  (K⁺, typically −90 mV)
    public var species: IonSpecies? { .potassium }

    // Gating parameters
    public var vHalfAtRef: Double   // V_half when [Ca] = Ca_ref (mV)
    public var caShift: Double      // mV shift per natural-log unit of [Ca]/Ca_ref
    public var caRef: Double        // reference [Ca] in mM (default 1e-3 mM = 1 µM)
    public var slopeFactor: Double  // k — sigmoid slope factor (mV)

    // Time-constant bell curve
    public var tauMin: Double       // ms
    public var tauMax: Double       // ms  (added on top of tauMin at peak)
    public var tauVPeak: Double     // voltage of τ peak (mV)
    public var tauSigma: Double     // width σ (mV)

    /// [Ca²⁺] assumed for initial state and kinetics preview (mM).
    public var restingCalcium: Double = 1e-4

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double      = 10.0,
                reversal: Double  = IonSpecies.potassium.defaultReversal(),
                vHalfAtRef: Double  = -20.0,
                caShift: Double     =  20.0,
                caRef: Double       =  1e-3,
                slopeFactor: Double =  15.0,
                tauMin: Double      =   1.0,
                tauMax: Double      =   4.0,
                tauVPeak: Double    = -30.0,
                tauSigma: Double    =  30.0) {
        self.gMax        = gMax
        self.reversal    = reversal
        self.vHalfAtRef  = vHalfAtRef
        self.caShift     = caShift
        self.caRef       = caRef
        self.slopeFactor = slopeFactor
        self.tauMin      = tauMin
        self.tauMax      = tauMax
        self.tauVPeak    = tauVPeak
        self.tauSigma    = tauSigma
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }

    public func initialState(atVoltage v: Double) -> [Double] {
        [inf(voltage: v, calcium: restingCalcium)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let w = gates[gates.startIndex]
        return gMax * w * (v - reversal)
    }

    /// Voltage-only fallback; preview chart uses this at restingCalcium.
    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let w = gates[gates.startIndex]
        output[offset] = (inf(voltage: v, calcium: restingCalcium) - w)
                          / tau(voltage: v)
    }

    /// Concentration-aware path called by Compartment during integration.
    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                concentrations: [String: Double],
                                into output: inout [Double],
                                offset: Int) {
        let ca = concentrations["Ca"] ?? restingCalcium
        let w  = gates[gates.startIndex]
        output[offset] = (inf(voltage: v, calcium: ca) - w) / tau(voltage: v)
    }

    public var concentrationDependencies: [String] { ["Ca"] }

    // MARK: HHGated

    public var gateNames: [String] { ["w"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? inf(voltage: v, calcium: restingCalcium) : 0
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? tau(voltage: v) : 1
    }

    // MARK: Private

    private func vHalf(calcium ca: Double) -> Double {
        let caClamped = max(ca, 1e-9)
        return vHalfAtRef - caShift * log(caClamped / caRef)
    }

    private func inf(voltage v: Double, calcium ca: Double) -> Double {
        1.0 / (1.0 + exp(-(v - vHalf(calcium: ca)) / slopeFactor))
    }

    private func tau(voltage v: Double) -> Double {
        let dv = v - tauVPeak
        return tauMin + tauMax * exp(-(dv * dv) / (2.0 * tauSigma * tauSigma))
    }
}
