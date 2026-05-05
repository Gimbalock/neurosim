//
//  CustomChannel.swift
//  NeuroSimCore
//
//  User-defined ion channel built from parameterised Boltzmann + bell-curve
//  gate kinetics. Conforms to both IonChannel and HHGated so it integrates
//  with Rush-Larsen, plots x∞(V) and τ(V) in the inspector, and supports
//  per-gate curve overrides just like the hard-coded HH channels.
//
//  Gate model
//  ──────────
//  x∞(V) = 1 / (1 + exp(−(V − vHalf) / slope))
//    slope > 0 → activation gate  (opens on depolarisation)
//    slope < 0 → inactivation gate (closes on depolarisation)
//
//  τ(V)  = tauMin + (tauMax − tauMin) · exp(−½·((V − vPeak)/tauWidth)²)
//    Gaussian bell centred at vPeak. When tauMax ≈ tauMin the time constant
//    is approximately voltage-independent (constant τ channel).
//
//  Conductance: I = gMax · Π(xᵢ^powerᵢ) · (V − E_rev)
//

import Foundation

// MARK: - Gate definition

/// One gating variable with its voltage-dependent kinetics.
public struct GateDef: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String       // "m", "h", "n", …
    public var power: Int         // exponent in conductance product (≥ 1)

    // x∞(V) parameters
    public var vHalf: Double      // mV — half-activation voltage
    public var slope: Double      // mV — positive = activation, negative = inactivation

    // τ(V) parameters (Gaussian bell)
    public var tauMin: Double     // ms — minimum (floor) time constant
    public var tauMax: Double     // ms — peak time constant
    public var vPeak: Double      // mV — voltage of τ maximum
    public var tauWidth: Double   // mV — width (σ) of the Gaussian

    public init(id: UUID = UUID(),
                name: String = "x",
                power: Int = 1,
                vHalf: Double = -40,
                slope: Double = 7,
                tauMin: Double = 0.5,
                tauMax: Double = 5.0,
                vPeak: Double = -40,
                tauWidth: Double = 20) {
        self.id       = id
        self.name     = name
        self.power    = max(1, power)
        self.vHalf    = vHalf
        self.slope    = slope
        self.tauMin   = tauMin
        self.tauMax   = tauMax
        self.vPeak    = vPeak
        self.tauWidth = tauWidth
    }
}

// MARK: - Channel definition (serialisable)

/// Full specification of a custom channel — stored in the channel library
/// and embedded in network documents. Value type so copy = independent clone.
public struct CustomChannelDefinition: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// Symbol of the carried ion species, e.g. "Na", "K", "Ca", "Cl".
    /// `nil` means mixed / non-selective (no Nernst auto-update).
    public var ionSymbol: String?
    public var reversal: Double   // mV
    public var gMax: Double       // mS/cm²
    public var gates: [GateDef]

    public init(id: UUID = UUID(),
                name: String = "Custom",
                ionSymbol: String? = nil,
                reversal: Double = 0,
                gMax: Double = 1,
                gates: [GateDef] = [GateDef()]) {
        self.id        = id
        self.name      = name
        self.ionSymbol = ionSymbol
        self.reversal  = reversal
        self.gMax      = gMax
        self.gates     = gates.isEmpty ? [GateDef()] : gates
    }
}

// MARK: - Runtime class

/// Hodgkin-Huxley-style channel whose kinetics are driven by a
/// `CustomChannelDefinition` rather than hard-coded Swift formulas.
public final class CustomChannel: IonChannel, HHGated {

    public var definition: CustomChannelDefinition

    // IonChannel protocol — proxy through the definition
    public var name:     String { get { definition.name }    set { definition.name = newValue } }
    public var gMax:     Double { get { definition.gMax }    set { definition.gMax = newValue } }
    public var reversal: Double { get { definition.reversal} set { definition.reversal = newValue } }
    public var species:  IonSpecies? { definition.ionSymbol.flatMap(IonSpecies.canonical(symbol:)) }
    public var stateCount: Int { definition.gates.count }

    // HHGated protocol
    public var gateNames: [String] { definition.gates.map(\.name) }
    public var gateInfOverrides: [GateCurve?]
    public var gateTauOverrides: [GateCurve?]

    public init(definition: CustomChannelDefinition) {
        self.definition = definition
        let n = definition.gates.count
        gateInfOverrides = [GateCurve?](repeating: nil, count: n)
        gateTauOverrides = [GateCurve?](repeating: nil, count: n)
    }

    // MARK: - HHGated built-in formulas

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        let g = definition.gates[index]
        guard abs(g.slope) > 1e-12 else { return v < g.vHalf ? 0 : 1 }
        return 1.0 / (1.0 + exp(-(v - g.vHalf) / g.slope))
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        let g = definition.gates[index]
        let sigma = max(g.tauWidth, 1e-6)
        let u = (v - g.vPeak) / sigma
        return g.tauMin + (g.tauMax - g.tauMin) * exp(-0.5 * u * u)
    }

    // MARK: - IonChannel

    public func initialState(atVoltage v: Double) -> [Double] {
        definition.gates.indices.map { resolvedGateInf($0, voltage: v) }
    }

    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        var g = gMax
        for (i, gDef) in definition.gates.enumerated() {
            let x = gates[gates.startIndex + i]
            g *= pow(x, Double(gDef.power))
        }
        return g * (v - reversal)
    }

    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double],
                                offset: Int) {
        for i in definition.gates.indices {
            let x = gates[gates.startIndex + i]
            output[offset + i] = (resolvedGateInf(i, voltage: v) - x)
                                    / resolvedGateTau(i, voltage: v)
        }
    }
}
