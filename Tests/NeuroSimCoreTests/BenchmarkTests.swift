//
//  BenchmarkTests.swift
//  NeuroSimCoreTests
//
//  CPU profiling — measures wall-clock time for each phase of the
//  simulation pipeline.  Run with:
//
//      swift test --filter BenchmarkTests 2>&1 | grep -E "▶|ms|µs|ns|PASS|FAIL"
//
//  The numbers are printed to stdout so they survive the normal XCTest
//  "no output in release" filtering.  Build in Debug for realistic numbers
//  (the app runs Debug in Xcode by default too).
//

import XCTest
@testable import NeuroSimCore
import Foundation

// Helpers needed for test_13 (phase-plane collection + chi² scoring).
// All optimizer types (DifferentialEvolution, CMAES, ArtificialBeeColony,
// EvalDensityGrid, chiSquaredFast …) arrive via @testable import NeuroSimCore.

private func collectPhasePts(sim: Simulator,
                              neuronID: UUID,
                              duration: Double) -> [(v: Double, dvdt: Double)] {
    var pts: [(v: Double, dvdt: Double)] = []
    pts.reserveCapacity(Int(duration / 0.025))
    var pp: (t: Double, v: Double)? = nil
    var pv: (t: Double, v: Double)? = nil
    sim.run(duration: duration) { sample in
        guard let v = sample.voltages[neuronID] else { return }
        let cur = (t: sample.time, v: v)
        defer { pp = pv; pv = cur }
        guard let p2 = pp, let p1 = pv else { return }
        let dt2 = cur.t - p2.t
        guard dt2 > 0, dt2 < 4.0 else { return }
        let dv = (cur.v - p2.v) / dt2
        guard abs(dv) < 5_000 else { return }
        pts.append((v: p1.v, dvdt: dv))
    }
    return pts
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

// Output file — readable after the test run
private let benchLog = "/tmp/neurosim_benchmark.txt"
private var benchBuffer: [String] = []

private func blog(_ s: String = "") {
    benchBuffer.append(s)
    fputs(s + "\n", stderr)   // also visible in Xcode console
}

private func flushBlog() {
    let content = benchBuffer.joined(separator: "\n") + "\n"
    try? content.write(toFile: benchLog, atomically: true, encoding: .utf8)
}

private func timeIt(label: String, warmup: Int = 5, repeats: Int = 1000,
                    body: () -> Void) -> Double {
    for _ in 0..<warmup { body() }

    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0..<repeats { body() }
    let elapsed = clock.now - start

    let totalNs = Double(elapsed.components.attoseconds) / 1e9
                + Double(elapsed.components.seconds) * 1e9
    let perCallNs = totalNs / Double(repeats)

    let fmt: String
    if perCallNs >= 1_000_000 { fmt = String(format: "%.3f ms", perCallNs / 1e6) }
    else if perCallNs >= 1_000 { fmt = String(format: "%.2f µs", perCallNs / 1e3) }
    else                        { fmt = String(format: "%.0f ns", perCallNs) }

    blog("  [\(label)]  \(fmt)/call  (n=\(repeats))")
    return perCallNs
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Network factories
// ─────────────────────────────────────────────────────────────────────────────

private func makeNetwork(neurons n: Int,
                         fullyConnected: Bool = false,
                         energyEnabled: Bool = false) -> Network {
    let net = Network()
    var added: [HHNeuron] = []
    for i in 0..<n {
        let neuron = HHNeuron(name: "N\(i+1)")
        if energyEnabled { neuron.energyParams.enabled = true }
        net.addNeuron(neuron)
        added.append(neuron)
    }
    if fullyConnected && n > 1 {
        for i in 0..<n {
            for j in 0..<n where i != j {
                net.addSynapse(ChemicalSynapse(from: added[i].id,
                                               to:   added[j].id,
                                               gMax: 0.3,
                                               reversal: 0.0,
                                               tauDecay: 5.0))
            }
        }
    }
    if n > 0 {
        net.setStimulus(PulseStimulus(start: 10, duration: 80, amplitude: 10),
                        on: added[0].id)
    }
    return net
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - BenchmarkTests
// ─────────────────────────────────────────────────────────────────────────────

final class BenchmarkTests: XCTestCase {

    // ── 1. step() — integration kernel by network size ──────────────────────

    func test_01_stepVsNetworkSize() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("1. step() — integration kernel (RushLarsen, dt=0.025 ms)")
        blog("═══════════════════════════════════════════════════════")
        let dt = 0.025
        for n in [1, 2, 5, 10] {
            let net = makeNetwork(neurons: n, fullyConnected: true)
            let sim = Simulator(network: net, dt: dt)
            sim.method = .rushLarsen
            timeIt(label: "\(n) neuron\(n==1 ? "" : "s") fully-connected", repeats: 2000) {
                sim.step()
            }
        }
    }

    // ── 2. Integration method comparison (1 neuron, dt=0.025 ms) ────────────

    func test_02_integrationMethods() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("2. Integration method comparison — 1 neuron, dt=0.025 ms")
        blog("═══════════════════════════════════════════════════════")
        let dt = 0.025
        let methods: [(String, IntegrationMethod)] = [
            ("Euler", .euler),
            ("RK2",   .rk2),
            ("RK4",   .rk4),
            ("Rush-Larsen", .rushLarsen)
        ]
        for (name, method) in methods {
            let net = makeNetwork(neurons: 1)
            let sim = Simulator(network: net, dt: dt)
            sim.method = method
            timeIt(label: name, repeats: 5000) { sim.step() }
        }
    }

    // ── 3. Integration method comparison — dt=0.05 ms ───────────────────────

    func test_03_integrationMethodsBigDt() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("3. Integration method comparison — 1 neuron, dt=0.05 ms")
        blog("═══════════════════════════════════════════════════════")
        let dt = 0.05
        let methods: [(String, IntegrationMethod)] = [
            ("Euler", .euler),
            ("RK2",   .rk2),
            ("RK4",   .rk4),
            ("Rush-Larsen", .rushLarsen)
        ]
        for (name, method) in methods {
            let net = makeNetwork(neurons: 1)
            let sim = Simulator(network: net, dt: dt)
            sim.method = method
            timeIt(label: name, repeats: 5000) { sim.step() }
        }
    }

    // ── 4. Energy model impact (1 neuron) ────────────────────────────────────

    func test_04_energyModelImpact() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("4. Energy model impact — 1 neuron, Rush-Larsen, dt=0.025 ms")
        blog("═══════════════════════════════════════════════════════")
        let dt = 0.025
        for energy in [false, true] {
            let net = makeNetwork(neurons: 1, energyEnabled: energy)
            let sim = Simulator(network: net, dt: dt)
            sim.method = .rushLarsen
            timeIt(label: energy ? "energy ON" : "energy OFF", repeats: 5000) {
                sim.step()
            }
        }
    }

    // ── 5. computeDerivatives() alone vs full step() ─────────────────────────

    func test_05_derivativesVsFullStep() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("5. computeDerivatives() vs full step() — 1 neuron, RK4")
        blog("═══════════════════════════════════════════════════════")
        let dt = 0.025
        let net = makeNetwork(neurons: 1)
        let sim = Simulator(network: net, dt: dt)
        sim.method = .rk4

        // full step
        timeIt(label: "full step()", repeats: 5000) { sim.step() }

        // derivatives only (calls computeDerivatives 4× inside RK4, we call it 1×)
        var scratch = [Double](repeating: 0, count: net.stateCount)
        timeIt(label: "computeDerivatives() ×1", repeats: 5000) {
            net.computeDerivatives(state: sim.state, time: sim.time, into: &scratch)
        }
    }

    // ── 6. Synaptic overhead (sparse vs dense connections) ───────────────────

    func test_06_synapticOverhead() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("6. Synaptic overhead — 5 neurons, Rush-Larsen, dt=0.025 ms")
        blog("═══════════════════════════════════════════════════════")
        let dt = 0.025

        let netNo  = makeNetwork(neurons: 5, fullyConnected: false)
        let netYes = makeNetwork(neurons: 5, fullyConnected: true)   // 20 synapses

        let simNo  = Simulator(network: netNo,  dt: dt); simNo.method  = .rushLarsen
        let simYes = Simulator(network: netYes, dt: dt); simYes.method = .rushLarsen

        timeIt(label: "5 neurons, 0 synapses",  repeats: 2000) { simNo.step() }
        timeIt(label: "5 neurons, 20 synapses", repeats: 2000) { simYes.step() }
    }

    // ── 7. ViewModel-side: sample collection overhead ────────────────────────
    // Simulates what the hot loop in kickFrame() does after each step.

    func test_07_sampleCollectionOverhead() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("7. Sample-collection overhead per frame (ViewModel side)")
        blog("   — reading voltage + building voltSamples array")
        blog("═══════════════════════════════════════════════════════")

        let neuronCount = 5
        let net = makeNetwork(neurons: neuronCount, fullyConnected: true)
        let sim = Simulator(network: net, dt: 0.025)
        sim.method = .rushLarsen

        // Pre-build neuronIdx like kickFrame() does
        let neuronIdx: [(UUID, Int)] = net.neurons.compactMap { n in
            guard let i = net.voltageIndex(of: n.id) else { return nil }
            return (n.id, i)
        }

        // Measure reading voltage for all neurons (divergence check + collect)
        timeIt(label: "read \(neuronCount) voltages from state[]", repeats: 50_000) {
            for (id, vIdx) in neuronIdx {
                let _ = (id, sim.state[vIdx])
            }
        }

        // Measure appending one sample per neuron
        var buf: [(UUID, Double, Double)] = []
        buf.reserveCapacity(neuronCount * 1000)
        let t = sim.time
        timeIt(label: "append \(neuronCount) voltSamples (no alloc)", repeats: 50_000) {
            for (id, vIdx) in neuronIdx {
                buf.append((id, t, sim.state[vIdx]))
            }
        }
    }

    // ── 8. ViewModel-side: trace append + trim (main-actor work) ─────────────

    func test_08_traceAppendAndTrim() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("8. Trace append + trim — ViewModel main-actor work")
        blog("   (COW copy of pendingTraces + append + binary-search trim)")
        blog("═══════════════════════════════════════════════════════")

        struct PP: Hashable { let t, v: Double }

        let neuronCount = 5
        let samplesPerNeuron = 4000   // typical for 200ms window at dt=0.025, stride=1
        let stepsPerFrame = 500       // typical at realtimeFactor=1, dt=0.025ms

        // Simulate the pendingTraces dictionary as it exists at the start of a frame
        var pending: [UUID: [PP]] = [:]
        let ids = (0..<neuronCount).map { _ in UUID() }
        for id in ids {
            pending[id] = (0..<samplesPerNeuron).map { PP(t: Double($0) * 0.025, v: -65.0) }
        }

        // Simulate the voltSamples produced by the background task in one frame
        let frameSamples: [(UUID, Double, Double)] = ids.flatMap { id in
            (0..<stepsPerFrame).map { i in
                (id, Double(samplesPerNeuron + i) * 0.025, -65.0)
            }
        }
        let cutoff = Double(samplesPerNeuron + stepsPerFrame) * 0.025 - 200.0
        let maxSamples = 500_000

        timeIt(label: "COW copy + append \(stepsPerFrame) samples (\(neuronCount) neurons)",
               repeats: 200) {
            var pt = pending    // COW copy
            for (id, t, v) in frameSamples {
                pt[id, default: []].append(PP(t: t, v: v))
            }
            // binary-search trim
            for id in pt.keys {
                guard var arr = pt[id], !arr.isEmpty else { continue }
                var lo = 0, hi = arr.count
                while lo < hi {
                    let mid = lo + (hi - lo) / 2
                    if arr[mid].t < cutoff { lo = mid + 1 } else { hi = mid }
                }
                if lo > 0 { arr.removeSubrange(0..<lo) }
                if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
                pt[id] = arr
            }
            pending = pt
        }
    }

    // ── 9. Full pipeline throughput — simulated ms / wall-s ──────────────────

    func test_09_fullPipelineThroughput() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("9. Full pipeline throughput (simulated ms / wall second)")
        blog("═══════════════════════════════════════════════════════")

        let configs: [(String, Int, Bool, IntegrationMethod, Double)] = [
            ("1 neuron, RL, dt=0.025", 1, false, .rushLarsen, 0.025),
            ("1 neuron, RL, dt=0.05",  1, false, .rushLarsen, 0.05),
            ("2 neurons fully-conn, RL, dt=0.025", 2, true, .rushLarsen, 0.025),
            ("5 neurons fully-conn, RL, dt=0.025", 5, true, .rushLarsen, 0.025),
            ("5 neurons fully-conn, RK4, dt=0.025", 5, true, .rk4, 0.025),
            ("5 neurons + energy, RL, dt=0.025",    5, false, .rushLarsen, 0.025),
            ("10 neurons fully-conn, RL, dt=0.025",10, true, .rushLarsen, 0.025),
        ]

        for (label, n, fc, method, dt) in configs {
            let energyEnabled = label.contains("energy")
            let net = makeNetwork(neurons: n, fullyConnected: fc, energyEnabled: energyEnabled)
            let sim = Simulator(network: net, dt: dt)
            sim.method = method
            sim.reset(restingVoltage: -65.0)

            let nSteps = 10_000
            let clock  = ContinuousClock()
            let start  = clock.now
            for _ in 0..<nSteps { sim.step() }
            let elapsed = clock.now - start

            let wallS = Double(elapsed.components.seconds)
                      + Double(elapsed.components.attoseconds) / 1e18
            let simMs  = Double(nSteps) * dt
            let ratio  = simMs / (wallS * 1000.0)   // simulated ms / wall ms

            let line = String(format: "  %-48@  %6.0f× real-time  (%.2f µs/step)",
                              label as CVarArg, ratio, wallS / Double(nSteps) * 1e6)
            blog(line)
        }
    }

    // ── 10. Channels cost breakdown — add channels one at a time ─────────────

    func test_10_channelCost() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("10. Channel cost — adding channels to a single neuron")
        blog("    Rush-Larsen, dt=0.025 ms")
        blog("═══════════════════════════════════════════════════════")

        let dt = 0.025

        // 1. Bare leak channel only
        let netLeak = Network()
        let nLeak = HHNeuron(name: "leak")
        // replace all default channels with just a leak channel
        if let somaIdx = nLeak.compartments.firstIndex(where: { $0.id == nLeak.somaCompartmentID }) {
            nLeak.compartments[somaIdx].channels = [LeakChannel()]
        }
        netLeak.addNeuron(nLeak)
        let simLeak = Simulator(network: netLeak, dt: dt)
        simLeak.method = .rushLarsen
        timeIt(label: "Leak only", repeats: 5000) { simLeak.step() }

        // 2. Standard HH (Na + K + Leak — the default HHNeuron)
        let netHH = makeNetwork(neurons: 1)
        let simHH = Simulator(network: netHH, dt: dt)
        simHH.method = .rushLarsen
        timeIt(label: "Standard HH (Na+K+Leak)", repeats: 5000) { simHH.step() }

        blog("\n  (cost per added HH channel ≈ difference between the two above)")
        flushBlog()   // write everything to /tmp/neurosim_benchmark.txt
    }

    // ── 11. Density scorer pipeline ──────────────────────────────────────────
    //
    //  Measures the hot path of the optimiser / heatmap sweep:
    //    a) buildEvalGridInRange — phase-plane → weighted histogram
    //    b) ssdNormalized (old)  — χ² with totalWeight computed inside
    //    c) chiSquaredFast (new) — χ² with pre-normalised reference
    //
    //  Runs entirely in NeuroSimCore (no SwiftUI) using inline replicas of
    //  the NeuroSimApp scoring functions so the test target doesn't need to
    //  import NeuroSimApp.
    //
    func test_11_densityScorerPipeline() {
        blog("\n═══════════════════════════════════════════════════════")
        blog("11. Density scorer pipeline")
        blog("    (buildEvalGrid + χ²)  — nBinsV=80, nBinsDvdt=60")
        blog("═══════════════════════════════════════════════════════")

        // ── Synthetic phase-plane data ──────────────────────────────────────
        // Simulate a HH neuron for 500 ms at dt=0.025 ms, collect phase-plane pts.
        let net = makeNetwork(neurons: 1)
        let sim = Simulator(network: net, dt: 0.025)
        sim.method = .rushLarsen
        sim.reset(restingVoltage: -65.0)
        guard let nid = net.neurons.first?.id else { return }

        // Add a small tonic drive so we get spikes (500 ms, dt=0.025 → 20 000 steps)
        // We borrow the stimulus from the default stim protocol by injecting manually.
        var refPts:  [(v: Double, dvdt: Double)] = []
        refPts.reserveCapacity(20_000)
        var pp: (t: Double, v: Double)? = nil
        var pv: (t: Double, v: Double)? = nil
        sim.run(duration: 500.0) { sample in
            guard let v = sample.voltages[nid] else { return }
            let cur = (t: sample.time, v: v)
            defer { pp = pv; pv = cur }
            guard let p2 = pp, let p1 = pv else { return }
            let dt2 = cur.t - p2.t
            guard dt2 > 0, dt2 < 4.0 else { return }
            let dv = (cur.v - p2.v) / dt2
            guard abs(dv) < 5_000 else { return }
            refPts.append((v: p1.v, dvdt: dv))
        }
        blog("  Synthetic ref pts: \(refPts.count)")

        // Candidate: slightly perturbed copy
        let candPts = refPts.map { (v: $0.v + 0.5, dvdt: $0.dvdt * 0.98) }

        let nV = 80, nD = 60

        // Compute reference domain once
        let vs  = refPts.map(\.v);    let ds = refPts.map(\.dvdt)
        let vMn = vs.min()!;          let vMx = vs.max()!
        let dMn = ds.min()!;          let dMx = ds.max()!
        let vPad = (vMx - vMn) * 0.04; let dPad = (dMx - dMn) * 0.04
        let vLo = vMn - vPad; let vHi = vMx + vPad
        let dLo = dMn - dPad; let dHi = dMx + dPad

        // ── Helper: arc-length bin accumulator (inline replica) ─────────────
        func buildGrid(_ pts: [(v: Double, dvdt: Double)]) -> [Double] {
            var w = [Double](repeating: 0, count: nV * nD)
            let n = pts.count
            @inline(__always)
            func segLen(_ i: Int, _ j: Int) -> Double {
                let dv = pts[j].v - pts[i].v; let dd = pts[j].dvdt - pts[i].dvdt
                return max(sqrt(dv*dv + dd*dd), 1e-12)
            }
            for i in 0..<n {
                let wi: Double
                switch (i, n) {
                case (_, 1):                       wi = 1.0
                case (0, _):                       wi = segLen(0, 1)
                case (_, _) where i == n - 1:      wi = segLen(n-2, n-1)
                default:                           wi = (segLen(i-1, i) + segLen(i, i+1)) * 0.5
                }
                let p = pts[i]
                guard p.v >= vLo, p.v <= vHi, p.dvdt >= dLo, p.dvdt <= dHi else { continue }
                let ci = min(Int((p.v    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
                let ri = min(Int((p.dvdt - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
                w[ri * nV + ci] += wi
            }
            return w
        }

        // ── a) buildEvalGrid ────────────────────────────────────────────────
        blog("\n  a) buildEvalGrid — \(refPts.count) pts → \(nV)×\(nD) grid")
        let refWeights = buildGrid(refPts)
        timeIt(label: "buildEvalGrid (ref, \(refPts.count) pts)", repeats: 200) {
            _ = buildGrid(refPts)
        }
        timeIt(label: "buildEvalGrid (cand, \(candPts.count) pts)", repeats: 200) {
            _ = buildGrid(candPts)
        }

        // ── b) χ² — OLD: totalWeight recomputed inside ──────────────────────
        blog("\n  b) χ² — OLD: totalWeight via reduce() inside scorer")
        let candWeights = buildGrid(candPts)
        timeIt(label: "χ² old (reduce totalWeight × 2 + loop)", repeats: 2000) {
            let tA = max(1e-10, refWeights.reduce(0, +))   // 4800 additions
            let tB = max(1e-10, candWeights.reduce(0, +))  // 4800 additions
            var dist = 0.0
            for i in 0..<(nV * nD) {
                let pA = refWeights[i] / tA
                let pB = candWeights[i] / tB
                let den = pA + pB
                if den > 1e-20 { let d = pA - pB; dist += d * d / den }
            }
            _ = dist
        }

        // ── c) χ² — NEW: totalWeight stored, ref pre-normalised ─────────────
        blog("\n  c) χ² — NEW: stored totalWeight + pre-normalised refNorm")
        let tRef    = max(1e-10, refWeights.reduce(0, +))     // computed ONCE
        let tCand   = max(1e-10, candWeights.reduce(0, +))    // computed ONCE
        let refNorm = refWeights.map { $0 / tRef }            // normalised ONCE
        timeIt(label: "χ² new (stored totals + refNorm, no reduce)", repeats: 2000) {
            var dist = 0.0
            for i in 0..<(nV * nD) {
                let pA = refNorm[i]                   // free — pre-computed
                let pB = candWeights[i] / tCand       // one division only
                let den = pA + pB
                if den > 1e-20 { let d = pA - pB; dist += d * d / den }
            }
            _ = dist
        }

        // ── d) Full scorer cost per candidate ───────────────────────────────
        blog("\n  d) Full per-candidate cost: buildGrid + χ² (new)")
        timeIt(label: "buildGrid(cand) + χ²fast  [per eval]", repeats: 200) {
            let cw   = buildGrid(candPts)
            let tB   = max(1e-10, cw.reduce(0, +))
            var dist = 0.0
            for i in 0..<(nV * nD) {
                let pA = refNorm[i]; let pB = cw[i] / tB
                let den = pA + pB
                if den > 1e-20 { let d = pA - pB; dist += d * d / den }
            }
            _ = dist
        }

        flushBlog()
    }

    // ── 12. Convergence landscape — 4-formula comparison ─────────────────────
    //
    //  Question: does arc-length weighting produce a better-shaped (sharper,
    //  more monotone) optimisation landscape than uniform point counting?
    //
    //  We compare 4 combinations independently:
    //    A. Uniform counts + SSD   (old formula, pre-commit 2737969)
    //    B. Uniform counts + χ²
    //    C. Arc-length weights + SSD
    //    D. Arc-length weights + χ²  (current production)
    //
    //  Methodology:
    //    · Reference = HH neuron at gNa = 56.0 mS/cm² (true value), 500 ms
    //    · Candidate = same neuron at gNa = 0.3× … 2.5× true
    //    · Domain bounds fixed from the reference trajectory (same as production)
    //    · Quality metric: sensitivity = mean(score±20%) / min_score
    //      → higher means sharper minimum → better gradient for optimiser
    //
    func test_12_convergenceLandscape() {

        let trueGNa  = 56.0         // default SodiumChannel.gMax
        let nV       = 80
        let nD       = 60
        let duration = 500.0        // ms — long enough to capture several APs
        let dt       = 0.025

        blog("\n═══════════════════════════════════════════════════════")
        blog("12. Convergence landscape — 4-formula comparison")
        blog("    Reference: HH gNa=\(trueGNa) mS/cm², \(Int(duration)) ms")
        blog("    Scoring grid: \(nV)×\(nD),  4 methods (A/B/C/D)")
        blog("═══════════════════════════════════════════════════════")

        // ── Helper: collect phase-plane points from a simulation ─────────────
        func collectPts(sim: Simulator, neuronID: UUID) -> [(v: Double, dvdt: Double)] {
            var pts: [(v: Double, dvdt: Double)] = []
            pts.reserveCapacity(20_000)
            var pp: (t: Double, v: Double)? = nil
            var pv: (t: Double, v: Double)? = nil
            sim.run(duration: duration) { sample in
                guard let v = sample.voltages[neuronID] else { return }
                let cur = (t: sample.time, v: v)
                defer { pp = pv; pv = cur }
                guard let p2 = pp, let p1 = pv else { return }
                let dt2 = cur.t - p2.t
                guard dt2 > 0, dt2 < 4.0 else { return }
                let dv = (cur.v - p2.v) / dt2
                guard abs(dv) < 5_000 else { return }
                pts.append((v: p1.v, dvdt: dv))
            }
            return pts
        }

        // ── 1. Reference simulation ──────────────────────────────────────────
        let refNet = makeNetwork(neurons: 1)
        let refSim = Simulator(network: refNet, dt: dt)
        refSim.method = .rushLarsen
        refSim.reset(restingVoltage: -65.0)
        guard let refNID = refNet.neurons.first?.id else { return }

        let refPts = collectPts(sim: refSim, neuronID: refNID)
        blog("  Reference pts: \(refPts.count)")
        guard !refPts.isEmpty else { blog("  ERROR: no reference pts — aborting"); return }

        // Domain bounds from reference (identical to production code)
        let vs  = refPts.map(\.v);     let ds = refPts.map(\.dvdt)
        let vMn = vs.min()!;           let vMx = vs.max()!
        let dMn = ds.min()!;           let dMx = ds.max()!
        let vPad = (vMx - vMn) * 0.04; let dPad = (dMx - dMn) * 0.04
        let vLo = vMn - vPad;          let vHi = vMx + vPad
        let dLo = dMn - dPad;          let dHi = dMx + dPad
        let nCells = nV * nD

        // ── 2. Grid builders (inline — NeuroSimApp not importable from tests) ─

        // Uniform grid: each phase-plane point contributes weight 1.
        func buildUniform(_ pts: [(v: Double, dvdt: Double)]) -> (w: [Double], outFrac: Double) {
            var w = [Double](repeating: 0, count: nCells)
            var inside = 0
            for p in pts {
                guard p.v >= vLo, p.v <= vHi, p.dvdt >= dLo, p.dvdt <= dHi else { continue }
                let ci = min(Int((p.v    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
                let ri = min(Int((p.dvdt - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
                w[ri * nV + ci] += 1.0
                inside += 1
            }
            let out = pts.isEmpty ? 1.0 : Double(pts.count - inside) / Double(pts.count)
            return (w, out)
        }

        // Arc-length grid: each point weighted by the mean arc length of its
        // adjacent segments (identical to OptimizationRunner.buildEvalGridInRange).
        func buildArcLen(_ pts: [(v: Double, dvdt: Double)]) -> (w: [Double], outFrac: Double) {
            var w = [Double](repeating: 0, count: nCells)
            let n = pts.count
            guard n > 0 else { return (w, 1.0) }

            @inline(__always)
            func seg(_ i: Int, _ j: Int) -> Double {
                let dv = pts[j].v - pts[i].v; let dd = pts[j].dvdt - pts[i].dvdt
                return max(sqrt(dv*dv + dd*dd), 1e-12)
            }

            var inside = 0
            for i in 0..<n {
                let wi: Double
                if n == 1                { wi = 1.0 }
                else if i == 0           { wi = seg(0, 1) }
                else if i == n - 1       { wi = seg(n-2, n-1) }
                else                     { wi = (seg(i-1, i) + seg(i, i+1)) * 0.5 }
                let p = pts[i]
                guard p.v >= vLo, p.v <= vHi, p.dvdt >= dLo, p.dvdt <= dHi else { continue }
                let ci = min(Int((p.v    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
                let ri = min(Int((p.dvdt - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
                w[ri * nV + ci] += wi
                inside += 1
            }
            let out = Double(pts.count - inside) / Double(pts.count)
            return (w, out)
        }

        // SSD: Σ(p_A − p_B)²  + outFrac·2
        @inline(__always)
        func scoreSSD(refNorm: [Double], cw: [Double], cTotal: Double, outFrac: Double) -> Double {
            let tB = max(1e-10, cTotal)
            var d = 0.0
            for i in 0..<nCells {
                let pB = cw[i] / tB; let diff = refNorm[i] - pB; d += diff * diff
            }
            return d + outFrac * 2.0
        }

        // χ²: Σ(p_A − p_B)²/(p_A + p_B)  + outFrac·2
        @inline(__always)
        func scoreChi2(refNorm: [Double], cw: [Double], cTotal: Double, outFrac: Double) -> Double {
            let tB = max(1e-10, cTotal)
            var d = 0.0
            for i in 0..<nCells {
                let pA = refNorm[i]; let pB = cw[i] / tB
                let den = pA + pB
                if den > 1e-20 { let diff = pA - pB; d += diff * diff / den }
            }
            return d + outFrac * 2.0
        }

        // ── 3. Reference normalizations (computed once) ──────────────────────
        let (refUniW, _)  = buildUniform(refPts)
        let (refArcW, _)  = buildArcLen(refPts)
        let refUniTotal   = max(1e-10, refUniW.reduce(0, +))
        let refArcTotal   = max(1e-10, refArcW.reduce(0, +))
        let refUniNorm    = refUniW.map { $0 / refUniTotal }
        let refArcNorm    = refArcW.map { $0 / refArcTotal }

        // ── 4. gNa sweep ─────────────────────────────────────────────────────
        // Dense near the true value, sparser at the extremes.
        let multipliers: [Double] = [
            0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.85, 0.90, 0.95,
            1.00,                                   // ← true value
            1.05, 1.10, 1.20, 1.30, 1.50, 1.80, 2.00, 2.50
        ]

        struct Row {
            let gNa: Double; let mult: Double
            let sA, sB, sC, sD: Double   // method A/B/C/D scores
        }
        var rows: [Row] = []

        blog("\n  Running \(multipliers.count) candidate simulations…")
        for m in multipliers {
            let gNa = trueGNa * m

            // Fresh neuron with modified gNa (reference stays untouched)
            let candNeuron = HHNeuron(name: "cand")
            for ch in candNeuron.channels {
                if let na = ch as? SodiumChannel { na.gMax = gNa }
            }
            let candNet = Network()
            _ = candNet.addNeuron(candNeuron)
            candNet.setStimulus(PulseStimulus(start: 10, duration: 80, amplitude: 10),
                                on: candNeuron.id)
            let candSim = Simulator(network: candNet, dt: dt)
            candSim.method = .rushLarsen
            candSim.reset(restingVoltage: -65.0)
            let cNID = candNeuron.id

            let cPts = collectPts(sim: candSim, neuronID: cNID)

            let (uniW, uniOut) = buildUniform(cPts)
            let (arcW, arcOut) = buildArcLen(cPts)
            let uniTot         = uniW.reduce(0, +)
            let arcTot         = arcW.reduce(0, +)

            // If no pts (no spikes), every method gets the max-penalty score.
            if cPts.isEmpty {
                rows.append(Row(gNa: gNa, mult: m, sA: 2.0, sB: 2.0, sC: 2.0, sD: 2.0))
                blog(String(format: "    gNa=%5.1f (×%.2f)  → no spikes", gNa, m))
                continue
            }

            let sA = scoreSSD( refNorm: refUniNorm, cw: uniW, cTotal: uniTot, outFrac: uniOut)
            let sB = scoreChi2(refNorm: refUniNorm, cw: uniW, cTotal: uniTot, outFrac: uniOut)
            let sC = scoreSSD( refNorm: refArcNorm, cw: arcW, cTotal: arcTot, outFrac: arcOut)
            let sD = scoreChi2(refNorm: refArcNorm, cw: arcW, cTotal: arcTot, outFrac: arcOut)
            rows.append(Row(gNa: gNa, mult: m, sA: sA, sB: sB, sC: sC, sD: sD))
        }

        // ── 5. Results table ─────────────────────────────────────────────────
        blog("\n  ┌─────────┬───────┬─────────────┬─────────────┬─────────────┬─────────────┐")
        blog("  │  gNa    │ ×true │ A uni+SSD   │ B uni+χ²    │ C arc+SSD   │ D arc+χ²    │")
        blog("  ├─────────┼───────┼─────────────┼─────────────┼─────────────┼─────────────┤")
        for r in rows {
            let star = abs(r.mult - 1.0) < 0.001 ? " ★" : "  "
            blog(String(format: "  │ %7.2f │ %5.2f │ %11.4e │ %11.4e │ %11.4e │ %11.4e │%@",
                        r.gNa, r.mult, r.sA, r.sB, r.sC, r.sD, star))
        }
        blog("  └─────────┴───────┴─────────────┴─────────────┴─────────────┴─────────────┘")

        // ── 6. Quality metrics ────────────────────────────────────────────────
        //
        // The exact-match candidate gives minScore = 0 (same simulation twice),
        // so ratio-based metrics are undefined.  We instead report:
        //
        //   • argmin    — gNa where the score is lowest (correct = 56.0)
        //   • ±5/10/20% — mean absolute score at those offsets from true.
        //                 Higher = steeper gradient = richer signal for optimiser.
        //   • mono      — fraction of steps (moving away from true in either
        //                 direction) where the score strictly increases.
        //                 1.0 = clean bowl;  < 1.0 = flat or rugged near minimum.
        //
        func metrics(scores: [Double], label: String) {
            guard scores.count == rows.count else { return }
            let minScore = scores.min() ?? 0
            let argMin   = rows[scores.firstIndex(of: minScore) ?? 0].gNa

            func s(_ m: Double) -> Double {   // score at nearest multiplier
                scores[rows.indices.min(by: { abs(rows[$0].mult - m) < abs(rows[$1].mult - m) })!]
            }

            // Monotonicity check: walking outward from the true minimum,
            // score must not decrease.
            let trueIdx = rows.firstIndex(where: { abs($0.mult - 1.0) < 0.001 }) ?? 0
            var monoOK = 0; var monoTot = 0
            // Left side (rows 0..trueIdx reversed = walking away from true)
            for i in stride(from: trueIdx - 1, through: 0, by: -1) {
                monoTot += 1
                if scores[i] >= scores[i + 1] { monoOK += 1 }
            }
            // Right side (rows trueIdx..end = walking away from true)
            for i in (trueIdx + 1)..<rows.count {
                monoTot += 1
                if scores[i] >= scores[i - 1] { monoOK += 1 }
            }
            let mono = monoTot > 0 ? Double(monoOK) / Double(monoTot) : 1.0

            blog(String(format: "  %@  argmin=%5.1f  ±5%%=%.3e  ±10%%=%.3e  ±20%%=%.3e  mono=%.0f%%",
                        label, argMin,
                        (s(0.95) + s(1.05)) * 0.5,
                        (s(0.90) + s(1.10)) * 0.5,
                        (s(0.80) + s(1.20)) * 0.5,
                        mono * 100))
        }

        blog("\n  Quality metrics  (±X% = mean absolute score at ±X% from true gNa,")
        blog("                    higher = steeper gradient;  mono=100% = clean bowl)")
        metrics(scores: rows.map(\.sA), label: "A uni+SSD:")
        metrics(scores: rows.map(\.sB), label: "B uni+χ²: ")
        metrics(scores: rows.map(\.sC), label: "C arc+SSD:")
        metrics(scores: rows.map(\.sD), label: "D arc+χ²: ")

        // ── 7. Arc-length vs uniform gradient gain ────────────────────────────
        // Compare same distance formula (SSD or χ²) with arc-length vs uniform.
        // Using ±10% as the reference offset (typical coarse optimiser step).
        // Positive Δ = arc-length method delivers more gradient signal = better.
        func meanAt10(_ kp: KeyPath<Row, Double>) -> Double {
            let i90  = rows.indices.min(by: { abs(rows[$0].mult - 0.90) < abs(rows[$1].mult - 0.90) })!
            let i110 = rows.indices.min(by: { abs(rows[$0].mult - 1.10) < abs(rows[$1].mult - 1.10) })!
            return (rows[i90][keyPath: kp] + rows[i110][keyPath: kp]) * 0.5
        }
        let m10_A = meanAt10(\.sA); let m10_B = meanAt10(\.sB)
        let m10_C = meanAt10(\.sC); let m10_D = meanAt10(\.sD)

        blog("\n  Gradient gain: arc-length vs uniform at ±10% from true gNa:")
        blog(String(format: "  SSD:  arc(C)=%.3e  uniform(A)=%.3e  gain=+%.0f%%",
                    m10_C, m10_A, (m10_C / max(m10_A, 1e-30) - 1.0) * 100))
        blog(String(format: "  χ²:   arc(D)=%.3e  uniform(B)=%.3e  gain=+%.0f%%",
                    m10_D, m10_B, (m10_D / max(m10_B, 1e-30) - 1.0) * 100))
        blog("  (+gain = arc-length formula has steeper landscape near min)")
        blog("  (−gain = uniform formula has steeper landscape near min)")

        flushBlog()
    }

    // ── 13. Algorithm benchmark — DE vs CMA-ES vs ABC ────────────────────────
    //
    //  Empirical convergence comparison on a 2-parameter HH recovery problem:
    //    · Recover (gNa, gK) from a reference trace — the same problem as test_12
    //      but now letting an optimizer search instead of scanning a grid.
    //    · Score: arc-length χ² (production formula D from test_12)
    //    · Budget: up to MAX_EVALS evaluations per trial
    //    · N_TRIALS independent runs per algorithm (different random seeds)
    //    · Metric: evals to first E < threshold, median final error
    //
    func test_13_algorithmBenchmark() {

        // ── Config ─────────────────────────────────────────────────────────
        let trueGNa   = 56.0          // SodiumChannel default
        let trueGK    = 12.0          // PotassiumChannel default
        let bounds: [(lo: Double, hi: Double)] = [(14.0, 168.0), (3.0, 36.0)]
        let nV        = 80;  let nD   = 60
        let simDur    = 300.0         // ms — enough for several spikes
        let dt        = 0.025
        let N_TRIALS  = 5
        let MAX_EVALS = 300
        let threshold = 0.05          // "converged" criterion

        blog("\n═══════════════════════════════════════════════════════")
        blog("13. Algorithm benchmark — 2D parameter recovery (DE vs CMA-ES vs ABC)")
        blog("    Target: gNa=\(trueGNa), gK=\(trueGK)")
        blog("    Bounds: gNa∈[14,168], gK∈[3,36]  (0.25× – 3× true)")
        blog("    Score: arc-length χ²  |  grid \(nV)×\(nD)  |  \(Int(simDur)) ms sim")
        blog("    Budget: \(MAX_EVALS) evals/trial  |  \(N_TRIALS) trials/algo  |  threshold E<\(threshold)")
        blog("═══════════════════════════════════════════════════════")

        // ── 1. Reference simulation ─────────────────────────────────────────
        let refNet = makeNetwork(neurons: 1)
        let refSim = Simulator(network: refNet, dt: dt)
        refSim.method = .rushLarsen
        refSim.reset(restingVoltage: -65.0)
        guard let refNID = refNet.neurons.first?.id else { return }

        let refPts = collectPhasePts(sim: refSim, neuronID: refNID, duration: simDur)
        blog("  Reference pts: \(refPts.count)")
        guard !refPts.isEmpty else { blog("  ERROR: no ref pts — abort"); return }

        guard let refGrid = buildEvalGrid(refPts, nV: nV, nD: nD) else { return }
        let tRef    = max(1e-10, refGrid.totalWeight)
        let refNorm = refGrid.weights.map { $0 / tRef }

        // ── 2. Shared candidate infrastructure ──────────────────────────────
        // Reuse one HHNeuron + Simulator across all evaluations — just mutate gMax
        // and reset the integrator between runs (same approach as OptimizationRunner).
        let candNeuron = HHNeuron(name: "cand")
        let candNet    = Network()
        candNet.addNeuron(candNeuron)
        candNet.setStimulus(PulseStimulus(start: 10, duration: 80, amplitude: 10),
                            on: candNeuron.id)
        let candSim = Simulator(network: candNet, dt: dt)
        candSim.method = .rushLarsen

        var evalCallCount = 0
        let score: ([Double]) -> Double = { params in
            evalCallCount += 1
            let gNa = params[0]; let gK = params[1]
            for ch in candNeuron.channels {
                if let na = ch as? SodiumChannel    { na.gMax = gNa }
                if let k  = ch as? PotassiumChannel { k.gMax  = gK  }
            }
            candSim.reset(restingVoltage: -65.0)
            let cPts = collectPhasePts(sim: candSim, neuronID: candNeuron.id, duration: simDur)
            if cPts.isEmpty { return 2.0 }
            let cg = buildEvalGridInRange(cPts,
                                          vLo: refGrid.vMin, vHi: refGrid.vMax,
                                          dLo: refGrid.dvdtMin, dHi: refGrid.dvdtMax,
                                          nV: nV, nD: nD)
            return chiSquaredFast(refNorm: refNorm, cg: cg)
        }

        // ── 3. Trial-runner helpers ──────────────────────────────────────────
        struct TrialResult {
            let evalsToThresh: Int?    // nil if never converged within budget
            let finalError:    Double
            let wallSeconds:   Double
        }

        func medianInt(_ vals: [Int?]) -> String {
            let good = vals.compactMap { $0 }.sorted()
            guard !good.isEmpty else { return "  >budget" }
            let i = good.count / 2
            return String(format: "%9d", good.count % 2 == 0 ? (good[i-1]+good[i])/2 : good[i])
        }
        func medianDouble(_ vals: [Double]) -> Double {
            let s = vals.sorted(); let i = s.count / 2
            return s.count % 2 == 0 ? (s[i-1]+s[i])/2 : s[i]
        }

        // ── DE trial ────────────────────────────────────────────────────────
        func runDETrial() -> TrialResult {
            let t0 = ContinuousClock().now
            var de = DifferentialEvolution(bounds: bounds, popFactor: 6, F: 0.8, CR: 0.9)
            // Init population
            var fit  = de.initialCandidates().map { score($0) }
            de.setInitialFitness(fit)
            var bestErr = fit.min() ?? .infinity
            var totalEvals = de.popSize
            var evalsToThresh: Int? = bestErr < threshold ? totalEvals : nil
            // Generational loop — full generations only
            while totalEvals + de.popSize <= MAX_EVALS {
                let trials = de.generateTrials()
                let errs   = trials.map { score($0) }
                _ = de.applyTrials(trials, errors: errs)
                let genBest = de.fitness.min() ?? bestErr
                if genBest < bestErr {
                    bestErr = genBest
                    if evalsToThresh == nil && bestErr < threshold { evalsToThresh = totalEvals }
                }
                totalEvals += de.popSize
                if bestErr < threshold && evalsToThresh == nil { evalsToThresh = totalEvals }
            }
            let elapsed = ContinuousClock().now - t0
            let wallS = Double(elapsed.components.seconds) +
                        Double(elapsed.components.attoseconds) / 1e18
            return TrialResult(evalsToThresh: evalsToThresh, finalError: bestErr, wallSeconds: wallS)
        }

        // ── CMA-ES trial ─────────────────────────────────────────────────────
        func runCMAESTrial() -> TrialResult {
            let t0 = ContinuousClock().now
            var cma = CMAES(bounds: bounds, sigma0fraction: 0.25)
            var bestErr = Double.infinity
            var totalEvals = 0
            var evalsToThresh: Int? = nil
            while totalEvals + cma.lambda <= MAX_EVALS {
                let offs = cma.generateOffspring()
                let errs = offs.map { score($0.x) }
                _ = cma.applyOffspring(offs, errors: errs)
                let genBest = errs.min() ?? bestErr
                if genBest < bestErr { bestErr = genBest }
                totalEvals += cma.lambda
                if bestErr < threshold && evalsToThresh == nil { evalsToThresh = totalEvals }
            }
            let elapsed = ContinuousClock().now - t0
            let wallS = Double(elapsed.components.seconds) +
                        Double(elapsed.components.attoseconds) / 1e18
            return TrialResult(evalsToThresh: evalsToThresh, finalError: bestErr, wallSeconds: wallS)
        }

        // ── ABC trial ────────────────────────────────────────────────────────
        func runABCTrial() -> TrialResult {
            let t0 = ContinuousClock().now
            // colonySize=12 so each gen = 2×12=24 evals — comparable to DE/CMA-ES per gen
            var abc = ArtificialBeeColony(bounds: bounds, colonySize: 12,
                                          tabuEnabled: true, tabuStagnation: 20)
            var initFit = abc.initialCandidates().map { score($0) }
            abc.setInitialFitness(initFit)
            var bestErr   = initFit.min() ?? .infinity
            var bestParams = abc.sources[initFit.indices.min { initFit[$0] < initFit[$1] }!]
            var totalEvals = abc.colonySize
            var evalsToThresh: Int? = bestErr < threshold ? totalEvals : nil
            let evalsPerGen = 2 * abc.colonySize   // employed + onlooker
            while totalEvals + evalsPerGen <= MAX_EVALS {
                let prevBest = bestErr
                // Employed phase
                for (si, cand) in abc.employedCandidates() {
                    let err = score(cand)
                    abc.applyEmployed(sourceIdx: si, candidate: cand, error: err)
                    if err < bestErr { bestErr = err; bestParams = cand }
                }
                // Onlooker phase
                for (si, cand) in abc.onlookerCandidates() {
                    let err = score(cand)
                    abc.applyOnlooker(sourceIdx: si, candidate: cand, error: err)
                    if err < bestErr { bestErr = err; bestParams = cand }
                }
                _ = abc.finishGeneration(globalBestImproved: bestErr < prevBest,
                                         bestParams: bestParams)
                totalEvals += evalsPerGen
                if bestErr < threshold && evalsToThresh == nil { evalsToThresh = totalEvals }
            }
            let elapsed = ContinuousClock().now - t0
            let wallS = Double(elapsed.components.seconds) +
                        Double(elapsed.components.attoseconds) / 1e18
            return TrialResult(evalsToThresh: evalsToThresh, finalError: bestErr, wallSeconds: wallS)
        }

        // ── 4. Run all trials ────────────────────────────────────────────────
        blog("\n  Running DE (\(N_TRIALS) trials)…")
        evalCallCount = 0
        let deT  = (0..<N_TRIALS).map { _ in runDETrial()    }
        blog(String(format: "    evals used: %d", evalCallCount))

        blog("  Running CMA-ES (\(N_TRIALS) trials)…")
        evalCallCount = 0
        let cmaT = (0..<N_TRIALS).map { _ in runCMAESTrial() }
        blog(String(format: "    evals used: %d", evalCallCount))

        blog("  Running ABC (\(N_TRIALS) trials)…")
        evalCallCount = 0
        let abcT = (0..<N_TRIALS).map { _ in runABCTrial()   }
        blog(String(format: "    evals used: %d", evalCallCount))

        // ── 5. Results ────────────────────────────────────────────────────────
        let algoNames  = ["DE      ", "CMA-ES  ", "ABC     "]
        let algoTrials = [deT, cmaT, abcT]

        blog(String(format: "\n  ─── Summary  (threshold E < %.2f,  budget %d evals,  %d trials) ───",
                    threshold, MAX_EVALS, N_TRIALS))
        blog("  ┌──────────┬────────────────────┬─────────────┬──────────┐")
        blog("  │ Algo     │ Evals to threshold  │ Final E     │ Wall     │")
        blog("  │          │ (median | % success)│ (median)    │ (median) │")
        blog("  ├──────────┼────────────────────┼─────────────┼──────────┤")
        for (name, trials) in zip(algoNames, algoTrials) {
            let succ  = trials.filter { $0.evalsToThresh != nil }.count
            let med   = medianInt(trials.map { $0.evalsToThresh })
            let medE  = medianDouble(trials.map { $0.finalError })
            let medW  = medianDouble(trials.map { $0.wallSeconds })
            blog(String(format: "  │ %@ │ %@ | %3d%%       │ %11.4e │ %6.2f s  │",
                        name, med, succ * 100 / N_TRIALS, medE, medW))
        }
        blog("  └──────────┴────────────────────┴─────────────┴──────────┘")

        // Per-trial detail
        blog("\n  Per-trial  [evalsToThresh | finalError]:")
        for (name, trials) in zip(algoNames, algoTrials) {
            let detail = trials.map { t in
                let e = t.evalsToThresh.map { String($0) } ?? "N/A"
                return String(format: "%@|%.3e", e, t.finalError)
            }.joined(separator: "  ")
            blog("  \(name.trimmingCharacters(in: .whitespaces)): \(detail)")
        }

        flushBlog()
    }
}
