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
    case gapJunction        // G — drag between two neurons (electrical, I = g(V₁−V₂))
    case axialCoupling      // A — drag between two compartments of one neuron
    case stimulus           // B — click a neuron to drop a default stimulus
    case probe              // M — click to add a trace to the plot window

    var id: String { rawValue }

    /// Short label for tooltips and accessibility.
    var displayName: String {
        switch self {
        case .select:             return "Select"
        case .pan:                return "Pan"
        case .addNeuron:          return "Add neuron"
        case .addCompartment:     return "Add compartment"
        case .synapseExcitatory:  return "Excitatory synapse"
        case .synapseInhibitory:  return "Inhibitory synapse"
        case .gapJunction:        return "Gap junction (electrical)"
        case .axialCoupling:      return "Axial coupling"
        case .stimulus:           return "Stimulus"
        case .probe:              return "Probe"
        }
    }

    /// SF Symbol used in the palette.
    var systemImage: String {
        switch self {
        case .select:             return "cursorarrow"
        case .pan:                return "hand.draw"
        case .addNeuron:          return "circle.dashed"
        case .addCompartment:     return "circle.dotted.and.circle"
        case .synapseExcitatory:  return "arrowtriangle.right.fill"
        case .synapseInhibitory:  return "minus.circle.fill"
        case .gapJunction:        return "alternatingcurrent"
        case .axialCoupling:      return "link"
        case .stimulus:           return "bolt"
        case .probe:              return "magnifyingglass"
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
        case .gapJunction:        return "g"
        case .axialCoupling:      return "a"
        case .stimulus:           return "b"
        case .probe:              return "m"
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
             .synapseExcitatory, .synapseInhibitory, .gapJunction, .stimulus:
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
            || self == .gapJunction
    }
}
