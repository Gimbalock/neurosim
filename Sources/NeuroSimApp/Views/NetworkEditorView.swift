//
//  NetworkEditorView.swift
//  NeuroSimApp
//
//  Graphical editor for the neural network. Two tool modes:
//
//    Select   — click neurons or synapses to select; drag a neuron to move it.
//               Double-click empty space to add a new neuron.
//    Connect  — drag from one neuron onto another to create a chemical synapse.
//
//  Live state: each neuron's fill colour reflects its instantaneous membrane
//  potential (blue = hyperpolarised, white ~ rest, red = spiking).
//

import SwiftUI
import NeuroSimCore

enum EditorTool: String, CaseIterable, Identifiable {
    case select  = "Select"
    case connect = "Connect"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .select:  return "cursorarrow"
        case .connect: return "arrow.triangle.branch"
        }
    }
}

struct NetworkEditorView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @State private var tool: EditorTool = .select
    @State private var draftSynapse: DraftSynapse? = nil

    struct DraftSynapse {
        let fromID: UUID
        var currentPoint: CGPoint
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $tool) {
                ForEach(EditorTool.allCases) { t in
                    Label(t.rawValue, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Button {
                vm.addNeuron(at: 200, y: 200)
            } label: {
                Label("Add neuron", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                vm.removeSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(vm.selection == .none)

            Spacer()

            Text("\(vm.network.neurons.count) neurons · \(vm.network.synapses.count) synapses")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.secondary)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                // Background for clicks on empty space.
                // NB: count:2 must be declared *before* count:1 — SwiftUI
                // otherwise resolves single-tap immediately and the double-
                // tap is never recognised.
                Color(NSColor.textBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Double-click: add a neuron near the click site
                        // (we don't get the location from this overload, so
                        // fall back to the canvas centre).
                        vm.addNeuron(at: Double(proxy.size.width / 2),
                                     y: Double(proxy.size.height / 2))
                    }
                    .onTapGesture(count: 1) {
                        vm.selection = .none
                    }

                // Edges (drawn first so neurons sit on top)
                ForEach(vm.network.synapses, id: \.id) { syn in
                    SynapseEdgeView(synapse: syn)
                }

                // Draft connection arrow (during connect-mode drag)
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
                    NeuronNodeView(neuron: neuron, tool: tool, draftSynapse: $draftSynapse)
                }
            }
            .focusable()
            .onKeyPress(.delete) { vm.removeSelected(); return .handled }
            .onKeyPress(.deleteForward) { vm.removeSelected(); return .handled }
        }
    }
}

// MARK: - Neuron node

private struct NeuronNodeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let neuron: HHNeuron
    let tool: EditorTool
    @Binding var draftSynapse: NetworkEditorView.DraftSynapse?

    /// Captured at gesture start so we can interpret `value.translation`
    /// (which is cumulative since drag start) as an absolute offset.
    @State private var dragOrigin: CGPoint? = nil

    private let radius: CGFloat = 28

    var body: some View {
        let isSelected = vm.selection == .neuron(neuron.id)
        let v = vm.traces[neuron.id]?.last?.v ?? -65.0

        ZStack {
            Circle()
                .fill(activityColor(v: v))
                .overlay(
                    Circle().stroke(isSelected ? Color.accentColor : .gray,
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
        .onTapGesture {
            vm.selection = .neuron(neuron.id)
        }
    }

    private var nodeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                switch tool {
                case .select:
                    if dragOrigin == nil {
                        dragOrigin = CGPoint(x: neuron.positionX, y: neuron.positionY)
                    }
                    let origin = dragOrigin ?? .zero
                    vm.setNeuronPosition(
                        neuron.id,
                        x: Double(origin.x) + Double(value.translation.width),
                        y: Double(origin.y) + Double(value.translation.height)
                    )
                case .connect:
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
            }
            .onEnded { value in
                switch tool {
                case .select:
                    dragOrigin = nil
                case .connect:
                    let endPoint = CGPoint(
                        x: neuron.positionX + Double(value.translation.width),
                        y: neuron.positionY + Double(value.translation.height)
                    )
                    // Find a target neuron under the endpoint.
                    if let target = vm.network.neurons.first(where: {
                        hypot($0.positionX - Double(endPoint.x),
                              $0.positionY - Double(endPoint.y)) < Double(radius)
                    }), target.id != neuron.id {
                        vm.addSynapse(from: neuron.id, to: target.id)
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

private struct SynapseEdgeView: View {
    @EnvironmentObject var vm: SimulationViewModel
    let synapse: Synapse

    var body: some View {
        if let pre = vm.network.neurons.first(where: { $0.id == synapse.preNeuronID }),
           let post = vm.network.neurons.first(where: { $0.id == synapse.postNeuronID }) {
            let isSelected = vm.selection == .synapse(synapse.id)
            let color = edgeColor(isSelected: isSelected)
            ZStack {
                ArrowShape(
                    from: CGPoint(x: pre.positionX, y: pre.positionY),
                    to: CGPoint(x: post.positionX, y: post.positionY),
                    nodeRadius: 28
                )
                .stroke(color, style: StrokeStyle(lineWidth: isSelected ? 3 : 2, lineCap: .round))
                // Wider invisible hit area for easier clicking.
                ArrowShape(
                    from: CGPoint(x: pre.positionX, y: pre.positionY),
                    to: CGPoint(x: post.positionX, y: post.positionY),
                    nodeRadius: 28
                )
                .stroke(Color.white.opacity(0.001), lineWidth: 14)
                .contentShape(Rectangle())
                .onTapGesture { vm.selection = .synapse(synapse.id) }
            }
        }
    }

    private func edgeColor(isSelected: Bool) -> Color {
        if isSelected { return .accentColor }
        if let chem = synapse as? ChemicalSynapse {
            return chem.reversal > -30 ? .green : .red // excitatory vs inhibitory
        }
        if synapse is GapJunction { return .orange }
        return .gray
    }
}

// MARK: - Shapes

private struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let nodeRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = to.x - from.x
        let dy = to.y - from.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > 1e-3 else { return path }
        let ux = dx / d, uy = dy / d

        let start = CGPoint(x: from.x + ux * nodeRadius, y: from.y + uy * nodeRadius)
        let end   = CGPoint(x: to.x   - ux * nodeRadius, y: to.y   - uy * nodeRadius)

        path.move(to: start)
        path.addLine(to: end)

        // Arrowhead
        let headLen: CGFloat = 10
        let headW: CGFloat = 6
        let perp = CGPoint(x: -uy, y: ux)
        let base = CGPoint(x: end.x - ux * headLen, y: end.y - uy * headLen)
        path.move(to: end)
        path.addLine(to: CGPoint(x: base.x + perp.x * headW,
                                 y: base.y + perp.y * headW))
        path.move(to: end)
        path.addLine(to: CGPoint(x: base.x - perp.x * headW,
                                 y: base.y - perp.y * headW))
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
