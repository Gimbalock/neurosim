//
//  CompartmentTests.swift
//  NeuroSimCoreTests
//
//  Verifies Compartment in isolation. Multi-compartment integration tests
//  (axial coupling, soma + dendrite spread) live in MultiCompartmentTests.
//

import XCTest
@testable import NeuroSimCore

final class CompartmentTests: XCTestCase {

    // MARK: - State layout

    func testStateCountIsOneVoltagePlusGateSum() {
        let comp = Compartment(channels: HHNeuron.defaultChannels())
        // HH defaults: Na (m, h), K (n), Leak (—) → 3 gates total + 1 V = 4.
        XCTAssertEqual(comp.stateCount, 4)
    }

    func testEmptyChannelsGivesOneStateSlot() {
        let comp = Compartment()
        XCTAssertEqual(comp.stateCount, 1, "An empty compartment still owns one V slot.")
    }

    // MARK: - Initial state

    func testInitialStatePlacesVoltageFirst() {
        let comp = Compartment(channels: HHNeuron.defaultChannels())
        let s = comp.initialState(restingVoltage: -70.0)
        XCTAssertEqual(s[0], -70.0, "V should be the first state slot.")
        XCTAssertEqual(s.count, comp.stateCount)
    }

    func testInitialGatesAreAtSteadyState() {
        // Use a single Na channel and check that m₀ = α_m / (α_m + β_m) at v0.
        let na = SodiumChannel()
        let comp = Compartment(channels: [na])
        let v0 = -65.0
        let s = comp.initialState(restingVoltage: v0)
        let mFromCompartment = s[1]
        // Recompute via channel directly.
        let mInit = na.initialState(atVoltage: v0)[0]
        XCTAssertEqual(mFromCompartment, mInit, accuracy: 1e-12)
    }

    // MARK: - Derivatives

    /// At rest with HH defaults, total ionic current should be ~ 0 (the
    /// classical leak reversal is tuned so currents balance there).
    func testIonicCurrentIsNearZeroAtRest() {
        let comp = Compartment(channels: HHNeuron.defaultChannels())
        let s = comp.initialState(restingVoltage: -65.0)
        let i = comp.ionicCurrent(localState: s[s.startIndex..<s.endIndex])
        XCTAssertEqual(i, 0.0, accuracy: 0.5,
                       "HH currents should approximately balance at rest, got I = \(i) µA/cm².")
    }

    /// dV/dt at rest with no injection should be very small (≈ 0).
    func testRestingDerivativeIsSmall() {
        let comp = Compartment(channels: HHNeuron.defaultChannels())
        let s = comp.initialState(restingVoltage: -65.0)
        var d = [Double](repeating: 0, count: comp.stateCount)
        comp.writeDerivatives(localState: s[s.startIndex..<s.endIndex],
                              iInjected: 0,
                              into: &d,
                              offset: 0)
        XCTAssertEqual(d[0], 0.0, accuracy: 1.0,
                       "dV/dt at rest with no injection should be near zero, got \(d[0]) mV/ms.")
    }

    /// Capacitance scales dV/dt inversely. Doubling Cm halves dV/dt for the
    /// same total current.
    func testCapacitanceScalesDerivative() {
        let c1 = Compartment(capacitance: 1.0, channels: [LeakChannel()])
        let c2 = Compartment(capacitance: 2.0, channels: [LeakChannel()])
        let s1 = c1.initialState(restingVoltage: -90.0) // far from rest → big I
        let s2 = c2.initialState(restingVoltage: -90.0)
        var d1 = [Double](repeating: 0, count: c1.stateCount)
        var d2 = [Double](repeating: 0, count: c2.stateCount)
        c1.writeDerivatives(localState: s1[...], iInjected: 0, into: &d1, offset: 0)
        c2.writeDerivatives(localState: s2[...], iInjected: 0, into: &d2, offset: 0)
        XCTAssertEqual(d1[0], 2.0 * d2[0], accuracy: 1e-9,
                       "Doubling Cm should halve dV/dt at fixed I.")
    }
}
