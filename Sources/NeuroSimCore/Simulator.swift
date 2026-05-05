//
//  Simulator.swift
//  NeuroSimCore
//
//  Drives the integrator forward in time and dispatches discrete spike events
//  onto outgoing synapses. Designed to be cheap to step from a background
//  thread — the UI can pull the latest state at its own cadence.
//

import Foundation

/// One recorded sample of (time, V_per_neuron). Synaptic state is preserved
/// in the simulator's `state` vector for those who need it; the trace stays
/// lean so a 60 fps GUI plot doesn't drown.
public struct SimulationSample {
    public let time: Double
    public let voltages: [UUID: Double]
}

public final class Simulator {
    public let network: Network

    /// Integration step (ms). With Rush-Larsen or RK45 you can safely use
    /// larger values (up to ~0.5 ms and ~1 ms respectively).
    public var dt: Double

    /// Numerical method used to advance the state vector.
    public var method: IntegrationMethod = .rushLarsen

    /// Threshold (mV) used for upward-crossing spike detection.
    public var spikeThreshold: Double = 0.0

    public private(set) var time: Double = 0
    public private(set) var state: [Double]

    /// V at the end of the previous fully-completed step — used to detect
    /// upward threshold crossings.
    private var prevVoltages: [UUID: Double] = [:]

    public init(network: Network, dt: Double = 0.01) {
        self.network = network
        self.dt = dt
        self.state = network.initialState()
        for n in network.neurons {
            if let i = network.voltageIndex(of: n.id) {
                prevVoltages[n.id] = state[i]
            }
        }
    }

    /// Reset to the resting state (V = v0, gates at steady state, synapses off).
    public func reset(restingVoltage v0: Double = -65.0) {
        time = 0
        state = network.initialState(restingVoltage: v0)
        prevVoltages.removeAll(keepingCapacity: true)
        for n in network.neurons {
            if let i = network.voltageIndex(of: n.id) {
                prevVoltages[n.id] = state[i]
            }
        }
        for stim in network.stimuli.values { stim.reset() }
    }

    /// Advance by one `dt` using the chosen integration method, then
    /// dispatch any spikes detected at the new time.
    public func step() {
        switch method {
        case .euler:
            ForwardEuler.step(provider: network, state: &state, time: time, dt: dt)
        case .rk2:
            RK2.step(provider: network, state: &state, time: time, dt: dt)
        case .rk4:
            RK4.step(provider: network, state: &state, time: time, dt: dt)
        case .rushLarsen:
            RushLarsen.step(network: network, state: &state, time: time, dt: dt)
        case .rk45:
            RK45.step(provider: network, state: &state, time: time, dt: dt)
        }
        time += dt
        dispatchSpikes()
    }

    /// Convenience: integrate for `duration` ms, calling `onSample` once per
    /// completed step. Use a downsampling counter in `onSample` to keep
    /// memory usage bounded for long runs.
    public func run(duration: Double,
                    onSample: ((SimulationSample) -> Void)? = nil) {
        let nSteps = Int((duration / dt).rounded())
        for _ in 0..<nSteps {
            step()
            if let cb = onSample { cb(currentSample()) }
        }
    }

    public func currentSample() -> SimulationSample {
        var v: [UUID: Double] = [:]
        v.reserveCapacity(network.neurons.count)
        for n in network.neurons {
            if let i = network.voltageIndex(of: n.id) {
                v[n.id] = state[i]
            }
        }
        return SimulationSample(time: time, voltages: v)
    }

    // MARK: - Spike dispatch

    /// After each step, look for upward V threshold crossings and apply the
    /// corresponding synaptic state jumps. We do this *outside* the RK4 inner
    /// loop on purpose — discrete events shouldn't happen mid-substep.
    private func dispatchSpikes() {
        for n in network.neurons {
            guard let vIdx = network.voltageIndex(of: n.id) else { continue }
            let vNow = state[vIdx]
            let vPrev = prevVoltages[n.id] ?? vNow
            if vPrev < spikeThreshold && vNow >= spikeThreshold {
                for syn in network.outgoingSynapses(of: n.id) {
                    if let off = network.stateOffset(ofSynapse: syn.id) {
                        syn.applySpike(into: &state, offset: off)
                    }
                }
            }
            prevVoltages[n.id] = vNow
        }
    }
}
