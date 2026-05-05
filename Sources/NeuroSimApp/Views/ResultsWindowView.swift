//
//  ResultsWindowView.swift
//  NeuroSimApp
//
//  Independent results window. One Swift Chart per chart group, where a group
//  can hold one or more overlaid signals (e.g. m(t), h(t), n(t) on the same axes).
//
//  • Per-chart y-axis triangle handles (drag to rescale the y range)
//  • "+" button on each card to add another signal to that group
//  • Global simulation controls (run/pause, reset, plot-window duration)
//  • Save / load graph configurations
//  • Add / remove signals via the picker sheet
//

import SwiftUI
import Charts
import NeuroSimCore
import AppKit
import UniformTypeIdentifiers

// MARK: - Colour palette for overlaid traces

private let kTraceColors: [Color] = [
    .blue, .orange, .green, .red, .purple, .yellow, .teal, .pink
]

// MARK: - Root view

struct ResultsWindowView: View {
    @EnvironmentObject var vm: SimulationViewModel

    /// nil  → full "Add Signal" picker (creates a new chart)
    /// non-nil → "Add to Chart" picker (adds to an existing group)
    @State private var pickerGroupID: UUID? = nil
    @State private var showingPicker = false

    /// Chart groups in stable insertion order.
    private var chartGroups: [(id: UUID, traces: [SimulationViewModel.SignalTrace])] {
        var seen: [UUID] = []
        var map:  [UUID: [SimulationViewModel.SignalTrace]] = [:]
        for trace in vm.signalTraces {
            let g = trace.chartGroupID
            if map[g] == nil { seen.append(g) }
            map[g, default: []].append(trace)
        }
        return seen.compactMap { id in map[id].map { (id: id, traces: $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if vm.signalTraces.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(chartGroups, id: \.id) { group in
                            SignalChartCard(
                                groupID: group.id,
                                traces: group.traces,
                                onAddToGroup: {
                                    pickerGroupID = group.id
                                    showingPicker = true
                                }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $showingPicker) {
            SignalPickerView(isPresented: $showingPicker, targetGroupID: pickerGroupID)
                .environmentObject(vm)
                .onDisappear { pickerGroupID = nil }
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button(action: vm.toggleRunning) {
                Label(vm.isRunning ? "Pause" : "Run",
                      systemImage: vm.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: vm.reset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider().frame(height: 18)

            Text(String(format: "t = %.1f ms", vm.simulationTime))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)

            // Duration
            HStack(spacing: 4) {
                Text("Duration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NumericSlider(value: $vm.plotWindow,
                              range: 50...5000,
                              step: 50,
                              format: "%.0f",
                              unit: "ms",
                              fieldWidth: 52,
                              unitWidth: 28,
                              showSlider: false)
            }

            Divider().frame(height: 18)

            Spacer()

            Button { vm.loadGraphConfig() } label: {
                Label("Load Graph", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Load a saved graph configuration")

            Button { vm.saveGraphConfig() } label: {
                Label("Save Graph", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save the current graph configuration")

            Divider().frame(height: 18)

            if !vm.signalTraces.isEmpty {
                Button(role: .destructive) {
                    vm.clearSignalTraces()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove all traces")
            }

            Button {
                pickerGroupID = nil
                showingPicker = true
            } label: {
                Label("Add Signal", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No signals selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Click \"+ Add Signal\" to choose a parameter to plot.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Add Signal") {
                pickerGroupID = nil
                showingPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Individual chart card (one group = one or more overlaid traces)

private struct SignalChartCard: View {
    @EnvironmentObject var vm: SimulationViewModel
    let groupID: UUID
    let traces: [SimulationViewModel.SignalTrace]
    var onAddToGroup: () -> Void

    @State private var yMin: Double = -90
    @State private var yMax: Double =  60
    @State private var yDragStart: YDragSnapshot? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
                .frame(height: 180)
                .onAppear { autoscale() }
                .onChange(of: groupID) { _, _ in autoscale() }
                .onChange(of: vm.autoscaleGeneration) { _, _ in autoscale() }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            // Legend: one label per trace with its colour dot
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(traces.enumerated()), id: \.element.id) { idx, trace in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(kTraceColors[idx % kTraceColors.count])
                            .frame(width: 8, height: 8)
                        Text(trace.label)
                            .font(.subheadline.weight(idx == 0 ? .medium : .regular))
                        if !trace.signal.unit.isEmpty {
                            Text("[\(trace.signal.unit)]")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // Remove this single trace
                        Button {
                            vm.removeSignalTrace(id: trace.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.quaternary)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this trace")
                    }
                }
            }

            Spacer()

            // Add another signal to this group
            Button(action: onAddToGroup) {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Add a signal to this chart")

            // Autoscale y range
            Button { autoscale() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Autoscale y-axis")
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(Array(traces.enumerated()), id: \.element.id) { idx, trace in
                let color = kTraceColors[idx % kTraceColors.count]
                ForEach(trace.points) { p in
                    LineMark(
                        x: .value("t (ms)", p.t),
                        y: .value(trace.signal.unit.isEmpty ? "value" : trace.signal.unit, p.v),
                        series: .value("signal", trace.label)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(color)
                }
            }
            if shouldShowZeroLine {
                RuleMark(y: .value("0", 0))
                    .foregroundStyle(.gray.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yMin...yMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    yHandle(.yMin, plotFrame: plotFrame, proxy: proxy)
                    yHandle(.yMax, plotFrame: plotFrame, proxy: proxy)
                }
            }
        }
    }

    // MARK: - Y-axis triangle handles

    private func yHandlePoint(_ edge: YEdge, plotFrame: CGRect) -> CGPoint {
        let gutter: CGFloat = 34
        switch edge {
        case .yMin: return CGPoint(x: plotFrame.minX - gutter, y: plotFrame.midY + 10)
        case .yMax: return CGPoint(x: plotFrame.minX - gutter, y: plotFrame.midY - 10)
        }
    }

    private func yHandleDirection(_ edge: YEdge) -> AxisTriangle.Direction {
        switch edge {
        case .yMin: return .down
        case .yMax: return .up
        }
    }

    @ViewBuilder
    private func yHandle(_ edge: YEdge,
                          plotFrame: CGRect,
                          proxy: ChartProxy) -> some View {
        let size: CGFloat = 12
        let color: Color = yDragStart != nil ? Color.accentColor : Color.secondary.opacity(0.7)
        AxisTriangle(direction: yHandleDirection(edge))
            .fill(color)
            .frame(width: size, height: size)
            .background(
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: size + 16, height: size + 16)
            )
            .position(yHandlePoint(edge, plotFrame: plotFrame))
            .gesture(yDragGesture(for: edge, proxy: proxy))
            .help(edge == .yMin ? "Drag to adjust y min" : "Drag to adjust y max")
    }

    private func yDragGesture(for edge: YEdge, proxy: ChartProxy) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if yDragStart == nil {
                    yDragStart = captureYSnapshot(proxy: proxy)
                }
                guard let snap = yDragStart else { return }
                applyYDrag(edge: edge, snapshot: snap, value: value)
            }
            .onEnded { _ in yDragStart = nil }
    }

    private func captureYSnapshot(proxy: ChartProxy) -> YDragSnapshot {
        let py0 = proxy.position(forY: yMin) ?? 0
        let py1 = proxy.position(forY: yMax) ?? 1
        let pxPerY = (yMax - yMin) > 1e-9 ? (py1 - py0) / (yMax - yMin) : -1
        return YDragSnapshot(yMin: yMin, yMax: yMax, pxPerY: pxPerY)
    }

    private func applyYDrag(edge: YEdge,
                             snapshot snap: YDragSnapshot,
                             value: DragGesture.Value) {
        let dy = snap.pxPerY != 0 ? value.translation.height / snap.pxPerY : 0
        switch edge {
        case .yMin: yMin = min(snap.yMax - 1e-3, snap.yMin + dy)
        case .yMax: yMax = max(snap.yMin + 1e-3, snap.yMax + dy)
        }
    }

    // MARK: - Helpers

    private var xDomain: ClosedRange<Double> {
        let end = max(vm.simulationTime, vm.plotWindow)
        return (end - vm.plotWindow)...end
    }

    private var shouldShowZeroLine: Bool { yMin < 0 && yMax > 0 }

    private func autoscale() {
        let vals = traces.flatMap { $0.points.map(\.v) }
        if vals.isEmpty {
            // No data yet: fall back to suggested domain or a safe default.
            if let d = traces.first?.signal.suggestedYDomain {
                yMin = d.lowerBound; yMax = d.upperBound
            } else {
                yMin = -1; yMax = 1
            }
        } else {
            let lo = vals.min()!
            let hi = vals.max()!
            let span = hi - lo
            let pad = max(span * 0.1, 0.5)
            yMin = lo - pad
            yMax = hi + pad
        }
    }

    // MARK: - Supporting types

    enum YEdge { case yMin, yMax }

    struct YDragSnapshot {
        let yMin: Double
        let yMax: Double
        let pxPerY: Double
    }
}
