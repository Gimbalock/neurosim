//
//  DendriticTargetingTests.swift
//  NeuroSimCoreTests
//
//  Validates that stimuli and synapses can be targeted at non-soma
//  compartments and that the resulting voltage transients are filtered
//  through the axial coupling — i.e. the dendrite sees a bigger signal,
//  the soma a smaller (cable-filtered) one.
//

import XCTest
@testable import NeuroSimCore

final class DendriticTargetingTests: XCTestCase {

    // MARK: - Helper: build a soma + passive-dendrite neuron

    private func makeTwoCompartmentNeuron(
        couplingConductance: Double = 0.3
    ) -> (HHNeuron, Compartment, Compartment) {
        let soma = Compartment(name: "soma",
                               channels: HHNeuron.defaultChannels())
        let dend = Compartment(name: "dend",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let neuron = HHNeuron(
            name: "soma+dend",
            compartments: [soma, dend],
            couplings: [AxialCoupling(between: soma.id, and: dend.id,
                                      conductance: couplingConductance)],
            soma: soma.id
        )
        return (neuron, soma, dend)
    }

    // MARK: - Stimuli

    /// A current injected on the dendrite must depolarise the dendrite
    /// MORE than it depolarises the soma — that's the whole point of having
    /// distinct compartments and an axial resistance between them.
    func testDendriticStimulusFiltersOnTheWayToSoma() {
        let (neuron, soma, dend) = makeTwoCompartmentNeuron(couplingConductance: 0.3)
        let net = Network()
        net.addNeuron(neuron)
        net.setStimulus(ConstantStimulus(amplitude: 4.0),
                        onCompartment: dend.id)

        let sim = Simulator(network: net, dt: 0.01)
        sim.run(duration: 100.0)

        let vSoma = sim.state[net.voltageIndex(ofCompartment: soma.id)!]
        let vDend = sim.state[net.voltageIndex(ofCompartment: dend.id)!]

        // Dendrite has the stim and only leak — its rest shifts strongly.
        // Soma has full HH; the same drive arrives only through the axial
        // coupling, so soma depolarises less than the dendrite.
        let depDend = vDend - (-65.0)
        let depSoma = vSoma - (-65.0)
        XCTAssertGreaterThan(depDend, 1.0,
            "Dendrite should depolarise (Δ = \(depDend) mV).")
        XCTAssertGreaterThan(depDend, depSoma,
            "Dendrite should be more depolarised than soma (dend = \(depDend), soma = \(depSoma) mV).")
    }

    /// Tighter axial coupling = soma and dendrite closer to equipotential.
    /// Looser coupling = bigger gradient between them under the same drive.
    func testTighterCouplingReducesVoltageGradient() {
        func gradientUnderDendriticDrive(coupling g: Double) -> Double {
            let (neuron, soma, dend) = makeTwoCompartmentNeuron(couplingConductance: g)
            let net = Network()
            net.addNeuron(neuron)
            net.setStimulus(ConstantStimulus(amplitude: 4.0),
                            onCompartment: dend.id)
            let sim = Simulator(network: net, dt: 0.01)
            sim.run(duration: 100.0)
            return sim.state[net.voltageIndex(ofCompartment: dend.id)!]
                 - sim.state[net.voltageIndex(ofCompartment: soma.id)!]
        }
        let gradTight = gradientUnderDendriticDrive(coupling: 5.0)
        let gradLoose = gradientUnderDendriticDrive(coupling: 0.05)
        XCTAssertLessThan(gradTight, gradLoose,
            "Tighter coupling (g=5) should give a smaller V gradient than loose (g=0.05). Got tight=\(gradTight), loose=\(gradLoose).")
    }

    // MARK: - Synapses

    /// A synapse landing on the dendrite must produce a measurably smaller
    /// somatic PSP than the same synapse landing on the soma — that's the
    /// canonical "dendritic filtering" of EPSPs.
    func testDendriticSynapsePSPSmallerAtSomaThanSomaticSynapsePSP() {
        // Two identical post-synaptic neurons; the same pre fires on both
        // through identical synapses, but one targets the dendrite and the
        // other targets the soma. Compare somatic PSP heights.

        // --- Build network ---
        let pre = HHNeuron(name: "pre")  // single-compartment driver
        let (postDend, _, dendOfDend) = makeTwoCompartmentNeuron(couplingConductance: 0.3)
        postDend.name = "post_dend"
        let (postSoma, somaOfSoma, _) = makeTwoCompartmentNeuron(couplingConductance: 0.3)
        postSoma.name = "post_soma"

        let net = Network()
        net.addNeuron(pre)
        net.addNeuron(postDend)
        net.addNeuron(postSoma)

        // Drive the pre neuron with one short pulse → exactly one spike.
        net.setStimulus(PulseStimulus(start: 5, duration: 5, amplitude: 15),
                        on: pre.id)

        // Identical synapses — only the target compartment differs.
        // gMax kept low enough to stay sub-threshold on the soma so we can
        // compare PSP amplitudes (a supra-threshold synapse would clip both
        // signals at the spike peak and the comparison would be meaningless).
        let synParams: (gMax: Double, tauDecay: Double, rev: Double) = (0.1, 8.0, 0.0)
        net.addSynapse(ChemicalSynapse(
            from: pre.id, to: postDend.id,
            onCompartment: dendOfDend.id,
            gMax: synParams.gMax, reversal: synParams.rev, tauDecay: synParams.tauDecay
        ))
        net.addSynapse(ChemicalSynapse(
            from: pre.id, to: postSoma.id,
            onCompartment: somaOfSoma.id,
            gMax: synParams.gMax, reversal: synParams.rev, tauDecay: synParams.tauDecay
        ))

        // --- Run and record peak somatic depolarisation ---
        let sim = Simulator(network: net, dt: 0.01)
        var peakSomaDend = -1000.0
        var peakSomaSoma = -1000.0
        sim.run(duration: 80.0) { sample in
            if let v = sample.voltages[postDend.id] { peakSomaDend = max(peakSomaDend, v) }
            if let v = sample.voltages[postSoma.id] { peakSomaSoma = max(peakSomaSoma, v) }
        }

        // The dendritically-targeted synapse must produce a *smaller* somatic
        // PSP than the somatically-targeted one — that's dendritic filtering.
        let pspDend = peakSomaDend - (-65.0)
        let pspSoma = peakSomaSoma - (-65.0)
        XCTAssertGreaterThan(pspDend, 0.5,
            "Dendritic synapse should still produce *some* somatic PSP (got Δ = \(pspDend) mV).")
        XCTAssertLessThan(pspDend, pspSoma,
            "Dendritic synapse PSP at soma (\(pspDend) mV) should be < somatic synapse PSP (\(pspSoma) mV).")
    }

    /// Removing a stimulus targeting a dendrite must clear it.
    func testRemovingDendriticStimulus() {
        let (neuron, _, dend) = makeTwoCompartmentNeuron()
        let net = Network()
        net.addNeuron(neuron)
        net.setStimulus(ConstantStimulus(amplitude: 5), onCompartment: dend.id)
        XCTAssertNotNil(net.stimuli[dend.id])
        net.setStimulus(nil, onCompartment: dend.id)
        XCTAssertNil(net.stimuli[dend.id])
    }
}
