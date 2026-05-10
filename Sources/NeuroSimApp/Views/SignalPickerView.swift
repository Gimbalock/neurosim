//
//  SignalPickerView.swift
//  NeuroSimApp
//
//  Hierarchical parameter picker presented as a sheet from ResultsWindowView.
//
//  Two display modes (segmented control at the top):
//
//  "Par type"    — by-type sections: Tensions / Courants / Gating / Métabolique / Synapses
//  "Par neurone" — classic hierarchical tree: Neurons → Neuron N → Compartment → signal
//

import SwiftUI
import NeuroSimCore

// MARK: - View mode

private enum PickerMode: String, CaseIterable {
    case byType    = "Par type"
    case byNeuron  = "Par neurone"
}

// MARK: - Main view

struct SignalPickerView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Binding var isPresented: Bool
    /// When non-nil, newly selected signals are added to this existing chart group.
    var targetGroupID: UUID? = nil

    @State private var search = ""
    @State private var mode: PickerMode = .byType

    private var title: String { targetGroupID != nil ? "Add to Chart" : "Add Signal" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(PickerMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                List {
                    if mode == .byType {
                        byTypeSections
                    } else {
                        neuronsSection
                        synapsesSection
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $search, prompt: "Search parameters…")
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    // MARK: - By-type sections

    @ViewBuilder
    private var byTypeSections: some View {
        tensionsSection
        currentSection
        gatingSection
        metabolicSection
        synapsesTypeSection
    }

    // ⚡ Tensions — all V(t)
    private var tensionsSection: some View {
        Section("⚡ Tensions") {
            ForEach(vm.network.neurons, id: \.id) { neuron in
                ForEach(neuron.compartments, id: \.id) { comp in
                    let hasMultiComp = neuron.compartments.count > 1
                    let vSignal = TracedSignal.voltage(neuronID: neuron.id, compartmentID: comp.id)
                    let vLabel = hasMultiComp
                        ? "\(neuron.name) · \(comp.name)  V(t)  [mV]"
                        : "\(neuron.name)  V(t)  [mV]"
                    if matches(vLabel) {
                        SignalRow(label: vLabel, icon: "waveform", color: .blue,
                                  signal: vSignal, groupID: targetGroupID, isPresented: $isPresented)
                    }
                }
            }
        }
    }

    // ➡ Courants — channel I(t), I_inj, I_syn
    @ViewBuilder
    private var currentSection: some View {
        Section("➡ Courants") {
            // Channel currents
            ForEach(vm.network.neurons, id: \.id) { neuron in
                ForEach(neuron.compartments, id: \.id) { comp in
                    let hasMultiComp = neuron.compartments.count > 1
                    let compLabel = hasMultiComp ? comp.name : ""
                    ForEach(Array(comp.channels.enumerated()), id: \.offset) { chIdx, ch in
                        let prefix = compLabel.isEmpty
                            ? "\(neuron.name) · \(ch.name)"
                            : "\(neuron.name) · \(compLabel) · \(ch.name)"
                        let iSignal = TracedSignal.channelCurrent(neuronID: neuron.id,
                                                                   compartmentID: comp.id,
                                                                   channelIndex: chIdx)
                        let iLabel = "\(prefix)  I(t)  [µA/cm²]"
                        if matches(iLabel) {
                            SignalRow(label: iLabel, icon: "arrow.left.and.right", color: .green,
                                      signal: iSignal, groupID: targetGroupID, isPresented: $isPresented)
                        }
                    }
                    // Stimulus current
                    if vm.network.stimuli[comp.id] != nil {
                        let stimSignal = TracedSignal.stimulusCurrent(compartmentID: comp.id)
                        let stimLabel = hasMultiComp
                            ? "\(neuron.name) · \(comp.name)  I_inj(t)  [µA/cm²]"
                            : "\(neuron.name)  I_inj(t)  [µA/cm²]"
                        if matches(stimLabel) {
                            SignalRow(label: stimLabel, icon: "bolt", color: .orange,
                                      signal: stimSignal, groupID: targetGroupID, isPresented: $isPresented)
                        }
                    }
                }
            }
            // Synaptic currents
            ForEach(vm.network.synapses, id: \.id) { syn in
                let preName  = vm.network.neurons.first { $0.id == syn.preNeuronID }?.name  ?? "?"
                let postName = vm.network.neurons.first { $0.id == syn.postNeuronID }?.name ?? "?"
                let isGap    = syn is GapJunction
                let arrow    = isGap ? "↔" : "→"
                let iSynSignal = TracedSignal.synapticCurrent(synapseID: syn.id)
                let iSynLabel  = "\(preName)\(arrow)\(postName)  I_syn(t)  [µA/cm²]"
                if matches(iSynLabel) {
                    SignalRow(label: iSynLabel, icon: "arrow.left.and.right", color: .pink,
                              signal: iSynSignal, groupID: targetGroupID, isPresented: $isPresented)
                }
            }
        }
    }

    // 🎚 Gating — all gate variables
    @ViewBuilder
    private var gatingSection: some View {
        Section("🎚 Gating") {
            ForEach(vm.network.neurons, id: \.id) { neuron in
                ForEach(neuron.compartments, id: \.id) { comp in
                    let hasMultiComp = neuron.compartments.count > 1
                    let compLabel = hasMultiComp ? comp.name : ""
                    ForEach(Array(comp.channels.enumerated()), id: \.offset) { chIdx, ch in
                        if let gated = ch as? HHGated {
                            let prefix = compLabel.isEmpty
                                ? "\(neuron.name) · \(ch.name)"
                                : "\(neuron.name) · \(compLabel) · \(ch.name)"
                            ForEach(Array(gated.gateNames.enumerated()), id: \.offset) { gIdx, gName in
                                let gSignal = TracedSignal.gate(neuronID: neuron.id,
                                                                compartmentID: comp.id,
                                                                channelIndex: chIdx,
                                                                gateIndex: gIdx)
                                let gLabel = "\(prefix)  \(gName)(t)"
                                if matches(gLabel) {
                                    SignalRow(label: gLabel, icon: "slider.horizontal.3", color: .purple,
                                              signal: gSignal, groupID: targetGroupID, isPresented: $isPresented)
                                }
                            }
                        }
                    }
                }
            }
            // Synaptic gating s(t)
            ForEach(vm.network.synapses, id: \.id) { syn in
                guard !(syn is GapJunction) else { return }
                let preName  = vm.network.neurons.first { $0.id == syn.preNeuronID }?.name  ?? "?"
                let postName = vm.network.neurons.first { $0.id == syn.postNeuronID }?.name ?? "?"
                let sSignal = TracedSignal.synapticGating(synapseID: syn.id)
                let sLabel  = "\(preName)→\(postName)  s(t)"
                if matches(sLabel) {
                    SignalRow(label: sLabel,
                              icon: "point.topleft.down.to.point.bottomright.curvepath",
                              color: .teal,
                              signal: sSignal, groupID: targetGroupID, isPresented: $isPresented)
                }
            }
        }
    }

    // ⚗ Métabolique — ion concentrations
    @ViewBuilder
    private var metabolicSection: some View {
        let allConc: [(label: String, signal: TracedSignal)] = vm.network.neurons.flatMap { neuron in
            neuron.compartments.flatMap { comp -> [(label: String, signal: TracedSignal)] in
                let hasMultiComp = neuron.compartments.count > 1
                return comp.concentrationDynamics.map { dyn in
                    let concSignal = TracedSignal.ionConcentration(neuronID: neuron.id,
                                                                    compartmentID: comp.id,
                                                                    ionSymbol: dyn.ionSymbol)
                    let concLabel = hasMultiComp
                        ? "\(neuron.name) · \(comp.name)  [\(dyn.ionSymbol)]_in(t)  [mM]"
                        : "\(neuron.name)  [\(dyn.ionSymbol)]_in(t)  [mM]"
                    return (label: concLabel, signal: concSignal)
                }
            }
        }

        if !allConc.isEmpty {
            Section("⚗ Métabolique") {
                ForEach(Array(allConc.enumerated()), id: \.offset) { _, item in
                    if matches(item.label) {
                        SignalRow(label: item.label, icon: "atom", color: .cyan,
                                  signal: item.signal, groupID: targetGroupID, isPresented: $isPresented)
                    }
                }
            }
        }
    }

    // 🔗 Synapses — s(t) + I_syn grouped together
    @ViewBuilder
    private var synapsesTypeSection: some View {
        if !vm.network.synapses.isEmpty {
            Section("🔗 Synapses") {
                ForEach(vm.network.synapses, id: \.id) { syn in
                    synapseRows(syn: syn)
                }
            }
        }
    }

    // MARK: - "Par neurone" sections (original tree)

    private var neuronsSection: some View {
        Section("Neurons") {
            ForEach(vm.network.neurons, id: \.id) { neuron in
                DisclosureGroup(neuron.name) {
                    ForEach(neuron.compartments, id: \.id) { comp in
                        compartmentRows(neuron: neuron, comp: comp)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compartmentRows(neuron: HHNeuron, comp: Compartment) -> some View {
        let hasMultiComp = neuron.compartments.count > 1
        let compLabel = hasMultiComp ? comp.name : ""

        let vSignal = TracedSignal.voltage(neuronID: neuron.id, compartmentID: comp.id)
        let vLabel = hasMultiComp
            ? "\(neuron.name) · \(comp.name)  V(t)  [mV]"
            : "\(neuron.name)  V(t)  [mV]"
        if matches(vLabel) {
            SignalRow(label: vLabel, icon: "waveform", color: .blue,
                      signal: vSignal, groupID: targetGroupID, isPresented: $isPresented)
        }

        ForEach(Array(comp.channels.enumerated()), id: \.offset) { chIdx, ch in
            channelRows(neuron: neuron, comp: comp,
                        compLabel: compLabel, chIdx: chIdx, ch: ch)
        }

        if vm.network.stimuli[comp.id] != nil {
            let stimSignal = TracedSignal.stimulusCurrent(compartmentID: comp.id)
            let stimLabel = hasMultiComp
                ? "\(neuron.name) · \(comp.name)  I_inj(t)  [µA/cm²]"
                : "\(neuron.name)  I_inj(t)  [µA/cm²]"
            if matches(stimLabel) {
                SignalRow(label: stimLabel, icon: "bolt", color: .orange,
                          signal: stimSignal, groupID: targetGroupID, isPresented: $isPresented)
            }
        }

        ForEach(comp.concentrationDynamics, id: \.ionSymbol) { dyn in
            let concSignal = TracedSignal.ionConcentration(neuronID: neuron.id,
                                                           compartmentID: comp.id,
                                                           ionSymbol: dyn.ionSymbol)
            let concLabel = hasMultiComp
                ? "\(neuron.name) · \(comp.name)  [\(dyn.ionSymbol)]_in(t)  [mM]"
                : "\(neuron.name)  [\(dyn.ionSymbol)]_in(t)  [mM]"
            if matches(concLabel) {
                SignalRow(label: concLabel, icon: "atom", color: .cyan,
                          signal: concSignal, groupID: targetGroupID, isPresented: $isPresented)
            }
        }
    }

    @ViewBuilder
    private func channelRows(neuron: HHNeuron, comp: Compartment,
                              compLabel: String, chIdx: Int, ch: IonChannel) -> some View {
        let prefix = compLabel.isEmpty
            ? "\(neuron.name) · \(ch.name)"
            : "\(neuron.name) · \(compLabel) · \(ch.name)"

        if let gated = ch as? HHGated {
            ForEach(Array(gated.gateNames.enumerated()), id: \.offset) { gIdx, gName in
                let gSignal = TracedSignal.gate(neuronID: neuron.id,
                                                compartmentID: comp.id,
                                                channelIndex: chIdx,
                                                gateIndex: gIdx)
                let gLabel = "\(prefix)  \(gName)(t)"
                if matches(gLabel) {
                    SignalRow(label: gLabel, icon: "slider.horizontal.3", color: .purple,
                              signal: gSignal, groupID: targetGroupID, isPresented: $isPresented)
                }
            }
        }

        let iSignal = TracedSignal.channelCurrent(neuronID: neuron.id,
                                                  compartmentID: comp.id,
                                                  channelIndex: chIdx)
        let iLabel = "\(prefix)  I(t)  [µA/cm²]"
        if matches(iLabel) {
            SignalRow(label: iLabel, icon: "arrow.left.and.right", color: .green,
                      signal: iSignal, groupID: targetGroupID, isPresented: $isPresented)
        }
    }

    // MARK: - Synapses section (used by both modes)

    @ViewBuilder
    private var synapsesSection: some View {
        if !vm.network.synapses.isEmpty {
            Section("Synapses") {
                ForEach(vm.network.synapses, id: \.id) { syn in
                    synapseRows(syn: syn)
                }
            }
        }
    }

    @ViewBuilder
    private func synapseRows(syn: Synapse) -> some View {
        let preName  = vm.network.neurons.first { $0.id == syn.preNeuronID }?.name  ?? "?"
        let postName = vm.network.neurons.first { $0.id == syn.postNeuronID }?.name ?? "?"
        let isGap    = syn is GapJunction
        let arrow    = isGap ? "↔" : "→"
        let prefix   = "\(preName)\(arrow)\(postName)"

        if !isGap {
            let sSignal = TracedSignal.synapticGating(synapseID: syn.id)
            let sLabel  = "\(prefix)  s(t)"
            if matches(sLabel) {
                SignalRow(label: sLabel,
                          icon: "point.topleft.down.to.point.bottomright.curvepath",
                          color: .teal,
                          signal: sSignal, groupID: targetGroupID, isPresented: $isPresented)
            }
        }

        let iSynSignal = TracedSignal.synapticCurrent(synapseID: syn.id)
        let iSynLabel  = "\(prefix)  I_syn(t)  [µA/cm²]"
        if matches(iSynLabel) {
            SignalRow(label: iSynLabel, icon: "arrow.left.and.right", color: .pink,
                      signal: iSynSignal, groupID: targetGroupID, isPresented: $isPresented)
        }
    }

    // MARK: - Search filter

    private func matches(_ label: String) -> Bool {
        search.isEmpty || label.localizedCaseInsensitiveContains(search)
    }
}

// MARK: - Single selectable row

private struct SignalRow: View {
    @EnvironmentObject var vm: SimulationViewModel
    let label: String
    let icon: String
    let color: Color
    let signal: TracedSignal
    var groupID: UUID?           // nil → new chart; non-nil → overlay on that chart
    @Binding var isPresented: Bool

    private var alreadyAdded: Bool {
        vm.signalTraces.contains { $0.signal == signal }
    }

    var body: some View {
        Button {
            if !alreadyAdded {
                vm.addSignalTrace(signal, toGroup: groupID)
            }
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                if alreadyAdded {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
