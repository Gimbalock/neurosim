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
    // Membrane
    case compartmentCm(ci: Int)
    // All channels
    case channelGMax(ci: Int, chi: Int)
    case channelReversal(ci: Int, chi: Int)
    // CustomChannel gate
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

        // Membrane capacitance
        params.append(OptimParam(
            isActive: false, label: "\(cpfx)Cm", unit: "µF/cm²",
            currentValue: comp.capacitance, minBound: 0.1, maxBound: 10.0,
            target: .compartmentCm(ci: ci)))

        for (chi, ch) in comp.channels.enumerated() {
            let pfx = "\(cpfx)\(ch.name)"

            // gMax — checked by default
            params.append(OptimParam(
                isActive: true, label: "\(pfx)·gMax", unit: "mS/cm²",
                currentValue: ch.gMax,
                minBound: 0.0, maxBound: max(ch.gMax * 5, 1.0),
                target: .channelGMax(ci: ci, chi: chi)))

            // Reversal potential
            params.append(OptimParam(
                isActive: false, label: "\(pfx)·E_rev", unit: "mV",
                currentValue: ch.reversal,
                minBound: ch.reversal - 50, maxBound: ch.reversal + 50,
                target: .channelReversal(ci: ci, chi: chi)))

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
        case .compartmentCm:     return "compartmentCm"
        case .channelGMax:       return "channelGMax"
        case .channelReversal:   return "channelReversal"
        case .customGateVHalf:   return "customGateVHalf"
        case .customGateSlope:   return "customGateSlope"
        case .customGateTauMin:  return "customGateTauMin"
        case .customGateTauMax:  return "customGateTauMax"
        case .customGateVPeak:   return "customGateVPeak"
        case .customGateTauWidth:return "customGateTauWidth"
        case .skHalfActivation:  return "skHalfActivation"
        case .skHillCoeff:       return "skHillCoeff"
        case .skTauActivation:   return "skTauActivation"
        case .bkVHalfAtRef:      return "bkVHalfAtRef"
        case .bkCaShift:         return "bkCaShift"
        case .bkSlopeFactor:     return "bkSlopeFactor"
        case .bkTauMin:          return "bkTauMin"
        case .bkTauMax:          return "bkTauMax"
        }
    }

    var docCI:  Int { if case .compartmentCm(let ci) = self { return ci }
                      if case .channelGMax(let ci, _) = self { return ci }
                      if case .channelReversal(let ci, _) = self { return ci }
                      if case .customGateVHalf(let ci, _, _) = self { return ci }
                      if case .customGateSlope(let ci, _, _) = self { return ci }
                      if case .customGateTauMin(let ci, _, _) = self { return ci }
                      if case .customGateTauMax(let ci, _, _) = self { return ci }
                      if case .customGateVPeak(let ci, _, _) = self { return ci }
                      if case .customGateTauWidth(let ci, _, _) = self { return ci }
                      if case .skHalfActivation(let ci, _) = self { return ci }
                      if case .skHillCoeff(let ci, _) = self { return ci }
                      if case .skTauActivation(let ci, _) = self { return ci }
                      if case .bkVHalfAtRef(let ci, _) = self { return ci }
                      if case .bkCaShift(let ci, _) = self { return ci }
                      if case .bkSlopeFactor(let ci, _) = self { return ci }
                      if case .bkTauMin(let ci, _) = self { return ci }
                      if case .bkTauMax(let ci, _) = self { return ci }
                      return 0 }

    var docCHI: Int { if case .channelGMax(_, let chi) = self { return chi }
                      if case .channelReversal(_, let chi) = self { return chi }
                      if case .customGateVHalf(_, let chi, _) = self { return chi }
                      if case .customGateSlope(_, let chi, _) = self { return chi }
                      if case .customGateTauMin(_, let chi, _) = self { return chi }
                      if case .customGateTauMax(_, let chi, _) = self { return chi }
                      if case .customGateVPeak(_, let chi, _) = self { return chi }
                      if case .customGateTauWidth(_, let chi, _) = self { return chi }
                      if case .skHalfActivation(_, let chi) = self { return chi }
                      if case .skHillCoeff(_, let chi) = self { return chi }
                      if case .skTauActivation(_, let chi) = self { return chi }
                      if case .bkVHalfAtRef(_, let chi) = self { return chi }
                      if case .bkCaShift(_, let chi) = self { return chi }
                      if case .bkSlopeFactor(_, let chi) = self { return chi }
                      if case .bkTauMin(_, let chi) = self { return chi }
                      if case .bkTauMax(_, let chi) = self { return chi }
                      return -1 }

    var docGI:  Int { if case .customGateVHalf(_, _, let gi) = self { return gi }
                      if case .customGateSlope(_, _, let gi) = self { return gi }
                      if case .customGateTauMin(_, _, let gi) = self { return gi }
                      if case .customGateTauMax(_, _, let gi) = self { return gi }
                      if case .customGateVPeak(_, _, let gi) = self { return gi }
                      if case .customGateTauWidth(_, _, let gi) = self { return gi }
                      return -1 }

    static func from(kind: String, ci: Int, chi: Int, gi: Int) -> ParamTarget? {
        switch kind {
        case "compartmentCm":     return .compartmentCm(ci: ci)
        case "channelGMax":       return .channelGMax(ci: ci, chi: chi)
        case "channelReversal":   return .channelReversal(ci: ci, chi: chi)
        case "customGateVHalf":   return .customGateVHalf(ci: ci, chi: chi, gi: gi)
        case "customGateSlope":   return .customGateSlope(ci: ci, chi: chi, gi: gi)
        case "customGateTauMin":  return .customGateTauMin(ci: ci, chi: chi, gi: gi)
        case "customGateTauMax":  return .customGateTauMax(ci: ci, chi: chi, gi: gi)
        case "customGateVPeak":   return .customGateVPeak(ci: ci, chi: chi, gi: gi)
        case "customGateTauWidth":return .customGateTauWidth(ci: ci, chi: chi, gi: gi)
        case "skHalfActivation":  return .skHalfActivation(ci: ci, chi: chi)
        case "skHillCoeff":       return .skHillCoeff(ci: ci, chi: chi)
        case "skTauActivation":   return .skTauActivation(ci: ci, chi: chi)
        case "bkVHalfAtRef":      return .bkVHalfAtRef(ci: ci, chi: chi)
        case "bkCaShift":         return .bkCaShift(ci: ci, chi: chi)
        case "bkSlopeFactor":     return .bkSlopeFactor(ci: ci, chi: chi)
        case "bkTauMin":          return .bkTauMin(ci: ci, chi: chi)
        case "bkTauMax":          return .bkTauMax(ci: ci, chi: chi)
        default:                  return nil
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

// MARK: - Apply

/// Write a single parameter value back into the network model.
/// Network is a class (reference type) — no inout needed.
func applyOptimParam(_ param: OptimParam, value: Double,
                     neuronID: UUID, network: Network) {
    network.updateNeuron(id: neuronID) { n in
        switch param.target {

        case .compartmentCm(let ci):
            n.compartments[ci].capacitance = value

        case .channelGMax(let ci, let chi):
            n.compartments[ci].channels[chi].gMax = value

        case .channelReversal(let ci, let chi):
            n.compartments[ci].channels[chi].reversal = value

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
