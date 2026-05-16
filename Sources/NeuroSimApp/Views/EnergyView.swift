//
//  EnergyView.swift
//  NeuroSimApp
//
//  Redesigned metabolic energy view:
//
//   ┌─── control bar ─────────────────────────────────────────────┐
//   ├─── Section A: Bar gauges (current snapshot) ─────────────────┤
//   │   Vertical bar charts (mV panel + mM panel) with annotation  │
//   ├──────────────────────────────────────────────────────────────┤
//   │  ┌── Section B: Network ATP panel ──┐ ┌─ Section C: Cost ──┐ │
//   │  │ ATP consumed per neuron          │ │ ATP/spike estimate  │ │
//   │  └──────────────────────────────────┘ └────────────────────┘ │
//   ├──────────────────────────────────────────────────────────────┤
//   │  Section D: Nernst line charts (E_Na, E_K vs time) compact   │
//   └──────────────────────────────────────────────────────────────┘
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - Bar gauge data helpers

private struct BarItem: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

struct EnergyView: View {
    @EnvironmentObject var vm: SimulationViewModel

    // Neuron selection
    @State private var selectedNeuronID: UUID? = nil

    // Cursor state (shared across nernst chart)
    @State private var cursorT: Double?    = nil
    @State private var cursorAbs: CGPoint? = nil

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
                // Section A: Bar gauges
                sectionA(pts: pts)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                Divider().padding(.vertical, 8)

                // Section B + C side by side
                HStack(alignment: .top, spacing: 12) {
                    sectionB(pts: pts)
                    Divider()
                    sectionC(pts: pts, neuron: neuron)
                }
                .padding(.horizontal, 12)

                Divider().padding(.vertical, 8)

                // Section D: Nernst compact chart
                sectionD(pts: pts)
                    .frame(height: 160)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Section A: Bar gauges

    @ViewBuilder
    private func sectionA(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        let last = pts.last!
        VStack(alignment: .leading, spacing: 6) {
            Text("Instantané — snapshot courant")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                // mV chart: E_Na, E_K
                let mvItems: [BarItem] = [
                    BarItem(id: "E_Na", label: "E_Na", value: last.eNa, color: .blue),
                    BarItem(id: "E_K",  label: "E_K",  value: last.eK,  color: .orange)
                ]
                milliVoltBarChart(items: mvItems)
                    .frame(width: 140, height: 180)

                // mM chart: [Na]_i, [K]_i (clamped display), [ATP], [ADP], [Pi]
                let mmItems: [BarItem] = [
                    BarItem(id: "naI", label: "[Na]ᵢ", value: last.naI, color: .blue),
                    BarItem(id: "kI",  label: "[K]ᵢ",  value: min(last.kI, 160), color: .orange),
                    BarItem(id: "atp", label: "[ATP]",  value: last.atp, color: .green),
                    BarItem(id: "adp", label: "[ADP]",  value: last.adp, color: .yellow),
                    BarItem(id: "pi",  label: "[Pi]",   value: last.pi,  color: .red)
                ]
                millimolarBarChart(items: mmItems, last: last)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func milliVoltBarChart(items: [BarItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Potentiels (mV)").font(.system(size: 9)).foregroundStyle(.secondary)
            Chart {
                mvBarContent(items: items)
            }
            .chartYAxisLabel("mV", alignment: .center)
            .chartXAxis { AxisMarks(values: .automatic) }
        }
    }

    @ChartContentBuilder
    private func mvBarContent(items: [BarItem]) -> some ChartContent {
        ForEach(items) { item in
            BarMark(
                x: .value("Quantité", item.label),
                y: .value("Valeur", item.value)
            )
            .foregroundStyle(item.color)
            .annotation(position: .top, alignment: .center) {
                Text(String(format: "%.1f", item.value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        // Reference lines
        RuleMark(y: .value("réf E_Na", 67.0))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Color.blue.opacity(0.5))
            .annotation(position: .trailing) {
                Text("67").font(.system(size: 8)).foregroundStyle(.blue.opacity(0.7))
            }
        RuleMark(y: .value("réf E_K", -98.0))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Color.orange.opacity(0.5))
            .annotation(position: .trailing) {
                Text("-98").font(.system(size: 8)).foregroundStyle(.orange.opacity(0.7))
            }
    }

    @ViewBuilder
    private func millimolarBarChart(items: [BarItem], last: SimulationViewModel.EnergyPlotPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Concentrations (mM)").font(.system(size: 9)).foregroundStyle(.secondary)
            Chart {
                mmBarContent(items: items)
            }
            .chartYAxisLabel("mM", alignment: .center)
        }
    }

    @ChartContentBuilder
    private func mmBarContent(items: [BarItem]) -> some ChartContent {
        ForEach(items) { item in
            BarMark(
                x: .value("Quantité", item.label),
                y: .value("Valeur", item.value)
            )
            .foregroundStyle(item.color)
            .annotation(position: .top, alignment: .center) {
                Text(String(format: "%.2f", item.value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        // Reference lines for physiological targets
        RuleMark(y: .value("réf [Na]ᵢ", 15.0))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Color.blue.opacity(0.4))
        RuleMark(y: .value("réf ATP", 2.0))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Color.green.opacity(0.5))
    }

    // MARK: - Section B: Network ATP panel

    @ViewBuilder
    private func sectionB(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATP consommé — réseau")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            let energyNeurons = vm.network.neurons.filter { $0.energyParams.enabled }
            if energyNeurons.isEmpty {
                Text("Aucun neurone avec énergie activée")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                var total = 0.0
                ForEach(energyNeurons) { neuron in
                    if let nPts = vm.energyTraces[neuron.id],
                       let first = nPts.first, let last = nPts.last {
                        let consumed = last.atpConsumed - first.atpConsumed
                        let _ = { total += consumed }()
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

                // Total network
                let networkTotal: Double = energyNeurons.reduce(0.0) { acc, neuron in
                    guard let nPts = vm.energyTraces[neuron.id],
                          let first = nPts.first, let last = nPts.last
                    else { return acc }
                    return acc + (last.atpConsumed - first.atpConsumed)
                }
                HStack {
                    Text("Total réseau")
                        .font(.system(size: 11, weight: .semibold))
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
    private func sectionC(pts: [SimulationViewModel.EnergyPlotPoint], neuron: HHNeuron) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coût énergétique")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            let spikeCount = countSpikes(neuronID: neuron.id)
            let first = pts.first!
            let last  = pts.last!
            let totalATP = last.atpConsumed - first.atpConsumed   // mM

            if spikeCount > 0 {
                let costPerSpike = totalATP / Double(spikeCount)  // mM/spike

                // Soma volume in litres
                let somaVol = neuron.compartments
                    .first(where: { $0.id == neuron.somaCompartmentID })?.volume ?? 1e-12
                // molecules = costMM × 1e-3 mol/mM × vol [L] × 6.022e23
                let molecules = costPerSpike * 1e-3 * somaVol * 6.022e23
                let log10mol  = molecules > 0 ? log10(molecules) : 0
                let mantissa  = molecules / pow(10, floor(log10mol))
                let exponent  = Int(floor(log10mol))

                VStack(alignment: .leading, spacing: 4) {
                    costRow("Potentiels d'action", value: "\(spikeCount)")
                    costRow("ATP/PA",     value: String(format: "%.5f mM", costPerSpike))
                    costRow("Molécules/PA", value: String(format: "%.1f × 10^%d", mantissa, exponent))
                    costRow("Vol. soma",  value: String(format: "%.1f µm³", somaVol * 1e15))
                }
            } else {
                Text("Pas de PA détecté")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    // MARK: - Section D: Nernst compact chart

    @ViewBuilder
    private func sectionD(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Potentiels de Nernst")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            Chart {
                nernstLines(pts: pts)
            }
            .chartForegroundStyleScale([
                "E_Na": Color.blue,
                "E_K":  Color.orange
            ])
            .chartXAxisLabel("Temps (ms)")
            .chartYAxisLabel("Potentiel (mV)")
            .chartLegend(position: .topLeading, alignment: .leading)
            .chartOverlay { proxy in nernstCursorOverlay(proxy: proxy) }
        }
    }

    @ChartContentBuilder
    private func nernstLines(pts: [SimulationViewModel.EnergyPlotPoint]) -> some ChartContent {
        ForEach(pts.indices, id: \.self) { i in
            let p = pts[i]
            LineMark(x: .value("t", p.t), y: .value("E_Na", p.eNa))
                .foregroundStyle(by: .value("Série", "E_Na"))
                .lineStyle(.init(lineWidth: 1.5))
            LineMark(x: .value("t", p.t), y: .value("E_K",  p.eK))
                .foregroundStyle(by: .value("Série", "E_K"))
                .lineStyle(.init(lineWidth: 1.5))
        }
    }

    // MARK: - Nernst cursor overlay

    @ViewBuilder
    private func nernstCursorOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let f = proxy.plotFrame.map { geo[$0] } ?? .zero
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let rx = loc.x - f.minX
                        guard rx >= 0, rx <= f.width,
                              loc.y >= f.minY, loc.y <= f.maxY else {
                            cursorT = nil; cursorAbs = nil; return
                        }
                        cursorAbs = loc
                        cursorT   = proxy.value(atX: rx, as: Double.self)
                    case .ended:
                        cursorT = nil; cursorAbs = nil
                    }
                }
            if let loc = cursorAbs {
                Path { p in
                    p.move(to: CGPoint(x: loc.x, y: f.minY))
                    p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                }
                .stroke(Color.white.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .allowsHitTesting(false)
            }
            if let loc = cursorAbs, let t = cursorT,
               let nid = selectedNeuronID,
               let pts = vm.energyTraces[nid], !pts.isEmpty {
                let lx = loc.x + 10 > f.maxX - 140 ? loc.x - 145 : loc.x + 10
                let label = nernstLabel(t: t, pts: pts)
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: lx + 65, y: max(loc.y, f.minY + 28))
            }
        }
    }

    private func nernstLabel(t: Double, pts: [SimulationViewModel.EnergyPlotPoint]) -> String {
        var lo = 0, hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let p = pts[lo]
        return String(format: "t = %.1f ms\nE_Na = %.1f  E_K = %.1f mV", p.t, p.eNa, p.eK)
    }

    // MARK: - Spike counting

    /// Count upward crossings of 0 mV threshold in the voltage trace for the given neuron.
    private func countSpikes(neuronID: UUID) -> Int {
        guard let pts = vm.traces[neuronID], pts.count > 1 else { return 0 }
        var count = 0
        for i in 1..<pts.count {
            if pts[i - 1].v < 0 && pts[i].v >= 0 {
                count += 1
            }
        }
        return count
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
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func autoSelect() {
        if selectedNeuronID == nil ||
           !vm.network.neurons.contains(where: { $0.id == selectedNeuronID }) {
            selectedNeuronID = vm.network.neurons.first?.id
        }
    }
}
