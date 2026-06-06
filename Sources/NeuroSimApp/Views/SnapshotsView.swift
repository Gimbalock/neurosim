//
//  SnapshotsView.swift
//  NeuroSimApp
//
//  Floating panel for managing parameter snapshots ("freeze states").
//
//  A snapshot captures the full network topology and channel parameters
//  (g_max, reversal potentials, gating curves, stimuli, etc.) at a given
//  moment so the user can revert to any earlier version. It is NOT the
//  simulation state vector — use the warm-start (⚡) feature for that.
//
//  Layout
//  ──────
//   ┌─── Freeze State ────────────────────────────────────┐
//   │  [Nom du snapshot_______________]  [Freeze ❄]       │
//   ├─────────────────────────────────────────────────────┤
//   │  ❄ Mon bon modèle    12:34  23 mai   [Restaurer] [×]│
//   │  ❄ Avant modif Na    11:10  23 mai   [Restaurer] [×]│
//   │  …                                                   │
//   └─────────────────────────────────────────────────────┘
//

import SwiftUI
import NeuroSimCore

struct SnapshotsView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newName: String = ""
    @State private var restoreTarget: NetworkDocument.ModelSnapshot? = nil
    @State private var editingID: UUID? = nil
    @State private var editingName: String = ""
    @State private var showPresets = false

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
                Image(systemName: "snowflake")
                    .foregroundStyle(.blue)
                Text("Freeze State — Instantanés paramètres")
                    .font(.headline)
                Spacer()
                Button {
                    showPresets = true
                } label: {
                    Label("Presets globaux", systemImage: "star.fill")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
                .help("Ouvrir la bibliothèque de presets globaux (persistants entre sessions)")
                .sheet(isPresented: $showPresets) {
                    PresetsView().environmentObject(vm)
                }
                Button("Fermer") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // ── Create new snapshot ───────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "snowflake")
                    .foregroundStyle(.blue)
                    .font(.caption)
                TextField("Nom du snapshot…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { tryFreeze() }
                Button {
                    tryFreeze()
                } label: {
                    Label("Freeze", systemImage: "snowflake")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.blue.opacity(0.05))

            Divider()

            // ── Snapshot list ─────────────────────────────────────
            if vm.snapshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Aucun instantané")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Saisissez un nom et cliquez Freeze pour capturer\nl'état actuel des paramètres du modèle.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.snapshots) { snap in
                            snapshotRow(snap)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .confirmationDialog(
            "Restaurer \"\(restoreTarget?.name ?? "")\" ?",
            isPresented: Binding(get: { restoreTarget != nil },
                                 set: { if !$0 { restoreTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restaurer les paramètres", role: .destructive) {
                if let snap = restoreTarget { vm.restoreSnapshot(snap) }
                restoreTarget = nil
                dismiss()
            }
            Button("Annuler", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("Les paramètres actuels seront remplacés par ceux de cet instantané. L'état de simulation en cours sera perdu.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func snapshotRow(_ snap: NetworkDocument.ModelSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "snowflake")
                .foregroundStyle(.blue)
                .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                if editingID == snap.id {
                    // Inline rename field
                    TextField("Nom", text: $editingName, onCommit: { commitRename(snap) })
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .frame(maxWidth: 240)
                        .onSubmit { commitRename(snap) }
                } else {
                    Text(snap.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editingID   = snap.id
                            editingName = snap.name
                        }
                }
                HStack(spacing: 4) {
                    Text(Self.timeFormatter.string(from: snap.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    let nCount = snap.network.neurons.count
                    let sCount = snap.network.synapses.count
                    Text("\(nCount) neurone\(nCount == 1 ? "" : "s"), \(sCount) synapse\(sCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if editingID == snap.id {
                Button("OK") { commitRename(snap) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Annuler") { editingID = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    restoreTarget = snap
                } label: {
                    Label("Restaurer", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .help("Restaurer les paramètres du modèle à partir de cet instantané")

                Button {
                    PresetLibrary.shared.saveSnapshot(snap)
                } label: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Exporter vers les presets globaux (persistants entre sessions)")

                Button(role: .destructive) {
                    vm.deleteSnapshot(id: snap.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.borderless)
                .help("Supprimer cet instantané")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func tryFreeze() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        vm.freezeState(name: name)
        newName = ""
    }

    private func commitRename(_ snap: NetworkDocument.ModelSnapshot) {
        let name = editingName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let i = vm.snapshots.firstIndex(where: { $0.id == snap.id }) {
            vm.snapshots[i].name = name
        }
        editingID = nil
    }
}
