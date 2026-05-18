//
//  HChannel.swift
//  NeuroSimCore
//
//  Hyperpolarisation-activated cyclic-nucleotide-gated (HCN) channel, I_h.
//  One gate: r (activates on hyperpolarisation — opposite sign to most channels).
//
//  Mixed Na⁺/K⁺ reversal ≈ −43 mV (sag current). Generates the depolarising
//  sag seen in thalamocortical and layer-5 pyramidal neurons and contributes
//  to rhythmic theta/delta activity.
//
//  Kinetics: Destexhe, McCormick & Sejnowski 1993 / Wang 1993.
//  Voltages in mV, time constants in ms.
//

import Foundation

public final class HChannel: IonChannel, HHGated {

    public var name: String = "I_h"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV — mixed Na⁺/K⁺, ≈ −43 mV
    public var species: IonSpecies? { nil }  // non-selective, mixed Na⁺/K⁺

    public var gateInfOverrides: [GateCurve?] = [nil]
    public var gateTauOverrides: [GateCurve?] = [nil]

    public init(gMax: Double = 0.08,
                reversal: Double = -43.0) {
        self.gMax    = gMax
        self.reversal = reversal
    }

    // MARK: IonChannel

    public var stateCount: Int { 1 }

    public func initialState(atVoltage v: Double) -> [Double] {
        [resolvedGateInf(0, voltage: v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let r = gates[gates.startIndex]
        return gMax * r * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let r = gates[gates.startIndex]
        output[offset] = (resolvedGateInf(0, voltage: v) - r)
                            / resolvedGateTau(0, voltage: v)
    }

    // MARK: Steady-state and time-constant equations

    internal static func rInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp((v + 75.0) / 5.5))
    }

    internal static func tauR(_ v: Double) -> Double {
        1.0 / (exp(-14.59 - 0.086 * v) + exp(-1.87 + 0.0701 * v))
    }

    // MARK: HHGated

    public var gateNames: [String] { ["r"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.rInf(v) : 0
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        index == 0 ? Self.tauR(v) : 1
    }
}
