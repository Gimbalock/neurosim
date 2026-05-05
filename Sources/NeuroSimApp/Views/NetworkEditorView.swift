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
//   - .pan             : drag the background to pan the viewport.
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
//  Viewport: the canvas supports zoom (pinch / scroll-wheel) and pan
//  (.pan tool or drag-background when pan is active).
//  Neuron positions are stored in canvas space; screen space = canvas * scale + offset.
//
//  Live state: each neuron's fill colour reflects its instantaneous
//  membrane potential (blue = hyperpolarised, white ~ rest, red = spiking).
//

import SwiftUI
import NeuroSimCore
import AppKit

// MARK: - Canvas constants

/// Visible radius of a neuron in canvas points. Shared between the node
/// renderer and the synapse renderer so curves and dots align with the
/// circle edges.
private let kNeuronRadius: CGFloat = 32

/// Radius of the small post-synaptic indicator dot.
private let kSynapseDotRadius: CGFloat = 7

// MARK: - Scroll-wheel zoom helper

/// NSViewRepresentable that forwards NSEvent scroll-wheel events as a
/// zoom delta to a callback. MagnificationGesture handles trackpad pinch;
/// this handles the traditional scroll wheel on non-trackpad mice.
private struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void   // delta Y (positive = scroll down)

    func makeNSView(context: Context) -> _ScrollView { _ScrollView(onScroll: onScroll) }
    func updateNSView(_ v: _ScrollView, context: Context) { v.onScroll = onScroll }

    class _ScrollView: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { false }
        override func scrollWheel(with event: NSEvent) {
            // Only intercept vertical scroll; horizontal is ignored (let
            // SwiftUI handle it for any containing scroll view).
            onScroll(event.scrollingDeltaY)
        }
    }
}

// MARK: - NetworkEditorView

struct NetworkEditorView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @State private var draftSynapse: DraftSynapse? = nil
    /// Live drag position — stored locally so updating it does NOT trigger
    /// vm.objectWillChange and does not cause chart views to re-render.
    @State private var neuronDrag: NeuronDrag? = nil

    // Viewport transform — canvas space → screen space:
    //   screen = canvas * viewportScale + viewportOffset
    @State private var viewportScale: CGFloat = 1.0
    @State private var viewportOffset: CGSize = .zero

    // Pan gesture bookkeeping
    @State private var panLastTranslation: CGSize = .zero

    struct DraftSynapse {
        let fromID: UUID
        var currentPoint: CGPoint   // screen space
    }

    struct NeuronDrag {
        let neuronID: UUID
        var position: CGPoint   // canvas space
    }

    var body: some View {
        canvas
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                // Background — handles tap-to-deselect and pan gesture
                Color(NSColor.textBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        let canvasPoint = screenToCanvas(location)
                        handleCanvasTap(at: canvasPoint)
                    }
                    .gesture(backgroundPanGesture)

                // Edges (drawn first so neurons sit on top)
                ForEach(vm.network.synapses, id: \.id) { syn in
                    SynapseEdgeView(synapse: syn,
                                    neuronDrag: neuronDrag,
                                    viewportScale: viewportScale,
                                    viewportOffset: viewportOffset)
                }

                // Draft connection arrow (during synapse-tool drag)
                if let draft = draftSynapse,
                   let from = vm.network.neurons.first(where: { $0.id == draft.fromID }) {
                    let fromScreen = canvasToScreen(CGPoint(x: from.positionX,
                                                           y: from.positionY))
                    DraftEdgeShape(from: fromScreen, to: draft.currentPoint)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }

                // Nodes
                ForEach(vm.network.neurons, id: \.id) { neuron in
                    NeuronNodeView(neuron: neuron,
                                   draftSynapse: $draftSynapse,
                                   neuronDrag: $neuronDrag,
                                   viewportScale: viewportScale,
                                   viewportOffset: viewportOffset)
                }

                // Reset-view button — bottom-right corner of the canvas
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        resetViewButton
                            .padding(10)
                    }
                }
            }
            // Scroll-wheel zoom (intercepts NSEvent before SwiftUI sees it)
            .background(
                ScrollWheelReceiver { deltaY in
                    // Zoom centred on the canvas centre (approximation; cursor
                    // position is not available via NSEvent in this path on macOS).
                    let factor: CGFloat = deltaY > 0 ? 0.9 : 1.1
                    let newScale = min(max(viewportScale * factor, 0.1), 8.0)
                    // Adjust offset to keep the visual centre fixed
                    let centre = CGPoint(x: proxy.size.width / 2,
                                        y: proxy.size.height / 2)
                    let scaleRatio = newScale / viewportScale
                    viewportOffset = CGSize(
                        width:  centre.x + (viewportOffset.width  - centre.x) * scaleRatio,
                        height: centre.y + (viewportOffset.height - centre.y) * scaleRatio
                    )
                    viewportScale = newScale
                }
            )
            // Pinch-to-zoom (trackpad)
            .gesture(
                MagnificationGesture()
                    .onChanged { mag in
                        let newScale = min(max(mag * viewportScale, 0.1), 8.0)
                        _ = newScale   // will be committed on end
                    }
                    .onEnded { mag in
                        let centre = CGPoint(x: proxy.size.width / 2,
                                            y: proxy.size.height / 2)
                        let newScale = min(max(viewportScale * mag, 0.1), 8.0)
                        let scaleRatio = newScale / viewportScale
                        viewportOffset = CGSize(
                            width:  centre.x + (viewportOffset.width  - centre.x) * scaleRatio,
                            height: centre.y + (viewportOffset.height - centre.y) * scaleRatio
                        )
                        viewportScale = newScale
                    }
            )
            .focusable()
            .onKeyPress(.delete) { vm.removeSelected(); return .handled }
            .onKeyPress(.deleteForward) { vm.removeSelected(); return .handled }
        }
    }

    // MARK: - Reset-view button

    private var resetViewButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                viewportScale = 1.0
                viewportOffset = .zero
            }
        } label: {
            Label("1:1", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Reset zoom and pan to 1:1")
    }

    // MARK: - Pan gesture (background drag when .pan tool is active)

    private var backgroundPanGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard vm.activeTool == .pan else { return }
                let delta = CGSize(
                    width:  v.translation.width  - panLastTranslation.width,
                    height: v.translation.height - panLastTranslation.height
                )
                viewportOffset = CGSize(
                    width:  viewportOffset.width  + delta.width,
                    height: viewportOffset.height + delta.height
                )
                panLastTranslation = v.translation
            }
            .onEnded { _ in panLastTranslation = .zero }
    }

    // MARK: - Coordinate helpers

    /// Convert a screen-space point to canvas space.
    func screenToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - viewportOffset.width)  / viewportScale,
            y: (p.y - viewportOffset.height) / viewportScale
        )
    }

    /// Convert a canvas-space point to screen space.
    func canvasToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x * viewportScale + viewportOffset.width,
            y: p.y * viewportScale + viewportOffset.height
        )
    }

    // MARK: - Tool dispatch

    private func handleCanvasTap(at canvasPoint: CGPoint) {
        switch vm.activeTool {
        case .select, .pan:
            vm.selection = .none
        case .addNeuron:
            vm.addNeuron(at: Double(canvasPoint.x), y: Double(canvasPoint.y))
        case .addCompartment, .synapseExcitatory, .synapseInhibitory,
             .gapJunction, .axialCoupling, .stimulus, .probe:
            vm.selection = .none
        }
    }
}

// MARK: - Neuron node

private struct NeuronNodeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    @Binding var draftSynapse: NetworkEditorView.DraftSynapse?
    @Binding var neuronDrag: NetworkEditorView.NeuronDrag?
    let viewportScale: CGFloat
    let viewportOffset: CGSize

    @State private var dragOrigin: CGPoint? = nil

    private var radius: CGFloat { kNeuronRadius }

    /// Canvas-space position (live during drag, committed otherwise).
    private var canvasPosition: CGPoint {
        if let drag = neuronDrag, drag.neuronID == neuron.id { return drag.position }
        return CGPoint(x: neuron.positionX, y: neuron.positionY)
    }

    /// Screen-space position — what `.position()` needs.
    private var screenPosition: CGPoint {
        canvasToScreen(canvasPosition)
    }

    private func canvasToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x * viewportScale + viewportOffset.width,
            y: p.y * viewportScale + viewportOffset.height
        )
    }

    private func screenToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - viewportOffset.width)  / viewportScale,
            y: (p.y - viewportOffset.height) / viewportScale
        )
    }

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
        .position(screenPosition)
        .gesture(nodeGesture)
        .onTapGesture { handleNeuronTap() }
    }

    // MARK: - Tool dispatch (per-node)

    private func handleNeuronTap() {
        switch vm.activeTool {
        case .select, .pan, .addNeuron,
             .synapseExcitatory, .synapseInhibitory, .gapJunction,
             .axialCoupling:
            vm.selection = .neuron(neuron.id)
        case .addCompartment:
            _ = vm.addCompartment(to: neuron.id)
            vm.selection = .neuron(neuron.id)
        case .stimulus:
            let pulse = PulseStimulus(start: 10, duration: 50, amplitude: 10)
            vm.setStimulus(pulse, onCompartment: neuron.somaCompartmentID)
            vm.selection = .neuron(neuron.id)
        case .probe:
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
                    // Translate screen-space drag delta back to canvas space
                    let canvasDelta = CGSize(
                        width:  value.translation.width  / viewportScale,
                        height: value.translation.height / viewportScale
                    )
                    neuronDrag = NetworkEditorView.NeuronDrag(
                        neuronID: neuron.id,
                        position: CGPoint(
                            x: origin.x + canvasDelta.width,
                            y: origin.y + canvasDelta.height
                        )
                    )
                } else if tool.isSynapseTool {
                    // Compute current tip in screen space
                    let originScreen = canvasToScreen(
                        CGPoint(x: neuron.positionX, y: neuron.positionY)
                    )
                    let current = CGPoint(
                        x: originScreen.x + value.translation.width,
                        y: originScreen.y + value.translation.height
                    )
                    if draftSynapse?.fromID != neuron.id {
                        draftSynapse = .init(fromID: neuron.id, currentPoint: current)
                    } else {
                        draftSynapse?.currentPoint = current
                    }
                }
            }
            .onEnded { value in
                let tool = vm.activeTool
                if tool == .select {
                    if let drag = neuronDrag, drag.neuronID == neuron.id {
                        vm.setNeuronPosition(neuron.id,
                                             x: Double(drag.position.x),
                                             y: Double(drag.position.y))
                    }
                    neuronDrag = nil
                    dragOrigin = nil
                } else if tool.isSynapseTool {
                    // Convert end point to canvas space for hit-test
                    let originScreen = canvasToScreen(
                        CGPoint(x: neuron.positionX, y: neuron.positionY)
                    )
                    let endScreen = CGPoint(
                        x: originScreen.x + value.translation.width,
                        y: originScreen.y + value.translation.height
                    )
                    let endCanvas = screenToCanvas(endScreen)
                    let hitRadius = Double(kNeuronRadius)
                    if let target = vm.network.neurons.first(where: {
                        hypot($0.positionX - Double(endCanvas.x),
                              $0.positionY - Double(endCanvas.y)) < hitRadius
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

    private func activityColor(v: Double) -> Color {
        let lo = -90.0, mid = -65.0, hi = 30.0
        if v <= mid {
            let t = max(0, (v - lo) / (mid - lo))
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
/// All geometry is computed in screen space (canvas coords * scale + offset)
/// so the curves follow neurons correctly during zoom and pan.
private struct SynapseEdgeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let synapse: Synapse
    let neuronDrag: NetworkEditorView.NeuronDrag?
    let viewportScale: CGFloat
    let viewportOffset: CGSize

    /// Canvas-space centre of a neuron (respects live drag).
    private func canvasPos(of neuron: HHNeuron) -> CGPoint {
        if let drag = neuronDrag, drag.neuronID == neuron.id { return drag.position }
        return CGPoint(x: neuron.positionX, y: neuron.positionY)
    }

    /// Screen-space centre of a neuron.
    private func screenPos(of neuron: HHNeuron) -> CGPoint {
        let cp = canvasPos(of: neuron)
        return CGPoint(
            x: cp.x * viewportScale + viewportOffset.width,
            y: cp.y * viewportScale + viewportOffset.height
        )
    }

    var body: some View {
        if let pre = vm.network.neurons.first(where: { $0.id == synapse.preNeuronID }),
           let post = vm.network.neurons.first(where: { $0.id == synapse.postNeuronID }) {
            let isSelected = vm.selection == .synapse(synapse.id)
            let color = edgeColor(isSelected: isSelected)

            // Scale neuron radius to screen space so endpoints sit on the
            // visible circle edges regardless of zoom level.
            let geom = SynapseGeometry(
                pre: screenPos(of: pre),
                post: screenPos(of: post),
                neuronRadius: kNeuronRadius * viewportScale,
                straight: synapse is GapJunction
            )

            ZStack {
                SynapseCurveShape(geom: geom)
                    .stroke(color,
                            style: StrokeStyle(lineWidth: isSelected ? 3 : 2,
                                               lineCap: .round))

                SynapseCurveShape(geom: geom)
                    .stroke(Color.white.opacity(0.001), lineWidth: 16)
                    .onTapGesture { vm.selection = .synapse(synapse.id) }

                if synapse is GapJunction {
                    if let mid = geom.midPoint, let tan = geom.midTangent {
                        ResistorMarker(center: mid, tangent: tan,
                                       length: 30, amplitude: 5, peakCount: 4)
                            .stroke(Color.white.opacity(0.001), lineWidth: 18)
                            .onTapGesture { vm.selection = .synapse(synapse.id) }
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

    private func edgeColor(isSelected: Bool) -> Color {
        if isSelected { return .accentColor }
        return Color.primary.opacity(0.6)
    }

    private var dotColor: Color {
        if let chem = synapse as? ChemicalSynapse {
            return chem.reversal > -30 ? .red : .green
        }
        if synapse is GapJunction { return .orange }
        return .gray
    }
}

// MARK: - Shapes & geometry

/// Pre-computed geometry for a single synapse curve.
///
/// Inputs are in **screen space** — callers must transform canvas positions
/// to screen positions before constructing this struct.
private struct SynapseGeometry {
    let pre: CGPoint
    let post: CGPoint
    let neuronRadius: CGFloat
    var straight: Bool = false

    var controlPoint: CGPoint? {
        let dx = post.x - pre.x
        let dy = post.y - pre.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-3 else { return nil }
        let mid = CGPoint(x: (pre.x + post.x) / 2, y: (pre.y + post.y) / 2)
        if straight { return mid }
        let ux = dx / dist, uy = dy / dist
        let perpX = -uy, perpY = ux
        let bow = max(28, dist * 0.22)
        return CGPoint(x: mid.x + bow * perpX, y: mid.y + bow * perpY)
    }

    var startPoint: CGPoint? {
        guard let cp = controlPoint else { return nil }
        return edgePoint(of: pre, towards: cp)
    }

    var endPoint: CGPoint? {
        guard let cp = controlPoint else { return nil }
        return edgePoint(of: post, towards: cp)
    }

    var midPoint: CGPoint? {
        guard let s = startPoint, let cp = controlPoint, let e = endPoint
        else { return nil }
        return CGPoint(x: 0.25 * s.x + 0.5 * cp.x + 0.25 * e.x,
                       y: 0.25 * s.y + 0.5 * cp.y + 0.25 * e.y)
    }

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

private struct ResistorMarker: Shape {
    let center: CGPoint
    let tangent: CGVector
    let length: CGFloat
    let amplitude: CGFloat
    let peakCount: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let perp = CGVector(dx: -tangent.dy, dy: tangent.dx)
        let segCount = peakCount + 1
        let segLen = length / CGFloat(segCount)
        let halfLen = length / 2

        let start = CGPoint(x: center.x - tangent.dx * halfLen,
                            y: center.y - tangent.dy * halfLen)
        path.move(to: start)

        for i in 1...peakCount {
            let alongDist = -halfLen + CGFloat(i) * segLen
            let sign: CGFloat = (i % 2 == 1) ? 1 : -1
            let peak = CGPoint(
                x: center.x + tangent.dx * alongDist + perp.dx * amplitude * sign,
                y: center.y + tangent.dy * alongDist + perp.dy * amplitude * sign
            )
            path.addLine(to: peak)
        }

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
