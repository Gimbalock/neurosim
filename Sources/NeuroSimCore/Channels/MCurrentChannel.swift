//
//  MCurrentChannel.swift
//  NeuroSimCore
//
//  KCNQ/Kv7 M-current channel, I_M.
//  One gate: w (slow, non-inactivating voltage-dependent activation).
//
//  The M-current is a slowly activating and deactivating outward K⁺ current
//  that is active near rest and provides spike-frequency adaptation and a
//  brake on repetitive firing. It is suppressed by muscarinic receptor
//  activation (hence "M-current").
//
//  Kinetics: Adams et al. 1982 / Wang 1993 cortical formulation.
//  Voltages in mV, time constants in ms.
//  τw clamped to [10.0, 5000.0] ms.
//

import Foundation

public final class MCurrentChannel: IonChannel, HHGated {

    public var name: String = "K_M"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .potassium }

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 0.3,
                reversal: Double = IonSpecies.potassium.defaultReversal()) {
        self.gMax    = gMax
        self.reversal = reversal
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }

    public func initialState(atVoltage v: Double) -> [Double] {
        [resolvedGateInf(0, voltage: v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let w = gates[gates.startIndex]
        return gMax * w * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let w = gates[gates.startIndex]
        output[offset] = (resolvedGateInf(0, voltage: v) - w)
                            / resolvedGateTau(0, voltage: v)
    }

    // MARK: Steady-state and time-constant equations

    internal static func wInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp(-(v + 35.0) / 10.0))
    }

    internal static func tauW(_ v: Double) -> Double {
        let raw = 400.0 / (3.3 * (exp((v + 35.0) / 20.0) + exp(-(v + 35.0) / 20.0)))
        return max(10.0, min(5000.0, raw))
    }

    // MARK: HHGated

    public var gateNames: [String] { ["w"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.wInf(v) : 0
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.tauW(v) : 1
    }
}
