//
//  LeakChannel.swift
//  NeuroSimCore
//
//  Passive (non-gated) leak current.
//
//  Default E_rev = -70 mV — typical mammalian resting potential / mixed
//  Na⁺-K⁺-Cl⁻ leak reversal.  (Original HH squid value was -54.4 mV.)
//

import Foundation

public final class LeakChannel: IonChannel {
    public var name: String = "Leak"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV

    public init(gMax: Double = 0.3, reversal: Double = -70.0) {
        self.gMax = gMax
        self.reversal = reversal
    }

    public var stateCount: Int { 0 }

    public func initialState(atVoltage v: Double) -> [Double] { [] }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        gMax * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        // No gates — nothing to write.
    }
}
