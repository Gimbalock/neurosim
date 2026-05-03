//
//  Nernst.swift
//  NeuroSimCore
//
//  Equilibrium potential utilities. Returns are in **millivolts** so they
//  drop into the existing HH machinery without further conversion.
//
//  Two equations are exposed:
//
//   - Nernst: single-ion equilibrium, E_X = (RT/zF) · ln([X]_out / [X]_in).
//   - Goldman-Hodgkin-Katz (GHK): multi-ion resting potential, useful for
//     setting up the leak reversal of a compartment to match a target
//     resting V given Na/K/Cl permeabilities.
//
//  Physical constants are SI; the only unit acrobatics happen in the final
//  *1000.0 to convert volts to millivolts.
//

import Foundation

public enum Nernst {

    // MARK: - Constants

    /// Faraday constant (C·mol⁻¹).
    public static let F: Double = 96_485.332_12

    /// Universal gas constant (J·mol⁻¹·K⁻¹).
    public static let R: Double = 8.314_462_618_153_24

    // MARK: - Useful temperatures (K)

    /// 37 °C — mammalian body temperature.
    public static let mammalianBodyTemperatureK: Double = 310.15

    /// 22 °C — typical room temperature for in-vitro slice recordings.
    public static let roomTemperatureK: Double = 295.15

    /// 6.3 °C — squid giant axon temperature in Hodgkin & Huxley (1952).
    /// Useful when reproducing the original HH paper exactly.
    public static let squidTemperatureK: Double = 279.45

    // MARK: - Nernst equation

    /// Equilibrium potential of a single ion species, in millivolts.
    ///
    ///     E = (RT / zF) · ln([X]_out / [X]_in)
    ///
    /// - Parameters:
    ///   - species: ion species (provides valence z).
    ///   - concentrationIn: intracellular concentration (any consistent unit).
    ///   - concentrationOut: extracellular concentration (same unit).
    ///   - temperatureK: absolute temperature in kelvin. Defaults to 37 °C.
    /// - Returns: reversal potential E_X in millivolts.
    public static func reversalPotential(species: IonSpecies,
                                         concentrationIn cIn: Double,
                                         concentrationOut cOut: Double,
                                         temperatureK T: Double = mammalianBodyTemperatureK) -> Double {
        precondition(cIn > 0 && cOut > 0,
                     "Concentrations passed to Nernst must be strictly positive.")
        precondition(T > 0, "Temperature must be positive.")
        let z = Double(species.valence)
        // RT/(zF) is in volts; convert to mV at the end.
        let coefficient = (R * T / (z * F)) * 1000.0
        return coefficient * log(cOut / cIn)
    }

    // MARK: - Goldman-Hodgkin-Katz voltage equation

    /// One ion's contribution to the GHK voltage equation. Permeability is a
    /// relative weight (only ratios matter).
    public struct GHKContribution: Sendable {
        public let species: IonSpecies
        public let permeability: Double
        public let concentrationIn: Double
        public let concentrationOut: Double

        public init(species: IonSpecies,
                    permeability: Double,
                    concentrationIn: Double,
                    concentrationOut: Double) {
            self.species = species
            self.permeability = permeability
            self.concentrationIn = concentrationIn
            self.concentrationOut = concentrationOut
        }
    }

    /// Goldman-Hodgkin-Katz voltage equation for monovalent ions, in mV.
    /// Cations and anions enter the formula with opposite roles for [in]/[out].
    /// Multivalent ions (Ca²⁺ etc.) require a different treatment and are
    /// rejected here on purpose — call `reversalPotential` for those, or
    /// extend this helper if you need a full multivalent GHK.
    ///
    ///     V_m = (RT/F) · ln( (Σ P_cat·[cat]_out + Σ P_an·[an]_in)
    ///                       / (Σ P_cat·[cat]_in  + Σ P_an·[an]_out) )
    public static func ghkVoltage(contributions: [GHKContribution],
                                  temperatureK T: Double = mammalianBodyTemperatureK) -> Double {
        precondition(!contributions.isEmpty,
                     "GHK voltage requires at least one ion contribution.")
        var num = 0.0
        var den = 0.0
        for c in contributions {
            switch c.species.valence {
            case +1:
                num += c.permeability * c.concentrationOut
                den += c.permeability * c.concentrationIn
            case -1:
                num += c.permeability * c.concentrationIn
                den += c.permeability * c.concentrationOut
            default:
                preconditionFailure(
                    "GHK helper expects monovalent ions only — got valence \(c.species.valence) " +
                    "for species \(c.species.symbol). Use reversalPotential() for divalent ions.")
            }
        }
        precondition(num > 0 && den > 0,
                     "GHK numerator/denominator must be positive — check permeabilities.")
        return (R * T / F) * 1000.0 * log(num / den)
    }
}
