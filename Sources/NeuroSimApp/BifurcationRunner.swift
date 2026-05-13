//
//  BifurcationRunner.swift
//  NeuroSimApp
//
//  @MainActor driver: iterates parameter values, yields between each step,
//  and accumulates BifPoints into `points` (updated live for the chart).
//

import Foundation
import SwiftUI
import NeuroSimCore

@MainActor
final class BifurcationRunner: ObservableObject {

    @Published var config             = BifurcationConfig()
    @Published var sweepParam: BifSweepParam = .iInj
    @Published var selectedNeuronID: UUID?   = nil

    @Published var points:    [BifPoint] = []
    @Published var isRunning: Bool       = false
    @Published var progress:  Int        = 0
    @Published var status:    String     = "Prêt"

    private var runTask: Task<Void, Never>?

    // MARK: - Public API

    func run(network: Network) {
        guard !isRunning else { return }
        guard let nid = selectedNeuronID,
              network.neurons.contains(where: { $0.id == nid }) else {
            status = "Sélectionnez un neurone"; return
        }

        points    = []
        progress  = 0
        isRunning = true
        status    = "Démarrage…"

        let engine = BifurcationEngine(network: network, neuronID: nid,
                                       sweepParam: sweepParam, config: config)
        let values = config.paramValues

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var acc: [BifPoint] = []
            acc.reserveCapacity(values.count * 4)

            for (i, pv) in values.enumerated() {
                guard !Task.isCancelled else { break }
                let step = engine.runStep(paramValue: pv)
                acc.append(contentsOf: step)
                self.points   = acc
                self.progress = i + 1
                self.status   = String(format: "Palier %d/%d  (%.2f)",
                                       i + 1, values.count, pv)
                await Task.yield()
            }

            self.isRunning = false
            self.status    = Task.isCancelled
                ? "Arrêté"
                : String(format: "Terminé — %d points", acc.count)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask    = nil
        isRunning  = false
        status     = "Arrêté"
    }
}
