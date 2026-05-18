//
//  ATypeChannel.swift
//  NeuroSimCore
//
//  A-type transient K⁺ channel, I_A (Kv4).
//  Two gates: m (fast activation) and h (fast inactivation).
//  Conductance ∝ m⁴ · h.
//
//  I_A activates rapidly at subthreshold voltages and inactivates almost as
//  fast, producing a transient outward current that delays the first spike and
//  reduces initial firing rate. It is de-inactivated by hyperpolarisation and
//  is important for controlling inter-spike intervals and dendritic computation.
//
//  Kinetics: Connor & Stevens 1971 / Huguenard & McCormick 1992.
//  Voltages in mV, time constants in ms.
//

import Foundation

public final class ATypeChannel: IonChannel, HHGated {

    public var name: String = "K_A"
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var species: IonSpecies? { .potassium }

    public var gateInfOverrides: [GateCurve?] = [nil, nil]
    public var gateTauOverrides: [GateCurve?] = [nil, nil]

    public init(gMax: Double = 0.5,
                reversal: Double = IonSpecies.potassium.defaultReversal()) {
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
        return gMax * m * m * m * m * h * (v - reversal)
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
        1.0 / (1.0 + exp(-(v + 60.0) / 8.5))
    }

    internal static func tauM(_ v: Double) -> Double {
        0.37 + 1.0 / (exp((v + 35.82) / 19.69) + exp(-(v + 79.69) / 12.7))
    }

    internal static func hInf(_ v: Double) -> Double {
        1.0 / (1.0 + exp((v + 78.0) / 6.0))
    }

    internal static func tauH(_ v: Double) -> Double {
        v < -63.0
            ? 1.0 / (exp((v + 46.05) / 5.0) + exp(-(v + 238.4) / 37.45))
            : 19.0
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
