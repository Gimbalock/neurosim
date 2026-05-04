//
//  SodiumChannel.swift
//  NeuroSimCore
//
//  Classical Hodgkin-Huxley fast Na+ channel: m^3 * h.
//  Rate constants from Hodgkin & Huxley (1952), squid giant axon,
//  shifted to V_rest = -65 mV (modern convention).
//

import Foundation

public final class SodiumChannel: IonChannel, HHGated {
    public var name: String = "Na+"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .sodium }

    /// User overrides for x∞(V) and τ(V), per gate (m, h). `nil` = use
    /// the built-in formula below; non-nil = use the GateCurve. Set by
    /// the inspector's curve editor; consumed via `resolvedGateInf` /
    /// `resolvedGateTau` in the integrator path.
    public var gateInfOverrides: [GateCurve?] = [nil, nil]
    public var gateTauOverrides: [GateCurve?] = [nil, nil]

    public init(gMax: Double = 120.0, reversal: Double = 50.0) {
        self.gMax = gMax
        self.reversal = reversal
    }

    public var stateCount: Int { 2 } // m, h

    public func initialState(atVoltage v: Double) -> [Double] {
        // Route through `resolvedGateInf` so any user override is
        // respected at simulator-reset time, not just during steady
        // dynamics.
        [resolvedGateInf(0, voltage: v),
         resolvedGateInf(1, voltage: v)]
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
        // Express the dynamics in the (x∞, τ) form so user edits to
        // either curve flow through automatically:
        //   dx/dt = (x∞(V) − x) / τ(V)
        // Mathematically identical to α(V)(1−x) − β(V)x for the
        // built-in HH formulas.
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        output[offset]     = (resolvedGateInf(0, voltage: v) - m)
                                / resolvedGateTau(0, voltage: v)
        output[offset + 1] = (resolvedGateInf(1, voltage: v) - h)
                                / resolvedGateTau(1, voltage: v)
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

    // MARK: - HHGated introspection

    public var gateNames: [String] { ["m", "h"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        switch index {
        case 0:  // m
            let a = alphaM(v), b = betaM(v)
            return a / (a + b)
        case 1:  // h
            let a = alphaH(v), b = betaH(v)
            return a / (a + b)
        default:
            return 0
        }
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        switch index {
        case 0:  return 1.0 / (alphaM(v) + betaM(v))
        case 1:  return 1.0 / (alphaH(v) + betaH(v))
        default: return 0
        }
    }
}
