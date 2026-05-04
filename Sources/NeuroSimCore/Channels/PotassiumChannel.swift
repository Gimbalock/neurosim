//
//  PotassiumChannel.swift
//  NeuroSimCore
//
//  Delayed-rectifier K+ channel: n^4.
//

import Foundation

public final class PotassiumChannel: IonChannel, HHGated {
    public var name: String = "K+"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .potassium }

    /// Per-gate user overrides for n's steady-state and time constant.
    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 36.0, reversal: Double = -77.0) {
        self.gMax = gMax
        self.reversal = reversal
    }

    public var stateCount: Int { 1 } // n

    public func initialState(atVoltage v: Double) -> [Double] {
        [resolvedGateInf(0, voltage: v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let n = gates[gates.startIndex]
        return gMax * n * n * n * n * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        // (n∞ − n) / τ_n form. Mathematically identical to
        // αn(V)(1−n) − βn(V)·n for the built-in formulas, but routes
        // through user overrides when set.
        let n = gates[gates.startIndex]
        output[offset] = (resolvedGateInf(0, voltage: v) - n)
                            / resolvedGateTau(0, voltage: v)
    }

    // MARK: - Rate constants

    private func alphaN(_ v: Double) -> Double {
        HHRate.linexp(v, a: 0.01, v0: -55.0, k: 10.0)
    }

    private func betaN(_ v: Double) -> Double {
        0.125 * exp(-(v + 65.0) / 80.0)
    }

    // MARK: - HHGated introspection

    public var gateNames: [String] { ["n"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        let a = alphaN(v), b = betaN(v)
        return a / (a + b)
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        1.0 / (alphaN(v) + betaN(v))
    }
}
