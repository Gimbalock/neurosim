//
//  PersistentSodiumChannel.swift
//  NeuroSimCore
//
//  Persistent (non-inactivating) Na⁺ channel, I_NaP.
//  One gate: m (quasi-instantaneous activation; no inactivation gate).
//
//  I_NaP activates at subthreshold voltages and does not inactivate, producing
//  a persistent depolarising drive that amplifies synaptic inputs, lowers the
//  spike threshold, and contributes to burst firing and plateau potentials.
//
//  Kinetics: French et al. 1990 / Alzheimer et al. 1993.
//  Voltages in mV, time constants in ms.
//  τm clamped to [0.1, 10.0] ms.
//

import Foundation

public final class PersistentSodiumChannel: IonChannel, HHGated {

    public var name: String = "Na_P"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .sodium }

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 0.5,
                reversal: Double = IonSpecies.sodium.defaultReversal()) {
        self.gMax    = gMax
        self.reversal = reversal
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }

    public func initialState(atVoltage v: Double) -> [Double] {
        [resolvedGateInf(0, voltage: v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex]
        return gMax * m * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let m = gates[gates.startIndex]
        output[offset] = (resolvedGateInf(0, voltage: v) - m)
                            / resolvedGateTau(0, voltage: v)
    }

    // MARK: Steady-state and time-constant equations

    internal static func mInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp(-(v + 55.7) / 7.7))
    }

    internal static func tauM(_ v: Double) -> Double {
        let raw = 1.0 / (0.0353 * exp((v + 55.7) / 14.54)
                       + 0.000883 * exp(-(v + 55.7) / 14.54))
        return max(0.1, min(10.0, raw))
    }

    // MARK: HHGated

    public var gateNames: [String] { ["m"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.mInf(v) : 0
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.tauM(v) : 1
    }
}
