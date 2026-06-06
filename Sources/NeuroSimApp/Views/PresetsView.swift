//
//  PresetsView.swift
//  NeuroSimApp
//
//  Global preset library panel — presets survive across sessions and documents.
//  Displayed as a sheet from the main toolbar ("Presets" button).
//
//  Layout
//  ──────
//   ┌─── Presets globaux ──────────────────────────────────┐
//   │  [Nom du preset___________________]  [Sauver ★]      │
//   ├──────────────────────────────────────────────────────┤
//   │  ★ Mon modèle PD parfait  23 mai 12:34  [Restaurer] [×] │
//   │  ★ HH standard calibré    22 mai 09:10  [Restaurer] [×] │
//   │  …                                                   │
//   └──────────────────────────────────────────────────────┘
//

import SwiftUI
import NeuroSimCore

struct PresetsView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = PresetLibrary.shared

    @State private var newName: String = ""
    @State private var restoreTarget: NetworkDocument.ModelSnapshot? = nil
    @State private var editingID: UUID? = nil
    @State private var editingName: String = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                Text("Presets globaux")
                    .font(.headline)
                Spacer()
                Button("Fermer") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // ── Create new preset from current model ──────────────
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                TextField("Nom du preset…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { trySave() }
                Button { trySave() } label: {
                    Label("Sauver", systemImage: "star")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                          vm.network.neurons.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.05))

            Divider()

            // ── Preset list ───────────────────────────────────────
            if library.presets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Aucun preset")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Entrez un nom et cliquez « Sauver » pour conserver\n" +
                         "le modèle actuel entre les sessions.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(library.presets) { preset in
                            presetRow(preset)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 320)
        .confirmationDialog(
            "Restaurer « \(restoreTarget?.name ?? "") » ?",
            isPresented: Binding(get: { restoreTarget != nil },
                                 set: { if !$0 { restoreTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restaurer les paramètres", role: .destructive) {
                if let p = restoreTarget { library.restore(p, to: vm) }
                restoreTarget = nil
                dismiss()
            }
            Button("Annuler", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("Les paramètres actuels seront remplacés par ceux du preset. " +
                 "L'état de simulation en cours sera perdu.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func presetRow(_ preset: NetworkDocument.ModelSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .foregroundStyle(.orange)
                .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                if editingID == preset.id {
                    TextField("Nom", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .frame(maxWidth: 260)
                        .onSubmit { commitRename(preset) }
                } else {
                    Text(preset.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editingID   = preset.id
                            editingName = preset.name
                        }
                }
                HStack(spacing: 4) {
                    Text(Self.timeFormatter.string(from: preset.date))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text("·").font(.caption2).foregroundStyle(.quaternary)
                    let n = preset.network.neurons.count
                    let s = preset.network.synapses.count
                    Text("\(n) neurone\(n == 1 ? "" : "s"), \(s) synapse\(s == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if editingID == preset.id {
                Button("OK") { commitRename(preset) }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Annuler") { editingID = nil }
                    .buttonStyle(.borderless).controlSize(.small)
                    .foregroundStyle(.secondary)
            } else {
                Button { restoreTarget = preset } label: {
                    Label("Restaurer", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help("Charger ce preset dans le modèle actuel")

                Button(role: .destructive) { library.delete(id: preset.id) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.quaternary)
                }
                .buttonStyle(.borderless)
                .help("Supprimer ce preset")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func trySave() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        library.save(name: name, from: vm)
        newName = ""
    }

    private func commitRename(_ preset: NetworkDocument.ModelSnapshot) {
        let name = editingName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { library.rename(id: preset.id, newName: name) }
        editingID = nil
    }
}
