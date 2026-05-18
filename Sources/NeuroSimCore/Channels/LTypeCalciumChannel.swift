//
//  LTypeCalciumChannel.swift
//  NeuroSimCore
//
//  L-type high-threshold Ca²⁺ channel, I_CaL (Cav1).
//  Two gates: m (fast activation) and h (slow inactivation).
//  Conductance ∝ m² · h.
//
//  L-type channels activate at high voltages (−30 to 0 mV), inactivate slowly,
//  and are blocked by dihydropyridines. They are the primary source of Ca²⁺
//  influx during the plateau phase of cardiac action potentials and contribute
//  to dendritic Ca²⁺ spikes, synaptic plasticity (LTP/LTD), and Ca²⁺-dependent
//  gene expression in neurons.
//
//  Kinetics: Reuveni et al. 1993 / Bhatt et al.
//  Voltages in mV, time constants in ms.
//  τm clamped to [0.05, 50.0] ms; τh clamped to [1.0, 1000.0] ms.
//

import Foundation

public final class LTypeCalciumChannel: IonChannel, HHGated {

    public var name: String = "Ca_L"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .calcium }

    public var gateInfOverrides: [GateCurve?] = [nil, nil]
    public var gateTauOverrides: [GateCurve?] = [nil, nil]

    public init(gMax: Double = 0.1,
                reversal: Double = IonSpecies.calcium.defaultReversal()) {
        self.gMax    = gMax
        self.reversal = reversal
    }

    // MARK: IonChannel

    public var stateCount: Int { 2 }  // m, h

    public func initialState(atVoltage v: Double) -> [Double] {
        [resolvedGateInf(0, voltage: v),
         resolvedGateInf(1, voltage: v)]
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        return gMax * m * m * h * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        let m = gates[gates.startIndex]
        let h = gates[gates.startIndex + 1]
        output[offset]     = (resolvedGateInf(0, voltage: v) - m)
                                / resolvedGateTau(0, voltage: v)
        output[offset + 1] = (resolvedGateInf(1, voltage: v) - h)
                                / resolvedGateTau(1, voltage: v)
    }

    // MARK: Steady-state and time-constant equations

    internal static func mInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp(-(v + 37.0) / 7.0))
    }

    internal static func tauM(_ v: Double) -> Double {
        let raw = 1.0 / (0.055 * exp(-(v + 27.0) / 3.8)
                       + 0.94  * exp( (v + 75.0) / 17.0))
        return max(0.05, min(50.0, raw))
    }

    internal static func hInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp((v + 41.0) / 0.5))
    }

    internal static func tauH(_ v: Double) -> Double {
        let raw = 1.0 / (0.000457 * exp(-(v + 13.0) / 50.0)
                       + 0.0065   * exp( (v + 15.0) / 28.0))
        return max(1.0, min(1000.0, raw))
    }

    // MARK: HHGated

    public var gateNames: [String] { ["m", "h"] }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        switch index {
        case 0:  return Self.mInf(v)
        case 1:  return Self.hInf(v)
        default: return 0
        }
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        switch index {
        case 0:  return Self.tauM(v)
        case 1:  return Self.tauH(v)
        default: return 1
        }
    }
}
