//
//  EnergyView.swift
//  NeuroSimApp
//
//  Visualises the metabolic energy sub-model for one neuron:
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │  Control bar: neuron picker + "Modèle énergie" enable toggle │
//   ├────────────────────────────┬─────────────────────────────────┤
//   │  Ion concentrations        │  Metabolites (ATP / ADP / Pi)   │
//   │  [Na]_i, [K]_i (mM)       │  [ATP], [ADP], [Pi] (mM)        │
//   │  [Na]_o, [K]_o dashed      │                                 │
//   ├────────────────────────────┴─────────────────────────────────┤
//   │  Nernst potentials  E_Na (blue), E_K (orange) vs time        │
//   ├──────────────────────────────────────────────────────────────┤
//   │  Summary: total ATP consumed, estimated cost per AP          │
//   └──────────────────────────────────────────────────────────────┘
//

import SwiftUI
import Charts
import NeuroSimCore

struct EnergyView: View {
    @EnvironmentObject var vm: SimulationViewModel

    // Neuron selection
    @State private var selectedNeuronID: UUID? = nil

    // Cursor state (shared across charts)
    @State private var cursorT: Double?   = nil
    @State private var cursorAbs: CGPoint? = nil

    // Which chart is the cursor in (for label)
    @State private var cursorChart: CursorChart = .conc

    private enum CursorChart { case conc, meta, nernst }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let nid = selectedNeuronID,
               let neuron = vm.network.neurons.first(where: { $0.id == nid }) {
                if neuron.energyParams.enabled {
                    if let pts = vm.energyTraces[nid], !pts.isEmpty {
                        chartsArea(pts: pts)
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
                // Neuron picker
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

                // Enable toggle (directly mutates the network's neuron)
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

                    // Pump Jmax
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

    // MARK: - Charts area

    @ViewBuilder
    private func chartsArea(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        VStack(spacing: 0) {
            // Row 1: ion concentrations | metabolites
            HSplitView {
                concChart(pts: pts)
                    .frame(minWidth: 260)
                metaChart(pts: pts)
                    .frame(minWidth: 260)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Row 2: Nernst potentials (full width)
            nernstChart(pts: pts)
                .frame(height: 180)

            Divider()

            // Row 3: summary bar
            summaryBar(pts: pts)
                .frame(height: 36)
        }
    }

    // MARK: Ion concentrations chart

    @ViewBuilder
    private func concChart(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        Chart {
            concLines(pts: pts)
        }
        .chartForegroundStyleScale([
            "[Na]ᵢ": Color.blue,
            "[K]ᵢ":  Color.orange,
            "[Na]ₒ": Color.blue.opacity(0.45),
            "[K]ₒ":  Color.orange.opacity(0.45)
        ])
        .chartXAxisLabel("Temps (ms)")
        .chartYAxisLabel("[X] (mM)")
        .chartLegend(position: .topLeading, alignment: .leading)
        .chartOverlay { proxy in cursorOverlay(proxy: proxy, chart: .conc) }
        .padding(12)
    }

    @ChartContentBuilder
    private func concLines(pts: [SimulationViewModel.EnergyPlotPoint]) -> some ChartContent {
        ForEach(pts.indices, id: \.self) { i in
            let p = pts[i]
            LineMark(x: .value("t", p.t), y: .value("[Na]ᵢ", p.naI))
                .foregroundStyle(by: .value("Série", "[Na]ᵢ"))
                .lineStyle(.init(lineWidth: 1.5))
            LineMark(x: .value("t", p.t), y: .value("[K]ᵢ",  p.kI))
                .foregroundStyle(by: .value("Série", "[K]ᵢ"))
                .lineStyle(.init(lineWidth: 1.5))
            LineMark(x: .value("t", p.t), y: .value("[Na]ₒ", p.naO))
                .foregroundStyle(by: .value("Série", "[Na]ₒ"))
                .lineStyle(.init(lineWidth: 1.0, dash: [4, 3]))
            LineMark(x: .value("t", p.t), y: .value("[K]ₒ",  p.kO))
                .foregroundStyle(by: .value("Série", "[K]ₒ"))
                .lineStyle(.init(lineWidth: 1.0, dash: [4, 3]))
        }
    }

    // MARK: Metabolites chart

    @ViewBuilder
    private func metaChart(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        Chart {
            metaLines(pts: pts)
        }
        .chartForegroundStyleScale([
            "[ATP]": Color.green,
            "[ADP]": Color.yellow,
            "[Pi]":  Color.red
        ])
        .chartXAxisLabel("Temps (ms)")
        .chartYAxisLabel("[X] (mM)")
        .chartLegend(position: .topLeading, alignment: .leading)
        .chartOverlay { proxy in cursorOverlay(proxy: proxy, chart: .meta) }
        .padding(12)
    }

    @ChartContentBuilder
    private func metaLines(pts: [SimulationViewModel.EnergyPlotPoint]) -> some ChartContent {
        ForEach(pts.indices, id: \.self) { i in
            let p = pts[i]
            LineMark(x: .value("t", p.t), y: .value("[ATP]", p.atp))
                .foregroundStyle(by: .value("Série", "[ATP]"))
                .lineStyle(.init(lineWidth: 2))
            LineMark(x: .value("t", p.t), y: .value("[ADP]", p.adp))
                .foregroundStyle(by: .value("Série", "[ADP]"))
                .lineStyle(.init(lineWidth: 1.5))
            LineMark(x: .value("t", p.t), y: .value("[Pi]",  p.pi))
                .foregroundStyle(by: .value("Série", "[Pi]"))
                .lineStyle(.init(lineWidth: 1.5))
        }
    }

    // MARK: Nernst potentials chart

    @ViewBuilder
    private func nernstChart(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
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
        .chartOverlay { proxy in cursorOverlay(proxy: proxy, chart: .nernst) }
        .padding(12)
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

    // MARK: Shared cursor overlay

    @ViewBuilder
    private func cursorOverlay(proxy: ChartProxy, chart: CursorChart) -> some View {
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
                        cursorAbs   = loc
                        cursorT     = proxy.value(atX: rx, as: Double.self)
                        cursorChart = chart
                    case .ended:
                        cursorT = nil; cursorAbs = nil
                    }
                }
            // Vertical cursor line
            if let loc = cursorAbs {
                Path { p in
                    p.move(to: CGPoint(x: loc.x, y: f.minY))
                    p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                }
                .stroke(Color.white.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .allowsHitTesting(false)
            }
            // Tooltip
            if cursorChart == chart, let loc = cursorAbs, let t = cursorT {
                let lx = loc.x + 10 > f.maxX - 140 ? loc.x - 145 : loc.x + 10
                Text(cursorLabel(t: t))
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: lx + 65, y: max(loc.y, f.minY + 28))
            }
        }
    }

    private func cursorLabel(t: Double) -> String {
        guard let nid = selectedNeuronID,
              let pts = vm.energyTraces[nid],
              !pts.isEmpty else { return String(format: "t = %.1f ms", t) }
        // Find closest point by binary search
        var lo = 0, hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let p = pts[lo]
        switch cursorChart {
        case .conc:
            return String(format: "t = %.1f ms\n[Na]ᵢ = %.2f  [K]ᵢ = %.2f mM", p.t, p.naI, p.kI)
        case .meta:
            return String(format: "t = %.1f ms\n[ATP] = %.3f  [ADP] = %.3f mM", p.t, p.atp, p.adp)
        case .nernst:
            return String(format: "t = %.1f ms\nE_Na = %.1f  E_K = %.1f mV", p.t, p.eNa, p.eK)
        }
    }

    // MARK: Summary bar

    @ViewBuilder
    private func summaryBar(pts: [SimulationViewModel.EnergyPlotPoint]) -> some View {
        if let last = pts.last, let first = pts.first {
            let totalATP  = last.atpConsumed - first.atpConsumed   // mM consumed
            let duration  = last.t - first.t   // ms
            // Count approximate spikes from ATP consumed bursts — proxy: just show raw numbers
            HStack(spacing: 20) {
                statLabel("ATP consommé", value: String(format: "%.4f mM", totalATP))
                statLabel("Durée", value: String(format: "%.0f ms", duration))
                statLabel("E_Na final", value: String(format: "%.1f mV", last.eNa))
                statLabel("E_K final",  value: String(format: "%.1f mV", last.eK))
                statLabel("[ATP] final", value: String(format: "%.3f mM", last.atp))
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func statLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced))
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
