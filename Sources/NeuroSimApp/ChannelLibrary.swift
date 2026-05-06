// ChannelLibrary.swift
// NeuroSimApp
//
// Persistent registry of user-defined ion channels (custom Boltzmann or .mod imported).
// Saved to ~/Library/Application Support/NeuroSim/channelLibrary.json.
// Singleton access via ChannelLibrary.shared.

import Foundation
import Combine
import NeuroSimCore

// MARK: - LibraryEntry

/// Unified entry that can represent either a custom (Boltzmann) or .mod-imported channel.
public enum LibraryEntry: Identifiable, Codable {
    case custom(CustomChannelDefinition)
    case modImported(MODImportedChannelDefinition)

    public var id: UUID {
        switch self {
        case .custom(let d):      return d.id
        case .modImported(let d): return d.id
        }
    }

    public var name: String {
        switch self {
        case .custom(let d):      return d.name
        case .modImported(let d): return d.channelName
        }
    }

    public var gMax: Double {
        switch self {
        case .custom(let d):      return d.gMax
        case .modImported(let d): return d.gMax
        }
    }

    public var gateCount: Int {
        switch self {
        case .custom(let d):      return d.gates.count
        case .modImported(let d): return d.gates.count
        }
    }

    public var gateNames: [String] {
        switch self {
        case .custom(let d):      return d.gates.map(\.name)
        case .modImported(let d): return d.gates.map(\.name)
        }
    }

    public var kindLabel: String {
        switch self {
        case .custom:      return "Custom"
        case .modImported: return "MOD"
        }
    }

    public func makeChannel() throws -> IonChannel {
        switch self {
        case .custom(let d):      return CustomChannel(definition: d)
        case .modImported(let d): return try MODImportedChannel(definition: d)
        }
    }

    // MARK: Codable (manual — enum with associated values)
    private enum CodingKeys: String, CodingKey { case kind, custom, mod }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .custom(let d):
            try c.encode("custom", forKey: .kind)
            try c.encode(d, forKey: .custom)
        case .modImported(let d):
            try c.encode("mod", forKey: .kind)
            try c.encode(d, forKey: .mod)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "custom":
            self = .custom(try c.decode(CustomChannelDefinition.self, forKey: .custom))
        case "mod":
            self = .modImported(try c.decode(MODImportedChannelDefinition.self, forKey: .mod))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "Unknown LibraryEntry kind: \(kind)")
        }
    }
}

// MARK: - ChannelLibrary

final class ChannelLibrary: ObservableObject {

    static let shared = ChannelLibrary()

    @Published var entries: [LibraryEntry] = []

    private let fileURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("NeuroSim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("channelLibrary.json")
    }()

    private init() { load() }

    // MARK: - CRUD

    func upsert(_ entry: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    func delete(_ entry: LibraryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    // Backward-compat helper for existing CustomChannel callers
    func upsert(_ def: CustomChannelDefinition) { upsert(.custom(def)) }
    func delete(_ def: CustomChannelDefinition) { entries.removeAll { $0.id == def.id }; persist() }

    // MARK: - Filtered views

    var customEntries: [LibraryEntry]     { entries.filter { if case .custom      = $0 { return true }; return false } }
    var modEntries:    [LibraryEntry]     { entries.filter { if case .modImported = $0 { return true }; return false } }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }

        // Try current format
        if let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            entries = decoded; return
        }
        // Migrate from old format (plain [CustomChannelDefinition])
        if let old = try? JSONDecoder().decode([CustomChannelDefinition].self, from: data) {
            entries = old.map { .custom($0) }
            persist()
        }
    }
}
