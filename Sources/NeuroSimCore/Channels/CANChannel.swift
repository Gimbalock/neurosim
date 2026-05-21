//
//  CANChannel.swift
//  NeuroSimCore
//
//  Ca²⁺-activated non-specific cation channel (I_CAN).
//  One gate: m (purely Ca²⁺-dependent Hill kinetics — no voltage dependence).
//
//  The channel carries inward current from multiple cation species (Na⁺, K⁺,
//  and sometimes Ca²⁺) with a reversal near −20 mV. It amplifies slow
//  depolarisations after Ca²⁺ entry, contributing to plateau potentials and
//  UP-states in cortex and thalamus.
//
//  Parameters (Bhatt et al. / Destexhe 1994):
//    Kd  = 5e-4 mM  = 0.5 µM  (half-activation [Ca])
//    n   = 2                    (Hill coefficient)
//    τ   = 150 ms               (time constant)
//
//  Gating:
//    m∞([Ca]) = [Ca]^n / (Kd^n + [Ca]^n)
//    dm/dt    = (m∞ − m) / τ
//
//  The channel reads "Ca" from the compartment's concentrations dict (mM).
//

import Foundation

public final class CANChannel: IonChannel, HHGated {

    public var name: String = "I_CAN"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV — non-selective cation, ≈ −20 mV
    public var species: IonSpecies? { nil }  // non-selective cation

    /// Half-activation Ca²⁺ concentration (mM). Default 5e-4 mM = 0.5 µM.
    public var halfActivation: Double
    /// Hill coefficient. Default 2.
    public var hillCoefficient: Double
    /// Activation time constant (ms). Default 150 ms.
    public var tauActivation: Double
    /// Resting [Ca²⁺] used for initial state and kinetics preview (mM).
    public var restingCalcium: Double = 1e-4

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 0.25,
                reversal: Double = -20.0,
                halfActivation: Double = 5e-4,
                hillCoefficient: Double = 2,
                tauActivation: Double = 150.0) {
        self.gMax            = gMax
        self.reversal        = reversal
        self.halfActivation  = halfActivation
        self.hillCoefficient = hillCoefficient
        self.tauActivation   = tauActivation
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }

    public func initialState(atVoltage _: Double) -> [Double] {
        [hillInf(calcium: restingCalcium)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex]
        return gMax * m * (v - reversal)
    }

    /// Gate derivative. `_latestCa` updated by `applyConcentrations` before this call.
    public func gateDerivatives(voltage _: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let m = gates[gates.startIndex]
        output[offset] = (hillInf(calcium: _latestCa) - m) / tauActivation
    }

    public var concentrationDependencies: [String] { ["Ca"] }

    private var _latestCa: Double = 1e-4

    public func applyConcentrations(_ concentrations: [String: Double]) {
        _latestCa = concentrations["Ca"] ?? restingCalcium
    }

    // MARK: HHGated

    public var gateNames: [String] { ["m"] }

    /// Preview curve: m∞ vs V is flat (no V dependence).
    /// Returns the Hill value at resting [Ca] so the preview shows a constant.
    /// Rush-Larsen steady-state: uses _latestCa so exponential update is correct.
    public func gateInf(_ index: Int, voltage _: Double) -> Double {
        index == 0 ? hillInf(calcium: _latestCa) : 0
    }

    /// Preview: constant time constant.
    public func gateTau(_ index: Int, voltage _: Double) -> Double {
        index == 0 ? tauActivation : 1
    }

    // MARK: Private

    private func hillInf(calcium ca: Double) -> Double {
        let n  = hillCoefficient
        let kn = pow(halfActivation, n)
        let can = pow(max(ca, 0), n)
        return can / (kn + can)
    }
}
