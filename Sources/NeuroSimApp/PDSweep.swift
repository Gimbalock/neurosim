//
//  PDSweep.swift
//  NeuroSimApp
//
//  Grid sweep over three key parameters of the STG PD oscillation to find
//  the parameter region that produces sustained periodic bursting:
//
//    · CaS half-activation vHalf  (mV)   — plateau threshold / burst onset
//    · SK Kd (µM)                         — controls burst duration
//    · Ih gMax (mS/cm²)                   — controls inter-burst interval / frequency
//
//  Each grid point runs an isolated 3 s simulation with a fresh Network and
//  Simulator — no shared mutable state between evaluations.
//  APs are detected in the AIS trace; bursts are grouped by ISI threshold.
//  Results are ranked by a composite score (burst count × AP closeness × period).
//
//  The sweep Task runs on @MainActor, yielding after every evaluation so the UI
//  stays responsive (same pattern as OptimizationRunner).
//

import Foundation
import NeuroSimCore

// MARK: - Result

struct PDSweepResult: Identifiable {
    let id               = UUID()
    let casVHalf:        Double   // mV
    let skKd:            Double   // mM
    let ihGMax:          Double   // mS/cm²
    let tauDecay:        Double   // ms
    let burstCount:      Int
    let meanAPsPerBurst: Double
    let meanPeriodMs:    Double   // inter-burst period (0 if < 2 bursts)
    let score:           Double   // higher = better; < 0 = no bursting

    var casVHalfStr:  String { String(format: "%.0f mV",  casVHalf) }
    var skKdStr:      String { String(format: "%.0f µM",  skKd * 1000) }
    var ihGMaxStr:    String { String(format: "%.1f",     ihGMax) }
    var meanAPsStr:   String { burstCount > 0 ? String(format: "%.1f", meanAPsPerBurst) : "—" }
    var periodStr:    String { burstCount > 1 ? String(format: "%.0f ms", meanPeriodMs) : "—" }
    var scoreStr:     String { String(format: "%.2f", max(score, 0)) }
}

// MARK: - Runner

@MainActor
final class PDSweepRunner: ObservableObject {

    // MARK: Published state

    @Published var isRunning  = false
    @Published var progress:  Double = 0      // 0…1
    @Published var totalEvals = 0
    @Published var doneEvals  = 0
    @Published var results:   [PDSweepResult] = []   // sorted best-first
    @Published var status     = "Prêt"

    // MARK: Grid (tune here to add/remove candidate values)

    static let casVHalfGrid: [Double] = [-38, -34, -30, -26, -22]  // mV
    static let skKdGrid:     [Double] = [0.010, 0.015, 0.020, 0.025, 0.030]  // mM
    static let ihGMaxGrid:   [Double] = [0.8, 1.2, 1.5, 2.0, 2.5]  // mS/cm²
    static let fixedTauDecay: Double  = 150.0   // ms  — kept constant for now
    static let simDuration:   Double  = 3000.0  // ms

    static var gridSize: Int {
        casVHalfGrid.count * skKdGrid.count * ihGMaxGrid.count
    }

    // MARK: Private

    private var sweepTask: Task<Void, Never>?

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning  = true
        results    = []
        doneEvals  = 0
        totalEvals = Self.gridSize
        progress   = 0
        status     = "Démarrage (\(Self.gridSize) simulations)…"

        sweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var all: [PDSweepResult] = []
            all.reserveCapacity(Self.gridSize)

            outer: for casVHalf in Self.casVHalfGrid {
                for skKd in Self.skKdGrid {
                    for ihGMax in Self.ihGMaxGrid {
                        guard !Task.isCancelled else { break outer }

                        let r = Self.evaluate(
                            casVHalf: casVHalf, skKd: skKd, ihGMax: ihGMax,
                            tauDecay: Self.fixedTauDecay,
                            duration: Self.simDuration)

                        all.append(r)
                        all.sort { $0.score > $1.score }
                        self.results   = all
                        self.doneEvals += 1
                        self.progress  = Double(self.doneEvals) / Double(self.totalEvals)

                        let best = all.first
                        self.status = String(
                            format: "%d/%d — score %.1f (%d bursts, %.0f PA/burst)",
                            self.doneEvals, Self.gridSize,
                            best.map { max($0.score, 0) } ?? 0,
                            best?.burstCount ?? 0,
                            best?.meanAPsPerBurst ?? 0)

                        await Task.yield()   // hand control back to the RunLoop
                    }
                }
            }

            self.isRunning = false
            self.status    = "Terminé — \(all.count) points évalués"
        }
    }

    func stop() {
        sweepTask?.cancel()
        sweepTask  = nil
        isRunning  = false
        status     = "Arrêté"
    }

    /// Apply a sweep result's parameters to the live network in the ViewModel,
    /// then rebuild the simulator so the changes take effect.
    func apply(result: PDSweepResult, vm: SimulationViewModel) {
        vm.pause()

        guard let neuron = vm.network.neurons.first,
              let soma   = neuron.compartments.first
        else { return }

        for ch in soma.channels {
            if let cas = ch as? CaSChannel {
                cas.gateInfOverrides[0] = .sigmoid(
                    lo: 0, hi: 1, vHalf: result.casVHalf, k: 8.5, domain: nil)
            }
            if let sk = ch as? SKChannel {
                sk.halfActivation = result.skKd
            }
            if let ih = ch as? HChannel {
                ih.gMax = result.ihGMax
            }
        }

        // Update Ca²⁺ decay time constant if changed
        if let idx = soma.concentrationDynamics.firstIndex(where: { $0.ionSymbol == "Ca" }) {
            soma.concentrationDynamics[idx].tauDecay = result.tauDecay
        }

        // Rebuild simulator from the mutated network, then reset to -80 mV.
        vm.rebuildSimulatorPublic()
        vm.reset()
    }

    // MARK: - Single-point evaluation (synchronous, @MainActor)

    /// Builds a fresh isolated PD network, runs a simulation, and scores it.
    static func evaluate(casVHalf: Double, skKd: Double, ihGMax: Double,
                         tauDecay: Double, duration: Double) -> PDSweepResult {
        let (net, _, aisID) = buildPDNetwork(casVHalf: casVHalf, skKd: skKd,
                                             ihGMax: ihGMax, tauDecay: tauDecay)
        let sim = Simulator(network: net, dt: 0.025)
        sim.method = .rushLarsen
        sim.reset(restingVoltage: -80.0)

        guard let aisIdx = net.voltageIndex(ofCompartment: aisID) else {
            return PDSweepResult(casVHalf: casVHalf, skKd: skKd, ihGMax: ihGMax,
                                 tauDecay: tauDecay, burstCount: 0, meanAPsPerBurst: 0,
                                 meanPeriodMs: 0, score: -99)
        }

        // Sample AIS voltage every 0.5 ms (20 steps at dt=0.025 ms).
        // Resolution: fine enough to capture Na AP upward crossings reliably.
        let sampleEvery = max(1, Int((0.5 / sim.dt).rounded()))
        var stepN = 0
        var aisSamples: [(t: Double, v: Double)] = []
        aisSamples.reserveCapacity(Int(duration * 2))

        sim.run(duration: duration) { sample in
            stepN += 1
            guard stepN % sampleEvery == 0 else { return }
            // sim.state is updated *before* onSample is called — read AIS directly.
            aisSamples.append((t: sample.time, v: sim.state[aisIdx]))
        }

        let (burstCount, meanAPs, meanPeriod) = detectBursts(samples: aisSamples)
        let score = scoreBurstObjective(burstCount: burstCount, meanAPs: meanAPs,
                                        meanPeriodMs: meanPeriod, durationMs: duration)

        return PDSweepResult(casVHalf: casVHalf, skKd: skKd, ihGMax: ihGMax,
                             tauDecay: tauDecay,
                             burstCount: burstCount, meanAPsPerBurst: meanAPs,
                             meanPeriodMs: meanPeriod, score: score)
    }

    // MARK: - Network factory

    /// Build a fresh two-compartment PD neuron (soma + AIS) with the given parameters.
    static func buildPDNetwork(casVHalf: Double, skKd: Double,
                                ihGMax: Double, tauDecay: Double
    ) -> (network: Network, neuronID: UUID, aisID: UUID) {

        let skCh = SKChannel(gMax: 1.5, reversal: -98.0)
        skCh.halfActivation  = skKd
        skCh.hillCoefficient = 4
        skCh.tauActivation   = 50.0
        skCh.restingCalcium  = 0.0001

        let casCh = CaSChannel(gMax: 1.0, reversal: 132.0)
        casCh.gateInfOverrides[0] = .sigmoid(lo: 0, hi: 1,
                                              vHalf: casVHalf, k: 8.5, domain: nil)

        let soma = Compartment(
            name: "soma",
            capacitance: 1.0, diameter: 200.0, length: 100.0,
            channels: [
                TTypeCalciumChannel(gMax: 1.0,  reversal: 132.0),
                casCh,
                PotassiumChannel(gMax: 5.0,     reversal: -98.0),
                HChannel(gMax: ihGMax,           reversal: -43.0),
                ATypeChannel(gMax: 0.5,          reversal: -98.0),
                skCh,
                LeakChannel(gMax: 0.03,          reversal: -60.0),
            ],
            concentrationDynamics: [
                ConcentrationDynamic(ionSymbol: "Ca",
                                     restingConc: 0.0001,
                                     tauDecay: tauDecay)
            ]
        )

        let ais = Compartment(
            name: "AIS",
            capacitance: 1.0, diameter: 5.0, length: 10.0,
            channels: [
                SodiumChannel(gMax: 80.0,    reversal:  67.0),
                PotassiumChannel(gMax: 15.0,  reversal: -98.0),
                LeakChannel(gMax: 0.1,        reversal: -65.0),
            ]
        )

        let coupling = AxialCoupling(between: soma.id, and: ais.id, conductance: 0.25)
        let neuron   = HHNeuron(name: "PD",
                                compartments: [soma, ais],
                                couplings: [coupling],
                                soma: soma.id)
        let net = Network()
        net.addNeuron(neuron)
        return (net, neuron.id, ais.id)
    }

}
// Note: detectBursts() and scoreBurstObjective() are free functions in
// OptimObjective.swift — called directly in evaluate() without a wrapper.
