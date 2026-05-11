//
//  STDPSynapse.swift
//  NeuroSimCore
//
//  AMPA-like chemical synapse with Spike-Timing Dependent Plasticity (STDP).
//
//  STDP is implemented via eligibility traces (Morrison et al. 2008):
//
//    x_pre  — pre-synaptic trace, jumps +1 on each pre spike,  decays with τ+
//    x_post — post-synaptic trace, jumps +1 on each post spike, decays with τ−
//
//  Weight update rules (additive STDP):
//    On PRE  spike:  w -= A− · x_post   (LTD — post fired before pre)
//    On POST spike:  w += A+ · x_pre    (LTP — pre fired before post)
//
//  Weight is clamped to [wMin, wMax] after every update.
//
//  State vector layout: [s, x_pre, x_post]
//    s      — conductance gating variable (same as ChemicalSynapse)
//    x_pre  — pre-synaptic eligibility trace
//    x_post — post-synaptic eligibility trace
//
//  Conductance dynamics and spike dispatch are identical to ChemicalSynapse:
//    On pre spike:   s += 1 (clamped to sMax)
//    ds/dt = −s / τ_decay
//    I_post = weight · gMax · s · (V_post − E_rev)
//

import Foundation

public final class STDPSynapse: Synapse {

    public let id: UUID
    public var preNeuronID: UUID
    public var postNeuronID: UUID
    public var postCompartmentID: UUID?

    // Base conductance parameters (identical to ChemicalSynapse)
    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV  — 0 mV for AMPA/excitatory
    public var tauDecay: Double  // ms  — decay of s (~5 ms for AMPA)
    public var sMax: Double      // saturation cap on s

    // Plasticity weight (modified by STDP; 1.0 = unmodulated)
    public var weight: Double

    // STDP parameters
    public var aPlus: Double     // LTP amplitude (e.g. 0.005)
    public var aMinus: Double    // LTD amplitude (e.g. 0.005)
    public var tauPlus: Double   // ms — LTP trace time constant (e.g. 20 ms)
    public var tauMinus: Double  // ms — LTD trace time constant (e.g. 20 ms)
    public var wMin: Double      // minimum weight (e.g. 0)
    public var wMax: Double      // maximum weight (e.g. 4)

    public init(id: UUID = UUID(),
                from pre: UUID,
                to post: UUID,
                onCompartment compartment: UUID? = nil,
                gMax: Double = 0.1,
                reversal: Double = 0.0,
                tauDecay: Double = 5.0,
                sMax: Double = 1.0,
                weight: Double = 1.0,
                aPlus: Double = 0.005,
                aMinus: Double = 0.005,
                tauPlus: Double = 20.0,
                tauMinus: Double = 20.0,
                wMin: Double = 0.0,
                wMax: Double = 4.0) {
        self.id = id
        self.preNeuronID = pre
        self.postNeuronID = post
        self.postCompartmentID = compartment
        self.gMax = gMax
        self.reversal = reversal
        self.tauDecay = tauDecay
        self.sMax = sMax
        self.weight = weight
        self.aPlus = aPlus
        self.aMinus = aMinus
        self.tauPlus = tauPlus
        self.tauMinus = tauMinus
        self.wMin = wMin
        self.wMax = wMax
    }

    // MARK: - State layout: [s, x_pre, x_post]

    public var stateCount: Int { 3 }

    public func initialState() -> [Double] { [0.0, 0.0, 0.0] }

    // MARK: - Synapse protocol

    public func currentToPost(state: ArraySlice<Double>,
                              vPre: Double,
                              vPost: Double) -> Double {
        let s = state[state.startIndex]
        return weight * gMax * s * (vPost - reversal)
    }

    public func writeDerivatives(state: ArraySlice<Double>,
                                 vPre: Double,
                                 vPost: Double,
                                 into output: inout [Double],
                                 offset: Int) {
        let s      = state[state.startIndex]
        let xPre   = state[state.startIndex + 1]
        let xPost  = state[state.startIndex + 2]
        output[offset]     = -s     / tauDecay
        output[offset + 1] = -xPre  / tauPlus
        output[offset + 2] = -xPost / tauMinus
    }

    /// Pre-synaptic spike: conductance jump + pre-trace jump + LTD.
    public func applySpike(into state: inout [Double], offset: Int) {
        state[offset] = min(state[offset] + 1.0, sMax)   // s jump
        state[offset + 1] += 1.0                          // x_pre jump
        // LTD: depress weight if post fired recently (x_post > 0)
        weight = max(wMin, weight - aMinus * state[offset + 2])
    }

    /// Post-synaptic spike: post-trace jump + LTP.
    public func applyPostSpike(into state: inout [Double], offset: Int) {
        state[offset + 2] += 1.0                          // x_post jump
        // LTP: potentiate weight if pre fired recently (x_pre > 0)
        weight = min(wMax, weight + aPlus * state[offset + 1])
    }
}
