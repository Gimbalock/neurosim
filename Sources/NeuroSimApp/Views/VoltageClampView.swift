//
//  VoltageClampView.swift
//  NeuroSimApp
//
//  Voltage-clamp protocol editor + I(t) family + I-V curve.
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - Data models for Charts

private struct TracePoint: Identifiable {
    let id = UUID()
    let time:      Double   // ms
    let current:   Double   // µA/cm²
    let stepIndex: Int      // for color mapping
    let stepVoltage: Double // mV — used in legend
}

private struct IVPoint: Identifiable {
    let id = UUID()
    let voltage:     Double
    let current:     Double
    let channelName: String
}

// MARK: - Main view

struct VoltageClampView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @StateObject private var runner = VoltageClampRunner()

    @State private var selectedChannelIndex: Int? = nil   // nil = sum

    // Cursor — I(t) chart
    @State private var cursorTime: Double?  = nil
    @State private var cursorI:    Double?  = nil
    @State private var cursorAbs:  CGPoint? = nil
    // Cursor — I/V chart
    @State private var cursorIV_V:   Double?  = nil
    @State private var cursorIV_I:   Double?  = nil
    @State private var cursorIV_Abs: CGPoint? = nil

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            HSplitView {
                itChart
                    .frame(minWidth: 200)
                ivChart
                    .frame(minWidth: 160)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { autoSelectNeuron() }
        .onChange(of: vm.network.neurons.map(\.id)) { _, _ in autoSelectNeuron() }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                neuronPicker
                if let nid = runner.selectedNeuronID,
                   let neuron = vm.network.neurons.first(where: { $0.id == nid }),
                   neuron.compartments.count > 1 {
                    compartmentPicker(neuron: neuron)
                }
                Divider().frame(height: 24)
                labeledField("V hold",  value: $runner.vcProtocol.vHold,  range: -120...0,   unit: "mV", fmt: "%.0f")
                labeledField("V start", value: $runner.vcProtocol.vStart, range: -120...0,   unit: "mV", fmt: "%.0f")
                labeledField("V end",   value: $runner.vcProtocol.vEnd,   range: -80...120,  unit: "mV", fmt: "%.0f")
                labeledIntField("Paliers", value: $runner.vcProtocol.nSteps, range: 2...30)
                Divider().frame(height: 24)
                labeledField("t pré",   value: $runner.vcProtocol.tPre,   range: 5...500,    unit: "ms", fmt: "%.0f")
                labeledField("t palier",value: $runner.vcProtocol.tStep,  range: 10...2000,  unit: "ms", fmt: "%.0f")
                Divider().frame(height: 24)
                runButton
                if runner.isRunning {
                    ProgressView(value: Double(runner.progress),
                                 total: Double(max(1, runner.vcProtocol.nSteps)))
                        .frame(width: 80)
                }
                Text(runner.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var neuronPicker: some View {
        let neurons = vm.network.neurons
        if neurons.isEmpty {
            Text("Aucun neurone").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Neurone", selection: $runner.selectedNeuronID) {
                ForEach(neurons) { n in
                    Text(n.name).tag(Optional(n.id))
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    @ViewBuilder
    private func compartmentPicker(neuron: HHNeuron) -> some View {
        Picker("Compartiment", selection: $runner.selectedCompartmentID) {
            ForEach(neuron.compartments) { c in
                Text(c.name).tag(Optional(c.id))
            }
        }
        .labelsHidden()
        .frame(width: 90)
    }

    @ViewBuilder
    private func labeledField(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>, unit: String, fmt: String) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .multilineTextAlignment(.trailing)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func labeledIntField(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 38)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var runButton: some View {
        if runner.isRunning {
            Button(action: { runner.stop() }) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        } else {
            Button(action: { runner.run(network: vm.network) }) {
                Label("Lancer", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.selectedNeuronID == nil)
        }
    }

    // MARK: - I(t) chart

    @ViewBuilder
    private var itChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            channelSelector
            if let result = runner.result, !result.traces.isEmpty {
                let stepColors = (0..<result.traces.count).map { i in
                    stepColor(index: i, total: result.traces.count)
                }
                Chart {
                    ForEach(0..<result.traces.count, id: \.self) { si in
                        ForEach(itDataForStep(result: result, stepIndex: si)) { pt in
                            LineMark(
                                x: .value("t (ms)", pt.time),
                                y: .value("I (µA/cm²)", pt.current)
                            )
                            .foregroundStyle(by: .value("palier", pt.stepIndex))
                            .lineStyle(.init(lineWidth: 1))
                        }
                    }
                    // No RuleMark — cursor drawn as Path overlay to avoid chart re-render
                }
                .chartForegroundStyleScale(range: stepColors)
                .chartXAxisLabel("t (ms)")
                .chartYAxisLabel("I (µA/cm²)")
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let f = proxy.plotFrame.map { geo[$0] } ?? .zero
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let rx = loc.x - f.minX
                                    let ry = loc.y - f.minY
                                    guard rx >= 0, rx <= f.width, ry >= 0, ry <= f.height else {
                                        cursorTime = nil; return
                                    }
                                    cursorAbs  = loc
                                    cursorTime = proxy.value(atX: rx, as: Double.self)
                                    cursorI    = proxy.value(atY: ry, as: Double.self)
                                case .ended:
                                    cursorTime = nil; cursorI = nil; cursorAbs = nil
                                }
                            }
                        // Cursor vertical line
                        if let loc = cursorAbs {
                            Path { p in
                                p.move(to: CGPoint(x: loc.x, y: f.minY))
                                p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                            }
                            .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .allowsHitTesting(false)
                        }
                        // Label
                        if let loc = cursorAbs, let t = cursorTime, let i = cursorI {
                            let lx = loc.x + 10 > f.maxX - 120 ? loc.x - 125 : loc.x + 10
                            Text(String(format: "t = %.2f ms\nI = %.3g µA/cm²", t, i))
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                                .position(x: lx + 53, y: max(loc.y - 4, f.minY + 18))
                        }
                    }
                }
                .padding(12)
            } else {
                emptyPlaceholder(text: runner.isRunning ? "Calcul en cours…" : "Lancez le protocole")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var channelSelector: some View {
        if let result = runner.result, result.channelNames.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("Total") { selectedChannelIndex = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(selectedChannelIndex == nil ? .accentColor : .secondary)
                    ForEach(result.channelNames.indices, id: \.self) { ci in
                        Button(result.channelNames[ci]) { selectedChannelIndex = ci }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(selectedChannelIndex == ci ? channelColor(ci) : .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            .frame(height: 34)
        }
    }

    // MARK: - I-V chart

    @ViewBuilder
    private var ivChart: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("I-V (steady-state)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.top, 8)
            if let result = runner.result, !result.traces.isEmpty {
                let data = ivData(result: result)
                Chart(data) { pt in
                    LineMark(
                        x: .value("V (mV)", pt.voltage),
                        y: .value("I (µA/cm²)", pt.current)
                    )
                    .foregroundStyle(by: .value("Canal", pt.channelName))
                    PointMark(
                        x: .value("V (mV)", pt.voltage),
                        y: .value("I (µA/cm²)", pt.current)
                    )
                    .foregroundStyle(by: .value("Canal", pt.channelName))
                    .symbolSize(20)
                }
                .chartXAxisLabel("V (mV)")
                .chartYAxisLabel("I (µA/cm²)")
                .chartForegroundStyleScale(channelColorScale(result: result))
                .chartLegend(position: .bottom, alignment: .center)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let f = proxy.plotFrame.map { geo[$0] } ?? .zero
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let rx = loc.x - f.minX
                                    let ry = loc.y - f.minY
                                    guard rx >= 0, rx <= f.width, ry >= 0, ry <= f.height else {
                                        cursorIV_V = nil; return
                                    }
                                    cursorIV_Abs = loc
                                    cursorIV_V   = proxy.value(atX: rx, as: Double.self)
                                    cursorIV_I   = proxy.value(atY: ry, as: Double.self)
                                case .ended:
                                    cursorIV_V = nil; cursorIV_I = nil; cursorIV_Abs = nil
                                }
                            }
                        if let loc = cursorIV_Abs {
                            let style = StrokeStyle(lineWidth: 1, dash: [4, 4])
                            Path { p in
                                p.move(to: CGPoint(x: loc.x, y: f.minY))
                                p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                            }
                            .stroke(Color.white.opacity(0.45), style: style)
                            .allowsHitTesting(false)
                            Path { p in
                                p.move(to: CGPoint(x: f.minX, y: loc.y))
                                p.addLine(to: CGPoint(x: f.maxX, y: loc.y))
                            }
                            .stroke(Color.white.opacity(0.45), style: style)
                            .allowsHitTesting(false)
                        }
                        if let loc = cursorIV_Abs, let v = cursorIV_V, let i = cursorIV_I {
                            let lx = loc.x + 10 > f.maxX - 130 ? loc.x - 135 : loc.x + 10
                            Text(String(format: "V = %.1f mV\nI = %.3g µA/cm²", v, i))
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                                .position(x: lx + 53, y: max(loc.y, f.minY + 24))
                        }
                    }
                }
                .padding(12)
            } else {
                emptyPlaceholder(text: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data builders

    private func itDataForStep(result: VClampResult, stepIndex si: Int) -> [TracePoint] {
        let stepTraces = result.traces[si]
        guard let refTrace = stepTraces.first else { return [] }
        let vTest = result.vcProtocol.stepVoltages[si]
        return refTrace.times.indices.map { ti in
            let I: Double
            if let ci = selectedChannelIndex, ci < stepTraces.count {
                I = stepTraces[ci].currentsDensity[ti]
            } else {
                I = stepTraces.reduce(0.0) { $0 + $1.currentsDensity[ti] }
            }
            return TracePoint(time: refTrace.times[ti], current: I,
                              stepIndex: si, stepVoltage: vTest)
        }
    }

    private func ivData(result: VClampResult) -> [IVPoint] {
        var pts: [IVPoint] = []
        let matrix = result.steadyStateMatrix   // [channelIndex][stepIndex]
        let stepVs = result.vcProtocol.stepVoltages
        for (ci, name) in result.channelNames.enumerated() {
            guard ci < matrix.count else { continue }
            for (si, v) in stepVs.enumerated() {
                guard si < matrix[ci].count else { continue }
                pts.append(IVPoint(voltage: v, current: matrix[ci][si], channelName: name))
            }
        }
        return pts
    }

    // MARK: - Color helpers

    private func stepColor(index: Int, total: Int) -> Color {
        let t = total > 1 ? Double(index) / Double(total - 1) : 0.5
        return Color(hue: (1 - t) * 0.67, saturation: 0.9, brightness: 0.85)
    }

    private let channelColors: [Color] = [.blue, .orange, .red, .green, .purple, .teal, .pink, .yellow]

    private func channelColor(_ index: Int) -> Color {
        channelColors[index % channelColors.count]
    }

    private func channelColorScale(result: VClampResult) -> KeyValuePairs<String, Color> {
        // Build explicit scale for chartForegroundStyleScale
        var pairs: [(String, Color)] = []
        for (ci, name) in result.channelNames.enumerated() {
            pairs.append((name, channelColor(ci)))
        }
        // KeyValuePairs doesn't have a direct init from [(K,V)]; use a switch on count
        switch pairs.count {
        case 1:  return [pairs[0].0: pairs[0].1]
        case 2:  return [pairs[0].0: pairs[0].1, pairs[1].0: pairs[1].1]
        case 3:  return [pairs[0].0: pairs[0].1, pairs[1].0: pairs[1].1,
                         pairs[2].0: pairs[2].1]
        case 4:  return [pairs[0].0: pairs[0].1, pairs[1].0: pairs[1].1,
                         pairs[2].0: pairs[2].1, pairs[3].0: pairs[3].1]
        case 5:  return [pairs[0].0: pairs[0].1, pairs[1].0: pairs[1].1,
                         pairs[2].0: pairs[2].1, pairs[3].0: pairs[3].1,
                         pairs[4].0: pairs[4].1]
        default: return [pairs[0].0: pairs[0].1]
        }
    }

    // MARK: - Placeholder

    @ViewBuilder
    private func emptyPlaceholder(text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
                .padding(12)
            if !text.isEmpty {
                Text(text).foregroundStyle(.tertiary).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Auto-select

    private func autoSelectNeuron() {
        if runner.selectedNeuronID == nil || !vm.network.neurons.contains(where: { $0.id == runner.selectedNeuronID }) {
            runner.selectedNeuronID = vm.network.neurons.first?.id
        }
    }
}
