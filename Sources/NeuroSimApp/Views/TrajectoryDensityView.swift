//
//  TrajectoryDensityView.swift
//  NeuroSimApp
//
//  Two density panels side-by-side, each with its own neuron picker.
//  V(t) vs dV/dt(t), coloured by visit count via a blue→red log-scale colormap.
//

import SwiftUI
import NeuroSimCore

// MARK: - Parent (two panels)

struct TrajectoryDensityView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var leftNeuronID:  UUID? = nil
    @State private var rightNeuronID: UUID? = nil

    var body: some View {
        HStack(spacing: 0) {
            DensityPanel(selectedNeuronID: $leftNeuronID, side: .left)
                .environmentObject(vm)
            Divider()
            DensityPanel(selectedNeuronID: $rightNeuronID, side: .right)
                .environmentObject(vm)
        }
        .onAppear {
            // Default: left = first neuron, right = second (if any)
            let ids = vm.network.neurons.compactMap { n -> UUID? in
                guard let t = vm.traces[n.id], t.count >= 2 else { return nil }
                return n.id
            }
            if leftNeuronID  == nil { leftNeuronID  = ids.first }
            if rightNeuronID == nil { rightNeuronID = ids.dropFirst().first ?? ids.first }
        }
    }
}

// MARK: - Single density panel

private enum PanelSide { case left, right }

private struct DensityPanel: View {
    @EnvironmentObject var vm: SimulationViewModel
    @Binding var selectedNeuronID: UUID?
    let side: PanelSide

    private let nBinsV    = 100
    private let nBinsDvdt = 80

    // MARK: Data model

    private struct DensityGrid {
        let counts: [Int]
        let nV: Int
        let nDvdt: Int
        let vMin: Double;  let vMax: Double
        let dvdtMin: Double; let dvdtMax: Double
        let maxCount: Int
    }

    // MARK: Helpers

    private var availableNeurons: [(id: UUID, name: String)] {
        vm.network.neurons.compactMap { n in
            guard let t = vm.traces[n.id], t.count >= 2 else { return nil }
            return (id: n.id, name: n.name)
        }
    }

    private var resolvedID: UUID? {
        if let id = selectedNeuronID, availableNeurons.contains(where: { $0.id == id }) {
            return id
        }
        return availableNeurons.first?.id
    }

    private func buildGrid(for neuronID: UUID) -> DensityGrid? {
        guard let trace = vm.traces[neuronID], trace.count >= 2 else { return nil }

        var vs:    [Double] = []
        var dvdts: [Double] = []
        vs.reserveCapacity(trace.count)
        dvdts.reserveCapacity(trace.count)

        for i in 1..<trace.count {
            let dt = trace[i].t - trace[i-1].t
            guard dt > 0, dt < 2.0 else { continue }
            let dvdt = (trace[i].v - trace[i-1].v) / dt
            guard dvdt > -2000, dvdt < 2000 else { continue }
            vs.append(trace[i-1].v)
            dvdts.append(dvdt)
        }
        guard !vs.isEmpty,
              let vMin = vs.min(), let vMax = vs.max(), vMax > vMin,
              let dMin = dvdts.min(), let dMax = dvdts.max(), dMax > dMin
        else { return nil }

        let vPad    = (vMax - vMin) * 0.04
        let dvdtPad = (dMax - dMin) * 0.04
        let vLo = vMin - vPad;    let vHi = vMax + vPad
        let dLo = dMin - dvdtPad; let dHi = dMax + dvdtPad

        let nV = nBinsV; let nD = nBinsDvdt
        var counts = [Int](repeating: 0, count: nV * nD)
        for k in 0..<vs.count {
            let ci = min(Int((vs[k]    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
            let ri = min(Int((dvdts[k] - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
            counts[ri * nV + ci] += 1
        }

        return DensityGrid(counts: counts, nV: nV, nDvdt: nD,
                           vMin: vLo, vMax: vHi,
                           dvdtMin: dLo, dvdtMax: dHi,
                           maxCount: max(1, counts.max() ?? 1))
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            if let id = resolvedID, let grid = buildGrid(for: id) {
                densityCanvas(grid: grid)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .background(.black)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Neurone :")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Picker("", selection: Binding(
                get:  { resolvedID },
                set:  { selectedNeuronID = $0 }
            )) {
                ForEach(availableNeurons, id: \.id) { n in
                    Text(n.name).tag(Optional(n.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Spacer()
            colormapLegend
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black)
    }

    // MARK: Colormap legend

    private var colormapLegend: some View {
        HStack(spacing: 4) {
            Text("Faible")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
            GeometryReader { geo in
                Canvas { ctx, size in
                    for px in 0..<Int(size.width) {
                        let t = Double(px) / max(1, size.width - 1)
                        ctx.fill(
                            Path(CGRect(x: CGFloat(px), y: 0, width: 1, height: size.height)),
                            with: .color(densityColor(logT: t))
                        )
                    }
                }
            }
            .frame(width: 72, height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            Text("Élevée")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: Canvas

    private func densityCanvas(grid: DensityGrid) -> some View {
        let marginLeft:   CGFloat = 50
        let marginBottom: CGFloat = 34
        let marginTop:    CGFloat = 8
        let marginRight:  CGFloat = 10

        return GeometryReader { geo in
            Canvas { ctx, size in
                let plotW = size.width  - marginLeft - marginRight
                let plotH = size.height - marginTop  - marginBottom
                guard plotW > 0, plotH > 0 else { return }

                let plotRect = CGRect(x: marginLeft, y: marginTop, width: plotW, height: plotH)

                // Fill background
                ctx.fill(Path(plotRect), with: .color(.black))

                // Density cells
                let cellW = plotW / CGFloat(grid.nV)
                let cellH = plotH / CGFloat(grid.nDvdt)
                let logDenom = log(100.0)

                for row in 0..<grid.nDvdt {
                    for col in 0..<grid.nV {
                        let count = grid.counts[row * grid.nV + col]
                        guard count > 0 else { continue }
                        let t = log(1.0 + Double(count) / Double(grid.maxCount) * 99.0) / logDenom
                        let x = marginLeft + CGFloat(col) * cellW
                        let y = marginTop + plotH - CGFloat(row + 1) * cellH
                        ctx.fill(
                            Path(CGRect(x: x, y: y, width: cellW + 0.6, height: cellH + 0.6)),
                            with: .color(densityColor(logT: t))
                        )
                    }
                }

                // Axes
                var axes = Path()
                axes.move(to:    CGPoint(x: marginLeft, y: marginTop))
                axes.addLine(to: CGPoint(x: marginLeft, y: marginTop + plotH))
                axes.addLine(to: CGPoint(x: marginLeft + plotW, y: marginTop + plotH))
                ctx.stroke(axes, with: .color(.white.opacity(0.35)), lineWidth: 1)

                // X ticks (V)
                let nTicksX = max(3, Int(plotW / 65))
                let spanV   = grid.vMax - grid.vMin
                let stepV   = niceStep(span: spanV, targetCount: nTicksX)
                var v = ceil(grid.vMin / stepV) * stepV
                while v <= grid.vMax + 1e-9 {
                    let x = marginLeft + CGFloat((v - grid.vMin) / spanV) * plotW
                    var tick = Path()
                    tick.move(to:    CGPoint(x: x, y: marginTop + plotH))
                    tick.addLine(to: CGPoint(x: x, y: marginTop + plotH + 4))
                    ctx.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
                    ctx.draw(
                        Text(String(format: "%.0f", v))
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.55)),
                        at: CGPoint(x: x, y: marginTop + plotH + 13), anchor: .center
                    )
                    v += stepV
                }

                // Y ticks (dV/dt)
                let nTicksY = max(3, Int(plotH / 50))
                let spanD   = grid.dvdtMax - grid.dvdtMin
                let stepD   = niceStep(span: spanD, targetCount: nTicksY)
                var d = ceil(grid.dvdtMin / stepD) * stepD
                while d <= grid.dvdtMax + 1e-9 {
                    let y = marginTop + plotH - CGFloat((d - grid.dvdtMin) / spanD) * plotH
                    var tick = Path()
                    tick.move(to:    CGPoint(x: marginLeft, y: y))
                    tick.addLine(to: CGPoint(x: marginLeft - 4, y: y))
                    ctx.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
                    ctx.draw(
                        Text(String(format: "%.0f", d))
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.55)),
                        at: CGPoint(x: marginLeft - 7, y: y), anchor: .trailing
                    )
                    d += stepD
                }

                // X axis label
                ctx.draw(
                    Text("V  (mV)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5)),
                    at: CGPoint(x: marginLeft + plotW / 2, y: size.height - 3), anchor: .bottom
                )
            }

            // Rotated Y label
            Text("dV/dt  (mV/ms)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .position(x: 8, y: geo.size.height / 2)
        }
    }

    // MARK: Colormap

    private func densityColor(logT: Double) -> Color {
        let hue = (1.0 - logT) * 0.67
        return Color(hue: hue, saturation: 1.0, brightness: logT < 0.05 ? logT * 20.0 : 1.0)
    }

    // MARK: niceStep

    private func niceStep(span: Double, targetCount: Int) -> Double {
        let raw  = span / Double(max(1, targetCount))
        let mag  = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm < 2 ? 2 : norm < 5 ? 5 : 10
        return nice * mag
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.2))
            Text("Lance la simulation")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
