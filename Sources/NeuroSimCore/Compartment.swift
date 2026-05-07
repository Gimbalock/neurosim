//
//  Compartment.swift
//  NeuroSimCore
//
//  A single electrical compartment of a neuron — one membrane patch with its
//  own potential V, capacitance, and set of voltage-gated channels.
//
//  Conceptually, this is what `HHNeuron` was carrying *internally* before
//  Step 1b. Pulling it out lets us assemble multi-compartment neurons:
//  soma + dendritic tree + axon hillock, etc., each compartment plugging
//  into the same RK4 machinery via the shared state vector.
//
//  State layout for one compartment:
//
//      [ V, gate_0_0, gate_0_1, …, gate_1_0, gate_1_1, … ]
//        ↑    └─ channel 0 gates ─┘  └─ channel 1 gates ─┘
//        membrane potential (mV)
//
//  Channels are ordered as in `channels`. Each channel knows how many gating
//  variables it owns via `IonChannel.stateCount` — Compartment just
//  concatenates them. Conventions of the underlying numerics (units, signs)
//  are inherited from HH: V in mV, time in ms, conductance in mS/cm²,
//  current density in µA/cm², capacitance in µF/cm².
//

import Foundation

public struct ConcentrationDynamic: Codable, Identifiable, Equatable {
    public var id: UUID
    public var ionSymbol: String    // "Ca", "Na", "K", etc.
    public var restingConc: Double  // mM — concentration au repos / équilibre
    public var tauDecay: Double     // ms — constante de temps de la pompe/buffer

    public init(id: UUID = UUID(), ionSymbol: String,
                restingConc: Double, tauDecay: Double = 100) {
        self.id = id; self.ionSymbol = ionSymbol
        self.restingConc = restingConc; self.tauDecay = tauDecay
    }
}

public final class Compartment: Identifiable {

    public let id: UUID
    public var name: String

    /// Specific membrane capacitance (µF/cm²). 1.0 is the canonical squid
    /// HH default and a reasonable starting point for mammalian neurons too.
    public var capacitance: Double

    /// Soma/dendrite diameter (µm). Used to compute membrane area and to
    /// convert between current density (µA/cm²) and absolute current (pA).
    public var diameter: Double

    /// Compartment length (µm). For soma use diameter (sphere approximation).
    /// For dendrites this is the cylinder length.
    public var length: Double

    /// Angle relative to parent compartment in the AxialCoupling tree (radians).
    /// Positive = counter-clockwise. Ignored for soma. Canvas-only, no physics.
    public var displayAngle: Double = 0.0

    /// Membrane area (cm²) — sphere model: A = π·d² for a sphere of diameter d.
    /// 1 µm = 1e-4 cm, so 1 µm² = 1e-8 cm².
    public var area: Double { Double.pi * diameter * diameter * 1e-8 }

    /// Cross-sectional area (cm²) for axial current: A = π·(d/2)².
    public var crossSectionArea: Double { Double.pi * (diameter / 2) * (diameter / 2) * 1e-8 }

    /// Convert a current density (µA/cm²) to absolute current (pA).
    public func densityToPicoAmps(_ density: Double) -> Double {
        density * area * 1e6  // µA/cm² × cm² = µA; × 1e6 = pA
    }

    /// Convert an absolute current (pA) to current density (µA/cm²).
    public func picoAmpsToDensity(_ pA: Double) -> Double {
        (pA * 1e-6) / area   // pA → µA; / cm² = µA/cm²
    }

    /// Voltage-gated channels populating this compartment's membrane.
    /// Order is significant only insofar as it fixes the layout of gates in
    /// the state vector — the physics is symmetric in channel ordering.
    public var channels: [IonChannel]

    /// Ion concentration dynamics tracked in this compartment.
    public var concentrationDynamics: [ConcentrationDynamic] = []

    public init(id: UUID = UUID(),
                name: String = "compartment",
                capacitance: Double = 1.0,
                diameter: Double = 20.0,
                length: Double = 20.0,
                channels: [IonChannel] = [],
                concentrationDynamics: [ConcentrationDynamic] = []) {
        self.id = id
        self.name = name
        self.capacitance = capacitance
        self.diameter = diameter
        self.length = length
        self.channels = channels
        self.concentrationDynamics = concentrationDynamics
    }

    /// Compartment volume (L) — cylinder model: π·(d/2)²·length, d/length in µm.
    public var volume: Double {
        Double.pi * (diameter / 2) * (diameter / 2) * length * 1e-15
    }

    // MARK: - State vector

    /// Total state slots this compartment owns: 1 (V) + Σ channel gate counts + concentration slots.
    public var stateCount: Int {
        1 + channels.reduce(0) { $0 + $1.stateCount } + concentrationDynamics.count
    }

    /// Initial state at a given resting potential — V at v0, every gate at
    /// its steady-state value α/(α+β) for that V.
    public func initialState(restingVoltage v0: Double = -65.0) -> [Double] {
        var s: [Double] = [v0]
        s.reserveCapacity(stateCount)
        for ch in channels {
            s.append(contentsOf: ch.initialState(atVoltage: v0))
        }
        for dyn in concentrationDynamics {
            s.append(dyn.restingConc)
        }
        return s
    }

    /// Total ionic current density (µA/cm²) crossing this compartment's
    /// membrane at the given local state.
    public func ionicCurrent(localState: ArraySlice<Double>) -> Double {
        let v = localState[localState.startIndex]
        var i = 0.0
        var idx = localState.startIndex + 1
        for ch in channels {
            let gates = localState[idx..<(idx + ch.stateCount)]
            i += ch.current(voltage: v, gates: gates)
            idx += ch.stateCount
        }
        return i
    }

    /// Writes derivatives for V and every gate this compartment owns, into
    /// `output` starting at `offset`.
    ///
    /// `iInjected` is the *external* current density (µA/cm²) flowing into
    /// the compartment — sum of any stimulus protocol applied here, of
    /// post-synaptic currents (when this compartment is the post-synaptic
    /// target), and of axial currents from coupled neighbouring
    /// compartments. The compartment itself doesn't know about these
    /// sources; it just trusts the caller to have summed them.
    public func writeDerivatives(localState: ArraySlice<Double>,
                                 iInjected: Double,
                                 into output: inout [Double],
                                 offset: Int) {
        let v = localState[localState.startIndex]
        var iIonic = 0.0

        // Build concentration snapshot for channels that need it.
        // Concentrations live at the end of the compartment's state slice,
        // after V and all gate variables.
        let totalGateSlots = channels.reduce(0) { $0 + $1.stateCount }
        var concentrations: [String: Double] = [:]
        for (i, dyn) in concentrationDynamics.enumerated() {
            concentrations[dyn.ionSymbol] =
                localState[localState.startIndex + 1 + totalGateSlots + i]
        }

        var src = localState.startIndex + 1
        var dst = offset + 1
        for ch in channels {
            let gates = localState[src..<(src + ch.stateCount)]
            iIonic += ch.current(voltage: v, gates: gates)
            ch.gateDerivatives(voltage: v, gates: gates,
                               concentrations: concentrations,
                               into: &output, offset: dst)
            src += ch.stateCount
            dst += ch.stateCount
        }
        // Cm · dV/dt = -I_ionic + I_inj
        output[offset] = (-iIonic + iInjected) / capacitance

        // Concentration dynamics — Euler (concentrations slow, τ >> dt)
        for (i, dyn) in concentrationDynamics.enumerated() {
            let concLocalIdx = localState.startIndex + 1 + totalGateSlots + i
            let conc = localState[concLocalIdx]

            // Sum currents (µA/cm²) from all channels of this ion species
            var iTotal = 0.0
            var gatePtr = localState.startIndex + 1
            for ch in channels {
                if ch.species?.symbol == dyn.ionSymbol {
                    let gates = localState[gatePtr..<(gatePtr + ch.stateCount)]
                    iTotal += ch.current(voltage: v, gates: gates)
                }
                gatePtr += ch.stateCount
            }
            // I_µA = I (µA/cm²) × area (cm²)
            let iAbs_muA = iTotal * area

            guard let sp = IonSpecies.canonical(symbol: dyn.ionSymbol) else {
                output[offset + 1 + totalGateSlots + i] = 0; continue
            }
            let z = Double(sp.valence)
            // d[X]/dt (mM/ms) = -I_µA × 1e-6 / (z × F × vol_L) - ([X] - [X]_rest) / τ
            output[offset + 1 + totalGateSlots + i] =
                -(iAbs_muA * 1e-6) / (z * Nernst.F * volume)
                - (conc - dyn.restingConc) / max(dyn.tauDecay, 0.01)
        }
    }
}
