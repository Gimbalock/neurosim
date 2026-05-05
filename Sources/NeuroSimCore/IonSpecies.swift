//
//  IonSpecies.swift
//  NeuroSimCore
//
//  A typed identifier for ion species (Na+, K+, Ca²⁺, …) carrying valence and
//  canonical mammalian concentrations. Used by `IonChannel` to declare which
//  ion it conducts, and by future `Compartment`s to look up reversal
//  potentials and concentration dynamics.
//
//  Concentrations stored on the static canonical species are *defaults* —
//  they exist so that anything which needs a sane starting point (UI presets,
//  Nernst computations before a compartment has been wired up) has somewhere
//  to read them from. Real simulations should override them per-compartment
//  once the concentration-dynamics layer (Step 2) is in place.
//

import Foundation

/// A chemical ion species, identified by symbol and electrical valence,
/// optionally carrying canonical reference concentrations.
public struct IonSpecies: Hashable, Sendable {

    /// Chemical symbol — used for labels, exports, and as a stable identifier
    /// (e.g. "Na", "K", "Ca", "Cl").
    public let symbol: String

    /// Electrical valence (charge in elementary units). Must be non-zero —
    /// uncharged species can't have a Nernst potential.
    public let valence: Int

    /// Canonical intracellular concentration (mM). For mammalian neurons by
    /// default; tunable per-instance for non-standard preparations.
    public let defaultConcentrationIn: Double

    /// Canonical extracellular concentration (mM).
    public let defaultConcentrationOut: Double

    public init(symbol: String,
                valence: Int,
                defaultConcentrationIn: Double = 1.0,
                defaultConcentrationOut: Double = 1.0) {
        precondition(valence != 0, "Ion species must have non-zero valence.")
        self.symbol = symbol
        self.valence = valence
        self.defaultConcentrationIn = defaultConcentrationIn
        self.defaultConcentrationOut = defaultConcentrationOut
    }

    // MARK: - Canonical species (typical mammalian neuron, mM)

    /// Sodium — extracellular ≫ intracellular, drives depolarisation.
    public static let sodium = IonSpecies(
        symbol: "Na", valence: +1,
        defaultConcentrationIn: 15.0,
        defaultConcentrationOut: 145.0
    )

    /// Potassium — intracellular ≫ extracellular, drives repolarisation.
    public static let potassium = IonSpecies(
        symbol: "K", valence: +1,
        defaultConcentrationIn: 140.0,
        defaultConcentrationOut: 4.0
    )

    /// Calcium — huge extracellular/intracellular ratio (10 000×), drives
    /// signalling cascades. Free [Ca²⁺]_in at rest is ~100 nM = 1e-4 mM.
    public static let calcium = IonSpecies(
        symbol: "Ca", valence: +2,
        defaultConcentrationIn: 0.0001,
        defaultConcentrationOut: 2.0
    )

    /// Chloride — extracellular > intracellular in mature neurons; sets a
    /// hyperpolarising reversal (~-65 mV at body T).
    public static let chloride = IonSpecies(
        symbol: "Cl", valence: -1,
        defaultConcentrationIn: 10.0,
        defaultConcentrationOut: 110.0
    )

    /// Magnesium — primarily a permeating block on NMDA receptors; modest
    /// gradient compared to Ca²⁺.
    public static let magnesium = IonSpecies(
        symbol: "Mg", valence: +2,
        defaultConcentrationIn: 0.5,
        defaultConcentrationOut: 1.5
    )

    // MARK: - Registry

    /// All canonical species, ordered for UI display.
    public static let allCanonical: [IonSpecies] = [.sodium, .potassium, .calcium, .chloride, .magnesium]

    /// Look up a canonical species by its symbol (case-sensitive).
    /// Returns nil when the symbol is unknown or nil.
    public static func canonical(symbol: String) -> IonSpecies? {
        allCanonical.first { $0.symbol == symbol }
    }

    // MARK: - Convenience

    /// Reversal potential at this species' default concentrations (mV).
    /// Convenient for UI presets when a real concentration model isn't wired
    /// up yet.
    public func defaultReversal(temperatureK T: Double = Nernst.mammalianBodyTemperatureK) -> Double {
        Nernst.reversalPotential(species: self,
                                 concentrationIn: defaultConcentrationIn,
                                 concentrationOut: defaultConcentrationOut,
                                 temperatureK: T)
    }
}
