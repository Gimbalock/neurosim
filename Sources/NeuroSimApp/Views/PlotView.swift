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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Membrane potential V(t)")
                    .font(.headline)
                Spacer()
                Stepper(value: $vm.plotWindow, in: 50...600_000, step: 50) {
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
    }

    private var xDomain: ClosedRange<Double> {
        let end = max(vm.simulationTime, vm.plotWindow)
        return (end - vm.plotWindow)...end
    }
}
