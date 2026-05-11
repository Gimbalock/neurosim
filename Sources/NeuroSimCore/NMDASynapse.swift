//
//  NMDASynapse.swift
//  NeuroSimCore
//
//  NMDA receptor synapse with voltage-dependent Mg²⁺ block.
//
//  Unlike AMPA, NMDA conductance is gated by both:
//    1. The pre-synaptic gating variable `s` (spike-driven, slow decay)
//    2. A voltage-dependent Mg²⁺ unblock factor B(V_post)
//
//  B(V) = 1 / (1 + [Mg²⁺]_o / β · exp(−γ · V))   (Jahr & Stevens 1990)
//
//  At resting potential (−65 mV) the channel is nearly fully blocked (~95%).
//  Depolarisation relieves the block — NMDA thus acts as a coincidence
//  detector requiring both pre-synaptic input AND post-synaptic depolarisation.
//
//  Typical parameters:
//    gMax    = 0.05–0.3  mS/cm²
//    E_rev   = 0 mV      (same as AMPA — mixed Na⁺/K⁺/Ca²⁺)
//    τ_decay = 80–150 ms (much slower than AMPA ~5 ms)
//    [Mg²⁺]  = 1.0 mM   (physiological extracellular concentration)
//

import Foundation

public final class NMDASynapse: Synapse {

    public let id: UUID
    public var preNeuronID: UUID
    public var postNeuronID: UUID
    public var postCompartmentID: UUID?

    public var gMax: Double      // mS/cm²  — peak conductance
    public var reversal: Double  // mV       — typically 0
    public var tauDecay: Double  // ms       — slow NMDA decay (~100 ms)
    public var sMax: Double      // dimensionless — saturation cap
    public var weight: Double    // dimensionless — plasticity multiplier

    // Mg²⁺ block parameters (Jahr & Stevens 1990)
    public var mgConc: Double    // mM — extracellular [Mg²⁺], typically 1.0
    public var mgGamma: Double   // mV⁻¹ — voltage sensitivity, typically 0.062
    public var mgBeta: Double    // mM   — half-block concentration, typically 3.57

    public init(id: UUID = UUID(),
                from pre: UUID,
                to post: UUID,
                onCompartment compartment: UUID? = nil,
                gMax: Double = 0.1,
                reversal: Double = 0.0,
                tauDecay: Double = 100.0,
                sMax: Double = 1.0,
                weight: Double = 1.0,
                mgConc: Double = 1.0,
                mgGamma: Double = 0.062,
                mgBeta: Double = 3.57) {
        self.id = id
        self.preNeuronID = pre
        self.postNeuronID = post
        self.postCompartmentID = compartment
        self.gMax = gMax
        self.reversal = reversal
        self.tauDecay = tauDecay
        self.sMax = sMax
        self.weight = weight
        self.mgConc = mgConc
        self.mgGamma = mgGamma
        self.mgBeta = mgBeta
    }

    // MARK: - Mg²⁺ block

    /// Fraction of channels unblocked at the given post-synaptic voltage.
    /// Ranges from ~0.05 at −65 mV to ~0.97 at +40 mV.
    public func mgBlock(vPost: Double) -> Double {
        1.0 / (1.0 + (mgConc / mgBeta) * exp(-mgGamma * vPost))
    }

    // MARK: - Synapse protocol

    public var stateCount: Int { 1 }

    public func initialState() -> [Double] { [0.0] }

    public func currentToPost(state: ArraySlice<Double>,
                              vPre: Double,
                              vPost: Double) -> Double {
        let s = state[state.startIndex]
        return weight * gMax * s * mgBlock(vPost: vPost) * (vPost - reversal)
    }

    public func writeDerivatives(state: ArraySlice<Double>,
                                 vPre: Double,
                                 vPost: Double,
                                 into output: inout [Double],
                                 offset: Int) {
        let s = state[state.startIndex]
        output[offset] = -s / tauDecay
    }

    public func applySpike(into state: inout [Double], offset: Int) {
        state[offset] = min(state[offset] + 1.0, sMax)
    }
}
