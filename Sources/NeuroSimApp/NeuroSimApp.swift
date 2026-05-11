//
//  NeuroSimApp.swift
//  NeuroSimApp
//
//  Entry point. Window scene with a single ContentView.
//

import SwiftUI
import AppKit

@main
struct NeuroSimApp: App {
    @StateObject private var viewModel = SimulationViewModel.demoNetwork()

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
            AppCommands(vm: viewModel)
        }

        Window("Results", id: "results") {
            ResultsWindowView()
                .environmentObject(viewModel)
        }
    }
}

// MARK: - Commands

/// Using a dedicated Commands struct with @ObservedObject ensures SwiftUI
/// keeps a live reference to the ViewModel rather than capturing a potentially
/// stale value from the scene-body closure.
private struct AppCommands: Commands {
    @ObservedObject var vm: SimulationViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Network") { vm.newNetwork() }
                .keyboardShortcut("n", modifiers: [.command])
            Button("Open…") { vm.openNetwork() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Import…") { vm.importNetwork() }
            Divider()
            Button("Save") { vm.saveNetwork() }
                .keyboardShortcut("s", modifiers: [.command])
            Button("Save As…") { vm.saveNetworkAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Simulation") {
            Button("Run / Pause") { vm.toggleRunning() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Reset") { vm.reset() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Button("Export traces (CSV)…") { vm.exportTracesCSV() }
                .keyboardShortcut("e", modifiers: [.command])
            Divider()
            OpenResultsMenuItem()
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
