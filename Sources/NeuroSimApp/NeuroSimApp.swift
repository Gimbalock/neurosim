//
//  NeuroSimApp.swift
//  NeuroSimApp
//
//  Entry point. Window scene with a single ContentView.
//

import SwiftUI
import AppKit
import NeuroSimCore

@main
struct NeuroSimApp: App {
    @StateObject  private var viewModel     = SimulationViewModel(network: Network())
    @ObservedObject private var presetLib   = PresetLibrary.shared

    init() {
        // Without a signed .app bundle, `swift run`-launched executables
        // default to a non-regular activation policy: their windows show
        // but cannot become the key window, so keyboard input goes to
        // whichever app *was* frontmost (typically Xcode or Terminal).
        // Forcing `.regular` and activating makes us a proper foreground
        // app and lets text fields receive input. Harmless when wrapped
        // in a real .app bundle later.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("NeuroSim") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Network") { viewModel.newNetwork() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Open…") { viewModel.openNetwork() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Import…") { viewModel.importNetwork() }
                Divider()
                Button("Save") { viewModel.saveNetwork() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Save As…") { viewModel.saveNetworkAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Simulation") {
                Button("Run / Pause") { viewModel.toggleRunning() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Reset") { viewModel.reset() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("Export traces (CSV)…") { viewModel.exportTracesCSV() }
                    .keyboardShortcut("e", modifiers: [.command])
                Divider()
                OpenResultsMenuItem()
            }
            CommandMenu("Presets") {
                // ── Save current model ──────────────────────────────
                Button("Sauvegarder le modèle comme preset…") {
                    let alert = NSAlert()
                    alert.messageText = "Sauvegarder comme preset global"
                    alert.informativeText = "Ce preset sera disponible dans toutes les sessions."
                    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    tf.placeholderString = "Nom du preset…"
                    alert.accessoryView = tf
                    alert.addButton(withTitle: "Sauvegarder")
                    alert.addButton(withTitle: "Annuler")
                    if alert.runModal() == .alertFirstButtonReturn {
                        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            PresetLibrary.shared.save(name: name, from: viewModel)
                        }
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Divider()

                // ── Built-in models ─────────────────────────────────
                Button("PD Neuron — soma + AIS (STG)") { viewModel.loadPresetPD() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])

                // ── User-saved presets (dynamic) ────────────────────
                if !presetLib.presets.isEmpty {
                    Divider()
                    ForEach(presetLib.presets) { preset in
                        Button(preset.name) {
                            PresetLibrary.shared.restore(preset, to: viewModel)
                        }
                    }
                }
            }
        }

        Window("Results", id: "results") {
            ResultsWindowView()
                .environmentObject(viewModel)
        }
    }
}

// Helper View so `openWindow` environment action is accessible inside Commands.
private struct OpenResultsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Results Window") { openWindow(id: "results") }
            .keyboardShortcut("g", modifiers: [.command])
    }
}
