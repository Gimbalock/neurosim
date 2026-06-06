//
//  ModelSweepView.swift
//  NeuroSimApp
//
//  General model sweep — brute-force exploration of any neuron's parameter
//  space for any supported objective (density match or burst score).
//
//  Layout:
//    ┌─────────────────┬──────────────────────────────────────────┐
//    │  Sidebar        │  Results table  (sorted best-first)      │
//    │  · neuron       │  Score │ P1 │ P2 │ P3 │  [Appliquer]    │
//    │  · parameters   ├──────────────────────────────────────────┤
//    │  · objective    │  …rows…                                  │
//    │  · duration     │                                          │
//    │  · [Start]      │                                          │
//    └─────────────────┴──────────────────────────────────────────┘
//

import SwiftUI
import NeuroSimCore

// MARK: - Objective picker

private enum SweepObjectiveMode: String, CaseIterable, Identifiable {
    case density = "Densité de trajectoire"
    case burst   = "Score de burst"
    var id: String { rawValue }
}

// MARK: - View

struct ModelSweepView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @StateObject private var runner = ModelSweepRunner()

    // ── Neuron selection ──────────────────────────────────────────────────
    @State private var selectedNeuronIdx: Int = 0
    @State private var optimParams: [OptimParam] = []

    // ── Sweep parameters (up to 3) ────────────────────────────────────────
    @State private var paramCount: Int = 1   // 1, 2, or 3
    @State private var specs: [SweepParamSpec] = []
    // Indices into optimParams for each slot
    @State private var paramIdx0: Int = 0
    @State private var paramIdx1: Int = 1
    @State private var paramIdx2: Int = 2

    // ── Objective ─────────────────────────────────────────────────────────
    @State private var objectiveMode: SweepObjectiveMode = .density
    // Density
    @State private var refNeuronIdx: Int = 0
    // Burst
    @State private var burstRestingV:    Double = -65.0
    @State private var burstTargetBPS:   Double = 1.0
    @State private var burstTargetAPs:   Double = 12.5
    @State private var burstTargetMs:    Double = 1000.0

    // ── Simulation config ─────────────────────────────────────────────────
    @State private var simDuration: Double = 500.0

    // MARK: - Derived

    private var availableNeurons: [HHNeuron] { vm.network.neurons }

    private var selectedNeuron: HHNeuron? {
        availableNeurons[safe: selectedNeuronIdx] ?? availableNeurons.first
    }

    private var refPoints: [(v: Double, dvdt: Double)] {
        guard availableNeurons.indices.contains(refNeuronIdx),
              let trace = vm.traces[availableNeurons[refNeuronIdx].id],
              trace.count >= 2 else { return [] }
        return phasePlanePoints(from: trace.map { (t: $0.t, v: $0.v) })
    }

    private var activeParamIndices: [Int] {
        switch paramCount {
        case 1: return [paramIdx0]
        case 2: return [paramIdx0, paramIdx1]
        default: return [paramIdx0, paramIdx1, paramIdx2]
        }
    }

    private var totalEvals: Int {
        activeParamIndices.compactMap { optimParams[safe: $0] }.enumerated()
            .reduce(1) { acc, el in
                let sp = specs[safe: el.offset]
                return acc * max(1, sp?.values.count ?? 1)
            }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, maxWidth: 290)
                .background(.background.secondary)

            resultsPanel
        }
        .onAppear { rebuildParams() }
        .onChange(of: selectedNeuronIdx) { _, _ in rebuildParams() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Text("Model Sweep")
                    .font(.title3.bold())
                    .padding(.top, 4)

                // ── Neuron ──────────────────────────────────────────
                GroupBox {
                    Picker("Neurone", selection: $selectedNeuronIdx) {
                        ForEach(Array(availableNeurons.enumerated()), id: \.offset) { i, n in
                            Text(n.name).tag(i)
                        }
                    }
                } label: {
                    Label("Neurone", systemImage: "brain")
                        .font(.caption.bold())
                }

                // ── Parameters ───────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Nombre de paramètres")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $paramCount) {
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("3").tag(3)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 90)
                        }

                        if optimParams.isEmpty {
                            Text("Aucun paramètre disponible")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            paramSlot(idx: $paramIdx0, slotIndex: 0, label: "P1")
                            if paramCount >= 2 {
                                Divider()
                                paramSlot(idx: $paramIdx1, slotIndex: 1, label: "P2")
                            }
                            if paramCount >= 3 {
                                Divider()
                                paramSlot(idx: $paramIdx2, slotIndex: 2, label: "P3")
                            }
                        }

                        let n = totalEvals
                        Text("\(n) simulation\(n == 1 ? "" : "s") au total")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                } label: {
                    Label("Paramètres", systemImage: "slider.horizontal.3")
                        .font(.caption.bold())
                }

                // ── Objective ────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Objectif", selection: $objectiveMode) {
                            ForEach(SweepObjectiveMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }

                        if objectiveMode == .density {
                            sectionLabel("Trace de référence")
                            Picker("", selection: $refNeuronIdx) {
                                ForEach(Array(availableNeurons.enumerated()), id: \.offset) { i, n in
                                    let ok = (vm.traces[n.id]?.count ?? 0) >= 2
                                    Text(n.name + (ok ? "" : " ✗")).tag(i)
                                }
                            }
                            .labelsHidden()
                            if refPoints.isEmpty {
                                Label("Lancez une simulation d'abord",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        } else {
                            sectionLabel("Config burst")
                            compactField("V repos", val: $burstRestingV, unit: "mV")
                            compactField("Cible BPS", val: $burstTargetBPS, unit: "/s")
                            compactField("Cible AP/burst", val: $burstTargetAPs, unit: "")
                            compactField("Période cible", val: $burstTargetMs, unit: "ms")
                        }
                    }
                } label: {
                    Label("Objectif", systemImage: "target")
                        .font(.caption.bold())
                }

                // ── Duration ─────────────────────────────────────────
                GroupBox {
                    HStack {
                        Text("Durée sim.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        TextField("ms", value: $simDuration, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .font(.system(size: 11).monospacedDigit())
                        Text("ms").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Simulation", systemImage: "clock")
                        .font(.caption.bold())
                }

                // ── Run / Stop ───────────────────────────────────────
                Button {
                    if runner.isRunning { runner.stop() } else { startSweep() }
                } label: {
                    Label(runner.isRunning ? "Arrêter" : "Démarrer le sweep",
                          systemImage: runner.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(runner.isRunning ? .red : .accentColor)
                .disabled(!runner.isRunning && cannotRun)

                // Progress
                if runner.totalEvals > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: runner.progress).progressViewStyle(.linear)
                        Text(runner.status)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Text("\(runner.doneEvals) / \(runner.totalEvals)")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }

                // Apply best
                if let best = runner.results.first, !runner.isRunning {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Meilleur résultat", systemImage: "star.fill")
                            .font(.caption.bold()).foregroundStyle(.yellow)
                        HStack {
                            Button("Appliquer le meilleur") {
                                applyResult(best)
                            }
                            .buttonStyle(.bordered)
                            Button("Appliquer + Run") {
                                applyResult(best)
                                vm.play()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Spacer(minLength: 12)
            }
            .padding(12)
        }
    }

    // MARK: - Results panel

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            resultHeader
            Divider()
            if runner.results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(runner.results.enumerated()), id: \.element.id) { idx, r in
                            resultRow(r, rank: idx + 1)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private var resultHeader: some View {
        HStack(spacing: 0) {
            colLabel("#",      width: 28, align: .trailing)
            colLabel("Score",  width: 72, align: .trailing)
            ForEach(Array(headerLabels.enumerated()), id: \.offset) { _, label in
                colLabel(label, width: 88, align: .trailing)
            }
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.tertiary)
    }

    @ViewBuilder
    private func resultRow(_ r: ModelSweepResult, rank: Int) -> some View {
        HStack(spacing: 0) {
            colValue("\(rank)",                width: 28, align: .trailing)
                .foregroundStyle(rank == 1 ? .yellow : rank <= 3 ? .orange : .secondary)
            colValue(scoreStr(r.score),        width: 72, align: .trailing)
                .fontWeight(rank == 1 ? .semibold : .regular)
            ForEach(Array(r.paramValues.enumerated()), id: \.offset) { i, v in
                colValue(formatVal(v, param: specs[safe: i]?.param),
                         width: 88, align: .trailing)
            }
            Spacer()
            Button("Appliquer") { applyResult(r) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(runner.isRunning)
                .padding(.trailing, 10)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(rank == 1 ? Color.green.opacity(0.08)
                    : rank <= 3 ? Color.orange.opacity(0.04)
                    : Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.xaxis.ascending.badge.clock")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Configurez les paramètres et lancez le sweep")
                    .font(.callout).foregroundStyle(.secondary)
                Text("L'exploration brute force teste toutes les combinaisons")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var cannotRun: Bool {
        optimParams.isEmpty ||
        (objectiveMode == .density && refPoints.isEmpty) ||
        selectedNeuron == nil
    }

    private var headerLabels: [String] {
        activeParamIndices.compactMap { optimParams[safe: $0]?.label }
    }

    private func startSweep() {
        guard let neuron = selectedNeuron else { return }
        rebuildSpecs()
        let activePSpecs = activeParamIndices.compactMap { i -> SweepParamSpec? in
            guard optimParams[safe: i] != nil else { return nil }
            let si = activeParamIndices.firstIndex(of: i)!
            return specs[safe: si]
        }
        guard !activePSpecs.isEmpty else { return }

        let objective: ModelSweepRunner.SweepObjective
        switch objectiveMode {
        case .density:
            objective = .density(refPoints: refPoints, nBinsV: 80, nBinsDvdt: 60)
        case .burst:
            objective = .burst(aisCompartmentID: nil,
                               restingVoltage:   burstRestingV,
                               targetBPS:        burstTargetBPS,
                               targetAPsPerBurst: burstTargetAPs,
                               targetPeriodMs:   burstTargetMs)
        }

        runner.start(vm: vm, neuronID: neuron.id,
                     paramSpecs: activePSpecs,
                     objective: objective,
                     simDuration: simDuration)
    }

    private func applyResult(_ r: ModelSweepResult) {
        guard let neuron = selectedNeuron else { return }
        let activePSpecs: [SweepParamSpec] = activeParamIndices.enumerated().compactMap { _, i in
            specs[safe: activeParamIndices.firstIndex(of: i)!]
        }
        runner.apply(result: r, paramSpecs: activePSpecs,
                     neuronID: neuron.id, vm: vm)
    }

    private func rebuildParams() {
        guard let neuron = selectedNeuron else { optimParams = []; specs = []; return }
        optimParams = makeOptimParams(for: neuron)
        let n = optimParams.count
        paramIdx0 = 0
        paramIdx1 = n > 1 ? 1 : 0
        paramIdx2 = n > 2 ? 2 : (n > 1 ? 1 : 0)
        rebuildSpecs()
    }

    private func rebuildSpecs() {
        guard !optimParams.isEmpty else { specs = []; return }
        specs = activeParamIndices.map { i in
            let p = optimParams[safe: i] ?? optimParams[0]
            var s = SweepParamSpec(param: p, values: [], steps: 8, logSpacing: false)
            s.values = SweepParamSpec.makeValues(minV: p.minBound, maxV: p.maxBound,
                                                  steps: s.steps, log: s.logSpacing)
            return s
        }
    }

    private func scoreStr(_ s: Double) -> String {
        if s.isInfinite || s.isNaN { return "—" }
        return String(format: "%.3e", s)
    }

    private func formatVal(_ v: Double, param: OptimParam?) -> String {
        let u = param?.unit ?? ""
        if abs(v) >= 100 { return String(format: "%.0f \(u)", v) }
        if abs(v) >= 0.1  { return String(format: "%.3g \(u)", v) }
        return String(format: "%.2e \(u)", v)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func paramSlot(idx: Binding<Int>, slotIndex: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label + " :").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: idx) {
                    ForEach(Array(optimParams.enumerated()), id: \.offset) { i, p in
                        Text(p.label).tag(i)
                    }
                }
                .labelsHidden()
                .font(.system(size: 11))
            }
            // Steps + log toggle
            HStack(spacing: 8) {
                Stepper(value: Binding(
                    get: { specs[safe: slotIndex]?.steps ?? 8 },
                    set: { newVal in
                        guard specs.indices.contains(slotIndex) else { return }
                        specs[slotIndex].steps = max(2, min(20, newVal))
                        rebuildSpecValues(slotIndex: slotIndex)
                    }
                ), in: 2...20) {
                    Text("\(specs[safe: slotIndex]?.steps ?? 8) pts")
                        .font(.system(size: 11))
                }
                .frame(maxWidth: 120)

                Toggle(isOn: Binding(
                    get: { specs[safe: slotIndex]?.logSpacing ?? false },
                    set: { val in
                        guard specs.indices.contains(slotIndex) else { return }
                        specs[slotIndex].logSpacing = val
                        rebuildSpecValues(slotIndex: slotIndex)
                    }
                )) {
                    Text("Log").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func rebuildSpecValues(slotIndex: Int) {
        guard specs.indices.contains(slotIndex) else { return }
        let s = specs[slotIndex]
        specs[slotIndex].values = SweepParamSpec.makeValues(
            minV: s.param.minBound, maxV: s.param.maxBound,
            steps: s.steps, log: s.logSpacing)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func compactField(_ label: String, val: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(label + " :").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            TextField("", value: val, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.system(size: 11).monospacedDigit())
            if !unit.isEmpty {
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func colLabel(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text).frame(width: width, alignment: align)
    }

    @ViewBuilder
    private func colValue(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text).frame(width: width, alignment: align)
    }
}
