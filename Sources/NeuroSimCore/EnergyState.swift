//
//  EnergyState.swift
//  NeuroSimCore
//
//  Biophysical energy bookkeeping for a single neuron soma:
//  – Ion concentrations [Na]_i, [K]_i, [Na]_o, [K]_o, [Ca]_i, [Ca]_ER, [Ca]_o (mM)
//  – Metabolite pool [ATP], [ADP], [Pi] (mM)
//  – Cumulative ATP consumed since simulation start (mM, intracellular volume basis)
//
//  ATPPump is a generic struct for any ATP-dependent ion pump (Na/K, PMCA, SERCA, …).
//  EnergyParams holds all tuneable knobs (pump array, mito rate, geometry…).
//  EnergyState is the current snapshot (pure value type — cheap to copy/snapshot).
//

import Foundation

// MARK: - ATPPump

/// A generic ATP-dependent ion pump. Covers Na/K-ATPase, PMCA, SERCA, and
/// any future pump with Hill-type kinetics for one or two ion binding sites.
public struct ATPPump: Sendable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var label: String          // display name: "Na/K-ATPase", "PMCA", "SERCA"

    // Primary ion (intracellular side)
    public var ion: String            // "Na", "K", "Ca"
    public var pumpOut: Bool          // true = pumps ion OUT of cell
    public var stoichiometry: Double  // primary ions per ATP cycle

    // Optional secondary ion (e.g. K for Na/K pump, extracellular side)
    public var ion2: String?
    public var pumpOut2: Bool         // for Na/K: K pumped IN (false)
    public var stoichiometry2: Double // secondary ions per ATP
    public var kmIon2: Double?        // Km for secondary ion
    public var hillN2: Int            // Hill n for secondary ion

    // For SERCA: destination is ER lumen, not extracellular
    public var pumpToER: Bool         // true for SERCA only

    // Kinetics
    public var jMax: Double           // mM/ms max ATP hydrolysis rate
    public var kmIon: Double          // Km for primary ion (mM)
    public var hillN: Int             // Hill cooperativity for primary ion
    public var kmATP: Double          // Km for ATP (mM)

    public init(id: UUID = UUID(), enabled: Bool = true, label: String,
                ion: String, pumpOut: Bool = true, stoichiometry: Double = 1,
                ion2: String? = nil, pumpOut2: Bool = false, stoichiometry2: Double = 0,
                kmIon2: Double? = nil, hillN2: Int = 1,
                pumpToER: Bool = false,
                jMax: Double, kmIon: Double, hillN: Int = 1, kmATP: Double = 0.5) {
        self.id = id; self.enabled = enabled; self.label = label
        self.ion = ion; self.pumpOut = pumpOut; self.stoichiometry = stoichiometry
        self.ion2 = ion2; self.pumpOut2 = pumpOut2; self.stoichiometry2 = stoichiometry2
        self.kmIon2 = kmIon2; self.hillN2 = hillN2
        self.pumpToER = pumpToER
        self.jMax = jMax; self.kmIon = kmIon; self.hillN = hillN; self.kmATP = kmATP
    }

    // MARK: - Presets
    public static var naKPump: ATPPump {
        ATPPump(label: "Na/K-ATPase",
                ion: "Na", pumpOut: true, stoichiometry: 3,
                ion2: "K", pumpOut2: false, stoichiometry2: 2,
                kmIon2: 1.5, hillN2: 2,
                jMax: 0.012, kmIon: 10, hillN: 3, kmATP: 0.5)
    }
    public static var pmca: ATPPump {
        ATPPump(label: "PMCA",
                ion: "Ca", pumpOut: true, stoichiometry: 1,
                jMax: 0.0008, kmIon: 0.0003, hillN: 2, kmATP: 0.5)
    }
    public static var serca: ATPPump {
        ATPPump(label: "SERCA",
                ion: "Ca", pumpOut: false, stoichiometry: 2, pumpToER: true,
                jMax: 0.0012, kmIon: 0.0003, hillN: 2, kmATP: 0.5)
    }
}

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

    // MARK: Calcium initial concentrations (mM)
    public var caI0:  Double = 0.0001  // [Ca²⁺]ᵢ at rest (mM = 100 nM)
    public var caER0: Double = 0.40    // [Ca²⁺]_ER at rest (mM)
    public var caO0:  Double = 2.0     // [Ca²⁺]ₒ (constant, mM)

    // MARK: Calcium buffer + ER leak
    /// Cytoplasmic buffer ratio κ — total/free Ca ratio. Typical range 10–200.
    /// A value of 100 means 99% of incoming Ca is immediately buffered.
    public var caBufferKappa: Double = 100.0

    /// Passive ER→cytoplasm Ca leak rate (mM/ms per mM [Ca]_ER).
    public var erLeakRate: Double = 0.00005

    // MARK: ATP pumps
    /// Array of ATP-dependent pumps. Default: Na/K-ATPase only.
    /// Add .pmca or .serca presets to include calcium pumps.
    public var pumps: [ATPPump] = [.naKPump]

    // MARK: Mitochondrial ATP synthesis
    /// Maximum ATP synthesis rate (mM/ms, intracellular volume basis).
    public var mitoJmax:   Double = 0.004  // mM/ms
    /// Reference mitoJmax corresponding to 100 % mitochondrial health.
    /// Persisted so that changing the health slider always scales relative
    /// to the user's calibrated "healthy" value, not the hard-coded default.
    public var mitoJmaxRef: Double = 0.004  // mM/ms
    /// K_m for [ADP] driving synthesis.
    public var mitoKmADP:  Double = 0.05   // mM

    // MARK: Mitochondrial health convenience (0 – 100 %)
    /// Percentage of full mitochondrial capacity (100 % = healthy, 0 % = complete failure).
    /// Setting this property updates `mitoJmax` proportionally; reading it derives the
    /// percentage from the current `mitoJmax` relative to `mitoJmaxRef`.
    public var mitoHealthPercent: Double {
        get {
            guard mitoJmaxRef > 0 else { return 0 }
            return min(mitoJmax / mitoJmaxRef * 100.0, 100.0)
        }
        set {
            mitoJmax = mitoJmaxRef * max(0.0, min(newValue, 100.0)) / 100.0
        }
    }

    // MARK: Basal ATP consumption
    /// First-order basal consumption (mM/ms) representing all non-pump costs
    /// (actin dynamics, vesicle cycling, etc.).
    public var basalATPRate: Double = 0.0004  // mM/ms

    // MARK: Geometry
    /// Fraction of tissue volume occupied by the extracellular space (0–1).
    /// Cortical tissue ≈ 0.20 (20 %).  Determines how fast [Na]_o / [K]_o
    /// shift when clampExtracellular is false.
    /// Internally converted to vol_o/vol_i ratio = ecsFraction / (1 − ecsFraction).
    public var ecsFraction: Double = 0.20   // 20 % — typical cortex

    /// vol_o / vol_i derived from ecsFraction.  Used by EnergyEngine.
    public var extracellularRatio: Double {
        get { let f = max(1e-6, min(ecsFraction, 0.9999)); return f / (1.0 - f) }
    }

    // MARK: Extracellular clamping
    /// When true (default), [Na]_o and [K]_o are held constant — blood/glia
    /// maintain the extracellular reservoir (physiological in vivo condition).
    /// When false, extracellular concentrations evolve with ionic flux, scaled
    /// by extracellularRatio. Use this to model ischemia / no glial buffering
    /// where concentrations can equalize and reversal potentials collapse to 0.
    public var clampExtracellular: Bool = true

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

    // MARK: Calcium concentrations (mM)
    public var caI: Double    // [Ca²⁺]ᵢ (free cytoplasmic)
    public var caER: Double   // [Ca²⁺]_ER (ER lumen)
    public var caO: Double    // [Ca²⁺]ₒ (clamped at 2 mM)

    // MARK: Metabolites (mM, intracellular volume basis)
    public var atp: Double    // [ATP]
    public var adp: Double    // [ADP]
    public var pi:  Double    // [Pi]

    /// Cumulative ATP consumed by pumps since simulation start (mM).
    public var atpConsumedTotal: Double

    /// Instantaneous ATP consumption by the Na/K pump in the last step (mM/ms).
    public var pumpRateLast: Double = 0
    /// Na/K pump demand at unlimited ATP — jMax × Hill_Na × Hill_K (mM/ms).
    /// The difference (pumpDemandLast - pumpRateLast) is the ATP deficit per ms.
    public var pumpDemandLast: Double = 0

    // MARK: - Initialisers

    /// Resting state consistent with EnergyParams defaults.
    public init(params: EnergyParams) {
        naI = params.naI0;  kI  = params.kI0
        naO = params.naO0;  kO  = params.kO0
        caI = params.caI0;  caER = params.caER0;  caO = params.caO0
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
    /// Calcium concentrations start at param defaults (no inversion needed).
    public init(inferredFrom comp: Compartment, params: EnergyParams) {
        naO = params.naO0;  kO  = params.kO0
        caI = params.caI0;  caER = params.caER0;  caO = params.caO0
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
                caI: Double, caER: Double, caO: Double,
                atp: Double, adp: Double, pi: Double,
                atpConsumedTotal: Double,
                pumpRateLast: Double = 0, pumpDemandLast: Double = 0) {
        self.naI = naI; self.kI = kI; self.naO = naO; self.kO = kO
        self.caI = caI; self.caER = caER; self.caO = caO
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

    /// Ca²⁺ Nernst potential (mV) from current concentrations.
    public var eCa: Double {
        Nernst.reversalPotential(
            species: .calcium,
            concentrationIn: max(caI, 1e-9),
            concentrationOut: max(caO, 1e-4))
    }

    /// ATP-to-ADP ratio (dimensionless). Drops sharply during energy failure.
    public var atpAdpRatio: Double {
        adp > 1e-9 ? atp / adp : .infinity
    }

    /// ATP deficit: how much the pump wanted but couldn't get due to low ATP (mM/ms).
    public var pumpDeficitLast: Double { max(pumpDemandLast - pumpRateLast, 0) }
}
