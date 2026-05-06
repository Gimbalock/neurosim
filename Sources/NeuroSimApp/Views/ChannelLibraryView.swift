// ChannelLibraryView.swift
// NeuroSimApp

import SwiftUI
import Charts
import UniformTypeIdentifiers
import NeuroSimCore

// MARK: - Shared

private let kGateColors: [Color] = [.blue, .orange, .green, .red, .purple]

private struct PreviewItem: Identifiable {
    let id  = UUID()
    let channel: IonChannel
    let name: String
}

// MARK: - ChannelLibrarySheet

struct ChannelLibrarySheet: View {
    @EnvironmentObject var vm: SimulationViewModel
    @ObservedObject private var library = ChannelLibrary.shared
    @Environment(\.dismiss) private var dismiss

    let compartmentID: UUID
    let neuronID: UUID

    @State private var editorDraft:  CustomChannelDefinition?      = nil
    @State private var editingMOD:   MODImportedChannelDefinition? = nil
    @State private var previewItem:  PreviewItem?                  = nil
    @State private var showImporter  = false
    @State private var importError:  String?                       = nil
    @State private var showError     = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── En-tête ─────────────────────────────────────────
            HStack {
                Text("Bibliothèque de canaux").font(.title3.bold())
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(.borderless)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    integresSection
                    bibliothequeSection
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 560)
        .sheet(item: $previewItem) { item in
            ChannelKineticsSheet(channel: item.channel, channelName: item.name)
        }
        .sheet(item: $editorDraft) { draft in
            CustomChannelEditorView(draft: draft) { library.upsert($0) }
        }
        .sheet(item: $editingMOD) { def in
            MODChannelEditSheet(definition: def) { library.upsert(.modImported($0)) }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "mod") ?? .data],
                      allowsMultipleSelection: false,
                      onCompletion: handleImport)
        .alert("Erreur d'importation", isPresented: $showError, presenting: importError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    // MARK: Sections

    private var integresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Canaux intégrés")
            ForEach(ChannelKind.allCases) { kind in
                let ch = kind.makeInstance()
                HStack(spacing: 8) {
                    Label(kind.rawValue, systemImage: kind.systemImage).font(.callout)
                    Spacer()
                    iconButton("chart.line.uptrend.xyaxis", help: "Aperçu cinétique") {
                        previewItem = PreviewItem(channel: ch, name: kind.rawValue)
                    }
                    Button("Ajouter") {
                        vm.addChannel(kind, toCompartment: compartmentID, in: neuronID)
                        dismiss()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var bibliothequeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Ma bibliothèque")
                Spacer()
                Button { showImporter = true } label: {
                    Label("Importer .mod…", systemImage: "square.and.arrow.down").font(.callout)
                }
                .buttonStyle(.borderless).help("Importer depuis un fichier NEURON .mod")
                Button { editorDraft = CustomChannelDefinition() } label: {
                    Label("Nouveau…", systemImage: "plus.circle").font(.callout)
                }
                .buttonStyle(.borderless).help("Créer un canal personnalisé")
            }

            if library.entries.isEmpty {
                Text("Bibliothèque vide — importez un fichier .mod ou créez un canal personnalisé.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            } else {
                ForEach(library.entries) { entry in entryRow(entry) }
            }
        }
    }

    // MARK: Entry row

    @ViewBuilder
    private func entryRow(_ entry: LibraryEntry) -> some View {
        let ch = try? entry.makeChannel()
        HStack(spacing: 8) {
            kindBadge(entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout.bold())
                Text(subtitle(entry)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()

            // Aperçu
            if let ch {
                iconButton("chart.line.uptrend.xyaxis", help: "Aperçu cinétique") {
                    previewItem = PreviewItem(channel: ch, name: entry.name)
                }
            }

            // Édition
            switch entry {
            case .custom(let def):
                iconButton("pencil", help: "Modifier") { editorDraft = def }
            case .modImported(let def):
                iconButton("slider.horizontal.3", help: "Modifier les paramètres") { editingMOD = def }
            }

            // Suppression
            Button(role: .destructive) { library.delete(entry) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Supprimer de la bibliothèque")

            Button("Ajouter") {
                guard let ch else { return }
                vm.addIonChannel(ch, toCompartment: compartmentID, in: neuronID)
                dismiss()
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(ch == nil)
        }
        .padding(8)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Helpers

    private func kindBadge(_ entry: LibraryEntry) -> some View {
        let isMOD = { if case .modImported = entry { return true }; return false }()
        return Text(entry.kindLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(isMOD ? Color.purple.opacity(0.15) : Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(isMOD ? .purple : .accentColor)
    }

    private func iconButton(_ sysImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: sysImage) }
            .buttonStyle(.borderless).help(help)
    }

    private func subtitle(_ entry: LibraryEntry) -> String {
        let g = entry.gateNames.isEmpty ? "passif" : entry.gateNames.joined(separator: ", ")
        return "\(entry.gateCount) gate\(entry.gateCount == 1 ? "" : "s")  (\(g))  ·  g_max \(String(format: "%.2f", entry.gMax)) mS/cm²"
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.subheadline.bold()).foregroundStyle(.secondary)
    }

    // MARK: Import .mod

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            importError = err.localizedDescription; showError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Accès refusé : \(url.lastPathComponent)"; showError = true; return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                for desc in try MODFileParser.parse(source) {
                    let def = MODImportedChannelDefinition(
                        channelName: desc.name, gMax: desc.gMax,
                        reversal: desc.reversal, ionSymbol: desc.ionSymbol,
                        gates: desc.gates.map { g in
                            MODImportedChannelDefinition.GateDef(
                                name: g.name, power: g.power,
                                alphaExpr: g.alphaExpr, betaExpr: g.betaExpr,
                                params: g.params)
                        }
                    )
                    library.upsert(.modImported(def))
                }
            } catch {
                importError = error.localizedDescription; showError = true
            }
        }
    }
}

// MARK: - ChannelKineticsSheet

struct ChannelKineticsSheet: View {
    let channel: IonChannel
    let channelName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channelName).font(.title3.bold())
                    Text("g_max \(String(format: "%.2f", channel.gMax)) mS/cm²  ·  E_rev \(String(format: "%.1f", channel.reversal)) mV")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(.borderless)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let gated = channel as? any HHGated, gated.stateCount > 0 {
                        KineticsCurveGroup(gated: gated)
                    } else {
                        Text("Canal passif (leak) — aucune variable de gate.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

// MARK: - KineticsCurveGroup

private struct KineticsCurveGroup: View {
    let gated: any HHGated

    private struct Pt: Identifiable {
        let id: String; let v, y: Double; let gate: String
    }

    var body: some View {
        let vs     = Array(stride(from: -100.0, through: 60.0, by: 0.5))
        let n      = gated.stateCount
        let names  = (0..<n).map { gated.gateNames[safe: $0] ?? "g\($0)" }
        let colors = (0..<n).map { kGateColors[$0 % kGateColors.count] }

        let infPts = (0..<n).flatMap { i in
            vs.map { v in Pt(id:"\(i)i\(v)", v: v,
                             y: gated.resolvedGateInf(i, voltage: v), gate: names[i]) }
        }
        let tauPts = (0..<n).flatMap { i in
            vs.map { v in Pt(id:"\(i)t\(v)", v: v,
                             y: gated.resolvedGateTau(i, voltage: v), gate: names[i]) }
        }

        VStack(alignment: .leading, spacing: 20) {
            kChart("x∞(V) — probabilité d'ouverture",
                   pts: infPts, domain: names, colors: colors,
                   yLabel: "Probabilité", yRange: 0...1)
            kChart("τ(V) — constante de temps",
                   pts: tauPts, domain: names, colors: colors,
                   yLabel: "τ (ms)", yRange: nil)
        }
    }

    private func kChart(_ title: String, pts: [Pt],
                         domain: [String], colors: [Color],
                         yLabel: String, yRange: ClosedRange<Double>?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            Chart(pts) { pt in
                LineMark(x: .value("V (mV)", pt.v), y: .value(yLabel, pt.y))
                    .foregroundStyle(by: .value("Gate", pt.gate))
                    .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(domain: domain, range: colors)
            .chartXAxisLabel("V (mV)").chartYAxisLabel(yLabel)
            .if(yRange != nil) { $0.chartYScale(domain: yRange!) }
            .frame(height: 180)
        }
    }
}

// MARK: - MODChannelEditSheet

struct MODChannelEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var def: MODImportedChannelDefinition
    var onSave: (MODImportedChannelDefinition) -> Void

    init(definition: MODImportedChannelDefinition,
         onSave: @escaping (MODImportedChannelDefinition) -> Void) {
        _def = State(initialValue: definition)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Modifier le canal MOD").font(.title3.bold())
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Button("Enregistrer") { onSave(def); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Nom").frame(width: 80, alignment: .leading)
                        TextField("Nom du canal", text: $def.channelName)
                    }
                    NumericSlider(label: "g_max", value: $def.gMax, range: 0...500,
                                  format: "%.2f", unit: "mS/cm²", labelWidth: 80)
                    NumericSlider(label: "E_rev", value: $def.reversal, range: -100...200,
                                  format: "%.1f", unit: "mV", labelWidth: 80)
                    Divider()
                    Text("Gates — cinétique issue du fichier .mod").font(.subheadline.bold())
                    ForEach(Array(def.gates.enumerated()), id: \.offset) { i, gate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(kGateColors[i % kGateColors.count]).frame(width: 8, height: 8)
                                Text("\(gate.name)  ×\(gate.power)").font(.callout.bold())
                            }
                            Text("α = \(gate.alphaExpr)")
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            Text("β = \(gate.betaExpr)")
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 500)
    }
}

// MARK: - CustomChannelEditorView

struct CustomChannelEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomChannelDefinition
    var onConfirm: (CustomChannelDefinition) -> Void

    @State private var expandedGate: UUID? = nil

    init(draft: CustomChannelDefinition, onConfirm: @escaping (CustomChannelDefinition) -> Void) {
        _draft = State(initialValue: draft)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "Nouveau canal" : draft.name).font(.title3.bold())
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Button("Enregistrer dans la bibliothèque") { onConfirm(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.isEmpty || draft.gates.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { formSection; gatesSection }
                        .padding(16)
                }
                .frame(width: 360)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { previewSection }.padding(16)
                }
            }
        }
        .frame(minWidth: 750, minHeight: 520)
    }

    // MARK: Formulaire

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canal").font(.headline)
            HStack {
                Text("Nom").frame(width: 80, alignment: .leading)
                TextField("ex. Kv4.2", text: $draft.name)
            }
            HStack {
                Text("Ion").frame(width: 80, alignment: .leading)
                Picker("", selection: $draft.ionSymbol) {
                    Text("Aucun / mixte").tag(Optional<String>.none)
                    Divider()
                    ForEach(IonSpecies.allCanonical, id: \.symbol) { sp in
                        Text("\(sp.symbol)\(sp.valence > 0 ? "+" : "")  (\(sp.valence > 0 ? "+" : "")\(sp.valence))")
                            .tag(Optional(sp.symbol))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .onChange(of: draft.ionSymbol) { _, sym in
                    if let sp = sym.flatMap(IonSpecies.canonical(symbol:)) { draft.reversal = sp.defaultReversal() }
                }
                if let sym = draft.ionSymbol, let sp = IonSpecies.canonical(symbol: sym) {
                    Text(ionLabel(sp)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            NumericSlider(label: "g_max", value: $draft.gMax, range: 0...200, format: "%.2f", unit: "mS/cm²", labelWidth: 80)
            NumericSlider(label: "E_rev", value: $draft.reversal, range: -100...140, format: "%.1f", unit: "mV", labelWidth: 80)
            if let sym = draft.ionSymbol, let sp = IonSpecies.canonical(symbol: sym) {
                Text("E_rev (Nernst) = \(String(format: "%.1f", sp.defaultReversal())) mV  ·  [in]=\(cLabel(sp.defaultConcentrationIn)) [out]=\(cLabel(sp.defaultConcentrationOut)) mM")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ionLabel(_ sp: IonSpecies) -> String {
        "[in]=\(cLabel(sp.defaultConcentrationIn)) mM  [out]=\(cLabel(sp.defaultConcentrationOut)) mM"
    }
    private func cLabel(_ c: Double) -> String { c < 0.01 ? String(format: "%.1e", c) : String(format: "%.1f", c) }

    // MARK: Gates

    private var gatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gates").font(.headline)
                Spacer()
                Button {
                    let g = GateDef(name: defaultGateName()); draft.gates.append(g); expandedGate = g.id
                } label: { Label("Ajouter", systemImage: "plus.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
            }
            if draft.gates.isEmpty {
                Text("Aucun gate — canal passif pur (leak).").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(draft.gates.indices, id: \.self) { i in
                GateEditorRow(gate: $draft.gates[i], color: kGateColors[i % kGateColors.count],
                               isExpanded: expandedGate == draft.gates[i].id,
                               onToggle: { let gid = draft.gates[i].id; expandedGate = expandedGate == gid ? nil : gid },
                               onDelete: { draft.gates.remove(at: i) })
            }
        }
    }

    private func defaultGateName() -> String {
        let used = Set(draft.gates.map(\.name))
        return ["m","h","n","p","q","r","s"].first { !used.contains($0) } ?? "x\(draft.gates.count)"
    }

    // MARK: Aperçu

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aperçu").font(.headline)
            if draft.gates.isEmpty {
                Text("Ajoutez au moins un gate pour voir les courbes.").font(.caption).foregroundStyle(.secondary)
            } else {
                previewChart("x∞(V)", yLabel: "Probabilité d'ouverture", yRange: 0...1) { g, v in
                    guard abs(g.slope) > 1e-12 else { return v < g.vHalf ? 0 : 1 }
                    return 1.0 / (1.0 + exp(-(v - g.vHalf) / g.slope))
                }
                previewChart("τ(V)", yLabel: "Constante de temps (ms)", yRange: nil) { g, v in
                    let s = max(g.tauWidth, 1e-6); let u = (v - g.vPeak) / s
                    return g.tauMin + (g.tauMax - g.tauMin) * exp(-0.5 * u * u)
                }
            }
        }
    }

    private func previewChart(_ title: String, yLabel: String, yRange: ClosedRange<Double>?,
                               valueFor: (GateDef, Double) -> Double) -> some View {
        struct Pt: Identifiable { let id: String; let v, y: Double; let gate: String }
        var pts: [Pt] = []
        for (i, gate) in draft.gates.enumerated() {
            let label = "\(gate.name) (×\(gate.power))"
            for v in stride(from: -100.0, through: 40.0, by: 1.0) {
                pts.append(Pt(id:"\(i)\(v)", v: v, y: valueFor(gate, v), gate: label))
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Chart(pts) { pt in
                LineMark(x: .value("V (mV)", pt.v), y: .value(yLabel, pt.y))
                    .foregroundStyle(by: .value("Gate", pt.gate)).interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(domain: draft.gates.enumerated().map { "\($1.name) (×\($1.power))" },
                                        range: draft.gates.indices.map { kGateColors[$0 % kGateColors.count] })
            .chartXAxisLabel("V (mV)").chartYAxisLabel(yLabel)
            .if(yRange != nil) { $0.chartYScale(domain: yRange!) }
            .frame(height: 160)
        }
    }
}

// MARK: - GateEditorRow

private struct GateEditorRow: View {
    @Binding var gate: GateDef
    let color: Color
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(gate.name.isEmpty ? "(sans nom)" : gate.name).font(.callout.bold())
                    Text("pow=\(gate.power)").font(.caption2).foregroundStyle(.secondary)
                    Text("V½=\(String(format: "%.0f", gate.vHalf))mV").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        HStack {
                            Text("Nom").font(.caption).frame(width: 40, alignment: .leading)
                            TextField("m", text: $gate.name).frame(width: 60)
                        }
                        HStack {
                            Text("Puissance").font(.caption).frame(width: 60, alignment: .leading)
                            Stepper("\(gate.power)", value: $gate.power, in: 1...8).fixedSize()
                        }
                    }
                    Text("Activation x∞(V)").font(.caption.bold()).foregroundStyle(.secondary)
                    NumericSlider(label: "V½",     value: $gate.vHalf,    range: -100...40,  format: "%.1f", unit: "mV", labelWidth: 60)
                    NumericSlider(label: "Pente",  value: $gate.slope,    range: -30...30,   step: 0.5, format: "%.1f", unit: "mV", labelWidth: 60)
                    Text("Constante de temps τ(V)").font(.caption.bold()).foregroundStyle(.secondary)
                    NumericSlider(label: "τ_min",  value: $gate.tauMin,   range: 0.01...50,  format: "%.2f", unit: "ms", labelWidth: 60)
                    NumericSlider(label: "τ_max",  value: $gate.tauMax,   range: 0.01...200, format: "%.2f", unit: "ms", labelWidth: 60)
                    NumericSlider(label: "V_pic",  value: $gate.vPeak,    range: -100...40,  format: "%.1f", unit: "mV", labelWidth: 60)
                    NumericSlider(label: "Largeur",value: $gate.tauWidth, range: 1...100,    format: "%.1f", unit: "mV", labelWidth: 60)
                }
                .padding(10)
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

// MARK: - Identifiable conformance (pour .sheet(item:))

extension MODImportedChannelDefinition: Identifiable {}

// MARK: - View helpers

extension View {
    @ViewBuilder
    fileprivate func `if`<C: View>(_ condition: Bool, transform: (Self) -> C) -> some View {
        if condition { transform(self) } else { self }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
