//
//  MultiCompartmentTests.swift
//  NeuroSimCoreTests
//
//  Integration tests for Step 1b — multi-compartment neurons coupled by
//  AxialCoupling. Three flavours of check:
//
//   1. Backward-compat: single-compartment HHNeurons behave identically to
//      the pre-Step-1b version (delegated to the existing HH and Network
//      tests; here we just sanity-check the API).
//   2. Passive cable: two leak-only compartments coupled, current injected
//      into one. We verify the gradient direction, the equivalence under
//      tight coupling, and the isolation under loose coupling.
//   3. Soma + passive dendrite: an HH soma firing, with a passive dendrite
//      attached. The dendrite tracks soma fluctuations with attenuation.
//

import XCTest
@testable import NeuroSimCore

final class MultiCompartmentTests: XCTestCase {

    // MARK: - Backward compatibility

    /// A default-constructed HHNeuron must still be a one-compartment HH —
    /// same stateCount, same channel list shape, soma is the lone compartment.
    func testSingleCompartmentDefaultIsBackwardCompatible() {
        let n = HHNeuron(name: "compat")
        XCTAssertEqual(n.compartments.count, 1)
        XCTAssertTrue(n.axialCouplings.isEmpty)
        XCTAssertEqual(n.somaCompartmentID, n.compartments[0].id)
        XCTAssertEqual(n.stateCount, 4) // 1 V + 3 HH gates
        XCTAssertEqual(n.channels.count, 3) // soma channels, via shim
    }

    /// The `channels` shim must read the soma's channels and writes must
    /// land on the soma compartment.
    func testChannelsShimAliasesSoma() {
        let n = HHNeuron(name: "shim")
        XCTAssertEqual(n.channels.count, n.soma.channels.count)
        n.channels = [LeakChannel()]
        XCTAssertEqual(n.soma.channels.count, 1)
        XCTAssertEqual(n.stateCount, 1) // Leak has zero gates.
    }

    // MARK: - Passive cable: tight coupling

    /// With a very large axial conductance, the two compartments are
    /// effectively isopotential — V_dendrite should track V_soma closely
    /// even when current is injected only at the soma.
    func testTightCouplingMakesCompartmentsIsopotential() {
        let soma = Compartment(name: "soma",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let dend = Compartment(name: "dend",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let neuron = HHNeuron(
            name: "tight",
            compartments: [soma, dend],
            couplings: [AxialCoupling(between: soma.id, and: dend.id,
                                      conductance: 100.0)],   // very tight
            soma: soma.id
        )
        let net = Network()
        net.addNeuron(neuron)
        net.setStimulus(ConstantStimulus(amplitude: 2.0), on: neuron.id)

        let sim = Simulator(network: net, dt: 0.01)
        sim.run(duration: 200.0)

        let vSoma = sim.state[net.voltageIndex(ofCompartment: soma.id)!]
        let vDend = sim.state[net.voltageIndex(ofCompartment: dend.id)!]
        XCTAssertEqual(vSoma, vDend, accuracy: 0.5,
                       "Tight axial coupling should equalise soma and dendrite (got \(vSoma) vs \(vDend)).")
    }

    // MARK: - Passive cable: loose coupling

    /// With a tiny axial conductance, the dendrite stays close to its rest
    /// while the soma depolarises noticeably under injection.
    func testLooseCouplingIsolatesCompartments() {
        let soma = Compartment(name: "soma",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let dend = Compartment(name: "dend",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let neuron = HHNeuron(
            name: "loose",
            compartments: [soma, dend],
            couplings: [AxialCoupling(between: soma.id, and: dend.id,
                                      conductance: 0.001)],   // nearly disconnected
            soma: soma.id
        )
        let net = Network()
        net.addNeuron(neuron)
        net.setStimulus(ConstantStimulus(amplitude: 2.0), on: neuron.id)

        let sim = Simulator(network: net, dt: 0.01)
        sim.run(duration: 200.0)

        let vSoma = sim.state[net.voltageIndex(ofCompartment: soma.id)!]
        let vDend = sim.state[net.voltageIndex(ofCompartment: dend.id)!]

        XCTAssertGreaterThan(vSoma, -60.0,
                             "Soma should depolarise under 2 µA/cm² injection (got \(vSoma)).")
        XCTAssertLessThan(vDend, vSoma - 1.0,
                          "Loose coupling must leave a clear gradient: V_soma > V_dend (got soma \(vSoma), dend \(vDend)).")
        XCTAssertEqual(vDend, -65.0, accuracy: 1.0,
                       "Dendrite should sit near rest with near-zero coupling (got \(vDend)).")
    }

    // MARK: - Sign / propagation

    /// Current injected into the soma must depolarise the dendrite (not
    /// hyperpolarise it). Catches sign flips in axial-current bookkeeping.
    func testInjectedCurrentSpreadsPositively() {
        let soma = Compartment(name: "soma",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let dend = Compartment(name: "dend",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let neuron = HHNeuron(
            name: "spread",
            compartments: [soma, dend],
            couplings: [AxialCoupling(between: soma.id, and: dend.id,
                                      conductance: 1.0)],
            soma: soma.id
        )
        let net = Network()
        net.addNeuron(neuron)
        net.setStimulus(ConstantStimulus(amplitude: 3.0), on: neuron.id)

        let sim = Simulator(network: net, dt: 0.01)
        sim.run(duration: 200.0)

        let vDend = sim.state[net.voltageIndex(ofCompartment: dend.id)!]
        XCTAssertGreaterThan(vDend, -65.0,
                             "Dendrite must depolarise (V > rest) when soma is current-injected, got \(vDend).")
    }

    // MARK: - HH soma + passive dendrite

    /// An HH soma fires under sustained 10 µA/cm². A passive dendrite
    /// attached to it should oscillate too (driven by spike electrotonus)
    /// but with strictly smaller amplitude than the soma.
    func testHHSomaWithPassiveDendriteAttenuates() {
        let soma = Compartment(name: "soma",
                               channels: HHNeuron.defaultChannels())
        let dend = Compartment(name: "dend",
                               channels: [LeakChannel(gMax: 0.3, reversal: -65)])
        let neuron = HHNeuron(
            name: "soma+dend",
            compartments: [soma, dend],
            couplings: [AxialCoupling(between: soma.id, and: dend.id,
                                      conductance: 0.5)],
            soma: soma.id
        )
        let net = Network()
        net.addNeuron(neuron)
        net.setStimulus(ConstantStimulus(amplitude: 10.0), on: neuron.id)

        let sim = Simulator(network: net, dt: 0.01)

        var maxSoma = -100.0, maxDend = -100.0
        var minSoma =  100.0, minDend =  100.0
        let somaIdx = net.voltageIndex(ofCompartment: soma.id)!
        let dendIdx = net.voltageIndex(ofCompartment: dend.id)!

        sim.run(duration: 200.0) { _ in
            let vS = sim.state[somaIdx]
            let vD = sim.state[dendIdx]
            maxSoma = max(maxSoma, vS); minSoma = min(minSoma, vS)
            maxDend = max(maxDend, vD); minDend = min(minDend, vD)
        }

        let ampSoma = maxSoma - minSoma
        let ampDend = maxDend - minDend

        XCTAssertGreaterThan(maxSoma, 20.0,
                             "Soma should produce real spikes (peak > 20 mV), got \(maxSoma).")
        XCTAssertGreaterThan(ampDend, 0.5,
                             "Dendrite should ripple in response to soma spikes (got Δ = \(ampDend) mV).")
        XCTAssertLessThan(ampDend, ampSoma,
                          "Dendrite amplitude must be strictly attenuated relative to soma (\(ampDend) vs \(ampSoma)).")
    }
}
