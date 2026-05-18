//
//  EnergyView.swift
//  NeuroSimApp
//
//  Metabolic energy dashboard — v4:
//
//   ┌─── control bar ──────────────────────────────────────────────────────────┐
//   ├─── Ligne 1 (scroll horizontal) ──────────────────────────────────────────┤
//   │  E_Na  E_K↓  [Na]ᵢ  [K]ᵢ  [ATP]  [ADP]  [Pi]  [Ca²⁺]ᵢ  │ Demande Débit Déficit
//   │  E_K : barre part de 0 vers le bas — plus courte = moins négatif = danger│
//   ├──────────────────────────────────────────────────────────────────────────┤
//   │  Ligne 2 : ATP consommé / neurone (une barre par neurone)                │
//   ├──────────────────────────────────────────────────────────────────────────┤
//   │  Ligne 3 : Chiffres clefs (liste compacte)                               │
//   └──────────────────────────────────────────────────────────────────────────┘

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - GaugeSpec / MiniGauge

private struct GaugeSpec {
    let id: String
    let label: String
    let unit: String
    let value: Double
    let yMin: Double
    let yMax: Double
    let refValue: Double?
    let color: Color
    /// When true the bar goes from 0 downward (for E_K: 0 at top, negative below).
    var invertedFromZero: Bool = false
}

/// Vertical bar gauge — value displayed above the chart, no in-chart annotation.
private struct MiniGauge: View {
    let spec: GaugeSpec

    var body: some View {
        VStack(spacing: 0) {
            // Value above — fixed width centres it over the chart frame
            Text(formatted)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(spec.color)
                .frame(width: 68, height: 20, alignment: .center)
                .multilineTextAlignment(.center)

            Chart {
                BarMark(
                    x: .value("", spec.label),
                    yStart: .value("", barStart),
                    yEnd:   .value("", barEnd),
                    width:  .fixed(48)
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
            // Hide y-axis labels: their variable width (e.g. "0.01088" vs "0")
            // shifts the plot area left inside the fixed 68 px frame, misaligning
            // the bar centre with the label below. Hidden axis → bar always centred.
            .chartYAxis(.hidden)
            .frame(width: 68, height: 110)

            // Label + unit below — fixed width AND fixed height so all
            // MiniGauges are identical in total height → labels align.
            VStack(spacing: 1) {
                Text(spec.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(spec.color)
                    .multilineTextAlignment(.center)
                Text(spec.unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 68, height: 32, alignment: .top)
            .padding(.top, 3)
        }
    }

    private var clamped: Double { max(spec.yMin, min(spec.yMax, spec.value)) }

    /// Bar start: 0 for inverted (E_K), yMin otherwise.
    private var barStart: Double { spec.invertedFromZero ? 0.0 : spec.yMin }
    /// Bar end: clamped value always.
    private var barEnd:   Double { clamped }

    private var formatted: String {
        let v = spec.value
        if abs(v) < 0.01 { return String(format: "%.4f", v) }
        if abs(v) < 1    { return String(format: "%.3f", v) }
        if abs(v) < 10   { return String(format: "%.2f", v) }
        return String(format: "%.1f", v)
    }
}

// MARK: - NetworkBarItem

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
                    .labelsHidden().frame(width: 120)
                }
                Divider().frame(height: 24)

                if let nid = selectedNeuronID,
                   let idx = vm.network.neurons.firstIndex(where: { $0.id == nid }) {
                    Toggle("Modèle énergie", isOn: Binding(
                        get: { vm.network.neurons[idx].energyParams.enabled },
                        set: { v in vm.network.neurons[idx].energyParams.enabled = v
                               vm.objectWillChange.send() }))
                    .toggleStyle(.switch).font(.system(size: 12))

                    if vm.network.neurons[idx].energyParams.enabled {
                        Divider().frame(height: 24)
                        // Na/K pump jMax from first pump
                        if let nakIdx = vm.network.neurons[idx].energyParams.pumps
                            .firstIndex(where: { $0.ion == "Na" }) {
                            paramField("J_pump max",
                                       value: Binding(
                                        get: { vm.network.neurons[idx].energyParams.pumps[nakIdx].jMax },
                                        set: { vm.network.neurons[idx].energyParams.pumps[nakIdx].jMax = $0
                                               vm.objectWillChange.send() }),
                                       unit: "mM/ms", width: 56)
                        }
                        mitoHealthControl(idx: idx)
                        paramField("J_mito",
                                   value: Binding(
                                    get: { vm.network.neurons[idx].energyParams.mitoJmax },
                                    set: { vm.network.neurons[idx].energyParams.mitoJmax = $0
                                           vm.objectWillChange.send() }),
                                   unit: "mM/ms", width: 56)
                        paramField("[ATP]₀",
                                   value: Binding(
                                    get: { vm.network.neurons[idx].energyParams.atp0 },
                                    set: { vm.network.neurons[idx].energyParams.atp0 = $0
                                           vm.objectWillChange.send() }),
                                   unit: "mM", width: 44)

                        if !vm.network.neurons[idx].energyParams.clampExtracellular {
                            Label("Ischémie", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.orange.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(height: 44)
    }

    // MARK: - Main content

    @ViewBuilder
    private func mainContent(pts: [SimulationViewModel.EnergyPlotPoint],
                             neuron: HHNeuron) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Ligne 1 : gauges + pompe ──────────────────────────────
                rowGauges(pts: pts)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                Divider().padding(.vertical, 8)

                // ── Ligne 2 : ATP consommé / neurone ─────────────────────
                rowATPNetwork()
                    .padding(.horizontal, 14)

                Divider().padding(.vertical, 8)

                // ── Ligne 3 : chiffres clefs ──────────────────────────────
                rowKeyFigures(pts: pts, neuron: neuron)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    // MARK: - Ligne 1 : Gauges groupées par section

    @ViewBuilder
    private func rowGauges(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        let last        = pts.last!
        let pumpDemand  = last.pumpDemand
        let pumpRate    = last.pumpRate
        let pumpDeficit = max(pumpDemand - pumpRate, 0)
        let pumpMax     = max(pumpDemand * 1.2, 0.001)

        // ── Palette apaisée, cohérente par espèce ionique ─────────────────
        let cENa  = Color.indigo
        let cEK   = Color.brown
        let cNaI  = Color.teal
        let cKI   = Color(hue: 0.09, saturation: 0.45, brightness: 0.80)
        let cATP  = Color.mint
        let cADP  = Color(hue: 0.12, saturation: 0.48, brightness: 0.80)
        let cPi   = Color.purple.opacity(0.80)
        let cCa   = Color.cyan.opacity(0.82)
        let cDem  = Color(hue: 0.07, saturation: 0.48, brightness: 0.80)
        let cRate = Color.green.opacity(0.72)
        let cDef  = Color.pink.opacity(0.82)

        ScrollView(.horizontal, showsIndicators: false) {
            // Bottom alignment : le bas des charts est aligné entre toutes les sections
            HStack(alignment: .bottom, spacing: 10) {

                // ── Reversal potential ─────────────────────────────────────
                gaugeSection("Reversal potential") {
                    MiniGauge(spec: GaugeSpec(id: "eNa", label: "E_Na", unit: "mV",
                        value: last.eNa, yMin: 0, yMax: 80, refValue: 67, color: cENa))
                    MiniGauge(spec: GaugeSpec(id: "eK",  label: "E_K",  unit: "mV",
                        value: last.eK,  yMin: -110, yMax: 0, refValue: -98, color: cEK,
                        invertedFromZero: true))
                }

                // ── Ion concentrations ─────────────────────────────────────
                // yMin = 0 so bars are always visible regardless of how far
                // [Na]i rises or [K]i falls (e.g. during ischaemia / SD)
                gaugeSection("Ion concentrations") {
                    MiniGauge(spec: GaugeSpec(id: "naI", label: "[Na]ᵢ", unit: "mM",
                        value: last.naI, yMin: 0, yMax: 30,  refValue: 15,  color: cNaI))
                    MiniGauge(spec: GaugeSpec(id: "kI",  label: "[K]ᵢ",  unit: "mM",
                        value: last.kI,  yMin: 0, yMax: 145, refValue: 140, color: cKI))
                }

                // ── ATP ────────────────────────────────────────────────────
                gaugeSection("ATP") {
                    MiniGauge(spec: GaugeSpec(id: "atp", label: "[ATP]", unit: "mM",
                        value: last.atp, yMin: 0, yMax: 3,   refValue: 2,   color: cATP))
                    MiniGauge(spec: GaugeSpec(id: "adp", label: "[ADP]", unit: "mM",
                        value: last.adp, yMin: 0, yMax: 0.5, refValue: 0.2, color: cADP))
                    MiniGauge(spec: GaugeSpec(id: "pi",  label: "[Pi]",  unit: "mM",
                        value: last.pi,  yMin: 0, yMax: 5,   refValue: 2.5, color: cPi))
                }

                // ── Calcium ────────────────────────────────────────────────
                gaugeSection("Calcium") {
                    MiniGauge(spec: GaugeSpec(id: "caI", label: "[Ca²⁺]ᵢ", unit: "µM",
                        value: last.caI * 1000,
                        yMin: 0, yMax: 2.0, refValue: 0.1, color: cCa))
                }

                // ── Pompe Na/K ─────────────────────────────────────────────
                gaugeSection("Pompe Na/K") {
                    MiniGauge(spec: GaugeSpec(id: "pDem",  label: "Demande", unit: "mM/ms",
                        value: pumpDemand,  yMin: 0, yMax: pumpMax, refValue: nil, color: cDem))
                    MiniGauge(spec: GaugeSpec(id: "pRate", label: "Débit",   unit: "mM/ms",
                        value: pumpRate,    yMin: 0, yMax: pumpMax, refValue: nil, color: cRate))
                    MiniGauge(spec: GaugeSpec(id: "pDef",  label: "Déficit", unit: "mM/ms",
                        value: pumpDeficit, yMin: 0, yMax: pumpMax, refValue: nil, color: cDef))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }

    /// Groupe visuel : titre + fond teinté + alignement bas des barres.
    @ViewBuilder
    private func gaugeSection<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            HStack(alignment: .bottom, spacing: 8) {
                content()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Ligne 2 : ATP consommé / neurone

    @ViewBuilder
    private func rowATPNetwork() -> some View {
        let energyNeurons = vm.network.neurons.filter { $0.energyParams.enabled }
        let items: [NetworkBarItem] = energyNeurons.compactMap { neuron in
            guard let nPts = vm.energyTraces[neuron.id],
                  let first = nPts.first, let last = nPts.last
            else { return nil }
            return NetworkBarItem(id: neuron.id, name: neuron.name,
                                  consumed: last.atpConsumed - first.atpConsumed)
        }

        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("ATP dynamics")
            if items.isEmpty {
                Text("Données insuffisantes").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 55, alignment: .leading)
                            GeometryReader { geo in
                                let maxVal = items.map(\.consumed).max() ?? 1e-9
                                let frac   = CGFloat(item.consumed / max(maxVal, 1e-9))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.green.opacity(0.7))
                                    .frame(width: geo.size.width * frac)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 10)
                            Text(String(format: "%.5f mM", item.consumed))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 115, alignment: .trailing)
                        }
                    }
                    if items.count > 1 {
                        Divider()
                        let total = items.reduce(0.0) { $0 + $1.consumed }
                        HStack {
                            Text("Total réseau").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text(String(format: "%.5f mM", total))
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Ligne 3 : Chiffres clefs (liste compacte)

    @ViewBuilder
    private func rowKeyFigures(pts: [SimulationViewModel.EnergyPlotPoint],
                               neuron: HHNeuron) -> some View {
        let spikeCount  = countSpikes(neuronID: neuron.id)
        let first       = pts.first!
        let last        = pts.last!
        let totalATP    = last.atpConsumed - first.atpConsumed
        let somaVol     = neuron.compartments
            .first(where: { $0.id == neuron.somaCompartmentID })?.volume ?? 1e-12

        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Chiffres clefs")

            let costPerSpike: Double = spikeCount > 0 ? totalATP / Double(spikeCount) : 0
            let molecules: Double = costPerSpike * 1e-3 * somaVol * 6.022e23

            // Two-column grid
            let rows: [(String, String)] = [
                ("Potentiels d'action",  spikeCount > 0 ? "\(spikeCount) PA" : "—"),
                ("ATP total consommé",   String(format: "%.5f mM", totalATP)),
                ("ATP / PA",             spikeCount > 0
                    ? String(format: "%.5f mM", costPerSpike) : "—"),
                ("Molécules ATP / PA",   spikeCount > 0
                    ? moleculeString(molecules) : "—"),
                ("Volume soma",          String(format: "%.0f µm³", somaVol * 1e15)),
                ("Santé mito",           String(format: "%.0f %%",
                    neuron.energyParams.mitoHealthPercent)),
            ]

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(value)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    // MARK: - Enable prompt / placeholder

    @ViewBuilder
    private func enablePrompt(neuron: HHNeuron) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.heart").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("Modèle énergétique désactivé pour **\(neuron.name)**")
                .multilineTextAlignment(.center)
            Text("Activez le modèle dans la barre de contrôle pour suivre les concentrations ioniques, l'ATP/ADP et les potentiels de Nernst dynamiques.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button {
                if let idx = vm.network.neurons.firstIndex(where: { $0.id == neuron.id }) {
                    vm.network.neurons[idx].energyParams.enabled = true
                    vm.objectWillChange.send()
                }
            } label: { Label("Activer le modèle énergie", systemImage: "bolt.fill") }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func placeholder(_ msg: String) -> some View {
        ZStack { Color.clear; Text(msg).foregroundStyle(.tertiary).font(.caption) }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
                .frame(width: 80).tint(healthColor(pct))
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
                    .textFieldStyle(.roundedBorder).frame(width: width)
                    .multilineTextAlignment(.trailing)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func countSpikes(neuronID: UUID) -> Int {
        guard let pts = vm.traces[neuronID], pts.count > 1 else { return 0 }
        var count = 0
        for i in 1..<pts.count { if pts[i-1].v < 0 && pts[i].v >= 0 { count += 1 } }
        return count
    }

    private func moleculeString(_ n: Double) -> String {
        guard n > 0 else { return "—" }
        let exp = floor(log10(n))
        let man = n / pow(10, exp)
        return String(format: "%.1f × 10^%d", man, Int(exp))
    }

    private func autoSelect() {
        if selectedNeuronID == nil ||
           !vm.network.neurons.contains(where: { $0.id == selectedNeuronID }) {
            selectedNeuronID = vm.network.neurons.first?.id
        }
    }
}
