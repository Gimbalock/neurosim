//
//  BifurcationEngine.swift
//  NeuroSimApp
//
//  Sweeps a single parameter, runs the simulation at each value,
//  discards the transient, then collects local maxima and minima of V.
//

import Foundation
import NeuroSimCore

// MARK: - Parameter choice

enum BifSweepParam: Equatable {
    case iInj
    case channelGMax(compartmentIdx: Int, channelIdx: Int)

    func label(for neuron: HHNeuron) -> String {
        switch self {
        case .iInj: return "I inj (µA/cm²)"
        case .channelGMax(let ci, let chi):
            guard ci < neuron.compartments.count,
                  chi < neuron.compartments[ci].channels.count else { return "gMax" }
            return "\(neuron.compartments[ci].channels[chi].name) gMax (mS/cm²)"
        }
    }

    var unit: String {
        switch self { case .iInj: return "µA/cm²"; case .channelGMax: return "mS/cm²" }
    }
}

// MARK: - Output

struct BifPoint: Identifiable {
    let id    = UUID()
    let param: Double    // swept parameter value
    let v:     Double    // mV
    let isMax: Bool
}

// MARK: - Config

struct BifurcationConfig: Equatable {
    var paramMin:   Double = 0.0
    var paramMax:   Double = 20.0
    var nSteps:     Int    = 80
    var tTransient: Double = 500.0   // ms — discard
    var tCollect:   Double = 500.0   // ms — collect extrema
    var dt:         Double = 0.025   // ms

    var paramValues: [Double] {
        guard nSteps > 1 else { return [(paramMin + paramMax) / 2] }
        return (0..<nSteps).map { i in
            paramMin + Double(i) * (paramMax - paramMin) / Double(nSteps - 1)
        }
    }
}

// MARK: - Engine

struct BifurcationEngine {
    let network:    Network
    let neuronID:   UUID
    let sweepParam: BifSweepParam
    let config:     BifurcationConfig

    /// Run one parameter value and return its local extrema.
    func runStep(paramValue: Double) -> [BifPoint] {
        guard let neuron = network.neurons.first(where: { $0.id == neuronID }) else { return [] }

        let restore = applyParam(paramValue, to: neuron)
        defer { restore() }

        let sim = Simulator(network: network, dt: config.dt)
        sim.method = .rushLarsen
        sim.reset()

        // Discard transient
        sim.run(duration: config.tTransient)

        // Sample V at ~0.1 ms resolution during collection window
        let every = max(1, Int(0.1 / config.dt))
        var samples: [Double] = []
        var k = 0
        sim.run(duration: config.tCollect) { sample in
            k += 1
            guard k % every == 0, let v = sample.voltages[neuronID] else { return }
            samples.append(v)
        }
        guard !samples.isEmpty else { return [] }

        let vMin = samples.min()!
        let vMax = samples.max()!

        // Resting / constant state — report equilibrium as a single point
        if vMax - vMin < 3.0 {
            let eq = samples.reduce(0, +) / Double(samples.count)
            return [BifPoint(param: paramValue, v: eq, isMax: true)]
        }

        // Local extrema
        var pts: [BifPoint] = []
        for i in 1..<(samples.count - 1) {
            let p = samples[i-1], v = samples[i], n = samples[i+1]
            if v > p && v > n { pts.append(BifPoint(param: paramValue, v: v, isMax: true)) }
            else if v < p && v < n { pts.append(BifPoint(param: paramValue, v: v, isMax: false)) }
        }
        return pts
    }

    // MARK: - Apply / restore

    private func applyParam(_ value: Double, to neuron: HHNeuron) -> () -> Void {
        switch sweepParam {
        case .iInj:
            let somaID = neuron.somaCompartmentID
            let old    = network.stimuli[somaID]
            network.stimuli[somaID] = ConstantStimulus(amplitude: value)
            return { [weak network] in
                if let old { network?.stimuli[somaID] = old }
                else { network?.stimuli.removeValue(forKey: somaID) }
            }
        case .channelGMax(let ci, let chi):
            guard ci < neuron.compartments.count,
                  chi < neuron.compartments[ci].channels.count else { return {} }
            let ch  = neuron.compartments[ci].channels[chi]
            let old = ch.gMax
            ch.gMax = value
            return { ch.gMax = old }
        }
    }
}
