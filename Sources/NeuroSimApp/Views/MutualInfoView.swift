//
//  MutualInfoView.swift
//  NeuroSimApp
//
//  Mutual information I(A ; B) between two spike trains, as a function of
//  time lag τ.  Approach: bin both trains at Δt ms, build a joint binary
//  distribution P(a,b) ∈ {0,1}², compute
//
//      I(A;B) = Σ_{a,b} P(a,b) · log₂[ P(a,b) / (P(a)·P(b)) ]   (bits)
//
//  and sweep τ from −maxLag to +maxLag by shifting train B.
//  The zero-lag MI and the peak MI (+ its lag) are reported in the header.
//  Normalised MI = I / min(H(A), H(B)) is also shown.
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - MI engine (file-private, fast enough for computed properties)

private func spikeTimes(trace: [SimulationViewModel.PlotPoint],
                        threshold: Double = 0.0) -> [Double] {
    var result: [Double] = []
    for i in 1..<trace.count {
        if trace[i-1].v < threshold && trace[i].v >= threshold {
            result.append(trace[i].t)
        }
    }
    return result
}

private func binaryEntropy(_ p: Double) -> Double {
    guard p > 1e-12, p < 1 - 1e-12 else { return 0 }
    return -(p * log2(p) + (1-p) * log2(1-p))
}

private func mutualInfo(spikesA: [Double], spikesB: [Double],
                        tStart: Double, tEnd: Double,
                        binWidth: Double, lagMs: Double) -> Double {
    let nBins = Int((tEnd - tStart) / binWidth)
    guard nBins > 4 else { return 0 }

    var a = [Bool](repeating: false, count: nBins)
    var b = [Bool](repeating: false, count: nBins)

    for t in spikesA {
        let i = Int((t - tStart) / binWidth)
        if i >= 0, i < nBins { a[i] = true }
    }
    for t in spikesB {
        let i = Int((t + lagMs - tStart) / binWidth)
        if i >= 0, i < nBins { b[i] = true }
    }

    var n = (n00: 0, n01: 0, n10: 0, n11: 0)
    for i in 0..<nBins {
        switch (a[i], b[i]) {
        case (false, false): n.n00 += 1
        case (false, true):  n.n01 += 1
        case (true,  false): n.n10 += 1
        case (true,  true):  n.n11 += 1
        }
    }
    let N = Double(nBins)
    let p00 = Double(n.n00) / N, p01 = Double(n.n01) / N
    let p10 = Double(n.n10) / N, p11 = Double(n.n11) / N
    let pA0 = p00 + p01, pA1 = p10 + p11
    let pB0 = p00 + p10, pB1 = p01 + p11

    func term(_ pab: Double, _ pa: Double, _ pb: Double) -> Double {
        guard pab > 1e-12, pa > 1e-12, pb > 1e-12 else { return 0 }
        return pab * log2(pab / (pa * pb))
    }
    return term(p00, pA0, pB0) + term(p01, pA0, pB1)
         + term(p10, pA1, pB0) + term(p11, pA1, pB1)
}

// MARK: - MutualInfoView

struct MutualInfoView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var neuronAID: UUID? = nil
    @State private var neuronBID: UUID? = nil
    @State private var binWidth: Double = 5.0    // ms
    @State private var maxLag:   Double = 100.0  // ms

    // Cursor on MI chart
    @State private var cursorLag: Double?  = nil
    @State private var cursorMI:  Double?  = nil
    @State private var cursorAbs: CGPoint? = nil

    // MARK: - Helpers

    private var availableNeurons: [(id: UUID, name: String)] {
        vm.network.neurons.compactMap { n in
            guard let t = vm.traces[n.id], !t.isEmpty else { return nil }
            return (n.id, n.name)
        }
    }
    private var resolvedA: UUID? {
        if let id = neuronAID, availableNeurons.contains(where: { $0.id == id }) { return id }
        return availableNeurons.first?.id
    }
    private var resolvedB: UUID? {
        if let id = neuronBID, availableNeurons.contains(where: { $0.id == id }) { return id }
        return availableNeurons.dropFirst().first?.id ?? availableNeurons.first?.id
    }

    private var timeRange: (Double, Double)? {
        let all = vm.traces.values.flatMap { $0 }.map(\.t)
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return nil }
        return (lo, hi)
    }

    private func spikesFor(_ id: UUID?) -> [Double] {
        guard let id, let trace = vm.traces[id] else { return [] }
        return spikeTimes(trace: trace)
    }

    // MARK: - MI curve (computed synchronously; fast for Δt ≥ 1 ms)

    private struct MIPoint: Identifiable {
        let id = UUID(); let lag: Double; let mi: Double
    }

    private var effectiveBinWidth: Double { max(binWidth, 1.0) }

    private var miCurve: [MIPoint] {
        guard let aID = resolvedA, let bID = resolvedB,
              let (tStart, tEnd) = timeRange else { return [] }
        let spA = spikesFor(aID)
        let spB = spikesFor(bID)
        guard !spA.isEmpty, !spB.isEmpty else { return [] }

        let step = effectiveBinWidth
        var pts: [MIPoint] = []
        var lag = -maxLag
        while lag <= maxLag + 1e-9 {
            pts.append(MIPoint(lag: lag,
                               mi: mutualInfo(spikesA: spA, spikesB: spB,
                                              tStart: tStart, tEnd: tEnd,
                                              binWidth: effectiveBinWidth, lagMs: lag)))
            lag += step
        }
        return pts
    }

    // Entropy at lag = 0 for each train (binary)
    private var entropyA: Double {
        guard let (tStart, tEnd) = timeRange else { return 0 }
        let sp = spikesFor(resolvedA)
        let nBins = Int((tEnd - tStart) / effectiveBinWidth)
        guard nBins > 0 else { return 0 }
        var fired = 0
        for t in sp {
            let i = Int((t - tStart) / effectiveBinWidth)
            if i >= 0, i < nBins { fired += 1 }
        }
        return binaryEntropy(Double(fired) / Double(nBins))
    }
    private var entropyB: Double {
        guard let (tStart, tEnd) = timeRange else { return 0 }
        let sp = spikesFor(resolvedB)
        let nBins = Int((tEnd - tStart) / effectiveBinWidth)
        guard nBins > 0 else { return 0 }
        var fired = 0
        for t in sp {
            let i = Int((t - tStart) / effectiveBinWidth)
            if i >= 0, i < nBins { fired += 1 }
        }
        return binaryEntropy(Double(fired) / Double(nBins))
    }

    private var miAtZero: Double { miCurve.min(by: { abs($0.lag) < abs($1.lag) })?.mi ?? 0 }
    private var miPeak:   MIPoint? { miCurve.max(by: { $0.mi < $1.mi }) }
    private var normalizedMI: Double {
        let hMin = min(entropyA, entropyB)
        guard hMin > 1e-12 else { return 0 }
        return miAtZero / hMin
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if availableNeurons.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        rasterPanel(id: resolvedA, label: "A")
                        Divider()
                        rasterPanel(id: resolvedB, label: "B")
                    }
                    .frame(height: 100)
                    Divider()
                    miChartView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { autoSelect() }
        .onChange(of: vm.network.neurons.map(\.id)) { _, _ in autoSelect() }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // Pickers
                pickerCol("A", id: Binding(get: { resolvedA }, set: { neuronAID = $0 }))
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                pickerCol("B", id: Binding(get: { resolvedB }, set: { neuronBID = $0 }))

                Divider().frame(height: 24)

                numField("Δt bin", value: $binWidth, unit: "ms")
                numField("Lag max", value: $maxLag,   unit: "ms")

                Divider().frame(height: 24)

                // Summary stats
                if !miCurve.isEmpty {
                    statLabel("MI (τ=0)", String(format: "%.4f bits", miAtZero))
                    statLabel("NMI",      String(format: "%.3f", normalizedMI))
                    statLabel("H(A)",     String(format: "%.4f bits", entropyA))
                    statLabel("H(B)",     String(format: "%.4f bits", entropyB))
                    if let pk = miPeak {
                        statLabel("MI max",
                                  String(format: "%.4f bits  @  τ=%.0f ms", pk.mi, pk.lag))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func pickerCol(_ label: String, id: Binding<UUID?>) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text("Neurone \(label)").font(.system(size: 9)).foregroundStyle(.secondary)
            Picker("", selection: id) {
                ForEach(availableNeurons, id: \.id) { n in
                    Text(n.name).tag(Optional(n.id))
                }
            }
            .labelsHidden().frame(width: 110)
        }
    }

    @ViewBuilder
    private func numField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 46)
                    .multilineTextAlignment(.trailing)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
        }
    }

    // MARK: - Mini raster panel

    @ViewBuilder
    private func rasterPanel(id: UUID?, label: String) -> some View {
        let neuronName = id.flatMap { uid in availableNeurons.first(where: { $0.id == uid })?.name } ?? "—"
        let spikes = spikesFor(id)
        let (tStart, tEnd) = timeRange ?? (0, 1)

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Neurone \(label) · \(neuronName)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(spikes.count) spikes")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.75))
            }
            .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 3)

            MiniRasterCanvas(spikes: spikes, tStart: tStart, tEnd: tEnd)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - MI vs lag chart

    @ViewBuilder
    private var miChartView: some View {
        let pts = miCurve
        if pts.isEmpty {
            ZStack {
                Color.clear
                Text(availableNeurons.count < 2
                     ? "Il faut au moins 2 neurones avec des spikes"
                     : "Sélectionne deux neurones")
                    .foregroundStyle(.tertiary).font(.caption)
            }
        } else {
            Chart {
                ForEach(pts) { pt in
                    AreaMark(x: .value("τ (ms)", pt.lag), y: .value("MI (bits)", pt.mi))
                        .foregroundStyle(.orange.opacity(0.12))
                    LineMark(x: .value("τ (ms)", pt.lag), y: .value("MI (bits)", pt.mi))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                // lag = 0 reference line
                RuleMark(x: .value("", 0.0))
                    .foregroundStyle(.white.opacity(0.2))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYScale(domain: 0.0 ... max(pts.map(\.mi).max() ?? 0.001, 0.001))
            .chartXAxisLabel("Décalage τ (ms)", alignment: .center)
            .chartYAxisLabel("I(A ; B)  (bits)", alignment: .center)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 10)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4))
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4))
                    AxisValueLabel()
                }
            }
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
                                    cursorLag = nil; return
                                }
                                cursorAbs = loc
                                cursorLag = proxy.value(atX: rx, as: Double.self)
                                cursorMI  = proxy.value(atY: ry, as: Double.self)
                            case .ended:
                                cursorLag = nil; cursorMI = nil; cursorAbs = nil
                            }
                        }
                    // Cursor lines
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
                    // Nearest MI value from curve (more accurate than raw proxy Y)
                    if let loc = cursorAbs, let lag = cursorLag {
                        let nearest = pts.min(by: { abs($0.lag - lag) < abs($1.lag - lag) })
                        let mi = nearest?.mi ?? (cursorMI ?? 0)
                        let lx = loc.x + 10 > f.maxX - 135 ? loc.x - 140 : loc.x + 10
                        Text(String(format: "τ = %.1f ms\nI = %.4f bits", lag, mi))
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .position(x: lx + 55, y: max(loc.y, f.minY + 24))
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Lance la simulation pour calculer l'information mutuelle")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Auto-select

    private func autoSelect() {
        if neuronAID == nil || !availableNeurons.contains(where: { $0.id == neuronAID }) {
            neuronAID = availableNeurons.first?.id
        }
        if neuronBID == nil || !availableNeurons.contains(where: { $0.id == neuronBID }) {
            neuronBID = availableNeurons.dropFirst().first?.id ?? availableNeurons.first?.id
        }
    }
}

// MARK: - Mini raster canvas

private struct MiniRasterCanvas: View {
    let spikes: [Double]
    let tStart: Double
    let tEnd:   Double

    var body: some View {
        Canvas { ctx, size in
            let span = tEnd - tStart
            guard span > 0, size.width > 0, size.height > 0 else { return }

            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.orange.opacity(0.04)))

            for t in spikes {
                let x = CGFloat((t - tStart) / span) * size.width
                var tick = Path()
                tick.move(to:    CGPoint(x: x, y: 4))
                tick.addLine(to: CGPoint(x: x, y: size.height - 4))
                ctx.stroke(tick, with: .color(.orange.opacity(0.75)), lineWidth: 0.8)
            }
            ctx.stroke(Path(CGRect(origin: .zero, size: size)),
                       with: .color(.white.opacity(0.08)), lineWidth: 0.5)
        }
    }
}
