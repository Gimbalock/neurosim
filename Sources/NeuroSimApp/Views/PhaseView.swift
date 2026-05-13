//
//  PhaseView.swift
//  NeuroSimApp
//
//  Phase portrait : V(t) en abscisse, dV/dt(t) en ordonnée.
//  dV/dt est approché par différence finie entre points consécutifs
//  de la trace stockée.  Les sauts temporels trop grands (coupure du
//  buffer) sont ignorés pour éviter les segments parasites.
//
//  Tracé par neurone avec sa couleur habituelle.
//  Le portrait se lit comme une orbite : au repos c'est un point fixe
//  vers (-65, 0) ; pendant un spike c'est une boucle fermée.
//

import SwiftUI
import Charts
import NeuroSimCore

struct PhaseView: View {
    @EnvironmentObject var vm: SimulationViewModel

    // Cursor
    @State private var cursorV:    Double?    = nil
    @State private var cursorDvdt: Double?    = nil
    @State private var cursorAbs:  CGPoint?   = nil

    // MARK: - Data model

    private struct PhasePoint: Identifiable {
        let id = UUID()
        let v: Double       // mV
        let dvdt: Double    // mV/ms
    }

    private struct NeuronPhase: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let points: [PhasePoint]
    }

    // MARK: - Computed data

    private var phases: [NeuronPhase] {
        vm.network.neurons.enumerated().compactMap { idx, n in
            guard let trace = vm.traces[n.id], trace.count >= 2 else { return nil }
            var pts: [PhasePoint] = []
            pts.reserveCapacity(trace.count)
            for i in 1..<trace.count {
                let dt = trace[i].t - trace[i-1].t
                // Skip gaps (buffer trim creates discontinuities)
                guard dt > 0, dt < 2.0 else { continue }
                let dvdt = (trace[i].v - trace[i-1].v) / dt
                // Reject extreme numerical artefacts
                guard dvdt > -2000, dvdt < 2000 else { continue }
                pts.append(PhasePoint(v: trace[i-1].v, dvdt: dvdt))
            }
            guard !pts.isEmpty else { return nil }
            return NeuronPhase(
                id: n.id,
                name: n.name,
                color: kTracePalette[idx % kTracePalette.count],
                points: pts
            )
        }
    }

    // MARK: - Body

    var body: some View {
        if phases.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                phaseChart
                    .padding(20)
            }
        }
    }

    // MARK: - Chart

    @ChartContentBuilder
    private func phaseLines(for phase: NeuronPhase) -> some ChartContent {
        let color = phase.color.opacity(0.65)
        ForEach(phase.points) { pt in
            LineMark(
                x: .value("V (mV)", pt.v),
                y: .value("dV/dt (mV/ms)", pt.dvdt),
                series: .value("Neurone", phase.name)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.0))
        }
    }

    private var phaseChart: some View {
        Chart {
            ForEach(phases) { phase in
                phaseLines(for: phase)
            }
            if let v = cursorV {
                RuleMark(x: .value("", v))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
            }
            if let d = cursorDvdt {
                RuleMark(y: .value("", d))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXAxisLabel("V  (mV)", alignment: .center)
        .chartYAxisLabel("dV/dt  (mV/ms)", alignment: .center)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel()
            }
        }
        .chartLegend(position: .topLeading, spacing: 8)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let f = geo[proxy.plotAreaFrame]
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
                if let loc = cursorAbs, let v = cursorV, let d = cursorDvdt {
                    let lx = loc.x + 10 > f.maxX - 110 ? loc.x - 115 : loc.x + 10
                    let ly = max(loc.y - 4, f.minY + 4)
                    Text(String(format: "V = %.1f mV\ndV/dt = %.1f mV/ms", v, d))
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .position(x: lx + 50, y: ly + 18)
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
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Lance la simulation pour voir le portrait de phase")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
