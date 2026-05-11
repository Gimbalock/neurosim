//
//  Integrator.swift
//  NeuroSimCore
//
//  Numerical integrators for ODE systems.
//
//  Available methods
//  ─────────────────
//  ForwardEuler  — O(dt¹), 1 eval/step.  Kept for diagnostics only.
//  RK2 (Heun)   — O(dt²), 2 eval/step.  Decent for quick runs.
//  RK4           — O(dt⁴), 4 eval/step.  Former default; good to ~0.05 ms.
//  RushLarsen    — O(dt²) for V, EXACT for HH gates (analytical).
//                  2 eval/step.  Stable to ~0.5 ms.  Standard in NEURON/Brian.
//  RK45          — Dormand-Prince adaptive. 6 eval/sub-step with error
//                  control; dt becomes the output interval, sub-step is
//                  chosen automatically.
//

import Foundation

// MARK: - Derivative provider (generic interface)

/// Anything that can compute its own time-derivatives.
public protocol DerivativeProvider: AnyObject {
    var stateCount: Int { get }
    func computeDerivatives(state: [Double], time: Double, into output: inout [Double])
}

// MARK: - Forward Euler

public enum ForwardEuler {
    public static func step(provider: DerivativeProvider,
                            state: inout [Double],
                            time: Double,
                            dt: Double) {
        var k = [Double](repeating: 0, count: state.count)
        step(provider: provider, state: &state, time: time, dt: dt, k: &k)
    }

    static func step(provider: DerivativeProvider,
                     state: inout [Double],
                     time: Double,
                     dt: Double,
                     k: inout [Double]) {
        provider.computeDerivatives(state: state, time: time, into: &k)
        for i in 0..<state.count { state[i] += dt * k[i] }
    }
}

// MARK: - RK2 (Heun's predictor-corrector)

public enum RK2 {
    public static func step(provider: DerivativeProvider,
                            state: inout [Double],
                            time: Double,
                            dt: Double) {
        let n = state.count
        var k1 = [Double](repeating: 0, count: n)
        var k2 = [Double](repeating: 0, count: n)
        var tmp = [Double](repeating: 0, count: n)
        step(provider: provider, state: &state, time: time, dt: dt, k1: &k1, k2: &k2, tmp: &tmp)
    }

    static func step(provider: DerivativeProvider,
                     state: inout [Double],
                     time: Double,
                     dt: Double,
                     k1: inout [Double],
                     k2: inout [Double],
                     tmp: inout [Double]) {
        let n = state.count
        provider.computeDerivatives(state: state, time: time, into: &k1)
        for i in 0..<n { tmp[i] = state[i] + dt * k1[i] }
        provider.computeDerivatives(state: tmp, time: time + dt, into: &k2)
        for i in 0..<n { state[i] += dt * 0.5 * (k1[i] + k2[i]) }
    }
}

// MARK: - RK4 (classical 4th-order Runge-Kutta)

public enum RK4 {
    public static func step(provider: DerivativeProvider,
                            state: inout [Double],
                            time: Double,
                            dt: Double) {
        let n = state.count
        var k1 = [Double](repeating: 0, count: n)
        var k2 = [Double](repeating: 0, count: n)
        var k3 = [Double](repeating: 0, count: n)
        var k4 = [Double](repeating: 0, count: n)
        var tmp = [Double](repeating: 0, count: n)
        step(provider: provider, state: &state, time: time, dt: dt,
             k1: &k1, k2: &k2, k3: &k3, k4: &k4, tmp: &tmp)
    }

    static func step(provider: DerivativeProvider,
                     state: inout [Double],
                     time: Double,
                     dt: Double,
                     k1: inout [Double],
                     k2: inout [Double],
                     k3: inout [Double],
                     k4: inout [Double],
                     tmp: inout [Double]) {
        let n = state.count
        provider.computeDerivatives(state: state, time: time, into: &k1)
        for i in 0..<n { tmp[i] = state[i] + 0.5 * dt * k1[i] }
        provider.computeDerivatives(state: tmp, time: time + 0.5 * dt, into: &k2)
        for i in 0..<n { tmp[i] = state[i] + 0.5 * dt * k2[i] }
        provider.computeDerivatives(state: tmp, time: time + 0.5 * dt, into: &k3)
        for i in 0..<n { tmp[i] = state[i] + dt * k3[i] }
        provider.computeDerivatives(state: tmp, time: time + dt, into: &k4)
        let f = dt / 6.0
        for i in 0..<n { state[i] += f * (k1[i] + 2*k2[i] + 2*k3[i] + k4[i]) }
    }
}

// MARK: - Rush-Larsen

/// Semi-implicit method tailored for Hodgkin-Huxley models.
///
/// Gate variables of the form  dx/dt = (x∞(V) - x) / τ(V)  have an exact
/// analytical solution when V is held constant over the step:
///
///     x(t+dt) = x∞ + (x(t) − x∞) · exp(−dt / τ)
///
/// This update is unconditionally stable for the gates, allowing dt up to
/// ~0.5 ms without oscillation (vs ~0.05 ms for RK4).
///
/// Voltage is updated semi-implicitly: gates are advanced first, then V is
/// integrated with Euler using the NEW gate values — this one extra evaluation
/// improves accuracy at no additional derivative cost.
///
/// Non-HHGated channels and synaptic state fall back to Euler.
///
/// Requires `Network` (not just `DerivativeProvider`) to walk the state
/// layout and access per-gate x∞ / τ.
public enum RushLarsen {
    public static func step(network: Network,
                            state: inout [Double],
                            time: Double,
                            dt: Double) {
        let n = state.count
        var deriv  = [Double](repeating: 0, count: n)
        var deriv2 = [Double](repeating: 0, count: n)
        step(network: network, state: &state, time: time, dt: dt, deriv: &deriv, deriv2: &deriv2)
    }

    static func step(network: Network,
                     state: inout [Double],
                     time: Double,
                     dt: Double,
                     deriv: inout [Double],
                     deriv2: inout [Double]) {
        network.computeDerivatives(state: state, time: time, into: &deriv)

        // Phase 1 — gate variables: exact exponential update.
        for neuron in network.neurons {
            for comp in neuron.compartments {
                guard let vIdx = network.voltageIndex(ofCompartment: comp.id)
                else { continue }
                let v = state[vIdx]
                var slot = vIdx + 1
                for ch in comp.channels {
                    if let gated = ch as? HHGated {
                        for gi in 0..<ch.stateCount {
                            let xInf = gated.resolvedGateInf(gi, voltage: v)
                            let tau  = gated.resolvedGateTau(gi, voltage: v)
                            let x    = state[slot + gi]
                            state[slot + gi] = xInf + (x - xInf) * exp(-dt / tau)
                        }
                    } else {
                        for gi in 0..<ch.stateCount {
                            state[slot + gi] += dt * deriv[slot + gi]
                        }
                    }
                    slot += ch.stateCount
                }
            }
        }

        // Phase 2 — voltage: re-evaluate with updated gates, Euler for V.
        network.computeDerivatives(state: state, time: time + dt, into: &deriv2)
        for neuron in network.neurons {
            for comp in neuron.compartments {
                guard let vIdx = network.voltageIndex(ofCompartment: comp.id)
                else { continue }
                state[vIdx] += dt * deriv2[vIdx]
            }
        }

        // Phase 2.5 — concentration dynamics: Euler using deriv2 (slow variables).
        for neuron in network.neurons {
            for comp in neuron.compartments {
                guard !comp.concentrationDynamics.isEmpty,
                      let vIdx = network.voltageIndex(ofCompartment: comp.id)
                else { continue }
                let totalGates = comp.channels.reduce(0) { $0 + $1.stateCount }
                for i in comp.concentrationDynamics.indices {
                    let idx = vIdx + 1 + totalGates + i
                    state[idx] += dt * deriv2[idx]
                }
            }
        }

        // Phase 3 — synaptic state: Euler (RL trick doesn't apply here).
        for syn in network.synapses {
            guard let off = network.stateOffset(ofSynapse: syn.id) else { continue }
            for k in 0..<syn.stateCount { state[off + k] += dt * deriv[off + k] }
        }
    }
}

// MARK: - RK45 (Dormand-Prince adaptive)

/// 4th/5th-order Runge-Kutta with automatic step-size control.
///
/// Uses the Dormand-Prince tableau. `dt` is the *output interval* — the
/// integrator advances by exactly `dt` using as many internal sub-steps as
/// needed to keep the local truncation error below `tolerance`.
///
/// toleranceMixed norm:  max_i( |err_i| / max(atol, rtol · |y_i|) )
/// Default atol = 1.0 (mV scale), rtol = 1e-3.
public enum RK45 {

    // Dormand-Prince Butcher tableau
    private static let a21 = 1.0/5.0
    private static let a31 = 3.0/40.0,    a32 = 9.0/40.0
    private static let a41 = 44.0/45.0,   a42 = -56.0/15.0,    a43 = 32.0/9.0
    private static let a51 = 19372.0/6561.0, a52 = -25360.0/2187.0,
                       a53 = 64448.0/6561.0, a54 = -212.0/729.0
    private static let a61 = 9017.0/3168.0,  a62 = -355.0/33.0,
                       a63 = 46732.0/5247.0, a64 = 49.0/176.0, a65 = -5103.0/18656.0

    // 5th-order weights
    private static let e1 = 35.0/384.0, e3 = 500.0/1113.0,
                       e4 = 125.0/192.0, e5 = -2187.0/6784.0, e6 = 11.0/84.0

    // Error coefficients (difference between 4th and 5th order)
    private static let er1 =  71.0/57600.0,  er3 = -71.0/16695.0,
                       er4 =  71.0/1920.0,   er5 = -17253.0/339200.0,
                       er6 =  22.0/525.0,    er7 = -1.0/40.0

    // Tolerances
    private static let atol = 1.0      // mV-scale absolute tolerance
    private static let rtol = 1e-3     // relative tolerance
    private static let hMin = 1e-6     // minimum sub-step (ms)
    private static let hMax = 1.0      // maximum sub-step (ms)

    public static func step(provider: DerivativeProvider,
                            state: inout [Double],
                            time: Double,
                            dt: Double) {
        let n = state.count
        var y = state
        var t = time
        var remaining = dt
        var h = min(dt, hMax)   // initial sub-step guess

        var k1 = [Double](repeating: 0, count: n)
        var k2 = [Double](repeating: 0, count: n)
        var k3 = [Double](repeating: 0, count: n)
        var k4 = [Double](repeating: 0, count: n)
        var k5 = [Double](repeating: 0, count: n)
        var k6 = [Double](repeating: 0, count: n)
        var k7 = [Double](repeating: 0, count: n)
        var tmp = [Double](repeating: 0, count: n)

        provider.computeDerivatives(state: y, time: t, into: &k1)

        while remaining > 1e-12 {
            h = min(h, remaining)

            // — Stage evaluations —
            for i in 0..<n { tmp[i] = y[i] + h * a21*k1[i] }
            provider.computeDerivatives(state: tmp, time: t + h/5, into: &k2)

            for i in 0..<n { tmp[i] = y[i] + h*(a31*k1[i] + a32*k2[i]) }
            provider.computeDerivatives(state: tmp, time: t + 3*h/10, into: &k3)

            for i in 0..<n { tmp[i] = y[i] + h*(a41*k1[i] + a42*k2[i] + a43*k3[i]) }
            provider.computeDerivatives(state: tmp, time: t + 4*h/5, into: &k4)

            for i in 0..<n { tmp[i] = y[i] + h*(a51*k1[i] + a52*k2[i] + a53*k3[i] + a54*k4[i]) }
            provider.computeDerivatives(state: tmp, time: t + 8*h/9, into: &k5)

            for i in 0..<n { tmp[i] = y[i] + h*(a61*k1[i] + a62*k2[i] + a63*k3[i] + a64*k4[i] + a65*k5[i]) }
            provider.computeDerivatives(state: tmp, time: t + h, into: &k6)

            // — 5th-order solution candidate —
            var yNew = [Double](repeating: 0, count: n)
            for i in 0..<n {
                yNew[i] = y[i] + h*(e1*k1[i] + e3*k3[i] + e4*k4[i] + e5*k5[i] + e6*k6[i])
            }

            // — Error estimation (difference 5th − 4th order) —
            provider.computeDerivatives(state: yNew, time: t + h, into: &k7)
            var errNorm = 0.0
            for i in 0..<n {
                let err = h * (er1*k1[i] + er3*k3[i] + er4*k4[i] + er5*k5[i] + er6*k6[i] + er7*k7[i])
                let sc  = atol + rtol * max(abs(y[i]), abs(yNew[i]))
                errNorm = max(errNorm, abs(err) / sc)
            }

            if errNorm <= 1.0 {
                // Accept step; FSAL — reuse k7 as k1 of next sub-step.
                y   = yNew
                t  += h
                remaining -= h
                k1  = k7
                // Increase h for next sub-step (capped).
                let factor = errNorm > 1e-10 ? min(5.0, 0.9 * pow(errNorm, -0.2)) : 5.0
                h = min(h * factor, min(hMax, remaining))
            } else {
                // Reject: shrink h.
                let factor = max(0.1, 0.9 * pow(errNorm, -0.25))
                h = max(h * factor, hMin)
                if h <= hMin {
                    // Forced accept at minimum step to avoid infinite loop.
                    y  = yNew
                    t += hMin
                    remaining -= hMin
                    k1 = k7
                    h = min(hMin * 2, remaining)
                }
            }
        }
        state = y
    }
}
