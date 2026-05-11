// SynapticNoise.swift
// NeuroSimCore — Ornstein-Uhlenbeck synaptic background noise (Destexhe 2001).
//
// Two OU conductance processes inject realistic background fluctuations:
//   dGe = -(Ge-μe)/τe dt + σe√(2/τe) dWe   (excitatory, Ee ≈ 0 mV)
//   dGi = -(Gi-μi)/τi dt + σi√(2/τi) dWi   (inhibitory, Ei ≈ −70 mV)
//
// Conductances are in mS/cm² (same convention as IonChannel.gMax).
// Current I = Ge*(V−Ee) + Gi*(V−Ei)  [µA/cm²]  (outward-positive convention).

import Foundation

// MARK: - Serialisable parameters

public struct SynapticNoiseParams: Codable, Equatable {
    // ── Excitatory OU ─────────────────────────────────────────────────────────
    public var geMean:  Double = 0.012   // mS/cm², mean excitatory conductance
    public var geSigma: Double = 0.003   // mS/cm², stationary std
    public var geTau:   Double = 3.0     // ms, correlation time

    // ── Inhibitory OU ─────────────────────────────────────────────────────────
    public var giMean:  Double = 0.057   // mS/cm², mean inhibitory conductance
    public var giSigma: Double = 0.0066  // mS/cm², stationary std
    public var giTau:   Double = 10.0   // ms, correlation time

    // ── Reversal potentials ───────────────────────────────────────────────────
    public var ee: Double = 0.0          // mV, excitatory (AMPA)
    public var ei: Double = -70.0        // mV, inhibitory (GABA-A)

    // ── Global weight ─────────────────────────────────────────────────────────
    public var weight: Double = 1.0         // dimensionless scaler [0, 1]

    // ── Reproducibility ───────────────────────────────────────────────────────
    public var seed: UInt64 = 42

    public init() {}
}

// MARK: - Runtime noise source (volatile — rebuilt from params on load)

public final class SynapticNoiseSource {

    public var params: SynapticNoiseParams {
        didSet { invalidateCoefficients() }
    }

    // OU fluctuation state
    private var geDelta: Double = 0
    private var giDelta: Double = 0

    // Cached exact-discretisation coefficients (recomputed when dt changes)
    private var cachedDt: Double = .nan
    private var geExp:    Double = 0
    private var geAmp:    Double = 0
    private var giExp:    Double = 0
    private var giAmp:    Double = 0

    // Avoid double-stepping inside RK4 sub-steps
    private var lastStepTime: Double = -.infinity

    private var rng: SplitMix64

    public init(params: SynapticNoiseParams = SynapticNoiseParams()) {
        self.params = params
        self.rng    = SplitMix64(seed: params.seed)
    }

    // MARK: Lifecycle

    public func reset() {
        geDelta      = 0
        giDelta      = 0
        lastStepTime = -.infinity
        rng          = SplitMix64(seed: params.seed)
        cachedDt     = .nan
    }

    // MARK: Stepping

    /// Advance OU state (once per unique simulation time) and return the net
    /// synaptic current density **I [µA/cm²]** at membrane voltage `v` (mV).
    ///
    /// Called from `Network.computeDerivatives`; `dt` is the simulator step.
    /// The `lastStepTime` guard prevents double-update during RK4 sub-steps.
    public func current(at t: Double, voltage v: Double, dt: Double) -> Double {
        if t > lastStepTime {
            updateCoefficients(dt: dt)
            geDelta      = geExp * geDelta + geAmp * nextGaussian()
            giDelta      = giExp * giDelta + giAmp * nextGaussian()
            lastStepTime = t
        }
        let ge = max(0, params.geMean + geDelta)   // clamp ≥ 0
        let gi = max(0, params.giMean + giDelta)
        // mS/cm² × mV = µA/cm²  — scaled by weight [0, 1]
        return params.weight * (ge * (v - params.ee) + gi * (v - params.ei))
    }

    // MARK: Private

    private func invalidateCoefficients() { cachedDt = .nan }

    private func updateCoefficients(dt: Double) {
        guard dt != cachedDt else { return }
        cachedDt = dt
        let eTau = max(params.geTau, 1e-9)
        let iTau = max(params.giTau, 1e-9)
        geExp = exp(-dt / eTau)
        geAmp = params.geSigma * sqrt(max(0, 1 - geExp * geExp))
        giExp = exp(-dt / iTau)
        giAmp = params.giSigma * sqrt(max(0, 1 - giExp * giExp))
    }

    /// Box-Muller Gaussian deviate using SplitMix64.
    private func nextGaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
