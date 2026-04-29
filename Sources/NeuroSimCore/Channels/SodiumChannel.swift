//
//  SodiumChannel.swift
//  NeuroSimCore
//
//  Classical Hodgkin-Huxley fast Na+ channel: m^3 * h.
//  Rate constants from Hodgkin & Huxley (1952), squid giant axon,
//  shifted to V_rest = -65 mV (modern convention).
//

import Foundation

public final class SodiumChannel: IonChannel {
    public var name: String = "Na+"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV

    public init(gMax: Double = 120.0, reversal: Double = 50.0) {
        self.gMax = gMax
        self.reversal = reversal
    }

    public var stateCount: Int { 2 } // m, h

    public func initialState(atVoltage v: Double) -> [Double] {
        let am = alphaM(v), bm = betaM(v)
        let ah = alphaH(v), bh = betaH(v)
        return [am / (am + bm), ah / (ah + bh)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        return gMax * m * m * m * h * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        output[offset]     = alphaM(v) * (1 - m) - betaM(v) * m
        output[offset + 1] = alphaH(v) * (1 - h) - betaH(v) * h
    }

    // MARK: - Rate constants (1/ms, V in mV)

    private func alphaM(_ v: Double) -> Double {
        HHRate.linexp(v, a: 0.1, v0: -40.0, k: 10.0)
    }

    private func betaM(_ v: Double) -> Double {
        4.0 * exp(-(v + 65.0) / 18.0)
    }

    private func alphaH(_ v: Double) -> Double {
        0.07 * exp(-(v + 65.0) / 20.0)
    }

    private func betaH(_ v: Double) -> Double {
        1.0 / (1.0 + exp(-(v + 35.0) / 10.0))
    }
}
