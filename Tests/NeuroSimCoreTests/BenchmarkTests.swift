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
}
