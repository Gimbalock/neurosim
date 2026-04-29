//
//  ContentView.swift
//  NeuroSimApp
//
//  Three-pane layout:
//    ┌──────────────────────────┬──────────────────┐
//    │                          │                  │
//    │      Network editor      │    Inspector     │
//    │                          │                  │
//    ├──────────────────────────┴──────────────────┤
//    │              V(t) plot (Charts)             │
//    └─────────────────────────────────────────────┘
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: SimulationViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NetworkEditorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView()
                    .frame(width: 320)
            }
            Divider()
            PlotView()
                .frame(height: 220)
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
                Button(action: vm.exportTracesCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItemGroup(placement: .status) {
                Text(String(format: "t = %.1f ms", vm.simulationTime))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Slider(value: $vm.realtimeFactor, in: 0.25...20.0) {
                    Text("Speed")
                } minimumValueLabel: {
                    Text("0.25x").font(.caption2)
                } maximumValueLabel: {
                    Text("20x").font(.caption2)
                }
                .frame(width: 200)
            }
        }
    }
}
