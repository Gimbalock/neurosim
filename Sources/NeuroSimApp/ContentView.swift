//
//  ContentView.swift
//  NeuroSimApp
//
//  Three-column main window layout (step 5a):
//
//    ┌────┬──────────────────────────┬────────────────┐
//    │ T  │                          │                │
//    │ O  │     Network editor       │   Inspector    │
//    │ O  │       (canvas)           │   (320 px)     │
//    │ L  │                          │                │
//    │ S  │                          │                │
//    ├────┴──────────────────────────┴────────────────┤
//    │              V(t) plot (Charts)                │
//    └────────────────────────────────────────────────┘
//
//  - Sidebar (left)   : ToolPaletteView, fixed 56 px (not draggable).
//                       Still collapsible via the standard macOS sidebar
//                       toggle (⌃⌘S) — provided by NavigationSplitView.
//  - Content (middle) : NetworkEditorView. Flexible — absorbs window resize.
//  - Detail  (right)  : InspectorView, resizable 260…480 px (default 320).
//                       Drag the divider between canvas and inspector.
//  - Bottom strip     : PlotView (~220 px). Will be moved to its own
//                       detachable window in step 5e.
//
//  The whole window is resizable; the canvas grows/shrinks to absorb
//  changes while the palette stays at 56 px and the inspector keeps its
//  user-set width.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSnapshots = false

    var body: some View {
        ZStack {
            mainLayout

            // Welcome overlay — shown on fresh launch until the user picks an action.
            // `showWelcomeScreen` is set to false by newNetwork/openNetwork/importNetwork
            // so the overlay dismisses even when the resulting network is empty.
            if vm.showWelcomeScreen {
                WelcomeView()
                    .environmentObject(vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.showWelcomeScreen)
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ToolPaletteView()
                    .navigationSplitViewColumnWidth(56)
            } content: {
                NetworkEditorView()
                    .overlay(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    )
                    .navigationSplitViewColumnWidth(min: 400, ideal: 700)
            } detail: {
                InspectorView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
            }
            .navigationSplitViewStyle(.balanced)

            // Bottom status bar
            Divider()
            HStack(spacing: 12) {
                // Simulation time
                HStack(spacing: 3) {
                    Text("t =")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f ms", vm.simulationTime))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Divider().frame(height: 14)

                // dt
                HStack(spacing: 3) {
                    Text("dt =")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.3f ms", vm.dt))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Divider().frame(height: 14)

                // Neuron / synapse count
                Text("\(vm.network.neurons.count) neuron\(vm.network.neurons.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(vm.network.synapses.count) synapse\(vm.network.synapses.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Warm-start indicator — shows when the next Run will continue
                // from the end of the last simulation rather than resting state.
                if vm.hasWarmState {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("Warm")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                    .help("Prochain Run repart de l'état final de la dernière simulation. " +
                          "Cliquez ↺ pour revenir à l'état de repos.")
                }

                Spacer()

                if let err = vm.divergenceError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                // Status indicator
                Circle()
                    .fill(vm.divergenceError != nil ? Color.red :
                          vm.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(vm.divergenceError != nil ? "Divergence" :
                     vm.isRunning ? "Running" : "Paused")
                    .font(.caption)
                    .foregroundStyle(vm.divergenceError != nil ? .red :
                                     vm.isRunning ? .primary : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: vm.toggleRunning) {
                    Label(vm.isRunning ? "Pause" : "Run",
                          systemImage: vm.isRunning ? "pause.fill" : "play.fill")
                }
                Button(action: vm.reset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help(vm.hasWarmState
                      ? "Réinitialiser à l'état de repos (efface le warm start)"
                      : "Réinitialiser à l'état de repos")
                Button { openWindow(id: "results") } label: {
                    Label("Results", systemImage: "chart.xyaxis.line")
                }
                .help("Open Results window (⌘G)")
                Button(action: vm.exportTracesCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                // Freeze State — parameter snapshots
                Button {
                    showSnapshots = true
                } label: {
                    Label(
                        vm.snapshots.isEmpty ? "Freeze State" : "Freeze State (\(vm.snapshots.count))",
                        systemImage: "snowflake"
                    )
                }
                .help("Capturer / restaurer un instantané des paramètres du modèle")
                .sheet(isPresented: $showSnapshots) {
                    SnapshotsView()
                        .environmentObject(vm)
                }
            }
            ToolbarItemGroup(placement: .status) {
                // Speed — compact editable field, no slider
                HStack(spacing: 4) {
                    Text("Speed")
                        .font(.caption)
                    NumericSlider(value: $vm.realtimeFactor,
                                  range: 0.1...50.0,
                                  format: "%.2f",
                                  fieldWidth: 52,
                                  unitWidth: 0,
                                  showSlider: false)
                    Text("×")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - WelcomeView

private struct WelcomeView: View {
    @EnvironmentObject var vm: SimulationViewModel

    var body: some View {
        ZStack {
            // Frosted background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // Logo / titre
                VStack(spacing: 8) {
                    Image(systemName: "brain.filled.head.profile")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text("NeuroSim")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Simulateur de réseaux de neurones Hodgkin-Huxley")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Boutons d'action
                VStack(spacing: 12) {
                    Button {
                        vm.openNetwork()
                    } label: {
                        Label("Ouvrir un réseau…", systemImage: "folder")
                            .frame(width: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)

                    Button {
                        vm.importNetwork()
                    } label: {
                        Label("Importer…", systemImage: "square.and.arrow.down")
                            .frame(width: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        vm.newNetwork()
                    } label: {
                        Label("Nouveau réseau vide", systemImage: "plus.circle")
                            .frame(width: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
                }

                Text("⌘O pour ouvrir · ⌘N pour nouveau")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(48)
        }
    }
}
