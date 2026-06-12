//
//  DensityScore.swift
//  NeuroSimCore
//
//  Phase-plane trajectory density (PPTD) scoring utilities.
//  Lives in NeuroSimCore so they are accessible from both NeuroSimApp
//  and the test target (NeuroSimCoreTests).
//
//  The χ² distance between two arc-length-weighted density grids is the
//  production fitness function used by the optimizer and the benchmark.
//
//  Improvements (v2)
//  ─────────────────
//  1. Axis-normalised arc-length: each segment is measured in the normalised
//     (V/V_range, dV/dt/dvdt_range) plane, giving equal weight to both axes
//     regardless of their physical scale difference (~8× for HH models).
//
//  2. Spike-count field: `spikeCount` in EvalDensityGrid stores the AP count
//     (upward threshold crossings) so callers can add a firing-rate mismatch
//     penalty via `chiSquaredScore`.
//
//  3. Optional Gaussian smoothing: `smoothRadius > 0` blurs the histogram
//     before scoring.  Disabled by default — smoothing distributes density
//     and reduces sensitivity to point-like features (resting voltage,
//     spike threshold) that are diagnostic of conductance errors.
//
//  4. Progressive out-of-bounds penalty: `2·(1 − exp(−5·outFraction))`
//     replaces the linear `outFraction × 2` for a smooth C∞ transition
//     with softer gradients at the reference-window boundary.
//
//  5. `chiSquaredScore`: composite scorer combining PPTD χ² with an
//     optional firing-rate mismatch term `λ_ISI × (ΔspikeFrac)²`.
//     Useful when both spike shape AND firing rate must match.
//

import Foundation

// MARK: - Density grid

/// A weighted phase-plane density histogram.
///
/// `weights` accumulates arc-length mass rather than raw point counts so that
/// each segment of the phase-plane trajectory contributes proportionally to
/// its length in the *normalised* (V/V_range, dV/dt/dvdt_range) plane.
public struct EvalDensityGrid: Sendable {
    public let weights:     [Double]   // arc-length-weighted bin masses
    public let nV:          Int
    public let nDvdt:       Int
    public let vMin:        Double
    public let vMax:        Double
    public let dvdtMin:     Double
    public let dvdtMax:     Double
    public let outFraction: Double     // fraction of pts outside reference range
    /// AP count: upward crossings of threshold = vMin + 0.75 × (vMax − vMin).
    /// Reliable for HH models (threshold ≈ +10 mV, well inside AP upstroke).
    public let spikeCount:  Int
    /// Pre-computed sum of all bin weights (avoids repeated reduce).
    public let totalWeight: Double
}

// MARK: - Grid builders

/// Build a density grid with automatic domain bounds (4% padding).
public func buildEvalGrid(_ pts: [(v: Double, dvdt: Double)],
                          nV: Int, nD: Int,
                          smoothRadius: Int = 0) -> EvalDensityGrid? {
    guard !pts.isEmpty else { return nil }
    let vs = pts.map(\.v); let ds = pts.map(\.dvdt)
    guard let vMn = vs.min(), let vMx = vs.max(), vMx > vMn,
          let dMn = ds.min(), let dMx = ds.max(), dMx > dMn else { return nil }
    let vPad = (vMx - vMn) * 0.04; let dPad = (dMx - dMn) * 0.04
    return buildEvalGridInRange(pts,
                                vLo: vMn - vPad, vHi: vMx + vPad,
                                dLo: dMn - dPad, dHi: dMx + dPad,
                                nV: nV, nD: nD, smoothRadius: smoothRadius)
}

/// Build a weighted density grid within a fixed (V, dV/dt) bounding box.
///
/// Each point `pts[i]` receives a weight equal to the average arc-length of
/// its two adjacent phase-plane segments, measured in the *normalised* plane
/// where V and dV/dt each span [0, 1] relative to the grid bounds.
/// This balances the contribution of V (mV) and dV/dt (mV/ms), which differ
/// by ~8× in physical scale for Hodgkin-Huxley models.
///
/// Points outside [vLo, vHi] × [dLo, dHi] are counted in `outFraction`.
///
/// - Parameter smoothRadius: bins of Gaussian blur applied to the weight grid.
///   Disabled (0) by default.  Increasing this value reduces noise in sparse
///   grids but also reduces sensitivity to fixed-potential features such as
///   resting voltage and AP threshold — leave off unless grids are very sparse.
public func buildEvalGridInRange(_ pts: [(v: Double, dvdt: Double)],
                                 vLo: Double, vHi: Double,
                                 dLo: Double, dHi: Double,
                                 nV: Int, nD: Int,
                                 smoothRadius: Int = 0) -> EvalDensityGrid {
    var weights  = [Double](repeating: 0, count: nV * nD)
    var outCount = 0
    let n        = pts.count

    // ── Axis normalisation ──────────────────────────────────────────────────
    // Divide increments by the respective axis range so that both V and dV/dt
    // contribute equally to arc-length regardless of their physical scales.
    let vRange = max(vHi - vLo, 1e-6)
    let dRange = max(dHi - dLo, 1e-6)

    @inline(__always)
    func segLen(_ i: Int, _ j: Int) -> Double {
        let dv = (pts[j].v    - pts[i].v)    / vRange
        let dd = (pts[j].dvdt - pts[i].dvdt) / dRange
        return max(sqrt(dv*dv + dd*dd), 1e-12)
    }

    for i in 0..<n {
        let w: Double
        switch (i, n) {
        case (_, 1):                           w = 1.0
        case (0, _):                           w = segLen(0, 1)
        case (_, _) where i == n - 1:          w = segLen(n-2, n-1)
        default:                               w = (segLen(i-1, i) + segLen(i, i+1)) * 0.5
        }
        let p = pts[i]
        guard p.v >= vLo, p.v <= vHi,
              p.dvdt >= dLo, p.dvdt <= dHi else { outCount += 1; continue }
        let ci = min(Int((p.v    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
        let ri = min(Int((p.dvdt - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
        weights[ri * nV + ci] += w
    }

    // ── Spike counting ──────────────────────────────────────────────────────
    // Upward crossings of threshold = vLo + 0.75 × vRange.
    // For typical HH bounds (vLo ≈ −83 mV, vHi ≈ +43 mV): threshold ≈ +11 mV,
    // which sits inside the AP upstroke and is reliable even at reduced amplitudes.
    let spkThresh  = vLo + 0.75 * vRange
    var spikeCount = 0
    var wasAbove   = n > 0 && pts[0].v >= spkThresh
    for i in 1..<n {
        let above = pts[i].v >= spkThresh
        if above && !wasAbove { spikeCount += 1 }
        wasAbove = above
    }

    // ── Optional Gaussian smoothing ─────────────────────────────────────────
    // Off by default (smoothRadius == 0).
    // When enabled, a separable 2-D Gaussian kernel is applied to the weight
    // grid.  This reduces scoring noise in very sparse grids but distributes
    // density away from point-like features (resting potential, spike threshold)
    // that carry important information about conductance errors — only enable
    // when the grid is too coarse or the simulation too short for stable peaks.
    if smoothRadius > 0 {
        let r     = smoothRadius
        let ksize = r * 2 + 1
        let sigma = Double(r)
        var kernel = [Double](repeating: 0, count: ksize)
        var ksum   = 0.0
        for k in 0..<ksize {
            let x = Double(k - r)
            kernel[k] = exp(-x * x / (2.0 * sigma * sigma))
            ksum += kernel[k]
        }
        for k in 0..<ksize { kernel[k] /= ksum }

        // Horizontal pass (V axis)
        var temp = [Double](repeating: 0, count: nV * nD)
        for row in 0..<nD {
            for col in 0..<nV {
                var v = 0.0
                for ki in 0..<ksize {
                    let cc = col + (ki - r)
                    if cc >= 0 && cc < nV { v += weights[row * nV + cc] * kernel[ki] }
                }
                temp[row * nV + col] = v
            }
        }
        // Vertical pass (dV/dt axis)
        for row in 0..<nD {
            for col in 0..<nV {
                var v = 0.0
                for ki in 0..<ksize {
                    let rr = row + (ki - r)
                    if rr >= 0 && rr < nD { v += temp[rr * nV + col] * kernel[ki] }
                }
                weights[row * nV + col] = v
            }
        }
    }

    let outFrac     = n > 0 ? Double(outCount) / Double(n) : 0.0
    let totalWeight = weights.reduce(0, +)
    return EvalDensityGrid(weights: weights, nV: nV, nDvdt: nD,
                           vMin: vLo, vMax: vHi,
                           dvdtMin: dLo, dvdtMax: dHi,
                           outFraction: outFrac,
                           spikeCount: spikeCount,
                           totalWeight: totalWeight)
}

// MARK: - Scoring

/// χ² distance between two arc-length-weighted density grids.
///
/// χ²(p, q) = Σ_i (p_i − q_i)² / (p_i + q_i + ε)
///           + 2·(1 − exp(−5·outFraction_b))
///
/// The progressive out-of-bounds term replaces the former linear
/// `outFraction × 2`.  It is C∞, equals 0 at outFraction=0, and saturates
/// smoothly toward 2 — giving softer gradient transitions at the boundary.
public func ssdNormalized(_ a: EvalDensityGrid, _ b: EvalDensityGrid) -> Double {
    let tA = max(1e-10, a.totalWeight)
    let tB = max(1e-10, b.totalWeight)
    var dist = 0.0
    let n = min(a.weights.count, b.weights.count)
    for i in 0..<n {
        let pA = a.weights[i] / tA
        let pB = b.weights[i] / tB
        let denom = pA + pB
        if denom > 1e-20 {
            let diff = pA - pB
            dist += diff * diff / denom
        }
    }
    dist += 2.0 * (1.0 - exp(-5.0 * b.outFraction))
    return dist
}

/// Fast χ² scorer for hot evaluation loops.
///
/// `refNorm` must be pre-computed once from the reference grid:
///     let tRef    = max(1e-10, refGrid.totalWeight)
///     let refNorm = refGrid.weights.map { $0 / tRef }
///
/// Out-of-bounds: smooth progressive penalty `2·(1−exp(−5·outFraction))`.
@inline(__always)
public func chiSquaredFast(refNorm: [Double], cg: EvalDensityGrid) -> Double {
    let tB  = max(1e-10, cg.totalWeight)
    var dist = 0.0
    let n   = min(refNorm.count, cg.weights.count)
    for i in 0..<n {
        let pA    = refNorm[i]
        let pB    = cg.weights[i] / tB
        let denom = pA + pB
        if denom > 1e-20 {
            let diff = pA - pB
            dist += diff * diff / denom
        }
    }
    dist += 2.0 * (1.0 - exp(-5.0 * cg.outFraction))
    return dist
}

/// Composite scorer: arc-length χ² + optional firing-rate mismatch term.
///
///   score = χ²_PPTD(refNorm, cg)
///         + 2·(1 − exp(−5·outFraction))
///         + λ_ISI · ((n_spk_cand − n_spk_ref) / n_spk_ref)²
///
/// The ISI term captures relative firing-rate mismatch that the normalised
/// PPTD alone misses when spike shapes are identical but firing rates differ
/// (e.g. gNa controls both AP amplitude and firing frequency in HH models).
///
/// - Parameters:
///   - refNorm:        pre-normalised reference histogram (ref.weights / totalWeight)
///   - refSpikeCount:  `refGrid.spikeCount` — AP count in the reference trace
///   - cg:             candidate density grid (same bin layout as refNorm)
///   - lambdaISI:      weight for the rate term; 0 = disabled (default).
///                     Suggested range: 0.2 – 0.5 for HH conductance fitting.
@inline(__always)
public func chiSquaredScore(refNorm: [Double], refSpikeCount: Int,
                             cg: EvalDensityGrid, lambdaISI: Double = 0.0) -> Double {
    let tB   = max(1e-10, cg.totalWeight)
    var dist = 0.0
    let n    = min(refNorm.count, cg.weights.count)
    for i in 0..<n {
        let pA    = refNorm[i]
        let pB    = cg.weights[i] / tB
        let denom = pA + pB
        if denom > 1e-20 {
            let diff = pA - pB
            dist += diff * diff / denom
        }
    }
    dist += 2.0 * (1.0 - exp(-5.0 * cg.outFraction))
    if lambdaISI > 0.0 && refSpikeCount > 0 {
        let rDiff = Double(cg.spikeCount - refSpikeCount) / Double(refSpikeCount)
        dist += lambdaISI * rDiff * rDiff
    }
    return dist
}
