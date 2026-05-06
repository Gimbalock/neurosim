//
//  IonChannel.swift
//  NeuroSimCore
//
//  Protocol-based ion channel abstraction. Adding a new channel = conforming
//  to IonChannel — the neuron and integrator pick it up automatically.
//

import Foundation

/// A voltage-gated ion channel with arbitrarily many gating variables.
///
/// State layout convention: each channel exposes a flat `[Double]` of gating
/// variables. The neuron concatenates these into its state vector. Sign
/// convention for currents follows Hodgkin-Huxley: `I = g_max * f(gates) * (V - E)`,
/// positive = outward, negative = inward.
public protocol IonChannel: AnyObject {
    /// Human-readable identifier (used in UI/labels/exports).
    var name: String { get }

    /// Maximum conductance (mS/cm²). Editable from the UI.
    var gMax: Double { get set }

    /// Reversal potential (mV).
    var reversal: Double { get set }

    /// Number of gating variables this channel carries in the state vector.
    var stateCount: Int { get }

    /// The ion species this channel selectively conducts, if any. When
    /// non-nil, the channel can have its `reversal` recomputed from
    /// intracellular/extracellular concentrations of `species` via the
    /// Nernst equation (see `updateReversalFromNernst`). When nil, the
    /// channel is treated as mixed/non-selective (e.g. a passive leak that
    /// lumps Na⁺ + K⁺ + Cl⁻) and keeps its `reversal` as a free parameter.
    ///
    /// Default is `nil` — existing channels stay backward-compatible without
    /// changes; new channels override this to declare their carrier ion.
    var species: IonSpecies? { get }

    /// Steady-state initial values for the gates at a given holding potential.
    func initialState(atVoltage v: Double) -> [Double]

    /// Current (µA/cm²) given membrane potential and current gate values.
    func current(voltage v: Double, gates: ArraySlice<Double>) -> Double

    /// Time derivatives of the gates (1/ms), in the same order as `initialState`.
    func gateDerivatives(voltage v: Double,
                         gates: ArraySlice<Double>,
                         into output: inout [Double],
                         offset: Int)

    /// Ion symbols this channel reads from the compartment's concentration
    /// state (e.g. `["Ca"]` for SK/BK). Default `[]` — no concentration
    /// dependency. Used by `Compartment` to know which ions to pass.
    var concentrationDependencies: [String] { get }

    /// Concentration-aware variant of `gateDerivatives`. `concentrations` is
    /// a dictionary of ion-symbol → current value (mM) for every tracked ion
    /// in this compartment. Channels that depend on concentrations override
    /// this method; all others get the default implementation below which
    /// simply ignores `concentrations` and delegates to the voltage-only form.
    func gateDerivatives(voltage v: Double,
                         gates: ArraySlice<Double>,
                         concentrations: [String: Double],
                         into output: inout [Double],
                         offset: Int)
}

public extension IonChannel {
    /// Default: no concentration dependency.
    var concentrationDependencies: [String] { [] }

    /// Default: ignore concentrations and delegate to the voltage-only form.
    /// Every existing channel conforms automatically without any source change.
    func gateDerivatives(voltage v: Double,
                         gates: ArraySlice<Double>,
                         concentrations: [String: Double],
                         into output: inout [Double],
                         offset: Int) {
        gateDerivatives(voltage: v, gates: gates, into: &output, offset: offset)
    }

    /// Default: channel doesn't declare an ion species. Keeps every channel
    /// written before the IonSpecies layer existed conforming as-is.
    var species: IonSpecies? { nil }

    /// Recompute `reversal` (mV) from concentrations using the Nernst
    /// equation. No-op for channels that don't declare a species — the
    /// fixed `reversal` set at construction time is left untouched, which
    /// is what you want for a mixed leak.
    ///
    /// - Parameters:
    ///   - cIn: intracellular concentration of the channel's species.
    ///   - cOut: extracellular concentration.
    ///   - T: absolute temperature (K). Defaults to 37 °C.
    func updateReversalFromNernst(concentrationIn cIn: Double,
                                  concentrationOut cOut: Double,
                                  temperatureK T: Double = Nernst.mammalianBodyTemperatureK) {
        guard let sp = species else { return }
        reversal = Nernst.reversalPotential(species: sp,
                                            concentrationIn: cIn,
                                            concentrationOut: cOut,
                                            temperatureK: T)
    }
}

/// A handful of helpers shared by HH-style channels (avoid singularities at
/// the rate-constant limits).
public enum HHRate {
    /// `α(V) = a * (V - V0) / (1 - exp(-(V - V0)/k))` — has a removable
    /// singularity at V == V0 where both numerator and denominator vanish.
    /// We use `expm1(-x) = exp(-x) - 1`, which is numerically accurate even
    /// for x near zero, so `1 - exp(-x) = -expm1(-x)` stays well-conditioned.
    /// At exactly V == V0 the limit is `a · k`.
    public static func linexp(_ v: Double, a: Double, v0: Double, k: Double) -> Double {
        let dv = v - v0
        if abs(dv) < 1e-9 { return a * k }
        return -a * dv / expm1(-dv / k)
    }
}
