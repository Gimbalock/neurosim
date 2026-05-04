//
//  CurveFitter.swift
//  NeuroSimCore
//
//  Least-squares fitters for the two `GateCurve` parameterisations.
//
//   - `fitSigmoid` runs a small Gauss-Newton loop on the 4-parameter
//     logistic. Convergence is robust for clean data with a sensible
//     initial guess (we seed from the data extrema and a slope estimate
//     at the midpoint). The Jacobian is computed analytically.
//
//   - `fitPolynomial` is closed-form: linear least squares via the
//     normal equations Mᵀ M c = Mᵀ y, solved with Gauss-Jordan with
//     partial pivoting. Voltages are centred on their mean for
//     conditioning.
//
//  Both fitters are pure functions of the input points and return a
//  `GateCurve` ready to plug into a channel's override slot.
//

import Foundation

public enum CurveFitter {

    public typealias Point = (v: Double, y: Double)

    // MARK: - Sigmoid fit (Gauss-Newton)

    /// Fit a 4-parameter logistic to `points` by Gauss-Newton iterations.
    /// Returns `nil` if the input is degenerate (fewer than 4 points,
    /// all-same V, all-same y, or convergence failure).
    public static func fitSigmoid(points: [Point],
                                  maxIterations: Int = 40,
                                  tolerance: Double = 1e-9) -> GateCurve?
    {
        guard points.count >= 4 else { return nil }

        // Initial guess from data extrema + a slope estimate.
        let ys = points.map(\.y)
        let vs = points.map(\.v)
        guard let yMin = ys.min(), let yMax = ys.max(),
              let vMin = vs.min(), let vMax = vs.max(),
              abs(yMax - yMin) > 1e-9, abs(vMax - vMin) > 1e-9
        else { return nil }

        var lo = yMin
        var hi = yMax
        // Estimate vHalf as the V at which y is closest to (lo+hi)/2.
        let yMid = 0.5 * (lo + hi)
        let vHalfSeed = points.min { abs($0.y - yMid) < abs($1.y - yMid) }!.v
        var vHalf = vHalfSeed
        // Sign of slope from endpoints' ordering. Ascending data → k > 0.
        let sortedByV = points.sorted { $0.v < $1.v }
        let kSign: Double = sortedByV.last!.y >= sortedByV.first!.y ? 1 : -1
        // Magnitude of k ≈ (vMax - vMin) / 8 by analogy with HH curves.
        var k = kSign * max((vMax - vMin) / 8.0, 1e-3)

        // Gauss-Newton loop on parameters θ = (lo, hi, vHalf, k).
        for _ in 0..<maxIterations {
            // Build residuals r_i = y_i − f(v_i; θ) and Jacobian J (n×4).
            let n = points.count
            var r = [Double](repeating: 0, count: n)
            // J flattened row-major.
            var J = [Double](repeating: 0, count: n * 4)

            for i in 0..<n {
                let v = points[i].v
                let y = points[i].y
                // Evaluate f and partial derivatives.
                let z = -(v - vHalf) / k
                // Use a numerically stable sigmoid σ(−z) = 1/(1+exp(z))
                // here we want s = 1 / (1 + exp(z))
                let s: Double
                if z >= 0 {
                    let e = exp(-z); s = e / (1.0 + e)
                } else {
                    s = 1.0 / (1.0 + exp(z))
                }
                let f = lo + (hi - lo) * s
                r[i] = y - f
                // Partial derivatives:
                //   ∂f/∂lo   = 1 − s
                //   ∂f/∂hi   = s
                //   ∂f/∂vHalf= (hi − lo) · s · (1 − s) · (−1/k) · (−1)
                //            = (hi − lo) · s(1−s) / k
                //   ∂f/∂k    = (hi − lo) · s · (1 − s) · (V − vHalf) / k²
                let s1 = s * (1 - s)
                let dV = v - vHalf
                let span = hi - lo
                // Partials of f(V) = lo + (hi − lo) · σ((V − V½)/k):
                //   ∂f/∂lo    = 1 − σ
                //   ∂f/∂hi    = σ
                //   ∂f/∂vHalf = −(hi − lo) · σ(1−σ) / k        ← negative
                //   ∂f/∂k     = −(hi − lo) · σ(1−σ) · (V − V½) / k²  ← negative
                // The sign on the last two comes from V½ and k both
                // appearing in the negative position inside the logistic
                // argument. Getting these wrong drives Gauss-Newton in the
                // opposite direction and the iteration collapses lo→hi,
                // turning the fit into a flat horizontal line.
                J[i * 4 + 0] =  1 - s
                J[i * 4 + 1] =  s
                J[i * 4 + 2] = -span * s1 / k
                J[i * 4 + 3] = -span * s1 * dV / (k * k)
            }

            // Normal equations:  (Jᵀ J) δ = Jᵀ r .
            var JtJ = [Double](repeating: 0, count: 16)
            var Jtr = [Double](repeating: 0, count: 4)
            for i in 0..<n {
                for a in 0..<4 {
                    Jtr[a] += J[i * 4 + a] * r[i]
                    for b in 0..<4 {
                        JtJ[a * 4 + b] += J[i * 4 + a] * J[i * 4 + b]
                    }
                }
            }
            // Levenberg-style damping on the diagonal — keeps the system
            // well-conditioned even when the Jacobian column for `k` (or
            // the asymptotes) becomes nearly collinear far from the
            // optimum. Scaled by the current trace of `JtJ` so the
            // damping is meaningful relative to the problem.
            let trace = JtJ[0] + JtJ[5] + JtJ[10] + JtJ[15]
            let lambda = max(1e-9, 1e-6 * trace)
            for a in 0..<4 { JtJ[a * 4 + a] += lambda }

            guard let delta = Self.solve4x4(matrix: JtJ, rhs: Jtr) else {
                return nil
            }
            lo    += delta[0]
            hi    += delta[1]
            vHalf += delta[2]
            k     += delta[3]

            // Stop when the parameter change is tiny (convergence).
            let stepNorm = sqrt(delta.reduce(0) { $0 + $1 * $1 })
            let scale    = max(1.0, sqrt(lo * lo + hi * hi + vHalf * vHalf + k * k))
            if stepNorm / scale < tolerance { break }

            // Sanity guard: keep |k| from collapsing to zero.
            if abs(k) < 1e-9 { k = (k >= 0 ? 1 : -1) * 1e-9 }
        }

        // Restrict the fitted curve to the voltage span of the input
        // points. Outside this range the override is treated as
        // undefined and the channel's built-in formula takes over —
        // protects against the user editing only a small voltage band
        // and the simulation later drifting outside it.
        let domain = vMin...vMax
        return .sigmoid(lo: lo, hi: hi, vHalf: vHalf, k: k, domain: domain)
    }

    // MARK: - Polynomial fit (closed-form linear LSQ)

    /// Least-squares polynomial fit of `degree` to `points`, expressed
    /// in centred coordinates (V − mean(V)) for numerical stability.
    /// Requires `points.count > degree`. Returns `nil` if the system is
    /// rank-deficient or singular.
    public static func fitPolynomial(points: [Point],
                                     degree: Int) -> GateCurve?
    {
        guard degree >= 0, points.count > degree else { return nil }
        let n = points.count
        let p = degree + 1
        let vCenter = points.map(\.v).reduce(0, +) / Double(n)

        // Build M (n × p) where M[i, j] = (V_i − vCenter)^j.
        var M = [Double](repeating: 0, count: n * p)
        for i in 0..<n {
            let u = points[i].v - vCenter
            var pow_u = 1.0
            for j in 0..<p {
                M[i * p + j] = pow_u
                pow_u *= u
            }
        }
        let y = points.map(\.y)

        // Mᵀ M (p × p), Mᵀ y (p).
        var MtM = [Double](repeating: 0, count: p * p)
        var Mty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            for a in 0..<p {
                Mty[a] += M[i * p + a] * y[i]
                for b in 0..<p {
                    MtM[a * p + b] += M[i * p + a] * M[i * p + b]
                }
            }
        }
        // Tikhonov-light: tiny regulariser for stability.
        for a in 0..<p { MtM[a * p + a] += 1e-12 }

        guard let coefficients = Self.solveLinearSystem(matrix: MtM,
                                                        rhs: Mty,
                                                        size: p)
        else { return nil }

        // Crucial for polynomials: clamp the validity domain to the
        // input points' voltage span. Polynomials are notoriously
        // wild outside the data they're fitted on (Runge phenomenon).
        let vs = points.map(\.v)
        let domain = vs.min()!...vs.max()!
        return .polynomial(coefficients: coefficients,
                           vCenter: vCenter,
                           domain: domain)
    }

    // MARK: - Linear algebra helpers

    /// Specialised solver for the 4×4 systems coming out of the sigmoid
    /// Gauss-Newton step. Wraps the generic solver below.
    private static func solve4x4(matrix: [Double], rhs: [Double]) -> [Double]? {
        return solveLinearSystem(matrix: matrix, rhs: rhs, size: 4)
    }

    /// Solve A x = b by Gauss-Jordan with partial pivoting.
    /// `matrix` is row-major n × n, `rhs` length n.
    /// Returns `nil` if A is singular.
    private static func solveLinearSystem(matrix: [Double],
                                          rhs: [Double],
                                          size n: Int) -> [Double]?
    {
        var A = matrix
        var b = rhs
        for col in 0..<n {
            // Partial pivot: find the row in [col, n) with the largest |A[r, col]|.
            var pivotRow = col
            var pivotVal = abs(A[col * n + col])
            for r in (col + 1)..<n {
                let v = abs(A[r * n + col])
                if v > pivotVal { pivotVal = v; pivotRow = r }
            }
            if pivotVal < 1e-14 { return nil } // singular

            // Swap rows pivotRow ↔ col in both A and b.
            if pivotRow != col {
                for c in 0..<n {
                    A.swapAt(pivotRow * n + c, col * n + c)
                }
                b.swapAt(pivotRow, col)
            }

            // Normalise pivot row.
            let pivot = A[col * n + col]
            for c in col..<n { A[col * n + c] /= pivot }
            b[col] /= pivot

            // Eliminate column `col` from every other row.
            for r in 0..<n where r != col {
                let factor = A[r * n + col]
                if factor == 0 { continue }
                for c in col..<n {
                    A[r * n + c] -= factor * A[col * n + c]
                }
                b[r] -= factor * b[col]
            }
        }
        return b
    }
}
