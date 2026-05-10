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
        // Alpha/beta formulation (classical HH)
        public var alphaExpr: String
        public var betaExpr:  String
        // Inf/tau formulation (Destexhe/Traub style — takes precedence when set)
        public var infExpr:   String?
        public var tauExpr:   String?
        public var params:    [String: Double]

        public init(name: String, power: Int,
                    alphaExpr: String, betaExpr: String,
                    infExpr: String? = nil, tauExpr: String? = nil,
                    params: [String: Double]) {
            self.name      = name
            self.power     = power
            self.alphaExpr = alphaExpr
            self.betaExpr  = betaExpr
            self.infExpr   = infExpr
            self.tauExpr   = tauExpr
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
    // Compiled inf/tau closures — non-nil when the .mod uses inf/tau formulation.
    private let infFns:   [(Double) -> Double?]
    private let tauFns:   [(Double) -> Double?]

    public var gateInfOverrides: [GateCurve?]
    public var gateTauOverrides: [GateCurve?]

    // MARK: Init

    public init(definition def: MODImportedChannelDefinition) throws {
        self.definition = def
        var af: [(Double) -> Double]  = []
        var bf: [(Double) -> Double]  = []
        var inf: [(Double) -> Double?] = []
        var tau: [(Double) -> Double?] = []

        for gate in def.gates {
            let p = gate.params

            // ── Inf/tau formulation (Destexhe/Traub style) ─────────────────
            if let infStr = gate.infExpr, let tauStr = gate.tauExpr,
               !infStr.isEmpty, !tauStr.isEmpty {
                do {
                    let ie = try MODExpression(infStr)
                    let te = try MODExpression(tauStr)
                    inf.append { v in ie.evaluate(v: v, params: p) }
                    tau.append { v in te.evaluate(v: v, params: p) }
                    af.append { _ in 0 }
                    bf.append { _ in 1 }
                } catch {
                    // Expression failed to parse — log and fall through to alpha/beta.
                    print("[MOD] ⚠️ gate '\(gate.name)' inf/tau compile failed: \(error)")
                    print("[MOD]   infExpr: \(infStr.prefix(120))")
                    print("[MOD]   tauExpr: \(tauStr.prefix(120))")
                    // Graceful fallback: constant inf=0.5, tau=1 ms so the
                    // channel can at least be instantiated and added.
                    inf.append { _ in 0.5 }
                    tau.append { _ in 1.0 }
                    af.append { _ in 0 }
                    bf.append { _ in 1 }
                }
                continue  // always skip the alpha/beta branch for inf/tau gates
            }

            // ── Classical alpha/beta formulation ───────────────────────────
            guard !gate.alphaExpr.isEmpty, !gate.betaExpr.isEmpty else {
                // No kinetic expressions at all — degenerate fallback.
                print("[MOD] ⚠️ gate '\(gate.name)' has no kinetic expressions — using fallback")
                inf.append { _ in 0.5 }
                tau.append { _ in 1.0 }
                af.append { _ in 0 }
                bf.append { _ in 1 }
                continue
            }
            let ae = try MODExpression(gate.alphaExpr)
            let be = try MODExpression(gate.betaExpr)
            af.append { v in ae.evaluate(v: v, params: p) }
            bf.append { v in be.evaluate(v: v, params: p) }
            inf.append { _ in nil }
            tau.append { _ in nil }
        }
        self.alphaFns = af
        self.betaFns  = bf
        self.infFns   = inf
        self.tauFns   = tau
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
                          infExpr:   g.infExpr,
                          tauExpr:   g.tauExpr,
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
        // Prefer direct inf(V) when the .mod used the inf/tau formulation.
        if index < infFns.count, let x = infFns[index](v) {
            return max(0.0, min(1.0, x))
        }
        guard index < alphaFns.count else { return 0 }
        let a = alphaFns[index](v)
        let b = betaFns[index](v)
        let sum = a + b
        return sum > 0 ? a / sum : 0.5
    }

    public func gateTau(_ index: Int, voltage v: Double) -> Double {
        // Prefer direct tau(V) when the .mod used the inf/tau formulation.
        if index < tauFns.count, let t = tauFns[index](v) {
            return max(t, 1e-9)
        }
        guard index < alphaFns.count else { return 1 }
        let a = alphaFns[index](v)
        let b = betaFns[index](v)
        return 1.0 / max(a + b, 1e-9)
    }
}
