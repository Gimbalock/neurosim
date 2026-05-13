//
//  OptimParam.swift
//  NeuroSimApp
//
//  One optimizable parameter: name, current value, [min, max] bounds, active flag.
//  ParamTarget encodes the write path into the neuron model so the optimizer
//  can apply a value without storing closures.
//

import Foundation
import NeuroSimCore

// MARK: - Descriptor

struct OptimParam: Identifiable, Equatable {
    let id           = UUID()
    var isActive:      Bool
    let label:         String      // e.g. "Na·gMax"
    let unit:          String      // e.g. "mS/cm²"
    var currentValue:  Double      // initial snapshot, updated after each optim step
    var minBound:      Double
    var maxBound:      Double
    let target:        ParamTarget
}

// MARK: - Write path

enum ParamTarget: Hashable {
    // All channels
    case channelGMax(ci: Int, chi: Int)
    // HHGated standard channels: sigmoid x∞ override
    case gateInfVHalf(ci: Int, chi: Int, gi: Int)
    case gateInfSlope(ci: Int, chi: Int, gi: Int)
    // HHGated standard channels: gaussian τ override
    case gateTauMin(ci: Int, chi: Int, gi: Int)
    case gateTauMax(ci: Int, chi: Int, gi: Int)
    case gateTauVPeak(ci: Int, chi: Int, gi: Int)
    case gateTauWidth(ci: Int, chi: Int, gi: Int)
    // CustomChannel gate definition
    case customGateVHalf(ci: Int, chi: Int, gi: Int)
    case customGateSlope(ci: Int, chi: Int, gi: Int)
    case customGateTauMin(ci: Int, chi: Int, gi: Int)
    case customGateTauMax(ci: Int, chi: Int, gi: Int)
    case customGateVPeak(ci: Int, chi: Int, gi: Int)
    case customGateTauWidth(ci: Int, chi: Int, gi: Int)
    // SK channel
    case skHalfActivation(ci: Int, chi: Int)
    case skHillCoeff(ci: Int, chi: Int)
    case skTauActivation(ci: Int, chi: Int)
    // BK channel
    case bkVHalfAtRef(ci: Int, chi: Int)
    case bkCaShift(ci: Int, chi: Int)
    case bkSlopeFactor(ci: Int, chi: Int)
    case bkTauMin(ci: Int, chi: Int)
    case bkTauMax(ci: Int, chi: Int)
}

// MARK: - Builder

/// Extract all optimizable parameters from a neuron.
/// gMax of every channel is active by default; everything else is unchecked.
func makeOptimParams(for neuron: HHNeuron) -> [OptimParam] {
    var params: [OptimParam] = []
    let multi = neuron.compartments.count > 1

    for (ci, comp) in neuron.compartments.enumerated() {
        let cpfx = multi ? "\(comp.name)·" : ""

        for (chi, ch) in comp.channels.enumerated() {
            let pfx = "\(cpfx)\(ch.name)"

            // gMax — checked by default
            params.append(OptimParam(
                isActive: true, label: "\(pfx)·gMax", unit: "mS/cm²",
                currentValue: ch.gMax,
                minBound: 0.0, maxBound: max(ch.gMax * 5, 1.0),
                target: .channelGMax(ci: ci, chi: chi)))

            // HHGated standard channels: expose sigmoid x∞ and gaussian τ overrides.
            // Skipped for CustomChannel (handled separately below via its gate definition).
            if !(ch is CustomChannel), let gated = ch as? any HHGated {
                for (gi, gateName) in gated.gateNames.enumerated() {
                    let gp = "\(pfx)[\(gateName)]"
                    // Sigmoid x∞ override
                    if gi < gated.gateInfOverrides.count,
                       let infCurve = gated.gateInfOverrides[gi],
                       case .sigmoid(_, _, let vHalf, let k, _) = infCurve {
                        params += [
                            OptimParam(isActive: false, label: "\(gp)·x∞·vHalf", unit: "mV",
                                       currentValue: vHalf,
                                       minBound: vHalf - 40, maxBound: vHalf + 40,
                                       target: .gateInfVHalf(ci: ci, chi: chi, gi: gi)),
                            OptimParam(isActive: false, label: "\(gp)·x∞·slope", unit: "mV",
                                       currentValue: k,
                                       minBound: -60, maxBound: 60,
                                       target: .gateInfSlope(ci: ci, chi: chi, gi: gi)),
                        ]
                    }
                    // Gaussian τ override
                    if gi < gated.gateTauOverrides.count,
                       let tauCurve = gated.gateTauOverrides[gi],
                       case .gaussian(let tMin, let tMax, let vPeak, let width, _) = tauCurve {
                        params += [
                            OptimParam(isActive: false, label: "\(gp)·τ·min",   unit: "ms",
                                       currentValue: tMin,
                                       minBound: 0.01, maxBound: 100,
                                       target: .gateTauMin(ci: ci, chi: chi, gi: gi)),
                            OptimParam(isActive: false, label: "\(gp)·τ·max",   unit: "ms",
                                       currentValue: tMax,
                                       minBound: 0.1, maxBound: 1000,
                                       target: .gateTauMax(ci: ci, chi: chi, gi: gi)),
                            OptimParam(isActive: false, label: "\(gp)·τ·vPeak", unit: "mV",
                                       currentValue: vPeak,
                                       minBound: vPeak - 40, maxBound: vPeak + 40,
                                       target: .gateTauVPeak(ci: ci, chi: chi, gi: gi)),
                            OptimParam(isActive: false, label: "\(gp)·τ·width", unit: "mV",
                                       currentValue: width,
                                       minBound: 1, maxBound: 100,
                                       target: .gateTauWidth(ci: ci, chi: chi, gi: gi)),
                        ]
                    }
                }
            }

            // CustomChannel: per-gate kinetic parameters
            if let cc = ch as? CustomChannel {
                for (gi, g) in cc.definition.gates.enumerated() {
                    let gp = "\(pfx)[\(g.name)]"
                    params += [
                        OptimParam(isActive: false, label: "\(gp)·vHalf",   unit: "mV",
                                   currentValue: g.vHalf,    minBound: g.vHalf - 40,  maxBound: g.vHalf + 40,
                                   target: .customGateVHalf(ci: ci, chi: chi, gi: gi)),
                        OptimParam(isActive: false, label: "\(gp)·slope",   unit: "mV",
                                   currentValue: g.slope,    minBound: -50,             maxBound: 50,
                                   target: .customGateSlope(ci: ci, chi: chi, gi: gi)),
                        OptimParam(isActive: false, label: "\(gp)·τMin",    unit: "ms",
                                   currentValue: g.tauMin,   minBound: 0.01,            maxBound: 100,
                                   target: .customGateTauMin(ci: ci, chi: chi, gi: gi)),
                        OptimParam(isActive: false, label: "\(gp)·τMax",    unit: "ms",
                                   currentValue: g.tauMax,   minBound: 0.1,             maxBound: 1000,
                                   target: .customGateTauMax(ci: ci, chi: chi, gi: gi)),
                        OptimParam(isActive: false, label: "\(gp)·vPeak",   unit: "mV",
                                   currentValue: g.vPeak,    minBound: g.vPeak - 40,   maxBound: g.vPeak + 40,
                                   target: .customGateVPeak(ci: ci, chi: chi, gi: gi)),
                        OptimParam(isActive: false, label: "\(gp)·τWidth",  unit: "mV",
                                   currentValue: g.tauWidth, minBound: 1,               maxBound: 100,
                                   target: .customGateTauWidth(ci: ci, chi: chi, gi: gi)),
                    ]
                }
            }

            // SK channel
            if let sk = ch as? SKChannel {
                params += [
                    OptimParam(isActive: false, label: "\(pfx)·K½",   unit: "mM",
                               currentValue: sk.halfActivation,  minBound: 1e-6, maxBound: 1e-2,
                               target: .skHalfActivation(ci: ci, chi: chi)),
                    OptimParam(isActive: false, label: "\(pfx)·Hill", unit: "",
                               currentValue: sk.hillCoefficient, minBound: 0.5,  maxBound: 10,
                               target: .skHillCoeff(ci: ci, chi: chi)),
                    OptimParam(isActive: false, label: "\(pfx)·τact", unit: "ms",
                               currentValue: sk.tauActivation,   minBound: 1,    maxBound: 500,
                               target: .skTauActivation(ci: ci, chi: chi)),
                ]
            }

            // BK channel
            if let bk = ch as? BKChannel {
                params += [
                    OptimParam(isActive: false, label: "\(pfx)·V½",     unit: "mV",
                               currentValue: bk.vHalfAtRef,  minBound: -80,  maxBound: 80,
                               target: .bkVHalfAtRef(ci: ci, chi: chi)),
                    OptimParam(isActive: false, label: "\(pfx)·caShift",unit: "mV",
                               currentValue: bk.caShift,     minBound: 0,    maxBound: 100,
                               target: .bkCaShift(ci: ci, chi: chi)),
                    OptimParam(isActive: false, label: "\(pfx)·slope",  unit: "mV",
                               currentValue: bk.slopeFactor, minBound: 1,    maxBound: 100,
                               target: .bkSlopeFactor(ci: ci, chi: chi)),
                    OptimParam(isActive: false, label: "\(pfx)·τMin",   unit: "ms",
                               currentValue: bk.tauMin,      minBound: 0.01, maxBound: 100,
                               target: .bkTauMin(ci: ci, chi: chi)),
                    OptimParam(isActive: false, label: "\(pfx)·τMax",   unit: "ms",
                               currentValue: bk.tauMax,      minBound: 0.1,  maxBound: 100,
                               target: .bkTauMax(ci: ci, chi: chi)),
                ]
            }
        }
    }
    return params
}

// MARK: - Apply

// MARK: - Document ↔ OptimParam conversion

extension ParamTarget {

    var docKind: String {
        switch self {
        case .channelGMax:        return "channelGMax"
        case .gateInfVHalf:       return "gateInfVHalf"
        case .gateInfSlope:       return "gateInfSlope"
        case .gateTauMin:         return "gateTauMin"
        case .gateTauMax:         return "gateTauMax"
        case .gateTauVPeak:       return "gateTauVPeak"
        case .gateTauWidth:       return "gateTauWidth"
        case .customGateVHalf:    return "customGateVHalf"
        case .customGateSlope:    return "customGateSlope"
        case .customGateTauMin:   return "customGateTauMin"
        case .customGateTauMax:   return "customGateTauMax"
        case .customGateVPeak:    return "customGateVPeak"
        case .customGateTauWidth: return "customGateTauWidth"
        case .skHalfActivation:   return "skHalfActivation"
        case .skHillCoeff:        return "skHillCoeff"
        case .skTauActivation:    return "skTauActivation"
        case .bkVHalfAtRef:       return "bkVHalfAtRef"
        case .bkCaShift:          return "bkCaShift"
        case .bkSlopeFactor:      return "bkSlopeFactor"
        case .bkTauMin:           return "bkTauMin"
        case .bkTauMax:           return "bkTauMax"
        }
    }

    var docCI: Int {
        switch self {
        case .channelGMax(let ci, _):           return ci
        case .gateInfVHalf(let ci, _, _):       return ci
        case .gateInfSlope(let ci, _, _):       return ci
        case .gateTauMin(let ci, _, _):         return ci
        case .gateTauMax(let ci, _, _):         return ci
        case .gateTauVPeak(let ci, _, _):       return ci
        case .gateTauWidth(let ci, _, _):       return ci
        case .customGateVHalf(let ci, _, _):    return ci
        case .customGateSlope(let ci, _, _):    return ci
        case .customGateTauMin(let ci, _, _):   return ci
        case .customGateTauMax(let ci, _, _):   return ci
        case .customGateVPeak(let ci, _, _):    return ci
        case .customGateTauWidth(let ci, _, _): return ci
        case .skHalfActivation(let ci, _):      return ci
        case .skHillCoeff(let ci, _):           return ci
        case .skTauActivation(let ci, _):       return ci
        case .bkVHalfAtRef(let ci, _):          return ci
        case .bkCaShift(let ci, _):             return ci
        case .bkSlopeFactor(let ci, _):         return ci
        case .bkTauMin(let ci, _):              return ci
        case .bkTauMax(let ci, _):              return ci
        }
    }

    var docCHI: Int {
        switch self {
        case .channelGMax(_, let chi):           return chi
        case .gateInfVHalf(_, let chi, _):       return chi
        case .gateInfSlope(_, let chi, _):       return chi
        case .gateTauMin(_, let chi, _):         return chi
        case .gateTauMax(_, let chi, _):         return chi
        case .gateTauVPeak(_, let chi, _):       return chi
        case .gateTauWidth(_, let chi, _):       return chi
        case .customGateVHalf(_, let chi, _):    return chi
        case .customGateSlope(_, let chi, _):    return chi
        case .customGateTauMin(_, let chi, _):   return chi
        case .customGateTauMax(_, let chi, _):   return chi
        case .customGateVPeak(_, let chi, _):    return chi
        case .customGateTauWidth(_, let chi, _): return chi
        case .skHalfActivation(_, let chi):      return chi
        case .skHillCoeff(_, let chi):           return chi
        case .skTauActivation(_, let chi):       return chi
        case .bkVHalfAtRef(_, let chi):          return chi
        case .bkCaShift(_, let chi):             return chi
        case .bkSlopeFactor(_, let chi):         return chi
        case .bkTauMin(_, let chi):              return chi
        case .bkTauMax(_, let chi):              return chi
        }
    }

    var docGI: Int {
        switch self {
        case .gateInfVHalf(_, _, let gi):       return gi
        case .gateInfSlope(_, _, let gi):       return gi
        case .gateTauMin(_, _, let gi):         return gi
        case .gateTauMax(_, _, let gi):         return gi
        case .gateTauVPeak(_, _, let gi):       return gi
        case .gateTauWidth(_, _, let gi):       return gi
        case .customGateVHalf(_, _, let gi):    return gi
        case .customGateSlope(_, _, let gi):    return gi
        case .customGateTauMin(_, _, let gi):   return gi
        case .customGateTauMax(_, _, let gi):   return gi
        case .customGateVPeak(_, _, let gi):    return gi
        case .customGateTauWidth(_, _, let gi): return gi
        default:                                return -1
        }
    }

    static func from(kind: String, ci: Int, chi: Int, gi: Int) -> ParamTarget? {
        switch kind {
        case "channelGMax":        return .channelGMax(ci: ci, chi: chi)
        case "gateInfVHalf":       return .gateInfVHalf(ci: ci, chi: chi, gi: gi)
        case "gateInfSlope":       return .gateInfSlope(ci: ci, chi: chi, gi: gi)
        case "gateTauMin":         return .gateTauMin(ci: ci, chi: chi, gi: gi)
        case "gateTauMax":         return .gateTauMax(ci: ci, chi: chi, gi: gi)
        case "gateTauVPeak":       return .gateTauVPeak(ci: ci, chi: chi, gi: gi)
        case "gateTauWidth":       return .gateTauWidth(ci: ci, chi: chi, gi: gi)
        case "customGateVHalf":    return .customGateVHalf(ci: ci, chi: chi, gi: gi)
        case "customGateSlope":    return .customGateSlope(ci: ci, chi: chi, gi: gi)
        case "customGateTauMin":   return .customGateTauMin(ci: ci, chi: chi, gi: gi)
        case "customGateTauMax":   return .customGateTauMax(ci: ci, chi: chi, gi: gi)
        case "customGateVPeak":    return .customGateVPeak(ci: ci, chi: chi, gi: gi)
        case "customGateTauWidth": return .customGateTauWidth(ci: ci, chi: chi, gi: gi)
        case "skHalfActivation":   return .skHalfActivation(ci: ci, chi: chi)
        case "skHillCoeff":        return .skHillCoeff(ci: ci, chi: chi)
        case "skTauActivation":    return .skTauActivation(ci: ci, chi: chi)
        case "bkVHalfAtRef":       return .bkVHalfAtRef(ci: ci, chi: chi)
        case "bkCaShift":          return .bkCaShift(ci: ci, chi: chi)
        case "bkSlopeFactor":      return .bkSlopeFactor(ci: ci, chi: chi)
        case "bkTauMin":           return .bkTauMin(ci: ci, chi: chi)
        case "bkTauMax":           return .bkTauMax(ci: ci, chi: chi)
        // Legacy keys (old files that had Cm / E_rev) — silently dropped
        default:                   return nil
        }
    }
}

extension OptimConfig {

    func toDoc(params: [OptimParam]) -> NetworkDocument.OptimSettingsDoc {
        NetworkDocument.OptimSettingsDoc(
            algorithm:     algorithm.rawValue,
            maxIterations: maxIterations,
            targetError:   targetError,
            simDuration:   simDuration,
            deF:           deF,
            deCR:          deCR,
            dePopFactor:   dePopFactor,
            cmaeSigma0:    cmaeSigma0,
            params:        params.map { p in
                NetworkDocument.OptimParamDoc(
                    targetKind: p.target.docKind,
                    ci:         p.target.docCI,
                    chi:        p.target.docCHI,
                    gi:         p.target.docGI,
                    isActive:   p.isActive,
                    minBound:   p.minBound,
                    maxBound:   p.maxBound)
            }
        )
    }
}

extension NetworkDocument.OptimSettingsDoc {

    func toConfig() -> OptimConfig {
        var c = OptimConfig()
        c.algorithm     = OptimizerAlgorithm(rawValue: algorithm) ?? .differentialEvolution
        c.maxIterations = maxIterations
        c.targetError   = targetError
        c.simDuration   = simDuration
        c.deF           = deF
        c.deCR          = deCR
        c.dePopFactor   = dePopFactor
        c.cmaeSigma0    = cmaeSigma0
        return c
    }

    /// Returns a dictionary keyed by ParamTarget for fast lookup when
    /// merging saved settings into a freshly-built OptimParam list.
    func paramOverrides() -> [ParamTarget: NetworkDocument.OptimParamDoc] {
        var dict: [ParamTarget: NetworkDocument.OptimParamDoc] = [:]
        for p in params {
            if let t = ParamTarget.from(kind: p.targetKind, ci: p.ci, chi: p.chi, gi: p.gi) {
                dict[t] = p
            }
        }
        return dict
    }
}

// MARK: - Gate override helpers

/// Update a sigmoid x∞ override on any HHGated class-based channel.
private func applyGateInfSigmoid<C: HHGated & AnyObject>(
    _ ch: C, gi: Int, transform: (Double, Double, Double, Double) -> GateCurve) {
    guard gi < ch.gateInfOverrides.count,
          let curve = ch.gateInfOverrides[gi],
          case .sigmoid(let lo, let hi, let vHalf, let k, let domain) = curve
    else { return }
    ch.gateInfOverrides[gi] = transform(lo, hi, vHalf, k)
}

/// Update a gaussian τ override on any HHGated class-based channel.
private func applyGateTauGaussian<C: HHGated & AnyObject>(
    _ ch: C, gi: Int, transform: (Double, Double, Double, Double) -> GateCurve) {
    guard gi < ch.gateTauOverrides.count,
          let curve = ch.gateTauOverrides[gi],
          case .gaussian(let tMin, let tMax, let vPeak, let width, let domain) = curve
    else { return }
    ch.gateTauOverrides[gi] = transform(tMin, tMax, vPeak, width)
}

/// Dispatch gate inf update to whatever concrete HHGated type owns the channel.
private func withGateInf(_ ch: IonChannel, gi: Int,
                          inf: @escaping (Double, Double, Double, Double) -> GateCurve) {
    switch ch {
    case let c as SodiumChannel:       applyGateInfSigmoid(c, gi: gi, transform: inf)
    case let c as PotassiumChannel:    applyGateInfSigmoid(c, gi: gi, transform: inf)
    case let c as TTypeCalciumChannel: applyGateInfSigmoid(c, gi: gi, transform: inf)
    default: break
    }
}

/// Dispatch gate tau update to whatever concrete HHGated type owns the channel.
private func withGateTau(_ ch: IonChannel, gi: Int,
                          tau: @escaping (Double, Double, Double, Double) -> GateCurve) {
    switch ch {
    case let c as SodiumChannel:       applyGateTauGaussian(c, gi: gi, transform: tau)
    case let c as PotassiumChannel:    applyGateTauGaussian(c, gi: gi, transform: tau)
    case let c as TTypeCalciumChannel: applyGateTauGaussian(c, gi: gi, transform: tau)
    default: break
    }
}

// MARK: - Apply

/// Write a single parameter value back into the network model.
/// Network is a class (reference type) — no inout needed.
func applyOptimParam(_ param: OptimParam, value: Double,
                     neuronID: UUID, network: Network) {
    network.updateNeuron(id: neuronID) { n in
        switch param.target {

        case .channelGMax(let ci, let chi):
            n.compartments[ci].channels[chi].gMax = value

        // HHGated standard channels — sigmoid x∞ override
        case .gateInfVHalf(let ci, let chi, let gi):
            withGateInf(n.compartments[ci].channels[chi], gi: gi) { lo, hi, _, k in
                .sigmoid(lo: lo, hi: hi, vHalf: value, k: k, domain: nil)
            }
        case .gateInfSlope(let ci, let chi, let gi):
            withGateInf(n.compartments[ci].channels[chi], gi: gi) { lo, hi, vHalf, _ in
                .sigmoid(lo: lo, hi: hi, vHalf: vHalf, k: value, domain: nil)
            }

        // HHGated standard channels — gaussian τ override
        case .gateTauMin(let ci, let chi, let gi):
            withGateTau(n.compartments[ci].channels[chi], gi: gi) { _, tMax, vPeak, width in
                .gaussian(tauMin: value, tauMax: tMax, vPeak: vPeak, width: width, domain: nil)
            }
        case .gateTauMax(let ci, let chi, let gi):
            withGateTau(n.compartments[ci].channels[chi], gi: gi) { tMin, _, vPeak, width in
                .gaussian(tauMin: tMin, tauMax: value, vPeak: vPeak, width: width, domain: nil)
            }
        case .gateTauVPeak(let ci, let chi, let gi):
            withGateTau(n.compartments[ci].channels[chi], gi: gi) { tMin, tMax, _, width in
                .gaussian(tauMin: tMin, tauMax: tMax, vPeak: value, width: width, domain: nil)
            }
        case .gateTauWidth(let ci, let chi, let gi):
            withGateTau(n.compartments[ci].channels[chi], gi: gi) { tMin, tMax, vPeak, _ in
                .gaussian(tauMin: tMin, tauMax: tMax, vPeak: vPeak, width: value, domain: nil)
            }

        case .customGateVHalf(let ci, let chi, let gi):
            guard let cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].vHalf = value

        case .customGateSlope(let ci, let chi, let gi):
            guard let cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].slope = value

        case .customGateTauMin(let ci, let chi, let gi):
            guard let cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].tauMin = value

        case .customGateTauMax(let ci, let chi, let gi):
            guard let cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].tauMax = value

        case .customGateVPeak(let ci, let chi, let gi):
            guard let cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].vPeak = value

        case .customGateTauWidth(let ci, let chi, let gi):
            guard let cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].tauWidth = value

        case .skHalfActivation(let ci, let chi):
            guard let sk = n.compartments[ci].channels[chi] as? SKChannel else { return }
            sk.halfActivation = value

        case .skHillCoeff(let ci, let chi):
            guard let sk = n.compartments[ci].channels[chi] as? SKChannel else { return }
            sk.hillCoefficient = value

        case .skTauActivation(let ci, let chi):
            guard let sk = n.compartments[ci].channels[chi] as? SKChannel else { return }
            sk.tauActivation = value

        case .bkVHalfAtRef(let ci, let chi):
            guard let bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.vHalfAtRef = value

        case .bkCaShift(let ci, let chi):
            guard let bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.caShift = value

        case .bkSlopeFactor(let ci, let chi):
            guard let bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.slopeFactor = value

        case .bkTauMin(let ci, let chi):
            guard let bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.tauMin = value

        case .bkTauMax(let ci, let chi):
            guard let bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.tauMax = value
        }
    }
}
