//
//  ChannelKind.swift
//  NeuroSimApp
//
//  Lightweight enum acting as a registry of the ion-channel types that
//  the UI exposes via the "Add channel" menu. Adding a new kind is two
//  lines — a case here and a row in `makeInstance` — and it shows up in
//  the inspector automatically.
//

import Foundation
import NeuroSimCore

enum ChannelKind: String, CaseIterable, Identifiable, Hashable {
    case sodium      = "Na+ (HH)"
    case potassium   = "K+ (HH)"
    case leak        = "Leak"
    case calciumT    = "Ca²⁺ T-type"

    var id: String { rawValue }

    /// Suggested system-image for menus / list rows.
    var systemImage: String {
        switch self {
        case .sodium:    return "bolt.fill"        // fast inward
        case .potassium: return "arrow.down.circle"
        case .leak:      return "drop"
        case .calciumT:  return "waveform.path.ecg"
        }
    }

    /// Construct a fresh instance with that kind's default parameters.
    func makeInstance() -> IonChannel {
        switch self {
        case .sodium:    return SodiumChannel()
        case .potassium: return PotassiumChannel()
        case .leak:      return LeakChannel()
        case .calciumT:  return TTypeCalciumChannel()
        }
    }
}
