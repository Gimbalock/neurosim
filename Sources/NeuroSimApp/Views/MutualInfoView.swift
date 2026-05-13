//
//  MutualInfoView.swift
//  NeuroSimApp
//
//  Two measures on the same binary-binned spike trains:
//
//  1. Mutual Information  I(A;B) vs lag τ  (symmetric)
//       I(A;B) = Σ_{a,b} P(a,b) · log₂[ P(a,b)/(P(a)·P(b)) ]
//
//  2. Transfer Entropy  TE(A→B) and TE(B→A) vs source delay τ  (asymmetric)
//       TE(A→B, τ) = I( B_{t+1} ; A_{t-τ} | B_t )
//                  = Σ P(b_t, a_{t-τ}, b_{t+1}) · log₂[ P(b_{t+1}|b_t,a_{t-τ}) / P(b_{t+1}|b_t) ]
//
//  TE encodes direction: TE(A→B) > TE(B→A) implies net information flow A→B.
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

// MARK: - Transfer Entropy engine

/// TE(source → target, lagBins) using binary bins and history depth = 1.
/// Returns max(0, te) — small negatives are numerical noise.
private func transferEntropy(src: [Bool], tgt: [Bool], lagBins: Int) -> Double {
    let n = tgt.count
    guard lagBins >= 0, n > lagBins + 1 else { return 0 }

    // c[b_t][a_lag][b_{t+1}]  — joint counts for the triplet
    var c = [[[Int]]](repeating: [[Int]](repeating: [0, 0], count: 2), count: 2)
    var total = 0

    for t in lagBins ..< (n - 1) {
        let bt  = tgt[t]           ? 1 : 0
        let bt1 = tgt[t + 1]       ? 1 : 0
        let al  = src[t - lagBins] ? 1 : 0
        c[bt][al][bt1] += 1
        total += 1
    }
    guard total > 0 else { return 0 }
    let N = Double(total)

    var te = 0.0
    for bt in 0 ... 1 {
        let cBT = c[bt][0][0] + c[bt][0][1] + c[bt][1][0] + c[bt][1][1]
        guard cBT > 0 else { continue }
        for al in 0 ... 1 {
            let cBT_AL = c[bt][al][0] + c[bt][al][1]
            guard cBT_AL > 0 else { continue }
            for bt1 in 0 ... 1 {
                let cFull = c[bt][al][bt1]
                guard cFull > 0 else { continue }
                let cBT_BT1 = c[bt][0][bt1] + c[bt][1][bt1]
                guard cBT_BT1 > 0 else { continue }
                let p = Double(cFull) / N
                let pCond_joint = Double(cFull)  / Double(cBT_AL)  // P(b_{t+1}|b_t,a_lag)
                let pCond_marg  = Double(cBT_BT1) / Double(cBT)    // P(b_{t+1}|b_t)
                te += p * log2(pCond_joint / pCond_marg)
            }
        }
    }
    return max(0.0, te)
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

    // MARK: - Transfer Entropy curves

    private struct TEPoint: Identifiable {
        let id = UUID(); let lag: Double; let te: Double; let direction: String
    }

    /// Build binary spike array from spike times
    private func binnedSpikes(_ spikes: [Double], tStart: Double, tEnd: Double) -> [Bool] {
        let nBins = Int((tEnd - tStart) / effectiveBinWidth)
        var arr = [Bool](repeating: false, count: max(nBins, 0))
        for t in spikes {
            let i = Int((t - tStart) / effectiveBinWidth)
            if i >= 0, i < nBins { arr[i] = true }
        }
        return arr
    }

    /// TE(A→B) and TE(B→A) for lags 0…maxLag, interleaved for a single Chart
    private var teCurve: [TEPoint] {
        guard let aID = resolvedA, let bID = resolvedB,
              let (tStart, tEnd) = timeRange else { return [] }
        let spA = spikesFor(aID)
        let spB = spikesFor(bID)
        guard !spA.isEmpty, !spB.isEmpty else { return [] }

        let srcA = binnedSpikes(spA, tStart: tStart, tEnd: tEnd)
        let srcB = binnedSpikes(spB, tStart: tStart, tEnd: tEnd)
        let maxLagBins = max(1, Int(maxLag / effectiveBinWidth))
        var pts: [TEPoint] = []
        for lagBins in 0 ... maxLagBins {
            let lagMs = Double(lagBins) * effectiveBinWidth
            pts.append(TEPoint(lag: lagMs,
                               te: transferEntropy(src: srcA, tgt: srcB, lagBins: lagBins),
                               direction: "A → B"))
            pts.append(TEPoint(lag: lagMs,
                               te: transferEntropy(src: srcB, tgt: srcA, lagBins: lagBins),
                               direction: "B → A"))
        }
        return pts
    }

    private var teAB: [TEPoint] { teCurve.filter { $0.direction == "A → B" } }
    private var teBA: [TEPoint] { teCurve.filter { $0.direction == "B → A" } }

    /// Directionality index DI = TE(A→B) − TE(B→A) at the lag where |DI| is max
    private var directionalityIndex: (di: Double, lagMs: Double) {
        let pairs = zip(teAB, teBA)
        guard let best = pairs.max(by: { abs($0.0.te - $0.1.te) < abs($1.0.te - $1.1.te) })
        else { return (0, 0) }
        return (best.0.te - best.1.te, best.0.lag)
    }

    // Cursor on TE chart
    @State private var cursorTE_Lag: Double?  = nil
    @State private var cursorTE_Abs: CGPoint? = nil

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
                    HSplitView {
                        miChartView.frame(minWidth: 200)
                        teChartView.frame(minWidth: 200)
                    }
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
                }
                if !teCurve.isEmpty {
                    Divider().frame(height: 24)
                    let di = directionalityIndex
                    let arrow = di.di > 0 ? "A → B" : "B → A"
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DI = TE(A→B) − TE(B→A)").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(String(format: "%+.4f bits  ·  %@  ·  τ=%.0f ms",
                                    di.di, arrow, di.lagMs))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(di.di > 0 ? Color.orange : Color.teal)
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

    // MARK: - TE vs lag chart

    @ViewBuilder
    private var teChartView: some View {
        let pts = teCurve
        if pts.isEmpty {
            ZStack {
                Color.clear
                VStack(spacing: 6) {
                    Text("Transfer Entropy")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("TE(A→B) & TE(B→A) vs délai source")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        } else {
            let ab = teAB; let ba = teBA
            let yMax = max(pts.map(\.te).max() ?? 0.001, 0.001)
            Chart {
                ForEach(ab) { pt in
                    LineMark(x: .value("Délai τ (ms)", pt.lag),
                             y: .value("TE (bits)", pt.te))
                    .foregroundStyle(by: .value("Direction", pt.direction))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(ba) { pt in
                    LineMark(x: .value("Délai τ (ms)", pt.lag),
                             y: .value("TE (bits)", pt.te))
                    .foregroundStyle(by: .value("Direction", pt.direction))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartForegroundStyleScale(["A → B": Color.orange, "B → A": Color.teal])
            .chartYScale(domain: 0.0 ... yMax)
            .chartXAxisLabel("Délai source τ (ms)", alignment: .center)
            .chartYAxisLabel("TE (bits)", alignment: .center)
            .chartLegend(position: .topLeading, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) {
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
                                guard rx >= 0, rx <= f.width else { cursorTE_Lag = nil; return }
                                cursorTE_Abs = loc
                                cursorTE_Lag = proxy.value(atX: rx, as: Double.self)
                            case .ended:
                                cursorTE_Lag = nil; cursorTE_Abs = nil
                            }
                        }
                    if let loc = cursorTE_Abs {
                        Path { p in
                            p.move(to: CGPoint(x: loc.x, y: f.minY))
                            p.addLine(to: CGPoint(x: loc.x, y: f.maxY))
                        }
                        .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .allowsHitTesting(false)
                    }
                    if let loc = cursorTE_Abs, let lag = cursorTE_Lag {
                        let nearAB = ab.min(by: { abs($0.lag - lag) < abs($1.lag - lag) })
                        let nearBA = ba.min(by: { abs($0.lag - lag) < abs($1.lag - lag) })
                        let lx = loc.x + 10 > f.maxX - 145 ? loc.x - 150 : loc.x + 10
                        Text(String(format: "τ = %.1f ms\nA→B = %.4f bits\nB→A = %.4f bits",
                                    lag, nearAB?.te ?? 0, nearBA?.te ?? 0))
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .position(x: lx + 60, y: max(loc.y, f.minY + 32))
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
