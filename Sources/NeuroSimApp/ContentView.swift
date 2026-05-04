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

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ToolPaletteView()
                    .navigationSplitViewColumnWidth(56)
            } content: {
                NetworkEditorView()
                    .navigationSplitViewColumnWidth(min: 400, ideal: 700)
            } detail: {
                InspectorView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
            }
            .navigationSplitViewStyle(.balanced)

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
                NumericSlider(label: "Speed",
                              value: $vm.realtimeFactor,
                              range: 0.25...20.0,
                              format: "%.2f",
                              unit: "x",
                              labelWidth: 44,
                              fieldWidth: 56)
                    .frame(width: 260)
            }
        }
    }
}
