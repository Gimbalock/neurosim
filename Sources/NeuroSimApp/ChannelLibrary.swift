//
//  ChannelLibrary.swift
//  NeuroSimApp
//
//  Persistent, in-memory registry of user-defined ion channels.
//  Saved as JSON in ~/Library/Application Support/NeuroSim/channelLibrary.json.
//  Access via the singleton `ChannelLibrary.shared`.
//

import Foundation
import Combine
import NeuroSimCore

final class ChannelLibrary: ObservableObject {

    static let shared = ChannelLibrary()

    @Published var channels: [CustomChannelDefinition] = []

    private let fileURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("NeuroSim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir.appendingPathComponent("channelLibrary.json")
    }()

    private init() { load() }

    // MARK: - CRUD

    func upsert(_ def: CustomChannelDefinition) {
        if let i = channels.firstIndex(where: { $0.id == def.id }) {
            channels[i] = def
        } else {
            channels.append(def)
        }
        persist()
    }

    func delete(_ def: CustomChannelDefinition) {
        channels.removeAll { $0.id == def.id }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder()
                .decode([CustomChannelDefinition].self, from: data)
        else { return }
        channels = decoded
    }
}
