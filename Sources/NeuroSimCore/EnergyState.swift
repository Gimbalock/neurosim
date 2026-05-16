//
//  EnergyState.swift
//  NeuroSimCore
//
//  Biophysical energy bookkeeping for a single neuron soma:
//  – Ion concentrations [Na]_i, [K]_i, [Na]_o, [K]_o (mM)
//  – Metabolite pool [ATP], [ADP], [Pi] (mM)
//  – Cumulative ATP consumed since simulation start (mM, intracellular volume basis)
//
//  EnergyParams holds all tuneable knobs (pump kinetics, mito rate, geometry…).
//  EnergyState is the current snapshot (pure value type — cheap to copy/snapshot).
//

import Foundation

// MARK: - EnergyParams

/// Configuration for the metabolic energy sub-model of one neuron.
/// Stored on `HHNeuron`; defaults to disabled so existing neurons are unaffected.
public struct EnergyParams: Sendable {

    /// When false the energy engine is bypassed entirely — zero overhead.
    public var enabled: Bool = false

    // MARK: Initial concentrations (mM)
    public var naI0:  Double = 15.0   // [Na⁺]_i at rest
    public var kI0:   Double = 140.0  // [K⁺]_i at rest
    public var naO0:  Double = 145.0  // [Na⁺]_o at rest
    public var kO0:   Double = 4.0    // [K⁺]_o at rest
    public var atp0:  Double = 2.0    // [ATP] at rest
    public var adp0:  Double = 0.2    // [ADP] at rest
    public var pi0:   Double = 2.5    // [Pi] at rest

    // MARK: Na/K-ATPase pump kinetics
    /// Maximum ATP consumption rate by the pump (mM/ms, intracellular volume basis).
    /// Calibrate so that the pump balances leak currents at rest.
    public var pumpJmax:  Double = 0.012   // mM/ms
    /// K_m for [Na]_i (mM) — half-saturation, Hill n=3 cooperative binding.
    public var pumpKmNa:  Double = 10.0    // mM
    /// K_m for [K]_o (mM) — half-saturation, Hill n=2.
    public var pumpKmK:   Double = 1.5     // mM
    /// K_m for [ATP] (mM) — Michaelis constant.
    public var pumpKmATP: Double = 0.5     // mM

    // MARK: Mitochondrial ATP synthesis
    /// Maximum ATP synthesis rate (mM/ms, intracellular volume basis).
    public var mitoJmax:   Double = 0.004  // mM/ms
    /// K_m for [ADP] driving synthesis.
    public var mitoKmADP:  Double = 0.05   // mM

    // MARK: Basal ATP consumption
    /// First-order basal consumption (mM/ms) representing all non-pump costs
    /// (actin dynamics, vesicle cycling, etc.).
    public var basalATPRate: Double = 0.0004  // mM/ms

    // MARK: Geometry
    /// Ratio of extracellular volume to intracellular volume (vol_o / vol_i).
    /// Typical cortical tissue ≈ 0.2 ECS fraction → ratio ≈ 0.25.
    /// Increasing this slows [Na]_o and [K]_o depletion.
    public var extracellularRatio: Double = 5.0

    // MARK: Temperature
    /// Temperature used for Nernst calculations (K).
    public var temperatureK: Double = Nernst.mammalianBodyTemperatureK

    public init() {}
}

// MARK: - EnergyState

/// Current snapshot of metabolic and ionic state for one neuron.
/// Immutable computed properties expose derived quantities (Nernst potentials,
/// ATP:ADP ratio). Use `EnergyEngine.step(...)` to advance to the next dt.
public struct EnergyState: Sendable {

    // MARK: Ion concentrations (mM)
    public var naI: Double    // [Na⁺]_i
    public var kI:  Double    // [K⁺]_i
    public var naO: Double    // [Na⁺]_o
    public var kO:  Double    // [K⁺]_o

    // MARK: Metabolites (mM, intracellular volume basis)
    public var atp: Double    // [ATP]
    public var adp: Double    // [ADP]
    public var pi:  Double    // [Pi]

    /// Cumulative ATP consumed by the Na/K pump since simulation start (mM).
    public var atpConsumedTotal: Double

    /// Instantaneous ATP consumption by the pump in the last step (mM/ms).
    public var pumpRateLast: Double = 0
    /// Pump demand at unlimited ATP — pumpJmax × Hill_Na × Hill_K (mM/ms).
    /// The difference (pumpDemandLast - pumpRateLast) is the ATP deficit per ms.
    public var pumpDemandLast: Double = 0

    // MARK: - Initialisers

    /// Resting state consistent with EnergyParams defaults.
    public init(params: EnergyParams) {
        naI = params.naI0;  kI  = params.kI0
        naO = params.naO0;  kO  = params.kO0
        atp = params.atp0;  adp = params.adp0; pi = params.pi0
        atpConsumedTotal = 0
        pumpRateLast = 0
        pumpDemandLast = 0
    }

    /// Infer initial intracellular concentrations from the **current E_rev values**
    /// of the compartment's channels, by inverting the Nernst equation.
    ///
    /// This ensures that enabling the energy model never changes the firing
    /// behaviour: at t = 0 the computed E_Na / E_K are identical to whatever
    /// the user had set manually in the inspector.
    ///
    ///     C_in = C_out · exp(-z · E_mV · 1e-3 · F / (R·T))
    ///
    /// Extracellular concentrations (C_out) are kept at the param defaults.
    /// Metabolites (ATP/ADP/Pi) are kept at param defaults.
    public init(inferredFrom comp: Compartment, params: EnergyParams) {
        naO = params.naO0;  kO  = params.kO0
        atp = params.atp0;  adp = params.adp0; pi = params.pi0
        atpConsumedTotal = 0

        // Locate reversal potentials from the first matching channel.
        var eNa: Double? = nil
        var eK:  Double? = nil
        for ch in comp.channels {
            switch ch.species?.symbol {
            case "Na" where eNa == nil: eNa = ch.reversal
            case "K"  where eK  == nil: eK  = ch.reversal
            default: break
            }
        }

        // Invert Nernst: C_in = C_out · exp(-z · E_V · F / (R·T))
        // z = +1 for both Na⁺ and K⁺.
        let rt = Nernst.R * params.temperatureK
        if let e = eNa {
            naI = max(params.naO0 * exp(-e * 1e-3 * Nernst.F / rt), 0.1)
        } else {
            naI = params.naI0
        }
        if let e = eK {
            kI  = max(params.kO0  * exp(-e * 1e-3 * Nernst.F / rt), 0.1)
        } else {
            kI  = params.kI0
        }
        pumpRateLast = 0
        pumpDemandLast = 0
    }

    /// Direct memberwise init used by EnergyEngine.
    public init(naI: Double, kI: Double, naO: Double, kO: Double,
                atp: Double, adp: Double, pi: Double,
                atpConsumedTotal: Double,
                pumpRateLast: Double = 0, pumpDemandLast: Double = 0) {
        self.naI = naI; self.kI = kI; self.naO = naO; self.kO = kO
        self.atp = atp; self.adp = adp; self.pi  = pi
        self.atpConsumedTotal = atpConsumedTotal
        self.pumpRateLast = pumpRateLast
        self.pumpDemandLast = pumpDemandLast
    }

    // MARK: - Derived quantities

    /// Na⁺ Nernst potential (mV) from current concentrations.
    public var eNa: Double {
        Nernst.reversalPotential(
            species: .sodium,
            concentrationIn: max(naI, 1e-4),
            concentrationOut: max(naO, 1e-4))
    }

    /// K⁺ Nernst potential (mV) from current concentrations.
    public var eK: Double {
        Nernst.reversalPotential(
            species: .potassium,
            concentrationIn: max(kI, 1e-4),
            concentrationOut: max(kO, 1e-4))
    }

    /// ATP-to-ADP ratio (dimensionless). Drops sharply during energy failure.
    public var atpAdpRatio: Double {
        adp > 1e-9 ? atp / adp : .infinity
    }

    /// ATP deficit: how much the pump wanted but couldn't get due to low ATP (mM/ms).
    public var pumpDeficitLast: Double { max(pumpDemandLast - pumpRateLast, 0) }
}
