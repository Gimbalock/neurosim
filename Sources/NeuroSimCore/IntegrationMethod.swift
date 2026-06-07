//
//  IntegrationMethod.swift
//  NeuroSimCore
//
//  Available numerical integration methods and their stability metadata.
//

import Foundation

public enum IntegrationMethod: String, CaseIterable, Codable, Identifiable, Sendable {

    case euler       = "Euler"
    case rk2         = "RK2 (Heun)"
    case rk4         = "RK4"
    case rushLarsen  = "Rush-Larsen"
    case rk45        = "RK45 adaptatif"
    case hines       = "Hines (câble implicite)"

    public var id: String { rawValue }

    /// Maximum dt (ms) beyond which instability is likely for standard HH.
    /// RK45 and Hines are unconditionally stable — threshold = max output interval.
    public var maxSafeDt: Double {
        switch self {
        case .euler:      return 0.01
        case .rk2:        return 0.025
        case .rk4:        return 0.05
        case .rushLarsen: return 0.5
        case .rk45:       return 1.0
        case .hines:      return 1.0   // unconditionally stable for cable; practical limit ≈ 1 ms
        }
    }

    /// Number of derivative evaluations per step (indicative CPU cost).
    public var evaluationsPerStep: Int {
        switch self {
        case .euler:      return 1
        case .rk2:        return 2
        case .rk4:        return 4
        case .rushLarsen: return 2   // 1 for gates (analytical) + 1 reeval for V
        case .rk45:       return 6   // per sub-step (Dormand-Prince)
        case .hines:      return 2   // same as Rush-Larsen + O(N) Thomas solve
        }
    }

    public var shortDescription: String {
        switch self {
        case .euler:
            return "Rapide, instable au-delà de ~0.01 ms. Pour tests uniquement."
        case .rk2:
            return "Heun — ordre 2, 2 évaluations/pas. Meilleur qu'Euler."
        case .rk4:
            return "Classique HH — ordre 4, précis jusqu'à ~0.05 ms."
        case .rushLarsen:
            return "Standard neuroscience — gates analytiques, stable jusqu'à ~0.5 ms."
        case .rk45:
            return "Dormand-Prince adaptatif — erreur contrôlée automatiquement."
        case .hines:
            return "Câble implicite (Thomas) — inconditionnellement stable pour axones multi-segments. Recommandé dès qu'un axone est attaché."
        }
    }
}
