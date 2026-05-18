//
//  EnergyEngine.swift
//  NeuroSimCore
//
//  One-step advance of the metabolic sub-model for a single neuron soma.
//
//  Physics summary
//  ───────────────
//  Each HH integration step produces ionic currents I_Na and I_K (µA/cm²).
//  These currents physically move ions across the membrane, changing [Na]_i
//  and [K]_i. The Na/K-ATPase pump then actively restores the gradients,
//  consuming ATP. Mitochondria re-synthesise ATP from ADP. Depleted ATP
//  weakens the pump → gradients collapse → Nernst potentials shift toward
//  zero → depolarisation (ATP-failure depolarisation).
//
//  Unit bookkeeping
//  ────────────────
//  Current-to-concentration conversion:
//
//      ΔC [mM] = -I [µA/cm²] · A [cm²] · dt [ms] · K_conv / V [L]
//
//  where K_conv = 1e-9 / F,  (1µA·ms = 1e-9 C; C/mol = F)
//  i.e.  K_conv ≈ 1.036 × 10⁻¹⁴  mol per (µA·cm²·ms·cm⁻²)
//  × 1000 for mM → K_conv = 1.036 × 10⁻¹¹  mM per (µA/cm²·ms·cm²/L)
//
//  Sign: HH I_Na < 0 (inward) → Na entering cell → [Na]_i rises → -I_Na > 0. ✓
//        HH I_K  > 0 (outward) → K leaving cell  → [K]_i drops  → -I_K  < 0. ✓
//
//  Pump model (Na/K-ATPase)
//  ────────────────────────
//  pumpRate [mM/ms] = Jmax · Hill_Na³ · Hill_K² · Hill_ATP
//
//  Per pump cycle (1 ATP hydrolysed): 3 Na out, 2 K in.
//  With pumpRate = ATP hydrolysis rate [mM/ms, intra-volume basis]:
//      Δ[Na]_i = -3 · pumpRate · dt
//      Δ[K]_i  = +2 · pumpRate · dt
//      Δ[Na]_o = +3 · pumpRate · dt · (vol_i/vol_o) = +3 · pumpRate · dt / extRatio
//      Δ[K]_o  = -2 · pumpRate · dt / extRatio
//      Δ[ATP]  = -pumpRate · dt
//
//  Mitochondrial synthesis
//  ───────────────────────
//  J_mito = mitoJmax · [ADP] / (mitoKmADP + [ADP])
//      Δ[ATP] = +J_mito · dt
//      Δ[ADP] = -J_mito · dt
//      Δ[Pi]  = -J_mito · dt
//
//  ATP/ADP/Pi must remain ≥ 0 (clamped after each step).
//

import Foundation

// MARK: - EnergyEngine

public enum EnergyEngine {

    // MARK: Result type

    public struct StepResult {
        /// Updated metabolic + ionic state.
        public let state: EnergyState
        /// Na⁺ Nernst potential for the new state (mV) — write to Na-channel reversals.
        public let eNa: Double
        /// K⁺ Nernst potential for the new state (mV) — write to K-channel reversals.
        public let eK: Double
        /// ATP consumed by the pump this step (mM) — positive.
        public let pumpATPThisStep: Double
    }

    // MARK: Main step

    /// Advance the energy sub-model by one `dt` (ms).
    ///
    /// - Parameters:
    ///   - energyState: current metabolic/ionic snapshot.
    ///   - params: kinetic constants and geometry for this neuron.
    ///   - somaCompartment: soma compartment object (provides area, volume, channels).
    ///   - somaState: corresponding slice of the global state vector (after HH step).
    ///   - dt: integration step in ms (same as Simulator.dt).
    /// - Returns: new state + Nernst potentials to feed back into channel reversals.
    public static func step(energyState es: EnergyState,
                            params p: EnergyParams,
                            somaCompartment comp: Compartment,
                            somaState slice: ArraySlice<Double>,
                            dt: Double) -> StepResult {

        let area = comp.area    // cm²
        let volI = comp.volume  // L (intracellular)

        // ── 1. Ion currents from HH channels ─────────────────────────────────
        //    Sum I_Na and I_K from channels declaring the matching species.
        let v = slice[slice.startIndex]
        var iNa = 0.0   // µA/cm² — net Na current (positive = outward)
        var iK  = 0.0   // µA/cm² — net K current

        var gatePtr = slice.startIndex + 1
        for ch in comp.channels {
            let end = gatePtr + ch.stateCount
            let gates = slice[gatePtr..<end]
            let sym = ch.species?.symbol
            if sym == "Na" {
                iNa += ch.current(voltage: v, gates: gates)
            } else if sym == "K" {
                iK += ch.current(voltage: v, gates: gates)
            }
            gatePtr = end
        }

        // ── 2. Δconcentration from ionic currents ────────────────────────────────
        //    ΔC [mM] = -I[µA/cm²] · area[cm²] · dt[ms] · 1e-6 / (F[C/mol] · vol[L])
        //    Sign: inward Na (iNa < 0) → [Na]_i rises; outward K (iK > 0) → [K]_i falls.
        let ionConv = area * dt * 1e-6 / (Nernst.F * max(volI, 1e-18))

        var naI = es.naI - iNa * ionConv
        var kI  = es.kI  - iK  * ionConv

        // Extracellular: clamped (blood/glia) or free (ischemia / no buffering).
        // When free, ions leaving the cell enter the extracellular space scaled by
        // vol_i / vol_o = 1 / extracellularRatio (conservation of moles).
        var naO = es.naO
        var kO  = es.kO
        if !p.clampExtracellular {
            let extR = max(p.extracellularRatio, 0.01)
            naO += iNa * ionConv / extR   // Na leaving cell → rises outside (sign flips)
            kO  += iK  * ionConv / extR   // K  leaving cell → rises outside
            naO  = max(naO, 0.1)
            kO   = max(kO,  0.1)
        }

        // ── 3. Na/K pump ──────────────────────────────────────────────────────
        let hillNa  = hillCoop(x: max(naI, 0), km: p.pumpKmNa, n: 3)
        let hillK   = hillCoop(x: max(kO, 0),  km: p.pumpKmK,  n: 2)
        let hillATP = hill(x: max(es.atp, 0),  km: p.pumpKmATP)
        let pumpDemand = p.pumpJmax * hillNa * hillK          // unlimited ATP demand (mM/ms)
        let pumpRate   = pumpDemand * hillATP                 // ATP-limited actual rate (mM/ms)

        let pumpDt = pumpRate * dt
        naI -= 3.0 * pumpDt     // 3 Na pumped out of cell
        kI  += 2.0 * pumpDt     // 2 K pumped into cell
        if !p.clampExtracellular {
            let extR = max(p.extracellularRatio, 0.01)
            naO += 3.0 * pumpDt / extR  // 3 Na enter extracellular space
            kO  -= 2.0 * pumpDt / extR  // 2 K leave extracellular space
            naO  = max(naO, 0.1)
            kO   = max(kO,  0.1)
        }
        var atp = es.atp - pumpDt      // 1 ATP per cycle
        var adp = es.adp + pumpDt
        var pi  = es.pi  + pumpDt

        // ── 4. Mitochondrial ATP synthesis ────────────────────────────────────
        let jMito = p.mitoJmax * hill(x: max(adp, 0), km: p.mitoKmADP)
        let mitoDt = jMito * dt
        atp += mitoDt
        adp -= mitoDt
        pi  -= mitoDt

        // ── 5. Basal ATP consumption ──────────────────────────────────────────
        let basalDt = p.basalATPRate * dt
        atp -= basalDt
        adp += basalDt
        pi  += basalDt

        // ── 6. Clamp to physical bounds ───────────────────────────────────────
        naI = max(naI, 0.1);   kI  = max(kI,  0.1)
        // naO and kO are constants — no clamp needed.
        atp = max(atp, 0.0);   adp = max(adp, 0.0);   pi = max(pi, 0.0)

        // ── 7. Build result ───────────────────────────────────────────────────
        let newState = EnergyState(
            naI: naI, kI: kI, naO: naO, kO: kO,
            atp: atp, adp: adp, pi: pi,
            atpConsumedTotal: es.atpConsumedTotal + pumpDt + basalDt,
            pumpRateLast: pumpRate, pumpDemandLast: pumpDemand)

        return StepResult(
            state: newState,
            eNa: newState.eNa,
            eK:  newState.eK,
            pumpATPThisStep: pumpDt + basalDt)
    }

    // MARK: - Hill functions

    /// Simple Michaelis-Menten (Hill n=1).
    @inline(__always)
    private static func hill(x: Double, km: Double) -> Double {
        x / (km + x)
    }

    /// Cooperative Hill function for integer n (n=2 or n=3).
    @inline(__always)
    private static func hillCoop(x: Double, km: Double, n: Int) -> Double {
        let xn  = pow(x,  Double(n))
        let kmn = pow(km, Double(n))
        return xn / (kmn + xn)
    }
}
