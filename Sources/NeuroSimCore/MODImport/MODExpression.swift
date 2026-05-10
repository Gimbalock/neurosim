// MODExpression.swift
// NeuroSimCore — evaluates NMODL math expressions at runtime.
//
// Supported: +, -, *, /, ^ (power), unary minus, parentheses
// Functions: exp, fabs, abs, log, sqrt, vtrap(x,y)
// Variables: v (membrane voltage, mV); named constants via `params` dict.

import Foundation

// MARK: - Tokens (internal, shared with MODFileParser)

enum MODToken {
    case number(Double)
    case identifier(String)
    case op(String)          // "+", "-", "*", "/", "^"
    case lparen, rparen, comma
}

func modTokenize(_ source: String) -> [MODToken] {
    var tokens: [MODToken] = []
    var i = source.startIndex

    while i < source.endIndex {
        let c = source[i]
        if c.isWhitespace { i = source.index(after: i); continue }

        // Number — leading dot allowed (e.g. .1)
        let nextIsDigit: Bool = {
            let n = source.index(after: i)
            return n < source.endIndex && source[n].isNumber
        }()
        if c.isNumber || (c == "." && nextIsDigit) {
            var num = ""
            while i < source.endIndex {
                let ch = source[i]
                if ch.isNumber || ch == "." {
                    num.append(ch); i = source.index(after: i)
                } else if ch == "e" || ch == "E" {
                    num.append(ch); i = source.index(after: i)
                    if i < source.endIndex && (source[i] == "+" || source[i] == "-") {
                        num.append(source[i]); i = source.index(after: i)
                    }
                } else { break }
            }
            tokens.append(.number(Double(num) ?? 0))
            continue
        }

        // Identifier
        if c.isLetter || c == "_" {
            var id = ""
            while i < source.endIndex && (source[i].isLetter || source[i].isNumber || source[i] == "_") {
                id.append(source[i]); i = source.index(after: i)
            }
            tokens.append(.identifier(id))
            continue
        }

        switch c {
        case "(": tokens.append(.lparen)
        case ")": tokens.append(.rparen)
        case ",": tokens.append(.comma)
        case "+": tokens.append(.op("+"))
        case "-": tokens.append(.op("-"))
        case "*": tokens.append(.op("*"))
        case "/": tokens.append(.op("/"))
        case "^": tokens.append(.op("^"))
        default:  break
        }
        i = source.index(after: i)
    }
    return tokens
}

// MARK: - AST

indirect enum MODExprNode {
    case number(Double)
    case variable(String)
    case unaryMinus(MODExprNode)
    case binary(String, MODExprNode, MODExprNode)
    case call(String, [MODExprNode])

    func eval(v: Double, params: [String: Double]) -> Double {
        switch self {
        case .number(let d):  return d
        case .variable(let n): return n == "v" ? v : (params[n] ?? 0)
        case .unaryMinus(let e): return -e.eval(v: v, params: params)
        case .binary(let op, let lhs, let rhs):
            let l = lhs.eval(v: v, params: params)
            let r = rhs.eval(v: v, params: params)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return r == 0 ? 0 : l / r
            case "^": return pow(l, r)
            default:  return 0
            }
        case .call(let fn, let args):
            let a = args.map { $0.eval(v: v, params: params) }
            switch fn.lowercased() {
            // "Exp" (Destexhe convention) and "exp" both supported;
            // mirror NMODL's clamped version: returns 0 for x < -100.
            case "exp":
                if a.count < 1 { return 0 }
                return a[0] < -100 ? 0 : Foundation.exp(a[0])
            case "fabs", "abs": return a.count >= 1 ? Foundation.fabs(a[0]) : 0
            case "log":         return a.count >= 1 ? Foundation.log(a[0]) : 0
            case "sqrt":        return a.count >= 1 ? Foundation.sqrt(a[0]) : 0
            case "vtrap":       return a.count >= 2 ? modVtrap(a[0], a[1]) : 0
            case "normrand":    return a.count >= 1 ? a[0] : 0   // treat as mean (ignore noise)
            default:            return 0
            }
        }
    }
}

private func modVtrap(_ x: Double, _ y: Double) -> Double {
    guard y != 0 else { return 0 }
    if fabs(x / y) < 1e-6 { return y * (1.0 - x / y / 2.0) }
    let ex = exp(x / y)
    return ex.isFinite ? x / (ex - 1.0) : 0
}

// MARK: - Recursive Descent Parser

public enum MODExprError: Error, LocalizedError {
    case unexpectedToken(String)
    case unexpectedEnd
    case missingCloseParen

    public var errorDescription: String? {
        switch self {
        case .unexpectedToken(let t): return "Unexpected token '\(t)'"
        case .unexpectedEnd:          return "Unexpected end of expression"
        case .missingCloseParen:      return "Missing ')'"
        }
    }
}

struct MODExprParser {
    let tokens: [MODToken]
    var pos: Int = 0

    mutating func parse() throws -> MODExprNode {
        let e = try parseExpr()
        if pos < tokens.count { throw MODExprError.unexpectedToken(tokenDesc(tokens[pos])) }
        return e
    }

    mutating func parseExpr() throws -> MODExprNode {
        var lhs = try parseTerm()
        while pos < tokens.count, case .op(let op) = tokens[pos], op == "+" || op == "-" {
            pos += 1; lhs = .binary(op, lhs, try parseTerm())
        }
        return lhs
    }

    mutating func parseTerm() throws -> MODExprNode {
        var lhs = try parseFactor()
        while pos < tokens.count, case .op(let op) = tokens[pos], op == "*" || op == "/" {
            pos += 1; lhs = .binary(op, lhs, try parseFactor())
        }
        return lhs
    }

    mutating func parseFactor() throws -> MODExprNode {
        if pos < tokens.count, case .op("-") = tokens[pos] { pos += 1; return .unaryMinus(try parseFactor()) }
        if pos < tokens.count, case .op("+") = tokens[pos] { pos += 1; return try parseFactor() }
        return try parsePower()
    }

    mutating func parsePower() throws -> MODExprNode {
        let base = try parseAtom()
        if pos < tokens.count, case .op("^") = tokens[pos] {
            pos += 1; return .binary("^", base, try parseFactor())
        }
        return base
    }

    mutating func parseAtom() throws -> MODExprNode {
        guard pos < tokens.count else { throw MODExprError.unexpectedEnd }
        switch tokens[pos] {
        case .number(let d):
            pos += 1; return .number(d)
        case .identifier(let name):
            pos += 1
            guard pos < tokens.count, case .lparen = tokens[pos] else { return .variable(name) }
            pos += 1
            if pos < tokens.count, case .rparen = tokens[pos] { pos += 1; return .call(name, []) }
            var args: [MODExprNode] = [try parseExpr()]
            while pos < tokens.count, case .comma = tokens[pos] { pos += 1; args.append(try parseExpr()) }
            guard pos < tokens.count, case .rparen = tokens[pos] else { throw MODExprError.missingCloseParen }
            pos += 1; return .call(name, args)
        case .lparen:
            pos += 1
            let e = try parseExpr()
            guard pos < tokens.count, case .rparen = tokens[pos] else { throw MODExprError.missingCloseParen }
            pos += 1; return e
        default:
            throw MODExprError.unexpectedToken(tokenDesc(tokens[pos]))
        }
    }
}

private func tokenDesc(_ t: MODToken) -> String {
    switch t {
    case .number(let d):      return "\(d)"
    case .identifier(let s):  return s
    case .op(let s):          return s
    case .lparen:             return "("
    case .rparen:             return ")"
    case .comma:              return ","
    }
}

// MARK: - Public struct

/// A compiled NMODL math expression. Source is stored for Codable; AST evaluates at runtime.
public struct MODExpression {
    public let source: String
    let root: MODExprNode

    public init(_ source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        self.source = trimmed
        var parser = MODExprParser(tokens: modTokenize(trimmed))
        self.root = try parser.parse()
    }

    public func evaluate(v: Double, params: [String: Double] = [:]) -> Double {
        root.eval(v: v, params: params)
    }
}
