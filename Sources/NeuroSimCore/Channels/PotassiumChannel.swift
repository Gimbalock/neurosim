//
//  PotassiumChannel.swift
//  NeuroSimCore
//
//  Delayed-rectifier K+ channel: n^4.
//

import Foundation

public final class PotassiumChannel: IonChannel {
    public var name: String = "K+"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .potassium }

    public init(gMax: Double = 36.0, reversal: Double = -77.0) {
        self.gMax = gMax
        self.reversal = reversal
    }

    public var stateCount: Int { 1 } // n

    public func initialState(atVoltage v: Double) -> [Double] {
        let an = alphaN(v), bn = betaN(v)
        return [an / (an + bn)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let n = gates[gates.startIndex]
        return gMax * n * n * n * n * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let n = gates[gates.startIndex]
        output[offset] = alphaN(v) * (1 - n) - betaN(v) * n
    }

    // MARK: - Rate constants

    private func alphaN(_ v: Double) -> Double {
        HHRate.linexp(v, a: 0.01, v0: -55.0, k: 10.0)
    }

    private func betaN(_ v: Double) -> Double {
        0.125 * exp(-(v + 65.0) / 80.0)
    }
}
