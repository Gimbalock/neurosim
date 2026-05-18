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
    case sk          = "K_SK (Ca²⁺)"
    case bk          = "K_BK (Ca²⁺ + V)"
    case ih          = "I_h (HCN)"
    case ican        = "I_CAN (Ca²⁺)"
    case persistentNa = "Na_P (persistant)"
    case mCurrent    = "K_M (M-current)"
    case aType       = "K_A (A-type)"
    case calciumL    = "Ca²⁺ L-type"

    var id: String { rawValue }

    /// Suggested system-image for menus / list rows.
    var systemImage: String {
        switch self {
        case .sodium:    return "bolt.fill"
        case .potassium: return "arrow.down.circle"
        case .leak:      return "drop"
        case .calciumT:  return "waveform.path.ecg"
        case .sk:        return "circle.grid.2x1.fill"
        case .bk:        return "circle.grid.2x2.fill"
        case .ih:        return "arrow.up.arrow.down.circle"
        case .ican:      return "flame.fill"
        case .persistentNa: return "bolt.circle.fill"
        case .mCurrent:  return "dial.low.fill"
        case .aType:     return "waveform"
        case .calciumL:  return "waveform.path.ecg.rectangle"
        }
    }

    /// Construct a fresh instance with that kind's default parameters.
    func makeInstance() -> IonChannel {
        switch self {
        case .sodium:    return SodiumChannel()
        case .potassium: return PotassiumChannel()
        case .leak:      return LeakChannel()
        case .calciumT:  return TTypeCalciumChannel()
        case .sk:        return SKChannel()
        case .bk:        return BKChannel()
        case .ih:        return HChannel()
        case .ican:      return CANChannel()
        case .persistentNa: return PersistentSodiumChannel()
        case .mCurrent:  return MCurrentChannel()
        case .aType:     return ATypeChannel()
        case .calciumL:  return LTypeCalciumChannel()
        }
    }
}
