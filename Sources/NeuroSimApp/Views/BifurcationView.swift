//
//  BifurcationView.swift
//  NeuroSimApp
//
//  Bifurcation diagram: scatter plot of V local maxima (orange) and minima
//  (teal) as a function of a swept parameter (I_inj or channel gMax).
//

import SwiftUI
import Charts
import NeuroSimCore

struct BifurcationView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @StateObject private var runner = BifurcationRunner()

    // Current parameter tag (encodes BifSweepParam as a String for Picker)
    @State private var paramTag: String = "iInj"

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            chartArea
        }
        .onAppear {
            autoSelectNeuron()
            syncParamTag()
        }
        .onChange(of: vm.network.neurons.map(\.id)) { _, _ in autoSelectNeuron() }
        .onChange(of: runner.selectedNeuronID)      { _, _ in syncParamTag() }
        .onChange(of: paramTag)                     { _, tag in applyParamTag(tag) }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // Neuron picker
                neuronPicker
                Divider().frame(height: 24)

                // Parameter picker (I_inj + all channel gMax)
                VStack(alignment: .center, spacing: 1) {
                    Text("Paramètre").font(.system(size: 9)).foregroundStyle(.secondary)
                    Picker("", selection: $paramTag) {
                        ForEach(paramChoices, id: \.tag) { choice in
                            Text(choice.label).tag(choice.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Divider().frame(height: 24)

                // Range
                numField("Min",   value: $runner.config.paramMin,   width: 52)
                numField("Max",   value: $runner.config.paramMax,   width: 52)
                intField("Paliers", value: $runner.config.nSteps,   width: 42)

                Divider().frame(height: 24)

                numField("t transient", value: $runner.config.tTransient, width: 54, unit: "ms")
                numField("t collecte",  value: $runner.config.tCollect,   width: 54, unit: "ms")

                Divider().frame(height: 24)

                // Run / Stop
                runButton

                if runner.isRunning {
                    ProgressView(value: Double(runner.progress),
                                 total: Double(max(1, runner.config.nSteps)))
                        .frame(width: 80)
                }
                Text(runner.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 120, alignment: .leading)
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
            Picker("", selection: $runner.selectedNeuronID) {
                ForEach(neurons) { n in Text(n.name).tag(Optional(n.id)) }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    @ViewBuilder
    private var runButton: some View {
        if runner.isRunning {
            Button { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.bordered).tint(.red)
        } else {
            Button { runner.run(network: vm.network) } label: {
                Label("Lancer", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.selectedNeuronID == nil)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartArea: some View {
        if runner.points.isEmpty {
            ZStack {
                Color.clear
                Text(runner.isRunning ? "Calcul en cours…" : "Lancez le calcul")
                    .foregroundStyle(.tertiary).font(.caption)
            }
        } else {
            let pts    = runner.points
            let xLabel = paramLabel
            Chart {
                ForEach(pts.filter(\.isMax)) { pt in
                    PointMark(x: .value(xLabel, pt.param),
                              y: .value("V (mV)", pt.v))
                    .foregroundStyle(.orange)
                    .symbolSize(12)
                }
                ForEach(pts.filter { !$0.isMax }) { pt in
                    PointMark(x: .value(xLabel, pt.param),
                              y: .value("V (mV)", pt.v))
                    .foregroundStyle(.teal)
                    .symbolSize(12)
                }
            }
            .chartXAxisLabel(xLabel)
            .chartYAxisLabel("V (mV)")
            .chartLegend(.hidden)
            .padding(16)
            // Colour legend (manual — small pills)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 10) {
                    legendPill("Maxima", color: .orange)
                    legendPill("Minima", color: .teal)
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func legendPill(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Field helpers

    @ViewBuilder
    private func numField(_ label: String, value: Binding<Double>,
                          width: CGFloat, unit: String? = nil) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .multilineTextAlignment(.trailing)
                if let u = unit {
                    Text(u).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func intField(_ label: String, value: Binding<Int>, width: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Parameter choices

    private struct ParamChoice { let tag: String; let label: String; let param: BifSweepParam }

    private var paramChoices: [ParamChoice] {
        var list: [ParamChoice] = [ParamChoice(tag: "iInj", label: "I inj (µA/cm²)", param: .iInj)]
        guard let nid    = runner.selectedNeuronID,
              let neuron = vm.network.neurons.first(where: { $0.id == nid }) else { return list }
        for (ci, comp) in neuron.compartments.enumerated() {
            for (chi, ch) in comp.channels.enumerated() {
                let tag = "gmax_\(ci)_\(chi)"
                list.append(ParamChoice(tag: tag,
                                        label: "\(ch.name) gMax (mS/cm²)",
                                        param: .channelGMax(compartmentIdx: ci, channelIdx: chi)))
            }
        }
        return list
    }

    private var paramLabel: String {
        guard let nid    = runner.selectedNeuronID,
              let neuron = vm.network.neurons.first(where: { $0.id == nid }) else {
            return runner.sweepParam.unit
        }
        return runner.sweepParam.label(for: neuron)
    }

    // MARK: - Sync helpers

    private func applyParamTag(_ tag: String) {
        runner.sweepParam = paramChoices.first(where: { $0.tag == tag })?.param ?? .iInj
    }

    private func syncParamTag() {
        if !paramChoices.contains(where: { $0.tag == paramTag }) {
            paramTag = "iInj"
        }
    }

    private func autoSelectNeuron() {
        if runner.selectedNeuronID == nil ||
           !vm.network.neurons.contains(where: { $0.id == runner.selectedNeuronID }) {
            runner.selectedNeuronID = vm.network.neurons.first?.id
        }
    }
}
