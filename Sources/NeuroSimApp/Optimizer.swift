//
//  Optimizer.swift
//  NeuroSimApp
//
//  Pure-math optimizer structs (no SwiftUI, no NeuroSimCore).
//  Two-phase API: generateCandidates() then applyResults() so the
//  caller can await Task.yield() between individual evaluations,
//  keeping the main-thread UI responsive.
//

import Foundation

// MARK: - Config

enum OptimizerAlgorithm: String, CaseIterable, Identifiable {
    case differentialEvolution = "Differential Evolution"
    case cmaes                 = "CMA-ES"
    var id: String { rawValue }
    var shortName: String { self == .differentialEvolution ? "DE" : "CMA-ES" }
}

struct OptimConfig: Equatable {
    var algorithm:      OptimizerAlgorithm = .differentialEvolution
    var maxIterations:  Int    = 150
    var targetError:    Double = 1e-7
    var simDuration:    Double = 800    // ms per evaluation
    // DE
    var deF:            Double = 0.8
    var deCR:           Double = 0.9
    var dePopFactor:    Int    = 6      // popSize = max(10, factor × n)
    // CMA-ES
    var cmaeSigma0:     Double = 0.25   // fraction of param range
}

struct OptimizerStep {
    let bestParams: [Double]
    let bestError:  Double
    let generation: Int
}

// MARK: - Differential Evolution  (DE/rand/1/bin)

struct DifferentialEvolution {
    let bounds:  [(lo: Double, hi: Double)]
    var F:       Double
    var CR:      Double
    private let n: Int
    private(set) var population: [[Double]]
    private(set) var fitness:    [Double]
    private(set) var generation  = 0

    init(bounds: [(lo: Double, hi: Double)],
         popFactor: Int = 6,
         F: Double = 0.8,
         CR: Double = 0.9) {
        self.bounds = bounds
        self.F  = F
        self.CR = CR
        self.n  = bounds.count
        let sz  = max(10, popFactor * bounds.count)
        self.population = (0..<sz).map { _ in bounds.map { b in .random(in: b.lo...b.hi) } }
        self.fitness    = [Double](repeating: .infinity, count: sz)
    }

    var popSize: Int { population.count }

    /// All initial candidates (call once before first step).
    func initialCandidates() -> [[Double]] { population }

    mutating func setInitialFitness(_ values: [Double]) {
        fitness = values
    }

    /// Generate trial vectors for one generation.
    func generateTrials() -> [[Double]] {
        (0..<popSize).map { i in
            let others = (0..<popSize).filter { $0 != i }.shuffled()
            let (a, b, c) = (population[others[0]], population[others[1]], population[others[2]])
            let mutant = (0..<n).map { j in (a[j] + F*(b[j]-c[j])).clamped(to: bounds[j].lo...bounds[j].hi) }
            let jRand = Int.random(in: 0..<n)
            var trial = population[i]
            for j in 0..<n where j == jRand || .random(in: 0.0...1.0) < CR { trial[j] = mutant[j] }
            return trial
        }
    }

    /// Apply selection from evaluated trials. Returns current best.
    mutating func applyTrials(_ trials: [[Double]], errors: [Double]) -> OptimizerStep {
        for i in 0..<popSize where errors[i] <= fitness[i] {
            population[i] = trials[i]
            fitness[i]    = errors[i]
        }
        generation += 1
        let bi = fitness.indices.min(by: { fitness[$0] < fitness[$1] })!
        return OptimizerStep(bestParams: population[bi], bestError: fitness[bi], generation: generation)
    }
}

// MARK: - CMA-ES  (Hansen 2016 tutorial, full update)

struct CMAES {
    let bounds:  [(lo: Double, hi: Double)]
    let n:       Int
    let lambda:  Int
    let mu:      Int
    let weights: [Double]
    let muEff:   Double
    // Adaptation constants
    let cc, c1, cmu, csigma, dsigma, chiN: Double
    // State
    private(set) var m:     [Double]
    private(set) var sigma: Double
    private var pc:    [Double]
    private var psigma:[Double]
    private var C:     [[Double]]
    private var B:     [[Double]]   // columns = eigenvectors of C
    private var D:     [Double]     // D[i] = sqrt(eigenvalue i)
    private(set) var generation = 0

    init(bounds: [(lo: Double, hi: Double)], sigma0fraction: Double = 0.25) {
        let n      = bounds.count
        let lambda = max(6, 4 + Int(3 * log(Double(n))))
        let mu     = lambda / 2
        var w      = (1...mu).map { i in log(Double(mu) + 0.5) - log(Double(i)) }
        let sumW   = w.reduce(0, +); w = w.map { $0 / sumW }
        let muEff  = 1.0 / w.map { $0*$0 }.reduce(0, +)
        let fn     = Double(n)
        let cc     = (4 + muEff/fn) / (fn + 4 + 2*muEff/fn)
        let c1     = 2 / ((fn+1.3)*(fn+1.3) + muEff)
        let cmu    = min(1-c1, 2*(muEff-2+1/muEff) / ((fn+2)*(fn+2) + muEff))
        let csig   = (muEff+2) / (fn+muEff+5)
        let dsig   = 1 + 2*max(0, sqrt((muEff-1)/(fn+1))-1) + csig
        let chiN   = sqrt(fn) * (1 - 1/(4*fn) + 1/(21*fn*fn))
        self.bounds  = bounds; self.n = n; self.lambda = lambda; self.mu = mu
        self.weights = w; self.muEff = muEff
        self.cc = cc; self.c1 = c1; self.cmu = cmu
        self.csigma = csig; self.dsigma = dsig; self.chiN = chiN
        // Initial state: midpoint of bounds, spherical covariance
        let ranges  = bounds.map { $0.hi - $0.lo }
        self.m      = bounds.map { ($0.lo + $0.hi)/2 }
        self.sigma  = sigma0fraction * (ranges.reduce(0,+)/Double(n))
        self.pc     = [Double](repeating: 0, count: n)
        self.psigma = [Double](repeating: 0, count: n)
        self.C      = matIdentity(n)
        self.B      = matIdentity(n)
        self.D      = [Double](repeating: 1, count: n)
    }

    /// Struct holding one sampled offspring (separating z/y/x for the CMA-ES update)
    struct Offspring {
        let x: [Double]   // actual point (clamped to bounds)
        let y: [Double]   // step in C-space:  x = m + sigma * y
        let z: [Double]   // isotropic sample:  y = B @ diag(D) @ z
    }

    func generateOffspring() -> [Offspring] {
        (0..<lambda).map { _ in
            let z   = (0..<n).map { _ in normalRandom() }
            let Dz  = (0..<n).map { j in D[j] * z[j] }
            let y   = matVec(B, Dz)
            let raw = (0..<n).map { j in m[j] + sigma * y[j] }
            let x   = (0..<n).map { j in raw[j].clamped(to: bounds[j].lo...bounds[j].hi) }
            return Offspring(x: x, y: y, z: z)
        }
    }

    mutating func applyOffspring(_ offspring: [Offspring], errors: [Double]) -> OptimizerStep {
        // Sort by fitness
        let ranked = zip(offspring, errors).sorted { $0.1 < $1.1 }
        let best   = ranked[0]

        let mOld = m

        // Update mean (weighted combination of top-mu)
        m = (0..<n).map { j in
            (0..<mu).reduce(0.0) { acc, i in acc + weights[i] * ranked[i].0.x[j] }
        }

        // Cumulative step-size adaptation (CSA)
        let zW  = (0..<n).map { j in (0..<mu).reduce(0.0) { $0 + weights[$1]*ranked[$1].0.z[j] } }
        let BzW = matVec(B, zW)
        let kSig = sqrt(csigma*(2-csigma)*muEff)
        psigma = (0..<n).map { j in (1-csigma)*psigma[j] + kSig*BzW[j] }
        let pSigNorm = sqrt(psigma.map { $0*$0 }.reduce(0,+))
        sigma = (sigma * exp((csigma/dsigma) * (pSigNorm/chiN - 1))).clamped(to: 1e-10...1e6)

        // Covariance matrix adaptation (CMA)
        let hThresh = (1.4 + 2/(Double(n)+1)) * chiN
        let pSigNormAdj = pSigNorm / sqrt(1 - pow(1-csigma, 2*Double(generation+1)))
        let hSig: Double = pSigNormAdj < hThresh ? 1 : 0
        let dm = (0..<n).map { j in (m[j]-mOld[j])/sigma }
        let kC = sqrt(cc*(2-cc)*muEff)
        pc = (0..<n).map { j in (1-cc)*pc[j] + hSig*kC*dm[j] }

        let deltaH   = (1-hSig)*cc*(2-cc)
        let cScale   = max(0, 1 - c1 - cmu + deltaH)
        let rank1    = matScale(matOuter(pc, pc), c1)
        let rankMu   = matScale(
            (0..<mu).reduce(matZero(n)) { acc, i in
                matAdd(acc, matScale(matOuter(ranked[i].0.y, ranked[i].0.y), weights[i]))
            }, cmu)
        C = matSymmetrise(matAdd(matAdd(matScale(C, cScale), rank1), rankMu))

        // Eigendecomposition (every generation; cheap for small n)
        let (eigVals, eigVecs) = jacobiEigen(C)
        D = eigVals.map { sqrt(max($0, 1e-20)) }
        B = eigVecs

        generation += 1
        return OptimizerStep(bestParams: best.0.x, bestError: best.1, generation: generation)
    }
}

// MARK: - Matrix helpers (small symmetric matrices, no external dependencies)

private func matIdentity(_ n: Int) -> [[Double]] {
    (0..<n).map { i in (0..<n).map { j in i==j ? 1.0 : 0.0 } }
}
private func matZero(_ n: Int) -> [[Double]] {
    (0..<n).map { _ in [Double](repeating: 0, count: n) }
}
private func matVec(_ A: [[Double]], _ v: [Double]) -> [Double] {
    let n = v.count
    return (0..<n).map { i in (0..<n).reduce(0.0) { $0 + A[i][$1]*v[$1] } }
}
private func matOuter(_ a: [Double], _ b: [Double]) -> [[Double]] {
    (0..<a.count).map { i in (0..<b.count).map { j in a[i]*b[j] } }
}
private func matScale(_ A: [[Double]], _ s: Double) -> [[Double]] {
    A.map { $0.map { $0*s } }
}
private func matAdd(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
    (0..<A.count).map { i in (0..<A[i].count).map { j in A[i][j]+B[i][j] } }
}
private func matSymmetrise(_ A: [[Double]]) -> [[Double]] {
    let n = A.count
    return (0..<n).map { i in (0..<n).map { j in (A[i][j]+A[j][i])/2 } }
}

// Jacobi iterative eigendecomposition for symmetric matrix.
// Returns (eigenvalues, eigenvector matrix B) where B[:,j] is the j-th eigenvector.
private func jacobiEigen(_ A: [[Double]]) -> ([Double], [[Double]]) {
    let n = A.count
    var a = A
    var V = matIdentity(n)

    for _ in 0..<200 {
        // Find max off-diagonal element
        var maxVal = 0.0; var p = 0; var q = 1
        for i in 0..<n { for j in i+1..<n { if abs(a[i][j]) > maxVal { maxVal = abs(a[i][j]); p=i; q=j } } }
        if maxVal < 1e-12 { break }

        // Rotation angle
        let theta = (a[q][q] - a[p][p]) / (2*a[p][q])
        let t: Double = theta >= 0
            ?  1.0/(theta + sqrt(1+theta*theta))
            :  1.0/(theta - sqrt(1+theta*theta))
        let c = 1/sqrt(1+t*t); let s = t*c

        // Update A
        let app = a[p][p]; let aqq = a[q][q]; let apq = a[p][q]
        a[p][p] = c*c*app - 2*s*c*apq + s*s*aqq
        a[q][q] = s*s*app + 2*s*c*apq + c*c*aqq
        a[p][q] = 0; a[q][p] = 0
        for i in 0..<n where i != p && i != q {
            let aip = a[i][p]; let aiq = a[i][q]
            a[i][p] = c*aip - s*aiq; a[p][i] = a[i][p]
            a[i][q] = s*aip + c*aiq; a[q][i] = a[i][q]
        }
        // Accumulate eigenvectors (columns)
        for i in 0..<n {
            let vip = V[i][p]; let viq = V[i][q]
            V[i][p] = c*vip - s*viq
            V[i][q] = s*vip + c*viq
        }
    }
    return ((0..<n).map { a[$0][$0] }, V)
}

// Box-Muller standard normal sample
private func normalRandom() -> Double {
    let u1 = max(Double.random(in: 0...1), 1e-300)
    let u2 =     Double.random(in: 0...1)
    return sqrt(-2*log(u1)) * cos(2 * .pi * u2)
}

// MARK: - Clamp extension

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
