//
//  PhaseView.swift
//  NeuroSimApp
//
//  Phase portrait : V(t) en abscisse, dV/dt(t) en ordonnée.
//
//  Cursor trick: RuleMark inside Chart forces Swift Charts to re-layout on every
//  hover event, causing flicker. Instead we draw cursor lines as Path views in
//  the chartOverlay using the raw screen position (cursorAbs), which only
//  updates the overlay layer — the chart marks are never touched.
//

import SwiftUI
import Charts
import NeuroSimCore

struct PhaseView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var cursorV:    Double?  = nil
    @State private var cursorDvdt: Double?  = nil
    @State private var cursorAbs:  CGPoint? = nil

    // MARK: - Data model

    private struct PhasePoint: Identifiable {
        let id = UUID()
        let v: Double; let dvdt: Double
    }
    private struct NeuronPhase: Identifiable {
        let id: UUID; let name: String; let color: Color; let points: [PhasePoint]
    }

    private var phases: [NeuronPhase] {
        vm.network.neurons.enumerated().compactMap { idx, n in
            guard let trace = vm.traces[n.id], trace.count >= 2 else { return nil }
            var pts: [PhasePoint] = []
            pts.reserveCapacity(trace.count)
            for i in 1..<trace.count {
                let dt = trace[i].t - trace[i-1].t
                guard dt > 0, dt < 2.0 else { continue }
                let dvdt = (trace[i].v - trace[i-1].v) / dt
                guard dvdt > -2000, dvdt < 2000 else { continue }
                pts.append(PhasePoint(v: trace[i-1].v, dvdt: dvdt))
            }
            guard !pts.isEmpty else { return nil }
            return NeuronPhase(id: n.id, name: n.name,
                               color: kTracePalette[idx % kTracePalette.count], points: pts)
        }
    }

    // MARK: - Body

    var body: some View {
        if phases.isEmpty { emptyState } else { phaseChart.padding(20) }
    }

    // MARK: - Chart

    @ChartContentBuilder
    private func phaseLines(for phase: NeuronPhase) -> some ChartContent {
        let color = phase.color.opacity(0.65)
        ForEach(phase.points) { pt in
            LineMark(x: .value("V (mV)", pt.v),
                     y: .value("dV/dt (mV/ms)", pt.dvdt),
                     series: .value("Neurone", phase.name))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.0))
        }
    }

    private var phaseChart: some View {
        Chart {
            ForEach(phases) { phase in phaseLines(for: phase) }
            // ↑ No RuleMark — cursor drawn in overlay so chart marks stay stable
        }
        .chartXAxisLabel("V  (mV)", alignment: .center)
        .chartYAxisLabel("dV/dt  (mV/ms)", alignment: .center)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)); AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)); AxisValueLabel()
            }
        }
        .chartLegend(position: .topLeading, spacing: 8)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let f = proxy.plotFrame.map { geo[$0] } ?? .zero
                // Hover tracking
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let rx = loc.x - f.minX
                            let ry = loc.y - f.minY
                            guard rx >= 0, rx <= f.width, ry >= 0, ry <= f.height else {
                                cursorV = nil; return
                            }
                            cursorAbs  = loc
                            cursorV    = proxy.value(atX: rx, as: Double.self)
                            cursorDvdt = proxy.value(atY: ry, as: Double.self)
                        case .ended:
                            cursorV = nil; cursorDvdt = nil; cursorAbs = nil
                        }
                    }
                // Cursor crosshair drawn as Path — does NOT touch chart marks
                if let loc = cursorAbs {
                    let style = StrokeStyle(lineWidth: 1, dash: [4, 4])
                    Path { p in
                        p.move(to: CGPoint(x: loc.x, y: f.minY))
                        p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                    }
                    .stroke(Color.white.opacity(0.45), style: style)
                    .allowsHitTesting(false)
                    Path { p in
                        p.move(to: CGPoint(x: f.minX, y: loc.y))
                        p.addLine(to: CGPoint(x: f.maxX, y: loc.y))
                    }
                    .stroke(Color.white.opacity(0.45), style: style)
                    .allowsHitTesting(false)
                }
                // Label
                if let loc = cursorAbs, let v = cursorV, let d = cursorDvdt {
                    let lx = loc.x + 10 > f.maxX - 115 ? loc.x - 120 : loc.x + 10
                    let ly = max(loc.y, f.minY + 24)
                    Text(String(format: "V = %.2f mV\ndV/dt = %.1f mV/ms", v, d))
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .position(x: lx + 53, y: ly)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Lance la simulation pour voir le portrait de phase")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
