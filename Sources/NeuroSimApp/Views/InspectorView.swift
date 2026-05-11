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
        case .compartment(let compID):
            if let n = vm.network.neurons.first(where: { $0.compartments.contains(where: { $0.id == compID }) }) {
                NeuronInspector(neuron: n)
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

            // Method picker
            Picker("Méthode", selection: $vm.integrationMethod) {
                ForEach(IntegrationMethod.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.menu)

            Text(vm.integrationMethod.shortDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // dt slider — range adapts to selected method
            NumericSlider(label: "dt",
                          value: $vm.dt,
                          range: 0.001...max(0.1, vm.integrationMethod.maxSafeDt),
                          step: 0.005,
                          format: "%.3f",
                          unit: "ms",
                          labelWidth: 90)

            if vm.dt > vm.integrationMethod.maxSafeDt {
                Label("dt dépasse la limite recommandée (\(String(format: "%.3f", vm.integrationMethod.maxSafeDt)) ms)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Window")
                .font(.headline)
                .padding(.top, 6)
            NumericSlider(label: nil,
                          value: $vm.plotWindow,
                          range: 50...2000,
                          step: 25,
                          format: "%.0f",
                          unit: "ms")
        }
    }
}

// MARK: - Neuron inspector (compartment-aware)

private struct NeuronInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron

    /// Single source of truth: derives from vm.selection, falls back to soma.
    private var selectedCompartmentID: UUID {
        if case .compartment(let id) = vm.selection,
           neuron.compartments.contains(where: { $0.id == id }) {
            return id
        }
        return neuron.somaCompartmentID
    }

    private var selectionBinding: Binding<UUID> {
        Binding(
            get: { selectedCompartmentID },
            set: { vm.selection = .compartment($0) }
        )
    }

    private var selectedCompartment: Compartment? {
        neuron.compartments.first(where: { $0.id == selectedCompartmentID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Neuron").font(.title3.bold())
                Spacer()
                Button(role: .destructive) {
                    vm.removeSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this neuron (or press Delete)")
            }

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
                    let parent = selectedCompartmentID == neuron.somaCompartmentID ? nil : selectedCompartmentID
                    if let new = vm.addCompartment(to: neuron.id, parent: parent) {
                        vm.selection = .compartment(new.id)
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            CompartmentList(neuron: neuron, selection: selectionBinding)

            // ─── Selected compartment editor ───────────────────
            if let comp = selectedCompartment {
                Divider().padding(.vertical, 4)
                CompartmentEditor(neuron: neuron, compartment: comp,
                                  selection: selectionBinding)
            }

            // ─── Couplings ─────────────────────────────────────
            if neuron.compartments.count > 1 {
                Divider().padding(.vertical, 4)
                CouplingsSection(neuron: neuron)
            }
        }
    }
}

// MARK: - Compartment list (selectable rows)

private struct CompartmentList: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    @Binding var selection: UUID

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
    @Binding var selection: UUID

    @State private var showLibrary = false

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

            NumericSlider(label: "Capacitance",
                          value: Binding(
                            get: { compartment.capacitance },
                            set: { compartment.capacitance = $0; vm.objectWillChange.send() }
                          ),
                          range: 0.1...3.0,
                          format: "%.2f",
                          unit: "µF/cm²",
                          labelWidth: 90)

            // Geometry
            Text("Géométrie")
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)

            NumericSlider(label: "Diamètre",
                          value: Binding(
                            get: { compartment.diameter },
                            set: { compartment.diameter = $0; vm.objectWillChange.send() }
                          ),
                          range: 1...500,
                          format: "%.1f",
                          unit: "µm",
                          labelWidth: 90)

            NumericSlider(label: "Longueur",
                          value: Binding(
                            get: { compartment.length },
                            set: { compartment.length = $0; vm.objectWillChange.send() }
                          ),
                          range: 1...2000,
                          format: "%.1f",
                          unit: "µm",
                          labelWidth: 90)

            // Branch point — only meaningful when parent is a dendrite (not soma)
            let parentID = neuron.axialCouplings
                .first(where: { $0.involves(compartment.id) })?
                .other(compartment.id)
            let parentIsDendrite = parentID != nil && parentID != neuron.somaCompartmentID
            if !isSoma && parentIsDendrite {
                NumericSlider(label: "Point attache",
                              value: Binding(
                                get: { compartment.branchFraction },
                                set: { compartment.branchFraction = max(0, min(1, $0))
                                       vm.objectWillChange.send() }
                              ),
                              range: 0...1,
                              format: "%.2f",
                              unit: "",
                              labelWidth: 90)
            }

            // Read-only area display
            HStack {
                Text("Surface")
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                Spacer()
                Text(String(format: "%.2e cm²", compartment.area))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                Button {
                    showLibrary = true
                } label: {
                    Label("Bibliothèque", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Ajouter un canal depuis la bibliothèque")
            }
            .sheet(isPresented: $showLibrary) {
                ChannelLibrarySheet(compartmentID: compartment.id,
                                    neuronID: neuron.id)
                    .environmentObject(vm)
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
            ConcentrationTrackingSection(compartment: compartment)

            Divider().padding(.vertical, 2)

            // ─── Stimulus on this compartment ──────────────────
            Text("Stimulus").font(.subheadline.bold())
            StimulusEditor(compartmentID: compartment.id)

            Divider().padding(.vertical, 2)

            // ─── Synaptic noise on this compartment ────────────
            SynapticNoiseInspector(compartmentID: compartment.id)
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

    @State private var showChannelEditor = false

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
                if channel is HHGated {
                    Button {
                        showChannelEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("Éditer les gates / cinétique")
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
            NumericSlider(label: "g_max",
                          value: Binding(
                            get: { channel.gMax },
                            set: { channel.gMax = $0; vm.objectWillChange.send() }
                          ),
                          range: 0...500,
                          format: "%.2f",
                          unit: "mS/cm²",
                          labelWidth: 90)
            NumericSlider(label: "E_rev",
                          value: Binding(
                            get: { channel.reversal },
                            set: { channel.reversal = $0; vm.objectWillChange.send() }
                          ),
                          range: -100...200,
                          format: "%.1f",
                          unit: "mV",
                          labelWidth: 90)
        }
        .padding(8)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .sheet(isPresented: $showChannelEditor) {
            if let hh = channel as? (any HHGated) {
                ChannelEditorSheet(
                    channel: hh,
                    context: .compartment(channel: hh) { _ in
                        vm.objectWillChange.send()
                        vm.rebuildSimulatorPublic()
                    }
                )
            }
        }
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
            NumericSlider(
                label: nil,
                value: Binding(
                    get: { coup.conductance },
                    set: { newValue in
                        if let i = neuron.axialCouplings.firstIndex(where: { $0.id == coup.id }) {
                            neuron.axialCouplings[i].conductance = newValue
                            vm.objectWillChange.send()
                        }
                    }
                ),
                range: 0...5,
                format: "%.2f",
                unit: "µS"
            )
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
                doubleSlider("Amplitude", "µA/cm²", bind(s, \.amplitude), -20...30)
            case let s as PulseStimulus:
                doubleSlider("Start",     "ms",     bind(s, \.start),     0...500)
                doubleSlider("Duration",  "ms",     bind(s, \.duration),  1...500)
                doubleSlider("Amplitude", "µA/cm²", bind(s, \.amplitude), -20...30)
            case let s as RampStimulus:
                doubleSlider("Start",     "ms",     bind(s, \.start),     0...500)
                doubleSlider("Duration",  "ms",     bind(s, \.duration),  1...500)
                doubleSlider("From",      "µA/cm²", bind(s, \.from),     -20...30)
                doubleSlider("To",        "µA/cm²", bind(s, \.to),       -20...30)
            case let s as TrainStimulus:
                doubleSlider("Start",     "ms",     bind(s, \.start),      0...500)
                doubleSlider("Period",    "ms",     bind(s, \.period),     1...200)
                doubleSlider("Width",     "ms",     bind(s, \.pulseWidth), 0.1...50)
                doubleSlider("Amplitude", "µA/cm²", bind(s, \.amplitude), -20...30)
            case let s as OUNoiseStimulus:
                doubleSlider("Mean",      "µA/cm²", bind(s, \.mean),  -20...30)
                doubleSlider("Sigma",     "µA/cm²", bind(s, \.sigma),   0...20)
                doubleSlider("Tau",       "ms",     bind(s, \.tau),    0.5...100)
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
                              _ unit: String,
                              _ binding: Binding<Double>,
                              _ range: ClosedRange<Double>) -> some View {
        NumericSlider(label: label,
                      value: binding,
                      range: range,
                      format: "%.2f",
                      unit: unit,
                      labelWidth: 90)
    }

    private func bind<T: AnyObject, V>(_ object: T,
                                       _ keyPath: ReferenceWritableKeyPath<T, V>) -> Binding<V> {
        Binding(
            get: { object[keyPath: keyPath] },
            set: { object[keyPath: keyPath] = $0; vm.objectWillChange.send() }
        )
    }
}

// MARK: - Concentration tracking section

private struct ConcentrationTrackingSection: View {
    @EnvironmentObject var vm: SimulationViewModel
    let compartment: Compartment

    // Ions that have at least one channel conducting them
    private var conductedIons: [IonSpecies] {
        var seen = Set<String>()
        var result: [IonSpecies] = []
        for ch in compartment.channels {
            if let sp = ch.species, !seen.contains(sp.symbol) {
                seen.insert(sp.symbol)
                result.append(sp)
            }
        }
        return result
    }

    var body: some View {
        if conductedIons.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Concentration tracking").font(.subheadline.bold())

                ForEach(conductedIons, id: \.symbol) { sp in
                    ionRow(sp)
                }
            }
        }
    }

    @ViewBuilder
    private func ionRow(_ sp: IonSpecies) -> some View {
        let isTracked = compartment.concentrationDynamics.contains { $0.ionSymbol == sp.symbol }
        let dyn = compartment.concentrationDynamics.first { $0.ionSymbol == sp.symbol }

        VStack(alignment: .leading, spacing: 6) {
            Toggle("[\(sp.symbol)]_in", isOn: Binding(
                get: { isTracked },
                set: { on in
                    if on {
                        let defaultConc = IonSpecies.canonical(symbol: sp.symbol)?.defaultConcentrationIn ?? 1.0
                        vm.setConcentrationDynamic(
                            ConcentrationDynamic(ionSymbol: sp.symbol,
                                                 restingConc: defaultConc,
                                                 tauDecay: 100),
                            inCompartment: compartment.id)
                    } else {
                        vm.removeConcentrationDynamic(ionSymbol: sp.symbol,
                                                      fromCompartment: compartment.id)
                    }
                }
            ))
            .font(.callout)

            if isTracked, let d = dyn {
                NumericSlider(label: "[X]_rest",
                              value: Binding(
                                get: { d.restingConc },
                                set: { val in
                                    var updated = d; updated.restingConc = val
                                    vm.setConcentrationDynamic(updated, inCompartment: compartment.id)
                                }
                              ),
                              range: 1e-5...10,
                              step: d.restingConc < 0.01 ? 1e-5 : 0.01,
                              format: d.restingConc < 0.001 ? "%.2e" : "%.4f",
                              unit: "mM",
                              labelWidth: 70)

                NumericSlider(label: "τ_pump",
                              value: Binding(
                                get: { d.tauDecay },
                                set: { val in
                                    var updated = d; updated.tauDecay = val
                                    vm.setConcentrationDynamic(updated, inCompartment: compartment.id)
                                }
                              ),
                              range: 1...2000,
                              format: "%.0f",
                              unit: "ms",
                              labelWidth: 70)
            }
        }
        .padding(6)
        .background(isTracked ? Color.cyan.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Synaptic noise inspector

private struct SynapticNoiseInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    let compartmentID: UUID

    private var hasNoise: Bool { vm.network.synapticNoises[compartmentID] != nil }

    private var paramsBinding: Binding<SynapticNoiseParams> {
        Binding(
            get: { vm.network.synapticNoises[compartmentID]?.params ?? SynapticNoiseParams() },
            set: { vm.updateSynapticNoiseParams($0, forCompartment: compartmentID) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.badge.plus").foregroundStyle(.orange)
                Text("Bruit synaptique").font(.subheadline.bold())
                Spacer()
                Toggle("", isOn: Binding(
                    get: { hasNoise },
                    set: { on in
                        if on { vm.setSynapticNoise(SynapticNoiseParams(), onCompartment: compartmentID) }
                        else  { vm.setSynapticNoise(nil, onCompartment: compartmentID) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if hasNoise {
                let p = paramsBinding
                VStack(spacing: 6) {
                    // ── Weight ───────────────────────────────────────
                    noiseSlider("poids", "",       p.weight,  0...1)

                    Divider()

                    // ── Excitatory ────────────────────────────────────
                    Text("Excitateur (Ee = \(String(format:"%.0f", p.ee.wrappedValue)) mV)")
                        .font(.caption).foregroundStyle(.secondary)
                    noiseSlider("ḡₑ",  "mS/cm²", p.geMean,  0...0.2)
                    noiseSlider("σₑ",  "mS/cm²", p.geSigma, 0...0.05)
                    noiseSlider("τₑ",  "ms",      p.geTau,   0.5...30)

                    Divider()

                    // ── Inhibitory ────────────────────────────────────
                    Text("Inhibiteur (Ei = \(String(format:"%.0f", p.ei.wrappedValue)) mV)")
                        .font(.caption).foregroundStyle(.secondary)
                    noiseSlider("ḡᵢ",  "mS/cm²", p.giMean,  0...0.2)
                    noiseSlider("σᵢ",  "mS/cm²", p.giSigma, 0...0.05)
                    noiseSlider("τᵢ",  "ms",      p.giTau,   0.5...30)
                }
                .padding(8)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func noiseSlider(_ label: String, _ unit: String,
                              _ binding: Binding<Double>,
                              _ range: ClosedRange<Double>) -> some View {
        NumericSlider(label: label, value: binding, range: range,
                      format: "%.4f", unit: unit, labelWidth: 36)
    }
}

// MARK: - Synapse inspector (unchanged)

private struct SynapseInspector: View {
    @EnvironmentObject var vm: SimulationViewModel
    let synapse: Synapse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Synapse").font(.title3.bold())
                Spacer()
                Button(role: .destructive) {
                    vm.removeSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this synapse (or press Delete)")
            }

            if let chem = synapse as? ChemicalSynapse {
                Text("Chemical").font(.callout).foregroundStyle(.secondary)
                connectivityLabel
                targetCompartmentPicker
                paramSlider("g_max", unit: "mS/cm²", value: Binding(
                    get: { chem.gMax },
                    set: { chem.gMax = $0; vm.objectWillChange.send() }
                ), range: 0...3)
                paramSlider("E_rev", unit: "mV", value: Binding(
                    get: { chem.reversal },
                    set: { chem.reversal = $0; vm.objectWillChange.send() }
                ), range: -90...20)
                paramSlider("τ_decay", unit: "ms", value: Binding(
                    get: { chem.tauDecay },
                    set: { chem.tauDecay = max($0, 0.1); vm.objectWillChange.send() }
                ), range: 0.5...50)
                weightSlider
                // Colour convention matches the post-synaptic dot in the
                // canvas: red = excitatory, green = inhibitory.
                Text(chem.reversal > -30 ? "Excitatory" : "Inhibitory")
                    .font(.caption)
                    .foregroundStyle(chem.reversal > -30 ? .red : .green)
            } else if let gap = synapse as? GapJunction {
                Text("Electrical (gap junction)")
                    .font(.callout).foregroundStyle(.secondary)
                connectivityLabel
                targetCompartmentPicker
                paramSlider("g", unit: "µS", value: Binding(
                    get: { gap.conductance },
                    set: { gap.conductance = $0; vm.objectWillChange.send() }
                ), range: 0...1)
                weightSlider
            }
        }
    }

    /// Plasticity weight (LTP/LTD-style multiplier). Lives on every
    /// `Synapse`, so this slider is shown for both chemical and gap
    /// junction inspectors. Default 1.0 means "no plasticity adjustment".
    private var weightSlider: some View {
        paramSlider("weight", unit: "", value: Binding(
            get: { synapse.weight },
            set: { synapse.weight = max(0, $0); vm.objectWillChange.send() }
        ), range: 0...4)
    }

    private var connectivityLabel: some View {
        let pre  = vm.network.neurons.first { $0.id == synapse.preNeuronID }?.name  ?? "?"
        let post = vm.network.neurons.first { $0.id == synapse.postNeuronID }?.name ?? "?"
        return Label("\(pre) → \(post)", systemImage: "arrow.right")
            .font(.callout)
    }

    @ViewBuilder
    private var targetCompartmentPicker: some View {
        if let postNeuron = vm.network.neurons.first(where: { $0.id == synapse.postNeuronID }),
           postNeuron.compartments.count > 1 {
            let comps = postNeuron.compartments
            let currentID = synapse.postCompartmentID ?? postNeuron.somaCompartmentID
            HStack {
                Text("Cible")
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: Binding(
                    get: { currentID },
                    set: { newID in
                        synapse.postCompartmentID = newID == postNeuron.somaCompartmentID ? nil : newID
                        vm.objectWillChange.send()
                    }
                )) {
                    ForEach(comps, id: \.id) { comp in
                        Text(comp.name).tag(comp.id)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func paramSlider(_ label: String,
                             unit: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>) -> some View {
        NumericSlider(label: label,
                      value: value,
                      range: range,
                      format: "%.2f",
                      unit: unit,
                      labelWidth: 90)
    }
}
