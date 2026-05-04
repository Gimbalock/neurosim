//
//  InspectorView.swift
//  NeuroSimApp
//
//  Right-hand inspector panel. Three states based on selection:
//   - empty   → integration / global parameters
//   - neuron  → name + compartment list + per-compartment editor + couplings
//   - synapse → chemical/gap-junction parameters
//
//  The neuron inspector is *compartment-aware*: every neuron-level edit goes
//  through a compartment selector, so dendrites get first-class UI alongside
//  the soma. The compartment editor itself hosts channel add/remove (Na+, K+,
//  Leak, Ca-T) and stimulus configuration.
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

// MARK: - Empty / global parameters

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

// MARK: - Neuron inspector (compartment-aware)

private struct NeuronInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron

    @State private var selectedCompartmentID: UUID? = nil

    private var selectedCompartment: Compartment? {
        guard let id = selectedCompartmentID
                ?? neuron.compartments.first?.id
        else { return nil }
        return neuron.compartments.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neuron").font(.title3.bold())

            HStack {
                Text("Name").frame(width: 90, alignment: .leading)
                TextField("name", text: Binding(
                    get: { neuron.name },
                    set: { neuron.name = $0; vm.objectWillChange.send() }
                ))
            }

            Divider().padding(.vertical, 4)

            // ─── Compartment list ──────────────────────────────
            HStack {
                Text("Compartments").font(.headline)
                Spacer()
                Button {
                    if let new = vm.addCompartment(to: neuron.id) {
                        selectedCompartmentID = new.id
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            CompartmentList(neuron: neuron, selection: $selectedCompartmentID)

            // ─── Selected compartment editor ───────────────────
            if let comp = selectedCompartment {
                Divider().padding(.vertical, 4)
                CompartmentEditor(neuron: neuron, compartment: comp,
                                  selection: $selectedCompartmentID)
            }

            // ─── Couplings ─────────────────────────────────────
            if neuron.compartments.count > 1 {
                Divider().padding(.vertical, 4)
                CouplingsSection(neuron: neuron)
            }
        }
        .onAppear {
            if selectedCompartmentID == nil {
                selectedCompartmentID = neuron.somaCompartmentID
            }
        }
    }
}

// MARK: - Compartment list (selectable rows)

private struct CompartmentList: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    @Binding var selection: UUID?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(neuron.compartments, id: \.id) { comp in
                let isSel = selection == comp.id
                let isSoma = comp.id == neuron.somaCompartmentID
                Button {
                    selection = comp.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSoma ? "star.fill" : "circle")
                            .foregroundStyle(isSoma ? .yellow : .secondary)
                            .font(.caption)
                        Text(comp.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("\(comp.channels.count) ch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        isSel ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Compartment editor (name, C_m, channels, stim)

private struct CompartmentEditor: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    let compartment: Compartment
    @Binding var selection: UUID?

    private var isSoma: Bool { compartment.id == neuron.somaCompartmentID }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Editing: \(compartment.name)")
                    .font(.callout.bold())
                if isSoma {
                    Text("soma")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.25),
                                    in: Capsule())
                        .foregroundStyle(.primary)
                }
                Spacer()
            }

            HStack {
                Text("Name").frame(width: 90, alignment: .leading)
                TextField("name", text: Binding(
                    get: { compartment.name },
                    set: { vm.renameCompartment(compartment.id, in: neuron.id, to: $0) }
                ))
            }

            HStack {
                Text("Capacitance").frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { compartment.capacitance },
                    set: { compartment.capacitance = $0; vm.objectWillChange.send() }
                ), in: 0.1...3.0)
                Text(String(format: "%.2f µF/cm²", compartment.capacitance))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            }

            // Soma toggle / delete
            HStack(spacing: 8) {
                if !isSoma {
                    Button {
                        vm.setSoma(compartment.id, of: neuron.id)
                    } label: {
                        Label("Mark as soma", systemImage: "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if !isSoma && neuron.compartments.count > 1 {
                    Button(role: .destructive) {
                        let toDelete = compartment.id
                        // After deletion, fall back to soma in the picker.
                        selection = neuron.somaCompartmentID
                        vm.removeCompartment(toDelete, from: neuron.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider().padding(.vertical, 2)

            // ─── Channels ──────────────────────────────────────
            HStack {
                Text("Ion channels").font(.subheadline.bold())
                Spacer()
                Menu {
                    ForEach(ChannelKind.allCases) { kind in
                        Button {
                            vm.addChannel(kind, toCompartment: compartment.id,
                                          in: neuron.id)
                        } label: {
                            Label(kind.rawValue, systemImage: kind.systemImage)
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if compartment.channels.isEmpty {
                Text("No channels — passive compartment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(compartment.channels.enumerated()), id: \.offset) { (i, ch) in
                    ChannelRow(channel: ch, indexInCompartment: i,
                               compartmentID: compartment.id,
                               neuronID: neuron.id)
                }
            }

            Divider().padding(.vertical, 2)

            // ─── Stimulus on this compartment ──────────────────
            Text("Stimulus").font(.subheadline.bold())
            StimulusEditor(compartmentID: compartment.id)
        }
    }
}

// MARK: - Channel row

private struct ChannelRow: View {
    @EnvironmentObject var vm: SimulationViewModel
    let channel: IonChannel
    let indexInCompartment: Int
    let compartmentID: UUID
    let neuronID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(channel.name).font(.callout.bold())
                if let species = channel.species {
                    Text(species.symbol)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.2), in: Capsule())
                }
                Spacer()
                Button(role: .destructive) {
                    vm.removeChannel(at: indexInCompartment,
                                     fromCompartment: compartmentID,
                                     in: neuronID)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Text("g_max").frame(width: 60, alignment: .leading).font(.caption)
                Slider(value: Binding(
                    get: { channel.gMax },
                    set: { channel.gMax = $0; vm.objectWillChange.send() }
                ), in: 0...200)
                Text(String(format: "%.2f", channel.gMax))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }
            HStack {
                Text("E_rev").frame(width: 60, alignment: .leading).font(.caption)
                Slider(value: Binding(
                    get: { channel.reversal },
                    set: { channel.reversal = $0; vm.objectWillChange.send() }
                ), in: -100...140)
                Text(String(format: "%.1f mV", channel.reversal))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(8)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Couplings section

private struct CouplingsSection: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron

    @State private var draftA: UUID? = nil
    @State private var draftB: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Axial couplings").font(.headline)

            if neuron.axialCouplings.isEmpty {
                Text("No couplings — compartments float electrically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(neuron.axialCouplings, id: \.id) { coup in
                    couplingRow(coup)
                }
            }

            // Add a new coupling
            HStack(spacing: 4) {
                compartmentPicker("from", selection: $draftA)
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                compartmentPicker("to", selection: $draftB)
                Button {
                    if let a = draftA, let b = draftB, a != b {
                        vm.addCoupling(between: a, and: b, in: neuron.id)
                        draftA = nil; draftB = nil
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(draftA == nil || draftB == nil || draftA == draftB)
            }
            .padding(.top, 4)
        }
    }

    private func couplingRow(_ coup: AxialCoupling) -> some View {
        let nameA = neuron.compartments.first { $0.id == coup.compartmentA }?.name ?? "?"
        let nameB = neuron.compartments.first { $0.id == coup.compartmentB }?.name ?? "?"
        return HStack(spacing: 6) {
            Text("\(nameA) ↔ \(nameB)")
                .font(.caption.monospaced())
                .frame(width: 110, alignment: .leading)
            Slider(value: Binding(
                get: { coup.conductance },
                set: { newValue in
                    if let i = neuron.axialCouplings.firstIndex(where: { $0.id == coup.id }) {
                        neuron.axialCouplings[i].conductance = newValue
                        vm.objectWillChange.send()
                    }
                }
            ), in: 0...5)
            Text(String(format: "%.2f", coup.conductance))
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            Button(role: .destructive) {
                vm.removeCoupling(coup.id, from: neuron.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func compartmentPicker(_ placeholder: String,
                                   selection: Binding<UUID?>) -> some View {
        Menu {
            ForEach(neuron.compartments, id: \.id) { comp in
                Button(comp.name) { selection.wrappedValue = comp.id }
            }
        } label: {
            let label = selection.wrappedValue.flatMap { id in
                neuron.compartments.first { $0.id == id }?.name
            } ?? placeholder
            Text(label)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Stimulus editor (now compartment-keyed)

private struct StimulusEditor: View {
    @EnvironmentObject var vm: SimulationViewModel
    let compartmentID: UUID

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
        switch vm.network.stimuli[compartmentID] {
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

            switch vm.network.stimuli[compartmentID] {
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
        vm.setStimulus(s, onCompartment: compartmentID)
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

    private func bind<T: AnyObject, V>(_ object: T,
                                       _ keyPath: ReferenceWritableKeyPath<T, V>) -> Binding<V> {
        Binding(
            get: { object[keyPath: keyPath] },
            set: { object[keyPath: keyPath] = $0; vm.objectWillChange.send() }
        )
    }
}

// MARK: - Synapse inspector (unchanged)

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
        let target = synapse.postCompartmentID.flatMap { compID in
            vm.network.neurons
                .flatMap(\.compartments)
                .first(where: { $0.id == compID })?.name
        } ?? "soma"
        return Label("\(pre) → \(post) [\(target)]", systemImage: "arrow.right")
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
