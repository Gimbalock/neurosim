//
//  NetworkBuilderSheet.swift
//  NeuroSimApp
//
//  Sheet containing three tabs for bulk network-building operations:
//   • Dupliquer  — deep-copy a neuron N times with chosen arrangement
//   • Connexions — random chemical synapse wiring between neuron groups
//   • Topologie  — build a layered network from scratch
//

import SwiftUI
import NeuroSimCore

// MARK: - NetworkBuilderSheet

struct NetworkBuilderSheet: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Binding var isPresented: Bool
    @State var selectedTab: Int

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with close button
            HStack {
                Text("Constructeur de réseau")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            TabView(selection: $selectedTab) {
                DuplicateTab()
                    .environmentObject(vm)
                    .tabItem { Label("Dupliquer", systemImage: "doc.on.doc") }
                    .tag(0)
                ConnectTab()
                    .environmentObject(vm)
                    .tabItem { Label("Connexions", systemImage: "arrow.triangle.branch") }
                    .tag(1)
                TopologyTab(isPresented: $isPresented)
                    .environmentObject(vm)
                    .tabItem { Label("Topologie", systemImage: "square.3.layers.3d") }
                    .tag(2)
            }
            .padding()
        }
        .frame(width: 480, height: 540)
    }
}

// MARK: - DuplicateTab

private struct DuplicateTab: View {
    @EnvironmentObject var vm: SimulationViewModel
    @State private var templateID: UUID? = nil
    @State private var count: Int = 5
    @State private var arrangement: NeuronArrangement = .grid
    @State private var spacing: Double = 80

    var body: some View {
        ScrollView {
            Form {
                Section("Neurone template") {
                    if vm.network.neurons.isEmpty {
                        Text("Aucun neurone dans le réseau.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Template", selection: $templateID) {
                            Text("— Choisir —").tag(Optional<UUID>(nil))
                            ForEach(vm.network.neurons, id: \.id) { n in
                                Text(n.name).tag(Optional(n.id))
                            }
                        }
                        .onAppear {
                            if templateID == nil {
                                templateID = vm.network.neurons.first?.id
                            }
                        }
                    }
                }

                Section("Paramètres") {
                    Stepper("Nombre de copies : \(count)", value: $count, in: 2...50)

                    Picker("Disposition", selection: $arrangement) {
                        ForEach(NeuronArrangement.allCases) { arr in
                            Label(arr.rawValue, systemImage: arr.systemImage).tag(arr)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading) {
                        Text("Espacement : \(Int(spacing)) pt")
                            .font(.caption)
                        Slider(value: $spacing, in: 40...200, step: 5)
                    }
                }

                Button(action: performDuplicate) {
                    Label("Créer les neurones", systemImage: "doc.on.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(templateID == nil)
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    private func performDuplicate() {
        guard let tid = templateID,
              let template = vm.network.neurons.first(where: { $0.id == tid }) else { return }
        // Offset index by existing neuron count so names don't collide
        let offset = vm.network.neurons.count
        let copies = NetworkAutomation.duplicate(
            neuron: template, count: count, arrangement: arrangement,
            spacing: spacing, originX: template.positionX, originY: template.positionY + spacing,
            indexOffset: offset)
        for n in copies { vm.network.addNeuron(n) }
        vm.objectWillChange.send()
        vm.rebuildSimulatorPublic()
    }
}

// MARK: - ConnectTab

private enum GroupMode: String, CaseIterable {
    case all      = "Tous les neurones"
    case filtered = "Filtrer par nom"
}

private struct ConnectTab: View {
    @EnvironmentObject var vm: SimulationViewModel
    @State private var sourceMode: GroupMode = .all
    @State private var targetMode: GroupMode = .all
    @State private var sourceFilter: String = ""
    @State private var targetFilter: String = ""
    @State private var params = ConnectParams()
    @State private var seed: String = "42"

    private var sourceNeurons: [HHNeuron] {
        filteredNeurons(mode: sourceMode, filter: sourceFilter)
    }
    private var targetNeurons: [HHNeuron] {
        filteredNeurons(mode: targetMode, filter: targetFilter)
    }
    private var possiblePairs: Int {
        var count = sourceNeurons.count * targetNeurons.count
        if !params.allowSelf {
            // Subtract pairs where src == tgt (same UUID)
            let shared = Set(sourceNeurons.map(\.id)).intersection(Set(targetNeurons.map(\.id)))
            count -= shared.count
        }
        return max(0, count)
    }
    private var expectedConnections: Int {
        Int(Double(possiblePairs) * params.probability)
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Source") {
                    Picker("Source", selection: $sourceMode) {
                        ForEach(GroupMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    if sourceMode == .filtered {
                        TextField("Préfixe…", text: $sourceFilter)
                    }
                }

                Section("Cible") {
                    Picker("Cible", selection: $targetMode) {
                        ForEach(GroupMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    if targetMode == .filtered {
                        TextField("Préfixe…", text: $targetFilter)
                    }
                }

                Section("Paramètres") {
                    VStack(alignment: .leading) {
                        Text("Probabilité : \(Int(params.probability * 100))%")
                            .font(.caption)
                        Slider(value: $params.probability, in: 0...1, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("Ratio E/I : \(Int(params.eiRatio * 100))% excitatrice / \(Int((1 - params.eiRatio) * 100))% inhibitrice")
                            .font(.caption)
                        Slider(value: $params.eiRatio, in: 0...1, step: 0.01)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Excitatrice").font(.caption).foregroundStyle(.secondary)
                            LabeledContent("gMax") {
                                TextField("", value: $params.exGMax, format: .number)
                                    .frame(width: 60)
                            }
                            LabeledContent("τ (ms)") {
                                TextField("", value: $params.exTauDecay, format: .number)
                                    .frame(width: 60)
                            }
                            LabeledContent("E_rev") {
                                TextField("", value: $params.exReversal, format: .number)
                                    .frame(width: 60)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Inhibitrice").font(.caption).foregroundStyle(.secondary)
                            LabeledContent("gMax") {
                                TextField("", value: $params.inhGMax, format: .number)
                                    .frame(width: 60)
                            }
                            LabeledContent("τ (ms)") {
                                TextField("", value: $params.inhTauDecay, format: .number)
                                    .frame(width: 60)
                            }
                            LabeledContent("E_rev") {
                                TextField("", value: $params.inhReversal, format: .number)
                                    .frame(width: 60)
                            }
                        }
                    }

                    Toggle("Autoriser auto-connexions", isOn: $params.allowSelf)

                    TextField("Graine aléatoire", text: $seed)
                }

                Text("→ \(possiblePairs) paires possibles, ~\(expectedConnections) connexions attendues")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: performConnect) {
                    Label("Connecter", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.network.neurons.isEmpty)
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    private func filteredNeurons(mode: GroupMode, filter: String) -> [HHNeuron] {
        let all = vm.network.neurons
        switch mode {
        case .all: return all
        case .filtered: return filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
    }

    private func performConnect() {
        let sources = filteredNeurons(mode: sourceMode, filter: sourceFilter)
        let targets = filteredNeurons(mode: targetMode, filter: targetFilter)
        let s = UInt64(seed) ?? 42
        let syns = NetworkAutomation.randomConnect(sources: sources, targets: targets,
                                                   params: params, seed: s)
        for syn in syns { vm.network.addSynapse(syn) }
        vm.objectWillChange.send()
        vm.rebuildSimulatorPublic()
    }
}

// MARK: - TopologyTab

private enum TopologyMode: String, CaseIterable {
    case feedforward  = "Feedforward"
    case feedback     = "Feedback"
    case both         = "Bidirectionnel"
}

private struct TopologyTab: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Binding var isPresented: Bool
    @State private var layerCount: Int = 3
    @State private var neuronsPerLayer: Int = 5
    @State private var templateID: UUID? = nil
    @State private var connectMode: TopologyMode = .feedforward
    @State private var params = ConnectParams()
    @State private var spacing: Double = 120
    @State private var showConfirmation = false

    var body: some View {
        ScrollView {
            Form {
                Section("Template neurone") {
                    if vm.network.neurons.isEmpty {
                        Text("Aucun neurone dans le réseau.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Template", selection: $templateID) {
                            Text("— Choisir —").tag(Optional<UUID>(nil))
                            ForEach(vm.network.neurons, id: \.id) { n in
                                Text(n.name).tag(Optional(n.id))
                            }
                        }
                        .onAppear {
                            if templateID == nil {
                                templateID = vm.network.neurons.first?.id
                            }
                        }
                    }
                }

                Section("Architecture") {
                    Stepper("Couches : \(layerCount)", value: $layerCount, in: 2...8)
                    Stepper("Neurones / couche : \(neuronsPerLayer)", value: $neuronsPerLayer, in: 1...20)

                    VStack(alignment: .leading) {
                        Text("Espacement : \(Int(spacing)) pt")
                            .font(.caption)
                        Slider(value: $spacing, in: 40...300, step: 10)
                    }

                    Picker("Mode connexion", selection: $connectMode) {
                        ForEach(TopologyMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                }

                Section("Connectivité") {
                    VStack(alignment: .leading) {
                        Text("Probabilité : \(Int(params.probability * 100))%")
                            .font(.caption)
                        Slider(value: $params.probability, in: 0...1, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("Ratio E/I : \(Int(params.eiRatio * 100))% excitatrice / \(Int((1 - params.eiRatio) * 100))% inhibitrice")
                            .font(.caption)
                        Slider(value: $params.eiRatio, in: 0...1, step: 0.01)
                    }
                    HStack(spacing: 16) {
                        LabeledContent("gMax Exc.") {
                            TextField("", value: $params.exGMax, format: .number)
                                .frame(width: 60)
                        }
                        LabeledContent("gMax Inh.") {
                            TextField("", value: $params.inhGMax, format: .number)
                                .frame(width: 60)
                        }
                    }
                }

                Text("→ \(layerCount) couches × \(neuronsPerLayer) neurones = \(layerCount * neuronsPerLayer) neurones")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: { showConfirmation = true }) {
                    Label("Construire le réseau", systemImage: "square.3.layers.3d")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(templateID == nil)
                .confirmationDialog(
                    "Remplacer le réseau actuel ?",
                    isPresented: $showConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Construire", role: .destructive) { performBuild() }
                    Button("Annuler", role: .cancel) { }
                } message: {
                    Text("Le réseau actuel sera remplacé par le nouveau réseau en couches. Cette action est irréversible.")
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    private func performBuild() {
        guard let tid = templateID,
              let template = vm.network.neurons.first(where: { $0.id == tid }) else { return }

        var layers: [[HHNeuron]] = []
        for l in 0..<layerCount {
            var layer: [HHNeuron] = []
            for n in 0..<neuronsPerLayer {
                let originX = Double(l) * (spacing * 1.5)
                let originY = Double(n) * spacing
                // Name: "L<layer>N<neuron>" — unique and readable
                let neuronName = "L\(l + 1)N\(n + 1)"
                let copies = NetworkAutomation.duplicate(neuron: template, count: 1,
                                                         arrangement: .line, spacing: spacing,
                                                         originX: originX, originY: originY,
                                                         nameOverride: neuronName)
                layer.append(contentsOf: copies)
            }
            layers.append(layer)
        }

        let net = Network()
        for layer in layers { for n in layer { net.addNeuron(n) } }

        var syns: [ChemicalSynapse] = []
        switch connectMode {
        case .feedforward:
            syns = NetworkAutomation.feedforwardConnect(layers: layers, params: params)
        case .feedback:
            syns = NetworkAutomation.feedbackConnect(layers: layers, params: params)
        case .both:
            syns += NetworkAutomation.feedforwardConnect(layers: layers, params: params, seed: 42)
            syns += NetworkAutomation.feedbackConnect(layers: layers, params: params, seed: 123)
        }
        for s in syns { net.addSynapse(s) }

        vm.replaceNetwork(net)
        isPresented = false
    }
}

// MARK: - Preview

#Preview {
    NetworkBuilderSheet(isPresented: .constant(true), selectedTab: 0)
        .environmentObject(SimulationViewModel.demoNetwork())
}
