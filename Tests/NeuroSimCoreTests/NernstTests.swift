//
//  NernstTests.swift
//  NeuroSimCoreTests
//
//  Sanity-checks for IonSpecies, the Nernst equation, GHK voltage equation,
//  and the IonChannel.updateReversalFromNernst helper.
//
//  The expected values are the canonical mammalian numbers every neuroscience
//  textbook prints — slipping outside their tolerance is a load-bearing
//  signal that something has broken.
//

import XCTest
@testable import NeuroSimCore

final class NernstTests: XCTestCase {

    // MARK: - Canonical reversal potentials at 37 °C (mammalian)

    /// E_Na with [out]/[in] = 145/15 should sit close to +60 mV.
    func testSodiumReversalAtBodyT() {
        let e = Nernst.reversalPotential(
            species: .sodium,
            concentrationIn: 15.0,
            concentrationOut: 145.0
        )
        XCTAssertEqual(e, 60.6, accuracy: 1.0,
                       "E_Na should be ~+60 mV at 37 °C, got \(e).")
    }

    /// E_K with [out]/[in] = 4/140 should be close to -95 mV.
    func testPotassiumReversalAtBodyT() {
        let e = Nernst.reversalPotential(
            species: .potassium,
            concentrationIn: 140.0,
            concentrationOut: 4.0
        )
        XCTAssertEqual(e, -94.96, accuracy: 1.0,
                       "E_K should be ~-95 mV at 37 °C, got \(e).")
    }

    /// E_Ca with [out]/[in] = 2 / 1e-4 (typical free [Ca²⁺]_in ~100 nM) →
    /// ~+132 mV. Note the divisor of 2 from the divalent valence.
    func testCalciumReversalAtBodyT() {
        let e = Nernst.reversalPotential(
            species: .calcium,
            concentrationIn: 0.0001,
            concentrationOut: 2.0
        )
        XCTAssertEqual(e, 132.3, accuracy: 1.0,
                       "E_Ca should be ~+132 mV at 37 °C with free Ca_in = 100 nM, got \(e).")
    }

    /// E_Cl with [out]/[in] = 110/10 should be close to -64 mV
    /// (negative valence flips the sign of the coefficient).
    func testChlorideReversalAtBodyT() {
        let e = Nernst.reversalPotential(
            species: .chloride,
            concentrationIn: 10.0,
            concentrationOut: 110.0
        )
        XCTAssertEqual(e, -64.06, accuracy: 1.0,
                       "E_Cl should be ~-64 mV at 37 °C, got \(e).")
    }

    /// IonSpecies.defaultReversal must agree with calling Nernst with the
    /// species' default concentrations.
    func testDefaultReversalMatchesNernst() {
        for sp in [IonSpecies.sodium, .potassium, .calcium, .chloride] {
            let direct = Nernst.reversalPotential(
                species: sp,
                concentrationIn: sp.defaultConcentrationIn,
                concentrationOut: sp.defaultConcentrationOut
            )
            XCTAssertEqual(sp.defaultReversal(), direct, accuracy: 1e-9,
                           "defaultReversal disagrees with Nernst for \(sp.symbol).")
        }
    }

    // MARK: - Temperature dependence

    /// The classical HH paper uses 6.3 °C — at that T, the same Na gradient
    /// gives a *smaller* E_Na (about 55 mV) because (RT/F) shrinks with T.
    func testNernstShrinksAtLowerTemperature() {
        let eBody = Nernst.reversalPotential(
            species: .sodium,
            concentrationIn: 15.0,
            concentrationOut: 145.0,
            temperatureK: Nernst.mammalianBodyTemperatureK
        )
        let eSquid = Nernst.reversalPotential(
            species: .sodium,
            concentrationIn: 15.0,
            concentrationOut: 145.0,
            temperatureK: Nernst.squidTemperatureK
        )
        XCTAssertGreaterThan(eBody, eSquid,
                             "E_Na should be larger at 37 °C (\(eBody)) than at 6.3 °C (\(eSquid)).")
        XCTAssertEqual(eSquid, 54.6, accuracy: 1.0,
                       "E_Na at 6.3 °C should be ~+55 mV, got \(eSquid).")
    }

    // MARK: - GHK

    /// GHK applied to the classical resting setup (P_K : P_Na : P_Cl = 1 :
    /// 0.04 : 0.45 with mammalian concentrations) should give a resting V
    /// in the -65 to -75 mV neighbourhood.
    func testGHKResemblesResting() {
        let v = Nernst.ghkVoltage(contributions: [
            .init(species: .potassium,
                  permeability: 1.00,
                  concentrationIn: 140, concentrationOut: 4),
            .init(species: .sodium,
                  permeability: 0.04,
                  concentrationIn: 15,  concentrationOut: 145),
            .init(species: .chloride,
                  permeability: 0.45,
                  concentrationIn: 10,  concentrationOut: 110)
        ])
        XCTAssertEqual(v, -70.0, accuracy: 8.0,
                       "GHK with Hodgkin-Katz canonical permeabilities should give ~-70 mV, got \(v).")
    }

    // MARK: - Channel integration

    /// Asking a SodiumChannel to refresh its reversal from concentrations
    /// should park it at exactly E_Na for those concentrations.
    func testSodiumChannelUpdatesReversal() {
        let ch = SodiumChannel()
        XCTAssertEqual(ch.reversal, 50.0, "SodiumChannel default reversal mismatch.")
        ch.updateReversalFromNernst(concentrationIn: 15, concentrationOut: 145)
        XCTAssertEqual(ch.reversal, 60.6, accuracy: 1.0,
                       "SodiumChannel.reversal should be Nernst-driven after update.")
    }

    /// LeakChannel has no declared species — Nernst update must be a no-op
    /// (it's a mixed-ion leak, fixed reversal is the right model).
    func testLeakChannelIgnoresNernstUpdate() {
        let ch = LeakChannel()
        let originalReversal = ch.reversal
        ch.updateReversalFromNernst(concentrationIn: 15, concentrationOut: 145)
        XCTAssertEqual(ch.reversal, originalReversal,
                       "LeakChannel reversal must not change — it has no declared species.")
        XCTAssertNil(ch.species, "LeakChannel.species should be nil (mixed/non-selective).")
    }

    /// Sanity: Na and K channels declare the right species.
    func testCanonicalChannelsDeclareTheirSpecies() {
        let na = SodiumChannel().species
        let k  = PotassiumChannel().species
        XCTAssertEqual(na, IonSpecies.sodium)
        XCTAssertEqual(k,  IonSpecies.potassium)
    }

    // MARK: - Pre-conditions / robustness

    /// Equal concentrations in/out → zero reversal regardless of valence.
    func testEqualConcentrationsGiveZeroReversal() {
        for sp in [IonSpecies.sodium, .potassium, .calcium, .chloride] {
            let e = Nernst.reversalPotential(species: sp,
                                             concentrationIn: 10.0,
                                             concentrationOut: 10.0)
            XCTAssertEqual(e, 0.0, accuracy: 1e-9,
                           "Equal concentrations must yield E = 0 (got \(e) for \(sp.symbol)).")
        }
    }
}
