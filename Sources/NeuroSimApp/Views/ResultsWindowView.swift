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

// MARK: - Colour palette alias (palette defined in SimulationViewModel.swift)

private let kTraceColors: [Color] = kTracePalette

// MARK: - Root view

private enum AnalysisTab: String, CaseIterable {
    case traces      = "Traces"
    case raster      = "Raster"
    case isi         = "ISI"
    case phase       = "Phase"
    case density     = "Optimisation"
    case clamp       = "Clamp"
    case bifurcation = "Bifurcation"
    case heatmap     = "Heatmap"
    case modelSweep  = "Model Sweep"
    case mutualInfo  = "Info Mut."
    case energy      = "Énergie"
}

struct ResultsWindowView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var selectedTab: AnalysisTab = .traces

    /// nil  → full "Add Signal" picker (creates a new chart)
    /// non-nil → "Add to Chart" picker (adds to an existing group)
    @State private var pickerGroupID: UUID? = nil
    @State private var showingPicker = false

    /// Explicit display order for chart groups. Kept in sync with
    /// vm.signalTraces: new groups appended at the end, deleted groups removed.
    /// The user can reorder by dragging cards.
    @State private var orderedGroupIDs: [UUID] = []

    /// Non-nil when the user has rubber-band-zoomed into a time region.
    /// All charts share this zoom; nil = full view.
    @State private var xZoom: ClosedRange<Double>? = nil

/// Chart groups in user-defined display order.
    private var orderedGroups: [(id: UUID, traces: [SimulationViewModel.SignalTrace])] {
        let map = Dictionary(grouping: vm.signalTraces, by: \.chartGroupID)
        return orderedGroupIDs.compactMap { id in map[id].map { (id: id, traces: $0) } }
    }

    /// Stable set of group IDs currently alive in vm.signalTraces.
    private var liveGroupIDs: [UUID] {
        var seen: [UUID] = []
        var set = Set<UUID>()
        for t in vm.signalTraces {
            if set.insert(t.chartGroupID).inserted { seen.append(t.chartGroupID) }
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            // Tab selector
            Picker("", selection: $selectedTab) {
                ForEach(AnalysisTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 860)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            Divider()
            // Tab content
            switch selectedTab {
            case .traces:       tracesContent
            case .raster:       RasterView()
            case .isi:          ISIView()
            case .phase:        PhaseView()
            case .density:      TrajectoryDensityView()
            case .clamp:        VoltageClampView()
            case .bifurcation:  BifurcationView()
            case .heatmap:      HeatmapView()
            case .modelSweep:   ModelSweepView()
            case .mutualInfo:   MutualInfoView()
            case .energy:       EnergyView()
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: vm.autoscaleGeneration) { _, _ in xZoom = nil }
        // Reset zoom whenever the simulation starts — the chart scrolls while
        // running, so a frozen zoom window would immediately show stale/empty data.
        .onChange(of: vm.isRunning) { _, running in if running { xZoom = nil } }
        .sheet(isPresented: $showingPicker) {
            SignalPickerView(isPresented: $showingPicker, targetGroupID: pickerGroupID)
                .environmentObject(vm)
                .onDisappear { pickerGroupID = nil }
        }
        .onChange(of: liveGroupIDs) { _, newIDs in syncOrder(with: newIDs) }
        .onAppear { syncOrder(with: liveGroupIDs) }
    }

    private var tracesContent: some View {
        Group {
            if vm.signalTraces.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(orderedGroups, id: \.id) { group in
                            SignalChartCard(
                                groupID: group.id,
                                traces: group.traces,
                                xZoom: $xZoom,
                                onAddToGroup: {
                                    pickerGroupID = group.id
                                    showingPicker = true
                                }
                            )
                            .padding(.horizontal, 16)
                            .draggable(group.id.uuidString) {
                                dragPreview(for: group)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let idStr = items.first,
                                      let draggedID = UUID(uuidString: idStr),
                                      draggedID != group.id
                                else { return false }
                                moveGroup(draggedID, beforeGroup: group.id)
                                return true
                            } isTargeted: { _ in }
                        }
                        if orderedGroups.count > 1 {
                            trailingDropZone.padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onDrop(of: [.plainText], isTargeted: nil) { _, _ in false }
            }
        }
    }

    // MARK: - Drag helpers

    @ViewBuilder
    private func dragPreview(for group: (id: UUID, traces: [SimulationViewModel.SignalTrace])) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.traces) { t in
                Text(t.label).font(.caption).lineLimit(1)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 240)
    }

    private var trailingDropZone: some View {
        Color.accentColor.opacity(0.001)   // invisible but hittable
            .frame(height: 24)
            .dropDestination(for: String.self) { items, _ in
                guard let idStr = items.first,
                      let draggedID = UUID(uuidString: idStr)
                else { return false }
                // Move dragged group to the very end
                if let idx = orderedGroupIDs.firstIndex(of: draggedID) {
                    orderedGroupIDs.remove(at: idx)
                    orderedGroupIDs.append(draggedID)
                    reorderSignalTraces()
                }
                return true
            }
    }

    // MARK: - Order management

    private func syncOrder(with liveIDs: [UUID]) {
        // Preserve existing order; append any new IDs; drop dead ones.
        orderedGroupIDs = orderedGroupIDs.filter { liveIDs.contains($0) }
        for id in liveIDs where !orderedGroupIDs.contains(id) {
            orderedGroupIDs.append(id)
        }
    }

    private func moveGroup(_ draggedID: UUID, beforeGroup targetID: UUID) {
        guard let fromIdx = orderedGroupIDs.firstIndex(of: draggedID),
              let toIdx   = orderedGroupIDs.firstIndex(of: targetID)
        else { return }
        orderedGroupIDs.remove(at: fromIdx)
        let insertIdx = orderedGroupIDs.firstIndex(of: targetID) ?? orderedGroupIDs.endIndex
        orderedGroupIDs.insert(draggedID, at: insertIdx)
        _ = toIdx  // suppress warning
        reorderSignalTraces()
    }

    /// Mirror orderedGroupIDs into vm.signalTraces so the sampling loop and
    /// graph-config save/load stay consistent with the visual order.
    private func reorderSignalTraces() {
        var reordered: [SimulationViewModel.SignalTrace] = []
        for gid in orderedGroupIDs {
            reordered.append(contentsOf: vm.signalTraces.filter { $0.chartGroupID == gid })
        }
        vm.signalTraces = reordered
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

            // Zoom-reset button — visible only while a rubber-band zoom is active.
            if xZoom != nil {
                Button {
                    xZoom = nil
                } label: {
                    Label("Zoom out", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Return to full view  (Esc)")

                Divider().frame(height: 18)
            }

            Text(String(format: "t = %.1f ms", vm.simulationTime))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)

            if vm.isRunning || vm.frameComputeMs > 0 {
                Divider().frame(height: 18)
                HStack(spacing: 6) {
                    Text(String(format: "%.1f ms/frame", vm.frameComputeMs))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "×%.1f", vm.simToWallRatio))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(vm.simToWallRatio >= 1 ? .green : .orange)
                        .help("Ratio temps simulé / temps réel (>1 = plus rapide que le temps réel)")
                }
            }

            // Duration
            HStack(spacing: 4) {
                Text("Duration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NumericSlider(value: $vm.plotWindow,
                              range: 50...60_000,
                              step: 50,
                              format: "%.0f",
                              unit: "ms",
                              fieldWidth: 52,
                              unitWidth: 28,
                              showSlider: false)
            }

            Divider().frame(height: 18)

            Spacer()

            if selectedTab == .traces {
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

                // Export traces as CSV
                let exportableNeurons = vm.network.neurons.filter {
                    vm.traces[$0.id]?.isEmpty == false
                }
                if !exportableNeurons.isEmpty {
                    Menu {
                        ForEach(exportableNeurons) { n in
                            Button(n.name) { exportTrace(neuron: n) }
                        }
                        if exportableNeurons.count > 1 {
                            Divider()
                            Button("Tous les neurones (colonnes)") { exportAllTraces() }
                        }
                    } label: {
                        Label("Exporter…", systemImage: "arrow.down.doc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Exporter les traces en CSV (t, V)")
                }

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - CSV Export

    /// Export a single neuron's trace as a two-column CSV: t (ms), V (mV).
    private func exportTrace(neuron: HHNeuron) {
        guard let pts = vm.traces[neuron.id], !pts.isEmpty else { return }
        let csv = buildCSV(header: "t_ms,V_mV", rows: pts.map { "\($0.t),\($0.v)" })
        saveCSV(csv, suggestedName: "\(neuron.name)_trace")
    }

    /// Export all neurons into one CSV: t (ms), V_N1, V_N2, … (interpolated on
    /// a shared time axis derived from the first neuron's timestamps).
    private func exportAllTraces() {
        let neurons = vm.network.neurons.filter { vm.traces[$0.id]?.isEmpty == false }
        guard !neurons.isEmpty else { return }

        // Use first neuron's time axis as reference
        guard let ref = vm.traces[neurons[0].id] else { return }
        let names = neurons.map { $0.name }.joined(separator: ",")
        var lines = ["t_ms,\(names)"]

        // Build per-neuron lookup dictionaries for O(1) access
        let lookups: [[Double: Double]] = neurons.map { n in
            Dictionary(uniqueKeysWithValues: (vm.traces[n.id] ?? []).map { ($0.t, $0.v) })
        }

        for pt in ref {
            let vs = lookups.map { dict in dict[pt.t].map { String($0) } ?? "" }
            lines.append("\(pt.t),\(vs.joined(separator: ","))")
        }

        saveCSV(lines.joined(separator: "\n"), suggestedName: "traces_all")
    }

    private func buildCSV(header: String, rows: [String]) -> String {
        ([header] + rows).joined(separator: "\n")
    }

    private func saveCSV(_ content: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Exporter la trace"
        panel.nameFieldStringValue = "\(suggestedName).csv"
        panel.allowedContentTypes  = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
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
    @Binding var xZoom: ClosedRange<Double>?
    var isDimmed: Bool = false
    var onAddToGroup: () -> Void

    @State private var yMin: Double = -90
    @State private var yMax: Double =  60
    @State private var yDragStart: YDragSnapshot? = nil

    // Rubber-band selection state
    @State private var selStartX: CGFloat? = nil
    @State private var selCurrentX: CGFloat = 0

    // Cursor (measurement crosshair)
    @State private var cursorAbs: CGPoint? = nil   // position in GeometryReader space
    @State private var cursorT:   Double?  = nil   // time value at cursor (ms)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
                .frame(height: 180)
                .onAppear { autoscale() }
                .onChange(of: groupID) { _, _ in autoscale() }
                .onChange(of: vm.autoscaleGeneration) { _, _ in autoscale() }
                .onChange(of: vm.isRunning) { _, running in if !running { autoscale() } }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .opacity(isDimmed ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.15), value: isDimmed)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            // Drag handle — visual affordance; the actual drag is on the whole card
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            // Legend: one label per trace with colour swatch
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(traces.enumerated()), id: \.element.id) { idx, trace in
                    TraceHeaderRow(trace: trace, isFirst: idx == 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

    /// Return the points to render in Swift Charts for one trace.
    ///
    /// Strategy (zoom-aware):
    ///  1. If `range` is given (zoom active), binary-search the sorted array to
    ///     extract only the points inside the visible window.  For a tight zoom
    ///     this typically leaves < maxCount points → no downsampling needed →
    ///     **full resolution automatically**.
    ///  2. If the remaining point count still exceeds `maxCount`, apply
    ///     **min/max pooling**: each bucket keeps its lowest-V and highest-V
    ///     sample (in chronological order).  This preserves AP peaks that a
    ///     uniform stride would skip.
    ///
    /// The raw array is never mutated; `interpolated(_:at:)` continues to use
    /// it for accurate cursor value lookup.
    private func displayPoints(
        _ points: [SimulationViewModel.PlotPoint],
        in range: ClosedRange<Double>? = nil,
        maxCount: Int = 2_000
    ) -> [SimulationViewModel.PlotPoint] {

        // ── Step 1 : restrict to the visible time window ──────────────────
        let src: ArraySlice<SimulationViewModel.PlotPoint>
        if let r = range, !points.isEmpty {
            // Binary search for first point with t >= lowerBound
            var lo = 0, hi = points.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if points[mid].t < r.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            let startIdx = lo
            // Binary search for first point with t > upperBound
            lo = startIdx; hi = points.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if points[mid].t <= r.upperBound { lo = mid + 1 } else { hi = mid }
            }
            src = points[startIdx..<lo]
        } else {
            src = points[...]
        }

        // ── Step 2 : return as-is when already within the cap ────────────
        guard src.count > maxCount else { return Array(src) }

        // ── Step 3 : min/max pooling ──────────────────────────────────────
        let srcArr   = Array(src)
        let buckets  = maxCount / 2
        let bucketSz = srcArr.count / buckets
        var result   = [SimulationViewModel.PlotPoint]()
        result.reserveCapacity(maxCount + 2)

        for b in 0..<buckets {
            let lo    = b * bucketSz
            let hi    = Swift.min(lo + bucketSz, srcArr.count)
            var minPt = srcArr[lo]
            var maxPt = srcArr[lo]
            for i in (lo + 1)..<hi {
                if srcArr[i].v < minPt.v { minPt = srcArr[i] }
                if srcArr[i].v > maxPt.v { maxPt = srcArr[i] }
            }
            if minPt.t <= maxPt.t {
                result.append(minPt)
                if minPt.id != maxPt.id { result.append(maxPt) }
            } else {
                result.append(maxPt)
                if minPt.id != maxPt.id { result.append(minPt) }
            }
        }
        return result
    }

    private var chart: some View {
        Chart {
            ForEach(Array(traces.enumerated()), id: \.element.id) { idx, trace in
                let color = trace.color
                let pts   = displayPoints(trace.points, in: xZoom)  // full-res when zoomed
                ForEach(pts) { p in
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
                // Capture the domain at render time so gesture closures use the same
                // coordinate mapping that was used to render the chart they dragged on.
                // Direct interpolation avoids proxy.value(atX:) returning nil when the
                // chart has an explicitly-set domain but no actual data points.
                let capturedDomain = xDomain

                // ── Chart overlay ZStack ─────────────────────────────────────────
                //
                // Coordinate convention: the GeometryReader fills the chartOverlay,
                // its origin (0,0) is the top-left of the whole chart widget.
                // plotFrame (resolved by geo[$0]) is a CGRect in this same space, so
                // plotFrame.minX = left edge of the actual plot area, etc.
                //
                // To avoid the SwiftUI .local/.offset ambiguity that broke previous
                // zoom attempts, a SINGLE full-size Color.clear (no .offset) hosts
                // BOTH the DragGesture (zoom) and onContinuousHover (crosshair).
                // On a full-size view (0,0 origin in GeoReader), .local coords are
                // identical to GeoReader coords, so plotFrame math works directly.
                //
                // Y-axis handles are placed LAST so they are on top and receive
                // drag events in the gutter before the zoom surface does.
                ZStack(alignment: .topLeading) {

                    // ── Rubber-band selection rectangle ───────────────────────────
                    // selStartX / selCurrentX are in GeoReader space.
                    if let startX = selStartX {
                        let left         = min(startX, selCurrentX)
                        let right        = max(startX, selCurrentX)
                        let clampedLeft  = max(left,  plotFrame.minX)
                        let clampedRight = min(right, plotFrame.maxX)
                        if clampedRight > clampedLeft {
                            Rectangle()
                                .fill(Color.green.opacity(0.18))
                                .overlay(
                                    ZStack {
                                        Rectangle().fill(Color.green.opacity(0.7))
                                            .frame(width: 1.5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Rectangle().fill(Color.green.opacity(0.7))
                                            .frame(width: 1.5)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                )
                                .frame(width: clampedRight - clampedLeft,
                                       height: plotFrame.height)
                                .offset(x: clampedLeft, y: plotFrame.minY)
                                .allowsHitTesting(false)
                        }
                    }

                    // ── Combined hover + zoom surface ─────────────────────────────
                    // Full-size (no .offset) → .local == GeoReader coords.
                    // Zoom is gated on !vm.isRunning inside the handler so the
                    // cursor crosshair still works while the simulation runs.
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Hover: crosshair + value tooltip
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                guard selStartX == nil,
                                      loc.x >= plotFrame.minX, loc.x <= plotFrame.maxX,
                                      loc.y >= plotFrame.minY, loc.y <= plotFrame.maxY
                                else { cursorT = nil; cursorAbs = nil; return }
                                cursorAbs = CGPoint(x: loc.x, y: loc.y)
                                // proxy.value(atX:) wants plot-relative (0 = left edge)
                                cursorT = proxy.value(atX: loc.x - plotFrame.minX,
                                                      as: Double.self)
                            case .ended:
                                cursorT = nil; cursorAbs = nil
                            }
                        }
                        // Zoom: rubber-band drag (disabled while simulation runs)
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { val in
                                    // Ignore drags outside plot area or during simulation
                                    guard !vm.isRunning,
                                          val.startLocation.x >= plotFrame.minX,
                                          val.startLocation.x <= plotFrame.maxX
                                    else { return }
                                    cursorAbs = nil
                                    if selStartX == nil {
                                        selStartX = val.startLocation.x
                                    }
                                    selCurrentX = max(plotFrame.minX,
                                                      min(val.location.x, plotFrame.maxX))
                                }
                                .onEnded { _ in
                                    defer { selStartX = nil }
                                    guard !vm.isRunning,
                                          let startX = selStartX,
                                          abs(selCurrentX - startX) > 4,
                                          plotFrame.width > 0
                                    else { return }
                                    // GeoReader x → fraction [0,1] in plot area
                                    let loFrac = (min(startX, selCurrentX) - plotFrame.minX)
                                                 / plotFrame.width
                                    let hiFrac = (max(startX, selCurrentX) - plotFrame.minX)
                                                 / plotFrame.width
                                    let span = capturedDomain.upperBound
                                             - capturedDomain.lowerBound
                                    let t1 = capturedDomain.lowerBound + loFrac * span
                                    let t2 = capturedDomain.lowerBound + hiFrac * span
                                    if t2 > t1 { xZoom = t1...t2 }
                                }
                        )

                    // ── Cursor crosshair ─────────────────────────────────────────
                    if let loc = cursorAbs, selStartX == nil {
                        let dash = StrokeStyle(lineWidth: 1, dash: [4, 4])
                        Path { p in
                            p.move(to:    CGPoint(x: loc.x, y: plotFrame.minY))
                            p.addLine(to: CGPoint(x: loc.x, y: plotFrame.maxY))
                        }
                        .stroke(Color.white.opacity(0.5), style: dash)
                        .allowsHitTesting(false)
                        Path { p in
                            p.move(to:    CGPoint(x: plotFrame.minX, y: loc.y))
                            p.addLine(to: CGPoint(x: plotFrame.maxX, y: loc.y))
                        }
                        .stroke(Color.white.opacity(0.25), style: dash)
                        .allowsHitTesting(false)
                    }

                    // ── Cursor value label ────────────────────────────────────────
                    if let loc = cursorAbs, let t = cursorT, selStartX == nil {
                        let labelW: CGFloat = 148
                        let lineH:  CGFloat = 14
                        let labelH  = lineH + lineH * CGFloat(traces.count) + 10
                        let onRight = loc.x + 12 + labelW < plotFrame.maxX
                        let lx      = onRight ? loc.x + 12 : loc.x - 12 - labelW
                        let rawLY   = loc.y - labelH / 2
                        let ly      = max(plotFrame.minY + 2,
                                          min(rawLY, plotFrame.maxY - labelH - 2))
                        cursorValueLabel(t: t)
                            .position(x: lx + labelW / 2, y: ly + labelH / 2)
                            .allowsHitTesting(false)
                    }

                    // ── Y-axis handles — placed last = on top in ZStack ───────────
                    // Their DragGesture receives events in the y-axis gutter before
                    // the zoom surface does (no interference with plot-area dragging).
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

    // MARK: - Cursor helpers

    /// Multi-trace floating label: shows t + interpolated value for every trace.
    @ViewBuilder
    private func cursorValueLabel(t: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "t = %.2f ms", t))
                .foregroundStyle(.primary)
            ForEach(Array(traces.enumerated()), id: \.element.id) { _, trace in
                let v = interpolated(trace.points, at: t)
                let unit = trace.signal.unit.isEmpty ? "" : " \(trace.signal.unit)"
                HStack(spacing: 4) {
                    Circle()
                        .fill(trace.color)
                        .frame(width: 5, height: 5)
                    Text(v.map { String(format: "%.4g", $0) + unit } ?? "—")
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    /// Linear interpolation of `points` at time `t`.
    /// Returns the nearest boundary value when `t` is outside the range.
    private func interpolated(_ points: [SimulationViewModel.PlotPoint],
                               at t: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        if points.count == 1 { return points[0].v }
        if t <= points[0].t  { return points[0].v }
        let last = points[points.count - 1]
        if t >= last.t { return last.v }
        // Binary search for the bracketing pair
        var lo = 0, hi = points.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[lo + 1]
        let dt = b.t - a.t
        guard dt > 0 else { return a.v }
        return a.v + (b.v - a.v) * (t - a.t) / dt
    }

    // MARK: - Helpers

    private var xDomain: ClosedRange<Double> {
        if let z = xZoom { return z }
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
            let relPad = span * 0.12
            if relPad < 1e-9 {
                // All values identical — widen around the midpoint.
                // Use 10 % of the absolute value, or fall back to the
                // signal's suggested range width, or ±0.5 (mV-scale default).
                let mid = lo
                if let d = traces.first?.signal.suggestedYDomain {
                    let half = (d.upperBound - d.lowerBound) / 2
                    yMin = mid - half; yMax = mid + half
                } else {
                    let r = max(abs(mid) * 0.10, 0.5)
                    yMin = mid - r; yMax = mid + r
                }
            } else {
                yMin = lo - relPad
                yMax = hi + relPad
            }
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

// MARK: - Per-trace header row (small colour swatch + label + remove)

/// Owns the popover state so each row independently shows/hides its colour picker.
private struct TraceHeaderRow: View {
    @EnvironmentObject var vm: SimulationViewModel
    let trace: SimulationViewModel.SignalTrace
    let isFirst: Bool

    @State private var showColorPicker = false

    private var colorBinding: Binding<Color> {
        Binding<Color>(
            get: { vm.signalTraces.first(where: { $0.id == trace.id })?.color ?? trace.color },
            set: { newColor in
                if let i = vm.signalTraces.firstIndex(where: { $0.id == trace.id }) {
                    vm.signalTraces[i].color = newColor
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            // Small filled circle — tap to open colour picker in a popover
            Button {
                showColorPicker.toggle()
            } label: {
                Circle()
                    .fill(colorBinding.wrappedValue)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                ColorPicker("Couleur de la trace", selection: colorBinding)
                    .padding()
                    .frame(minWidth: 220)
            }

            // Label + unit
            HStack(spacing: 4) {
                Text(trace.label)
                    .font(.subheadline.weight(isFirst ? .medium : .regular))
                    .lineLimit(1)
                if !trace.signal.unit.isEmpty {
                    Text("[\(trace.signal.unit)]")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Remove button
            Button {
                vm.removeSignalTrace(id: trace.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.quaternary)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Supprimer cette trace")
        }
    }
}
