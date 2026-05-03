//
//  AxialCouplingTests.swift
//  NeuroSimCoreTests
//
//  Type-level checks on AxialCoupling. Physical / integration behaviour is
//  exercised in MultiCompartmentTests.
//

import XCTest
@testable import NeuroSimCore

final class AxialCouplingTests: XCTestCase {

    func testInvolvesAndOtherEnd() {
        let a = UUID(), b = UUID(), c = UUID()
        let coup = AxialCoupling(between: a, and: b, conductance: 0.5)

        XCTAssertTrue(coup.involves(a))
        XCTAssertTrue(coup.involves(b))
        XCTAssertFalse(coup.involves(c))

        XCTAssertEqual(coup.other(a), b)
        XCTAssertEqual(coup.other(b), a)
        XCTAssertNil(coup.other(c))
    }

    func testIsHashableForUseInSets() {
        let a = UUID(), b = UUID()
        let c1 = AxialCoupling(between: a, and: b, conductance: 1.0)
        let c2 = AxialCoupling(between: a, and: b, conductance: 1.0)
        // Different IDs by default → not equal.
        XCTAssertNotEqual(c1, c2)

        let same = AxialCoupling(id: c1.id,
                                 between: c1.compartmentA,
                                 and: c1.compartmentB,
                                 conductance: c1.conductance)
        XCTAssertEqual(c1, same)

        var set = Set<AxialCoupling>()
        set.insert(c1)
        set.insert(c2)
        set.insert(same)
        XCTAssertEqual(set.count, 2,
                       "Set should dedupe couplings sharing the same id.")
    }
}
