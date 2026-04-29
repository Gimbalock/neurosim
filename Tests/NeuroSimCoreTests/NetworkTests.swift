//
//  NetworkTests.swift
//  NeuroSimCoreTests
//

import XCTest
@testable import NeuroSimCore

final class NetworkTests: XCTestCase {

    /// A pre-synaptic neuron driven to fire should propagate excitation to a
    /// post-synaptic neuron through a strong AMPA-like synapse.
    func testExcitatorySynapsePropagatesActivity() {
        let net = Network()
        let pre  = HHNeuron(name: "pre")
        let post = HHNeuron(name: "post")
        net.addNeuron(pre)
        net.addNeuron(post)

        // Drive the pre-synaptic neuron tonically.
        net.setStimulus(ConstantStimulus(amplitude: 10), on: pre.id)

        // Strong excitatory synapse so the post neuron is depolarised
        // measurably even on a single PSP.
        net.addSynapse(ChemicalSynapse(
            from: pre.id, to: post.id,
            gMax: 1.0, reversal: 0.0, tauDecay: 8.0
        ))

        let sim = Simulator(network: net, dt: 0.01)

        var maxPostV = -1000.0
        var spikesPost = 0
        var prevPostV = -65.0
        sim.run(duration: 200.0) { sample in
            if let v = sample.voltages[post.id] {
                maxPostV = max(maxPostV, v)
                if prevPostV < 0 && v >= 0 { spikesPost += 1 }
                prevPostV = v
            }
        }
        XCTAssertGreaterThan(maxPostV, -50.0,
            "Post neuron never depolarised — synapse not coupling? (max V = \(maxPostV))")
        // It's fine whether the post neuron itself spikes or just gets PSPs;
        // the key invariant is that pre activity affects post.
        XCTAssertGreaterThanOrEqual(spikesPost, 0)
    }

    /// An inhibitory synapse with E_rev = -75 mV should hyperpolarise the post
    /// neuron, suppressing or delaying spikes that a baseline drive would
    /// otherwise produce.
    func testInhibitorySynapseSuppressesPostNeuron() {
        let baseline = countSpikesInIsolatedDrive()
        XCTAssertGreaterThan(baseline, 5, "Baseline drive should fire several spikes.")

        // Now add an inhibitory pre neuron that fires faster than the post.
        let net = Network()
        let pre  = HHNeuron(name: "pre")
        let post = HHNeuron(name: "post")
        net.addNeuron(pre)
        net.addNeuron(post)
        net.setStimulus(ConstantStimulus(amplitude: 15), on: pre.id) // fires faster
        net.setStimulus(ConstantStimulus(amplitude: 8),  on: post.id)
        net.addSynapse(ChemicalSynapse(
            from: pre.id, to: post.id,
            gMax: 1.0, reversal: -75.0, tauDecay: 12.0
        ))
        let sim = Simulator(network: net, dt: 0.01)
        var spikesPost = 0
        var prevV = -65.0
        sim.run(duration: 300.0) { sample in
            if let v = sample.voltages[post.id] {
                if prevV < 0 && v >= 0 { spikesPost += 1 }
                prevV = v
            }
        }
        XCTAssertLessThan(spikesPost, baseline,
            "Inhibition should reduce post firing (got \(spikesPost) vs \(baseline)).")
    }

    /// Removing a neuron also tears down every synapse touching it.
    func testRemoveNeuronCleansUpSynapses() {
        let net = Network()
        let a = HHNeuron(name: "a")
        let b = HHNeuron(name: "b")
        net.addNeuron(a)
        net.addNeuron(b)
        net.addSynapse(ChemicalSynapse(from: a.id, to: b.id))
        net.addSynapse(ChemicalSynapse(from: b.id, to: a.id))

        XCTAssertEqual(net.synapses.count, 2)
        net.removeNeuron(id: a.id)
        XCTAssertEqual(net.synapses.count, 0)
        XCTAssertEqual(net.neurons.count, 1)
    }

    // Helper
    private func countSpikesInIsolatedDrive() -> Int {
        let net = Network()
        let n = HHNeuron()
        net.addNeuron(n)
        net.setStimulus(ConstantStimulus(amplitude: 8), on: n.id)
        let sim = Simulator(network: net, dt: 0.01)
        var spikes = 0
        var prev = -65.0
        sim.run(duration: 300.0) { sample in
            if let v = sample.voltages[n.id] {
                if prev < 0 && v >= 0 { spikes += 1 }
                prev = v
            }
        }
        return spikes
    }
}
