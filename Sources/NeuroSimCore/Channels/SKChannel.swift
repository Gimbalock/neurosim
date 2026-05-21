//
//  SKChannel.swift
//  NeuroSimCore
//
//  Small-conductance Ca²⁺-activated K⁺ channel (SK, K_Ca2.x).
//
//  Gating is purely Ca²⁺-dependent — no intrinsic voltage dependence.
//  The activation gate `w` follows Hill kinetics:
//
//      w∞([Ca]) = [Ca]^n / (Kd^n + [Ca]^n)
//      dw/dt    = (w∞ − w) / τ_w
//
//  Parameters (Waroux et al. 2005 / Destexhe & Paré 1999):
//    Kd = 0.5 µM  = 5e-4 mM   (half-activation [Ca])
//    n  = 4                     (Hill coefficient)
//    τ  = 80 ms                 (voltage-independent time constant)
//
//  The channel reads the compartment's "Ca" concentration (mM). If no
//  Ca²⁺ dynamics are tracked in the compartment the channel still compiles
//  but remains silent (concentrations dict is empty → [Ca] falls back to
//  the resting value used for initial conditions).
//
//  Sign convention: outward (positive) K⁺ current, repolarising.
//

import Foundation

public final class SKChannel: IonChannel, HHGated {

    public var name: String = "K_SK"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV  (K⁺ reversal, typically −90 mV)
    public var species: IonSpecies? { .potassium }

    /// Half-activation Ca²⁺ concentration (mM). Default 5e-4 mM = 0.5 µM.
    public var halfActivation: Double
    /// Hill coefficient. Default 4.
    public var hillCoefficient: Double
    /// Activation time constant (ms). Default 80 ms.
    public var tauActivation: Double
    /// Resting [Ca²⁺] used for initial state and kinetics preview (mM).
    /// 1e-4 mM = 100 nM — typical cytosolic resting value.
    public var restingCalcium: Double = 1e-4

    /// Most-recently seen intracellular [Ca²⁺] (mM), updated each integration
    /// step by the concentration-aware `gateDerivatives` path.
    /// Kept as a stored property so the voltage-only fallback (used e.g. by
    /// VoltageClampEngine and the UI preview) always uses the latest value seen
    /// during simulation — avoiding any Swift protocol-dispatch ambiguity
    /// between the two `gateDerivatives` overloads.
    private var _latestCa: Double = 1e-4

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 2.0,
                reversal: Double = IonSpecies.potassium.defaultReversal(),
                halfActivation: Double = 5e-4,
                hillCoefficient: Double = 4,
                tauActivation: Double = 80.0) {
        self.gMax            = gMax
        self.reversal        = reversal
        self.halfActivation  = halfActivation
        self.hillCoefficient = hillCoefficient
        self.tauActivation   = tauActivation
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }

    /// Initial w at resting [Ca²⁺] ≈ 0 (channel closed at rest).
    public func initialState(atVoltage _: Double) -> [Double] {
        [hillInf(calcium: restingCalcium)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let w = gates[gates.startIndex]
        return gMax * w * (v - reversal)
    }

    /// Gate derivative. `_latestCa` is updated by `applyConcentrations` each step,
    /// which Compartment calls before this method. No overloaded variant needed.
    public func gateDerivatives(voltage _: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let w = gates[gates.startIndex]
        output[offset] = (hillInf(calcium: _latestCa) - w) / tauActivation
    }

    public var concentrationDependencies: [String] { ["Ca"] }

    /// Receives the current [Ca²⁺]ᵢ (mM) from Compartment before each
    /// `gateDerivatives` call, bypassing any Swift existential dispatch
    /// ambiguity between overloaded `gateDerivatives` signatures.
    public func applyConcentrations(_ concentrations: [String: Double]) {
        _latestCa = concentrations["Ca"] ?? restingCalcium
    }

    // MARK: HHGated

    public var gateNames: [String] { ["w"] }

    /// Rush-Larsen steady-state: uses the most recently cached [Ca²⁺]
    /// so the exponential update w_new = w∞ + (w-w∞)·exp(-dt/τ) is
    /// correct for Ca-dependent gating (not stuck at restingCalcium).
    /// `applyConcentrations` is always called before gateInf in the RL loop.
    public func gateInf(_ index: Int, voltage _: Double) -> Double {
        index == 0 ? hillInf(calcium: _latestCa) : 0
    }

    /// Preview: constant time constant.
    public func gateTau(_ index: Int, voltage _: Double) -> Double {
        index == 0 ? tauActivation : 1
    }

    // MARK: Private

    private func hillInf(calcium ca: Double) -> Double {
        let n = hillCoefficient
        let kn = pow(halfActivation, n)
        let can = pow(max(ca, 0), n)
        return can / (kn + can)
    }
}
