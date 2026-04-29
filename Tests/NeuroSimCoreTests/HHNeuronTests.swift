//
//  HHNeuronTests.swift
//  NeuroSimCoreTests
//

import XCTest
@testable import NeuroSimCore

final class HHNeuronTests: XCTestCase {

    /// At rest with no input, the neuron should sit close to V_rest and stay
    /// there — the steady-state gates make ionic currents balance to ~0.
    func testRestingStateIsStable() {
        let network = Network()
        let neuron = HHNeuron(name: "rest")
        network.addNeuron(neuron)

        let sim = Simulator(network: network, dt: 0.01)
        sim.run(duration: 50.0)

        let v = sim.state[network.voltageIndex(of: neuron.id)!]
        XCTAssertEqual(v, -65.0, accuracy: 1.0,
                       "Resting potential drifted by more than 1 mV in 50 ms.")
    }

    /// A 10 µA/cm² square pulse should fire at least one spike.
    func testSuprathresholdPulseFiresSpike() {
        let network = Network()
        let neuron = HHNeuron(name: "test")
        network.addNeuron(neuron)
        network.setStimulus(PulseStimulus(start: 5, duration: 30, amplitude: 10),
                            on: neuron.id)

        let sim = Simulator(network: network, dt: 0.01)
        var peakV = -100.0
        sim.run(duration: 50.0) { sample in
            if let v = sample.voltages[neuron.id] { peakV = max(peakV, v) }
        }
        XCTAssertGreaterThan(peakV, 20.0,
                             "Expected a spike (V > 20 mV), got peak V = \(peakV).")
    }

    /// A weak 1 µA/cm² stimulus should NOT trigger a full action potential.
    func testSubthresholdPulseDoesNotFire() {
        let network = Network()
        let neuron = HHNeuron(name: "sub")
        network.addNeuron(neuron)
        network.setStimulus(PulseStimulus(start: 5, duration: 30, amplitude: 1.0),
                            on: neuron.id)

        let sim = Simulator(network: network, dt: 0.01)
        var peakV = -100.0
        sim.run(duration: 50.0) { sample in
            if let v = sample.voltages[neuron.id] { peakV = max(peakV, v) }
        }
        XCTAssertLessThan(peakV, 0.0,
                          "Subthreshold input shouldn't elicit a spike (peak V = \(peakV)).")
    }

    /// A 10 µA/cm² sustained input should produce repetitive firing — count
    /// spikes by upward threshold crossings.
    func testRepetitiveFiringUnderSustainedInput() {
        let network = Network()
        let neuron = HHNeuron(name: "tonic")
        network.addNeuron(neuron)
        network.setStimulus(ConstantStimulus(amplitude: 10), on: neuron.id)

        let sim = Simulator(network: network, dt: 0.01)
        var spikes = 0
        var prevV = -65.0
        sim.run(duration: 200.0) { sample in
            if let v = sample.voltages[neuron.id] {
                if prevV < 0 && v >= 0 { spikes += 1 }
                prevV = v
            }
        }
        // HH at I=10 µA/cm² fires at ~60-70 Hz → ~12-14 spikes in 200 ms.
        XCTAssertGreaterThan(spikes, 5, "Expected tonic firing (got \(spikes) spikes).")
        XCTAssertLessThan(spikes, 30, "Firing rate suspiciously high (\(spikes) spikes).")
    }

    /// The standard HH at 10 µA/cm² fires close to 60–70 Hz. Be lax about the
    /// exact rate (RK4 dt=0.01 is enough for ~1% accuracy on the period) but
    /// catch gross errors.
    func testFiringRateIsInExpectedRange() {
        let network = Network()
        let neuron = HHNeuron(name: "rate")
        network.addNeuron(neuron)
        network.setStimulus(ConstantStimulus(amplitude: 10), on: neuron.id)

        let sim = Simulator(network: network, dt: 0.01)
        var spikeTimes: [Double] = []
        var prevV = -65.0
        sim.run(duration: 500.0) { sample in
            if let v = sample.voltages[neuron.id] {
                if prevV < 0 && v >= 0 { spikeTimes.append(sample.time) }
                prevV = v
            }
        }
        // Drop the first two spikes (transient) and look at steady ISI.
        let isis = zip(spikeTimes.dropFirst(2), spikeTimes.dropFirst(3))
            .map { $1 - $0 }
        guard let avgISI = isis.isEmpty ? nil : isis.reduce(0,+) / Double(isis.count) else {
            XCTFail("Not enough spikes to compute an ISI."); return
        }
        let rate = 1000.0 / avgISI // Hz
        XCTAssertEqual(rate, 65.0, accuracy: 15.0,
                       "Firing rate \(rate) Hz outside expected band 50-80 Hz.")
    }
}
