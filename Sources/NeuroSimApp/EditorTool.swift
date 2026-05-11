//
//  EditorTool.swift
//  NeuroSimApp
//
//  Active editing tool for the network canvas. The selected tool
//  conditions what mouse interactions on the canvas mean — e.g. a click
//  on empty space adds a neuron when `.addNeuron` is active, or a drag
//  between two cells creates a chemical synapse with the appropriate
//  reversal potential when `.synapseExcitatory` / `.synapseInhibitory`
//  is active.
//
//  Layout reference: docs/UI_DESIGN.md §"Panneau outils (gauche)".
//

import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select             // V — pick / move
    case pan                // H — pan the canvas
    case addNeuron          // N — click empty canvas to add a neuron
    case addCompartment     // C — click a neuron to add a compartment
    case synapseExcitatory  // E — drag between two neurons (reversal ≈ 0 mV)
    case synapseInhibitory  // I — drag between two neurons (reversal ≈ -75 mV)
    case synapseNMDA        // D — drag between two neurons (NMDA, Mg²⁺ block)
    case synapseSTDP        // T — drag between two neurons (AMPA + STDP plasticity)
    case gapJunction        // G — drag between two neurons (electrical, I = g(V₁−V₂))
    case axialCoupling      // A — drag between two compartments of one neuron
    case stimulus           // B — click a neuron to drop a default stimulus
    case probe              // M — click to add a trace to the plot window
    case synapticNoise       // W — click a neuron to attach OU synaptic noise

    var id: String { rawValue }

    /// Short label for tooltips and accessibility.
    var displayName: String {
        switch self {
        case .select:             return "Sélectionner"
        case .pan:                return "Panoramique"
        case .addNeuron:          return "Ajouter un neurone"
        case .addCompartment:     return "Ajouter un compartiment"
        case .synapseExcitatory:  return "Synapse excitatrice (AMPA)"
        case .synapseInhibitory:  return "Synapse inhibitrice (GABA)"
        case .synapseNMDA:        return "Synapse NMDA (blocage Mg²⁺)"
        case .synapseSTDP:        return "Synapse AMPA + STDP (plastique)"
        case .gapJunction:        return "Jonction gap (électrique)"
        case .axialCoupling:      return "Couplage axial"
        case .stimulus:           return "Stimulus"
        case .probe:              return "Électrode"
        case .synapticNoise:      return "Bruit synaptique"
        }
    }

    /// SF Symbol used in the palette.
    var systemImage: String {
        switch self {
        // Navigation
        case .select:             return "cursorarrow"
        case .pan:                return "hand.raised"
        // Neurons
        case .addNeuron:          return "plus.circle"
        case .addCompartment:     return "smallcircle.filled.circle"
        // Connections
        case .synapseExcitatory:  return "arrow.forward.circle.fill"
        case .synapseInhibitory:  return "minus.circle.fill"
        case .synapseNMDA:        return "circle.dotted.and.circle"
        case .synapseSTDP:        return "arrow.triangle.2.circlepath.circle.fill"
        case .gapJunction:        return "waveform"
        case .axialCoupling:      return "arrow.left.and.right.circle"
        // Tools
        case .stimulus:           return "bolt.fill"
        case .probe:              return "scope"
        case .synapticNoise:      return "waveform.badge.plus"
        }
    }

    /// Single-character keyboard shortcut (no modifiers). Triggered while
    /// the canvas / palette has focus and no text field is being edited.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .select:             return "v"
        case .pan:                return "h"
        case .addNeuron:          return "n"
        case .addCompartment:     return "c"
        case .synapseExcitatory:  return "e"
        case .synapseInhibitory:  return "i"
        case .synapseNMDA:        return "d"
        case .synapseSTDP:        return "t"
        case .gapJunction:        return "g"
        case .axialCoupling:      return "a"
        case .stimulus:           return "b"
        case .probe:              return "m"
        case .synapticNoise:      return "w"
        }
    }

    /// Default reversal potential (mV) used when this tool creates a
    /// synapse. Only meaningful for `.synapseExcitatory` and
    /// `.synapseInhibitory`.
    var defaultReversal: Double {
        switch self {
        case .synapseExcitatory: return 0.0     // depolarising
        case .synapseInhibitory: return -75.0   // chloride-like, hyperpolarising
        default:                  return 0.0
        }
    }

    /// Whether the tool is "wired through" to canvas behaviour as of step 5c.
    /// Tools that aren't yet wired can still be selected from the palette,
    /// but clicks on the canvas do nothing for them — the visible state of
    /// the palette still reflects the selection so users can preview future
    /// behaviour.
    var isCanvasWired: Bool {
        switch self {
        case .select, .pan, .addNeuron, .addCompartment,
             .synapseExcitatory, .synapseInhibitory, .synapseNMDA, .synapseSTDP,
             .gapJunction, .stimulus, .synapticNoise:
            return true
        case .axialCoupling, .probe:
            return false
        }
    }

    /// Convenience: tools that draft a connection between two neurons on
    /// drag (chemical synapses *and* gap junctions). The drag UX and the
    /// hit-test are identical; only the model object created at the end
    /// differs.
    var isSynapseTool: Bool {
        self == .synapseExcitatory
            || self == .synapseInhibitory
            || self == .synapseNMDA
            || self == .synapseSTDP
            || self == .gapJunction
    }
}
