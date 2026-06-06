//
//  PresetLibrary.swift
//  NeuroSimApp
//
//  Global named preset store — persists across sessions and documents.
//
//  Presets reuse the existing `NetworkDocument.ModelSnapshot` type so
//  save / restore are identical to the per-document Freeze State mechanism.
//  Storage: ~/Library/Application Support/NeuroSim/presets.json
//
//  Usage
//  ─────
//  let lib = PresetLibrary.shared
//  lib.save(name: "My nice model", from: vm)
//  lib.restore(lib.presets[0], to: vm)
//

import Foundation
import SwiftUI
import NeuroSimCore

@MainActor
final class PresetLibrary: ObservableObject {

    // MARK: - Singleton

    static let shared = PresetLibrary()

    // MARK: - Published state

    @Published var presets: [NetworkDocument.ModelSnapshot] = []

    // MARK: - Storage path

    private static var storeURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuroSim", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true, attributes: nil)
        return support.appendingPathComponent("presets.json")
    }

    // MARK: - Init

    private init() { load() }

    // MARK: - Public API

    /// Capture the current network as a named global preset.
    func save(name: String, from vm: SimulationViewModel) {
        let doc  = NetworkDocument.from(vm.network)
        let snap = NetworkDocument.ModelSnapshot(name: name, network: doc)
        presets.insert(snap, at: 0)
        persist()
    }

    /// Capture a local snapshot as a global preset (one-click export from SnapshotsView).
    func saveSnapshot(_ snapshot: NetworkDocument.ModelSnapshot) {
        var copy = snapshot
        copy = NetworkDocument.ModelSnapshot(name: copy.name, network: copy.network)
        presets.insert(copy, at: 0)
        persist()
    }

    /// Restore a preset into the ViewModel (pauses simulation, rebuilds simulator).
    func restore(_ preset: NetworkDocument.ModelSnapshot, to vm: SimulationViewModel) {
        vm.restoreSnapshot(preset)
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, newName: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = newName
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        presets = (try? JSONDecoder().decode(
            [NetworkDocument.ModelSnapshot].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
