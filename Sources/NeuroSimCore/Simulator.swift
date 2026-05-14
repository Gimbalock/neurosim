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

    /// Current metabolic/ionic state for each neuron that has energy tracking enabled.
    /// Populated lazily on first step; read by the ViewModel to build energy traces.
    public private(set) var energyStates: [UUID: EnergyState] = [:]

    /// V at the end of the previous fully-completed step — used to detect
    /// upward threshold crossings.
    private var prevVoltages: [UUID: Double] = [:]

    // Pre-allocated scratch buffers — sized once to stateCount, then reused
    // every step so the integrators never heap-allocate during simulation.
    private var buf1: [Double] = []
    private var buf2: [Double] = []
    private var buf3: [Double] = []
    private var buf4: [Double] = []
    private var buf5: [Double] = []

    public init(network: Network, dt: Double = 0.01) {
        self.network = network
        self.dt = dt
        self.state = network.initialState()
        for n in network.neurons {
            if let i = network.voltageIndex(of: n.id) {
                prevVoltages[n.id] = state[i]
            }
        }
        allocateBuffers()
    }

    private func allocateBuffers() {
        let n = network.stateCount
        guard buf1.count != n else { return }
        let z = [Double](repeating: 0, count: n)
        buf1 = z; buf2 = z; buf3 = z; buf4 = z; buf5 = z
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
        for noise in network.synapticNoises.values { noise.reset() }
        // Re-initialise energy states and restore default channel reversals.
        energyStates.removeAll(keepingCapacity: true)
        for n in network.neurons where n.energyParams.enabled {
            let es = EnergyState(params: n.energyParams)
            energyStates[n.id] = es
            applyNernstReversals(neuron: n, eNa: es.eNa, eK: es.eK)
        }
    }

    /// Advance by one `dt` using the chosen integration method, then
    /// dispatch any spikes detected at the new time.
    public func step() {
        network.simulationDt = dt
        allocateBuffers()
        switch method {
        case .euler:
            ForwardEuler.step(provider: network, state: &state, time: time, dt: dt, k: &buf1)
        case .rk2:
            RK2.step(provider: network, state: &state, time: time, dt: dt,
                     k1: &buf1, k2: &buf2, tmp: &buf3)
        case .rk4:
            RK4.step(provider: network, state: &state, time: time, dt: dt,
                     k1: &buf1, k2: &buf2, k3: &buf3, k4: &buf4, tmp: &buf5)
        case .rushLarsen:
            RushLarsen.step(network: network, state: &state, time: time, dt: dt,
                            deriv: &buf1, deriv2: &buf2)
        case .rk45:
            RK45.step(provider: network, state: &state, time: time, dt: dt)
        }
        time += dt
        dispatchSpikes()
        stepEnergy()
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

    // Simulator is sent to background Tasks for the simulation loop.
    // Safety: the main actor only accesses the simulator when isRunning = false
    // (via rebuildSimulator / reset) or after a frame completes via MainActor.run.

    /// After each step, look for upward V threshold crossings and apply the
    /// corresponding synaptic state jumps. We do this *outside* the RK4 inner
    /// loop on purpose — discrete events shouldn't happen mid-substep.
    private func dispatchSpikes() {
        for n in network.neurons {
            guard let vIdx = network.voltageIndex(of: n.id) else { continue }
            let vNow = state[vIdx]
            let vPrev = prevVoltages[n.id] ?? vNow
            if vPrev < spikeThreshold && vNow >= spikeThreshold {
                // Pre-synaptic event: notify outgoing synapses (conductance jump).
                network.visitOutgoingSynapses(of: n.id) { syn in
                    if let off = network.stateOffset(ofSynapse: syn.id) {
                        syn.applySpike(into: &state, offset: off)
                    }
                }
                // Post-synaptic event: notify incoming synapses (STDP LTP update).
                network.visitIncomingSynapses(of: n.id) { syn in
                    if let off = network.stateOffset(ofSynapse: syn.id) {
                        syn.applyPostSpike(into: &state, offset: off)
                    }
                }
            }
            prevVoltages[n.id] = vNow
        }
    }

    // MARK: - Energy engine

    /// Called once per step (after spike dispatch). Updates metabolic state
    /// for every neuron with energy tracking enabled, then writes the new
    /// Nernst potentials back into the matching channel reversals so the
    /// *next* HH step uses the updated E_Na / E_K.
    private func stepEnergy() {
        for neuron in network.neurons {
            let params = neuron.energyParams
            guard params.enabled else { continue }

            // Find soma compartment and its offset in the full state vector.
            guard let somaComp = neuron.compartments.first(where: { $0.id == neuron.somaCompartmentID }),
                  let vIdx = network.voltageIndex(ofCompartment: somaComp.id) else { continue }

            let sliceEnd = vIdx + somaComp.stateCount
            guard sliceEnd <= state.count else { continue }
            let somaSlice = state[vIdx..<sliceEnd]

            // Lazy init (first step).
            if energyStates[neuron.id] == nil {
                energyStates[neuron.id] = EnergyState(params: params)
            }
            let es = energyStates[neuron.id]!

            let result = EnergyEngine.step(
                energyState: es,
                params: params,
                somaCompartment: somaComp,
                somaState: somaSlice,
                dt: dt)

            energyStates[neuron.id] = result.state
            applyNernstReversals(neuron: neuron, eNa: result.eNa, eK: result.eK)
        }
    }

    /// Update the reversal potential of every Na and K channel in the neuron's soma.
    private func applyNernstReversals(neuron: HHNeuron, eNa: Double, eK: Double) {
        guard let somaComp = neuron.compartments.first(where: { $0.id == neuron.somaCompartmentID }) else { return }
        for ch in somaComp.channels {
            switch ch.species?.symbol {
            case "Na": ch.reversal = eNa
            case "K":  ch.reversal = eK
            default: break
            }
        }
    }
}

extension Simulator: @unchecked Sendable {}
