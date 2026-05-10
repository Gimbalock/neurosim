//
//  ToolPaletteView.swift
//  NeuroSimApp
//
//  Vertical tool palette — left sidebar of the main canvas window.
//
//  Layout
//  ──────
//   NAVIGATION   select · pan
//   NEURONES     addNeuron · addCompartment · [supprimer sélection]
//   CONNEXIONS   synapseExcitatory · synapseInhibitory · gapJunction · axialCoupling
//   OUTILS       stimulus · probe
//   RÉSERVÉ      2 placeholder slots for future features
//
//  Interactions
//  ────────────
//  • Active tool highlighted with filled accent background.
//  • Single-key shortcuts (no modifiers) while canvas has focus.
//  • "Supprimer" is an *action* button (not a tool mode): enabled only when
//    a neuron or synapse is selected; calls vm.removeSelected().
//  • Reserved slots are disabled and dimly dashed — visual promise of
//    features to come.
//

import SwiftUI

struct ToolPaletteView: View {
    @EnvironmentObject var vm: SimulationViewModel

    var body: some View {
        VStack(spacing: 0) {

            // ── NAVIGATION ─────────────────────────────────────────────────
            sectionLabel("NAVIGATION")
            paletteButton(.select)
            paletteButton(.pan)

            paletteSeparator

            // ── NEURONES ────────────────────────────────────────────────────
            sectionLabel("NEURONES")
            paletteButton(.addNeuron)
            paletteButton(.addCompartment)
            deleteSelectedButton

            paletteSeparator

            // ── CONNEXIONS ──────────────────────────────────────────────────
            sectionLabel("CONNEXIONS")
            paletteButton(.synapseExcitatory)
            paletteButton(.synapseInhibitory)
            paletteButton(.gapJunction)
            paletteButton(.axialCoupling)
            paletteButton(.synapticNoise)

            paletteSeparator

            // ── OUTILS ──────────────────────────────────────────────────────
            sectionLabel("OUTILS")
            paletteButton(.stimulus)
            paletteButton(.probe)

            paletteSeparator

            // ── RÉSERVÉ ──────────────────────────────────────────────────────
            sectionLabel("RÉSERVÉ")
            reservedButton(icon: "map",                  label: "Carte de connectivité")
            reservedButton(icon: "waveform.path.badge.plus", label: "Générateur de patterns")
            reservedButton(icon: "cube.transparent",     label: "Vue 3D")

            Spacer()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }

    // MARK: - Tool button (toggle mode)

    @ViewBuilder
    private func paletteButton(_ tool: EditorTool) -> some View {
        let isActive = vm.activeTool == tool
        Button {
            if tool == .addCompartment {
                if vm.addCompartmentToSelection() == nil {
                    vm.activeTool = tool
                }
            } else {
                vm.activeTool = tool
            }
        } label: {
            toolIcon(systemImage: tool.systemImage,
                     isActive: isActive,
                     isWired: tool.isCanvasWired)
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName)  (\(String(tool.shortcutKey.character).uppercased()))")
        .accessibilityLabel(tool.displayName)
        .keyboardShortcut(tool.shortcutKey, modifiers: [])
    }

    // MARK: - Delete selected action button

    private var deleteSelectedButton: some View {
        let deletable: Bool
        switch vm.selection {
        case .neuron, .synapse: deletable = true
        default:                deletable = false
        }

        return Button {
            vm.removeSelected()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(deletable ? Color.red : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(deletable
                              ? Color.red.opacity(0.08)
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!deletable)
        .help("Supprimer la sélection  (⌫)")
        .accessibilityLabel("Supprimer la sélection")
    }

    // MARK: - Reserved placeholder

    @ViewBuilder
    private func reservedButton(icon: String, label: String) -> some View {
        Button { } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .frame(width: 32, height: 32)
                .foregroundStyle(.quaternary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("\(label)  (à venir)")
        .accessibilityLabel("\(label) — à venir")
    }

    // MARK: - Shared icon renderer

    @ViewBuilder
    private func toolIcon(systemImage: String,
                          isActive: Bool,
                          isWired: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .regular))
            .frame(width: 32, height: 32)
            .foregroundStyle(isActive ? Color.white : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor : Color.clear)
            )
            .overlay(
                // Dashed outline for tools not yet wired to canvas behaviour
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isWired ? .clear : .secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            )
            .contentShape(Rectangle())
    }

    // MARK: - Section label

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Separator

    private var paletteSeparator: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

#Preview {
    ToolPaletteView()
        .environmentObject(SimulationViewModel.demoNetwork())
        .frame(width: 56, height: 600)
}
