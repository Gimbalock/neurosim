//
//  Integrator.swift
//  NeuroSimCore
//
//  Numerical integrators for ODE systems. RK4 is the default — accurate enough
//  for HH dynamics at dt = 0.01 ms while remaining cheap. Forward Euler is
//  retained for diagnostic / convergence comparisons.
//

import Foundation

/// Anything that can compute its own time-derivatives.
/// Class-bound (`AnyObject`) because the only conforming type — `Network` —
/// owns mutable state and is naturally a class; this also lets the integrator
/// avoid copying it through inout boundaries.
public protocol DerivativeProvider: AnyObject {
    /// Total length of the state vector.
    var stateCount: Int { get }

    /// Writes dy/dt into `output` for the entire state vector.
    /// `output` is guaranteed to have `stateCount` slots already.
    func computeDerivatives(state: [Double], time: Double, into output: inout [Double])
}

/// Classical 4th-order Runge-Kutta. Pure function — no hidden state, easy to
/// reason about and trivial to unit-test against analytic solutions.
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

        provider.computeDerivatives(state: state, time: time, into: &k1)

        for i in 0..<n { tmp[i] = state[i] + 0.5 * dt * k1[i] }
        provider.computeDerivatives(state: tmp, time: time + 0.5 * dt, into: &k2)

        for i in 0..<n { tmp[i] = state[i] + 0.5 * dt * k2[i] }
        provider.computeDerivatives(state: tmp, time: time + 0.5 * dt, into: &k3)

        for i in 0..<n { tmp[i] = state[i] + dt * k3[i] }
        provider.computeDerivatives(state: tmp, time: time + dt, into: &k4)

        let f = dt / 6.0
        for i in 0..<n {
            state[i] += f * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i])
        }
    }
}

/// Forward Euler — kept around for sanity checks (it diverges at dt > ~0.05 ms
/// for HH, which is itself a useful regression test).
public enum ForwardEuler {
    public static func step(provider: DerivativeProvider,
                            state: inout [Double],
                            time: Double,
                            dt: Double) {
        var k = [Double](repeating: 0, count: state.count)
        provider.computeDerivatives(state: state, time: time, into: &k)
        for i in 0..<state.count { state[i] += dt * k[i] }
    }
}
