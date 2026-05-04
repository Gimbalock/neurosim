//
//  ToolPaletteView.swift
//  NeuroSimApp
//
//  Vertical tool palette displayed as the left sidebar of the main window.
//
//  Step 5c — fully wired:
//   - Each icon is a button that sets `vm.activeTool`.
//   - The active tool's icon is highlighted (filled accent background).
//   - Single-key shortcuts (V, H, N, C, S, A, I, M) — no modifiers — let
//     users switch tools without leaving the canvas, as long as no text
//     field has focus.
//   - Tools whose canvas behaviour isn't yet implemented (.axialCoupling,
//     .stimulus, .probe) are still selectable so users can see them, but
//     clicking on the canvas while one of them is active is a no-op for now.
//
//  Layout reference: docs/UI_DESIGN.md §"Panneau outils (gauche)".
//

import SwiftUI

struct ToolPaletteView: View {
    @EnvironmentObject var vm: SimulationViewModel

    var body: some View {
        VStack(spacing: 6) {
            paletteButton(.select)
            paletteButton(.pan)

            paletteSeparator

            paletteButton(.addNeuron)
            paletteButton(.addCompartment)
            paletteButton(.synapseExcitatory)
            paletteButton(.synapseInhibitory)
            paletteButton(.gapJunction)
            paletteButton(.axialCoupling)

            paletteSeparator

            paletteButton(.stimulus)
            paletteButton(.probe)

            Spacer()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func paletteButton(_ tool: EditorTool) -> some View {
        let isActive = vm.activeTool == tool
        Button {
            vm.activeTool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(isActive ? Color.white : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tool.isCanvasWired ? .clear : .secondary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName)  (\(String(tool.shortcutKey.character).uppercased()))")
        .accessibilityLabel(tool.displayName)
        // Single-character shortcut, no modifiers.
        .keyboardShortcut(tool.shortcutKey, modifiers: [])
    }

    private var paletteSeparator: some View {
        Divider()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }
}

#Preview {
    ToolPaletteView()
        .environmentObject(SimulationViewModel.demoNetwork())
        .frame(width: 56, height: 500)
}
