//
//  ModelSweepRunner.swift
//  NeuroSimApp
//
//  General-purpose brute-force parameter sweep for any neuron model.
//
//  Supports 1–3 parameters, each with a configurable list of candidate values.
//  Objectives: trajectory density error (needs reference) or burst score (none).
//  Results are sorted best-first and can be applied to the live network.
//
//  Architecture
//  ────────────
//  · Isolated network copy (NetworkDocument round-trip) — live model untouched.
//  · Uses existing OptimObjective + applyOptimParam infrastructure.
//  · Task.yield() between evaluations → UI stays responsive.
//

import Foundation
import SwiftUI
import NeuroSimCore

// MARK: - Sweep parameter spec

struct SweepParamSpec {
    var param: OptimParam
    var values: [Double]    // candidate values to try (computed from bounds + steps)
    var steps: Int          // grid steps
    var logSpacing: Bool    // true → log-spaced

    static func makeValues(minV: Double, maxV: Double, steps: Int, log: Bool) -> [Double] {
        guard steps >= 1 else { return [minV] }
        guard maxV > minV else { return [minV] }
        if log && minV > 0 {
            let lo = Foundation.log10(minV)
            let hi = Foundation.log10(maxV)
            let denom = Double(Swift.max(1, steps - 1))
            return (0..<steps).map { i in
                let t = Double(i) / denom
                return pow(10.0, lo + t * (hi - lo))
            }
        } else {
            if steps == 1 { return [minV] }
            return (0..<steps).map { i in minV + Double(i) / Double(steps - 1) * (maxV - minV) }
        }
    }
}

// MARK: - Result

struct ModelSweepResult: Identifiable {
    let id            = UUID()
    let paramValues:  [Double]   // one per SweepParamSpec
    let score:        Double     // lower = better (density error) or (1 / burst+1)
    let rawBurstInfo: (burstCount: Int, meanAPs: Double, meanPeriodMs: Double)?
}

// MARK: - Runner

@MainActor
final class ModelSweepRunner: ObservableObject {

    @Published var isRunning   = false
    @Published var progress:   Double = 0
    @Published var doneEvals   = 0
    @Published var totalEvals  = 0
    @Published var status      = "Prêt"
    @Published var results:    [ModelSweepResult] = []

    private var sweepTask: Task<Void, Never>?

    // MARK: - Configuration

    enum SweepObjective {
        case density(refPoints: [(v: Double, dvdt: Double)],
                     nBinsV: Int, nBinsDvdt: Int)
        case burst(aisCompartmentID: UUID?,
                   restingVoltage:   Double,
                   targetBPS:        Double,
                   targetAPsPerBurst: Double,
                   targetPeriodMs:   Double)
    }

    // MARK: - Public API

    func start(vm:          SimulationViewModel,
               neuronID:    UUID,
               paramSpecs:  [SweepParamSpec],
               objective:   SweepObjective,
               simDuration: Double) {

        guard !isRunning else { return }
        guard !paramSpecs.isEmpty else { status = "Aucun paramètre"; return }

        let nTotal = paramSpecs.reduce(1) { $0 * max(1, $1.values.count) }
        guard nTotal > 0 else { status = "Grille vide"; return }

        isRunning  = true
        doneEvals  = 0
        totalEvals = nTotal
        progress   = 0
        results    = []
        status     = "Démarrage (\(nTotal) simulations)…"

        sweepTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Deep-copy the network
            let evalNet = NetworkDocument.from(vm.network).toNetwork()
            let sim     = Simulator(network: evalNet, dt: 0.025)
            sim.method  = .rushLarsen

            // Build scorer from objective
            let optObjective: OptimObjective
            switch objective {
            case let .density(ref, nBV, nBD):
                optObjective = .densityMatch(refPoints: ref, nBinsV: nBV, nBinsDvdt: nBD)
            case let .burst(aisID, restV, bps, aps, period):
                optObjective = .burstCounting(aisCompartmentID: aisID,
                                               restingVoltage:   restV,
                                               targetBPS:        bps,
                                               targetAPsPerBurst: aps,
                                               targetPeriodMs:   period)
            }
            let scorer = optObjective.makeScorer(neuronID: neuronID, duration: simDuration)

            var all: [ModelSweepResult] = []
            all.reserveCapacity(nTotal)

            // Iterate over Cartesian product of all param value lists
            let indices = paramSpecs.map { Array(0..<$0.values.count) }
            for combo in cartesianProduct(indices) {
                guard !Task.isCancelled else { break }

                let vals = combo.enumerated().map { paramSpecs[$0.offset].values[$0.element] }

                // Apply each parameter value to the isolated network
                for (i, spec) in paramSpecs.enumerated() {
                    applyOptimParam(spec.param, value: vals[i],
                                    neuronID: neuronID, network: evalNet)
                }

                let (score, _, _) = scorer(sim)

                let burstInfo: (Int, Double, Double)? = nil
                // Burst info is encoded in score; no separate capture needed

                let r = ModelSweepResult(paramValues: vals, score: score,
                                          rawBurstInfo: burstInfo)
                all.append(r)
                all.sort { $0.score < $1.score }   // best (lowest score) first
                self.results   = all
                self.doneEvals += 1
                self.progress  = Double(self.doneEvals) / Double(nTotal)

                let bestE = all.first?.score ?? .infinity
                self.status = String(format: "%d/%d — meilleur %.3e",
                                      self.doneEvals, nTotal, bestE)
                await Task.yield()
            }

            self.isRunning = false
            self.status = "Terminé — \(all.count) points évalués"
        }
    }

    func stop() {
        sweepTask?.cancel()
        sweepTask = nil
        isRunning = false
        status    = "Arrêté"
    }

    /// Apply a result's parameter values to the live network.
    func apply(result: ModelSweepResult,
               paramSpecs: [SweepParamSpec],
               neuronID: UUID,
               vm: SimulationViewModel) {
        vm.pause()
        for (i, spec) in paramSpecs.enumerated() {
            guard i < result.paramValues.count else { continue }
            applyOptimParam(spec.param, value: result.paramValues[i],
                            neuronID: neuronID, network: vm.network)
        }
        vm.rebuildSimulatorPublic()
        vm.reset()
    }
}

// MARK: - Cartesian product helper

private func cartesianProduct(_ arrays: [[Int]]) -> [[Int]] {
    guard !arrays.isEmpty else { return [[]] }
    var result: [[Int]] = [[]]
    for arr in arrays {
        result = result.flatMap { prefix in arr.map { prefix + [$0] } }
    }
    return result
}
