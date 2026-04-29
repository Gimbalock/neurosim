//
//  Stimulus.swift
//  NeuroSimCore
//
//  Composable injected-current protocols. Each stimulus is a pure function
//  of time → current density (µA/cm²), making them safe to evaluate from
//  any thread and trivial to combine.
//

import Foundation

/// A current-injection protocol. Conforming types must be deterministic for a
/// given seed — the network re-evaluates them at each integrator sub-step.
public protocol Stimulus: AnyObject {
    /// Injected current density (µA/cm²) at simulation time `t` (ms).
    func current(at t: Double) -> Double

    /// Optional reset hook called at the start of a run.
    func reset()
}

public extension Stimulus {
    func reset() {}
}

/// Constant offset (handy as a baseline / holding current).
public final class ConstantStimulus: Stimulus {
    public var amplitude: Double
    public init(amplitude: Double) { self.amplitude = amplitude }
    public func current(at t: Double) -> Double { amplitude }
}

/// Rectangular pulse: `amplitude` between `start` and `start + duration`.
public final class PulseStimulus: Stimulus {
    public var start: Double      // ms
    public var duration: Double   // ms
    public var amplitude: Double  // µA/cm²

    public init(start: Double, duration: Double, amplitude: Double) {
        self.start = start
        self.duration = duration
        self.amplitude = amplitude
    }

    public func current(at t: Double) -> Double {
        (t >= start && t < start + duration) ? amplitude : 0
    }
}

/// Linear ramp from `from` to `to` between `start` and `start + duration`,
/// zero outside that window.
public final class RampStimulus: Stimulus {
    public var start: Double
    public var duration: Double
    public var from: Double
    public var to: Double

    public init(start: Double, duration: Double, from: Double, to: Double) {
        self.start = start
        self.duration = duration
        self.from = from
        self.to = to
    }

    public func current(at t: Double) -> Double {
        guard t >= start && t < start + duration, duration > 0 else { return 0 }
        let frac = (t - start) / duration
        return from + (to - from) * frac
    }
}

/// Periodic square wave (regular spike train of injected pulses).
public final class TrainStimulus: Stimulus {
    public var start: Double
    public var period: Double      // ms between pulse onsets
    public var pulseWidth: Double  // ms
    public var amplitude: Double
    public var count: Int          // number of pulses (0 = unbounded)

    public init(start: Double, period: Double, pulseWidth: Double,
                amplitude: Double, count: Int = 0) {
        self.start = start
        self.period = period
        self.pulseWidth = pulseWidth
        self.amplitude = amplitude
        self.count = count
    }

    public func current(at t: Double) -> Double {
        guard t >= start, period > 0 else { return 0 }
        let local = t - start
        let n = Int(local / period)
        if count > 0 && n >= count { return 0 }
        let phase = local - Double(n) * period
        return phase < pulseWidth ? amplitude : 0
    }
}

/// Tiny seeded RNG (SplitMix64) — fully deterministic for a given seed,
/// fast, and good enough for non-cryptographic Gaussian noise.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Ornstein-Uhlenbeck noise — coloured noise around `mean` with relaxation
/// time `tau` and stationary stddev `sigma`. Useful for biologically
/// plausible synaptic background. Fully deterministic for a given seed
/// (uses `SplitMix64`, not the system RNG).
public final class OUNoiseStimulus: Stimulus {
    public var mean: Double
    public var sigma: Double
    public var tau: Double         // ms
    public var dt: Double          // sample step (ms)
    public var seed: UInt64        // re-applied on `reset()`
    private var rng: SplitMix64
    private var currentValue: Double
    private var lastSampleTime: Double = -.infinity

    public init(mean: Double = 0, sigma: Double = 1, tau: Double = 5,
                dt: Double = 0.05, seed: UInt64 = 42) {
        self.mean = mean
        self.sigma = sigma
        self.tau = tau
        self.dt = dt
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
        self.currentValue = mean
    }

    public func reset() {
        currentValue = mean
        lastSampleTime = -.infinity
        rng = SplitMix64(seed: seed)
    }

    public func current(at t: Double) -> Double {
        if t - lastSampleTime >= dt {
            // Exact discretisation of the OU process (Gillespie 1996).
            let alpha = exp(-dt / tau)
            let noise = gaussian()
            currentValue = mean + alpha * (currentValue - mean) +
                           sigma * sqrt(1 - alpha * alpha) * noise
            lastSampleTime = t
        }
        return currentValue
    }

    private func gaussian() -> Double {
        // Box-Muller, clamping u1 away from 0 to avoid log(0).
        let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// Sum of multiple stimuli — composition primitive.
public final class CompositeStimulus: Stimulus {
    public var components: [Stimulus]
    public init(_ components: [Stimulus] = []) { self.components = components }
    public func reset() { components.forEach { $0.reset() } }
    public func current(at t: Double) -> Double {
        components.reduce(0) { $0 + $1.current(at: t) }
    }
}
