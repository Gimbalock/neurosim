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

struct EvalDensityGrid {
    let counts:   [Int]
    let nV:       Int
    let nDvdt:    Int
    let vMin:     Double; let vMax:     Double
    let dvdtMin:  Double; let dvdtMax:  Double
    var total: Int { counts.reduce(0, +) }
}

func buildEvalGrid(_ pts: [(v: Double, dvdt: Double)], nV: Int, nD: Int) -> EvalDensityGrid? {
    guard !pts.isEmpty else { return nil }
    let vs = pts.map(\.v); let ds = pts.map(\.dvdt)
    guard let vMn = vs.min(), let vMx = vs.max(), vMx > vMn,
          let dMn = ds.min(), let dMx = ds.max(), dMx > dMn else { return nil }
    let vPad = (vMx-vMn)*0.04; let dPad = (dMx-dMn)*0.04
    return buildEvalGridInRange(pts,
                                vLo: vMn-vPad, vHi: vMx+vPad,
                                dLo: dMn-dPad, dHi: dMx+dPad,
                                nV: nV, nD: nD)
}

func buildEvalGridInRange(_ pts: [(v: Double, dvdt: Double)],
                          vLo: Double, vHi: Double,
                          dLo: Double, dHi: Double,
                          nV: Int, nD: Int) -> EvalDensityGrid {
    var counts = [Int](repeating: 0, count: nV * nD)
    for p in pts {
        guard p.v >= vLo, p.v <= vHi, p.dvdt >= dLo, p.dvdt <= dHi else { continue }
        let ci = min(Int((p.v    - vLo)/(vHi-vLo) * Double(nV)), nV-1)
        let ri = min(Int((p.dvdt - dLo)/(dHi-dLo) * Double(nD)), nD-1)
        counts[ri*nV + ci] += 1
    }
    return EvalDensityGrid(counts: counts, nV: nV, nDvdt: nD,
                           vMin: vLo, vMax: vHi, dvdtMin: dLo, dvdtMax: dHi)
}

func ssdNormalized(_ a: EvalDensityGrid, _ b: EvalDensityGrid) -> Double {
    let tA = max(1, a.total); let tB = max(1, b.total)
    var e = 0.0
    for i in 0..<min(a.counts.count, b.counts.count) {
        let d = Double(a.counts[i])/Double(tA) - Double(b.counts[i])/Double(tB)
        e += d*d
    }
    return e
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

    // MARK: Public API

    func start(vm:         SimulationViewModel,
               params:     [OptimParam],
               neuronID:   UUID,
               refPoints:  [(v: Double, dvdt: Double)],
               config:     OptimConfig,
               nBinsV:     Int = 100,
               nBinsDvdt:  Int = 80) {
        guard !isRunning else { return }

        let active = params.filter(\.isActive)
        guard !active.isEmpty else { status = "Aucun paramètre sélectionné"; return }
        guard !refPoints.isEmpty else { status = "Pas de trace de référence"; return }

        guard let refGrid = buildEvalGrid(refPoints, nV: nBinsV, nD: nBinsDvdt) else {
            status = "Référence insuffisante"; return
        }

        let bounds  = active.map { (lo: $0.minBound, hi: $0.maxBound) }

        let sim     = Simulator(network: vm.network, dt: 0.025)
        sim.method  = .rushLarsen

        // Evaluation closure — also stores the last trajectory into _lastEvalPts
        let evalFn: ([Double]) -> Double = { [weak vm] candidate in
            guard let vm else { return .infinity }
            for (i, param) in active.enumerated() {
                applyOptimParam(param, value: candidate[i],
                                neuronID: neuronID, network: vm.network)
            }
            sim.reset()
            var pts: [(v: Double, dvdt: Double)] = []
            let every = max(1, Int(config.simDuration / sim.dt / 12_000))
            var step  = 0; var prevV: Double? = nil; var prevT = 0.0
            sim.run(duration: config.simDuration) { sample in
                step += 1; guard step % every == 0 else { return }
                guard let v = sample.voltages[neuronID] else { return }
                defer { prevV = v; prevT = sample.time }
                guard let pv = prevV else { return }
                let dt = sample.time - prevT
                guard dt > 0, dt < 2.0 else { return }
                let dv = (v - pv) / dt
                guard abs(dv) < 5000 else { return }
                pts.append((v: pv, dvdt: dv))
            }
            guard !pts.isEmpty else { return .infinity }
            let cg = buildEvalGridInRange(pts,
                                          vLo: refGrid.vMin, vHi: refGrid.vMax,
                                          dLo: refGrid.dvdtMin, dHi: refGrid.dvdtMax,
                                          nV: nBinsV, nD: nBinsDvdt)
            self._lastEvalPts = pts   // captured on main actor — always safe
            return ssdNormalized(refGrid, cg)
        }

        // Reset all published state
        isRunning      = true
        iteration      = 0
        bestError      = .infinity
        bestParams     = []
        errorHistory   = []
        lastBestPoints = []
        paramSnapshots = []
        activeParamInfo = active.map { ActiveParamInfo(label: $0.label, lo: $0.minBound, hi: $0.maxBound) }
        status         = "Démarrage…"
        _evalFn        = evalFn

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch config.algorithm {
            case .differentialEvolution:
                await self.runDE(evalFn: evalFn, bounds: bounds, config: config)
            case .cmaes:
                await self.runCMAES(evalFn: evalFn, bounds: bounds, config: config)
            }
            // Apply best params permanently to the live network
            if !self.bestParams.isEmpty {
                for (i, param) in active.enumerated() {
                    applyOptimParam(param, value: self.bestParams[i],
                                    neuronID: neuronID, network: vm.network)
                }
                vm.reset()
            }
            self._evalFn   = nil
            self.isRunning = false
            self.status    = String(format: "Terminé  E = %.3e  (%d iter.)",
                                    self.bestError, self.iteration)
        }
    }

    func stop() {
        runTask?.cancel(); runTask = nil
        _evalFn   = nil
        isRunning = false
        status    = "Arrêté"
    }

    // MARK: - DE loop

    private func runDE(evalFn: ([Double]) -> Double,
                       bounds: [(lo: Double, hi: Double)],
                       config: OptimConfig) async {
        var de = DifferentialEvolution(bounds: bounds, popFactor: config.dePopFactor,
                                       F: config.deF, CR: config.deCR)
        status = "DE — init (\(de.popSize) candidats)…"

        // Evaluate initial population, track best pts within this batch
        let initCandidates = de.initialCandidates()
        var initFitness = [Double](repeating: .infinity, count: de.popSize)
        var bestInitErr  = Double.infinity
        var bestInitPts: [(v: Double, dvdt: Double)] = []
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
        let bestInitIdx = initFitness.indices.min(by: { initFitness[$0] < initFitness[$1] })!
        updateBest(params: de.population[bestInitIdx], error: initFitness.min()!,
                   gen: 0, pts: bestInitPts)

        // Generational loop
        for _ in 0..<config.maxIterations {
            guard !Task.isCancelled else { break }
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

    private func runCMAES(evalFn: ([Double]) -> Double,
                          bounds: [(lo: Double, hi: Double)],
                          config: OptimConfig) async {
        var cma = CMAES(bounds: bounds, sigma0fraction: config.cmaeSigma0)
        status = "CMA-ES — λ=\(cma.lambda), μ=\(cma.mu)…"

        for _ in 0..<config.maxIterations {
            guard !Task.isCancelled else { break }
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
