//
//  PlotView.swift
//  NeuroSimApp
//
//  V(t) plot driven by Swift Charts. Each neuron gets its own series with
//  its own colour. The buffer is already downsampled by the ViewModel; we
//  only have to render.
//

import SwiftUI
import Charts
import NeuroSimCore

struct PlotView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var cursorAbs: CGPoint? = nil
    @State private var cursorT:   Double?  = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Membrane potential V(t)")
                    .font(.headline)
                Spacer()
                Stepper(value: $vm.plotWindow, in: 50...600_000, step: 500) {
                    Text("Window: \(Int(vm.plotWindow)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .frame(maxWidth: 220)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            chart
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(vm.network.neurons, id: \.id) { neuron in
                let pts = vm.traces[neuron.id] ?? []
                ForEach(pts) { p in
                    LineMark(
                        x: .value("t (ms)", p.t),
                        y: .value("V (mV)", p.v)
                    )
                    .foregroundStyle(by: .value("Neuron", neuron.name))
                    .interpolationMethod(.linear)
                }
            }
            // Stable y-range so spikes don't make it jitter.
            RuleMark(y: .value("Threshold", 0.0))
                .foregroundStyle(.gray.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartYScale(domain: -90...50)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let f = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let rx = loc.x - f.minX
                            let ry = loc.y - f.minY
                            guard rx >= 0, rx <= f.width,
                                  ry >= 0, ry <= f.height
                            else { cursorT = nil; cursorAbs = nil; return }
                            cursorAbs = loc
                            cursorT   = proxy.value(atX: rx, as: Double.self)
                        case .ended:
                            cursorT = nil; cursorAbs = nil
                        }
                    }
                // Crosshair
                if let loc = cursorAbs {
                    let dash = StrokeStyle(lineWidth: 1, dash: [4, 4])
                    Path { p in
                        p.move(to:    CGPoint(x: loc.x, y: f.minY))
                        p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                    }
                    .stroke(Color.white.opacity(0.5), style: dash)
                    .allowsHitTesting(false)
                    Path { p in
                        p.move(to:    CGPoint(x: f.minX, y: loc.y))
                        p.addLine(to: CGPoint(x: f.maxX, y: loc.y))
                    }
                    .stroke(Color.white.opacity(0.25), style: dash)
                    .allowsHitTesting(false)
                }
                // Value label
                if let loc = cursorAbs, let t = cursorT {
                    let neurons = vm.network.neurons
                    let labelW: CGFloat = 140
                    let lineH:  CGFloat = 14
                    let labelH  = lineH + lineH * CGFloat(neurons.count) + 10
                    let onRight = loc.x + 12 + labelW < f.maxX
                    let lx = onRight ? loc.x + 12 : loc.x - 12 - labelW
                    let rawLY = loc.y - labelH / 2
                    let ly = max(f.minY + 2, min(rawLY, f.maxY - labelH - 2))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "t = %.2f ms", t))
                            .foregroundStyle(.primary)
                        ForEach(Array(neurons.enumerated()), id: \.element.id) { idx, n in
                            let pts = vm.traces[n.id] ?? []
                            let v   = interpolatedV(pts, at: t)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(kTracePalette[idx % kTracePalette.count])
                                    .frame(width: 5, height: 5)
                                Text(v.map { String(format: "%.2f mV", $0) } ?? "—")
                            }
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: lx + labelW / 2, y: ly + labelH / 2)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func interpolatedV(_ points: [SimulationViewModel.PlotPoint],
                                at t: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        if points.count == 1 { return points[0].v }
        if t <= points[0].t  { return points[0].v }
        let last = points[points.count - 1]
        if t >= last.t { return last.v }
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

    private var xDomain: ClosedRange<Double> {
        let end = max(vm.simulationTime, vm.plotWindow)
        return (end - vm.plotWindow)...end
    }
}
