//
//  Optimizers.swift
//  NeuroSimCore
//
//  Pure-math optimizer structs — no SwiftUI, no UI dependencies.
//  Lives in NeuroSimCore so it is accessible to both NeuroSimApp and
//  the test target (NeuroSimCoreTests) without duplication.
//
//  Two-phase API: generateCandidates() then applyResults() so the
//  caller can await Task.yield() between individual evaluations.
//

import Foundation

// MARK: - Algorithm enum + config

public enum OptimizerAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case differentialEvolution = "Differential Evolution"
    case cmaes                 = "CMA-ES"
    case beeColony             = "Bee Colony (ABC)"
    case bayesian              = "Optimisation Bayésienne"
    public var id: String { rawValue }
    public var shortName: String {
        switch self {
        case .differentialEvolution: return "DE"
        case .cmaes:                 return "CMA-ES"
        case .beeColony:             return "ABC"
        case .bayesian:              return "GP-BO"
        }
    }
}

public struct OptimConfig: Equatable, Sendable {
    public var algorithm:      OptimizerAlgorithm = .differentialEvolution
    public var maxIterations:  Int    = 150
    public var targetError:    Double = 1e-7
    public var simDuration:    Double = 800    // ms per evaluation
    // DE
    public var deF:            Double = 0.8
    public var deCR:           Double = 0.9
    public var dePopFactor:    Int    = 6      // popSize = max(10, factor × n)
    // CMA-ES
    public var cmaeSigma0:     Double = 0.25   // fraction of param range
    // ABC
    public var abcColonySize:     Int  = 15    // number of food sources (employed bees)
    public var abcTabuEnabled:    Bool = true  // enable tabu list to escape local minima
    public var abcTabuStagnation: Int  = 25    // generations without improvement → add to tabu
    // Scoring
    /// Weight for the firing-rate mismatch term in `chiSquaredScore`.
    /// 0 = disabled (pure PPTD χ²).  Suggested: 0.2–0.5 for HH conductance fitting.
    public var scoringLambdaISI:     Double = 0.0
    /// Gaussian smoothing radius applied to the phase-plane density grid (bins).
    /// 0 = disabled (recommended — preserves sensitivity to resting potential etc.)
    public var scoringGridSmoothing: Int    = 0
    // GP-BO
    /// Number of Latin Hypercube evaluations before the GP surrogate takes over.
    /// Rule of thumb: 5 × n_params.  Range: [3, 20].
    public var boWarmup: Int = 8

    public init() {}
}

public struct OptimizerStep: Sendable {
    public let bestParams: [Double]
    public let bestError:  Double
    public let generation: Int
}

// MARK: - Differential Evolution  (DE/rand/1/bin)

public struct DifferentialEvolution: Sendable {
    public let bounds:  [(lo: Double, hi: Double)]
    public var F:       Double
    public var CR:      Double
    private let n: Int
    public private(set) var population: [[Double]]
    public private(set) var fitness:    [Double]
    public private(set) var generation  = 0

    public init(bounds: [(lo: Double, hi: Double)],
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

    public var popSize: Int { population.count }

    /// All initial candidates (call once before first step).
    public func initialCandidates() -> [[Double]] { population }

    public mutating func setInitialFitness(_ values: [Double]) {
        fitness = values
    }

    /// Generate trial vectors for one generation.
    public func generateTrials() -> [[Double]] {
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
    public mutating func applyTrials(_ trials: [[Double]], errors: [Double]) -> OptimizerStep {
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

public struct CMAES: Sendable {
    public let bounds:  [(lo: Double, hi: Double)]
    public let n:       Int
    public let lambda:  Int
    public let mu:      Int
    public let weights: [Double]
    public let muEff:   Double
    // Adaptation constants
    public let cc, c1, cmu, csigma, dsigma, chiN: Double
    // State
    public private(set) var m:     [Double]
    public private(set) var sigma: Double
    private var pc:    [Double]
    private var psigma:[Double]
    private var C:     [[Double]]
    private var B:     [[Double]]   // columns = eigenvectors of C
    private var D:     [Double]     // D[i] = sqrt(eigenvalue i)
    public private(set) var generation = 0

    public init(bounds: [(lo: Double, hi: Double)], sigma0fraction: Double = 0.25) {
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
        self.C      = _matIdentity(n)
        self.B      = _matIdentity(n)
        self.D      = [Double](repeating: 1, count: n)
    }

    /// One sampled offspring (z/y/x separated for the CMA-ES update).
    public struct Offspring: Sendable {
        public let x: [Double]   // actual point (clamped to bounds)
        public let y: [Double]   // step in C-space:  x = m + sigma * y
        public let z: [Double]   // isotropic sample:  y = B @ diag(D) @ z
    }

    public func generateOffspring() -> [Offspring] {
        (0..<lambda).map { _ in
            let z   = (0..<n).map { _ in _normalRandom() }
            let Dz  = (0..<n).map { j in D[j] * z[j] }
            let y   = _matVec(B, Dz)
            let raw = (0..<n).map { j in m[j] + sigma * y[j] }
            let x   = (0..<n).map { j in raw[j].clamped(to: bounds[j].lo...bounds[j].hi) }
            return Offspring(x: x, y: y, z: z)
        }
    }

    public mutating func applyOffspring(_ offspring: [Offspring], errors: [Double]) -> OptimizerStep {
        let ranked = zip(offspring, errors).sorted { $0.1 < $1.1 }
        let best   = ranked[0]
        let mOld = m
        m = (0..<n).map { j in
            (0..<mu).reduce(0.0) { acc, i in acc + weights[i] * ranked[i].0.x[j] }
        }
        let zW  = (0..<n).map { j in (0..<mu).reduce(0.0) { $0 + weights[$1]*ranked[$1].0.z[j] } }
        let BzW = _matVec(B, zW)
        let kSig = sqrt(csigma*(2-csigma)*muEff)
        psigma = (0..<n).map { j in (1-csigma)*psigma[j] + kSig*BzW[j] }
        let pSigNorm = sqrt(psigma.map { $0*$0 }.reduce(0,+))
        sigma = (sigma * exp((csigma/dsigma) * (pSigNorm/chiN - 1))).clamped(to: 1e-10...1e6)
        let hThresh = (1.4 + 2/(Double(n)+1)) * chiN
        let pSigNormAdj = pSigNorm / sqrt(1 - pow(1-csigma, 2*Double(generation+1)))
        let hSig: Double = pSigNormAdj < hThresh ? 1 : 0
        let dm = (0..<n).map { j in (m[j]-mOld[j])/sigma }
        let kC = sqrt(cc*(2-cc)*muEff)
        pc = (0..<n).map { j in (1-cc)*pc[j] + hSig*kC*dm[j] }
        let deltaH   = (1-hSig)*cc*(2-cc)
        let cScale   = max(0, 1 - c1 - cmu + deltaH)
        let rank1    = _matScale(_matOuter(pc, pc), c1)
        let rankMu   = _matScale(
            (0..<mu).reduce(_matZero(n)) { acc, i in
                _matAdd(acc, _matScale(_matOuter(ranked[i].0.y, ranked[i].0.y), weights[i]))
            }, cmu)
        C = _matSymmetrise(_matAdd(_matAdd(_matScale(C, cScale), rank1), rankMu))
        let (eigVals, eigVecs) = _jacobiEigen(C)
        D = eigVals.map { sqrt(max($0, 1e-20)) }
        B = eigVecs
        generation += 1
        return OptimizerStep(bestParams: best.0.x, bestError: best.1, generation: generation)
    }
}

// MARK: - Matrix helpers (internal, prefixed to avoid future naming conflicts)

func _matIdentity(_ n: Int) -> [[Double]] {
    (0..<n).map { i in (0..<n).map { j in i==j ? 1.0 : 0.0 } }
}
func _matZero(_ n: Int) -> [[Double]] {
    (0..<n).map { _ in [Double](repeating: 0, count: n) }
}
func _matVec(_ A: [[Double]], _ v: [Double]) -> [Double] {
    let n = v.count
    return (0..<n).map { i in (0..<n).reduce(0.0) { $0 + A[i][$1]*v[$1] } }
}
func _matOuter(_ a: [Double], _ b: [Double]) -> [[Double]] {
    (0..<a.count).map { i in (0..<b.count).map { j in a[i]*b[j] } }
}
func _matScale(_ A: [[Double]], _ s: Double) -> [[Double]] {
    A.map { $0.map { $0*s } }
}
func _matAdd(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
    (0..<A.count).map { i in (0..<A[i].count).map { j in A[i][j]+B[i][j] } }
}
func _matSymmetrise(_ A: [[Double]]) -> [[Double]] {
    let n = A.count
    return (0..<n).map { i in (0..<n).map { j in (A[i][j]+A[j][i])/2 } }
}

/// Jacobi iterative eigendecomposition for a symmetric matrix.
/// Returns (eigenvalues, eigenvector matrix V) where V[:,j] is the j-th eigenvector.
func _jacobiEigen(_ A: [[Double]]) -> ([Double], [[Double]]) {
    let n = A.count
    var a = A
    var V = _matIdentity(n)
    for _ in 0..<200 {
        var maxVal = 0.0; var p = 0; var q = 1
        for i in 0..<n { for j in i+1..<n { if abs(a[i][j]) > maxVal { maxVal = abs(a[i][j]); p=i; q=j } } }
        if maxVal < 1e-12 { break }
        let theta = (a[q][q] - a[p][p]) / (2*a[p][q])
        let t: Double = theta >= 0
            ? 1.0/(theta + sqrt(1+theta*theta))
            : 1.0/(theta - sqrt(1+theta*theta))
        let c = 1/sqrt(1+t*t); let s = t*c
        let app = a[p][p]; let aqq = a[q][q]; let apq = a[p][q]
        a[p][p] = c*c*app - 2*s*c*apq + s*s*aqq
        a[q][q] = s*s*app + 2*s*c*apq + c*c*aqq
        a[p][q] = 0; a[q][p] = 0
        for i in 0..<n where i != p && i != q {
            let aip = a[i][p]; let aiq = a[i][q]
            a[i][p] = c*aip - s*aiq; a[p][i] = a[i][p]
            a[i][q] = s*aip + c*aiq; a[q][i] = a[i][q]
        }
        for i in 0..<n {
            let vip = V[i][p]; let viq = V[i][q]
            V[i][p] = c*vip - s*viq
            V[i][q] = s*vip + c*viq
        }
    }
    return ((0..<n).map { a[$0][$0] }, V)
}

/// Box-Muller standard normal sample.
func _normalRandom() -> Double {
    let u1 = max(Double.random(in: 0...1), 1e-300)
    let u2 =     Double.random(in: 0...1)
    return sqrt(-2*log(u1)) * cos(2 * .pi * u2)
}

// MARK: - Artificial Bee Colony  (Karaboga 2005, + tabu extension from Frey et al.)

public struct ArtificialBeeColony: Sendable {
    public let bounds:          [(lo: Double, hi: Double)]
    public let limit:           Int
    public let tabuEnabled:     Bool
    public let tabuStagnation:  Int
    public let tabuRadius:      Double

    private let n:           Int
    public private(set) var sources:    [[Double]]
    public private(set) var fitness:    [Double]
    public private(set) var trials:     [Int]
    public private(set) var tabuList:   [[Double]]
    private var stagnationCount: Int
    public private(set) var generation: Int

    public var colonySize: Int { sources.count }

    public init(bounds:          [(lo: Double, hi: Double)],
                colonySize:      Int    = 15,
                limit:           Int?   = nil,
                tabuEnabled:     Bool   = true,
                tabuRadius:      Double = 0.05,
                tabuStagnation:  Int    = 25) {
        self.bounds         = bounds
        self.n              = bounds.count
        let sz              = max(4, colonySize)
        self.limit          = limit ?? sz * max(1, bounds.count)
        self.tabuEnabled    = tabuEnabled
        self.tabuRadius     = tabuRadius
        self.tabuStagnation = tabuStagnation
        self.sources        = (0..<sz).map { _ in bounds.map { b in .random(in: b.lo...b.hi) } }
        self.fitness        = [Double](repeating: .infinity, count: sz)
        self.trials         = [Int](repeating: 0, count: sz)
        self.tabuList       = []
        self.stagnationCount = 0
        self.generation     = 0
    }

    public func initialCandidates() -> [[Double]] { sources }

    public mutating func setInitialFitness(_ values: [Double]) {
        fitness = values
    }

    public func employedCandidates() -> [(sourceIdx: Int, candidate: [Double])] {
        (0..<colonySize).map { i in (sourceIdx: i, candidate: makeNeighbour(from: i)) }
    }

    public mutating func applyEmployed(sourceIdx i: Int, candidate: [Double], error: Double) {
        if error < fitness[i] {
            sources[i] = candidate; fitness[i] = error; trials[i] = 0
        } else {
            trials[i] += 1
        }
    }

    public func onlookerCandidates() -> [(sourceIdx: Int, candidate: [Double])] {
        let sel   = fitness.map { 1.0 / (1.0 + max(0.0, $0.isFinite ? $0 : 1e10)) }
        let total = sel.reduce(0.0, +)
        return (0..<colonySize).map { _ in
            let i = rouletteSelect(sel, total: total)
            return (sourceIdx: i, candidate: makeNeighbour(from: i))
        }
    }

    public mutating func applyOnlooker(sourceIdx i: Int, candidate: [Double], error: Double) {
        if error < fitness[i] {
            sources[i] = candidate; fitness[i] = error; trials[i] = 0
        } else {
            trials[i] += 1
        }
    }

    public mutating func finishGeneration(globalBestImproved: Bool,
                                          bestParams: [Double]) -> OptimizerStep {
        for i in 0..<colonySize where trials[i] > limit { reinitSource(i) }
        if tabuEnabled {
            if globalBestImproved {
                stagnationCount = 0
            } else {
                stagnationCount += 1
                if stagnationCount >= tabuStagnation {
                    tabuList.append(bestParams)
                    stagnationCount = 0
                    for i in 0..<colonySize where isTabu(sources[i]) { reinitSource(i) }
                }
            }
        }
        generation += 1
        let bi = fitness.indices.min(by: { fitness[$0] < fitness[$1] })!
        return OptimizerStep(bestParams: sources[bi], bestError: fitness[bi], generation: generation)
    }

    private func makeNeighbour(from i: Int) -> [Double] {
        var k: Int
        if colonySize > 1 {
            repeat { k = Int.random(in: 0..<colonySize) } while k == i
        } else { k = i }
        let j   = Int.random(in: 0..<n)
        let phi = Double.random(in: -1.0...1.0)
        var nb  = sources[i]
        nb[j]   = (sources[i][j] + phi * (sources[i][j] - sources[k][j]))
                  .clamped(to: bounds[j].lo...bounds[j].hi)
        return nb
    }

    private mutating func reinitSource(_ i: Int) {
        var attempts = 0
        repeat {
            sources[i] = bounds.map { b in .random(in: b.lo...b.hi) }
            attempts  += 1
        } while isTabu(sources[i]) && attempts < 20
        fitness[i] = .infinity
        trials[i]  = 0
    }

    private func isTabu(_ candidate: [Double]) -> Bool {
        guard tabuEnabled, !tabuList.isEmpty else { return false }
        for tabu in tabuList {
            var sq = 0.0
            for j in 0..<n {
                let range = bounds[j].hi - bounds[j].lo
                guard range > 0 else { continue }
                let d = (candidate[j] - tabu[j]) / range
                sq += d * d
            }
            if sqrt(sq / Double(max(1, n))) < tabuRadius { return true }
        }
        return false
    }

    private func rouletteSelect(_ weights: [Double], total: Double) -> Int {
        let r   = Double.random(in: 0..<max(total, 1e-10))
        var acc = 0.0
        for i in 0..<weights.count { acc += weights[i]; if acc >= r { return i } }
        return weights.count - 1
    }
}

// MARK: - Clamp extension

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
