// ChannelLibraryView.swift
// NeuroSimApp

import SwiftUI
import Charts
import UniformTypeIdentifiers
import NeuroSimCore

// kGateColors and GateEditorRow are defined in ChannelEditorSheet.swift

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
            ChannelEditorSheet(draft: draft,
                               context: .library(draft: draft) { library.upsert($0) })
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
            .ifCondition(yRange != nil) { $0.chartYScale(domain: yRange!) }
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

// MARK: - Identifiable conformance (pour .sheet(item:))

extension MODImportedChannelDefinition: Identifiable {}

