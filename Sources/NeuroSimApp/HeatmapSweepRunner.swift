//
//  HeatmapSweepRunner.swift
//  NeuroSimApp
//
//  2D parameter sweep that produces a colour heatmap of trajectory density
//  error (ssdNormalized) over a grid of (paramX × paramY) values.
//
//  Architecture
//  ────────────
//  · The runner creates a single isolated deep-copy Network (via NetworkDocument
//    round-trip) so the live model is NEVER touched during the sweep.
//  · Parameters are applied by index (OptimParam.target) which survives the
//    round-trip because compartment/channel order is preserved.
//  · Results are stored row-major: errors[iy * nX + ix].
//  · The sweep yields between every evaluation → UI stays responsive.
//

import Foundation
import SwiftUI
import NeuroSimCore

// MARK: - Result container

struct HeatmapResult {
    let nX:      Int
    let nY:      Int
    let xParam:  OptimParam
    let yParam:  OptimParam
    let xValues: [Double]
    let yValues: [Double]
    /// Row-major: errors[iy * nX + ix]. NaN = not yet evaluated.
    var errors:  [Double]

    var minError: Double { errors.compactMap { $0.isNaN ? nil : $0 }.min() ?? 0 }
    var maxError: Double { errors.compactMap { $0.isNaN ? nil : $0 }.max() ?? 1 }

    /// Flat index of the best (lowest error) evaluated cell. nil if all NaN.
    var bestIndex: Int? {
        var bi: Int? = nil
        var be = Double.infinity
        for i in errors.indices {
            if !errors[i].isNaN, errors[i] < be { be = errors[i]; bi = i }
        }
        return bi
    }

    func col(ofFlat i: Int) -> Int { i % nX }   // x axis
    func row(ofFlat i: Int) -> Int { i / nX }   // y axis
}

// MARK: - Runner

@MainActor
final class HeatmapSweepRunner: ObservableObject {

    @Published var isRunning  = false
    @Published var progress:  Double = 0
    @Published var doneEvals  = 0
    @Published var totalEvals = 0
    @Published var status     = "Prêt"
    @Published var result:    HeatmapResult? = nil
    /// Downsampled V(t) trace of the last evaluated candidate — for the live preview.
    @Published var lastCandidateTrace: [(t: Double, v: Double)] = []
    /// Downsampled V(t) traces stored per grid cell (flat index).
    /// Populated progressively during the sweep; persists after completion
    /// so the user can inspect any cell by selecting it on the heatmap.
    /// Each trace is capped at 2 000 points to limit memory usage.
    ///
    /// NOT `@Published`: mutations happen ~N² times per sweep and do NOT need
    /// to trigger a SwiftUI redraw by themselves — the view reads these only
    /// when the user taps a cell.  We publish `cellTracesVersion` as a cheap
    /// "something changed" signal instead.
    private(set) var cellTraces: [Int: [(t: Double, v: Double)]] = [:]
    /// Incremented once when the sweep finishes, so views can react once
    /// instead of once per cell evaluation.
    @Published var cellTracesVersion: Int = 0

    private var sweepTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start the sweep. `refPoints` must be non-empty (use `TrajectoryDensityView`
    /// or run a simulation and extract points before calling).
    func start(vm:          SimulationViewModel,
               neuronID:    UUID,
               xParam:      OptimParam,
               yParam:      OptimParam,
               xValues:     [Double],
               yValues:     [Double],
               refPoints:   [(v: Double, dvdt: Double)],
               simDuration: Double,
               nBinsV:      Int = 80,
               nBinsDvdt:   Int = 60) {

        guard !isRunning else { return }
        guard !xValues.isEmpty, !yValues.isEmpty else { status = "Grille vide"; return }
        guard !refPoints.isEmpty else { status = "Pas de trace de référence"; return }

        let nX = xValues.count
        let nY = yValues.count
        let nTotal = nX * nY

        var r = HeatmapResult(nX: nX, nY: nY,
                               xParam: xParam, yParam: yParam,
                               xValues: xValues, yValues: yValues,
                               errors: [Double](repeating: .nan, count: nTotal))

        isRunning   = true
        doneEvals   = 0
        totalEvals  = nTotal
        progress    = 0
        result      = r
        cellTraces  = [:]   // clear previous run's traces
        status      = "Démarrage (\(nTotal) simulations)…"

        // Validate that reference points produce a non-empty grid
        guard buildEvalGrid(refPoints, nV: nBinsV, nD: nBinsDvdt) != nil else {
            status = "Impossible de construire la grille de référence"
            isRunning = false
            return
        }

        sweepTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Deep-copy the network so the live model is never touched.
            let evalNet = NetworkDocument.from(vm.network).toNetwork()
            let sim     = Simulator(network: evalNet, dt: 0.025)
            sim.method  = .rushLarsen

            // Build scorer that reuses refGrid for every candidate
            let scorer = OptimObjective.densityMatch(
                refPoints: refPoints,
                nBinsV:    nBinsV,
                nBinsDvdt: nBinsDvdt
            ).makeScorer(neuronID: neuronID, duration: simDuration)

            for iy in 0..<nY {
                for ix in 0..<nX {
                    guard !Task.isCancelled else {
                        self.isRunning = false
                        self.status = "Annulé"
                        return
                    }

                    // Apply both param values to the isolated network copy
                    applyOptimParam(xParam, value: xValues[ix],
                                    neuronID: neuronID, network: evalNet)
                    applyOptimParam(yParam, value: yValues[iy],
                                    neuronID: neuronID, network: evalNet)

                    // Score (scorer handles reset + run internally)
                    let (err, _, candidateTrace) = scorer(sim)
                    self.lastCandidateTrace = candidateTrace

                    // Downsample and store per-cell trace (≤2 000 pts to cap memory)
                    let flatIdx = iy * nX + ix
                    let trStride = max(1, candidateTrace.count / 2_000)
                    self.cellTraces[flatIdx] = Swift.stride(from: 0, to: candidateTrace.count, by: trStride)
                        .map { candidateTrace[$0] }

                    r.errors[flatIdx] = err
                    self.result     = r
                    self.doneEvals += 1
                    self.progress   = Double(self.doneEvals) / Double(nTotal)
                    self.status     = String(format: "%d/%d — erreur min %.3e",
                                             self.doneEvals, nTotal, r.minError)

                    await Task.yield()
                }
            }

            self.isRunning        = false
            self.status           = "Terminé — \(nTotal) points évalués"
            self.cellTracesVersion += 1   // notify views once, not once per cell
        }
    }

    func stop() {
        sweepTask?.cancel()
        sweepTask = nil
        isRunning = false
        status    = "Arrêté"
        lastCandidateTrace = []
        // cellTraces is intentionally NOT cleared on stop — the user may
        // still want to inspect individual cells after pausing the sweep.
    }

    /// Fully reset the runner: cancel any running sweep, clear results and
    /// all stored traces so a fresh sweep can be started from scratch.
    func reset() {
        sweepTask?.cancel()
        sweepTask    = nil
        isRunning    = false
        result       = nil
        cellTraces   = [:]
        cellTracesVersion += 1   // invalidate any cached read
        lastCandidateTrace = []
        doneEvals    = 0
        totalEvals   = 0
        progress     = 0
        status       = "Prêt"
    }

    /// Apply the best grid point's parameter values to the live network.
    func applyBest(to vm: SimulationViewModel, neuronID: UUID) {
        guard let r = result, let bi = r.bestIndex else { return }
        let ix = r.col(ofFlat: bi)
        let iy = r.row(ofFlat: bi)
        applyOptimParam(r.xParam, value: r.xValues[ix],
                        neuronID: neuronID, network: vm.network)
        applyOptimParam(r.yParam, value: r.yValues[iy],
                        neuronID: neuronID, network: vm.network)
        vm.rebuildSimulatorPublic()
        vm.reset()
    }

    /// Apply a specific grid cell's parameter values to the live network.
    func applyCell(flatIndex: Int, to vm: SimulationViewModel, neuronID: UUID) {
        guard let r = result, flatIndex < r.errors.count else { return }
        let ix = r.col(ofFlat: flatIndex)
        let iy = r.row(ofFlat: flatIndex)
        applyOptimParam(r.xParam, value: r.xValues[ix],
                        neuronID: neuronID, network: vm.network)
        applyOptimParam(r.yParam, value: r.yValues[iy],
                        neuronID: neuronID, network: vm.network)
        vm.rebuildSimulatorPublic()
        vm.reset()
    }
}
