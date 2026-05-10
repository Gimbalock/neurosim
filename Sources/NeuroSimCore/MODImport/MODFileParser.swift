// MODFileParser.swift
// NeuroSimCore — parses NEURON .mod files into NeuroSim channel descriptions.
//
// Supports the standard Hodgkin-Huxley pattern:
//   PARAMETER, STATE, NEURON (SUFFIX + USEION + NONSPECIFIC_CURRENT),
//   BREAKPOINT (current formulas), PROCEDURE rates (alpha/beta per gate).
//
// One .mod file may produce multiple channels (Na, K, Leak from hh1.mod).

import Foundation

// MARK: - Output types

public struct MODChannelDescription {
    public var name:      String           // display name, e.g. "Na+"
    public var gMax:      Double           // mS/cm²
    public var reversal:  Double           // mV
    public var ionSymbol: String?          // "na", "k", "ca" — nil for nonspecific
    public var gates:     [MODGateDescription]
    public var suffix:    String           // original SUFFIX tag
}

public struct MODGateDescription {
    public var name:      String           // "m", "h", "n"
    public var power:     Int              // gate exponent in conductance formula
    // Alpha/beta formulation (classical HH)
    public var alphaExpr: String           // α(V) — empty when inf/tau used
    public var betaExpr:  String           // β(V) — empty when inf/tau used
    // Inf/tau formulation (Destexhe/Traub style)
    public var infExpr:   String?          // x_inf(V) direct expression
    public var tauExpr:   String?          // τ_x(V)  direct expression
    public var params:    [String: Double] // named constants for evaluation
}

public enum MODParseError: Error, LocalizedError {
    case noChannelsFound
    case noRatesForGate(String)

    public var errorDescription: String? {
        switch self {
        case .noChannelsFound:        return "No recognizable ion channels in .mod file"
        case .noRatesForGate(let g):  return "Could not extract α/β rates for gate '\(g)'"
        }
    }
}

// MARK: - Parser

public enum MODFileParser {

    public static func parse(_ source: String) throws -> [MODChannelDescription] {
        // Normalise Windows (CRLF) and old-Mac (CR) line endings to Unix (LF)
        // so all subsequent parsing is line-ending-agnostic.
        let unixSource = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
        let stripped = stripComments(unixSource)

        let paramBlock  = extractBlock("PARAMETER",  from: stripped) ?? ""
        let stateBlock  = extractBlock("STATE",      from: stripped) ?? ""
        let neuronBlock = extractBlock("NEURON",     from: stripped) ?? ""
        let bpBlock     = extractBlock("BREAKPOINT", from: stripped) ?? ""

        let params    = parseParameters(paramBlock)
        let stateVars = parseStateVars(stateBlock)         // ["m","h","n"]
        let suffix    = parseSuffix(neuronBlock)
        let ions      = parseIonInfo(neuronBlock)
        let nonspec   = parseNonspecific(neuronBlock)
        let formulas  = parseCurrentFormulas(bpBlock)

        // Derive params that may be computed outside PARAMETER (e.g. tadj from celsius)
        var flatParams = params.mapValues(\.value)
        enrichDerivedParams(&flatParams)

        // Extract kinetics: try alpha/beta first, then inf/tau with local-var inlining.
        let kineticsBody = extractKineticsBody(stateVars, from: stripped) ?? ""
        let (abRates, itRates) = parseKinetics(kineticsBody,
                                                stateVars: stateVars,
                                                params: &flatParams)

        var channels: [MODChannelDescription] = []

        // USEION channels
        for ion in ions {
            guard let formula = formulas[ion.writeVar] else { continue }
            guard let info = extractChannelComponents(formula, stateVars: Set(stateVars),
                                                       params: flatParams) else { continue }

            let gMax = convertConductance(value: params[info.gMaxVar]?.value ?? 0,
                                          unit:  params[info.gMaxVar]?.unit  ?? "")
            let eRev = params[info.reversalVar]?.value ?? params[ion.readVar]?.value ?? 0

            let gates = buildGates(info: info, stateVars: stateVars,
                                   abRates: abRates, itRates: itRates,
                                   params: flatParams)
            channels.append(MODChannelDescription(
                name:      ionDisplayName(ion.ion),
                gMax:      gMax,
                reversal:  eRev,
                ionSymbol: ion.ion,
                gates:     gates,
                suffix:    suffix
            ))
        }

        // NONSPECIFIC_CURRENT (leak)
        for currentVar in nonspec {
            guard let formula = formulas[currentVar] else { continue }
            guard let info = extractChannelComponents(formula, stateVars: Set(stateVars),
                                                       params: flatParams) else { continue }

            let gMax = convertConductance(value: params[info.gMaxVar]?.value ?? 0,
                                          unit:  params[info.gMaxVar]?.unit  ?? "")
            let eRev = params[info.reversalVar]?.value ?? 0

            channels.append(MODChannelDescription(
                name:      "Leak",
                gMax:      gMax,
                reversal:  eRev,
                ionSymbol: nil,
                gates:     [],
                suffix:    suffix
            ))
        }

        if channels.isEmpty { throw MODParseError.noChannelsFound }
        return channels
    }
}

// MARK: - Block extraction

private func stripComments(_ source: String) -> String {
    source.components(separatedBy: "\n").map { line in
        // NMODL comment starts at ":"
        if let idx = line.firstIndex(of: ":") { return String(line[..<idx]) }
        return line
    }.joined(separator: "\n")
}

private func extractBlock(_ name: String, from source: String) -> String? {
    guard let nameRange = source.range(of: name, options: .literal) else { return nil }
    let after = source[nameRange.upperBound...]
    guard let braceIdx = after.firstIndex(where: { !$0.isWhitespace }),
          after[braceIdx] == "{" else { return nil }
    let contentStart = after.index(after: braceIdx)
    return extractToMatchingBrace(after[contentStart...])
}

private func extractProcedureBody(_ name: String, from source: String) -> String? {
    // Match "PROCEDURE <name> ... {" where the argument list may contain
    // nested parentheses like "v(mV)" — so we use [^{]* instead of \([^)]*\).
    let pattern = "PROCEDURE\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*[^{]*\\{"
    guard let range = source.range(of: pattern, options: .regularExpression) else { return nil }
    return extractToMatchingBrace(source[range.upperBound...])
}

private func extractToMatchingBrace(_ slice: Substring) -> String {
    var depth = 1
    var i = slice.startIndex
    while i < slice.endIndex && depth > 0 {
        switch slice[i] {
        case "{": depth += 1
        case "}": depth -= 1
        default: break
        }
        if depth > 0 { i = slice.index(after: i) }
    }
    return String(slice[..<i])
}

// MARK: - PARAMETER block

private struct ParamEntry { var value: Double; var unit: String }

private func parseParameters(_ block: String) -> [String: ParamEntry] {
    var result: [String: ParamEntry] = [:]
    for line in block.components(separatedBy: "\n") {
        let stmt = line.trimmingCharacters(in: .whitespaces)
        guard stmt.contains("=") else { continue }
        let parts = stmt.components(separatedBy: "=")
        guard parts.count >= 2 else { continue }
        let name     = parts[0].trimmingCharacters(in: .whitespaces)
        let rest     = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
        let valueStr = rest.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let unit     = rest.components(separatedBy: "(").dropFirst().first?
                           .components(separatedBy: ")").first ?? ""
        guard let val = Double(valueStr) else { continue }
        result[name] = ParamEntry(value: val, unit: unit.trimmingCharacters(in: .whitespaces))
    }
    return result
}

// MARK: - STATE block

private func parseStateVars(_ block: String) -> [String] {
    block.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
}

// MARK: - NEURON block

private struct IonInfo { var ion: String; var readVar: String; var writeVar: String }

private func parseSuffix(_ block: String) -> String {
    for line in block.components(separatedBy: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
        if parts.first == "SUFFIX", parts.count >= 2 { return parts[1] }
    }
    return "mod"
}

private func parseIonInfo(_ block: String) -> [IonInfo] {
    var result: [IonInfo] = []
    for line in block.components(separatedBy: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
        guard parts.count >= 6, parts[0] == "USEION" else { continue }
        let ion      = parts[1].lowercased()
        // USEION na READ ena WRITE ina
        if let readIdx = parts.firstIndex(of: "READ"),
           let writeIdx = parts.firstIndex(of: "WRITE"),
           readIdx + 1 < parts.count,
           writeIdx + 1 < parts.count {
            let readVar  = parts[readIdx  + 1].trimmingCharacters(in: .init(charactersIn: ","))
            let writeVar = parts[writeIdx + 1].trimmingCharacters(in: .init(charactersIn: ","))
            result.append(IonInfo(ion: ion, readVar: readVar, writeVar: writeVar))
        }
    }
    return result
}

private func parseNonspecific(_ block: String) -> [String] {
    var result: [String] = []
    for line in block.components(separatedBy: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
        if parts.first == "NONSPECIFIC_CURRENT" {
            result += parts.dropFirst().map { $0.trimmingCharacters(in: .init(charactersIn: ",")) }
                          .filter { !$0.isEmpty }
        }
    }
    return result
}

// MARK: - BREAKPOINT formulas

private func parseCurrentFormulas(_ block: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in block.components(separatedBy: "\n") {
        let stmt = line.trimmingCharacters(in: .whitespaces)
        guard stmt.contains("="), !stmt.hasPrefix("SOLVE") else { continue }
        let parts = stmt.components(separatedBy: "=")
        guard parts.count >= 2 else { continue }
        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let rhs = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
        // lhs must be a plain identifier (no spaces)
        guard lhs.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
        result[lhs] = rhs
    }
    return result
}

// MARK: - Channel component extraction

private struct ChannelComponents {
    var gMaxVar:     String
    var reversalVar: String
    var gates:       Set<String>
    var gateCounts:  [String: Int]
}

private func extractChannelComponents(_ formula: String,
                                       stateVars: Set<String>,
                                       params: [String: Double]) -> ChannelComponents? {
    let tokens = modTokenize(formula)

    // Collect identifiers
    var identifiers: [String] = []
    for tok in tokens {
        if case .identifier(let name) = tok { identifiers.append(name) }
    }

    // Find conductance variable: in params, not a state var, not "v"
    guard let gMaxVar = identifiers.first(where: {
        params[$0] != nil && !stateVars.contains($0) && $0 != "v"
    }) else { return nil }

    // Count gate appearances
    var gateCounts: [String: Int] = [:]
    for id in identifiers where stateVars.contains(id) {
        gateCounts[id, default: 0] += 1
    }

    // Find reversal: pattern ".identifier("v") .op("-") .identifier(X)"
    var reversalVar = ""
    for i in 0..<(tokens.count - 2) {
        if case .identifier("v") = tokens[i],
           case .op("-")         = tokens[i + 1],
           case .identifier(let r) = tokens[i + 2],
           !stateVars.contains(r), r != "v" {
            reversalVar = r; break
        }
    }
    // Also try reversed: "(X - v)"
    if reversalVar.isEmpty {
        for i in 0..<(tokens.count - 2) {
            if case .identifier(let r) = tokens[i],
               case .op("-")           = tokens[i + 1],
               case .identifier("v")   = tokens[i + 2],
               !stateVars.contains(r), r != "v" {
                reversalVar = r; break
            }
        }
    }
    guard !reversalVar.isEmpty else { return nil }

    return ChannelComponents(gMaxVar: gMaxVar, reversalVar: reversalVar,
                             gates: Set(gateCounts.keys), gateCounts: gateCounts)
}

// MARK: - Kinetics procedure extraction (flexible name detection)

/// Tries several well-known NMODL procedure names used for gate kinetics.
/// Returns the body of the first matching procedure whose content looks like
/// it contains gate-kinetics assignments.
private func extractKineticsBody(_ stateVars: [String], from source: String) -> String? {
    let candidates = ["rates", "evaluate_fct", "rate", "calcrate",
                       "rates2", "calc_rates", "evaluate", "kinetics"]
    for name in candidates {
        if let body = extractProcedureBody(name, from: source) {
            let lower = body.lowercased()
            let hasKinetics = stateVars.contains { g in
                lower.contains("\(g)_inf") || lower.contains("tau_\(g)") ||
                lower.contains("alpha_\(g)") || lower.contains("alpha")
            }
            if hasKinetics { return body }
        }
    }
    return nil
}

// MARK: - Unified kinetics dispatcher

private typealias ABRates = [String: (alpha: String, beta: String)]
private typealias ITRates = [String: (inf: String, tau: String)]

private func parseKinetics(_ body: String,
                             stateVars: [String],
                             params: inout [String: Double]) -> (ABRates, ITRates) {
    // Try classic alpha/beta first
    let ab = parseAlphaBeta(body, stateVars: stateVars)
    if !ab.isEmpty { return (ab, [:]) }
    // Fall back to inf/tau with local-variable inlining (Destexhe/Traub style)
    let it = parseInfTau(body, stateVars: stateVars, params: &params)
    return ([:], it)
}

// MARK: - Alpha/beta parser (classic HH)

private func parseAlphaBeta(_ body: String, stateVars: [String]) -> ABRates {
    var result: ABRates = [:]
    var currentAlpha = ""
    var currentBeta  = ""

    for line in body.components(separatedBy: "\n") {
        let stmt = line.trimmingCharacters(in: .whitespaces)
        guard !stmt.isEmpty else { continue }

        func rhs() -> String {
            guard let eq = stmt.firstIndex(of: "=") else { return "" }
            return String(stmt[stmt.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }

        let lower = stmt.lowercased()
        if lower.hasPrefix("alpha") && stmt.contains("=") {
            currentAlpha = rhs()
        } else if lower.hasPrefix("beta") && stmt.contains("=") {
            currentBeta = rhs()
        } else {
            for gate in stateVars {
                if lower.hasPrefix(gate + "inf") && stmt.contains("=") {
                    if !currentAlpha.isEmpty && !currentBeta.isEmpty {
                        result[gate] = (alpha: currentAlpha, beta: currentBeta)
                    }
                    break
                }
            }
        }
    }
    return result
}

// MARK: - Inf/tau parser with local-variable inlining (Destexhe/Traub style)

/// Handles procedures like `evaluate_fct` that compute:
///   v2     = v - vtraub          ← local alias for shifted voltage
///   a      = alpha_expr(v2)      ← intermediate (re-used per gate)
///   b      = beta_expr(v2)       ← intermediate (re-used per gate)
///   tau_m  = 1 / (a + b) / tadj  ← gate kinetic
///   m_inf  = a / (a + b)         ← gate kinetic
///   a      = ...                 ← a is REUSED for next gate
///
/// Key: each local variable is inlined INTO the rhs **immediately** as each
/// line is read, and the fully-expanded value is stored back.  That way when
/// `a` is reassigned for the h-gate, the m-gate expressions already contain
/// the m-gate value of `a` — not the h-gate value.
private func parseInfTau(_ body: String,
                           stateVars: [String],
                           params: inout [String: Double]) -> ITRates {

    // name → fully-expanded expression (no local-var references left)
    var localMap: [String: String] = [:]
    var infExprs: [String: String] = [:]
    var tauExprs: [String: String] = [:]

    for rawLine in body.components(separatedBy: "\n") {
        let stmt = rawLine.trimmingCharacters(in: .whitespaces)
        guard !stmt.isEmpty, stmt.contains("=") else { continue }
        let lower = stmt.lowercased()
        // Skip non-assignment control keywords
        guard !lower.hasPrefix("verbatim"), !lower.hasPrefix("endverbatim"),
              !lower.hasPrefix("local"),    !lower.hasPrefix("solve"),
              !lower.hasPrefix("if"),       !lower.hasPrefix("else")
        else { continue }

        guard let eqIdx = stmt.firstIndex(of: "=") else { continue }
        let lhs = stmt[..<eqIdx].trimmingCharacters(in: .whitespaces)
        var rhs = String(stmt[stmt.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !lhs.isEmpty,
              lhs.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !rhs.isEmpty
        else { continue }

        // ── Inline every currently-known local variable into rhs. ──────────
        // Because stored values are already fully expanded, a single pass
        // through localMap suffices — no chained look-up needed.
        for (varName, varExpr) in localMap {
            rhs = inlineLocalVar(varName, replacement: varExpr, in: rhs)
        }

        // ── Classify the lhs ───────────────────────────────────────────────
        var isGateKinetic = false
        for gate in stateVars {
            if lhs == "\(gate)_inf" || lhs == "\(gate)inf" {
                infExprs[gate] = rhs; isGateKinetic = true; break
            }
            if lhs == "tau_\(gate)" || lhs == "\(gate)_tau" {
                tauExprs[gate] = rhs; isGateKinetic = true; break
            }
        }
        // Store (or overwrite) the fully-expanded local variable.
        // Overwriting is intentional: when `a` is reassigned for the next
        // gate, the old gate's expressions already captured its value.
        if !isGateKinetic && !stateVars.contains(lhs) {
            localMap[lhs] = rhs
        }
    }

    // Ensure temperature-adjustment factor is available as a numeric param.
    // tadj = Q10 ^ ((celsius − 36) / 10) — standard Traub/Destexhe convention.
    if params["tadj"] == nil {
        let celsius = params["celsius"] ?? 36.0
        params["tadj"] = pow(3.0, (celsius - 36.0) / 10.0)
    }

    var result: ITRates = [:]
    for gate in stateVars {
        if let inf = infExprs[gate], let tau = tauExprs[gate] {
            result[gate] = (inf: inf, tau: tau)
        }
    }
    return result
}

/// Replace whole-word occurrences of `name` with `(replacement)` using
/// look-around assertions to avoid partial-identifier matches.
private func inlineLocalVar(_ name: String, replacement: String, in expr: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = "(?<![a-zA-Z0-9_])\(escaped)(?![a-zA-Z0-9_])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return expr }
    let range = NSRange(expr.startIndex..., in: expr)
    return regex.stringByReplacingMatches(in: expr, range: range,
                                          withTemplate: "(\(replacement))")
}

// MARK: - Derived-param enrichment

/// Adds computed constants that are defined outside the PARAMETER block
/// (e.g. tadj derived from celsius, which is common in temperature-scaled models).
private func enrichDerivedParams(_ params: inout [String: Double]) {
    if params["tadj"] == nil {
        let celsius = params["celsius"] ?? 36.0
        params["tadj"] = pow(3.0, (celsius - 36.0) / 10.0)
    }
}

// MARK: - Gate assembly

private func buildGates(info: ChannelComponents,
                         stateVars: [String],
                         abRates: ABRates,
                         itRates: ITRates,
                         params: [String: Double]) -> [MODGateDescription] {
    var gates: [MODGateDescription] = []
    for gate in stateVars where info.gates.contains(gate) {
        let power = info.gateCounts[gate] ?? 1
        if let (alpha, beta) = abRates[gate] {
            gates.append(MODGateDescription(
                name: gate, power: power,
                alphaExpr: alpha, betaExpr: beta,
                params: params))
        } else if let (inf, tau) = itRates[gate] {
            gates.append(MODGateDescription(
                name: gate, power: power,
                alphaExpr: "", betaExpr: "",
                infExpr: inf, tauExpr: tau,
                params: params))
        }
    }
    return gates
}

// MARK: - Helpers

private func ionDisplayName(_ ion: String) -> String {
    switch ion.lowercased() {
    case "na":  return "Na⁺ (MOD)"
    case "k":   return "K⁺ (MOD)"
    case "ca":  return "Ca²⁺ (MOD)"
    case "cl":  return "Cl⁻ (MOD)"
    default:    return "\(ion.uppercased())⁺ (MOD)"
    }
}

private func convertConductance(value: Double, unit: String) -> Double {
    // mho/cm² = S/cm² → ×1000 to get mS/cm²
    let u = unit.lowercased()
    if u.contains("mho") || (u.contains("s/cm") && !u.contains("ms")) {
        return value * 1000.0
    }
    return value
}
