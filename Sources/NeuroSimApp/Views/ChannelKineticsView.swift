//
//  ChannelKineticsView.swift
//  NeuroSimApp
//
//  Sheet that plots and (optionally) edits an HH channel's gate steady-
//  state activation curves `x∞(V)` and time constants `τ(V)`.
//
//  View mode (default)
//  ───────────────────
//  Read-only Swift Charts plot of the *resolved* curves for every gate
//  of the channel. "Resolved" means the user override (if any) is
//  honoured; otherwise the channel's built-in HH formula is used.
//
//  Edit mode
//  ─────────
//  Toggle on with the "Edit" button. Edits target one gate at a time,
//  picked from the segmented gate selector. The user can:
//
//   - drag existing control points (default tool)
//   - add a control point by clicking on the chart (Add tool)
//   - remove a control point by clicking on it (Remove tool)
//   - translate the whole curve along V (Translate X) or y (Translate Y)
//   - switch the fit family between a 4-parameter sigmoid and a
//     polynomial of user-chosen degree
//   - import/export the control points as CSV
//
//  As long as the user is editing, the fitted curve is recomputed live
//  from the current control points and shown in bold; the built-in
//  formula is overlaid as a faded reference line. Pressing Apply writes
//  the fitted `GateCurve` into the channel's override slot, which the
//  integrator picks up on its next state evaluation.
//

import SwiftUI
import Charts
import NeuroSimCore
import AppKit
import UniformTypeIdentifiers

struct ChannelKineticsView: View {

    // MARK: - Public API

    enum Mode {
        case steadyState   // edit / view  x∞(V)
        case kinetics      // edit / view  τ(V)
    }

    let channel: HHGated
    let mode: Mode

    // MARK: - Environment

    @EnvironmentObject private var vm: SimulationViewModel
    @Environment(\.dismiss)    private var dismiss

    // MARK: - View / edit state

    @State private var isEditing: Bool = false
    @State private var selectedGateIndex: Int = 0
    @State private var fitMethod: FitMethod = .sigmoid
    @State private var polynomialDegree: Int = 3
    @State private var activeEditTool: EditTool = .move
    @State private var controlPoints: [ControlPoint] = []
    @State private var draggingPointID: UUID? = nil
    @State private var translateAnchor: [ControlPoint]? = nil
    @State private var history: [[ControlPoint]] = []   // for undo

    // Axis range — user-adjustable via the corner triangle handles.
    // Initialised from `defaultXRange()` / `defaultYRange()` on appear.
    @State private var xMin: Double = -100
    @State private var xMax: Double =  50
    @State private var yMin: Double = 0
    @State private var yMax: Double = 1
    @State private var axesInitialised: Bool = false

    /// Drag context for the axis handles. Captured at drag-start so the
    /// pixel→value conversion stays stable for the duration of a drag,
    /// even though the chart re-renders as we change xMin/xMax/yMin/yMax.
    @State private var axisDragStart: AxisDragSnapshot? = nil

    /// Number of voltage samples used to render the fitted / built-in
    /// curves smoothly.
    private let curveSampleCount = 200
    /// Hit radius for clicks on control points, in chart-view points.
    private let hitRadius: CGFloat = 12

    /// `vRange` lookalike, but live — derived from the @State axis
    /// limits so all the existing sampling helpers can keep using a
    /// single property.
    private var vRange: ClosedRange<Double> { xMin...xMax }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isEditing {
                editingControls
                toolPalette
            }

            chart
                .frame(minWidth: 600, minHeight: 380)

            if isEditing {
                editFooter
            } else {
                viewFooter
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .onAppear {
            if !axesInitialised {
                let xr = defaultXRange()
                let yr = defaultYRange()
                xMin = xr.lowerBound; xMax = xr.upperBound
                yMin = yr.lowerBound; yMax = yr.upperBound
                axesInitialised = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isEditing {
                Button {
                    cancelEditing()
                } label: {
                    Label("Cancel edit", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    enterEditMode()
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        switch mode {
        case .steadyState: return "\(channel.name) — steady-state activation"
        case .kinetics:    return "\(channel.name) — gating time constants"
        }
    }

    private var subtitle: String {
        let gates = channel.gateNames.joined(separator: ", ")
        switch mode {
        case .steadyState: return "x∞(V) for gates: \(gates)"
        case .kinetics:    return "τ(V) for gates: \(gates)  ·  ms"
        }
    }

    // MARK: - Editing controls (gate / method picker)

    private var editingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if channel.gateNames.count > 1 {
                    Picker("Gate", selection: $selectedGateIndex) {
                        ForEach(0..<channel.gateNames.count, id: \.self) { i in
                            Text(channel.gateNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                    .onChange(of: selectedGateIndex) { _, _ in
                        seedControlPoints()
                    }
                }

                Picker("Method", selection: $fitMethod) {
                    Text("Sigmoid").tag(FitMethod.sigmoid)
                    Text("Polynomial").tag(FitMethod.polynomial)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                if fitMethod == .polynomial {
                    Stepper(value: $polynomialDegree,
                            in: 1...8) {
                        Text("Degree: \(polynomialDegree)")
                            .font(.caption)
                            .frame(minWidth: 80, alignment: .leading)
                    }
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                }

                Spacer()
            }
        }
    }

    // MARK: - Tool palette

    private var toolPalette: some View {
        HStack(spacing: 4) {
            toolButton(.move, image: "hand.draw", help: "Move points")
            toolButton(.add, image: "plus.circle", help: "Add point on click")
            toolButton(.remove, image: "minus.circle", help: "Remove point on click")
            toolButton(.translateX, image: "arrow.left.and.right",
                       help: "Drag to translate the whole curve along V")
            toolButton(.translateY, image: "arrow.up.and.down",
                       help: "Drag to translate the whole curve along y")

            Divider().frame(height: 22).padding(.horizontal, 4)

            iconButton("arrow.uturn.backward", help: "Undo last edit",
                       enabled: history.count > 1) { undo() }
            iconButton("arrow.counterclockwise", help: "Reset control points to current curve") {
                seedControlPoints()
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            iconButton("square.and.arrow.up", help: "Export points as CSV") { exportCSV() }
            iconButton("square.and.arrow.down", help: "Import points from CSV") { importCSV() }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolButton(_ tool: EditTool,
                            image: String,
                            help: String) -> some View {
        let isActive = activeEditTool == tool
        return Button { activeEditTool = tool } label: {
            Image(systemName: image)
                .frame(width: 26, height: 26)
                .foregroundStyle(isActive ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ image: String,
                            help: String,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            // Built-in (faded reference) — only shown in edit mode for the
            // gate being edited, so users can compare against the original.
            if isEditing {
                ForEach(builtinSamples(forGate: selectedGateIndex)) { p in
                    LineMark(
                        x: .value("V (mV)", p.v),
                        y: .value(yLabel,    p.y)
                    )
                    .foregroundStyle(by: .value("Curve", "built-in (\(channel.gateNames[selectedGateIndex]))"))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .interpolationMethod(.catmullRom)
                }
            }

            // Resolved curves for every gate. In view mode, this is the
            // primary content. In edit mode, gates other than the
            // selected one are kept on screen as context.
            ForEach(0..<channel.gateNames.count, id: \.self) { i in
                let isFocus = isEditing && i == selectedGateIndex
                ForEach(resolvedSamples(forGate: i)) { p in
                    LineMark(
                        x: .value("V (mV)", p.v),
                        y: .value(yLabel,    p.y)
                    )
                    .foregroundStyle(by: .value("Curve", labelFor(channel.gateNames[i])))
                    .lineStyle(StrokeStyle(lineWidth: isFocus ? 0.8 : 2.0))
                    .opacity(isEditing ? (isFocus ? 0.35 : 1.0) : 1.0)
                    .interpolationMethod(.catmullRom)
                }
            }

            // Live fit overlay (edit mode).
            if isEditing, let curve = fittedCurve {
                ForEach(sampleCurve(curve)) { p in
                    LineMark(
                        x: .value("V (mV)", p.v),
                        y: .value(yLabel,    p.y)
                    )
                    .foregroundStyle(by: .value("Curve", "fit (\(fitMethod.label))"))
                    .lineStyle(StrokeStyle(lineWidth: 2.6))
                    .interpolationMethod(.catmullRom)
                }
            }

            // Control points (edit mode only).
            if isEditing {
                ForEach(controlPoints) { p in
                    PointMark(
                        x: .value("V (mV)", p.v),
                        y: .value(yLabel,    p.y)
                    )
                    .symbolSize(120)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .chartXScale(domain: vRange.lowerBound...vRange.upperBound)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) {
                AxisGridLine(); AxisTick(); AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) {
                AxisGridLine(); AxisTick(); AxisValueLabel()
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .chartOverlay { proxy in
            // Transparent overlay capturing taps and drags.
            // Editing rectangle catches clicks/drags inside the plot area
            // (only does anything in edit mode); the four corner triangles
            // catch their own drags to adjust the visible axis range.
            GeometryReader { geo in
                // `plotAreaFrame` was renamed to `plotFrame` (Optional) in macOS 14.
// During initial layout the chart may not have a frame yet, so we
// fall back to .zero to keep the math safe.
let plotFrame: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero

                ZStack(alignment: .topLeading) {
                    // Editing surface: full chart-overlay area (so the
                    // existing chartValue helpers, which expect geo-space
                    // coordinates, still work). The four axis handles
                    // drawn on top of this rectangle take hit-test
                    // priority because they're later in the ZStack.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard isEditing else { return }
                                    handleDragChanged(value: value, proxy: proxy, geo: geo)
                                }
                                .onEnded { value in
                                    guard isEditing else { return }
                                    handleDragEnded(value: value, proxy: proxy, geo: geo)
                                }
                        )

                    // Axis range handles (always visible — even in view
                    // mode, since adjusting the visible range is useful
                    // for inspection too).
                    axisHandle(.xMin, plotFrame: plotFrame, proxy: proxy)
                    axisHandle(.xMax, plotFrame: plotFrame, proxy: proxy)
                    axisHandle(.yMin, plotFrame: plotFrame, proxy: proxy)
                    axisHandle(.yMax, plotFrame: plotFrame, proxy: proxy)
                }
            }
        }
    }

    // MARK: - Axis handles

    /// Build a single triangular axis handle for the given edge.
    @ViewBuilder
    private func axisHandle(_ edge: AxisEdge,
                            plotFrame: CGRect,
                            proxy: ChartProxy) -> some View {
        let size: CGFloat = 12
        let isDragging = (axisDragStart != nil)
        let color: Color = isDragging ? Color.accentColor : Color.secondary.opacity(0.7)

        // Handles sit at the *middle* of each axis (not the extremities)
        // so they're easier to find at a glance, with both members of a
        // pair side-by-side and pointing outward — toward the direction
        // a drag would extend the visible range.
        //
        //                     ▲  yMax
        //                     ▼  yMin
        //   ┌─────── plot area ────────┐
        //   └──────────────────────────┘
        //                  ◀ ▶
        //                xMin xMax
        //
        // The offsets push the triangles past the axis labels so they
        // never overlap a tick value (e.g. "0,4" on the y axis or "−50"
        // on the x axis). 36 px clears typical numeric labels in the
        // chart's default font; 28 px below clears the bottom labels.
        let yGutter: CGFloat = 36
        let xGutter: CGFloat = 28
        let placement: (point: CGPoint, direction: AxisTriangle.Direction) = {
            switch edge {
            case .xMin:
                return (CGPoint(x: plotFrame.midX - 10, y: plotFrame.maxY + xGutter), .left)
            case .xMax:
                return (CGPoint(x: plotFrame.midX + 10, y: plotFrame.maxY + xGutter), .right)
            case .yMin:
                return (CGPoint(x: plotFrame.minX - yGutter, y: plotFrame.midY + 10), .down)
            case .yMax:
                return (CGPoint(x: plotFrame.minX - yGutter, y: plotFrame.midY - 10), .up)
            }
        }()

        AxisTriangle(direction: placement.direction)
            .fill(color)
            .frame(width: size, height: size)
            // A larger transparent hit-area sits behind the visible
            // triangle so users can grab the handle even with a few
            // pixels of imprecision.
            .background(
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: size + 14, height: size + 14)
            )
            .position(placement.point)
            .gesture(axisDragGesture(for: edge, proxy: proxy))
            .help(handleHelp(edge))
    }

    private func handleHelp(_ edge: AxisEdge) -> String {
        switch edge {
        case .xMin: return "Drag to adjust V min"
        case .xMax: return "Drag to adjust V max"
        case .yMin: return "Drag to adjust y min"
        case .yMax: return "Drag to adjust y max"
        }
    }

    private func axisDragGesture(for edge: AxisEdge,
                                 proxy: ChartProxy) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if axisDragStart == nil {
                    axisDragStart = makeAxisDragSnapshot(proxy: proxy)
                }
                guard let snap = axisDragStart else { return }
                applyAxisDrag(edge: edge, snapshot: snap, value: value)
            }
            .onEnded { _ in
                axisDragStart = nil
            }
    }

    /// Capture the current axis state and the pixel↔value scales so the
    /// drag delta can be converted to value units without re-querying
    /// the proxy each tick (whose answer drifts as we update the axis).
    private func makeAxisDragSnapshot(proxy: ChartProxy) -> AxisDragSnapshot {
        let p0 = proxy.position(forX: xMin) ?? 0
        let p1 = proxy.position(forX: xMax) ?? 1
        // Avoid divide-by-zero if the chart hasn't laid out yet.
        let pxPerV = (xMax - xMin) > 1e-9
            ? (p1 - p0) / (xMax - xMin)
            : 1
        let py0 = proxy.position(forY: yMin) ?? 0
        let py1 = proxy.position(forY: yMax) ?? 1
        let pxPerY = (yMax - yMin) > 1e-9
            ? (py1 - py0) / (yMax - yMin)   // negative (y axis inverted on screen)
            : -1
        return AxisDragSnapshot(xMin: xMin, xMax: xMax,
                                yMin: yMin, yMax: yMax,
                                pxPerV: pxPerV, pxPerY: pxPerY)
    }

    private func applyAxisDrag(edge: AxisEdge,
                               snapshot snap: AxisDragSnapshot,
                               value: DragGesture.Value) {
        let dxValue = snap.pxPerV != 0
            ? value.translation.width / snap.pxPerV
            : 0
        let dyValue = snap.pxPerY != 0
            ? value.translation.height / snap.pxPerY
            : 0

        switch edge {
        case .xMin:
            // Don't let xMin cross xMax (keep ≥ 1 mV of separation).
            xMin = min(snap.xMax - 1, max(-1000, snap.xMin + dxValue))
        case .xMax:
            xMax = max(snap.xMin + 1, min(1000, snap.xMax + dxValue))
        case .yMin:
            // pxPerY is negative, so dyValue's sign already follows the
            // intuitive "drag up = increase y".
            let lowerLimit: Double = (mode == .kinetics) ? 0 : -1000
            yMin = min(snap.yMax - 1e-3,
                       max(lowerLimit, snap.yMin + dyValue))
        case .yMax:
            yMax = max(snap.yMin + 1e-3,
                       min(10_000, snap.yMax + dyValue))
        }
    }


    private var yLabel: String {
        switch mode {
        case .steadyState: return "x∞"
        case .kinetics:    return "τ (ms)"
        }
    }

    /// Live y-domain — driven by the user-adjustable handles.
    private var yDomain: ClosedRange<Double> { yMin...yMax }

    /// Default y range used when the view first appears; tuned to fit
    /// the channel's actual built-in / overridden curves rather than
    /// blindly assuming `[0, 1]` for kinetics.
    private func defaultYRange() -> ClosedRange<Double> {
        switch mode {
        case .steadyState:
            return 0...1
        case .kinetics:
            let allYs = (0..<channel.gateNames.count).flatMap { i in
                resolvedSamples(forGate: i).map(\.y)
            }
            let lo = max(0, (allYs.min() ?? 0) * 0.9)
            let hi = (allYs.max() ?? 1) * 1.1
            return lo...max(hi, lo + 1)
        }
    }

    /// Default x range — wide enough to show all of HH dynamics.
    private func defaultXRange() -> ClosedRange<Double> { -100...50 }

    private func labelFor(_ gate: String) -> String {
        switch mode {
        case .steadyState: return "\(gate)∞"
        case .kinetics:    return "τ_\(gate)"
        }
    }

    // MARK: - Footers

    private var viewFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Click \"Edit\" to override the curve graphically. The simulation will use your edits at the next reset.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var editFooter: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                resetOverride()
            } label: {
                Label("Reset to built-in", systemImage: "arrow.counterclockwise.circle")
            }
            Spacer()
            Button("Cancel") { cancelEditing() }
                .buttonStyle(.bordered)
            Button {
                applyOverride()
            } label: {
                Label("Apply", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(fittedCurve == nil)
        }
    }

    // MARK: - Sampling helpers

    struct Sample: Identifiable {
        let v: Double
        let y: Double
        var id: Double { v }
    }

    /// Built-in (un-overridden) curve for `gateIndex`, sampled across `vRange`.
    private func builtinSamples(forGate gateIndex: Int) -> [Sample] {
        let lo = vRange.lowerBound, hi = vRange.upperBound
        let dv = (hi - lo) / Double(curveSampleCount)
        return (0...curveSampleCount).map { i in
            let v = lo + Double(i) * dv
            let y: Double
            switch mode {
            case .steadyState: y = channel.gateInf(gateIndex, voltage: v)
            case .kinetics:    y = channel.gateTau(gateIndex, voltage: v)
            }
            return Sample(v: v, y: y)
        }
    }

    /// Resolved (override-aware) curve for `gateIndex`, sampled across
    /// `vRange`. This is what the integrator effectively uses.
    private func resolvedSamples(forGate gateIndex: Int) -> [Sample] {
        let lo = vRange.lowerBound, hi = vRange.upperBound
        let dv = (hi - lo) / Double(curveSampleCount)
        return (0...curveSampleCount).map { i in
            let v = lo + Double(i) * dv
            let y: Double
            switch mode {
            case .steadyState: y = channel.resolvedGateInf(gateIndex, voltage: v)
            case .kinetics:    y = channel.resolvedGateTau(gateIndex, voltage: v)
            }
            return Sample(v: v, y: y)
        }
    }

    private func sampleCurve(_ curve: GateCurve) -> [Sample] {
        let lo = vRange.lowerBound, hi = vRange.upperBound
        let dv = (hi - lo) / Double(curveSampleCount)
        // Use compactMap so out-of-domain samples are dropped — the
        // chart's LineMark won't draw across a missing segment, so the
        // fitted curve appears only between the leftmost and rightmost
        // control points (no Runge tails outside).
        return (0...curveSampleCount).compactMap { i in
            let v = lo + Double(i) * dv
            guard let y = curve.evaluate(at: v) else { return nil }
            return Sample(v: v, y: y)
        }
    }

    // MARK: - Live fit

    /// Curve fitted to the current control points using the active method.
    /// `nil` if the points are insufficient or the fit fails to converge.
    private var fittedCurve: GateCurve? {
        let pts = controlPoints
            .sorted { $0.v < $1.v }
            .map { (v: $0.v, y: $0.y) }
        switch fitMethod {
        case .sigmoid:
            return CurveFitter.fitSigmoid(points: pts)
        case .polynomial:
            return CurveFitter.fitPolynomial(points: pts, degree: polynomialDegree)
        }
    }

    // MARK: - Edit-mode lifecycle

    private func enterEditMode() {
        seedControlPoints()
        history = [controlPoints]
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        translateAnchor = nil
        draggingPointID = nil
    }

    private func applyOverride() {
        guard let curve = fittedCurve else { return }
        switch mode {
        case .steadyState:
            channel.gateInfOverrides[selectedGateIndex] = curve
        case .kinetics:
            channel.gateTauOverrides[selectedGateIndex] = curve
        }
        // Tell the rest of the UI to redraw — the channel object itself
        // is a class so its mutation isn't picked up by SwiftUI's value
        // tracking. The viewmodel's objectWillChange is what drives the
        // inspector / canvas refresh.
        vm.objectWillChange.send()
        isEditing = false
    }

    /// Wipe the override back to nil for the currently selected gate, so
    /// the integrator falls back to the channel's hard-coded HH formula.
    private func resetOverride() {
        switch mode {
        case .steadyState:
            channel.gateInfOverrides[selectedGateIndex] = nil
        case .kinetics:
            channel.gateTauOverrides[selectedGateIndex] = nil
        }
        vm.objectWillChange.send()
        // Re-seed control points from the now-built-in curve, so further
        // edits start from there.
        seedControlPoints()
        history = [controlPoints]
    }

    /// Seed control points by sampling the resolved curve for the
    /// selected gate at evenly-spaced voltages.
    private func seedControlPoints() {
        let nSeed = 7
        let lo = vRange.lowerBound, hi = vRange.upperBound
        let dv = (hi - lo) / Double(nSeed - 1)
        controlPoints = (0..<nSeed).map { i in
            let v = lo + Double(i) * dv
            let y: Double
            switch mode {
            case .steadyState: y = channel.resolvedGateInf(selectedGateIndex, voltage: v)
            case .kinetics:    y = channel.resolvedGateTau(selectedGateIndex, voltage: v)
            }
            return ControlPoint(id: UUID(), v: v, y: y)
        }
    }

    private func pushHistory() {
        history.append(controlPoints)
        if history.count > 64 { history.removeFirst() }
    }

    private func undo() {
        guard history.count > 1 else { return }
        history.removeLast()
        controlPoints = history.last ?? []
    }

    // MARK: - Gestures

    /// Convert a point in the chart-overlay's local coordinate space to
    /// chart values `(V, y)`. Returns nil if outside the plot area or if
    /// the chart proxy can't resolve the value.
    private func chartValue(at location: CGPoint,
                            proxy: ChartProxy,
                            geo: GeometryProxy) -> (v: Double, y: Double)? {
        // `plotAreaFrame` was renamed to `plotFrame` (Optional) in macOS 14.
// During initial layout the chart may not have a frame yet, so we
// fall back to .zero to keep the math safe.
let plotFrame: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero
        let xInPlot = location.x - plotFrame.origin.x
        let yInPlot = location.y - plotFrame.origin.y
        guard xInPlot >= 0, xInPlot <= plotFrame.width,
              yInPlot >= 0, yInPlot <= plotFrame.height
        else { return nil }
        guard let v: Double = proxy.value(atX: xInPlot),
              let y: Double = proxy.value(atY: yInPlot)
        else { return nil }
        return (v, y)
    }

    /// Compute the screen-space distance (in points) between a control
    /// point and a location in the chart-overlay's local coordinates.
    private func screenDistance(from location: CGPoint,
                                to point: ControlPoint,
                                proxy: ChartProxy,
                                geo: GeometryProxy) -> CGFloat {
        // `plotAreaFrame` was renamed to `plotFrame` (Optional) in macOS 14.
// During initial layout the chart may not have a frame yet, so we
// fall back to .zero to keep the math safe.
let plotFrame: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero
        guard let px = proxy.position(forX: point.v),
              let py = proxy.position(forY: point.y)
        else { return .greatestFiniteMagnitude }
        let dx = location.x - (plotFrame.origin.x + px)
        let dy = location.y - (plotFrame.origin.y + py)
        return sqrt(dx * dx + dy * dy)
    }

    private func nearestPointID(to location: CGPoint,
                                proxy: ChartProxy,
                                geo: GeometryProxy) -> UUID? {
        var best: (id: UUID, d: CGFloat)? = nil
        for p in controlPoints {
            let d = screenDistance(from: location, to: p, proxy: proxy, geo: geo)
            if d < (best?.d ?? .greatestFiniteMagnitude) {
                best = (p.id, d)
            }
        }
        guard let b = best, b.d < hitRadius else { return nil }
        return b.id
    }

    private func handleDragChanged(value: DragGesture.Value,
                                   proxy: ChartProxy,
                                   geo: GeometryProxy) {
        // First drag tick: decide what we're doing based on the tool and
        // whether a point sits under the start location.
        if draggingPointID == nil && translateAnchor == nil {
            // Distinguish: tap-with-no-drag is handled in onEnded.
            let movedFar = abs(value.translation.width) > 2 ||
                           abs(value.translation.height) > 2
            guard movedFar else { return }

            switch activeEditTool {
            case .move:
                if let id = nearestPointID(to: value.startLocation,
                                           proxy: proxy, geo: geo) {
                    draggingPointID = id
                    pushHistory()
                }
            case .translateX, .translateY:
                translateAnchor = controlPoints
                pushHistory()
            case .add, .remove:
                // These are click actions, not drag actions.
                break
            }
        }

        // Continuous update.
        if let id = draggingPointID,
           let (v, y) = chartValue(at: value.location, proxy: proxy, geo: geo),
           let i = controlPoints.firstIndex(where: { $0.id == id }) {
            controlPoints[i].v = v
            controlPoints[i].y = clampToYDomain(y)
        }

        if let anchor = translateAnchor {
            // Map drag pixels → chart units via the proxy's identity at 0
            // and 1 (or any two voltages).
            let pxAtA = proxy.position(forX: 0.0) ?? 0
            let pxAtB = proxy.position(forX: 100.0) ?? 100
            let pxPerVoltUnit = (pxAtB - pxAtA) / 100.0
            let pyAtA = proxy.position(forY: yDomain.lowerBound) ?? 0
            let pyAtB = proxy.position(forY: yDomain.upperBound) ?? 1
            let pxPerYUnit = (pyAtB - pyAtA) /
                (yDomain.upperBound - yDomain.lowerBound)

            switch activeEditTool {
            case .translateX:
                let dv = pxPerVoltUnit != 0
                    ? value.translation.width / pxPerVoltUnit
                    : 0
                controlPoints = anchor.map { p in
                    var q = p; q.v = p.v + dv; return q
                }
            case .translateY:
                let dy = pxPerYUnit != 0
                    ? value.translation.height / pxPerYUnit
                    : 0
                controlPoints = anchor.map { p in
                    var q = p; q.y = clampToYDomain(p.y + dy); return q
                }
            default:
                break
            }
        }
    }

    private func handleDragEnded(value: DragGesture.Value,
                                 proxy: ChartProxy,
                                 geo: GeometryProxy) {
        let movedFar = abs(value.translation.width) > 2 ||
                       abs(value.translation.height) > 2

        if !movedFar {
            // Treat as a click.
            handleClick(at: value.location, proxy: proxy, geo: geo)
        }

        if draggingPointID != nil || translateAnchor != nil {
            // Final state is now the new history entry.
            pushHistory()
        }
        draggingPointID = nil
        translateAnchor = nil
    }

    private func handleClick(at location: CGPoint,
                             proxy: ChartProxy,
                             geo: GeometryProxy) {
        switch activeEditTool {
        case .add:
            guard let (v, y) = chartValue(at: location, proxy: proxy, geo: geo)
            else { return }
            controlPoints.append(ControlPoint(id: UUID(),
                                              v: v,
                                              y: clampToYDomain(y)))
            pushHistory()
        case .remove:
            if let id = nearestPointID(to: location, proxy: proxy, geo: geo) {
                controlPoints.removeAll { $0.id == id }
                pushHistory()
            }
        case .move, .translateX, .translateY:
            // No-op on click.
            break
        }
    }

    private func clampToYDomain(_ y: Double) -> Double {
        switch mode {
        case .steadyState: return min(max(y, 0), 1)
        case .kinetics:    return max(y, 1e-3)
        }
    }

    // MARK: - CSV import / export

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue =
            "\(channel.name)_\(channel.gateNames[selectedGateIndex])_\(modeFileSuffix).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = [
            "# NeuroSim curve export",
            "# channel: \(channel.name)",
            "# gate: \(channel.gateNames[selectedGateIndex])",
            "# mode: \(modeFileSuffix)",
            "# fit: \(fittedCurveDescription)",
            "v,y",
        ]
        for p in controlPoints.sorted(where: { $0.v < $1.v }) {
            lines.append(String(format: "%.6f,%.9f", p.v, p.y))
        }
        try? lines.joined(separator: "\n").write(to: url,
                                                 atomically: true,
                                                 encoding: .utf8)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed: [ControlPoint] = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return nil }
                if trimmed.hasPrefix("#") { return nil }
                if trimmed.lowercased().hasPrefix("v,") { return nil } // header row
                let parts = trimmed.split(separator: ",")
                guard parts.count >= 2,
                      let v = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                      let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
                else { return nil }
                return ControlPoint(id: UUID(), v: v, y: clampToYDomain(y))
            }
        guard !parsed.isEmpty else { return }
        controlPoints = parsed.sorted { $0.v < $1.v }
        pushHistory()
    }

    private var fittedCurveDescription: String {
        guard let curve = fittedCurve else { return "n/a" }
        let domainSuffix: String
        if let d = curve.validDomain {
            domainSuffix = String(format: " domain=[%.4f, %.4f]", d.lowerBound, d.upperBound)
        } else {
            domainSuffix = ""
        }
        switch curve {
        case let .sigmoid(lo, hi, vHalf, k, _):
            return String(format: "sigmoid lo=%.4f hi=%.4f vHalf=%.4f k=%.4f",
                          lo, hi, vHalf, k) + domainSuffix
        case let .polynomial(c, vCenter, _):
            let coefs = c.enumerated().map { String(format: "c%d=%.6g", $0.offset, $0.element) }
                .joined(separator: " ")
            return "polynomial vCenter=\(String(format: "%.4f", vCenter)) \(coefs)" + domainSuffix
        }
    }

    private var modeFileSuffix: String {
        switch mode {
        case .steadyState: return "xinf"
        case .kinetics:    return "tau"
        }
    }
}

// MARK: - Supporting types (kept private to this file)

extension ChannelKineticsView {

    enum FitMethod: Hashable {
        case sigmoid
        case polynomial
        var label: String {
            switch self {
            case .sigmoid:    return "sigmoid"
            case .polynomial: return "poly"
            }
        }
    }

    enum EditTool: Hashable {
        case move        // drag existing points
        case add         // click adds a new point
        case remove      // click removes the nearest point
        case translateX  // drag shifts the whole curve in V
        case translateY  // drag shifts the whole curve in y
    }

    struct ControlPoint: Identifiable, Equatable {
        let id: UUID
        var v: Double
        var y: Double
    }

    /// Captured at axis-handle drag-start; used to convert drag pixels
    /// into chart-value deltas without drift as the chart re-renders.
    struct AxisDragSnapshot {
        let xMin: Double
        let xMax: Double
        let yMin: Double
        let yMax: Double
        let pxPerV: Double  // points per mV
        let pxPerY: Double  // points per y-unit (negative because y axis is inverted)
    }

    /// Which axis edge a triangular handle controls.
    enum AxisEdge {
        case xMin, xMax, yMin, yMax
    }
}

/// Small triangular handle drawn at an axis edge of the chart.
/// `direction` says where the tip points, which is also the direction
/// that drags it "extends" the visible range.
struct AxisTriangle: Shape {
    enum Direction { case up, down, left, right }
    let direction: Direction

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch direction {
        case .up:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        case .down:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .left:
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        case .right:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        p.closeSubpath()
        return p
    }
}

private extension Array {
    func sorted(where areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        sorted(by: areInIncreasingOrder)
    }
}
