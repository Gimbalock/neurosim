//
//  AxialCoupling.swift
//  NeuroSimCore
//
//  Symmetric electrical coupling between two compartments belonging to the
//  same neuron — physically, the longitudinal cytoplasmic resistance that
//  links them. The current flowing from compartment A to compartment B is:
//
//      I(A → B) = g · (V_A − V_B)
//
//  which means a current of `g · (V_A − V_B)` *leaves* A and *enters* B.
//  The coupling is bidirectional: from B's perspective the same equation
//  with the sign flipped applies, so the network solver simply adds
//  `g · (V_other − V_self)` to the injected current of each compartment.
//
//  Note that this is identical in form to a `GapJunction` between neurons —
//  we don't share the type because the bookkeeping differs (couplings live
//  inside a `HHNeuron`, gap junctions between `HHNeuron`s in the network),
//  but the physics is the same.
//
//  Units: `conductance` in mS/cm² (per compartment area). For real
//  morphologies you'd derive `conductance` from R_a (axial resistivity),
//  cross-section, and length — out of scope for now; treat it as a free
//  tunable parameter.
//

import Foundation

public struct AxialCoupling: Identifiable, Hashable {

    public let id: UUID

    /// One end of the coupling. Convention: `compartmentA` is typically the
    /// "parent" / closer-to-soma node when modelling a tree, but the
    /// equation is symmetric so this is purely organisational.
    public let compartmentA: UUID

    /// The other end.
    public let compartmentB: UUID

    /// Axial conductance density at the **compartmentA** end (mS/cm²).
    /// For equal-diameter compartments this equals the conductance at the B end.
    /// Higher = tighter electrical coupling.
    public var conductance: Double

    /// Axial conductance density at the **compartmentB** end (mS/cm²).
    /// `nil` means the coupling is symmetric: both ends use `conductance`.
    ///
    /// When compartmentA (soma, d=20 µm) and compartmentB (axon, d=5 µm) have
    /// different membrane areas the same *absolute* axial conductance G [mS]
    /// yields different *density* values per end:
    ///
    ///     g_A = G / A_A        g_B = G / A_B
    ///
    /// Since A ∝ d², the ratio is (d_B/d_A)²  and can be 16× or more.
    /// Storing both values lets `HHNeuron.writeDerivatives` and `HinesSolver`
    /// apply the physically correct density to each compartment's ODE.
    public var conductanceFarEnd: Double?

    public init(id: UUID = UUID(),
                between a: UUID,
                and b: UUID,
                conductance: Double = 1.0,
                conductanceFarEnd: Double? = nil) {
        precondition(a != b, "AxialCoupling must connect two distinct compartments.")
        precondition(conductance >= 0,
                     "Axial conductance must be non-negative — got \(conductance).")
        self.id = id
        self.compartmentA = a
        self.compartmentB = b
        self.conductance = conductance
        self.conductanceFarEnd = conductanceFarEnd
    }

    /// Convenience: does this coupling involve the given compartment?
    public func involves(_ compartmentID: UUID) -> Bool {
        compartmentA == compartmentID || compartmentB == compartmentID
    }

    /// Convenience: given one end, return the other (or nil if `me` isn't
    /// part of this coupling).
    public func other(_ me: UUID) -> UUID? {
        if me == compartmentA { return compartmentB }
        if me == compartmentB { return compartmentA }
        return nil
    }
}
