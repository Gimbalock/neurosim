//
//  OptimizationRunner.swift
//  NeuroSimApp
//
//  @MainActor class that drives DE or CMA-ES optimization.
//  Yields between individual candidate evaluations so the UI stays
//  responsive (each eval is ~5-30 ms depending on simDuration).
//

import Foundation
import SwiftUI
import NeuroSimCore

// MARK: - Density grid (shared between reference pre-compute and eval)

// MARK: - Density grid
//
// `weights` accumulates arc-length mass rather than raw point counts so that
// each segment of the phase-plane trajectory contributes proportionally to
// its length in (V, dV/dt) space — not to the time spent there.
// This prevents slow-oscillation regimes (long dwell, small arc) from
// drowning out fast action-potential bursts (short dwell, large arc).
//
// `outFraction` tracks the fraction of candidate points that fell outside the
// reference bounding box (see `buildEvalGridInRange`).

struct EvalDensityGrid {
    let weights:     [Double]   // arc-length-weighted bin masses
    let nV:          Int
    let nDvdt:       Int
    let vMin:        Double; let vMax:        Double
    let dvdtMin:     Double; let dvdtMax:     Double
    let outFraction: Double     // fraction of pts outside reference range (0 for ref grid)
    var totalWeight: Double { weights.reduce(0, +) }
}

func buildEvalGrid(_ pts: [(v: Double, dvdt: Double)], nV: Int, nD: Int) -> EvalDensityGrid? {
    guard !pts.isEmpty else { return nil }
    let vs = pts.map(\.v); let ds = pts.map(\.dvdt)
    guard let vMn = vs.min(), let vMx = vs.max(), vMx > vMn,
          let dMn = ds.min(), let dMx = ds.max(), dMx > dMn else { return nil }
    let vPad = (vMx - vMn) * 0.04; let dPad = (dMx - dMn) * 0.04
    return buildEvalGridInRange(pts,
                                vLo: vMn - vPad, vHi: vMx + vPad,
                                dLo: dMn - dPad, dHi: dMx + dPad,
                                nV: nV, nD: nD)
}

/// Build a weighted density grid within a fixed (V, dV/dt) bounding box.
///
/// Each point `pts[i]` receives a weight equal to the average arc-length of
/// its two adjacent phase-plane segments:
///
///   w_i = ( ‖pts[i] − pts[i−1]‖ + ‖pts[i+1] − pts[i]‖ ) / 2
///
/// with boundary corrections for the first and last points.
/// Points outside [vLo, vHi] × [dLo, dHi] are counted in `outFraction` but
/// not binned (their arc-length contribution is forfeit — this acts as an
/// implicit penalty for trajectories that escape the reference domain).
func buildEvalGridInRange(_ pts: [(v: Double, dvdt: Double)],
                          vLo: Double, vHi: Double,
                          dLo: Double, dHi: Double,
                          nV: Int, nD: Int) -> EvalDensityGrid {
    var weights  = [Double](repeating: 0, count: nV * nD)
    var outCount = 0
    let n        = pts.count

    /// Euclidean distance in (V, dV/dt) space between two consecutive points.
    @inline(__always)
    func segLen(_ i: Int, _ j: Int) -> Double {
        let dv = pts[j].v    - pts[i].v
        let dd = pts[j].dvdt - pts[i].dvdt
        return max(sqrt(dv*dv + dd*dd), 1e-12)   // never exactly zero
    }

    for i in 0..<n {
        // Arc-length weight: half-sum of adjacent segment lengths
        let w: Double
        switch (i, n) {
        case (_, 1):        w = 1.0                              // single point
        case (0, _):        w = segLen(0, 1)                    // first point
        case (_, _) where i == n - 1: w = segLen(n-2, n-1)     // last point
        default:            w = (segLen(i-1, i) + segLen(i, i+1)) * 0.5
        }

        let p = pts[i]
        guard p.v    >= vLo, p.v    <= vHi,
              p.dvdt >= dLo, p.dvdt <= dHi else { outCount += 1; continue }

        let ci = min(Int((p.v    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
        let ri = min(Int((p.dvdt - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
        weights[ri * nV + ci] += w
    }

    let outFrac = n > 0 ? Double(outCount) / Double(n) : 0.0
    return EvalDensityGrid(weights: weights, nV: nV, nDvdt: nD,
                           vMin: vLo, vMax: vHi,
                           dvdtMin: dLo, dvdtMax: dHi,
                           outFraction: outFrac)
}

/// χ² distance between two arc-length-weighted density grids, plus an
/// out-of-range penalty for the candidate (`b`).
///
/// χ²(p, q) = Σ_i (p_i − q_i)² / (p_i + q_i + ε)
///
/// Advantages over plain SSD:
/// · Automatically up-weights sparse regions (AP peaks, burst transitions)
///   where a mismatch matters most diagnostically.
/// · Bounded ≈ [0, 2] for normalised distributions, so it scales predictably
///   regardless of bin count.
///
/// Out-of-range penalty:
/// · Each fraction of candidate points that lands outside the reference domain
///   adds up to 2.0 to the score (matching the maximum χ² value).
///   Convention: `a` = reference (outFraction ≈ 0), `b` = candidate.
func ssdNormalized(_ a: EvalDensityGrid, _ b: EvalDensityGrid) -> Double {
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
    // Out-of-range penalty: up to +2.0 when all candidate points are out of bounds
    dist += b.outFraction * 2.0
    return dist
}

// MARK: - Param info (published for the view)

struct ActiveParamInfo {
    let label: String
    let lo:    Double
    let hi:    Double
}

// MARK: - Runner

@MainActor
final class OptimizationRunner: ObservableObject {
    @Published var isRunning   = false
    @Published var isPaused    = false   // true while suspended between iterations
    @Published var iteration   = 0
    @Published var bestError   = Double.infinity
    @Published var bestParams: [Double] = []
    @Published var errorHistory: [(iteration: Int, error: Double)] = []
    @Published var status      = "Prêt"

    // Live feedback
    @Published var lastBestPoints: [(v: Double, dvdt: Double)] = []
    @Published var paramSnapshots: [(iteration: Int, values: [Double])] = []
    @Published var activeParamInfo: [ActiveParamInfo] = []

    // Pts captured by the last evalFn call (written synchronously on main actor)
    private var _lastEvalPts: [(v: Double, dvdt: Double)] = []
    // Stored so updateBest can trigger a re-eval of best params
    private var _evalFn: (([Double]) -> Double)?

    private var runTask: Task<Void, Never>?

    // MARK: - Pause / resume support

    /// Set to true from the main actor; the running loop checks it each iteration.
    private var shouldPause = false

    /// Everything needed to reconstruct an evalFn and resume the optimizer.
    private struct StartContext {
        let params:    [OptimParam]
        let neuronID:  UUID
        let config:    OptimConfig
        let objective: OptimObjective
        let bounds:    [(lo: Double, hi: Double)]
        let active:    [OptimParam]   // params.filter(\.isActive), precomputed
    }
    private var startContext: StartContext? = nil

    /// Frozen optimizer state saved when pause() is called.
    private enum SavedOptState {
        case de(DifferentialEvolution)
        case cmaes(CMAES)
    }
    private struct PausedState {
        let context:  StartContext
        let optState: SavedOptState
    }
    private var pausedState: PausedState? = nil

    // MARK: Public API

    /// Generalised entry point — caller passes any `OptimObjective`.
    /// The objective defines what to measure; parameter selection is unchanged.
    func start(vm:        SimulationViewModel,
               params:    [OptimParam],
               neuronID:  UUID,
               config:    OptimConfig,
               objective: OptimObjective) {
        guard !isRunning, !isPaused else { return }

        let active = params.filter(\.isActive)
        guard !active.isEmpty else { status = "Aucun paramètre sélectionné"; return }

        let bounds = active.map { (lo: $0.minBound, hi: $0.maxBound) }

        // Save context for potential pause/resume
        let ctx = StartContext(params: params, neuronID: neuronID,
                               config: config, objective: objective,
                               bounds: bounds, active: active)
        startContext = ctx
        pausedState  = nil

        // Reset all published state
        isRunning       = true
        isPaused        = false
        shouldPause     = false
        iteration       = 0
        bestError       = .infinity
        bestParams      = []
        errorHistory    = []
        lastBestPoints  = []
        paramSnapshots  = []
        activeParamInfo = active.map { ActiveParamInfo(label: $0.label,
                                                       lo: $0.minBound, hi: $0.maxBound) }
        status          = "Démarrage…"

        launchTask(vm: vm, ctx: ctx, optState: nil)
    }

    /// Convenience wrapper: density-match objective.
    func start(vm:        SimulationViewModel,
               params:    [OptimParam],
               neuronID:  UUID,
               refPoints: [(v: Double, dvdt: Double)],
               config:    OptimConfig,
               nBinsV:    Int = 100,
               nBinsDvdt: Int = 80) {
        guard !refPoints.isEmpty else { status = "Pas de trace de référence"; return }
        start(vm: vm, params: params, neuronID: neuronID, config: config,
              objective: .densityMatch(refPoints: refPoints,
                                       nBinsV: nBinsV, nBinsDvdt: nBinsDvdt))
    }

    /// Request a pause at the next inter-iteration boundary.
    func pause() {
        guard isRunning, !isPaused else { return }
        shouldPause = true
        status = "Mise en pause…"
    }

    /// Resume from a previously paused state (rebuilds evalFn from saved context).
    func resume(vm: SimulationViewModel) {
        guard isPaused, let ps = pausedState else { return }
        isPaused    = false
        shouldPause = false
        isRunning   = true
        status      = "Reprise…"
        startContext = ps.context   // keep available for potential re-pause
        launchTask(vm: vm, ctx: ps.context, optState: ps.optState)
    }

    func stop() {
        runTask?.cancel(); runTask  = nil
        shouldPause = false
        _evalFn     = nil
        isRunning   = false
        isPaused    = false
        pausedState = nil
        status      = "Arrêté"
    }

    // MARK: - Internal task launcher (shared by start + resume)

    private func launchTask(vm:       SimulationViewModel,
                            ctx:      StartContext,
                            optState: SavedOptState?) {
        // Build a fresh Simulator and scorer each time (safe for concurrent runs).
        let sim    = Simulator(network: vm.network, dt: 0.025)
        sim.method = .rushLarsen
        let scorer = ctx.objective.makeScorer(neuronID: ctx.neuronID,
                                              duration: ctx.config.simDuration)
        let evalFn: ([Double]) -> Double = { [weak vm] candidate in
            guard let vm else { return .infinity }
            for (i, param) in ctx.active.enumerated() {
                applyOptimParam(param, value: candidate[i],
                                neuronID: ctx.neuronID, network: vm.network)
            }
            let (score, pts) = scorer(sim)
            self._lastEvalPts = pts
            return score
        }
        _evalFn = evalFn

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch ctx.config.algorithm {
            case .differentialEvolution:
                await self.runDE(evalFn: evalFn, bounds: ctx.bounds,
                                 config: ctx.config,
                                 resumeFrom: optState.flatMap {
                                     if case .de(let d) = $0 { return d } else { return nil }
                                 })
            case .cmaes:
                await self.runCMAES(evalFn: evalFn, bounds: ctx.bounds,
                                    config: ctx.config,
                                    resumeFrom: optState.flatMap {
                                        if case .cmaes(let c) = $0 { return c } else { return nil }
                                    })
            }
            // Task finished normally (not paused) — apply best and clean up.
            guard !self.isPaused else { return }
            if !self.bestParams.isEmpty {
                for (i, param) in ctx.active.enumerated() {
                    applyOptimParam(param, value: self.bestParams[i],
                                    neuronID: ctx.neuronID, network: vm.network)
                }
                vm.reset()
            }
            self._evalFn     = nil
            self.isRunning   = false
            self.startContext = nil
            self.status      = String(format: "Terminé  E = %.3e  (%d iter.)",
                                      self.bestError, self.iteration)
        }
    }

    // MARK: - DE loop

    private func runDE(evalFn:     ([Double]) -> Double,
                       bounds:     [(lo: Double, hi: Double)],
                       config:     OptimConfig,
                       resumeFrom: DifferentialEvolution? = nil) async {

        var de = resumeFrom ?? DifferentialEvolution(bounds: bounds,
                                                      popFactor: config.dePopFactor,
                                                      F: config.deF, CR: config.deCR)

        if resumeFrom == nil {
            // Fresh start — evaluate initial population
            status = "DE — init (\(de.popSize) candidats)…"
            let initCandidates = de.initialCandidates()
            var initFitness    = [Double](repeating: .infinity, count: de.popSize)
            var bestInitErr    = Double.infinity
            var bestInitPts:   [(v: Double, dvdt: Double)] = []
            for (i, c) in initCandidates.enumerated() {
                guard !Task.isCancelled else { isRunning = false; return }
                initFitness[i] = evalFn(c)
                if initFitness[i] < bestInitErr {
                    bestInitErr = initFitness[i]
                    bestInitPts = _lastEvalPts
                }
                await Task.yield()
            }
            de.setInitialFitness(initFitness)
            let bi = initFitness.indices.min(by: { initFitness[$0] < initFitness[$1] })!
            updateBest(params: de.population[bi], error: initFitness.min()!,
                       gen: 0, pts: bestInitPts)
        } else {
            status = String(format: "DE — reprise gen. %d…", de.generation)
        }

        // Generational loop
        for _ in 0..<config.maxIterations {
            guard !Task.isCancelled else { break }

            // ── Pause check ────────────────────────────────────────────────
            if shouldPause {
                shouldPause = false
                if let ctx = startContext {
                    pausedState = PausedState(context: ctx, optState: .de(de))
                }
                isRunning = false
                isPaused  = true
                status = String(format: "⏸  En pause — gen. %d  E = %.3e  " +
                                        "(Reprendre pour continuer, ou lancez la sim. pour voir le résultat)",
                                de.generation, bestError)
                return
            }
            // ──────────────────────────────────────────────────────────────

            let trials = de.generateTrials()
            var errors = [Double](repeating: .infinity, count: de.popSize)
            var bestGenErr = Double.infinity
            var bestGenPts: [(v: Double, dvdt: Double)] = []
            for (i, t) in trials.enumerated() {
                guard !Task.isCancelled else { break }
                errors[i] = evalFn(t)
                if errors[i] < bestGenErr {
                    bestGenErr = errors[i]
                    bestGenPts = _lastEvalPts
                }
                await Task.yield()
            }
            let result = de.applyTrials(trials, errors: errors)
            updateBest(params: result.bestParams, error: result.bestError,
                       gen: result.generation,
                       pts: result.bestError < bestError ? bestGenPts : nil)
            if result.bestError < config.targetError { break }
        }
    }

    // MARK: - CMA-ES loop

    private func runCMAES(evalFn:     ([Double]) -> Double,
                          bounds:     [(lo: Double, hi: Double)],
                          config:     OptimConfig,
                          resumeFrom: CMAES? = nil) async {

        var cma = resumeFrom ?? CMAES(bounds: bounds, sigma0fraction: config.cmaeSigma0)
        if resumeFrom == nil {
            status = "CMA-ES — λ=\(cma.lambda), μ=\(cma.mu)…"
        } else {
            status = String(format: "CMA-ES — reprise gen. %d…", cma.generation)
        }

        for _ in 0..<config.maxIterations {
            guard !Task.isCancelled else { break }

            // ── Pause check ────────────────────────────────────────────────
            if shouldPause {
                shouldPause = false
                if let ctx = startContext {
                    pausedState = PausedState(context: ctx, optState: .cmaes(cma))
                }
                isRunning = false
                isPaused  = true
                status = String(format: "⏸  En pause — gen. %d  E = %.3e  " +
                                        "(Reprendre pour continuer, ou lancez la sim. pour voir le résultat)",
                                cma.generation, bestError)
                return
            }
            // ──────────────────────────────────────────────────────────────

            let offspring = cma.generateOffspring()
            var errors = [Double](repeating: .infinity, count: cma.lambda)
            var bestGenErr = Double.infinity
            var bestGenPts: [(v: Double, dvdt: Double)] = []
            for (i, o) in offspring.enumerated() {
                guard !Task.isCancelled else { break }
                errors[i] = evalFn(o.x)
                if errors[i] < bestGenErr {
                    bestGenErr = errors[i]
                    bestGenPts = _lastEvalPts
                }
                await Task.yield()
            }
            let result = cma.applyOffspring(offspring, errors: errors)
            updateBest(params: result.bestParams, error: result.bestError,
                       gen: result.generation,
                       pts: result.bestError < bestError ? bestGenPts : nil)
            if result.bestError < config.targetError { break }
        }
    }

    // MARK: - Helpers

    private func updateBest(params: [Double], error: Double, gen: Int,
                            pts: [(v: Double, dvdt: Double)]? = nil) {
        iteration = gen
        errorHistory.append((iteration: gen, error: error))
        if error < bestError {
            bestError  = error
            bestParams = params
            if let pts { lastBestPoints = pts }
            paramSnapshots.append((iteration: gen, values: params))
        }
        status = String(format: "%@  gen %d  E = %.3e",
                        errorHistory.count > 1 ? "…" : "init", gen, error)
    }
}
