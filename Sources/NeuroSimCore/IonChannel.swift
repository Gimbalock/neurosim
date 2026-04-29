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

    /// Steady-state initial values for the gates at a given holding potential.
    func initialState(atVoltage v: Double) -> [Double]

    /// Current (µA/cm²) given membrane potential and current gate values.
    func current(voltage v: Double, gates: ArraySlice<Double>) -> Double

    /// Time derivatives of the gates (1/ms), in the same order as `initialState`.
    func gateDerivatives(voltage v: Double,
                         gates: ArraySlice<Double>,
                         into output: inout [Double],
                         offset: Int)
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
