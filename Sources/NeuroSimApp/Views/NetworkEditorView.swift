//
//  NetworkEditorView.swift
//  NeuroSimApp
//
//  Graphical editor for the neural network.
//
//  Mouse interaction is conditioned by the active tool from the left
//  palette (`vm.activeTool`):
//
//   - .select          : click to select neuron / synapse / nothing,
//                        drag a neuron to move it.
//   - .pan             : (placeholder — viewport panning not yet wired)
//   - .addNeuron       : click an empty area to add a neuron at the click
//                        site.
//   - .addCompartment  : click a neuron to append a compartment to it.
//   - .synapse         : drag from one neuron onto another to create a
//                        chemical synapse.
//   - .axialCoupling   : (placeholder — meaningful only when compartments
//                        are visualised on the canvas).
//   - .stimulus        : click a neuron to drop a default pulse stimulus
//                        on its soma.
//   - .probe           : (placeholder — future hook into the Plots window).
//
//  Live state: each neuron's fill colour reflects its instantaneous
//  membrane potential (blue = hyperpolarised, white ~ rest, red = spiking).
//

import SwiftUI
import NeuroSimCore

// MARK: - Canvas constants

/// Visible radius of a neuron in canvas points. Shared between the node
/// renderer and the synapse renderer so curves and dots align with the
/// circle edges.
private let kNeuronRadius: CGFloat = 32

/// Radius of the small post-synaptic indicator dot.
private let kSynapseDotRadius: CGFloat = 7

struct NetworkEditorView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @State private var draftSynapse: DraftSynapse? = nil

    struct DraftSynapse {
        let fromID: UUID
        var currentPoint: CGPoint
    }

    var body: some View {
        canvas
            // Fill whatever space the parent (NavigationSplitView's content
            // column) gives us — without this the canvas collapses to its
            // intrinsic size and the focus ring stops short of the column
            // edges.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                // Background: catches clicks on empty space. We use the
                // location-aware overload so the .addNeuron tool can place
                // neurons exactly where the user clicks, not at canvas centre.
                Color(NSColor.textBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        handleCanvasTap(at: location)
                    }

                // Edges (drawn first so neurons sit on top)
                ForEach(vm.network.synapses, id: \.id) { syn in
                    SynapseEdgeView(synapse: syn)
                }

                // Draft connection arrow (during synapse-tool drag)
                if let draft = draftSynapse,
                   let from = vm.network.neurons.first(where: { $0.id == draft.fromID }) {
                    DraftEdgeShape(
                        from: CGPoint(x: from.positionX, y: from.positionY),
                        to: draft.currentPoint
                    )
                    .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }

                // Nodes
                ForEach(vm.network.neurons, id: \.id) { neuron in
                    NeuronNodeView(neuron: neuron, draftSynapse: $draftSynapse)
                }
            }
            .focusable()
            .onKeyPress(.delete) { vm.removeSelected(); return .handled }
            .onKeyPress(.deleteForward) { vm.removeSelected(); return .handled }
        }
    }

    // MARK: - Tool dispatch

    private func handleCanvasTap(at location: CGPoint) {
        switch vm.activeTool {
        case .select, .pan:
            vm.selection = .none
        case .addNeuron:
            vm.addNeuron(at: Double(location.x), y: Double(location.y))
        case .addCompartment, .synapseExcitatory, .synapseInhibitory,
             .gapJunction, .axialCoupling, .stimulus, .probe:
            // Empty-canvas click is meaningless for tools that act on a
            // neuron — fall back to clearing the selection so it isn't
            // confusing.
            vm.selection = .none
        }
    }
}

// MARK: - Neuron node

private struct NeuronNodeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    @Binding var draftSynapse: NetworkEditorView.DraftSynapse?

    /// Captured at gesture start so we can interpret `value.translation`
    /// (which is cumulative since drag start) as an absolute offset.
    @State private var dragOrigin: CGPoint? = nil

    private var radius: CGFloat { kNeuronRadius }

    var body: some View {
        let isSelected = vm.selection == .neuron(neuron.id)
        let v = vm.traces[neuron.id]?.last?.v ?? -65.0

        ZStack {
            Circle()
                .fill(activityColor(v: v))
                .overlay(
                    Circle().stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.75),
                                    lineWidth: isSelected ? 3 : 1.5)
                )
                .shadow(color: v > 0 ? .red.opacity(0.7) : .clear, radius: 10)
                .frame(width: radius * 2, height: radius * 2)

            VStack(spacing: 1) {
                Text(neuron.name)
                    .font(.system(.caption, design: .rounded).bold())
                Text(String(format: "%.0f", v))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        // Read from positionX/Y directly — we update them live during drag,
        // so the connected synapse arrows follow the node in real time.
        .position(
            x: CGFloat(neuron.positionX),
            y: CGFloat(neuron.positionY)
        )
        .gesture(nodeGesture)
        .onTapGesture { handleNeuronTap() }
    }

    // MARK: - Tool dispatch (per-node)

    private func handleNeuronTap() {
        switch vm.activeTool {
        case .select, .pan, .addNeuron,
             .synapseExcitatory, .synapseInhibitory, .gapJunction,
             .axialCoupling:
            // All of these select-on-tap; the actual tool action happens
            // on drag (synapse, axial, gap junction) or empty-canvas click
            // (addNeuron).
            vm.selection = .neuron(neuron.id)
        case .addCompartment:
            _ = vm.addCompartment(to: neuron.id)
            vm.selection = .neuron(neuron.id)
        case .stimulus:
            // Drop a default pulse stimulus on the neuron's soma. The user
            // can refine parameters in the inspector right after.
            let pulse = PulseStimulus(start: 10, duration: 50, amplitude: 10)
            vm.setStimulus(pulse, onCompartment: neuron.somaCompartmentID)
            vm.selection = .neuron(neuron.id)
        case .probe:
            // Placeholder: in the future this will add the neuron's V(t)
            // (or a chosen variable) as a trace in the Plots window.
            vm.selection = .neuron(neuron.id)
        }
    }

    private var nodeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let tool = vm.activeTool
                if tool == .select {
                    if dragOrigin == nil {
                        dragOrigin = CGPoint(x: neuron.positionX, y: neuron.positionY)
                    }
                    let origin = dragOrigin ?? .zero
                    vm.setNeuronPosition(
                        neuron.id,
                        x: Double(origin.x) + Double(value.translation.width),
                        y: Double(origin.y) + Double(value.translation.height)
                    )
                } else if tool.isSynapseTool {
                    let origin = CGPoint(x: neuron.positionX, y: neuron.positionY)
                    let current = CGPoint(
                        x: origin.x + value.translation.width,
                        y: origin.y + value.translation.height
                    )
                    if draftSynapse?.fromID != neuron.id {
                        draftSynapse = .init(fromID: neuron.id, currentPoint: current)
                    } else {
                        draftSynapse?.currentPoint = current
                    }
                }
                // pan / addNeuron / addCompartment / axialCoupling / stimulus
                // / probe — no-op on drag.
            }
            .onEnded { value in
                let tool = vm.activeTool
                if tool == .select {
                    dragOrigin = nil
                } else if tool.isSynapseTool {
                    let endPoint = CGPoint(
                        x: neuron.positionX + Double(value.translation.width),
                        y: neuron.positionY + Double(value.translation.height)
                    )
                    if let target = vm.network.neurons.first(where: {
                        hypot($0.positionX - Double(endPoint.x),
                              $0.positionY - Double(endPoint.y)) < Double(radius)
                    }), target.id != neuron.id {
                        switch tool {
                        case .gapJunction:
                            vm.addGapJunction(from: neuron.id, to: target.id)
                        default:
                            vm.addSynapse(from: neuron.id,
                                          to: target.id,
                                          reversal: tool.defaultReversal)
                        }
                    }
                    draftSynapse = nil
                }
            }
    }

    /// Map V (mV) to a fill colour: blue at hyperpolarised, white near rest,
    /// red at depolarised / spiking.
    private func activityColor(v: Double) -> Color {
        let lo = -90.0, mid = -65.0, hi = 30.0
        if v <= mid {
            let t = max(0, (v - lo) / (mid - lo)) // 0 → 1 from lo to mid
            return Color(red: t, green: t, blue: 1.0)
        } else {
            let t = min(1, (v - mid) / (hi - mid))
            return Color(red: 1.0, green: 1.0 - t, blue: 1.0 - t)
        }
    }
}

// MARK: - Synapse edge

/// Curved-Bézier rendering of a synapse with a colour-coded post-synaptic
/// dot that conveys directionality and excitatory/inhibitory nature.
///
/// Geometry
/// ────────
/// We bow the curve to the *left* of the pre→post direction by a fixed
/// fraction of the centre-to-centre distance. Because that rule is the
/// same for every synapse, a reciprocal pair (A→B and B→A) bows in
/// opposite directions and the two curves trace an ellipse around the
/// two cells — exactly the look of textbook circuit diagrams.
///
/// The endpoints sit on each cell's circle edge (in the direction of the
/// control point), so the curve always meets the cell tangentially and
/// adapts in real time when neurons are dragged.
private struct SynapseEdgeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let synapse: Synapse

    var body: some View {
        if let pre = vm.network.neurons.first(where: { $0.id == synapse.preNeuronID }),
           let post = vm.network.neurons.first(where: { $0.id == synapse.postNeuronID }) {
            let isSelected = vm.selection == .synapse(synapse.id)
            let color = edgeColor(isSelected: isSelected)

            let geom = SynapseGeometry(
                pre: CGPoint(x: pre.positionX, y: pre.positionY),
                post: CGPoint(x: post.positionX, y: post.positionY),
                neuronRadius: kNeuronRadius,
                straight: synapse is GapJunction
            )

            ZStack {
                // Visible curve
                SynapseCurveShape(geom: geom)
                    .stroke(color,
                            style: StrokeStyle(lineWidth: isSelected ? 3 : 2,
                                               lineCap: .round))

                // Wider invisible curve for easier hit-testing. Note we
                // intentionally do NOT add `.contentShape(Rectangle())`
                // here — for a bowed curve, the bounding rectangle of the
                // stroke covers a huge area, and using it for hit-testing
                // would catch clicks far from the curve and prevent the
                // user from deselecting by clicking on empty canvas.
                // The default hit area of the stroke (the 16-pt wide band)
                // is exactly what we want.
                SynapseCurveShape(geom: geom)
                    .stroke(Color.white.opacity(0.001), lineWidth: 16)
                    .onTapGesture { vm.selection = .synapse(synapse.id) }

                // Synapse marker — the visual signature of the connection
                // type. Chemical synapses get a colour-coded directional
                // dot at the post-synaptic edge; gap junctions get a
                // resistor zigzag at the curve apex (bidirectional).
                if synapse is GapJunction {
                    if let mid = geom.midPoint, let tan = geom.midTangent {
                        // Wider invisible stroke for easier hit-testing.
                        ResistorMarker(center: mid, tangent: tan,
                                       length: 30, amplitude: 5, peakCount: 4)
                            .stroke(Color.white.opacity(0.001), lineWidth: 18)
                            .onTapGesture { vm.selection = .synapse(synapse.id) }
                        // Visible resistor.
                        ResistorMarker(center: mid, tangent: tan,
                                       length: 30, amplitude: 5, peakCount: 4)
                            .stroke(Color.orange,
                                    style: StrokeStyle(lineWidth: 2.2,
                                                       lineCap: .round,
                                                       lineJoin: .round))
                    }
                } else if let endPoint = geom.endPoint {
                    Circle()
                        .fill(dotColor)
                        .overlay(
                            Circle().stroke(Color.primary.opacity(0.85), lineWidth: 1.2)
                        )
                        .frame(width: kSynapseDotRadius * 2,
                               height: kSynapseDotRadius * 2)
                        .contentShape(Circle())
                        .position(endPoint)
                        .onTapGesture { vm.selection = .synapse(synapse.id) }
                }
            }
        }
    }

    /// Curve stroke colour. Mirrors `dotColor` but goes grey when not
    /// selected so the dot stays the focal point.
    private func edgeColor(isSelected: Bool) -> Color {
        if isSelected { return .accentColor }
        return Color.primary.opacity(0.6)
    }

    /// Colour of the post-synaptic indicator dot.
    /// Convention used here (chosen by Gwen):
    ///   - red   = excitatory  (reversal > -30 mV, depolarising)
    ///   - green = inhibitory  (reversal ≤ -30 mV, hyperpolarising)
    /// (This is the inverse of the most common textbook convention; the
    /// app sticks with the user's preference.)
    private var dotColor: Color {
        if let chem = synapse as? ChemicalSynapse {
            return chem.reversal > -30 ? .red : .green
        }
        if synapse is GapJunction { return .orange }
        return .gray
    }
}

// MARK: - Shapes & geometry

/// Pre-computed geometry for a single synapse curve. Captured in one
/// place so both the curve shape and the post-synaptic dot draw against
/// the same numbers.
///
/// When `straight` is true the curve degenerates to a straight line
/// (the quadratic-Bézier control point sits exactly on the chord
/// midpoint). Used for gap junctions, which are bidirectional and look
/// more like wires than directional projections.
private struct SynapseGeometry {
    let pre: CGPoint
    let post: CGPoint
    let neuronRadius: CGFloat
    var straight: Bool = false

    /// Quadratic-Bézier control point. For chemical synapses we push it
    /// perpendicular-LEFT of the pre→post direction (giving the bowed
    /// look and producing an ellipse for reciprocal pairs). For gap
    /// junctions we leave it on the midpoint, so the path renders as a
    /// straight line.
    var controlPoint: CGPoint? {
        let dx = post.x - pre.x
        let dy = post.y - pre.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-3 else { return nil }
        let mid = CGPoint(x: (pre.x + post.x) / 2, y: (pre.y + post.y) / 2)
        if straight { return mid }
        let ux = dx / dist, uy = dy / dist
        // Left-perpendicular in the screen coordinate system (y goes down).
        let perpX = -uy, perpY = ux
        // Bow proportional to distance, with a comfortable minimum so even
        // close-by neurons get a visible curvature.
        let bow = max(28, dist * 0.22)
        return CGPoint(x: mid.x + bow * perpX, y: mid.y + bow * perpY)
    }

    /// Curve start point: pre cell edge in the direction of the control point.
    var startPoint: CGPoint? {
        guard let cp = controlPoint else { return nil }
        return edgePoint(of: pre, towards: cp)
    }

    /// Curve end point: post cell edge in the direction of the control point.
    var endPoint: CGPoint? {
        guard let cp = controlPoint else { return nil }
        return edgePoint(of: post, towards: cp)
    }

    /// Midpoint of the quadratic Bézier (t = 0.5):
    ///   B(0.5) = 0.25·start + 0.5·control + 0.25·end
    var midPoint: CGPoint? {
        guard let s = startPoint, let cp = controlPoint, let e = endPoint
        else { return nil }
        return CGPoint(x: 0.25 * s.x + 0.5 * cp.x + 0.25 * e.x,
                       y: 0.25 * s.y + 0.5 * cp.y + 0.25 * e.y)
    }

    /// Unit tangent at the curve midpoint. For a quadratic Bézier the
    /// derivative at t = 0.5 simplifies to (end − start), independent of
    /// the control point — so the tangent at the apex is parallel to the
    /// chord between the two endpoints.
    var midTangent: CGVector? {
        guard let s = startPoint, let e = endPoint else { return nil }
        let dx = e.x - s.x
        let dy = e.y - s.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > 1e-3 else { return nil }
        return CGVector(dx: dx / d, dy: dy / d)
    }

    private func edgePoint(of centre: CGPoint, towards target: CGPoint) -> CGPoint {
        let dx = target.x - centre.x
        let dy = target.y - centre.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > 1e-3 else { return centre }
        return CGPoint(x: centre.x + (dx / d) * neuronRadius,
                       y: centre.y + (dy / d) * neuronRadius)
    }
}

/// Quadratic Bézier path from one neuron's edge to another's, bowing
/// to the LEFT of the pre→post direction.
private struct SynapseCurveShape: Shape {
    let geom: SynapseGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let start = geom.startPoint,
              let end = geom.endPoint,
              let cp = geom.controlPoint
        else { return path }
        path.move(to: start)
        path.addQuadCurve(to: end, control: cp)
        return path
    }
}

/// Textbook electrical-resistor zigzag, used as the gap-junction marker.
/// Drawn centred on `center`, oriented along `tangent`. The shape is
/// purely geometric so it can be `stroke()`d in any colour and width.
///
/// Pattern: a baseline line that pops up/down `peakCount` times, then
/// returns to the baseline. With `peakCount = 4` you get the classic
/// 4-zigzag European resistor symbol.
private struct ResistorMarker: Shape {
    let center: CGPoint
    let tangent: CGVector   // unit vector along the resistor's axis
    let length: CGFloat
    let amplitude: CGFloat
    let peakCount: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let perp = CGVector(dx: -tangent.dy, dy: tangent.dx)
        let segCount = peakCount + 1
        let segLen = length / CGFloat(segCount)
        let halfLen = length / 2

        // Move to the start of the axis (on the baseline).
        let start = CGPoint(x: center.x - tangent.dx * halfLen,
                            y: center.y - tangent.dy * halfLen)
        path.move(to: start)

        // Draw the alternating peaks.
        for i in 1...peakCount {
            let alongDist = -halfLen + CGFloat(i) * segLen
            let sign: CGFloat = (i % 2 == 1) ? 1 : -1
            let peak = CGPoint(
                x: center.x + tangent.dx * alongDist + perp.dx * amplitude * sign,
                y: center.y + tangent.dy * alongDist + perp.dy * amplitude * sign
            )
            path.addLine(to: peak)
        }

        // Close back to the baseline at the far end.
        let end = CGPoint(x: center.x + tangent.dx * halfLen,
                          y: center.y + tangent.dy * halfLen)
        path.addLine(to: end)
        return path
    }
}

private struct DraftEdgeShape: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}
