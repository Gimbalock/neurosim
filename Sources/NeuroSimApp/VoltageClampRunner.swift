//
//  VoltageClampRunner.swift
//  NeuroSimApp
//
//  @MainActor runner that drives VoltageClampEngine step-by-step,
//  yielding between each step voltage to keep the UI responsive.
//

import Foundation
import SwiftUI
import NeuroSimCore

@MainActor
final class VoltageClampRunner: ObservableObject {

    // MARK: - Config (bound to UI controls)

    @Published var vcProtocol = VoltageClampProtocol()
    @Published var selectedNeuronID:      UUID? = nil
    @Published var selectedCompartmentID: UUID? = nil

    // MARK: - State

    @Published var result:    VClampResult? = nil
    @Published var isRunning: Bool = false
    @Published var progress:  Int  = 0     // steps completed
    @Published var status:    String = "Prêt"

    private var runTask: Task<Void, Never>?

    // MARK: - Public API

    func run(network: Network) {
        guard !isRunning else { return }
        guard let compartment = resolveCompartment(network: network) else {
            status = "Sélectionnez un neurone"; return
        }
        guard !compartment.channels.isEmpty else {
            status = "Pas de canaux dans ce compartiment"; return
        }

        result    = nil
        progress  = 0
        isRunning = true
        status    = "Démarrage…"

        let engine = VoltageClampEngine(compartment: compartment, vcProtocol: vcProtocol)
        let steps  = vcProtocol.stepVoltages

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var allTraces: [[VClampChannelTrace]] = []

            for (si, vTest) in steps.enumerated() {
                guard !Task.isCancelled else { break }
                let stepTraces = engine.runStep(vTest: vTest)
                allTraces.append(stepTraces)
                self.progress = si + 1
                self.status   = String(format: "Palier %d/%d  (%.0f mV)", si+1, steps.count, vTest)
                await Task.yield()
            }

            if !Task.isCancelled, !allTraces.isEmpty {
                self.result = VClampResult(vcProtocol:   self.vcProtocol,
                                           channelNames: compartment.channels.map(\.name),
                                           traces:       allTraces)
                self.status = String(format: "Terminé — %d paliers", allTraces.count)
            } else if Task.isCancelled {
                self.status = "Arrêté"
            }
            self.isRunning = false
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status    = "Arrêté"
    }

    // MARK: - Helpers

    private func resolveCompartment(network: Network) -> Compartment? {
        guard let nid    = selectedNeuronID,
              let neuron = network.neurons.first(where: { $0.id == nid }) else { return nil }
        if let cid  = selectedCompartmentID,
           let comp = neuron.compartments.first(where: { $0.id == cid }) { return comp }
        return neuron.compartments.first
    }
}
