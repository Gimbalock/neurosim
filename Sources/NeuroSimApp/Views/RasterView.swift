//
//  RasterView.swift
//  NeuroSimApp
//
//  Raster plot: one horizontal lane per neuron, a thin vertical tick
//  at each detected spike (upward threshold crossing of V at 0 mV).
//  Rendered with Canvas for performance.
//

import SwiftUI
import NeuroSimCore

struct RasterView: View {
    @EnvironmentObject var vm: SimulationViewModel

    private let threshold: Double = 0.0   // mV — matches Simulator default
    private let laneHeight: CGFloat = 48
    private let labelWidth: CGFloat = 80
    private let axisHeight: CGFloat = 24

    // MARK: - Data

    private struct NeuronRaster: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let spikes: [Double]      // spike times in ms
        var firingRate: Double {  // Hz over the visible window
            guard spikes.count >= 2,
                  let t0 = spikes.first, let t1 = spikes.last, t1 > t0
            else { return 0 }
            return Double(spikes.count - 1) / (t1 - t0) * 1000
        }
    }

    private var tEnd: Double { max(vm.simulationTime, vm.plotWindow) }
    private var tStart: Double { max(0, tEnd - vm.plotWindow) }

    private var rasters: [NeuronRaster] {
        vm.network.neurons.enumerated().compactMap { idx, n in
            guard let trace = vm.traces[n.id], !trace.isEmpty else { return nil }
            let spikes = detectSpikes(trace: trace)
            return NeuronRaster(
                id: n.id,
                name: n.name,
                color: kTracePalette[idx % kTracePalette.count],
                spikes: spikes
            )
        }
    }

    private func detectSpikes(trace: [SimulationViewModel.PlotPoint]) -> [Double] {
        var result: [Double] = []
        for i in 1..<trace.count {
            if trace[i-1].v < threshold && trace[i].v >= threshold {
                result.append(trace[i].t)
            }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        if rasters.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rasters.enumerated()), id: \.element.id) { idx, r in
                            rasterLane(r, shaded: idx % 2 == 1)
                            Divider().opacity(0.25)
                        }
                    }
                }
                Divider()
                timeAxisBar
            }
        }
    }

    // MARK: - Raster lane

    private func rasterLane(_ r: NeuronRaster, shaded: Bool) -> some View {
        HStack(spacing: 0) {
            // Label
            VStack(alignment: .trailing, spacing: 1) {
                Text(r.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                Text(String(format: "%.1f Hz", r.firingRate))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: labelWidth, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.leading, 12)

            // Spikes canvas
            Canvas { ctx, size in
                guard size.width > 0 else { return }
                let span = tEnd - tStart
                guard span > 0 else { return }

                for t in r.spikes {
                    guard t >= tStart && t <= tEnd else { continue }
                    let x = (t - tStart) / span * size.width
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 5))
                    path.addLine(to: CGPoint(x: x, y: size.height - 5))
                    ctx.stroke(path, with: .color(r.color.opacity(0.85)), lineWidth: 1.5)
                }
            }
            .frame(maxWidth: .infinity, minHeight: laneHeight, maxHeight: laneHeight)
            .background(shaded ? Color.primary.opacity(0.025) : Color.clear)
            .padding(.trailing, 16)
        }
    }

    // MARK: - Time axis

    private var timeAxisBar: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: labelWidth + 8 + 12)  // align with canvas area
            GeometryReader { geo in
                Canvas { ctx, size in
                    let span = tEnd - tStart
                    guard span > 0, size.width > 0 else { return }
                    let nTicks = max(4, Int(geo.size.width / 80))
                    let step = niceStep(span: span, targetCount: nTicks)
                    var t = ceil(tStart / step) * step
                    while t <= tEnd + 1e-9 {
                        let x = (t - tStart) / span * size.width
                        // Tick
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 0))
                        tick.addLine(to: CGPoint(x: x, y: 4))
                        ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                        // Label
                        ctx.draw(
                            Text(String(format: "%.0f ms", t))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary),
                            at: CGPoint(x: x, y: 6), anchor: .top
                        )
                        t += step
                    }
                }
            }
            .frame(height: axisHeight)
            .padding(.trailing, 16)
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func niceStep(span: Double, targetCount: Int) -> Double {
        let raw = span / Double(targetCount)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm < 2 ? 2 : norm < 5 ? 5 : 10
        return nice * mag
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Lance la simulation pour voir le raster")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
