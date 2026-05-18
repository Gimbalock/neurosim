//
//  EnergyView.swift
//  NeuroSimApp
//
//  Metabolic energy dashboard — v3:
//
//   ┌─── control bar ──────────────────────────────────────────────────────┐
//   ├─── Section A: MiniGauge grid (7 × individual Y scales) ──────────────┤
//   │   Valeur en gros au-dessus · barre · label/unité en dessous          │
//   ├──────────────────────────────────────────────────────────────────────┤
//   │  ┌── Section B: ATP consommé / neurone (bar chart) ──────────────────┤
//   ├──────────────────────────────────────────────────────────────────────┤
//   │  Section C: Coût énergétique — grand panel                           │
//   ├──────────────────────────────────────────────────────────────────────┤
//   │  Section D: Pompe Na/K — demande · débit réel · déficit (timeline)   │
//   └──────────────────────────────────────────────────────────────────────┘

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - MiniGauge

private struct GaugeSpec {
    let id: String
    let label: String
    let unit: String
    let value: Double
    let yMin: Double
    let yMax: Double
    let refValue: Double?
    let color: Color
}

/// Vertical bar gauge with its own Y domain.
/// Current value is displayed ABOVE the chart to avoid any in-chart overlap.
private struct MiniGauge: View {
    let spec: GaugeSpec

    var body: some View {
        VStack(spacing: 0) {
            // ── Current value — large, outside the chart ──────────────────
            Text(formatted)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(spec.color)
                .frame(height: 20)

            // ── Bar chart ─────────────────────────────────────────────────
            Chart {
                BarMark(
                    x: .value("", spec.label),
                    yStart: .value("", spec.yMin),
                    yEnd: .value("", clamped)
                )
                .foregroundStyle(spec.color.gradient)

                if let ref = spec.refValue {
                    RuleMark(y: .value("réf", ref))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(spec.color.opacity(0.55))
                }
            }
            .chartYScale(domain: spec.yMin...spec.yMax)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [spec.yMin, spec.yMax]) {
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                        .font(.system(size: 7))
                }
            }
            .frame(width: 68, height: 110)

            // ── Label + unit below ────────────────────────────────────────
            VStack(spacing: 1) {
                Text(spec.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(spec.color)
                Text(spec.unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 3)
        }
    }

    private var clamped: Double { max(spec.yMin, min(spec.yMax, spec.value)) }

    private var formatted: String {
        let v = spec.value
        if abs(v) < 1   { return String(format: "%.3f", v) }
        if abs(v) < 10  { return String(format: "%.2f", v) }
        return String(format: "%.1f", v)
    }
}

// MARK: - Network bar item (for Section B)

private struct NetworkBarItem: Identifiable {
    let id: UUID
    let name: String
    let consumed: Double  // mM
}

// MARK: - EnergyView

struct EnergyView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var selectedNeuronID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let nid = selectedNeuronID,
               let neuron = vm.network.neurons.first(where: { $0.id == nid }) {
                if neuron.energyParams.enabled {
                    if let pts = vm.energyTraces[nid], !pts.isEmpty {
                        mainContent(pts: pts, neuron: neuron)
                    } else {
                        placeholder("Lancez la simulation pour collecter les données")
                    }
                } else {
                    enablePrompt(neuron: neuron)
                }
            } else {
                placeholder("Sélectionnez un neurone")
            }
        }
        .onAppear { autoSelect() }
        .onChange(of: vm.network.neurons.map(\.id)) { _, _ in autoSelect() }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if vm.network.neurons.isEmpty {
                    Text("Aucun neurone").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Neurone", selection: $selectedNeuronID) {
                        ForEach(vm.network.neurons) { n in
                            Text(n.name).tag(Optional(n.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                Divider().frame(height: 24)

                if let nid = selectedNeuronID,
                   let idx = vm.network.neurons.firstIndex(where: { $0.id == nid }) {
                    Toggle("Modèle énergie", isOn: Binding(
                        get: { vm.network.neurons[idx].energyParams.enabled },
                        set: { v in
                            vm.network.neurons[idx].energyParams.enabled = v
                            vm.objectWillChange.send()
                        }))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))

                    if vm.network.neurons[idx].energyParams.enabled {
                        Divider().frame(height: 24)
                        paramField("J_pump max",
                                   value: Binding(
                                    get: { vm.network.neurons[idx].energyParams.pumpJmax },
                                    set: { vm.network.neurons[idx].energyParams.pumpJmax = $0; vm.objectWillChange.send() }),
                                   unit: "mM/ms", width: 56)
                        mitoHealthControl(idx: idx)

                        // ── Extracellular clamp badge ─────────────────────────
                        if !vm.network.neurons[idx].energyParams.clampExtracellular {
                            Label("Ischémie", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        }

                        paramField("J_mito",
                                   value: Binding(
                                    get: { vm.network.neurons[idx].energyParams.mitoJmax },
                                    set: { vm.network.neurons[idx].energyParams.mitoJmax = $0; vm.objectWillChange.send() }),
                                   unit: "mM/ms", width: 56)
                        paramField("[ATP]₀",
                                   value: Binding(
                                    get: { vm.network.neurons[idx].energyParams.atp0 },
                                    set: { vm.network.neurons[idx].energyParams.atp0 = $0; vm.objectWillChange.send() }),
                                   unit: "mM", width: 44)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 44)
    }

    // MARK: - Main content

    @ViewBuilder
    private func mainContent(pts: [SimulationViewModel.EnergyPlotPoint],
                             neuron: HHNeuron) -> some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── A: MiniGauge snapshot ─────────────────────────────────
                sectionA(pts: pts)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                Divider().padding(.vertical, 8)

                // ── B: Network ATP bar chart ──────────────────────────────
                sectionB()
                    .padding(.horizontal, 14)

                Divider().padding(.vertical, 8)

                // ── C: Cost summary — full width, large text ──────────────
                sectionC(pts: pts, neuron: neuron)
                    .padding(.horizontal, 14)

                Divider().padding(.vertical, 8)

                // ── D: Pump demand vs rate vs deficit ─────────────────────
                sectionD(pts: pts)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    // MARK: - Section A: MiniGauge snapshot

    @ViewBuilder
    private func sectionA(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        let last = pts.last!
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Instantané — snapshot courant")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    // Nernst group
                    MiniGauge(spec: GaugeSpec(id: "eNa", label: "E_Na", unit: "mV",
                        value: last.eNa, yMin: 50, yMax: 80, refValue: 67, color: .blue))
                    MiniGauge(spec: GaugeSpec(id: "eK", label: "E_K", unit: "mV",
                        value: last.eK, yMin: -110, yMax: -80, refValue: -98, color: .orange))

                    gaugeGroupDivider()

                    // Ion concentrations
                    MiniGauge(spec: GaugeSpec(id: "naI", label: "[Na]ᵢ", unit: "mM",
                        value: last.naI, yMin: 10, yMax: 30, refValue: 15, color: .blue))
                    MiniGauge(spec: GaugeSpec(id: "kI", label: "[K]ᵢ", unit: "mM",
                        value: last.kI, yMin: 100, yMax: 145, refValue: 140, color: .orange))

                    gaugeGroupDivider()

                    // Metabolites
                    MiniGauge(spec: GaugeSpec(id: "atp", label: "[ATP]", unit: "mM",
                        value: last.atp, yMin: 0, yMax: 3, refValue: 2, color: .green))
                    MiniGauge(spec: GaugeSpec(id: "adp", label: "[ADP]", unit: "mM",
                        value: last.adp, yMin: 0, yMax: 0.5, refValue: 0.2, color: .yellow))
                    MiniGauge(spec: GaugeSpec(id: "pi", label: "[Pi]", unit: "mM",
                        value: last.pi, yMin: 0, yMax: 5, refValue: 2.5, color: .purple))
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func gaugeGroupDivider() -> some View {
        Divider().frame(width: 1, height: 160)
            .padding(.horizontal, 2)
    }

    // MARK: - Section B: Network ATP bar chart

    @ViewBuilder
    private func sectionB() -> some View {
        let energyNeurons = vm.network.neurons.filter { $0.energyParams.enabled }

        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ATP consommé — par neurone")

            if energyNeurons.isEmpty {
                Text("Aucun neurone avec énergie activée")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                // Build items outside chart builder
                let items: [NetworkBarItem] = energyNeurons.compactMap { neuron in
                    guard let nPts = vm.energyTraces[neuron.id],
                          let first = nPts.first, let last = nPts.last
                    else { return nil }
                    return NetworkBarItem(id: neuron.id, name: neuron.name,
                                         consumed: last.atpConsumed - first.atpConsumed)
                }

                if items.isEmpty {
                    Text("Données insuffisantes — lancez la simulation")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Chart(items) { item in
                        BarMark(
                            x: .value("Neurone", item.name),
                            y: .value("ATP (mM)", item.consumed)
                        )
                        .foregroundStyle(by: .value("Neurone", item.name))
                        .annotation(position: .top, spacing: 4) {
                            Text(String(format: "%.5f mM", item.consumed))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let name = value.as(String.self) {
                                    Text(name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .chartYAxisLabel("ATP consommé (mM)", alignment: .center)
                    .chartLegend(.hidden)
                    .frame(height: max(100, CGFloat(items.count) * 44 + 40))

                    // Total réseau
                    let total = items.reduce(0.0) { $0 + $1.consumed }
                    HStack {
                        Text("Total réseau")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(String(format: "%.5f mM", total))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Section C: Cost per spike — large panel

    @ViewBuilder
    private func sectionC(pts: [SimulationViewModel.EnergyPlotPoint],
                           neuron: HHNeuron) -> some View {
        let spikeCount = countSpikes(neuronID: neuron.id)
        let first = pts.first!
        let last  = pts.last!
        let totalATP = last.atpConsumed - first.atpConsumed
        let somaVol  = neuron.compartments
            .first(where: { $0.id == neuron.somaCompartmentID })?.volume ?? 1e-12

        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Coût énergétique — résumé")

            if spikeCount > 0 {
                let costPerSpike = totalATP / Double(spikeCount)
                let molecules    = costPerSpike * 1e-3 * somaVol * 6.022e23
                let log10mol     = molecules > 0 ? log10(molecules) : 0
                let mantissa     = molecules / pow(10, floor(log10mol))
                let exponent     = Int(floor(log10mol))

                // Top row: spike count + ATP/spike
                HStack(spacing: 20) {
                    bigCostCard(
                        icon: "waveform.path.ecg",
                        title: "Potentiels d'action",
                        value: "\(spikeCount)",
                        unit: "PA",
                        color: .blue)

                    bigCostCard(
                        icon: "bolt.fill",
                        title: "ATP par PA",
                        value: String(format: "%.5f", costPerSpike),
                        unit: "mM / PA",
                        color: .green)

                    bigCostCard(
                        icon: "atom",
                        title: "Molécules ATP / PA",
                        value: String(format: "%.1f × 10^%d", mantissa, exponent),
                        unit: "molécules",
                        color: .orange)
                }

                // Second row: volume + total ATP
                HStack(spacing: 20) {
                    bigCostCard(
                        icon: "cube",
                        title: "Volume soma",
                        value: String(format: "%.1f", somaVol * 1e15),
                        unit: "µm³",
                        color: .purple)

                    bigCostCard(
                        icon: "chart.bar.fill",
                        title: "ATP total consommé",
                        value: String(format: "%.5f", totalATP),
                        unit: "mM",
                        color: .teal)
                }
            } else {
                HStack(spacing: 20) {
                    bigCostCard(
                        icon: "chart.bar.fill",
                        title: "ATP total consommé",
                        value: String(format: "%.5f", totalATP),
                        unit: "mM",
                        color: .teal)

                    bigCostCard(
                        icon: "cube",
                        title: "Volume soma",
                        value: String(format: "%.1f", somaVol * 1e15),
                        unit: "µm³",
                        color: .purple)
                }
                Text("Aucun potentiel d'action détecté — stimulez le neurone pour obtenir le coût/PA.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func bigCostCard(icon: String, title: String, value: String,
                              unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(color.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Section D: Pump demand vs rate vs deficit

    @ViewBuilder
    private func sectionD(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Pompe Na/K — demande · débit réel · déficit")
            Text("Si les mitochondries sont insuffisantes, le débit réel (vert) tombe sous la demande (orange) → déficit (rouge).")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Chart {
                pumpChartContent(pts: pts)
            }
            .chartForegroundStyleScale([
                "Demande": Color.orange,
                "Débit":   Color.green,
                "Déficit": Color.red
            ])
            .chartXAxisLabel("Temps (ms)", alignment: .center)
            .chartYAxisLabel("mM / ms", alignment: .center)
            .chartLegend(position: .topLeading, alignment: .leading)
            .frame(height: 160)
        }
    }

    @ChartContentBuilder
    private func pumpChartContent(pts: [SimulationViewModel.EnergyPlotPoint]) -> some ChartContent {
        let stride = max(1, pts.count / 400)
        let sampled = stride > 1
            ? pts.enumerated().compactMap { i, p in i % stride == 0 ? p : nil }
            : pts

        ForEach(sampled.indices, id: \.self) { i in
            let p = sampled[i]
            LineMark(x: .value("t", p.t), y: .value("Demande", p.pumpDemand))
                .foregroundStyle(by: .value("Série", "Demande"))
                .lineStyle(.init(lineWidth: 1.5, dash: [4, 3]))
            LineMark(x: .value("t", p.t), y: .value("Débit", p.pumpRate))
                .foregroundStyle(by: .value("Série", "Débit"))
                .lineStyle(.init(lineWidth: 1.5))
            let deficit = max(p.pumpDemand - p.pumpRate, 0.0)
            LineMark(x: .value("t", p.t), y: .value("Déficit", deficit))
                .foregroundStyle(by: .value("Série", "Déficit"))
                .lineStyle(.init(lineWidth: 1))
        }
    }

    // MARK: - Enable prompt

    @ViewBuilder
    private func enablePrompt(neuron: HHNeuron) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.heart")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Modèle énergétique désactivé pour **\(neuron.name)**")
                .multilineTextAlignment(.center)
            Text("Activez le modèle dans la barre de contrôle pour suivre les concentrations ioniques, l'ATP/ADP et les potentiels de Nernst dynamiques.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                if let idx = vm.network.neurons.firstIndex(where: { $0.id == neuron.id }) {
                    vm.network.neurons[idx].energyParams.enabled = true
                    vm.objectWillChange.send()
                }
            } label: {
                Label("Activer le modèle énergie", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func placeholder(_ msg: String) -> some View {
        ZStack {
            Color.clear
            Text(msg).foregroundStyle(.tertiary).font(.caption)
        }
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func mitoHealthControl(idx: Int) -> some View {
        let pct = vm.network.neurons[idx].energyParams.mitoHealthPercent
        let binding = Binding<Double>(
            get: { vm.network.neurons[idx].energyParams.mitoHealthPercent },
            set: { vm.network.neurons[idx].energyParams.mitoHealthPercent = $0
                   vm.objectWillChange.send() })
        VStack(alignment: .center, spacing: 1) {
            HStack(spacing: 3) {
                Text("Santé mito").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(healthColor(pct))
            }
            Slider(value: binding, in: 0...100, step: 1)
                .frame(width: 80)
                .tint(healthColor(pct))
        }
    }

    private func healthColor(_ pct: Double) -> Color {
        switch pct {
        case 75...: return .green
        case 40..<75: return .yellow
        case 10..<40: return .orange
        default: return .red
        }
    }

    private func paramField(_ label: String, value: Binding<Double>,
                            unit: String, width: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .multilineTextAlignment(.trailing)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func countSpikes(neuronID: UUID) -> Int {
        guard let pts = vm.traces[neuronID], pts.count > 1 else { return 0 }
        var count = 0
        for i in 1..<pts.count {
            if pts[i - 1].v < 0 && pts[i].v >= 0 { count += 1 }
        }
        return count
    }

    private func autoSelect() {
        if selectedNeuronID == nil ||
           !vm.network.neurons.contains(where: { $0.id == selectedNeuronID }) {
            selectedNeuronID = vm.network.neurons.first?.id
        }
    }
}
