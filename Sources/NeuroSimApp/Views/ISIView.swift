//
//  ISIView.swift
//  NeuroSimApp
//
//  Inter-Spike Interval (ISI) histogram.
//  For each neuron with ≥ 2 detected spikes, computes all consecutive
//  intervals and displays a bar-chart histogram with mean ISI and
//  estimated firing rate.
//

import SwiftUI
import Charts
import NeuroSimCore

struct ISIView: View {
    @EnvironmentObject var vm: SimulationViewModel

    private let threshold: Double = 0.0   // mV

    // MARK: - Data model

    private struct ISIData: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let isis: [Double]        // inter-spike intervals in ms
        var mean: Double   { isis.isEmpty ? 0 : isis.reduce(0, +) / Double(isis.count) }
        var cv: Double {          // coefficient of variation
            guard isis.count >= 2 else { return 0 }
            let m = mean
            let variance = isis.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(isis.count - 1)
            return m > 0 ? sqrt(variance) / m : 0
        }
        var firingRate: Double { mean > 0 ? 1000 / mean : 0 }   // Hz
    }

    private struct HistBin: Identifiable {
        let id = UUID()
        let center: Double
        let width: Double
        let count: Int
    }

    // MARK: - Computed data

    private var isiData: [ISIData] {
        vm.network.neurons.enumerated().compactMap { idx, n in
            guard let trace = vm.traces[n.id], !trace.isEmpty else { return nil }
            let spikes = detectSpikes(trace: trace)
            guard spikes.count >= 2 else { return nil }
            let isis = zip(spikes, spikes.dropFirst()).map { $1 - $0 }
            return ISIData(
                id: n.id,
                name: n.name,
                color: kTracePalette[idx % kTracePalette.count],
                isis: isis
            )
        }
    }

    // MARK: - Body

    var body: some View {
        if isiData.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(isiData) { d in
                        isiCard(d)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - ISI card

    private func isiCard(_ d: ISIData) -> some View {
        let bins = makeBins(d.isis)
        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(d.color)
                    .frame(width: 9, height: 9)
                Text(d.name)
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "ISI moy.  %.1f ms  (%.1f Hz)", d.mean, d.firingRate))
                    Text(String(format: "CV  %.2f   —  %d intervalles", d.cv, d.isis.count))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            // Histogram
            Chart(bins) { bin in
                BarMark(
                    x: .value("ISI (ms)", bin.center),
                    y: .value("n", bin.count),
                    width: .fixed(max(3, CGFloat(bin.width) - 1))
                )
                .foregroundStyle(d.color.opacity(0.75))
            }
            .chartXAxisLabel("ISI (ms)", alignment: .center)
            .chartYAxisLabel("Effectif")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .frame(height: 160)
        }
        .padding(14)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Binning

    private func makeBins(_ values: [Double]) -> [HistBin] {
        guard !values.isEmpty else { return [] }
        guard let mn = values.min(), let mx = values.max(), mx > mn else {
            return [HistBin(center: values[0], width: 1, count: values.count)]
        }
        let nBins = max(8, min(40, Int(sqrt(Double(values.count)) * 2.5)))
        let w = (mx - mn) / Double(nBins)
        var counts = [Int](repeating: 0, count: nBins)
        for v in values {
            let i = min(Int((v - mn) / w), nBins - 1)
            counts[i] += 1
        }
        return (0..<nBins).map { i in
            HistBin(center: mn + (Double(i) + 0.5) * w, width: w, count: counts[i])
        }
    }

    // MARK: - Spike detection

    private func detectSpikes(trace: [SimulationViewModel.PlotPoint]) -> [Double] {
        var result: [Double] = []
        for i in 1..<trace.count {
            if trace[i-1].v < threshold && trace[i].v >= threshold {
                result.append(trace[i].t)
            }
        }
        return result
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Pas assez de spikes")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("L'ISI nécessite au moins 2 spikes par neurone.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
