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

    var body: some View {
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
                Button { openWindow(id: "results") } label: {
                    Label("Results", systemImage: "chart.xyaxis.line")
                }
                .help("Open Results window (⌘G)")
                Button(action: vm.exportTracesCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
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
