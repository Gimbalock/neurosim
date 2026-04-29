//
//  NeuroSimApp.swift
//  NeuroSimApp
//
//  Entry point. Window scene with a single ContentView.
//

import SwiftUI

@main
struct NeuroSimApp: App {
    @StateObject private var viewModel = SimulationViewModel.demoNetwork()

    var body: some Scene {
        WindowGroup("NeuroSim") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) { } // we don't open documents — yet
            CommandMenu("Simulation") {
                Button("Run / Pause") { viewModel.toggleRunning() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Reset") { viewModel.reset() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("Export traces (CSV)…") { viewModel.exportTracesCSV() }
                    .keyboardShortcut("e", modifiers: [.command])
            }
        }
    }
}
