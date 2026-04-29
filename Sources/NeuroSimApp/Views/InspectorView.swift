//
//  InspectorView.swift
//  NeuroSimApp
//
//  Right-hand inspector panel. Switches between three states based on the
//  current selection: a neuron (with channels + stimulus), a synapse (with
//  per-type parameters), or nothing (welcome / global parameters).
//

import SwiftUI
import NeuroSimCore

struct InspectorView: View {
    @EnvironmentObject var vm: SimulationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(14)
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.selection {
        case .none:
            EmptyInspector()
        case .neuron(let id):
            if let n = vm.network.neurons.first(where: { $0.id == id }) {
                NeuronInspector(neuron: n)
            }
        case .synapse(let id):
            if let s = vm.network.synapses.first(where: { $0.id == id }) {
                SynapseInspector(synapse: s)
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspector")
                .font(.title3.bold())
            Text("Select a neuron or a synapse to edit its parameters, or use the toolbar to add new elements.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            Text("Integration")
                .font(.headline)
            HStack {
                Text("dt").frame(width: 30, alignment: .leading)
                Slider(value: $vm.dt, in: 0.005...0.1, step: 0.005)
                Text(String(format: "%.3f ms", vm.dt))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 70, alignment: .trailing)
            }
            Text("Window")
                .font(.headline)
                .padding(.top, 6)
            HStack {
                Slider(value: $vm.plotWindow, in: 50...2000, step: 25)
                Text("\(Int(vm.plotWindow)) ms")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }
}

// MARK: - Neuron inspector

private struct NeuronInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neuron")
                .font(.title3.bold())

            HStack {
                Text("Name").frame(width: 90, alignment: .leading)
                TextField("name", text: Binding(
                    get: { neuron.name },
                    set: { neuron.name = $0; vm.objectWillChange.send() }
                ))
            }

            HStack {
                Text("Capacitance").frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { neuron.capacitance },
                    set: { neuron.capacitance = $0; vm.objectWillChange.send() }
                ), in: 0.1...3.0)
                Text(String(format: "%.2f µF/cm²", neuron.capacitance))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            }

            Divider().padding(.vertical, 4)

            Text("Ion channels").font(.headline)
            ForEach(Array(neuron.channels.enumerated()), id: \.offset) { (_, ch) in
                ChannelEditor(channel: ch)
            }

            Divider().padding(.vertical, 4)

            Text("Stimulus").font(.headline)
            StimulusEditor(neuronID: neuron.id)
        }
    }
}

// MARK: - Channel editor

private struct ChannelEditor: View {
    @EnvironmentObject var vm: SimulationViewModel
    let channel: IonChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(channel.name).font(.callout.bold())
            HStack {
                Text("g_max").frame(width: 60, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.gMax },
                    set: { channel.gMax = $0; vm.objectWillChange.send() }
                ), in: 0...200)
                Text(String(format: "%.2f", channel.gMax))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            HStack {
                Text("E_rev").frame(width: 60, alignment: .leading)
                Slider(value: Binding(
                    get: { channel.reversal },
                    set: { channel.reversal = $0; vm.objectWillChange.send() }
                ), in: -100...80)
                Text(String(format: "%.1f mV", channel.reversal))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(8)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Stimulus editor

private struct StimulusEditor: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuronID: UUID

    enum Kind: String, CaseIterable, Identifiable {
        case none, constant, pulse, ramp, train, ouNoise
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "None"
            case .constant: "Constant"
            case .pulse: "Pulse"
            case .ramp: "Ramp"
            case .train: "Train"
            case .ouNoise: "OU Noise"
            }
        }
    }

    private var currentKind: Kind {
        switch vm.network.stimuli[neuronID] {
        case nil: return .none
        case is ConstantStimulus: return .constant
        case is PulseStimulus: return .pulse
        case is RampStimulus: return .ramp
        case is TrainStimulus: return .train
        case is OUNoiseStimulus: return .ouNoise
        default: return .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: Binding(
                get: { currentKind },
                set: { setKind($0) }
            )) {
                ForEach(Kind.allCases) { k in Text(k.label).tag(k) }
            }
            .pickerStyle(.menu)

            switch vm.network.stimuli[neuronID] {
            case let s as ConstantStimulus:
                doubleSlider("Amplitude (µA/cm²)", bind(s, \.amplitude), -20...30)
            case let s as PulseStimulus:
                doubleSlider("Start (ms)",     bind(s, \.start),     0...500)
                doubleSlider("Duration (ms)",  bind(s, \.duration),  1...500)
                doubleSlider("Amplitude (µA)", bind(s, \.amplitude), -20...30)
            case let s as RampStimulus:
                doubleSlider("Start (ms)",     bind(s, \.start),     0...500)
                doubleSlider("Duration (ms)",  bind(s, \.duration),  1...500)
                doubleSlider("From (µA)",      bind(s, \.from),     -20...30)
                doubleSlider("To (µA)",        bind(s, \.to),       -20...30)
            case let s as TrainStimulus:
                doubleSlider("Start (ms)",     bind(s, \.start),     0...500)
                doubleSlider("Period (ms)",    bind(s, \.period),    1...200)
                doubleSlider("Width (ms)",     bind(s, \.pulseWidth), 0.1...50)
                doubleSlider("Amplitude (µA)", bind(s, \.amplitude),-20...30)
            case let s as OUNoiseStimulus:
                doubleSlider("Mean (µA)",      bind(s, \.mean),     -20...30)
                doubleSlider("Sigma",          bind(s, \.sigma),     0...20)
                doubleSlider("Tau (ms)",       bind(s, \.tau),       0.5...100)
            default:
                EmptyView()
            }
        }
        .padding(8)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func setKind(_ k: Kind) {
        let s: Stimulus?
        switch k {
        case .none:     s = nil
        case .constant: s = ConstantStimulus(amplitude: 5)
        case .pulse:    s = PulseStimulus(start: 10, duration: 50, amplitude: 10)
        case .ramp:     s = RampStimulus(start: 10, duration: 100, from: 0, to: 15)
        case .train:    s = TrainStimulus(start: 10, period: 30, pulseWidth: 5, amplitude: 12)
        case .ouNoise:  s = OUNoiseStimulus(mean: 5, sigma: 3, tau: 5)
        }
        vm.setStimulus(s, on: neuronID)
    }

    @ViewBuilder
    private func doubleSlider(_ label: String,
                              _ binding: Binding<Double>,
                              _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading).font(.caption)
            Slider(value: binding, in: range)
            Text(String(format: "%.2f", binding.wrappedValue))
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 50, alignment: .trailing)
        }
    }

    /// Bind a class-property to a SwiftUI Slider, pinging the ViewModel on
    /// each write so dependent views (the network canvas, the plot legend)
    /// refresh too.
    private func bind<T: AnyObject, V>(_ object: T,
                                       _ keyPath: ReferenceWritableKeyPath<T, V>) -> Binding<V> {
        Binding(
            get: { object[keyPath: keyPath] },
            set: { object[keyPath: keyPath] = $0; vm.objectWillChange.send() }
        )
    }
}

// MARK: - Synapse inspector

private struct SynapseInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    let synapse: Synapse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synapse").font(.title3.bold())

            if let chem = synapse as? ChemicalSynapse {
                Text("Chemical").font(.callout).foregroundStyle(.secondary)
                connectivityLabel
                paramSlider("g_max", value: Binding(
                    get: { chem.gMax },
                    set: { chem.gMax = $0; vm.objectWillChange.send() }
                ), range: 0...3)
                paramSlider("E_rev", value: Binding(
                    get: { chem.reversal },
                    set: { chem.reversal = $0; vm.objectWillChange.send() }
                ), range: -90...20)
                paramSlider("τ_decay", value: Binding(
                    get: { chem.tauDecay },
                    set: { chem.tauDecay = max($0, 0.1); vm.objectWillChange.send() }
                ), range: 0.5...50)
                Text(chem.reversal > -30 ? "Excitatory" : "Inhibitory")
                    .font(.caption)
                    .foregroundStyle(chem.reversal > -30 ? .green : .red)
            } else if let gap = synapse as? GapJunction {
                Text("Electrical (gap junction)")
                    .font(.callout).foregroundStyle(.secondary)
                connectivityLabel
                paramSlider("g", value: Binding(
                    get: { gap.conductance },
                    set: { gap.conductance = $0; vm.objectWillChange.send() }
                ), range: 0...1)
            }
        }
    }

    private var connectivityLabel: some View {
        let pre  = vm.network.neurons.first { $0.id == synapse.preNeuronID }?.name  ?? "?"
        let post = vm.network.neurons.first { $0.id == synapse.postNeuronID }?.name ?? "?"
        return Label("\(pre) → \(post)", systemImage: "arrow.right")
            .font(.callout)
    }

    private func paramSlider(_ label: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }
}

