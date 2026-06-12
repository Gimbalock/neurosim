//
//  OptimizationRunner.swift
//  NeuroSimApp
//
//  @MainActor class that drives DE, CMA-ES and ABC optimization.
//  Yields between individual candidate evaluations so the UI stays
//  responsive (each eval is ~5-30 ms depending on simDuration).
//
//  EvalDensityGrid, buildEvalGrid, buildEvalGridInRange, ssdNormalized and
//  chiSquaredFast live in NeuroSimCore/DensityScore.swift so they can be
//  used from the test target without duplication.
//

import Foundation
import SwiftUI
import NeuroSimCore

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
    @Published var lastCandidateTrace: [(t: Double, v: Double)] = []        // V(t) preview
    /// Phase-plane points of the **most recently evaluated** candidate.
    /// Published so the density overlay refreshes on every evaluation,
    /// not only when a new global best is found.
    @Published var lastCandidatePhasePts: [(v: Double, dvdt: Double)] = []
    @Published var paramSnapshots: [(iteration: Int, values: [Double])] = []
    @Published var activeParamInfo: [ActiveParamInfo] = []
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
        case abc(ArtificialBeeColony)
        case bayesian(BayesianOptimizer)
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
        lastBestPoints          = []
        lastCandidatePhasePts   = []
        lastCandidateTrace      = []
        paramSnapshots          = []
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
                                              duration: ctx.config.simDuration,
                                              config:   ctx.config)
        let evalFn: ([Double]) -> Double = { [weak vm] candidate in
            guard let vm else { return .infinity }
            for (i, param) in ctx.active.enumerated() {
                applyOptimParam(param, value: candidate[i],
                                neuronID: ctx.neuronID, network: vm.network)
            }
            let (score, pts, tracePts) = scorer(sim)
            self.lastCandidatePhasePts       = pts
            self.lastCandidateTrace = tracePts   // @Published, safe on main actor
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
            case .beeColony:
                await self.runABC(evalFn: evalFn, bounds: ctx.bounds,
                                  config: ctx.config,
                                  resumeFrom: optState.flatMap {
                                      if case .abc(let a) = $0 { return a } else { return nil }
                                  })
            case .bayesian:
                await self.runBO(evalFn: evalFn, bounds: ctx.bounds,
                                 config: ctx.config,
                                 resumeFrom: optState.flatMap {
                                     if case .bayesian(let b) = $0 { return b } else { return nil }
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
                    bestInitPts = lastCandidatePhasePts
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
                    bestGenPts = lastCandidatePhasePts
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
                    bestGenPts = lastCandidatePhasePts
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

    // MARK: - ABC loop

    private func runABC(evalFn:     ([Double]) -> Double,
                        bounds:     [(lo: Double, hi: Double)],
                        config:     OptimConfig,
                        resumeFrom: ArtificialBeeColony? = nil) async {

        var abc = resumeFrom ?? ArtificialBeeColony(
            bounds:         bounds,
            colonySize:     config.abcColonySize,
            tabuEnabled:    config.abcTabuEnabled,
            tabuStagnation: config.abcTabuStagnation
        )

        if resumeFrom == nil {
            // Fresh start — evaluate initial food sources
            status = "ABC — init (\(abc.colonySize) sources)…"
            let initCands  = abc.initialCandidates()
            var initFitness = [Double](repeating: .infinity, count: abc.colonySize)
            var bestInitErr = Double.infinity
            var bestInitPts: [(v: Double, dvdt: Double)] = []
            for (i, c) in initCands.enumerated() {
                guard !Task.isCancelled else { isRunning = false; return }
                initFitness[i] = evalFn(c)
                if initFitness[i] < bestInitErr {
                    bestInitErr = initFitness[i]
                    bestInitPts = lastCandidatePhasePts
                }
                await Task.yield()
            }
            abc.setInitialFitness(initFitness)
            let bi = initFitness.indices.min(by: { initFitness[$0] < initFitness[$1] })!
            updateBest(params: abc.sources[bi], error: initFitness[bi],
                       gen: 0, pts: bestInitPts)
        } else {
            status = String(format: "ABC — reprise gen. %d…", abc.generation)
        }

        for _ in 0..<config.maxIterations {
            guard !Task.isCancelled else { break }

            // ── Pause check ────────────────────────────────────────────────
            if shouldPause {
                shouldPause = false
                if let ctx = startContext {
                    pausedState = PausedState(context: ctx, optState: .abc(abc))
                }
                isRunning = false
                isPaused  = true
                status = String(format: "⏸  En pause — gen. %d  E = %.3e  " +
                                        "(Reprendre pour continuer, ou lancez la sim. pour voir le résultat)",
                                abc.generation, bestError)
                return
            }
            // ──────────────────────────────────────────────────────────────

            var bestGenErr = Double.infinity
            var bestGenPts: [(v: Double, dvdt: Double)] = []

            // ── Employed bee phase ─────────────────────────────────────────
            let empCands = abc.employedCandidates()
            for (si, cand) in empCands {
                guard !Task.isCancelled else { break }
                let err = evalFn(cand)
                abc.applyEmployed(sourceIdx: si, candidate: cand, error: err)
                if err < bestGenErr { bestGenErr = err; bestGenPts = lastCandidatePhasePts }
                await Task.yield()
            }

            // ── Onlooker bee phase (uses updated fitness from employed) ────
            let oolCands = abc.onlookerCandidates()
            for (si, cand) in oolCands {
                guard !Task.isCancelled else { break }
                let err = evalFn(cand)
                abc.applyOnlooker(sourceIdx: si, candidate: cand, error: err)
                if err < bestGenErr { bestGenErr = err; bestGenPts = lastCandidatePhasePts }
                await Task.yield()
            }

            // ── Scout + tabu + finalise ────────────────────────────────────
            let prevBest = bestError
            let result   = abc.finishGeneration(
                globalBestImproved: bestGenErr < prevBest,
                bestParams:         bestParams.isEmpty ? (abc.sources.first ?? []) : bestParams
            )
            updateBest(params: result.bestParams, error: result.bestError,
                       gen: result.generation,
                       pts: result.bestError < bestError ? bestGenPts : nil)
            if result.bestError < config.targetError { break }
        }
    }

    // MARK: - GP-BO loop

    private func runBO(evalFn:     ([Double]) -> Double,
                       bounds:     [(lo: Double, hi: Double)],
                       config:     OptimConfig,
                       resumeFrom: BayesianOptimizer? = nil) async {

        var bo = resumeFrom ?? BayesianOptimizer(
            bounds:             bounds,
            warmupCount:        config.boWarmup,
            refitEvery:         5,
            acquisitionSamples: 2000
        )

        let startEval = bo.observationCount
        let budget    = config.maxIterations

        if resumeFrom == nil {
            status = "GP-BO — préchauffage (\(config.boWarmup) pts LHS)…"
        } else {
            status = String(format: "GP-BO — reprise eval %d/%d  E = %.3e",
                            startEval, budget, bo.bestError)
        }

        for eval in startEval..<budget {
            guard !Task.isCancelled else { break }

            // ── Pause check ────────────────────────────────────────────────
            if shouldPause {
                shouldPause = false
                if let ctx = startContext {
                    pausedState = PausedState(context: ctx, optState: .bayesian(bo))
                }
                isRunning = false
                isPaused  = true
                status = String(format:
                    "⏸  En pause — eval %d/%d  E = %.3e  " +
                    "(Reprendre pour continuer, ou lancez la sim. pour voir le résultat)",
                    eval, budget, bo.isInWarmup ? Double.infinity : bo.bestError)
                return
            }
            // ──────────────────────────────────────────────────────────────

            // Update status label: warm-up vs BO phase
            if bo.isInWarmup {
                status = String(format: "GP-BO — préchauffage %d/%d…",
                                eval + 1, config.boWarmup)
            } else {
                status = String(format: "GP-BO — eval %d/%d  E = %.3e",
                                eval + 1, budget, bo.bestError)
            }

            let candidate = bo.nextCandidate()
            let error     = evalFn(candidate)
            bo.addObservation(x: candidate, y: error)

            updateBest(params: bo.bestParams, error: bo.bestError,
                       gen: eval + 1,
                       pts: bo.bestError < bestError ? lastCandidatePhasePts : nil)

            if bo.bestError < config.targetError { break }
            await Task.yield()
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
