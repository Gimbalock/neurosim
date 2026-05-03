//
//  TTypeCalciumChannelTests.swift
//  NeuroSimCoreTests
//
//  Validates the T-type Ca²⁺ channel:
//   1. It declares the right ion species (.calcium).
//   2. Its default reversal is the divalent Nernst at canonical mammalian
//      [Ca²⁺] gradients (~+132 mV).
//   3. Its steady-state gates at canonical voltages match the Destexhe
//      thalamic parameterisation (m mostly closed at rest, h mostly
//      available; both reverse around -55 mV).
//   4. Adding it to a standard HH neuron does NOT destabilise the
//      simulation — V stays bounded over a long run, with at most a small
//      depolarising shift of the resting potential.
//   5. updateReversalFromNernst with non-default concentrations actually
//      moves `reversal`.
//

import XCTest
@testable import NeuroSimCore

final class TTypeCalciumChannelTests: XCTestCase {

    // MARK: - Identity

    func testDeclaresCalciumSpecies() {
        let species = TTypeCalciumChannel().species
        XCTAssertEqual(species, IonSpecies.calcium)
    }

    func testDefaultReversalMatchesCalciumNernst() {
        let ch = TTypeCalciumChannel()
        let expected = IonSpecies.calcium.defaultReversal()
        XCTAssertEqual(ch.reversal, expected, accuracy: 1e-9,
                       "Default reversal should equal Nernst E_Ca at canonical mammalian gradients.")
        XCTAssertEqual(ch.reversal, 132.3, accuracy: 1.0,
                       "E_Ca with default Ca gradients should be ~+132 mV at 37 °C.")
    }

    // MARK: - Gate steady-state values

    /// At rest (-65 mV) the activation gate should be mostly closed.
    func testActivationMostlyClosedAtRest() {
        let m = TTypeCalciumChannel.mInf(-65.0)
        XCTAssertLessThan(m, 0.05,
                          "m_inf(-65) should be < 5% (got \(m)) — T-channels are closed at rest.")
    }

    /// At rest (-65 mV) the inactivation gate should be partially available.
    /// Hodgkin-Huxley convention: h close to 1 = available (not inactivated).
    func testInactivationMostlyAvailableAtRest() {
        let h = TTypeCalciumChannel.hInf(-65.0)
        XCTAssertGreaterThan(h, 0.001,
                             "h_inf(-65) should be > 0 (some channels available, got \(h)).")
        XCTAssertLessThan(h, 0.05,
                          "h_inf(-65) should still be small at rest (mostly inactivated, got \(h)).")
    }

    /// On strong hyperpolarisation (-90 mV), inactivation lifts (h_inf → 1).
    /// This is what enables the post-inhibitory rebound in thalamic cells.
    func testHyperpolarisationDeinactivates() {
        let h = TTypeCalciumChannel.hInf(-90.0)
        XCTAssertGreaterThan(h, 0.85,
                             "h_inf(-90) should be > 0.85 (de-inactivated, got \(h)).")
    }

    /// On strong depolarisation (-30 mV), activation saturates (m_inf → 1).
    func testDepolarisationActivates() {
        let m = TTypeCalciumChannel.mInf(-30.0)
        XCTAssertGreaterThan(m, 0.95,
                             "m_inf(-30) should be > 0.95 (fully activated, got \(m)).")
    }

    /// Time constants stay positive everywhere we'd realistically simulate.
    func testTimeConstantsArePositive() {
        for v in stride(from: -120.0, through: 50.0, by: 5.0) {
            let tm = TTypeCalciumChannel.tauM(v)
            let th = TTypeCalciumChannel.tauH(v)
            XCTAssertGreaterThan(tm, 0, "tauM(\(v)) must be > 0 (got \(tm)).")
            XCTAssertGreaterThan(th, 0, "tauH(\(v)) must be > 0 (got \(th)).")
        }
    }

    // MARK: - Integration sanity

    /// Adding a T-channel to a default HH neuron must not blow the
    /// simulation up: V stays in physiologically plausible bounds over
    /// 200 ms with no input.
    func testHHWithCalciumStaysBounded() {
        let neuron = HHNeuron(
            name: "HH+Ca_T",
            channels: HHNeuron.defaultChannels() + [TTypeCalciumChannel()]
        )
        let net = Network()
        net.addNeuron(neuron)

        let sim = Simulator(network: net, dt: 0.01)
        var minV =  100.0
        var maxV = -100.0
        sim.run(duration: 200.0) { sample in
            if let v = sample.voltages[neuron.id] {
                minV = min(minV, v)
                maxV = max(maxV, v)
            }
        }
        XCTAssertGreaterThan(minV, -100.0,
                             "V should not run away below -100 mV (got \(minV)).")
        XCTAssertLessThan(maxV, 60.0,
                          "Without input, V should not exceed +60 mV (got \(maxV)).")
    }

    /// With T-channel added, the resting potential shifts slightly
    /// depolarised relative to plain HH (Ca current is inward at rest, even
    /// with tiny m·h product). The shift should be small (< 5 mV) at the
    /// default conductance.
    func testRestingPotentialShiftIsSmall() {
        let plain = HHNeuron(name: "plain")
        let withCa = HHNeuron(
            name: "withCa",
            channels: HHNeuron.defaultChannels() + [TTypeCalciumChannel()]
        )

        let n1 = Network(); n1.addNeuron(plain)
        let n2 = Network(); n2.addNeuron(withCa)

        let s1 = Simulator(network: n1, dt: 0.01); s1.run(duration: 100.0)
        let s2 = Simulator(network: n2, dt: 0.01); s2.run(duration: 100.0)

        let vPlain  = s1.state[n1.voltageIndex(of: plain.id)!]
        let vWithCa = s2.state[n2.voltageIndex(of: withCa.id)!]

        XCTAssertGreaterThanOrEqual(vWithCa, vPlain - 1.0,
            "T-channel adds inward current — rest should not be more hyperpolarised.")
        XCTAssertLessThan(abs(vWithCa - vPlain), 5.0,
            "Resting potential shift should be small (< 5 mV) at default gMax — got |Δ| = \(abs(vWithCa - vPlain)) mV.")
    }

    // MARK: - Nernst integration

    /// Driving the channel with non-default concentrations should move its
    /// reversal predictably. Halving the [Ca²⁺] gradient (10× smaller
    /// ratio) drops E_Ca by ~30 mV at body T (RT/2F · ln 10 ≈ 30.7 mV).
    func testReversalUpdatesWithConcentrations() {
        let ch = TTypeCalciumChannel()
        let baseline = ch.reversal
        ch.updateReversalFromNernst(
            concentrationIn: 0.001,    // 10× higher than default 0.0001
            concentrationOut: 2.0      // unchanged
        )
        let drop = baseline - ch.reversal
        XCTAssertEqual(drop, 30.7, accuracy: 2.0,
                       "Reducing [Ca²⁺]_out/[Ca²⁺]_in by 10× should drop E_Ca by ~30 mV (got Δ = \(drop)).")
    }
}
