//
//  BayesianOptimizer.swift
//  NeuroSimCore
//
//  Gaussian-Process Bayesian Optimisation (GP-BO).
//
//  Architecture
//  ─────────────
//  Surrogate  : RBF-ARD kernel (per-dimension length scales) + Gaussian noise.
//  Acquisition: Expected Improvement with ξ = 0.01 (minimisation convention).
//  Acq. max   : Latin Hypercube Search over `acquisitionSamples` candidates.
//  Hyper-opt  : Random search (20 restarts) in log-space over
//               (σ_f, σ_n, l₁…lₙ), maximising log marginal likelihood.
//
//  Normalisation
//  ─────────────
//  Inputs  : [lo, hi] → [0, 1] per dimension (from `bounds`).
//  Outputs : running (mean, std) → N(0, 1), updated after every observation.
//
//  Usage
//  ─────
//      var bo = BayesianOptimizer(bounds: [...])
//      for _ in 0..<budget {
//          let x = bo.nextCandidate()   // LHS during warm-up, GP-EI after
//          let y = evalFn(x)
//          bo.addObservation(x: x, y: y)
//      }
//

import Foundation

// MARK: - Private math helpers

/// Cholesky decomposition  A = L · Lᵀ  (A symmetric positive-definite).
/// `A` stored row-major in a flat `[Double]`. Returns L or `nil` if not SPD.
private func _chol(_ A: [Double], n: Int) -> [Double]? {
    var L = [Double](repeating: 0.0, count: n * n)
    for i in 0..<n {
        for j in 0...i {
            var s = A[i * n + j]
            for k in 0..<j { s -= L[i * n + k] * L[j * n + k] }
            if i == j {
                guard s > 0 else { return nil }
                L[i * n + i] = sqrt(s)
            } else {
                L[i * n + j] = s / L[j * n + j]
            }
        }
    }
    return L
}

/// Forward substitution: solve  L · x = b  (L lower-triangular).
private func _fwd(_ L: [Double], _ b: [Double], n: Int) -> [Double] {
    var x = b
    for i in 0..<n {
        for j in 0..<i { x[i] -= L[i * n + j] * x[j] }
        x[i] /= L[i * n + i]
    }
    return x
}

/// Back substitution: solve  Lᵀ · x = b.
private func _bwd(_ L: [Double], _ b: [Double], n: Int) -> [Double] {
    var x = b
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in (i + 1)..<n { x[i] -= L[j * n + i] * x[j] }
        x[i] /= L[i * n + i]
    }
    return x
}

/// Solve  (L · Lᵀ) · x = b  in two substitution passes.
private func _cholSolve(_ L: [Double], _ b: [Double], n: Int) -> [Double] {
    _bwd(L, _fwd(L, b, n: n), n: n)
}

/// log|K| = 2 · Σᵢ log(Lᵢᵢ).
private func _cholLogDet(_ L: [Double], n: Int) -> Double {
    (0..<n).reduce(0.0) { $0 + log(L[$1 * n + $1]) } * 2.0
}

/// Φ(x) — standard normal CDF via erfc for numerical stability.
@inline(__always) private func _Phi(_ x: Double) -> Double {
    0.5 * erfc(-x / sqrt(2.0))
}

/// φ(x) — standard normal PDF.
@inline(__always) private func _phi(_ x: Double) -> Double {
    exp(-0.5 * x * x) * (1.0 / sqrt(2.0 * .pi))
}

// MARK: - RBF-ARD kernel

/// k(x, x') = σ_f² · exp(−½ · Σᵢ ((xᵢ−x'ᵢ)/lᵢ)²)
@inline(__always)
private func _rbf(_ x: [Double], _ xp: [Double], sf2: Double, ls: [Double]) -> Double {
    var r2 = 0.0
    for i in 0..<x.count { let d = (x[i] - xp[i]) / ls[i]; r2 += d * d }
    return sf2 * exp(-0.5 * r2)
}

// MARK: - xoshiro256** PRNG  (fast, deterministic, Sendable value type)

private struct _RNG: Sendable {
    var s: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        func sm(_ v: inout UInt64) -> UInt64 {
            v &+= 0x9E3779B97F4A7C15
            var z = v
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        var x = seed; s = (sm(&x), sm(&x), sm(&x), sm(&x))
    }

    mutating func nextU64() -> UInt64 {
        let r = ((s.1 &* 5).rotl(7)) &* 9
        let t = s.1 << 17
        s.2 ^= s.0; s.3 ^= s.1; s.1 ^= s.2; s.0 ^= s.3
        s.2 ^= t;   s.3 = s.3.rotl(45)
        return r
    }

    /// Uniform Double in [0, 1).
    mutating func next01() -> Double {
        Double(nextU64() >> 11) * (1.0 / Double(1 << 53))
    }
}

private extension UInt64 {
    func rotl(_ k: Int) -> UInt64 { (self << k) | (self >> (64 - k)) }
}

// MARK: - Latin Hypercube Sampling in [0, 1]^n

private func _lhs(ndim: Int, nsamples: Int, seed: UInt64) -> [[Double]] {
    guard nsamples > 0 && ndim > 0 else { return [] }
    var rng = _RNG(seed: seed)
    var out = [[Double]](repeating: [Double](repeating: 0.0, count: ndim), count: nsamples)
    for d in 0..<ndim {
        var perm = Array(0..<nsamples)
        for i in stride(from: nsamples - 1, through: 1, by: -1) {
            let j = Int(rng.nextU64() % UInt64(i + 1))
            perm.swapAt(i, j)
        }
        for i in 0..<nsamples {
            out[i][d] = (Double(perm[i]) + rng.next01()) / Double(nsamples)
        }
    }
    return out
}

// MARK: - GP hyperparameters

private struct _GPHyp: Sendable {
    var sf2: Double           // signal variance σ_f²
    var sn2: Double           // noise variance σ_n²
    var ls:  [Double]         // per-dimension length scales

    static func initial(ndim: Int) -> _GPHyp {
        _GPHyp(sf2: 1.0, sn2: 1e-4, ls: [Double](repeating: 0.3, count: ndim))
    }
}

// MARK: - Log marginal likelihood

private func _lml(xs: [[Double]], ys: [Double], hyp: _GPHyp) -> Double {
    let n = xs.count
    guard n >= 2 else { return -.infinity }

    var K = [Double](repeating: 0.0, count: n * n)
    for i in 0..<n {
        for j in 0...i {
            var v = _rbf(xs[i], xs[j], sf2: hyp.sf2, ls: hyp.ls)
            if i == j { v += hyp.sn2 }
            K[i * n + j] = v; K[j * n + i] = v
        }
    }
    guard let L = _chol(K, n: n) else { return -.infinity }
    let alpha   = _cholSolve(L, ys, n: n)
    let dataTerm = zip(ys, alpha).reduce(0.0) { $0 + $1.0 * $1.1 }
    return -0.5 * dataTerm - 0.5 * _cholLogDet(L, n: n)
           - Double(n) * 0.5 * log(2.0 * .pi)
}

// MARK: - BayesianOptimizer

/// Gaussian-Process Bayesian Optimizer.
///
/// All internal computation uses normalised inputs ([0,1]^n) and outputs
/// (N(0,1)); `bounds` are used only to map between original and normalised
/// spaces.
public struct BayesianOptimizer: Sendable {

    // MARK: Configuration

    public let bounds:             [(lo: Double, hi: Double)]
    public let warmupCount:        Int
    public let refitEvery:         Int
    public let acquisitionSamples: Int

    private let ndim: Int

    // MARK: Pre-generated warm-up candidates (original space)

    private let _warmupXs: [[Double]]

    // MARK: Observations

    private var _xsOrig: [[Double]] = []   // original space
    private var _ys:     [Double]   = []   // original scale

    private var _xsNorm: [[Double]] = []   // normalized [0,1]^n
    private var _ysNorm: [Double]   = []   // normalized N(0,1)
    private var _yMean:  Double     = 0.0
    private var _yStd:   Double     = 1.0

    // MARK: Best observed

    private var _bestY: Double   = .infinity
    private var _bestX: [Double] = []

    // MARK: GP state

    private var _hyp:      _GPHyp
    private var _L:        [Double] = []
    private var _alpha:    [Double] = []
    private var _gpFitted: Bool     = false
    private var _sinceRefit: Int    = 0

    // MARK: RNG state

    private var _seed: UInt64 = 0xBA5E_BA110

    // MARK: - Init

    public init(bounds:             [(lo: Double, hi: Double)],
                warmupCount:        Int = 8,
                refitEvery:         Int = 5,
                acquisitionSamples: Int = 2000) {
        let nd              = bounds.count
        self.bounds         = bounds
        self.warmupCount    = max(1, warmupCount)
        self.refitEvery     = max(1, refitEvery)
        // Scale acquisition budget with dimensionality
        self.acquisitionSamples = max(acquisitionSamples, 500 * nd)
        self.ndim           = nd
        self._hyp           = _GPHyp.initial(ndim: nd)

        // Pre-generate all warm-up candidates as a single LHS design
        let lhsNorm = _lhs(ndim: nd, nsamples: max(1, warmupCount), seed: 0xFEED_1234)
        self._warmupXs = lhsNorm.map { xn in
            (0..<nd).map { i in bounds[i].lo + xn[i] * (bounds[i].hi - bounds[i].lo) }
        }
    }

    // MARK: - Normalisation

    private func _normX(_ x: [Double]) -> [Double] {
        (0..<ndim).map { i in
            let r = bounds[i].hi - bounds[i].lo
            return r > 1e-12 ? (x[i] - bounds[i].lo) / r : 0.5
        }
    }

    private func _denormX(_ xn: [Double]) -> [Double] {
        (0..<ndim).map { i in bounds[i].lo + xn[i] * (bounds[i].hi - bounds[i].lo) }
    }

    // MARK: - Add observation

    /// Record a (parameter, error) observation.
    ///
    /// Call this after every `evalFn` invocation to feed the surrogate model.
    /// Output normalisation (mean / std) is updated incrementally.
    public mutating func addObservation(x: [Double], y: Double) {
        _xsOrig.append(x)
        _ys.append(y)
        _xsNorm.append(_normX(x))

        if y < _bestY { _bestY = y; _bestX = x }

        // Running output normalisation
        let n      = Double(_ys.count)
        _yMean     = _ys.reduce(0, +) / n
        let var_   = _ys.reduce(0.0) { $0 + ($1 - _yMean) * ($1 - _yMean) }
                     / max(n - 1.0, 1.0)
        _yStd      = max(sqrt(var_), 1e-6)
        _ysNorm    = _ys.map { ($0 - _yMean) / _yStd }

        _gpFitted  = false
        _sinceRefit += 1
    }

    // MARK: - Hyperparameter optimisation  (random search, log-space)

    private mutating func _refitHyp() {
        let nObs = _xsNorm.count
        guard nObs >= 3 else { return }

        // Keep the current hyps as baseline
        var bestLML = _lml(xs: _xsNorm, ys: _ysNorm, hyp: _hyp)
        var bestHyp = _hyp

        // Number of restarts shrinks with n to keep runtime bounded
        let nR   = max(10, min(30, 300 / nObs))
        var rng  = _RNG(seed: _seed &+ 0xDEAD_BEEF)

        for _ in 0..<nR {
            let logSF = -1.5 + 3.0 * rng.next01()    // σ_f ∈ [0.22, 4.5]
            let logSN = -6.0 + 4.0 * rng.next01()    // σ_n ∈ [0.002, 0.37]
            var ls    = [Double](repeating: 0.0, count: ndim)
            for d in 0..<ndim {
                ls[d] = exp(-2.5 + 2.5 * rng.next01())   // l ∈ [0.08, 1.0]
            }
            let hyp  = _GPHyp(sf2: exp(2.0 * logSF), sn2: exp(2.0 * logSN), ls: ls)
            let lml  = _lml(xs: _xsNorm, ys: _ysNorm, hyp: hyp)
            if lml > bestLML { bestLML = lml; bestHyp = hyp }
        }
        _hyp        = bestHyp
        _sinceRefit = 0
    }

    // MARK: - GP fit  (Cholesky + α = K⁻¹ y)

    private mutating func _fitGP() {
        let n = _xsNorm.count
        guard n >= 2 else { _gpFitted = false; return }

        if !_gpFitted || _sinceRefit >= refitEvery { _refitHyp() }

        // Build K with adaptive jitter for numerical stability
        var jitter = _hyp.sn2
        for attempt in 0...5 {
            if attempt > 0 { jitter *= 10.0 }
            var K = [Double](repeating: 0.0, count: n * n)
            for i in 0..<n {
                for j in 0...i {
                    var v = _rbf(_xsNorm[i], _xsNorm[j], sf2: _hyp.sf2, ls: _hyp.ls)
                    if i == j { v += jitter }
                    K[i * n + j] = v; K[j * n + i] = v
                }
            }
            if let L = _chol(K, n: n) {
                _L        = L
                _alpha    = _cholSolve(L, _ysNorm, n: n)
                _gpFitted = true
                return
            }
        }
        _gpFitted = false
    }

    // MARK: - GP prediction at a normalised point

    private func _predict(xn: [Double]) -> (mu: Double, sigma: Double) {
        let n = _xsNorm.count
        guard _gpFitted, n > 0 else { return (0.0, 1.0) }

        // k* = [k(x*, xᵢ)]
        let kstar = (0..<n).map { _rbf(xn, _xsNorm[$0], sf2: _hyp.sf2, ls: _hyp.ls) }

        // μ* = k*ᵀ α
        let mu = zip(kstar, _alpha).reduce(0.0) { $0 + $1.0 * $1.1 }

        // σ²* = k(x*,x*) − vᵀv,   v = L⁻¹ k*
        let v   = _fwd(_L, kstar, n: n)
        let var_ = max(_hyp.sf2 - v.reduce(0.0) { $0 + $1 * $1 }, _hyp.sn2)
        return (mu, sqrt(var_))
    }

    // MARK: - Expected Improvement  (minimisation, ξ = 0.01)

    @inline(__always)
    private func _EI(mu: Double, sigma: Double, fBestNorm: Double) -> Double {
        let xi  = 0.01
        guard sigma > 1e-10 else { return 0.0 }
        let z   = (fBestNorm - mu - xi) / sigma
        return max(0.0, (fBestNorm - mu - xi) * _Phi(z) + sigma * _phi(z))
    }

    // MARK: - Next candidate

    /// Returns the next parameter vector to evaluate.
    ///
    /// - During warm-up (`observationCount < warmupCount`): returns the
    ///   next pre-generated Latin Hypercube point (space-filling coverage).
    /// - After warm-up: fits the GP, maximises EI over `acquisitionSamples`
    ///   LHS candidates, and returns the argmax.
    public mutating func nextCandidate() -> [Double] {
        _seed &+= 1

        // ── Warm-up: return pre-generated LHS points in order ─────────────
        let idx = _xsNorm.count
        if idx < warmupCount {
            return _warmupXs[min(idx, _warmupXs.count - 1)]
        }

        // ── BO: GP + EI ───────────────────────────────────────────────────
        _fitGP()

        guard _gpFitted, _bestY < .infinity else {
            // Fallback: random uniform point
            var rng = _RNG(seed: _seed)
            return (0..<ndim).map { i in
                bounds[i].lo + rng.next01() * (bounds[i].hi - bounds[i].lo)
            }
        }

        let fBestNorm = (_bestY - _yMean) / _yStd
        let cands     = _lhs(ndim: ndim, nsamples: acquisitionSamples, seed: _seed)

        var bestEI = -1.0
        var bestXn = cands[0]
        for xn in cands {
            let (mu, sigma) = _predict(xn: xn)
            let ei = _EI(mu: mu, sigma: sigma, fBestNorm: fBestNorm)
            if ei > bestEI { bestEI = ei; bestXn = xn }
        }
        return _denormX(bestXn)
    }

    // MARK: - Public state

    public var observationCount: Int  { _xsNorm.count }
    public var isInWarmup:       Bool { _xsNorm.count < warmupCount }
    public var bestParams:   [Double] { _bestX }
    public var bestError:     Double  { _bestY }

    // MARK: - ARD identifiability

    /// True once the GP surrogate has been fitted at least once (post warm-up),
    /// so the length scales below reflect the data rather than the prior.
    public var hasFittedGP: Bool { _gpFitted }

    /// Per-parameter ARD length scales in normalised input space ([0,1] per dim).
    /// Shorter ⇒ the objective changes rapidly along that parameter ⇒ the
    /// parameter is well constrained.  Longer (≳1) ⇒ a near-flat ("sloppy")
    /// direction the data cannot pin down.  Meaningful only when `hasFittedGP`.
    public var lengthScales: [Double] { _hyp.ls }

    /// Relative parameter relevance derived from ARD: (1/lₖ) normalised so the
    /// most influential parameter = 1.0.  High ⇒ the objective is sensitive to
    /// this parameter (identifiable); low ⇒ a flat direction the fit cannot
    /// constrain.  Empty until the GP is fitted.
    public var parameterRelevance: [Double] {
        guard _gpFitted, !_hyp.ls.isEmpty else { return [] }
        let inv = _hyp.ls.map { 1.0 / max($0, 1e-9) }
        let mx  = inv.max() ?? 1.0
        return mx > 1e-12 ? inv.map { $0 / mx } : inv
    }
}
