//
//  GateCurve.swift
//  NeuroSimCore
//
//  A user-editable curve x(V) used to override the steady-state
//  activation `x∞(V)` or the time constant `τ(V)` of a Hodgkin-Huxley
//  gate. Two parameterisations are supported:
//
//   - `.sigmoid` — classical 4-parameter logistic. Always monotone,
//     bounded between `lo` and `hi`. Ideal shape for `x∞`.
//   - `.polynomial` — coefficients in `(V − vCenter)`, evaluated by
//     Horner's method. The centring keeps the conditioning of the
//     normal equations during fitting reasonable. Useful for `τ(V)`,
//     which often shows a non-monotone bell.
//
//  Each case carries an optional `validDomain` (a closed range of mV).
//  When set, the curve only applies inside that range — `evaluate(at:)`
//  returns nil outside, and consumers (the simulation, the plot
//  renderer) fall back to the channel's built-in formula. This is what
//  protects you from polynomials that fly off to ±∞ outside the points
//  used to fit them: the override is only "active" between the leftmost
//  and rightmost control points.
//
//  When set as an override on a channel (see `HHGated`), the curve is
//  evaluated by the integrator on every step, so editing it in the UI
//  changes the simulation in real time.
//

import Foundation

public enum GateCurve: Equatable {
    /// 4-parameter logistic on `validDomain` (or all V if nil):
    ///   y(V) = lo + (hi − lo) / (1 + exp(−(V − vHalf)/k))
    case sigmoid(lo: Double,
                 hi: Double,
                 vHalf: Double,
                 k: Double,
                 domain: ClosedRange<Double>? = nil)

    /// Polynomial in centred voltage on `validDomain` (or all V if nil):
    ///   y(V) = c0 + c1·u + c2·u² + … + cn·uⁿ ,  u = V − vCenter
    case polynomial(coefficients: [Double],
                    vCenter: Double,
                    domain: ClosedRange<Double>? = nil)

    /// Gaussian bell — ideal shape for voltage-dependent τ(V):
    ///   y(V) = tauMin + (tauMax − tauMin) · exp(−½·((V − vPeak)/width)²)
    case gaussian(tauMin: Double,
                  tauMax: Double,
                  vPeak: Double,
                  width: Double,
                  domain: ClosedRange<Double>? = nil)

    /// Optional voltage domain over which the curve is considered valid.
    public var validDomain: ClosedRange<Double>? {
        switch self {
        case let .sigmoid(_, _, _, _, d):    return d
        case let .polynomial(_, _, d):       return d
        case let .gaussian(_, _, _, _, d):   return d
        }
    }

    /// Evaluate the curve at a given membrane potential `v` (mV).
    /// Returns nil if `v` lies outside `validDomain` (when one is set).
    public func evaluate(at v: Double) -> Double? {
        if let d = validDomain, !d.contains(v) { return nil }

        switch self {
        case let .sigmoid(lo, hi, vHalf, k, _):
            guard abs(k) > 1e-12 else {
                if v < vHalf      { return lo }
                else if v > vHalf { return hi }
                else              { return 0.5 * (lo + hi) }
            }
            let z = -(v - vHalf) / k
            let s: Double
            if z >= 0 {
                let e = exp(-z)
                s = e / (1.0 + e)
            } else {
                s = 1.0 / (1.0 + exp(z))
            }
            return lo + (hi - lo) * s

        case let .polynomial(coefficients, vCenter, _):
            guard !coefficients.isEmpty else { return 0 }
            let u = v - vCenter
            var result = coefficients.last!
            for c in coefficients.dropLast().reversed() {
                result = result * u + c
            }
            return result

        case let .gaussian(tauMin, tauMax, vPeak, width, _):
            let sigma = max(width, 1e-6)
            let u = (v - vPeak) / sigma
            return tauMin + (tauMax - tauMin) * exp(-0.5 * u * u)
        }
    }

    /// Translate the curve along the voltage axis by `dV` mV.
    /// Shifts both the parameterisation and the validity domain so the
    /// translated override stays "active" over a range that follows the
    /// curve geometrically. (Used by the UI's "translate X" tool.)
    public func translatedX(by dV: Double) -> GateCurve {
        switch self {
        case let .sigmoid(lo, hi, vHalf, k, domain):
            return .sigmoid(lo: lo, hi: hi, vHalf: vHalf + dV, k: k,
                            domain: domain.map(shifted(by: dV)))
        case let .polynomial(c, vCenter, domain):
            return .polynomial(coefficients: c, vCenter: vCenter + dV,
                               domain: domain.map(shifted(by: dV)))
        case let .gaussian(tMin, tMax, vPeak, w, domain):
            return .gaussian(tauMin: tMin, tauMax: tMax, vPeak: vPeak + dV, width: w,
                             domain: domain.map(shifted(by: dV)))
        }
    }

    public func translatedY(by dy: Double) -> GateCurve {
        switch self {
        case let .sigmoid(lo, hi, vHalf, k, domain):
            return .sigmoid(lo: lo + dy, hi: hi + dy, vHalf: vHalf, k: k, domain: domain)
        case .polynomial(var c, let vCenter, let domain):
            if c.isEmpty { c = [dy] } else { c[0] += dy }
            return .polynomial(coefficients: c, vCenter: vCenter, domain: domain)
        case let .gaussian(tMin, tMax, vPeak, w, domain):
            return .gaussian(tauMin: tMin + dy, tauMax: tMax + dy, vPeak: vPeak, width: w, domain: domain)
        }
    }

    /// Helper: shift a range by `delta`.
    private func shifted(by delta: Double) -> (ClosedRange<Double>) -> ClosedRange<Double> {
        return { ($0.lowerBound + delta)...($0.upperBound + delta) }
    }
}
