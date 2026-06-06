//
//  OptimObjective.swift
//  NeuroSimApp
//
//  Pluggable objective functions for the DE / CMA-ES optimizer.
//
//  Architecture
//  ────────────
//  `OptimObjective` is an enum where each case encodes one scoring strategy.
//  `makeScorer(neuronID:duration:)` turns a case into a closure that:
//    1. Receives a Simulator with candidate parameters already applied.
//    2. Resets, runs, and measures the simulation.
//    3. Returns (score-to-MINIMISE, display-pts).
//       display-pts = (V, dV/dt) pairs shown in the density overlay for
//       density-match mode; empty for objectives without a phase-plane view.
//
//  To add a new objective
//  ──────────────────────
//  1. Add a case to `OptimObjective`.
//  2. Implement its branch in `makeScorer`.
//  3. Add UI controls in `TrajectoryDensityView` sidebar.
//  No other files need to change.
//
//  Shared helpers
//  ──────────────
//  `detectBursts(samples:)` and `scoreBurstObjective(...)` are plain free
//  functions so they can be called from both `OptimObjective` and
//  `PDSweepRunner` without duplication.
//

import Foundation
import NeuroSimCore

// MARK: - Shared burst helpers (free functions, module-internal)

/// Detect bursts from a time-series of AIS (or soma) voltage.
///
/// - Parameter samples: (t ms, V mV) pairs, sampled at any rate ≤ 1 ms.
/// - Returns: (burstCount, meanAPsPerBurst, meanInterBurstPeriodMs).
///            meanInterBurstPeriodMs = 0 when fewer than 2 bursts detected.
func detectBursts(
    samples: [(t: Double, v: Double)]
) -> (burstCount: Int, meanAPsPerBurst: Double, meanPeriodMs: Double) {

    let apThreshold:      Double = 0.0    // mV — Na AP upward crossing
    let intraMaxISI:      Double = 150.0  // ms — max ISI *inside* a burst
    let interMinSilence:  Double = 300.0  // ms — min silence *between* bursts

    // 1 — AP times from upward threshold crossings
    var apTimes: [Double] = []
    var prevV = samples.first?.v ?? -70.0
    for s in samples {
        if prevV < apThreshold && s.v >= apThreshold { apTimes.append(s.t) }
        prevV = s.v
    }
    guard !apTimes.isEmpty else { return (0, 0, 0) }

    // 2 — group into bursts by ISI
    struct Burst { var times: [Double] }
    var bursts: [Burst] = []
    var cur    = Burst(times: [apTimes[0]])

    for i in 1..<apTimes.count {
        let isi = apTimes[i] - apTimes[i - 1]
        if isi <= intraMaxISI {
            cur.times.append(apTimes[i])
        } else {
            if cur.times.count >= 2 { bursts.append(cur) }
            cur = isi >= interMinSilence
                ? Burst(times: [apTimes[i]])   // clear silence → fresh burst
                : Burst(times: [])             // ambiguous gap → discard
        }
    }
    if cur.times.count >= 2 { bursts.append(cur) }

    let count = bursts.count
    guard count > 0 else { return (0, 0, 0) }

    let meanAPs = Double(bursts.reduce(0) { $0 + $1.times.count }) / Double(count)

    var meanPeriod = 0.0
    if count > 1 {
        let starts  = bursts.map { $0.times[0] }
        let sumPer  = zip(starts.dropFirst(), starts).map { $0 - $1 }.reduce(0, +)
        meanPeriod  = sumPer / Double(count - 1)
    }

    return (count, meanAPs, meanPeriod)
}

/// Composite burst score — **higher = better**.
///
/// - Parameters:
///   - burstCount:        detected burst count
///   - meanAPs:           mean APs per burst
///   - meanPeriodMs:      mean inter-burst period (ms)
///   - durationMs:        simulation duration (ms)
///   - targetBPS:         target bursts per second   (default 1.0)
///   - targetAPsPerBurst: target APs per burst       (default 12.5)
///   - targetPeriodMs:    target inter-burst period  (default 1000 ms)
func scoreBurstObjective(burstCount: Int,
                          meanAPs:    Double,
                          meanPeriodMs: Double,
                          durationMs: Double,
                          targetBPS:         Double = 1.0,
                          targetAPsPerBurst: Double = 12.5,
                          targetPeriodMs:    Double = 1000.0) -> Double {
    guard burstCount > 0 else { return Double(burstCount) - 10 }

    let expectedBursts = durationMs / 1000.0 * targetBPS
    // Burst count factor: capped at 1.2× to avoid rewarding runaway spiking
    let burstFactor     = min(Double(burstCount) / max(expectedBursts, 0.1), 1.2)
    // AP closeness: 1.0 at target, 0.0 at 0 or 2× target
    let apCloseness     = max(0, 1.0 - abs(meanAPs - targetAPsPerBurst) / targetAPsPerBurst)
    // Period closeness: 1.0 at target, 0.0 at 0 or 2× target; 0 if single burst
    let periodCloseness = burstCount > 1
        ? max(0, 1.0 - abs(meanPeriodMs - targetPeriodMs) / targetPeriodMs)
        : 0.0

    return 10.0 * burstFactor * (1.0 + apCloseness + periodCloseness)
}

// MARK: - Objective enum

/// Defines *what* the optimizer is trying to achieve.
/// Add a new case here + its branch in `makeScorer` to plug in a new metric.
enum OptimObjective {

    /// Minimise the Σ(p_sim − p_ref)² difference between (V, dV/dt) trajectory
    /// densities.  Requires a recorded or previously simulated reference trace.
    case densityMatch(
        refPoints: [(v: Double, dvdt: Double)],
        nBinsV:    Int,
        nBinsDvdt: Int
    )

    /// Maximise burst regularity — no reference trace required.
    /// The optimizer drives toward a target burst rhythm (count, APs, period).
    case burstCounting(
        aisCompartmentID:  UUID?,     // nil → use soma voltage
        restingVoltage:    Double,    // mV — initial condition (e.g. −80 for PD)
        targetBPS:         Double,    // bursts / second
        targetAPsPerBurst: Double,    // APs per burst
        targetPeriodMs:    Double     // inter-burst period (ms)
    )
}

// MARK: - Scorer factory

extension OptimObjective {

    /// Build a scorer closure for this objective.
    ///
    /// The returned closure:
    ///   - receives a `Simulator` with candidate parameters already applied
    ///   - resets it, runs it for `duration` ms, measures, and returns
    ///     `(score, displayPts, tracePts)` where `score` is to MINIMISE,
    ///     `displayPts` are (V, dV/dt) phase-plane points for the overlay,
    ///     and `tracePts` are downsampled (t, V) pairs for the V(t) preview.
    ///
    /// - Parameters:
    ///   - neuronID: UUID of the neuron being optimised.
    ///   - duration: simulation duration (ms) — pass `config.simDuration`.
    func makeScorer(
        neuronID: UUID,
        duration: Double
    ) -> (Simulator) -> (score: Double,
                         displayPts: [(v: Double, dvdt: Double)],
                         tracePts:   [(t: Double, v: Double)]) {

        switch self {

        // ── Density match ─────────────────────────────────────────────────
        case let .densityMatch(refPoints, nBinsV, nBinsDvdt):
            guard let refGrid = buildEvalGrid(refPoints, nV: nBinsV, nD: nBinsDvdt) else {
                return { _ in (.infinity, [], []) }
            }
            let every      = max(1, Int(duration / 0.025 / 12_000))  // phase-plane stride
            let traceEvery = max(1, Int(duration / 0.025 / 400))     // display trace (~400 pts)
            return { sim in
                sim.reset()
                var pts:   [(v: Double, dvdt: Double)] = []
                var trace: [(t: Double, v: Double)]    = []
                var step = 0
                // Central-difference rolling buffer: keep the two previous samples
                // so we can compute dV/dt[i] = (V[i+1] − V[i−1]) / (t[i+1] − t[i−1])
                // and place the point at V[i] (the centre sample).
                var pp: (t: Double, v: Double)? = nil   // i−1
                var pv: (t: Double, v: Double)? = nil   // i
                sim.run(duration: duration) { sample in
                    step += 1
                    guard let v = sample.voltages[neuronID] else { return }
                    // Low-res display trace
                    if step % traceEvery == 0 { trace.append((t: sample.time, v: v)) }
                    // Phase-plane central differences
                    guard step % every == 0 else { return }
                    let cur = (t: sample.time, v: v)
                    defer { pp = pv; pv = cur }
                    guard let prev2 = pp, let prev1 = pv else { return }
                    let dt2 = cur.t - prev2.t
                    guard dt2 > 0, dt2 < 4.0 else { return }
                    let dv = (cur.v - prev2.v) / dt2
                    guard abs(dv) < 5000 else { return }
                    pts.append((v: prev1.v, dvdt: dv))
                }
                guard !pts.isEmpty else { return (.infinity, [], trace) }
                let cg = buildEvalGridInRange(pts,
                                              vLo: refGrid.vMin, vHi: refGrid.vMax,
                                              dLo: refGrid.dvdtMin, dHi: refGrid.dvdtMax,
                                              nV: nBinsV, nD: nBinsDvdt)
                return (ssdNormalized(refGrid, cg), pts, trace)
            }

        // ── Burst counting ────────────────────────────────────────────────
        case let .burstCounting(aisID, restingV, targetBPS, targetAPs, targetPeriod):
            return { sim in
                sim.reset(restingVoltage: restingV)

                // Resolve the voltage index to track for AP detection
                let vIdx: Int
                if let aid = aisID,
                   let idx = sim.network.voltageIndex(ofCompartment: aid) {
                    vIdx = idx
                } else if let idx = sim.network.voltageIndex(of: neuronID) {
                    vIdx = idx
                } else {
                    return (.infinity, [], [])
                }

                // Sample every 0.5 ms — reliable upward-crossing detection for Na APs
                let sampleEvery = max(1, Int((0.5 / sim.dt).rounded()))
                var stepN   = 0
                var samples: [(t: Double, v: Double)] = []
                samples.reserveCapacity(Int(duration * 2))

                sim.run(duration: duration) { sample in
                    stepN += 1
                    guard stepN % sampleEvery == 0 else { return }
                    samples.append((t: sample.time, v: sim.state[vIdx]))
                }

                let (nBursts, meanAPs, period) = detectBursts(samples: samples)
                let score = scoreBurstObjective(
                    burstCount:    nBursts,
                    meanAPs:       meanAPs,
                    meanPeriodMs:  period,
                    durationMs:    duration,
                    targetBPS:         targetBPS,
                    targetAPsPerBurst: targetAPs,
                    targetPeriodMs:    targetPeriod)

                // Downsample samples → ~400 pts for the V(t) preview
                let traceStep = max(1, samples.count / 400)
                let trace = Swift.stride(from: 0, to: samples.count, by: traceStep)
                               .map { samples[$0] }
                // DE/CMA-ES minimise → invert (perfect score 36 → 0.027; no bursts → ~1.0)
                let toMinimise = 1.0 / (1.0 + max(score, 0))
                return (toMinimise, [], trace)
            }
        }
    }
}
