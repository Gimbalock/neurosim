//
//  HHGated.swift
//  NeuroSimCore
//
//  Introspection layer over Hodgkin-Huxley-formalism channels.
//
//  Channels conforming to `HHGated` expose, on top of the bare `IonChannel`
//  contract, the per-gate steady-state activation curve `x∞(V)` and time
//  constant `τ(V)`. This lets the UI plot those curves (and, eventually,
//  let the user manipulate them graphically) without having to know how
//  the channel computes them internally — some channels store α/β rate
//  constants and derive `x∞ = α/(α+β)`, others (Destexhe-style) hold
//  `x∞(V)` and `τ(V)` directly.
//
//  Pure-leak channels (no gating variables) do *not* conform to this
//  protocol — there is nothing to introspect.
//

import Foundation

/// Hodgkin-Huxley channel that can answer "what's the steady-state value
/// of gate i at voltage V?" and "what's its time constant at voltage V?".
///
/// Per-gate overrides
/// ──────────────────
/// `gateInfOverrides` and `gateTauOverrides` let the UI replace the
/// hard-coded HH formulas with user-edited `GateCurve`s on a per-gate
/// basis. `nil` means "use the channel's built-in formula"; a non-nil
/// entry is consulted instead. Use `resolvedGateInf(_:voltage:)` and
/// `resolvedGateTau(_:voltage:)` (default-implemented below) when you
/// want the effective curve — the integrator does, so user edits change
/// the simulation immediately.
///
/// Conformers must store `gateInfOverrides` / `gateTauOverrides` arrays
/// of length `stateCount`, initialised to `[GateCurve?](repeating: nil,
/// count: stateCount)`. Swift doesn't allow stored properties in
/// protocol extensions, so each channel declares the storage; the
/// resolution logic lives in the extension below.
public protocol HHGated: IonChannel {
    /// Display names of the gating variables, in state-vector order.
    /// E.g. `SodiumChannel` returns `["m", "h"]`; `PotassiumChannel`
    /// returns `["n"]`. Must have `count == stateCount`.
    var gateNames: [String] { get }

    /// Built-in steady-state value of gate `index` at membrane potential
    /// `v` (mV). Always in `[0, 1]`. Channels keep this hard-coded —
    /// it's the analytical formula written in the channel's source.
    /// Use `resolvedGateInf` to get the curve actually applied to the
    /// simulation (which honours overrides).
    func gateInf(_ index: Int, voltage v: Double) -> Double

    /// Built-in time constant of gate `index` at membrane potential `v`
    /// (mV), in ms. Always strictly positive.
    func gateTau(_ index: Int, voltage v: Double) -> Double

    /// User-editable overrides for `x∞(V)`, one per gate. `nil` means
    /// "use `gateInf`". Length must equal `stateCount`.
    var gateInfOverrides: [GateCurve?] { get set }

    /// User-editable overrides for `τ(V)`, one per gate. `nil` means
    /// "use `gateTau`". Length must equal `stateCount`.
    var gateTauOverrides: [GateCurve?] { get set }
}

public extension HHGated {
    /// Steady-state value actually used by the integrator and the UI:
    /// the override curve if one is set *and* `v` is inside its domain
    /// of validity, otherwise the channel's built-in formula. This
    /// "domain-aware" fallback keeps the simulation safe when the user
    /// has only edited a portion of the V axis: outside the edited
    /// band the original HH dynamics apply, no extrapolation surprises.
    func resolvedGateInf(_ index: Int, voltage v: Double) -> Double {
        if index >= 0,
           index < gateInfOverrides.count,
           let curve = gateInfOverrides[index],
           let value = curve.evaluate(at: v) {
            return value
        }
        return gateInf(index, voltage: v)
    }

    /// Time constant actually used by the integrator and the UI:
    /// override curve if set and in-domain, otherwise built-in.
    /// Clamped to a small positive minimum so a poorly-fitted polynomial
    /// dipping to or below zero can't produce non-finite derivatives.
    func resolvedGateTau(_ index: Int, voltage v: Double) -> Double {
        let raw: Double
        if index >= 0,
           index < gateTauOverrides.count,
           let curve = gateTauOverrides[index],
           let value = curve.evaluate(at: v) {
            raw = value
        } else {
            raw = gateTau(index, voltage: v)
        }
        return max(raw, 1e-3)  // floor at 1 µs to keep dx/dt finite
    }
}
