//
//  NetworkAutomation.swift
//  NeuroSimApp
//
//  Pure logic — no UI, no ViewModel dependency.
//  Provides bulk neuron duplication and random/structured connectivity.
//

import Foundation
import NeuroSimCore

// MARK: - Arrangement

public enum NeuronArrangement: String, CaseIterable, Identifiable {
    case line = "Ligne"
    case grid = "Grille"
    case ring = "Anneau"
    public var id: String { rawValue }
    public var systemImage: String {
        switch self {
        case .line: return "line.horizontal.3"
        case .grid: return "grid"
        case .ring: return "circle.dotted"
        }
    }
}

// MARK: - ConnectParams

public struct ConnectParams {
    public var probability: Double = 0.30      // 0-1
    public var eiRatio: Double     = 0.70      // fraction excitatory
    // Excitatory synapse (AMPA-like)
    public var exGMax: Double      = 0.30
    public var exReversal: Double  = 0.0
    public var exTauDecay: Double  = 5.0
    public var exSMax: Double      = 1.0
    // Inhibitory synapse (GABA-like)
    public var inhGMax: Double     = 0.30
    public var inhReversal: Double = -75.0
    public var inhTauDecay: Double = 10.0
    public var inhSMax: Double     = 1.0
    public var allowSelf: Bool     = false
    public init() {}
}

// MARK: - NetworkAutomation

public enum NetworkAutomation {

    // MARK: Duplicate

    /// Deep-copy `neuron` `count` times, arranged on the canvas.
    /// Uses ChannelDoc round-trip to copy channels correctly.
    /// Each copy gets a fresh UUID and a computed position.
    /// - Parameter nameOverride: If provided, each copy is named exactly this string (ignores index).
    ///   If nil, copies are named "<baseName> <index+1>" where baseName strips any trailing number.
    /// - Parameter indexOffset: Added to the displayed index (useful when adding to an existing network).
    public static func duplicate(
        neuron: HHNeuron,
        count: Int,
        arrangement: NeuronArrangement,
        spacing: Double,
        originX: Double,
        originY: Double,
        nameOverride: String? = nil,
        indexOffset: Int = 0
    ) -> [HHNeuron] {
        guard count > 0 else { return [] }
        var result: [HHNeuron] = []
        for i in 0..<count {
            let copy = copyNeuron(neuron, index: i, count: count,
                                  arrangement: arrangement, spacing: spacing,
                                  originX: originX, originY: originY,
                                  nameOverride: nameOverride,
                                  indexOffset: indexOffset)
            result.append(copy)
        }
        return result
    }

    // MARK: - Base name helper

    /// Strips a trailing " <digits>" suffix: "PD 3" → "PD", "Neuron" → "Neuron".
    private static func strippedBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #"\s+\d+$"#, options: .regularExpression) {
            return String(trimmed[trimmed.startIndex..<range.lowerBound])
        }
        return trimmed
    }

    // MARK: Random connectivity

    /// Creates random chemical synapses between sources and targets.
    public static func randomConnect(
        sources: [HHNeuron],
        targets: [HHNeuron],
        params: ConnectParams,
        seed: UInt64 = 42
    ) -> [ChemicalSynapse] {
        var rng = SeededRNG(seed: seed)
        var synapses: [ChemicalSynapse] = []
        for src in sources {
            for tgt in targets {
                if !params.allowSelf && src.id == tgt.id { continue }
                guard rng.nextDouble() < params.probability else { continue }
                let isExcitatory = rng.nextDouble() < params.eiRatio
                let soma = tgt.compartments.first { $0.id == tgt.somaCompartmentID }
                let syn = ChemicalSynapse(
                    from: src.id, to: tgt.id,
                    onCompartment: soma?.id,
                    gMax:     isExcitatory ? params.exGMax    : params.inhGMax,
                    reversal: isExcitatory ? params.exReversal : params.inhReversal,
                    tauDecay: isExcitatory ? params.exTauDecay : params.inhTauDecay,
                    sMax:     isExcitatory ? params.exSMax    : params.inhSMax
                )
                synapses.append(syn)
            }
        }
        return synapses
    }

    // MARK: Feedforward

    /// Connects layers[0]→layers[1]→…→layers[n-1].
    public static func feedforwardConnect(
        layers: [[HHNeuron]],
        params: ConnectParams,
        seed: UInt64 = 42
    ) -> [ChemicalSynapse] {
        guard layers.count >= 2 else { return [] }
        var result: [ChemicalSynapse] = []
        var s = seed
        for i in 0..<(layers.count - 1) {
            result += randomConnect(sources: layers[i], targets: layers[i+1], params: params, seed: s)
            s &+= 1
        }
        return result
    }

    // MARK: Feedback

    /// Connects layers[n-1]→layers[n-2]→…→layers[0].
    public static func feedbackConnect(
        layers: [[HHNeuron]],
        params: ConnectParams,
        seed: UInt64 = 42
    ) -> [ChemicalSynapse] {
        guard layers.count >= 2 else { return [] }
        var result: [ChemicalSynapse] = []
        var s = seed
        for i in stride(from: layers.count - 1, through: 1, by: -1) {
            result += randomConnect(sources: layers[i], targets: layers[i-1], params: params, seed: s)
            s &+= 1
        }
        return result
    }

    // MARK: - Private helpers

    private static func copyNeuron(_ template: HHNeuron,
                                   index: Int, count: Int,
                                   arrangement: NeuronArrangement,
                                   spacing: Double,
                                   originX: Double, originY: Double,
                                   nameOverride: String? = nil,
                                   indexOffset: Int = 0) -> HHNeuron {
        // Deep-copy channels via ChannelDoc round-trip
        let newCompartments: [Compartment] = template.compartments.map { comp in
            let channelsCopied: [IonChannel] = comp.channels.map { ch in
                ChannelDoc.from(ch).toChannel()
            }
            let newComp = Compartment(id: UUID(), name: comp.name,
                                      capacitance: comp.capacitance,
                                      diameter: comp.diameter,
                                      length: comp.length,
                                      channels: channelsCopied,
                                      concentrationDynamics: comp.concentrationDynamics)
            newComp.displayAngle = comp.displayAngle
            return newComp
        }
        let newSomaID = newCompartments.first?.id ?? UUID()
        let neuronName: String
        if let override = nameOverride {
            neuronName = override
        } else {
            let base = strippedBaseName(template.name)
            neuronName = "\(base) \(indexOffset + index + 1)"
        }
        let newNeuron = HHNeuron(id: UUID(),
                                 name: neuronName,
                                 compartments: newCompartments,
                                 soma: newSomaID)
        newNeuron.energyParams = template.energyParams
        let (px, py) = position(index: index, count: count, arrangement: arrangement,
                                spacing: spacing, originX: originX, originY: originY)
        newNeuron.positionX = px
        newNeuron.positionY = py
        return newNeuron
    }

    private static func position(index: Int, count: Int,
                                 arrangement: NeuronArrangement,
                                 spacing: Double,
                                 originX: Double, originY: Double) -> (Double, Double) {
        switch arrangement {
        case .line:
            return (originX + Double(index + 1) * spacing, originY)
        case .grid:
            let cols = max(1, Int(ceil(sqrt(Double(count)))))
            let col  = index % cols
            let row  = index / cols
            return (originX + Double(col + 1) * spacing,
                    originY + Double(row)     * spacing)
        case .ring:
            let r = spacing * Double(count) / (2 * .pi)
            let angle = 2 * .pi * Double(index) / Double(count)
            return (originX + r * cos(angle),
                    originY + r * sin(angle))
        }
    }
}

// MARK: - SeededRNG (deterministic for reproducibility)

private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func nextDouble() -> Double {
        Double(next()) / Double(UInt64.max)
    }
}
