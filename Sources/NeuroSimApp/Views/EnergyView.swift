//
//  EnergyView.swift
//  NeuroSimApp
//
//  Metabolic energy dashboard — v2:
//
//   ┌─── control bar ──────────────────────────────────────────────────────┐
//   ├─── Section A: MiniGauge grid (7 × individual Y scales) ──────────────┤
//   │   E_Na  E_K  [Na]ᵢ  [K]ᵢ  [ATP]  [ADP]  [Pi]                       │
//   │   Each bar has its own domain → small changes are always visible.    │
//   ├──────────────────────────────────────────────────────────────────────┤
//   │  ┌── Section B: Network ATP ──┐  ┌── Section C: Coût/PA ──┐         │
//   ├──────────────────────────────────────────────────────────────────────┤
//   │  Section D: Pompe Na/K — demande · débit réel · déficit (timeline)  │
//   └──────────────────────────────────────────────────────────────────────┘

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - MiniGauge helpers

private struct GaugeSpec {
    let id: String
    let label: String
    let unit: String
    let value: Double
    let yMin: Double
    let yMax: Double
    let refValue: Double?  // dashed reference line
    let color: Color
}

/// One vertical bar chart for a single quantity with its own Y domain.
private struct MiniGauge: View {
    let spec: GaugeSpec
    private let gaugeWidth: CGFloat = 62
    private let gaugeHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 3) {
            Chart {
                BarMark(
                    x: .value("", spec.label),
                    yStart: .value("", spec.yMin),
                    yEnd: .value("", clamped)
                )
                .foregroundStyle(spec.color.gradient)
                .annotation(position: annotationPos, alignment: .center, spacing: 2) {
                    Text(formatted)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(spec.color)
                }

                if let ref = spec.refValue {
                    RuleMark(y: .value("réf", ref))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(spec.color.opacity(0.5))
                }
            }
            .chartYScale(domain: spec.yMin...spec.yMax)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [spec.yMin, spec.yMax]) {
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.3))
                    AxisValueLabel()
                        .font(.system(size: 7))
                }
            }
            .frame(width: gaugeWidth, height: gaugeHeight)

            // Label below
            VStack(spacing: 1) {
                Text(spec.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(spec.color)
                Text(spec.unit)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clamped: Double { max(spec.yMin, min(spec.yMax, spec.value)) }

    /// Place annotation above bar unless bar is near the top, then below.
    private var annotationPos: AnnotationPosition {
        let range = spec.yMax - spec.yMin
        guard range > 0 else { return .top }
        let frac = (clamped - spec.yMin) / range
        return frac > 0.85 ? .bottom : .top
    }

    private var formatted: String {
        let v = spec.value
        if abs(v) < 1 { return String(format: "%.3f", v) }
        if abs(v) < 10 { return String(format: "%.2f", v) }
        return String(format: "%.1f", v)
    }
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
                        set: { val in
                            vm.network.neurons[idx].energyParams.enabled = val
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
                        paramField("J_mito max",
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

                // ── Section A: MiniGauge grid ─────────────────────────────────
                sectionA(pts: pts)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                Divider().padding(.vertical, 8)

                // ── Section B + C side by side ────────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    sectionB(pts: pts)
                    Divider()
                    sectionC(pts: pts, neuron: neuron)
                }
                .padding(.horizontal, 14)

                Divider().padding(.vertical, 8)

                // ── Section D: Pump demand vs rate vs deficit ─────────────────
                sectionD(pts: pts)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    // MARK: - Section A: MiniGauge grid

    @ViewBuilder
    private func sectionA(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        let last = pts.last!
        VStack(alignment: .leading, spacing: 8) {
            Text("Instantané — snapshot courant")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    MiniGauge(spec: GaugeSpec(
                        id: "eNa", label: "E_Na", unit: "mV",
                        value: last.eNa,
                        yMin: 50, yMax: 80, refValue: 67,
                        color: .blue))

                    MiniGauge(spec: GaugeSpec(
                        id: "eK", label: "E_K", unit: "mV",
                        value: last.eK,
                        yMin: -110, yMax: -80, refValue: -98,
                        color: .orange))

                    Divider().frame(height: 140)

                    MiniGauge(spec: GaugeSpec(
                        id: "naI", label: "[Na]ᵢ", unit: "mM",
                        value: last.naI,
                        yMin: 10, yMax: 30, refValue: 15,
                        color: .blue))

                    MiniGauge(spec: GaugeSpec(
                        id: "kI", label: "[K]ᵢ", unit: "mM",
                        value: last.kI,
                        yMin: 100, yMax: 145, refValue: 140,
                        color: .orange))

                    Divider().frame(height: 140)

                    MiniGauge(spec: GaugeSpec(
                        id: "atp", label: "[ATP]", unit: "mM",
                        value: last.atp,
                        yMin: 0, yMax: 3, refValue: 2,
                        color: .green))

                    MiniGauge(spec: GaugeSpec(
                        id: "adp", label: "[ADP]", unit: "mM",
                        value: last.adp,
                        yMin: 0, yMax: 0.5, refValue: 0.2,
                        color: .yellow))

                    MiniGauge(spec: GaugeSpec(
                        id: "pi", label: "[Pi]", unit: "mM",
                        value: last.pi,
                        yMin: 0, yMax: 5, refValue: 2.5,
                        color: .purple))
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Section B: Network ATP

    @ViewBuilder
    private func sectionB(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATP consommé — réseau")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            let energyNeurons = vm.network.neurons.filter { $0.energyParams.enabled }
            if energyNeurons.isEmpty {
                Text("Aucun neurone avec énergie activée")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(energyNeurons) { neuron in
                    if let nPts = vm.energyTraces[neuron.id],
                       let first = nPts.first, let last = nPts.last {
                        let consumed = last.atpConsumed - first.atpConsumed
                        HStack(spacing: 6) {
                            Text(neuron.name)
                                .font(.system(size: 11))
                                .frame(width: 50, alignment: .leading)
                            ProgressView(value: min(consumed / 0.05, 1.0))
                                .frame(width: 80)
                                .tint(.green)
                            Text(String(format: "%.5f mM", consumed))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                let networkTotal: Double = energyNeurons.reduce(0.0) { acc, neuron in
                    guard let nPts = vm.energyTraces[neuron.id],
                          let first = nPts.first, let last = nPts.last
                    else { return acc }
                    return acc + (last.atpConsumed - first.atpConsumed)
                }
                HStack {
                    Text("Total réseau").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.5f mM", networkTotal))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section C: Cost per spike

    @ViewBuilder
    private func sectionC(pts: [SimulationViewModel.EnergyPlotPoint],
                           neuron: HHNeuron) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coût énergétique")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            let spikeCount = countSpikes(neuronID: neuron.id)
            let first = pts.first!
            let last  = pts.last!
            let totalATP = last.atpConsumed - first.atpConsumed

            if spikeCount > 0 {
                let costPerSpike = totalATP / Double(spikeCount)
                let somaVol = neuron.compartments
                    .first(where: { $0.id == neuron.somaCompartmentID })?.volume ?? 1e-12
                let molecules = costPerSpike * 1e-3 * somaVol * 6.022e23
                let log10mol  = molecules > 0 ? log10(molecules) : 0
                let mantissa  = molecules / pow(10, floor(log10mol))
                let exponent  = Int(floor(log10mol))

                VStack(alignment: .leading, spacing: 4) {
                    costRow("Potentiels d'action", value: "\(spikeCount)")
                    costRow("ATP / PA",   value: String(format: "%.5f mM", costPerSpike))
                    costRow("Molécules / PA", value: String(format: "%.1f × 10^%d", mantissa, exponent))
                    costRow("Vol. soma",  value: String(format: "%.1f µm³", somaVol * 1e15))
                }
            } else {
                Text("Pas de PA détecté").font(.caption).foregroundStyle(.tertiary)
                costRow("ATP total", value: String(format: "%.5f mM", totalATP))
            }
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    @ViewBuilder
    private func costRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    // MARK: - Section D: Pump demand vs rate vs deficit

    @ViewBuilder
    private func sectionD(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pompe Na/K — demande · débit réel · déficit")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Si les mitochondries sont insuffisantes, le débit réel (vert) devient inférieur à la demande (orange) → déficit (rouge).")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Chart {
                pumpChartContent(pts: pts)
            }
            .chartForegroundStyleScale([
                "Demande":  Color.orange,
                "Débit":    Color.green,
                "Déficit":  Color.red
            ])
            .chartXAxisLabel("Temps (ms)", alignment: .center)
            .chartYAxisLabel("mM / ms", alignment: .center)
            .chartLegend(position: .topLeading, alignment: .leading)
            .frame(height: 160)
        }
    }

    @ChartContentBuilder
    private func pumpChartContent(pts: [SimulationViewModel.EnergyPlotPoint]) -> some ChartContent {
        // Thin out to at most 400 points for performance
        let stride = max(1, pts.count / 400)
        let sampled = stride > 1 ? pts.enumerated().compactMap { i, p in i % stride == 0 ? p : nil } : pts

        ForEach(sampled.indices, id: \.self) { i in
            let p = sampled[i]
            // Demand line
            LineMark(x: .value("t", p.t), y: .value("Demande", p.pumpDemand))
                .foregroundStyle(by: .value("Série", "Demande"))
                .lineStyle(.init(lineWidth: 1.5, dash: [4, 3]))
            // Actual rate
            LineMark(x: .value("t", p.t), y: .value("Débit", p.pumpRate))
                .foregroundStyle(by: .value("Série", "Débit"))
                .lineStyle(.init(lineWidth: 1.5))
            // Deficit = demand − rate (≥ 0)
            let deficit = max(p.pumpDemand - p.pumpRate, 0)
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

    // MARK: - Helpers

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

    /// Count upward crossings of 0 mV threshold in the voltage trace.
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
