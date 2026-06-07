//
//  HinesSolver.swift
//  NeuroSimCore
//
//  Intégrateur câble implicite (méthode de Hines, 1984) pour les neurones
//  multi-compartiments avec couplages axiaux.
//
//  Principe
//  ────────
//  Les intégrateurs explicites (Euler, Rush-Larsen) appliqués à l'équation
//  câble deviennent instables dès que g_axial·dt/Cm > 1. Pour des segments
//  physiologiques (d=5 µm, L=5 µm → g≈5 000 mS/cm²) et dt=0.05 ms, le
//  facteur d'amplification est ×250 par pas → divergence immédiate.
//
//  La méthode de Hines résout la partie câble de façon implicite :
//
//    (Cm_i/dt + Σg_ij)·V_i^{n+1} - Σg_ij·V_j^{n+1} = Cm_i/dt·V_i^n + (I_inj_i - I_ionique_i)
//
//  Pour une chaîne linéaire de N compartiments, ce système tridiagonal est
//  résolu en O(N) par l'algorithme de Thomas. La solution est inconditionnellement
//  stable quel que soit dt (la matrice est symétrique définie positive).
//
//  Décomposition de l'opérateur
//  ─────────────────────────────
//  1. Portes (Rush-Larsen analytique)  — inchangé, stable à tout dt
//  2. Tensions (Thomas implicite)       — remplace l'Euler explicite de RL Phase 2
//  3. Concentrations + synapses (Euler) — variables lentes, inchangé
//
//  Remarque : pour les neurones à 1 compartiment ou dont les couplages forment
//  un arbre ramifié non-linéaire, on retombe sur l'Euler explicite pour les
//  tensions (Rush-Larsen standard). L'extension à l'arbre complet (algorithme
//  de Hines généralisé) est laissée comme amélioration future.
//

import Foundation

// MARK: - Chain data

/// Pre-computed chain topology for one multi-compartment neuron.
/// Rebuilt at each step (can be cached as future optimisation).
///
/// Coupling conductances are stored PER COMPARTMENT END because adjacent
/// compartments may have different membrane areas (soma d=20 µm ↔ axon d=5 µm).
/// The same absolute axial conductance G [mS] yields different densities:
///
///     gForward[i]  = G / A_i     (density for comp[i], driving to the right)
///     gBackward[i] = G / A_{i+1} (density for comp[i+1], receiving from the left)
///
/// For equal-diameter compartments gForward[i] == gBackward[i].
struct CableChain {
    let comps:     [Compartment]
    let vIdx:      [Int]       // state-vector index of V_i
    let gForward:  [Double]    // coupling density at comp[i] toward comp[i+1], length N-1
    let gBackward: [Double]    // coupling density at comp[i+1] from comp[i],   length N-1
}

// MARK: - HinesCable integrator

public enum HinesCable {

    // ── Chain detection ───────────────────────────────────────────────────────

    /// Build a `CableChain` if the neuron's axial couplings form a simple linear
    /// path (no branching). Returns nil for single-compartment neurons or trees.
    ///
    /// Complexity: O(N + M) where N = compartments, M = couplings.
    static func buildChain(neuron: HHNeuron, network: Network) -> CableChain? {
        let n = neuron.compartments.count
        guard n >= 2,
              !neuron.axialCouplings.isEmpty,
              neuron.axialCouplings.count == n - 1
        else { return nil }

        // Adjacency: compID → [(neighbourID, coupling)] — store the coupling itself
        // so we can determine which end 'current' is (A or B) and pick the right density.
        var adj = [UUID: [(UUID, AxialCoupling)]](minimumCapacity: n)
        for coup in neuron.axialCouplings {
            adj[coup.compartmentA, default: []].append((coup.compartmentB, coup))
            adj[coup.compartmentB, default: []].append((coup.compartmentA, coup))
        }

        // A simple chain has exactly 2 endpoints (degree 1) and all others degree 2.
        let endpoints = neuron.compartments.filter { (adj[$0.id]?.count ?? 0) == 1 }
        guard endpoints.count == 2 else { return nil }

        // Walk from the first endpoint and build ordered arrays.
        var compByID = [UUID: Compartment](minimumCapacity: n)
        for c in neuron.compartments { compByID[c.id] = c }

        var comps        = [Compartment](); comps.reserveCapacity(n)
        var vIdxArr      = [Int]();         vIdxArr.reserveCapacity(n)
        var gForwardArr  = [Double]();      gForwardArr.reserveCapacity(n - 1)
        var gBackwardArr = [Double]();      gBackwardArr.reserveCapacity(n - 1)

        var current = endpoints[0].id
        var prev: UUID? = nil

        for _ in 0..<n {
            guard let comp = compByID[current],
                  let vi   = network.voltageIndex(ofCompartment: current)
            else { return nil }

            comps.append(comp)
            vIdxArr.append(vi)

            // Move to next uncommon neighbour, extract per-end conductances.
            if let (nextID, coup) = adj[current]?.first(where: { $0.0 != prev }) {
                // gForward[i]  = density at 'current' for current→next flow
                // gBackward[i] = density at 'next'    for next←current flow
                let gCurrent: Double
                let gNext:    Double
                if current == coup.compartmentA {
                    gCurrent = coup.conductance
                    gNext    = coup.conductanceFarEnd ?? coup.conductance
                } else {
                    gCurrent = coup.conductanceFarEnd ?? coup.conductance
                    gNext    = coup.conductance
                }
                gForwardArr.append(gCurrent)
                gBackwardArr.append(gNext)
                prev    = current
                current = nextID
            } else {
                break   // reached the other endpoint
            }
        }

        guard comps.count == n else { return nil }
        return CableChain(comps: comps, vIdx: vIdxArr,
                          gForward: gForwardArr, gBackward: gBackwardArr)
    }

    // ── Main step ─────────────────────────────────────────────────────────────

    /// Full Hines integration step.
    ///
    /// - Phase 1: `computeDerivatives` at t (for gate derivatives)
    /// - Phase 2: gate update via Rush-Larsen exponential formula
    /// - Phase 3: `computeDerivatives` at t+dt with updated gates (for ionic/stimulus RHS)
    /// - Phase 4: voltage update — Thomas implicit solve for chain neurons,
    ///            explicit Euler for the rest
    /// - Phase 5: concentrations + synapses (Euler, same as Rush-Larsen)
    public static func step(network: Network,
                            state:   inout [Double],
                            time:    Double,
                            dt:      Double,
                            deriv:   inout [Double],
                            deriv2:  inout [Double]) {

        // Pre-build chain topology for all cable neurons.
        var chains = [UUID: CableChain]()
        for neuron in network.neurons
            where neuron.compartments.count > 1 && !neuron.axialCouplings.isEmpty {
            if let cd = buildChain(neuron: neuron, network: network) {
                chains[neuron.id] = cd
            }
        }

        // ── Phase 1: derivatives at current state ────────────────────────────
        network.computeDerivatives(state: state, time: time, into: &deriv)

        // ── Phase 2: gate update (Rush-Larsen analytical) ────────────────────
        for neuron in network.neurons {
            for comp in neuron.compartments {
                guard let vIdx = network.voltageIndex(ofCompartment: comp.id)
                else { continue }
                let v = state[vIdx]
                var slot = vIdx + 1
                for ch in comp.channels {
                    if let gated = ch as? HHGated {
                        for gi in 0..<ch.stateCount {
                            let xInf = gated.resolvedGateInf(gi, voltage: v)
                            let tau  = max(gated.resolvedGateTau(gi, voltage: v), 1e-12)
                            let x    = state[slot + gi]
                            state[slot + gi] = xInf + (x - xInf) * exp(-dt / tau)
                        }
                    } else {
                        for gi in 0..<ch.stateCount {
                            state[slot + gi] += dt * deriv[slot + gi]
                        }
                    }
                    slot += ch.stateCount
                }
            }
        }

        // ── Phase 3: re-evaluate with updated gates ──────────────────────────
        network.computeDerivatives(state: state, time: time + dt, into: &deriv2)

        // ── Phase 4: voltage update ──────────────────────────────────────────
        for neuron in network.neurons {
            if let chain = chains[neuron.id] {
                // Implicit Thomas solve for chain neurons.
                thomasSolve(chain: chain, state: &state, deriv2: deriv2, dt: dt)
            } else {
                // Single-compartment or branching tree: Euler for V (same as Rush-Larsen).
                for comp in neuron.compartments {
                    guard let vi = network.voltageIndex(ofCompartment: comp.id) else { continue }
                    state[vi] += dt * deriv2[vi]
                }
            }
        }

        // ── Phase 5: concentrations (Euler) ──────────────────────────────────
        for neuron in network.neurons {
            for comp in neuron.compartments {
                guard !comp.concentrationDynamics.isEmpty,
                      let vIdx = network.voltageIndex(ofCompartment: comp.id)
                else { continue }
                let totalGates = comp.channels.reduce(0) { $0 + $1.stateCount }
                for i in comp.concentrationDynamics.indices {
                    let idx = vIdx + 1 + totalGates + i
                    state[idx] += dt * deriv2[idx]
                }
            }
        }

        // ── Phase 6: synaptic state (Euler) ──────────────────────────────────
        for syn in network.synapses {
            guard let off = network.stateOffset(ofSynapse: syn.id) else { continue }
            for k in 0..<syn.stateCount { state[off + k] += dt * deriv[off + k] }
        }
    }

    // ── Thomas algorithm ──────────────────────────────────────────────────────

    /// Solve the implicit cable equation for one linear chain of N compartments.
    ///
    /// System (generally asymmetric tridiagonal, row i):
    ///
    ///   d[i]·V_new[i] − gB[i-1]·V_new[i-1] − gF[i]·V_new[i+1] = b[i]
    ///
    /// where gF = gForward, gB = gBackward, and:
    ///
    ///   d[i]  = Cm_i/dt + gB[i-1] + gF[i]    (diagonal, mS/cm²)
    ///   b[i]  = Cm_i/dt·V_i + Cm_i·(dV/dt)_total − I_axial_explicit_i
    ///
    /// gForward[i]  = axial conductance density at comp[i] toward comp[i+1]
    /// gBackward[i] = axial conductance density at comp[i+1] from comp[i]
    ///
    /// These differ when soma and axon have different diameters: the same
    /// absolute G [mS] yields g_soma = G/A_soma and g_axon = G/A_axon,
    /// which can differ by (d_soma/d_axon)² = up to 16× for d_soma=20 µm,
    /// d_axon=5 µm.
    ///
    /// The matrix remains strictly diagonally dominant (all diagonal entries
    /// > sum of off-diagonals) because gF[i] × A_i = gB[i] × A_{i+1} = G_abs.
    /// Thomas is therefore numerically stable even for the asymmetric form.
    ///
    /// Complexity: O(N).
    private static func thomasSolve(chain:  CableChain,
                                    state:  inout [Double],
                                    deriv2: [Double],
                                    dt:     Double) {
        let N    = chain.comps.count
        let vIdx = chain.vIdx
        let gF   = chain.gForward    // length N-1: density at comp[i] toward comp[i+1]
        let gB   = chain.gBackward   // length N-1: density at comp[i+1] from comp[i]

        // Current voltages after gate update
        let V = vIdx.map { state[$0] }      // [Double], length N

        // Explicit axial currents using per-end densities.
        // Current into comp[i] from right:   gF[i] × (V[i+1] − V[i])
        // Current into comp[i+1] from left: −gB[i] × (V[i+1] − V[i])
        var iAxial = [Double](repeating: 0.0, count: N)
        for i in 0..<(N - 1) {
            let dV        = V[i + 1] - V[i]
            iAxial[i]     += gF[i] * dV
            iAxial[i + 1] -= gB[i] * dV
        }

        // Assemble tridiagonal: diagonal d[], RHS b[].
        //
        // Units:  Cm [µF/cm²] / dt [ms] = mS/cm²
        //         Cm [µF/cm²] × deriv2 [mV/ms] = µA/cm²
        //         iAxial [µA/cm²]  →  b in µA/cm²  ✓
        var d = [Double](repeating: 0.0, count: N)
        var b = [Double](repeating: 0.0, count: N)

        for i in 0..<N {
            let cm   = chain.comps[i].capacitance   // µF/cm²
            let cmDt = cm / dt                      // mS/cm²
            let gL   = i > 0     ? gB[i - 1] : 0.0  // density at i from left coupling
            let gR   = i < N - 1 ? gF[i]     : 0.0  // density at i toward right coupling
            d[i] = cmDt + gL + gR
            b[i] = cmDt * V[i] + cm * deriv2[vIdx[i]] - iAxial[i]
        }

        // ── Asymmetric Thomas forward elimination ─────────────────────────────
        //
        // Row i-1 (after elimination): d'[i-1]·V[i-1] − gF[i-1]·V[i] = b'[i-1]
        // Row i: −gB[i-1]·V[i-1] + d[i]·V[i] − gF[i]·V[i+1] = b[i]
        //
        // Multiplier w = gB[i-1] / d'[i-1]
        //   d'[i]   = d[i]   − w·gF[i-1]        (pivot update)
        //   b'[i]   = b[i]   + w·b'[i-1]         (RHS update)
        //
        // Note: for equal-diameter compartments gB[i-1] == gF[i-1] == g,
        // so the formula reduces to the standard symmetric Thomas:
        //   d'[i] = d[i] − g²/d'[i-1]  ✓
        for i in 1..<N {
            let w = gB[i - 1] / d[i - 1]
            d[i] = d[i] - w * gF[i - 1]
            b[i] = b[i] + w * b[i - 1]
        }

        // ── Back substitution ─────────────────────────────────────────────────
        // Row i (after forward): d'[i]·V[i] − gF[i]·V[i+1] = b'[i]
        var V_new = [Double](repeating: 0.0, count: N)
        V_new[N - 1] = b[N - 1] / d[N - 1]
        for i in stride(from: N - 2, through: 0, by: -1) {
            V_new[i] = (b[i] + gF[i] * V_new[i + 1]) / d[i]
        }

        // Write back to global state vector.
        for i in 0..<N {
            state[vIdx[i]] = V_new[i]
        }
    }
}
