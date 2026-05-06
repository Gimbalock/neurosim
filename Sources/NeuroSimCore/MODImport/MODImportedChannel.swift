// MODImportedChannel.swift
// NeuroSimCore — IonChannel implementation built from a parsed .mod file.
//
// Alpha/beta expressions are stored as strings (for Codable) and compiled to
// closures on init. Conductance formula: g_max * Π(gate_i ^ power_i) * (V - E_rev).

import Foundation

// MARK: - Codable definition (serialised to disk)

public struct MODImportedChannelDefinition: Codable {
    public var id:          UUID
    public var channelName: String
    public var gMax:        Double
    public var reversal:    Double
    public var ionSymbol:   String?
    public var gates:       [GateDef]

    public init(channelName: String, gMax: Double, reversal: Double,
                ionSymbol: String? = nil, gates: [GateDef]) {
        self.id          = UUID()
        self.channelName = channelName
        self.gMax        = gMax
        self.reversal    = reversal
        self.ionSymbol   = ionSymbol
        self.gates       = gates
    }

    public struct GateDef: Codable {
        public var name:      String
        public var power:     Int
        public var alphaExpr: String
        public var betaExpr:  String
        public var params:    [String: Double]

        public init(name: String, power: Int, alphaExpr: String,
                    betaExpr: String, params: [String: Double]) {
            self.name      = name
            self.power     = power
            self.alphaExpr = alphaExpr
            self.betaExpr  = betaExpr
            self.params    = params
        }
    }
}

// MARK: - Channel class

public final class MODImportedChannel: IonChannel, HHGated {

    public var definition: MODImportedChannelDefinition

    // Compiled α/β closures — rebuilt from expression strings on init.
    private let alphaFns: [(Double) -> Double]
    private let betaFns:  [(Double) -> Double]

    public var gateInfOverrides: [GateCurve?]
    public var gateTauOverrides: [GateCurve?]

    // MARK: Init

    public init(definition def: MODImportedChannelDefinition) throws {
        self.definition = def
        var af: [(Double) -> Double] = []
        var bf: [(Double) -> Double] = []
        for gate in def.gates {
            let p = gate.params
            let ae = try MODExpression(gate.alphaExpr)
            let be = try MODExpression(gate.betaExpr)
            af.append { v in ae.evaluate(v: v, params: p) }
            bf.append { v in be.evaluate(v: v, params: p) }
        }
        self.alphaFns = af
        self.betaFns  = bf
        self.gateInfOverrides = Array(repeating: nil, count: def.gates.count)
        self.gateTauOverrides = Array(repeating: nil, count: def.gates.count)
    }

    /// Convenience: build from parser output.
    public static func channels(from descriptions: [MODChannelDescription]) throws
            -> [MODImportedChannel] {
        try descriptions.map { desc in
            let def = MODImportedChannelDefinition(
                channelName: desc.name,
                gMax:        desc.gMax,
                reversal:    desc.reversal,
                ionSymbol:   desc.ionSymbol,
                gates:       desc.gates.map { g in
                    .init(name:      g.name,
                          power:     g.power,
                          alphaExpr: g.alphaExpr,
                          betaExpr:  g.betaExpr,
                          params:    g.params)
                }
            )
            return try MODImportedChannel(definition: def)
        }
    }

    // MARK: IonChannel

    public var name:    String { get { definition.channelName } set { definition.channelName = newValue } }
    public var gMax:    Double { get { definition.gMax }         set { definition.gMax = newValue }        }
    public var reversal: Double { get { definition.reversal }   set { definition.reversal = newValue }    }
    public var species: IonSpecies? { definition.ionSymbol.flatMap(IonSpecies.canonical(symbol:)) }
    public var stateCount: Int { definition.gates.count }

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

    // MARK: HHGated

    public var gateNames: [String] { definition.gates.map(\.name) }

    public func gateInf(_ index: Int, voltage v: Double) -> Double {
        guard index < alphaFns.count else { return 0 }
        let a = alphaFns[index](v)
        let b = betaFns[index](v)
        let sum = a + b
        return sum > 0 ? a / sum : 0.5
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        guard index < alphaFns.count else { return 1 }
        let a = alphaFns[index](v)
        let b = betaFns[index](v)
        return 1.0 / max(a + b, 1e-9)
    }
}
