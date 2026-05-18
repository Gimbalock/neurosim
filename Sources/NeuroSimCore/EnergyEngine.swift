//
//  EnergyEngine.swift
//  NeuroSimCore
//
//  One-step advance of the metabolic sub-model for a single neuron soma.
//
//  Physics summary
//  ───────────────
//  Each HH integration step produces ionic currents I_Na, I_K, and I_Ca (µA/cm²).
//  These currents physically move ions across the membrane, changing intracellular
//  concentrations. ATP-dependent pumps in `EnergyParams.pumps` then actively restore
//  gradients, consuming ATP. Mitochondria re-synthesise ATP from ADP. Depleted ATP
//  weakens pumps → gradients collapse → Nernst potentials shift toward zero →
//  depolarisation (ATP-failure depolarisation).
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
//        HH I_Ca < 0 (inward)  → Ca entering cell → [Ca]_i rises → -I_Ca > 0. ✓
//
//  Pump model (generic ATPPump)
//  ────────────────────────────
//  pumpRate [mM/ms] = jMax · Hill_ion^n · Hill_ion2^n2 · Hill_ATP
//
//  Per pump cycle (1 ATP hydrolysed):
//    primary ion: stoichiometry ions moved in direction pumpOut
//    secondary ion (if any): stoichiometry2 ions moved in direction pumpOut2
//
//  Calcium buffering
//  ─────────────────
//  Free [Ca²⁺]_i is a tiny fraction of total Ca flux — most is rapidly buffered.
//  The buffer ratio κ = [Ca_total]/[Ca_free] ≈ 100 in typical neurons.
//  So only 1/(1+κ) of the Ca flux changes [Ca²⁺]_i:
//    Δ[Ca²⁺]_i = -I_Ca · ionConv / (1 + κ)
//
//  ER calcium dynamics
//  ───────────────────
//  SERCA pumps Ca from cytoplasm into ER lumen (pumpToER=true).
//  Passive ER leak returns Ca slowly: J_leak = erLeakRate · [Ca]_ER
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
        /// ATP consumed by all pumps + basal this step (mM) — positive.
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
        //    Sum I_Na, I_K, I_Ca from channels declaring the matching species.
        let v = slice[slice.startIndex]
        var iNa = 0.0   // µA/cm² — net Na current (positive = outward)
        var iK  = 0.0   // µA/cm² — net K current
        var iCa = 0.0   // µA/cm² — net Ca current

        var gatePtr = slice.startIndex + 1
        for ch in comp.channels {
            let end = gatePtr + ch.stateCount
            let gates = slice[gatePtr..<end]
            let sym = ch.species?.symbol
            if sym == "Na" {
                iNa += ch.current(voltage: v, gates: gates)
            } else if sym == "K" {
                iK += ch.current(voltage: v, gates: gates)
            } else if sym == "Ca" {
                iCa += ch.current(voltage: v, gates: gates)
            }
            gatePtr = end
        }

        // ── 2. Δconcentration from ionic currents ────────────────────────────────
        //    ΔC [mM] = -I[µA/cm²] · area[cm²] · dt[ms] · 1e-6 / (F[C/mol] · vol[L])
        //    Sign: inward Na (iNa < 0) → [Na]_i rises; outward K (iK > 0) → [K]_i falls.
        let ionConv = area * dt * 1e-6 / (Nernst.F * max(volI, 1e-18))

        var naI = es.naI - iNa * ionConv
        var kI  = es.kI  - iK  * ionConv

        // Ca²⁺: only free fraction changes (buffer ratio κ divides the flux)
        var caI = es.caI - iCa * ionConv / (1.0 + p.caBufferKappa)
        caI = max(caI, 1e-6)

        // Extracellular: clamped (blood/glia) or free (ischemia / no buffering).
        // When free, ions leaving the cell enter the extracellular space scaled by
        // vol_i / vol_o = 1 / extracellularRatio (conservation of moles).
        var naO = es.naO
        var kO  = es.kO
        // caO is always clamped (extracellular Ca reservoir is vast)
        let caO = es.caO
        var caER = es.caER

        if !p.clampExtracellular {
            let extR = max(p.extracellularRatio, 0.01)
            naO += iNa * ionConv / extR   // Na leaving cell → rises outside (sign flips)
            kO  += iK  * ionConv / extR   // K  leaving cell → rises outside
            naO  = max(naO, 0.1)
            kO   = max(kO,  0.1)
        }

        // ── 3. ATP pumps ──────────────────────────────────────────────────────
        var atp = es.atp
        var adp = es.adp
        var pi  = es.pi

        var totalPumpATP = 0.0  // accumulated ATP cost from all pumps this dt

        // Track Na/K pump stats for backward-compat with EnergyView
        var nakPumpRate:   Double = 0
        var nakPumpDemand: Double = 0

        for pump in p.pumps where pump.enabled {
            // Look up primary ion concentration (intracellular)
            let ionConc: Double
            switch pump.ion {
            case "Na": ionConc = max(naI, 0)
            case "K":  ionConc = max(kI,  0)
            case "Ca": ionConc = max(caI, 0)
            default:   continue
            }

            // Primary Hill factor
            let hillPrimary = hillCoop(x: ionConc, km: pump.kmIon, n: pump.hillN)

            // Secondary ion Hill factor (if any)
            let hillSecondary: Double
            if let ion2 = pump.ion2, let km2 = pump.kmIon2 {
                // For Na/K pump: secondary is K on extracellular side (pumpOut2 = false → K pumped in)
                let ionConc2: Double
                switch ion2 {
                case "K":  ionConc2 = kO   // extracellular K drives K uptake
                case "Na": ionConc2 = naO
                case "Ca": ionConc2 = caO
                default:   ionConc2 = 1.0
                }
                hillSecondary = hillCoop(x: max(ionConc2, 0), km: km2, n: pump.hillN2)
            } else {
                hillSecondary = 1.0
            }

            // ATP Hill factor
            let hillATP = hill(x: max(atp, 0), km: pump.kmATP)

            let demand = pump.jMax * hillPrimary * hillSecondary
            let rate   = demand * hillATP

            let pumpDt = rate * dt

            // Consume ATP
            atp -= pumpDt
            adp += pumpDt
            pi  += pumpDt
            totalPumpATP += pumpDt

            let extR = max(p.extracellularRatio, 0.01)

            // Update primary ion
            let primaryDelta = pump.stoichiometry * pumpDt
            switch pump.ion {
            case "Na":
                if pump.pumpOut {
                    naI -= primaryDelta     // Na pumped out of cell
                    if !p.clampExtracellular { naO += primaryDelta / extR }
                } else {
                    naI += primaryDelta
                    if !p.clampExtracellular { naO -= primaryDelta / extR }
                }
            case "K":
                if pump.pumpOut {
                    kI -= primaryDelta
                    if !p.clampExtracellular { kO += primaryDelta / extR }
                } else {
                    kI += primaryDelta
                    if !p.clampExtracellular { kO -= primaryDelta / extR }
                }
            case "Ca":
                if pump.pumpToER {
                    // SERCA: move Ca from cytoplasm to ER
                    caI  -= primaryDelta
                    caER += primaryDelta
                } else if pump.pumpOut {
                    // PMCA: pump Ca out of cell (caO clamped, so ignore extracellular)
                    caI -= primaryDelta
                }
            default: break
            }

            // Update secondary ion (if any)
            if let ion2 = pump.ion2 {
                let secondaryDelta = pump.stoichiometry2 * pumpDt
                switch ion2 {
                case "K":
                    if !pump.pumpOut2 {
                        // K pumped INTO cell (Na/K pump)
                        kI  += secondaryDelta
                        if !p.clampExtracellular { kO -= secondaryDelta / extR }
                    } else {
                        kI  -= secondaryDelta
                        if !p.clampExtracellular { kO += secondaryDelta / extR }
                    }
                case "Na":
                    if !pump.pumpOut2 {
                        naI += secondaryDelta
                        if !p.clampExtracellular { naO -= secondaryDelta / extR }
                    } else {
                        naI -= secondaryDelta
                        if !p.clampExtracellular { naO += secondaryDelta / extR }
                    }
                default: break
                }
            }

            // Track Na/K pump for backward compat (first Na pump with secondary K)
            if pump.ion == "Na" && pump.ion2 == "K" && nakPumpDemand == 0 {
                nakPumpDemand = demand
                nakPumpRate   = rate
            }
        }

        // Clamp extracellular Na/K
        if !p.clampExtracellular {
            naO = max(naO, 0.1)
            kO  = max(kO,  0.1)
        }

        // ── 4. ER passive leak ────────────────────────────────────────────────
        let erLeak = p.erLeakRate * caER * dt
        caI  += erLeak
        caER -= erLeak

        // ── 5. Mitochondrial ATP synthesis ────────────────────────────────────
        let jMito = p.mitoJmax * hill(x: max(adp, 0), km: p.mitoKmADP)
        let mitoDt = jMito * dt
        atp += mitoDt
        adp -= mitoDt
        pi  -= mitoDt

        // ── 6. Basal ATP consumption ──────────────────────────────────────────
        let basalDt = p.basalATPRate * dt
        atp -= basalDt
        adp += basalDt
        pi  += basalDt
        totalPumpATP += basalDt

        // ── 7. Clamp to physical bounds ───────────────────────────────────────
        naI = max(naI, 0.1);   kI  = max(kI,  0.1)
        caI = max(caI, 1e-6);  caER = max(caER, 0.0)
        atp = max(atp, 0.0);   adp = max(adp, 0.0);   pi = max(pi, 0.0)

        // ── 8. Build result ───────────────────────────────────────────────────
        let newState = EnergyState(
            naI: naI, kI: kI, naO: naO, kO: kO,
            caI: caI, caER: caER, caO: caO,
            atp: atp, adp: adp, pi: pi,
            atpConsumedTotal: es.atpConsumedTotal + totalPumpATP,
            pumpRateLast: nakPumpRate, pumpDemandLast: nakPumpDemand)

        return StepResult(
            state: newState,
            eNa: newState.eNa,
            eK:  newState.eK,
            pumpATPThisStep: totalPumpATP)
    }

    // MARK: - Hill functions

    /// Simple Michaelis-Menten (Hill n=1).
    @inline(__always)
    private static func hill(x: Double, km: Double) -> Double {
        x / (km + x)
    }

    /// Cooperative Hill function for integer n (n=1, 2, or 3).
    @inline(__always)
    private static func hillCoop(x: Double, km: Double, n: Int) -> Double {
        guard n > 1 else { return x / (km + x) }
        let xn  = pow(x,  Double(n))
        let kmn = pow(km, Double(n))
        return xn / (kmn + xn)
    }
}
