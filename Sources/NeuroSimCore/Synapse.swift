//
//  Synapse.swift
//  NeuroSimCore
//
//  Synaptic connections between neurons. Two families ship by default:
//  - ChemicalSynapse: spike-triggered, single- or double-exponential conductance.
//  - GapJunction:     instantaneous electrical coupling (stateless).
//
//  Synapses live in the network's global state vector alongside neuron states.
//  Discrete spike events are applied as direct jumps on the synaptic gating
//  variable by the Simulator.
//

import Foundation

public protocol Synapse: AnyObject {
    var id: UUID { get }
    var preNeuronID: UUID { get }
    var postNeuronID: UUID { get }

    /// Optional explicit target compartment within the post-synaptic neuron.
    /// `nil` (default) means "the post neuron's soma" — the Network resolves
    /// the actual compartment when routing currents. Set this to a specific
    /// dendritic compartment to model dendritic synapses (EPSPs / IPSPs that
    /// land away from the spike-initiation zone and are filtered by the
    /// axial coupling on their way to the soma).
    var postCompartmentID: UUID? { get set }

    /// Number of state variables this synapse owns in the global state vector.
    var stateCount: Int { get }

    /// Steady-state initial values for the synapse's gating variables.
    func initialState() -> [Double]

    /// Post-synaptic current density (µA/cm²) given the synapse's state slice
    /// and the pre/post membrane potentials.
    func currentToPost(state: ArraySlice<Double>, vPre: Double, vPost: Double) -> Double

    /// Writes the time-derivatives of this synapse's state variables into
    /// `output` starting at `offset`.
    func writeDerivatives(state: ArraySlice<Double>,
                          vPre: Double,
                          vPost: Double,
                          into output: inout [Double],
                          offset: Int)

    /// Discrete state update applied when a pre-synaptic spike fires.
    /// Default: no-op (suitable for stateless synapses like gap junctions).
    func applySpike(into state: inout [Double], offset: Int)
}

public extension Synapse {
    func applySpike(into state: inout [Double], offset: Int) {}
}

// MARK: - Chemical synapse (single-exponential conductance)

/// Spike-triggered chemical synapse with exponential conductance decay.
/// On each pre-synaptic spike, the gating variable `s` jumps by 1 (clamped to
/// [0, sMax]); between spikes it decays as `ds/dt = -s/τ`.
/// Post-synaptic current: `I = gMax * s * (V_post - E_rev)`.
///
/// Common reversal potentials:
///   AMPA / nicotinic    →  E_rev =   0 mV  (excitatory)
///   GABA_A              →  E_rev = -75 mV  (inhibitory)
///   GABA_B (slow)       →  E_rev = -90 mV
public final class ChemicalSynapse: Synapse {
    public let id: UUID
    public var preNeuronID: UUID
    public var postNeuronID: UUID
    public var postCompartmentID: UUID?

    public var gMax: Double      // mS/cm²
    public var reversal: Double  // mV
    public var tauDecay: Double  // ms
    public var sMax: Double      // saturation cap on gating variable

    public init(id: UUID = UUID(),
                from pre: UUID,
                to post: UUID,
                onCompartment compartment: UUID? = nil,
                gMax: Double = 0.1,
                reversal: Double = 0.0,
                tauDecay: Double = 5.0,
                sMax: Double = 1.0) {
        self.id = id
        self.preNeuronID = pre
        self.postNeuronID = post
        self.postCompartmentID = compartment
        self.gMax = gMax
        self.reversal = reversal
        self.tauDecay = tauDecay
        self.sMax = sMax
    }

    public var stateCount: Int { 1 }

    public func initialState() -> [Double] { [0.0] }

    public func currentToPost(state: ArraySlice<Double>,
                              vPre: Double,
                              vPost: Double) -> Double {
        let s = state[state.startIndex]
        return gMax * s * (vPost - reversal)
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

// MARK: - Gap junction (electrical coupling)

/// Bidirectional electrical coupling: `I_post = g * (V_post - V_pre)`.
/// Stateless — no gating variables.
public final class GapJunction: Synapse {
    public let id: UUID
    public var preNeuronID: UUID
    public var postNeuronID: UUID
    public var postCompartmentID: UUID?
    public var conductance: Double // mS/cm²

    public init(id: UUID = UUID(),
                from pre: UUID,
                to post: UUID,
                onCompartment compartment: UUID? = nil,
                conductance: Double = 0.05) {
        self.id = id
        self.preNeuronID = pre
        self.postNeuronID = post
        self.postCompartmentID = compartment
        self.conductance = conductance
    }

    public var stateCount: Int { 0 }

    public func initialState() -> [Double] { [] }

    public func currentToPost(state: ArraySlice<Double>,
                              vPre: Double,
                              vPost: Double) -> Double {
        // Standard gap junction convention: positive current when V_post > V_pre
        // means current *leaves* the post-synaptic compartment, hyperpolarizing it.
        conductance * (vPost - vPre)
    }

    public func writeDerivatives(state: ArraySlice<Double>,
                                 vPre: Double,
                                 vPost: Double,
                                 into output: inout [Double],
                                 offset: Int) {
        // No state.
    }
}
