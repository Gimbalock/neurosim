//
//  HHNeuron.swift
//  NeuroSimCore
//
//  A Hodgkin-Huxley-style neuron, modelled as one or more electrically
//  coupled `Compartment`s. The single-compartment case is the historical
//  default and remains the path of least friction:
//
//      let neuron = HHNeuron(name: "soma")        // one HH compartment
//
//  Multi-compartment neurons (soma + dendritic tree, soma + axon hillock,
//  passive cable…) are assembled by passing a list of `Compartment`s and
//  the `AxialCoupling`s linking them:
//
//      let soma = Compartment(name: "soma", channels: HHNeuron.defaultChannels())
//      let dend = Compartment(name: "dend", channels: [LeakChannel()])
//      let neuron = HHNeuron(
//          name: "pyramidal",
//          compartments: [soma, dend],
//          couplings: [AxialCoupling(between: soma.id, and: dend.id, conductance: 1.0)]
//      )
//
//  One compartment is designated the **soma** — it's where spike detection
//  happens (used by `Simulator`), where stimulus protocols land by default,
//  and where post-synaptic currents arrive. The first compartment is the
//  soma unless an explicit one is passed.
//
//  State-vector layout for a multi-compartment neuron:
//
//      [ comp_0 state | comp_1 state | … ]
//
//  with each compartment laying out its own state per `Compartment.swift`.
//  Per-compartment offsets within the neuron's slice are recomputed lazily
//  whenever derivatives are evaluated.
//

import Foundation

public final class HHNeuron: Identifiable {

    public let id: UUID
    public var name: String

    /// All compartments belonging to this neuron, in declaration order.
    /// Mutating this array directly bypasses the `Network`'s state-layout
    /// bookkeeping — the network won't notice until the next structural
    /// mutation routed through it. Add/remove via `Network` for safety.
    public var compartments: [Compartment]

    /// Electrical couplings between pairs of this neuron's compartments.
    public var axialCouplings: [AxialCoupling]

    /// Identifier of the compartment treated as the spike-detection point
    /// (and the default landing zone for stimulus and synaptic input).
    public var somaCompartmentID: UUID

    /// Position in the network editor canvas (UI-only; ignored by the engine).
    public var positionX: Double = 0
    public var positionY: Double = 0

    /// Metabolic energy sub-model parameters. Disabled by default — enabling
    /// activates concentration tracking, Na/K pump, and mitochondrial ATP synthesis.
    public var energyParams: EnergyParams = EnergyParams()

    // MARK: - Initialisers

    /// Single-compartment initialiser — backward-compatible with the
    /// pre-Step-1b API. Creates one soma compartment with the given
    /// channels (defaults to the classical squid HH set).
    public init(id: UUID = UUID(),
                name: String = "Neuron",
                capacitance: Double = 1.0,
                channels: [IonChannel]? = nil) {
        self.id = id
        self.name = name
        let soma = Compartment(name: "soma",
                               capacitance: capacitance,
                               channels: channels ?? HHNeuron.defaultChannels())
        self.compartments = [soma]
        self.axialCouplings = []
        self.somaCompartmentID = soma.id
    }

    /// Multi-compartment initialiser. The first compartment is the soma
    /// unless an explicit `soma` is passed.
    public init(id: UUID = UUID(),
                name: String,
                compartments: [Compartment],
                couplings: [AxialCoupling] = [],
                soma somaID: UUID? = nil) {
        precondition(!compartments.isEmpty,
                     "A neuron must have at least one compartment.")
        if let s = somaID {
            precondition(compartments.contains(where: { $0.id == s }),
                         "The soma compartment ID must match one of the supplied compartments.")
        }
        self.id = id
        self.name = name
        self.compartments = compartments
        self.axialCouplings = couplings
        self.somaCompartmentID = somaID ?? compartments[0].id
    }

    /// Default channel set: classical squid HH (Na, K, leak).
    public static func defaultChannels() -> [IonChannel] {
        [SodiumChannel(), PotassiumChannel(), LeakChannel()]
    }

    // MARK: - Soma access (backward-compat shims for the single-compartment API)

    /// The soma compartment — falls back to the first compartment if the
    /// declared `somaCompartmentID` no longer matches any compartment
    /// (defensive; should not happen in normal use).
    public var soma: Compartment {
        compartments.first(where: { $0.id == somaCompartmentID }) ?? compartments[0]
    }

    /// Channels of the soma compartment. Reading or mutating this aliases
    /// the soma's `channels` directly, preserving the pre-Step-1b API.
    public var channels: [IonChannel] {
        get { soma.channels }
        set { soma.channels = newValue }
    }

    /// Capacitance of the soma compartment — back-compat shim.
    public var capacitance: Double {
        get { soma.capacitance }
        set { soma.capacitance = newValue }
    }

    // MARK: - State vector

    /// Total state slots this neuron contributes to the global state vector.
    public var stateCount: Int {
        compartments.reduce(0) { $0 + $1.stateCount }
    }

    /// Initial state at a given resting potential, compartment by compartment.
    public func initialState(restingVoltage v0: Double = -65.0) -> [Double] {
        var s: [Double] = []
        s.reserveCapacity(stateCount)
        for comp in compartments {
            s.append(contentsOf: comp.initialState(restingVoltage: v0))
        }
        return s
    }

    /// Total ionic current density (µA/cm²) summed across the soma — kept
    /// for any caller still inspecting "the neuron's ionic current". For
    /// multi-compartment neurons this is *not* the right summary metric;
    /// inspect compartments individually if that matters.
    public func ionicCurrent(localState: ArraySlice<Double>) -> Double {
        // The soma's local slice is the first `soma.stateCount` entries.
        let off = somaOffsetWithinNeuronSlice
        let start = localState.startIndex + off
        let end = start + soma.stateCount
        return soma.ionicCurrent(localState: localState[start..<end])
    }

    /// Writes derivatives for every compartment of this neuron into
    /// `output`, with axial currents between this neuron's compartments
    /// applied internally.
    ///
    /// `injectedByCompartment` maps each compartment ID to its external
    /// injected current density (µA/cm²) — sum of any stimulus protocol
    /// applied to that compartment plus any post-synaptic currents
    /// landing on it. Compartments not present in the dictionary receive
    /// zero external injection (they still receive axial currents from
    /// neighbours, computed here). The Network builds this dictionary
    /// before calling.
    public func writeDerivatives(localState: ArraySlice<Double>,
                                 injectedByCompartment: [UUID: Double],
                                 into output: inout [Double],
                                 offset: Int) {
        let n = compartments.count

        // Fast path: single-compartment neuron (the common case).
        // No axial couplings possible, no dict lookups needed.
        if n == 1 {
            let comp = compartments[0]
            let iInj = injectedByCompartment[comp.id] ?? 0
            comp.writeDerivatives(localState: localState,
                                  iInjected: iInj,
                                  into: &output,
                                  offset: offset)
            return
        }

        // Multi-compartment path — use parallel Int/Double arrays instead
        // of UUID-keyed dictionaries to avoid per-call heap allocations.

        // 1. Compute per-compartment offsets and read voltages in one pass.
        var offsets  = [Int](repeating: 0, count: n)
        var voltages = [Double](repeating: 0, count: n)
        var cursor = 0
        for i in 0..<n {
            offsets[i]  = cursor
            voltages[i] = localState[localState.startIndex + cursor]
            cursor += compartments[i].stateCount
        }

        // 2. Axial currents. Linear search for compartment indices is
        //    negligible for typical compartment counts (2-5).
        var iAxial = [Double](repeating: 0, count: n)
        for coup in axialCouplings {
            var iA = -1, iB = -1
            for i in 0..<n {
                if compartments[i].id == coup.compartmentA { iA = i }
                else if compartments[i].id == coup.compartmentB { iB = i }
            }
            guard iA >= 0, iB >= 0 else { continue }
            let diff = coup.conductance * (voltages[iB] - voltages[iA])
            iAxial[iA] += diff
            iAxial[iB] -= diff
        }

        // 3. Write per-compartment derivatives.
        for i in 0..<n {
            let comp = compartments[i]
            let localOff = offsets[i]
            let sliceStart = localState.startIndex + localOff
            let sliceEnd = sliceStart + comp.stateCount
            let iInj = iAxial[i] + (injectedByCompartment[comp.id] ?? 0)
            comp.writeDerivatives(localState: localState[sliceStart..<sliceEnd],
                                  iInjected: iInj,
                                  into: &output,
                                  offset: offset + localOff)
        }
    }

    /// Offset of the soma's local slice within this neuron's slice.
    /// Recomputed each time — cheap, and avoids cache-invalidation bugs
    /// when `compartments` is mutated.
    private var somaOffsetWithinNeuronSlice: Int {
        var off = 0
        for comp in compartments {
            if comp.id == somaCompartmentID { return off }
            off += comp.stateCount
        }
        return 0  // soma not found — soma fallback returns compartments[0] anyway
    }
}
