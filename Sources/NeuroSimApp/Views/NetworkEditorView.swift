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

// Scroll-wheel zoom is handled via NSEvent.addLocalMonitorForEvents in NetworkEditorView.onAppear.

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
    @State private var scrollMonitor: Any? = nil
    @State private var isMouseOverCanvas = false

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
            .onHover { isMouseOverCanvas = $0 }
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

                // Dendritic trees (drawn below soma circles)
                ForEach(vm.network.neurons, id: \.id) { neuron in
                    DendriteTreeView(neuron: neuron,
                                     neuronDrag: neuronDrag,
                                     viewportScale: viewportScale,
                                     viewportOffset: viewportOffset)
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
            .onAppear {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    // Zoom via scroll wheel only when the pan tool is active.
                    guard isMouseOverCanvas, vm.activeTool == .pan else { return event }
                    let factor: CGFloat = event.scrollingDeltaY > 0 ? 0.9 : 1.1
                    let newScale = min(max(viewportScale * factor, 0.1), 8.0)
                    let centre = CGPoint(x: proxy.size.width / 2,
                                        y: proxy.size.height / 2)
                    let scaleRatio = newScale / viewportScale
                    viewportOffset = CGSize(
                        width:  centre.x + (viewportOffset.width  - centre.x) * scaleRatio,
                        height: centre.y + (viewportOffset.height - centre.y) * scaleRatio
                    )
                    viewportScale = newScale
                    return nil  // consume the event
                }
            }
            .onDisappear {
                if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            }
            // Pinch-to-zoom (trackpad) — only when the pan tool is active.
            .gesture(
                MagnificationGesture()
                    .onChanged { _ in }   // no preview drag, committed on end
                    .onEnded { mag in
                        guard vm.activeTool == .pan else { return }
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
        case .addCompartment:
            break  // preserve selection so handleNeuronTap can use it as parent
        case .synapseExcitatory, .synapseInhibitory,
             .gapJunction, .axialCoupling, .stimulus, .probe, .synapticNoise:
            vm.selection = .none
        }
    }
}

// MARK: - Dendritic tree

/// Draws all non-soma compartments of a neuron as cylinders (rounded rectangles)
/// anchored to their parent in the AxialCoupling tree. Angles are relative to
/// the parent's orientation (option B). Each compartment has a drag handle at
/// its tip to rotate it around its attachment point.
private struct DendriteTreeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    let neuronDrag: NetworkEditorView.NeuronDrag?
    let viewportScale: CGFloat
    let viewportOffset: CGSize

    // px per µm for visual length/width
    private let pxPerMicron: CGFloat = 0.45

    private var somaCenter: CGPoint {
        let pos: CGPoint
        if let drag = neuronDrag, drag.neuronID == neuron.id {
            pos = drag.position
        } else {
            pos = CGPoint(x: neuron.positionX, y: neuron.positionY)
        }
        return CGPoint(x: pos.x * viewportScale + viewportOffset.width,
                       y: pos.y * viewportScale + viewportOffset.height)
    }

    private var somaRadius: CGFloat { kNeuronRadius * viewportScale }

    var body: some View {
        let nonSoma = neuron.compartments.filter { $0.id != neuron.somaCompartmentID }
        if nonSoma.isEmpty { return AnyView(EmptyView()) }

        // Build parent map from AxialCoupling tree (BFS from soma)
        var parentMap: [UUID: UUID] = [:]   // childID -> parentID
        var parentAngle: [UUID: Double] = [neuron.somaCompartmentID: 0]  // cumulative absolute angle
        var queue: [UUID] = [neuron.somaCompartmentID]
        var visited: Set<UUID> = [neuron.somaCompartmentID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for coupling in neuron.axialCouplings {
                if let other = coupling.other(current), !visited.contains(other) {
                    visited.insert(other)
                    parentMap[other] = current
                    queue.append(other)
                    // Absolute angle = parent absolute angle + this compartment's relative angle
                    let comp = neuron.compartments.first(where: { $0.id == other })
                    let rel = comp?.displayAngle ?? 0
                    parentAngle[other] = (parentAngle[current] ?? 0) + rel
                }
            }
        }

        return AnyView(
            ForEach(nonSoma) { comp in
                DendriteView(
                    compartment:   comp,
                    neuron:        neuron,
                    parentID:      parentMap[comp.id],
                    absoluteAngle: parentAngle[comp.id] ?? 0,
                    parentAngleMap: parentAngle,
                    somaCenter:    somaCenter,
                    somaRadius:    somaRadius,
                    pxPerMicron:   pxPerMicron * viewportScale,
                    viewportScale: viewportScale,
                    viewportOffset: viewportOffset,
                    allCompartments: neuron.compartments,
                    allCouplings:    neuron.axialCouplings
                )
            }
        )
    }
}

/// Renders a single compartment as a rounded rectangle (cylinder side view)
/// plus a small circular drag handle at its tip.
private struct DendriteView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let compartment: Compartment
    let neuron: HHNeuron
    let parentID: UUID?
    let absoluteAngle: Double
    let parentAngleMap: [UUID: Double]
    let somaCenter: CGPoint
    let somaRadius: CGFloat
    let pxPerMicron: CGFloat
    let viewportScale: CGFloat
    let viewportOffset: CGSize
    let allCompartments: [Compartment]
    let allCouplings: [AxialCoupling]

    @State private var isDraggingHandle = false

    private var visualLength: CGFloat {
        max(CGFloat(compartment.length) * pxPerMicron, 20 * viewportScale)
    }
    private var visualWidth: CGFloat {
        max(min(CGFloat(compartment.diameter) * pxPerMicron, 18 * viewportScale), 4 * viewportScale)
    }

    /// Screen-space position of the parent's tip (= this compartment's base).
    private var basePoint: CGPoint {
        guard let pid = parentID else {
            // No parent found — attach to soma edge at absoluteAngle
            return CGPoint(
                x: somaCenter.x + somaRadius * CGFloat(cos(absoluteAngle)),
                y: somaCenter.y + somaRadius * CGFloat(sin(absoluteAngle))
            )
        }
        if pid == neuron.somaCompartmentID {
            return CGPoint(
                x: somaCenter.x + somaRadius * CGFloat(cos(absoluteAngle)),
                y: somaCenter.y + somaRadius * CGFloat(sin(absoluteAngle))
            )
        }
        // Parent is a dendrite: attach at branchFraction along its length
        guard let parentComp = allCompartments.first(where: { $0.id == pid }) else {
            return somaCenter
        }
        let parentBase = parentBasePoint(for: pid)
        let parentLen = max(CGFloat(parentComp.length) * pxPerMicron, 20 * viewportScale)
        let pAngle = parentAngleMap[pid] ?? 0
        let fraction = CGFloat(compartment.branchFraction)
        return CGPoint(
            x: parentBase.x + parentLen * fraction * CGFloat(cos(pAngle)),
            y: parentBase.y + parentLen * fraction * CGFloat(sin(pAngle))
        )
    }

    private func parentBasePoint(for compID: UUID) -> CGPoint {
        guard let coupling = allCouplings.first(where: { $0.involves(compID) }),
              let grandParentID = coupling.other(compID) else {
            return somaCenter
        }
        if grandParentID == neuron.somaCompartmentID {
            let angle = parentAngleMap[compID] ?? 0
            return CGPoint(
                x: somaCenter.x + somaRadius * CGFloat(cos(angle)),
                y: somaCenter.y + somaRadius * CGFloat(sin(angle))
            )
        }
        guard let gpComp = allCompartments.first(where: { $0.id == grandParentID }) else {
            return somaCenter
        }
        let gpBase = parentBasePoint(for: grandParentID)
        let gpLen = max(CGFloat(gpComp.length) * pxPerMicron, 20 * viewportScale)
        let gpAngle = parentAngleMap[grandParentID] ?? 0
        return CGPoint(
            x: gpBase.x + gpLen * CGFloat(cos(gpAngle)),
            y: gpBase.y + gpLen * CGFloat(sin(gpAngle))
        )
    }

    private var tipPoint: CGPoint {
        CGPoint(
            x: basePoint.x + visualLength * CGFloat(cos(absoluteAngle)),
            y: basePoint.y + visualLength * CGFloat(sin(absoluteAngle))
        )
    }

    private var handleRadius: CGFloat { max(6 * viewportScale, 5) }

    var body: some View {
        let base = basePoint
        let tip  = tipPoint
        let angle = absoluteAngle
        let midX = (base.x + tip.x) / 2
        let midY = (base.y + tip.y) / 2
        let isSelected = vm.selection == .compartment(compartment.id)

        ZStack {
            // Cylinder body
            RoundedRectangle(cornerRadius: visualWidth / 2)
                .fill(Color.gray.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: visualWidth / 2)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.6),
                                lineWidth: isSelected ? 2 : 1)
                )
                .frame(width: visualLength, height: visualWidth)
                .rotationEffect(.radians(angle))
                .position(x: midX, y: midY)
                .onTapGesture {
                    if vm.activeTool == .probe {
                        vm.addSignalTrace(.voltage(neuronID: neuron.id,
                                                   compartmentID: compartment.id))
                    } else if vm.activeTool == .synapticNoise {
                        if vm.network.synapticNoises[compartment.id] == nil {
                            vm.setSynapticNoise(SynapticNoiseParams(), onCompartment: compartment.id)
                        }
                    }
                    vm.selection = .compartment(compartment.id)
                }

            // Name label
            Text(compartment.name)
                .font(.system(size: max(8 * viewportScale, 7), design: .rounded))
                .foregroundStyle(.secondary)
                .rotationEffect(.radians(angle))
                .position(x: midX, y: midY)
                .allowsHitTesting(false)

            // Noise badge — orange arrow when OU noise is attached to this compartment
            if vm.network.synapticNoises[compartment.id] != nil {
                let perpOffX = CGFloat(-sin(angle)) * (visualWidth / 2 + 5)
                let perpOffY = CGFloat( cos(angle)) * (visualWidth / 2 + 5)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.orange)
                    .background(
                        Circle().fill(Color(.windowBackgroundColor)).frame(width: 11, height: 11)
                    )
                    .position(x: midX + perpOffX, y: midY + perpOffY)
                    .allowsHitTesting(false)
            }

            // Drag handle at tip
            Circle()
                .fill(isDraggingHandle ? Color.accentColor : Color.primary.opacity(0.5))
                .frame(width: handleRadius * 2, height: handleRadius * 2)
                .position(x: tip.x, y: tip.y)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { val in
                            isDraggingHandle = true
                            // Cursor position in screen space
                            let cursor = CGPoint(x: tip.x + val.translation.width,
                                                y: tip.y + val.translation.height)
                            // New angle = atan2 from base to cursor
                            let dx = cursor.x - base.x
                            let dy = cursor.y - base.y
                            let newAbsAngle = Double(atan2(dy, dx))
                            // Relative angle = new absolute - parent's absolute
                            let parentAbs = parentAngleMap[parentID ?? neuron.somaCompartmentID] ?? 0
                            let newRel = newAbsAngle - parentAbs
                            vm.setCompartmentAngle(neuron.id,
                                                   compartmentID: compartment.id,
                                                   angle: newRel)
                        }
                        .onEnded { _ in isDraggingHandle = false }
                )
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

    private var radius: CGFloat { kNeuronRadius * viewportScale }

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

    /// Find the neuron and compartment hit by `screenPoint`.
    /// Checks soma circles first, then dendrite bodies (in screen space).
    private func findSynapseTarget(at screenPoint: CGPoint) -> (HHNeuron, UUID?)? {
        let hitR = kNeuronRadius * viewportScale
        let ppm  = 0.45 * viewportScale  // px per micron in screen space

        func screenPos(_ n: HHNeuron) -> CGPoint {
            CGPoint(x: CGFloat(n.positionX) * viewportScale + viewportOffset.width,
                    y: CGFloat(n.positionY) * viewportScale + viewportOffset.height)
        }

        for n in vm.network.neurons {
            let sc = screenPos(n)

            // 1. Soma circle hit
            if hypot(screenPoint.x - sc.x, screenPoint.y - sc.y) < hitR {
                return (n, nil)
            }

            // 2. Dendrite bodies — BFS to get absolute angles, then compute screen segments
            guard n.compartments.count > 1 else { continue }
            var parentMap:   [UUID: UUID]   = [:]
            var absAngleMap: [UUID: Double] = [n.somaCompartmentID: 0]
            var queue   = [n.somaCompartmentID]
            var visited: Set<UUID> = [n.somaCompartmentID]
            while !queue.isEmpty {
                let cur = queue.removeFirst()
                for c in n.axialCouplings {
                    if let other = c.other(cur), !visited.contains(other) {
                        visited.insert(other)
                        parentMap[other] = cur
                        queue.append(other)
                        let rel = n.compartments.first { $0.id == other }?.displayAngle ?? 0
                        absAngleMap[other] = (absAngleMap[cur] ?? 0) + rel
                    }
                }
            }

            // Screen-space base of a compartment (mirrors DendriteView.basePoint)
            func dendBase(_ compID: UUID) -> CGPoint {
                let angle = absAngleMap[compID] ?? 0
                guard let pid = parentMap[compID] else {
                    return CGPoint(x: sc.x + hitR * CGFloat(cos(angle)),
                                   y: sc.y + hitR * CGFloat(sin(angle)))
                }
                if pid == n.somaCompartmentID {
                    return CGPoint(x: sc.x + hitR * CGFloat(cos(angle)),
                                   y: sc.y + hitR * CGFloat(sin(angle)))
                }
                guard let pc = n.compartments.first(where: { $0.id == pid }) else { return sc }
                let pb   = dendBase(pid)
                let pLen = max(CGFloat(pc.length) * ppm, 20 * viewportScale)
                let pAng = absAngleMap[pid] ?? 0
                let frac = CGFloat(n.compartments.first { $0.id == compID }?.branchFraction ?? 1)
                return CGPoint(x: pb.x + pLen * frac * CGFloat(cos(pAng)),
                               y: pb.y + pLen * frac * CGFloat(sin(pAng)))
            }

            for comp in n.compartments where comp.id != n.somaCompartmentID {
                let base = dendBase(comp.id)
                let len  = max(CGFloat(comp.length) * ppm, 20 * viewportScale)
                let ang  = absAngleMap[comp.id] ?? 0
                let tip  = CGPoint(x: base.x + len * CGFloat(cos(ang)),
                                   y: base.y + len * CGFloat(sin(ang)))
                // Point-to-segment distance
                let sdx = tip.x - base.x, sdy = tip.y - base.y
                let sl2 = sdx * sdx + sdy * sdy
                let t   = sl2 > 0 ? max(0, min(1, ((screenPoint.x - base.x) * sdx
                                                   + (screenPoint.y - base.y) * sdy) / sl2)) : 0
                let nearX = base.x + t * sdx, nearY = base.y + t * sdy
                if hypot(screenPoint.x - nearX, screenPoint.y - nearY) < hitR {
                    return (n, comp.id)
                }
            }
        }
        return nil
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

            // Noise badge — small inward arrow shown when OU noise is attached to the soma
            if vm.network.synapticNoises[neuron.somaCompartmentID] != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.orange)
                    .background(Circle().fill(Color(.windowBackgroundColor)).frame(width: 13, height: 13))
                    .offset(x: radius - 5, y: -(radius - 5))
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
            // Use the selected compartment as parent if it belongs to this neuron,
            // otherwise fall back to soma.
            var parentID: UUID? = nil
            if case .compartment(let selID) = vm.selection,
               vm.network.neurons.first(where: { $0.id == neuron.id })?
                   .compartments.contains(where: { $0.id == selID }) == true {
                parentID = selID
            }
            if let newComp = vm.addCompartment(to: neuron.id, parent: parentID) {
                vm.selection = .compartment(newComp.id)
            }
        case .stimulus:
            let pulse = PulseStimulus(start: 10, duration: 50, amplitude: 10)
            vm.setStimulus(pulse, onCompartment: neuron.somaCompartmentID)
            vm.selection = .neuron(neuron.id)
        case .probe:
            let compID = neuron.somaCompartmentID
            vm.addSignalTrace(.voltage(neuronID: neuron.id, compartmentID: compID))
            vm.selection = .neuron(neuron.id)
        case .synapticNoise:
            let somaID = neuron.somaCompartmentID
            if vm.network.synapticNoises[somaID] == nil {
                vm.setSynapticNoise(SynapticNoiseParams(), onCompartment: somaID)
            }
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
                    let originScreen = canvasToScreen(
                        CGPoint(x: neuron.positionX, y: neuron.positionY)
                    )
                    let endScreen = CGPoint(
                        x: originScreen.x + value.translation.width,
                        y: originScreen.y + value.translation.height
                    )
                    let result = findSynapseTarget(at: endScreen)
                    if let (target, compID) = result,
                       target.id != neuron.id {
                        switch tool {
                        case .gapJunction:
                            vm.addGapJunction(from: neuron.id, to: target.id)
                        default:
                            vm.addSynapse(from: neuron.id,
                                          to: target.id,
                                          compartmentID: compID,
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

    /// Screen-space tip of `compartmentID` on `neuron`, or nil if not found.
    private func compartmentTipPos(for compartmentID: UUID, on neuron: HHNeuron) -> CGPoint? {
        let ppm: CGFloat = 0.45 * viewportScale
        let somaR = kNeuronRadius * viewportScale
        let sc = screenPos(of: neuron)
        var parentMap: [UUID: UUID] = [:]
        var absAngleMap: [UUID: Double] = [neuron.somaCompartmentID: 0]
        var queue = [neuron.somaCompartmentID]
        var visited: Set<UUID> = [neuron.somaCompartmentID]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            for c in neuron.axialCouplings {
                if let other = c.other(cur), !visited.contains(other) {
                    visited.insert(other)
                    parentMap[other] = cur
                    queue.append(other)
                    let rel = neuron.compartments.first { $0.id == other }?.displayAngle ?? 0
                    absAngleMap[other] = (absAngleMap[cur] ?? 0) + rel
                }
            }
        }
        func dendBase(_ cid: UUID) -> CGPoint {
            let ang = absAngleMap[cid] ?? 0
            guard let pid = parentMap[cid] else {
                return CGPoint(x: sc.x + somaR * CGFloat(cos(ang)),
                               y: sc.y + somaR * CGFloat(sin(ang)))
            }
            if pid == neuron.somaCompartmentID {
                return CGPoint(x: sc.x + somaR * CGFloat(cos(ang)),
                               y: sc.y + somaR * CGFloat(sin(ang)))
            }
            guard let pc = neuron.compartments.first(where: { $0.id == pid }) else { return sc }
            let pb = dendBase(pid)
            let pLen = max(CGFloat(pc.length) * ppm, 20 * viewportScale)
            let pAng = absAngleMap[pid] ?? 0
            let frac = CGFloat(neuron.compartments.first { $0.id == cid }?.branchFraction ?? 1)
            return CGPoint(x: pb.x + pLen * frac * CGFloat(cos(pAng)),
                           y: pb.y + pLen * frac * CGFloat(sin(pAng)))
        }
        guard let comp = neuron.compartments.first(where: { $0.id == compartmentID }) else { return nil }
        let base = dendBase(compartmentID)
        let len = max(CGFloat(comp.length) * ppm, 20 * viewportScale)
        let ang = absAngleMap[compartmentID] ?? 0
        return CGPoint(x: base.x + len * CGFloat(cos(ang)),
                       y: base.y + len * CGFloat(sin(ang)))
    }

    var body: some View {
        if let pre = vm.network.neurons.first(where: { $0.id == synapse.preNeuronID }),
           let post = vm.network.neurons.first(where: { $0.id == synapse.postNeuronID }) {
            let isSelected = vm.selection == .synapse(synapse.id)
            let color = edgeColor(isSelected: isSelected)
            let somaR = kNeuronRadius * viewportScale

            // When the synapse targets a specific dendrite compartment, draw the
            // arrow to that compartment's tip instead of the soma center.
            let postPoint: CGPoint = {
                guard let compID = synapse.postCompartmentID,
                      let tip = compartmentTipPos(for: compID, on: post) else {
                    return screenPos(of: post)
                }
                return tip
            }()
            let postR: CGFloat = synapse.postCompartmentID != nil ? kSynapseDotRadius : somaR

            let geom = SynapseGeometry(
                pre: screenPos(of: pre),
                post: postPoint,
                preRadius: somaR,
                postRadius: postR,
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
    let preRadius: CGFloat
    let postRadius: CGFloat
    var straight: Bool = false

    init(pre: CGPoint, post: CGPoint,
         preRadius: CGFloat, postRadius: CGFloat,
         straight: Bool = false) {
        self.pre = pre; self.post = post
        self.preRadius = preRadius; self.postRadius = postRadius
        self.straight = straight
    }

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
        return edgePoint(of: pre, towards: cp, radius: preRadius)
    }

    var endPoint: CGPoint? {
        guard let cp = controlPoint else { return nil }
        return edgePoint(of: post, towards: cp, radius: postRadius)
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

    private func edgePoint(of centre: CGPoint, towards target: CGPoint, radius: CGFloat) -> CGPoint {
        let dx = target.x - centre.x
        let dy = target.y - centre.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > 1e-3 else { return centre }
        return CGPoint(x: centre.x + (dx / d) * radius,
                       y: centre.y + (dy / d) * radius)
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
