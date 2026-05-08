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

    /// PCHIP spline — piecewise cubic Hermite (Fritsch-Carlson), monotone-preserving.
    /// Interpolates exactly through (xKnots[i], yKnots[i]) with tangent slopes[i].
    /// Outside the knot range the curve is clamped to its boundary value.
    case spline(xKnots: [Double],
                yKnots: [Double],
                slopes: [Double],
                domain: ClosedRange<Double>? = nil)

    /// Optional voltage domain over which the curve is considered valid.
    public var validDomain: ClosedRange<Double>? {
        switch self {
        case let .sigmoid(_, _, _, _, d):    return d
        case let .polynomial(_, _, d):       return d
        case let .gaussian(_, _, _, _, d):   return d
        case let .spline(_, _, _, d):        return d
        }
    }

    /// Evaluate the curve at a given membrane potential `v` (mV).
    ///
    /// - Sigmoid / Gaussian : return nil outside validDomain (falls back to
    ///   the channel's built-in formula).
    /// - Polynomial : clamp `v` to the domain boundary instead of returning
    ///   nil. Outside the control-point range the curve is held constant at
    ///   its endpoint value — no jump, no HH fallback.
    public func evaluate(at v: Double) -> Double? {
        switch self {
        case let .sigmoid(lo, hi, vHalf, k, domain):
            if let d = domain, !d.contains(v) { return nil }
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

        case let .polynomial(coefficients, vCenter, domain):
            guard !coefficients.isEmpty else { return 0 }
            // Clamp to domain: hors plage → valeur constante au dernier point
            let vc = domain.map { max($0.lowerBound, min($0.upperBound, v)) } ?? v
            let u = vc - vCenter
            var result = coefficients.last!
            for c in coefficients.dropLast().reversed() {
                result = result * u + c
            }
            return result

        case let .gaussian(tauMin, tauMax, vPeak, width, domain):
            if let d = domain, !d.contains(v) { return nil }
            let sigma = max(width, 1e-6)
            let u = (v - vPeak) / sigma
            return tauMin + (tauMax - tauMin) * exp(-0.5 * u * u)

        case let .spline(xs, ys, ds, domain):
            guard xs.count >= 2, xs.count == ys.count, xs.count == ds.count else {
                return ys.first
            }
            // Clamp to knot range (and optional validity domain)
            let lo = max(domain?.lowerBound ?? xs.first!, xs.first!)
            let hi = min(domain?.upperBound ?? xs.last!,  xs.last!)
            let vc = max(lo, min(hi, v))
            if vc <= xs.first! { return ys.first }
            if vc >= xs.last!  { return ys.last  }
            // Binary search for interval k: xs[k] ≤ vc < xs[k+1]
            var lo_i = 0, hi_i = xs.count - 1
            while hi_i - lo_i > 1 {
                let mid = (lo_i + hi_i) / 2
                if xs[mid] <= vc { lo_i = mid } else { hi_i = mid }
            }
            let k = lo_i
            let h = xs[k + 1] - xs[k]
            guard abs(h) > 1e-15 else { return ys[k] }
            let t  = (vc - xs[k]) / h
            let t2 = t * t; let t3 = t2 * t
            // Cubic Hermite basis: h00, h10, h01, h11
            let h00 =  2 * t3 - 3 * t2 + 1
            let h10 =      t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 =      t3 -     t2
            return h00 * ys[k] + h10 * h * ds[k] + h01 * ys[k + 1] + h11 * h * ds[k + 1]
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
        case let .spline(xs, ys, ds, domain):
            return .spline(xKnots: xs.map { $0 + dV }, yKnots: ys, slopes: ds,
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
        case let .spline(xs, ys, ds, domain):
            return .spline(xKnots: xs, yKnots: ys.map { $0 + dy }, slopes: ds, domain: domain)
        }
    }

    /// Helper: shift a range by `delta`.
    private func shifted(by delta: Double) -> (ClosedRange<Double>) -> ClosedRange<Double> {
        return { ($0.lowerBound + delta)...($0.upperBound + delta) }
    }
}
