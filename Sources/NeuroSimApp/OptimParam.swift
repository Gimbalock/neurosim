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

struct OptimParam: Identifiable {
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
            guard var cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].vHalf = value
            n.compartments[ci].channels[chi] = cc

        case .customGateSlope(let ci, let chi, let gi):
            guard var cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].slope = value
            n.compartments[ci].channels[chi] = cc

        case .customGateTauMin(let ci, let chi, let gi):
            guard var cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].tauMin = value
            n.compartments[ci].channels[chi] = cc

        case .customGateTauMax(let ci, let chi, let gi):
            guard var cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].tauMax = value
            n.compartments[ci].channels[chi] = cc

        case .customGateVPeak(let ci, let chi, let gi):
            guard var cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].vPeak = value
            n.compartments[ci].channels[chi] = cc

        case .customGateTauWidth(let ci, let chi, let gi):
            guard var cc = n.compartments[ci].channels[chi] as? CustomChannel else { return }
            cc.definition.gates[gi].tauWidth = value
            n.compartments[ci].channels[chi] = cc

        case .skHalfActivation(let ci, let chi):
            guard var sk = n.compartments[ci].channels[chi] as? SKChannel else { return }
            sk.halfActivation = value
            n.compartments[ci].channels[chi] = sk

        case .skHillCoeff(let ci, let chi):
            guard var sk = n.compartments[ci].channels[chi] as? SKChannel else { return }
            sk.hillCoefficient = value
            n.compartments[ci].channels[chi] = sk

        case .skTauActivation(let ci, let chi):
            guard var sk = n.compartments[ci].channels[chi] as? SKChannel else { return }
            sk.tauActivation = value
            n.compartments[ci].channels[chi] = sk

        case .bkVHalfAtRef(let ci, let chi):
            guard var bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.vHalfAtRef = value
            n.compartments[ci].channels[chi] = bk

        case .bkCaShift(let ci, let chi):
            guard var bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.caShift = value
            n.compartments[ci].channels[chi] = bk

        case .bkSlopeFactor(let ci, let chi):
            guard var bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.slopeFactor = value
            n.compartments[ci].channels[chi] = bk

        case .bkTauMin(let ci, let chi):
            guard var bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.tauMin = value
            n.compartments[ci].channels[chi] = bk

        case .bkTauMax(let ci, let chi):
            guard var bk = n.compartments[ci].channels[chi] as? BKChannel else { return }
            bk.tauMax = value
            n.compartments[ci].channels[chi] = bk
        }
    }
}
