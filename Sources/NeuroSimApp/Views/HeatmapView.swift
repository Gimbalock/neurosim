//
//  HeatmapView.swift
//  NeuroSimApp
//
//  2D parameter heatmap — screen two parameters of any neuron over a
//  configurable grid and display trajectory-density error as a colour map.
//
//  Layout:
//    ┌─────────────────┬──────────────────────────────────────┐
//    │  Sidebar        │  Heatmap canvas  (blue = good)       │
//    │  · neuron       │  Y ↑                                 │
//    │  · param X      │    │ ■ ■ ■ ■ ■ ■ ■                  │
//    │  · param Y      │    │ ■ ■ ★ ■ ■ ■ ■   ★ = best       │
//    │  · grid config  │    └──────────────────────────→ X    │
//    │  · duration     │  Bottom: legend + value readout      │
//    │  · reference    ├──────────────────────────────────────┤
//    │  · [Start]      │  Hover: show exact error + values    │
//    └─────────────────┴──────────────────────────────────────┘
//

import SwiftUI
import NeuroSimCore

// MARK: - Spacing helpers

private enum GridSpacing: String, CaseIterable, Identifiable {
    case linear     = "Linéaire"
    case logarithm  = "Logarithmique"
    var id: String { rawValue }
}

// MARK: - Reference source

private enum RefSource: String, CaseIterable {
    case neuron = "Neurone"
    case csv    = "Fichier CSV"
}

// MARK: - View

struct HeatmapView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @StateObject private var runner = HeatmapSweepRunner()

    // ── Neuron & param selection ──────────────────────────────────────────
    @State private var selectedNeuronIdx: Int = 0
    @State private var xParamIdx: Int = 0
    @State private var yParamIdx: Int = 1
    @State private var optimParams: [OptimParam] = []

    // ── Grid config ───────────────────────────────────────────────────────
    @State private var xSteps:     Int    = 8
    @State private var ySteps:     Int    = 8
    @State private var xMin:       Double = 0
    @State private var xMax:       Double = 1
    @State private var yMin:       Double = 0
    @State private var yMax:       Double = 1
    @State private var xSpacing:   GridSpacing = .linear
    @State private var ySpacing:   GridSpacing = .linear

    // ── Simulation config ─────────────────────────────────────────────────
    @State private var simDuration: Double = 500.0   // ms
    @State private var refNeuronIdx: Int = 0

    // ── CSV reference ─────────────────────────────────────────────────────
    @State private var refSource: RefSource = .neuron
    @State private var csvRefPoints: [(v: Double, dvdt: Double)] = []
    @State private var csvFileName: String = ""
    @State private var csvLoadError: String = ""

    // ── Hover / selection ─────────────────────────────────────────────────
    @State private var hoveredCell: Int? = nil
    @State private var selectedCell: Int? = nil

    // ── Colour scale ───────────────────────────────────────────────────────
    /// When true, colour is mapped on log(error) instead of error.
    /// Recommended whenever errors span several orders of magnitude — it
    /// prevents a few high-error outliers from compressing all "good" cells
    /// into an indistinguishable dark-blue band.
    @State private var logColorScale: Bool = true

    // MARK: - Derived helpers

    private var availableNeurons: [HHNeuron] { vm.network.neurons }

    private var selectedNeuron: HHNeuron? {
        guard availableNeurons.indices.contains(selectedNeuronIdx)
        else { return availableNeurons.first }
        return availableNeurons[selectedNeuronIdx]
    }

    private var xParam: OptimParam? { optimParams[safe: xParamIdx] }
    private var yParam: OptimParam? { optimParams[safe: yParamIdx] }

    private var refPoints: [(v: Double, dvdt: Double)] {
        switch refSource {
        case .csv:
            return csvRefPoints
        case .neuron:
            guard availableNeurons.indices.contains(refNeuronIdx),
                  let trace = vm.traces[availableNeurons[refNeuronIdx].id],
                  trace.count >= 2 else { return [] }
            let raw = trace.map { (t: $0.t, v: $0.v) }
            return phasePlanePoints(from: raw)
        }
    }

    private func makeGrid(min: Double, max: Double, steps: Int,
                           spacing: GridSpacing) -> [Double] {
        guard steps >= 2, max > min else {
            if steps == 1 { return [min] }
            return []
        }
        switch spacing {
        case .linear:
            return (0..<steps).map { min + Double($0) / Double(steps - 1) * (max - min) }
        case .logarithm:
            guard min > 0 else { return makeGrid(min: min, max: max, steps: steps, spacing: .linear) }
            let lo = log10(min); let hi = log10(max)
            return (0..<steps).map { pow(10, lo + Double($0) / Double(steps - 1) * (hi - lo)) }
        }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, maxWidth: 270)
                .background(.background.secondary)

            VStack(spacing: 0) {
                heatmapPanel
                Divider()
                statusBar
            }
        }
        .onAppear { rebuildParams() }
        .onChange(of: selectedNeuronIdx) { _, _ in rebuildParams() }
        .onChange(of: vm.network.neurons.count) { _, _ in rebuildParams() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Text("Heatmap 2D")
                    .font(.title3.bold())
                    .padding(.top, 4)

                // ── Neuron ──────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Neurone (modèle)")
                        Picker("", selection: $selectedNeuronIdx) {
                            ForEach(Array(availableNeurons.enumerated()), id: \.offset) { i, n in
                                Text(n.name).tag(i)
                            }
                        }
                        .labelsHidden()

                        sectionLabel("Source de référence")
                        Picker("", selection: $refSource) {
                            ForEach(RefSource.allCases, id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if refSource == .neuron {
                            Picker("", selection: $refNeuronIdx) {
                                ForEach(Array(availableNeurons.enumerated()), id: \.offset) { i, n in
                                    let hasTrace = vm.traces[n.id]?.count ?? 0 >= 2
                                    Text(n.name + (hasTrace ? "" : " ✗")).tag(i)
                                }
                            }
                            .labelsHidden()
                            if refPoints.isEmpty {
                                Label("Lancez une simulation d'abord",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            // CSV loader
                            Button {
                                loadCSVFile()
                            } label: {
                                Label(csvFileName.isEmpty ? "Charger CSV…" : "Changer…",
                                      systemImage: "doc.text")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if !csvFileName.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(csvFileName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(.system(size: 10))
                                Text("\(csvRefPoints.count) pts plan de phase")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            if !csvLoadError.isEmpty {
                                Label(csvLoadError, systemImage: "xmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            } else if csvRefPoints.isEmpty && csvFileName.isEmpty {
                                Label("Sélectionnez un fichier CSV",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } label: {
                    Label("Neurone", systemImage: "brain")
                        .font(.caption.bold())
                }

                // ── Parameters ───────────────────────────────────────
                if optimParams.isEmpty {
                    Label("Aucun paramètre", systemImage: "exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            // X Param
                            sectionLabel("Axe X")
                            Picker("", selection: $xParamIdx) {
                                ForEach(Array(optimParams.enumerated()), id: \.offset) { i, p in
                                    Text(p.label).tag(i)
                                }
                            }
                            .labelsHidden()
                            paramRangeRow(label: "X",
                                          minVal: $xMin, maxVal: $xMax,
                                          steps: $xSteps, spacing: $xSpacing)

                            Divider()

                            // Y Param
                            sectionLabel("Axe Y")
                            Picker("", selection: $yParamIdx) {
                                ForEach(Array(optimParams.enumerated()), id: \.offset) { i, p in
                                    Text(p.label).tag(i)
                                }
                            }
                            .labelsHidden()
                            paramRangeRow(label: "Y",
                                          minVal: $yMin, maxVal: $yMax,
                                          steps: $ySteps, spacing: $ySpacing)
                        }
                    } label: {
                        Label("Paramètres", systemImage: "slider.horizontal.3")
                            .font(.caption.bold())
                    }
                    .onChange(of: xParamIdx) { _, i in loadBounds(forX: i) }
                    .onChange(of: yParamIdx) { _, i in loadBounds(forY: i) }
                }

                // ── Duration ─────────────────────────────────────────
                GroupBox {
                    HStack {
                        Text("Durée sim.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("ms", value: $simDuration, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .font(.system(size: 11).monospacedDigit())
                        Text("ms").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Simulation", systemImage: "clock")
                        .font(.caption.bold())
                }

                // ── Grid summary ──────────────────────────────────────
                let nTotal = xSteps * ySteps
                Text("\(nTotal) simulations × \(Int(simDuration)) ms")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)

                // ── Start / Stop ──────────────────────────────────────
                Button {
                    if runner.isRunning { runner.stop() }
                    else { startSweep() }
                } label: {
                    Label(runner.isRunning ? "Arrêter" : "Démarrer",
                          systemImage: runner.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(runner.isRunning ? .red : .accentColor)
                .disabled(!runner.isRunning && (xParam == nil || yParam == nil ||
                           xParamIdx == yParamIdx || refPoints.isEmpty))

                // Progress
                if runner.totalEvals > 0 {
                    ProgressView(value: runner.progress).progressViewStyle(.linear)
                    Text(runner.status)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }

                // ── Best / Apply ──────────────────────────────────────
                if let r = runner.result, let bi = r.bestIndex,
                   !runner.isRunning {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Meilleur point", systemImage: "star.fill")
                            .font(.caption.bold()).foregroundStyle(.yellow)

                        bestRow("X = \(r.xParam.label)", value: r.xValues[r.col(ofFlat: bi)],
                                unit: r.xParam.unit)
                        bestRow("Y = \(r.yParam.label)", value: r.yValues[r.row(ofFlat: bi)],
                                unit: r.yParam.unit)
                        bestRow("Erreur", value: r.errors[bi], unit: "")

                        HStack(spacing: 6) {
                            Button("Appliquer") {
                                if let n = selectedNeuron {
                                    runner.applyBest(to: vm, neuronID: n.id)
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Appliquer + Run") {
                                if let n = selectedNeuron {
                                    runner.applyBest(to: vm, neuronID: n.id)
                                    vm.play()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Spacer(minLength: 12)
            }
            .padding(12)
        }
    }

    // MARK: - Heatmap canvas

    private var heatmapPanel: some View {
        GeometryReader { geo in
            if let r = runner.result {
                ZStack {
                    heatmapCanvas(r: r, size: geo.size)
                    // Hover overlay (handled inside canvas via gesture)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func heatmapCanvas(r: HeatmapResult, size: CGSize) -> some View {
        let margin: CGFloat = 60
        let plotW = max(10, size.width  - margin * 2)
        let plotH = max(10, size.height - margin * 2)
        let cellW = plotW / CGFloat(r.nX)
        let cellH = plotH / CGFloat(r.nY)

        let eMin  = r.minError
        let eMax  = r.maxError
        let span  = max(eMax - eMin, 1e-10)

        // Pre-compute log bounds once (safe: eMin may be 0)
        let eMinSafe = max(eMin, 1e-12)
        let eMaxSafe = max(eMax, eMinSafe * 1.0001)
        let logMin   = log(eMinSafe)
        let logSpan  = max(log(eMaxSafe) - logMin, 1e-15)

        // Normalise a single error value → [0,1] for heatColor()
        let normT: (Double) -> Double = { e in
            if logColorScale {
                // Log scale: spreads colours evenly across orders of magnitude
                let t = (log(max(e, eMinSafe)) - logMin) / logSpan
                return Swift.max(0, Swift.min(1, t))
            } else {
                return Swift.max(0, Swift.min(1, (e - eMin) / span))
            }
        }

        Canvas { ctx, _ in
            // Draw cells (y is inverted: low Y index = low param value = bottom)
            for iy in 0..<r.nY {
                for ix in 0..<r.nX {
                    let e = r.errors[iy * r.nX + ix]
                    let x = margin + CGFloat(ix) * cellW
                    let y = margin + CGFloat(r.nY - 1 - iy) * cellH
                    let rect = CGRect(x: x, y: y, width: cellW, height: cellH)

                    if e.isNaN {
                        ctx.fill(Path(rect), with: .color(.gray.opacity(0.15)))
                    } else {
                        ctx.fill(Path(rect), with: .color(heatColor(normT(e))))
                    }
                }
            }

            // Best-cell star marker
            if let bi = r.bestIndex {
                let ix = r.col(ofFlat: bi)
                let iy = r.row(ofFlat: bi)
                let cx = margin + (CGFloat(ix) + 0.5) * cellW
                let iyFlipped = CGFloat(r.nY - 1 - iy)
                let cy = margin + iyFlipped * cellH + cellH * 0.5
                let star = Path(ellipseIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10))
                ctx.fill(star, with: .color(.white))
                ctx.stroke(star, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
            }

            // Hover cell border
            if let hc = hoveredCell, hc < r.errors.count {
                let ix = r.col(ofFlat: hc)
                let iy = r.row(ofFlat: hc)
                let x = margin + CGFloat(ix) * cellW
                let y = margin + CGFloat(r.nY - 1 - iy) * cellH
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                ctx.stroke(Path(rect), with: .color(.white), lineWidth: 2)
            }

            // X axis labels (every nX/5 ticks)
            let xStep = max(1, r.nX / 5)
            for ix in stride(from: 0, to: r.nX, by: xStep) {
                let val = r.xValues[ix]
                let lx = margin + (CGFloat(ix) + 0.5) * cellW
                let label = formatVal(val)
                let res = ctx.resolve(Text(label).font(.system(size: 9)))
                ctx.draw(res, at: CGPoint(x: lx, y: margin + plotH + 12),
                         anchor: .center)
            }

            // Y axis labels (every nY/5 ticks)
            let yStep = max(1, r.nY / 5)
            for iy in stride(from: 0, to: r.nY, by: yStep) {
                let val = r.yValues[iy]
                let ly  = margin + CGFloat(r.nY - 1 - iy) * cellH + cellH * 0.5
                let res = ctx.resolve(Text(formatVal(val)).font(.system(size: 9)))
                ctx.draw(res, at: CGPoint(x: margin - 8, y: ly), anchor: .trailing)
            }
        }
        .gesture(
            SpatialTapGesture()
                .onEnded { val in
                    let cell = cellAt(pos: val.location, r: r,
                                      margin: margin, cellW: cellW, cellH: cellH)
                    if let c = cell, !r.errors[c].isNaN {
                        selectedCell = c
                    }
                }
        )
        .onContinuousHover { phase in
            if case .active(let loc) = phase {
                hoveredCell = cellAt(pos: loc, r: r,
                                     margin: margin, cellW: cellW, cellH: cellH)
            } else {
                hoveredCell = nil
            }
        }
        // Axis labels (SwiftUI overlay — for rotation)
        .overlay(alignment: .bottom) {
            Text(r.xParam.label + (r.xParam.unit.isEmpty ? "" : " (\(r.xParam.unit))"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
        }
        .overlay(alignment: .leading) {
            Text(r.yParam.label + (r.yParam.unit.isEmpty ? "" : " (\(r.yParam.unit))"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 20)
        }
    }

    private func cellAt(pos: CGPoint, r: HeatmapResult,
                         margin: CGFloat, cellW: CGFloat, cellH: CGFloat) -> Int? {
        let ix = Int((pos.x - margin) / cellW)
        let iyInv = Int((pos.y - margin) / cellH)
        let iy = r.nY - 1 - iyInv
        guard ix >= 0, ix < r.nX, iy >= 0, iy < r.nY else { return nil }
        return iy * r.nX + ix
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let hc = hoveredCell, let r = runner.result, !r.errors[hc].isNaN {
                let ix = r.col(ofFlat: hc)
                let iy = r.row(ofFlat: hc)
                Text("X=\(formatVal(r.xValues[ix]))  Y=\(formatVal(r.yValues[iy]))  Erreur=\(String(format: "%.3e", r.errors[hc]))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let sc = selectedCell, let r = runner.result, !r.errors[sc].isNaN {
                let ix = r.col(ofFlat: sc)
                let iy = r.row(ofFlat: sc)
                Text("Sélection: X=\(formatVal(r.xValues[ix]))  Y=\(formatVal(r.yValues[iy]))  E=\(String(format: "%.3e", r.errors[sc]))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.primary)

                Button("Appliquer ce point") {
                    if let n = selectedNeuron {
                        runner.applyCell(flatIndex: sc, to: vm, neuronID: n.id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Survolez la carte pour afficher les valeurs")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Log / Linear toggle
            Toggle(isOn: $logColorScale) {
                Text("Échelle log")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .help("Normalise les couleurs en log(erreur) pour mieux distinguer les zones de faible erreur")
            // Colour scale legend
            colorLegend
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.tertiary)
    }

    private var colorLegend: some View {
        HStack(spacing: 4) {
            Text("Bon").font(.system(size: 9)).foregroundStyle(.secondary)
            LinearGradient(
                colors: stride(from: 0.0, through: 1.0, by: 0.05).map { heatColor($0) },
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 80, height: 10)
            .cornerRadius(3)
            Text("Mauvais").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "squareshape.split.3x3")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Configurez les paramètres et lancez le sweep")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Pré-requis : simuler le neurone de référence pour obtenir sa trace")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func rebuildParams() {
        guard let neuron = selectedNeuron else { optimParams = []; return }
        optimParams = makeOptimParams(for: neuron)
        xParamIdx = 0
        yParamIdx = min(1, optimParams.count - 1)
        loadBounds(forX: xParamIdx)
        loadBounds(forY: yParamIdx)
    }

    private func loadBounds(forX i: Int) {
        guard let p = optimParams[safe: i] else { return }
        xMin = p.minBound; xMax = p.maxBound
    }
    private func loadBounds(forY i: Int) {
        guard let p = optimParams[safe: i] else { return }
        yMin = p.minBound; yMax = p.maxBound
    }

    private func startSweep() {
        guard let neuron = selectedNeuron,
              let xP = xParam, let yP = yParam,
              xParamIdx != yParamIdx else { return }

        let xVals = makeGrid(min: xMin, max: xMax, steps: xSteps, spacing: xSpacing)
        let yVals = makeGrid(min: yMin, max: yMax, steps: ySteps, spacing: ySpacing)
        guard !xVals.isEmpty, !yVals.isEmpty else { return }

        runner.start(vm: vm, neuronID: neuron.id,
                     xParam: xP, yParam: yP,
                     xValues: xVals, yValues: yVals,
                     refPoints: refPoints,
                     simDuration: simDuration)
    }

    // MARK: - CSV loading

    private func loadCSVFile() {
        let panel = NSOpenPanel()
        panel.title = "Charger une trajectoire de référence (CSV)"
        panel.message = "Colonnes attendues : temps (ms), tension (mV) — ligne d'en-tête optionnelle"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        parseCSV(url: url)
    }

    private func parseCSV(url: URL) {
        csvLoadError = ""
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rows = text.components(separatedBy: .newlines)
                           .map { $0.trimmingCharacters(in: .whitespaces) }
                           .filter { !$0.isEmpty }

            var pairs: [(t: Double, v: Double)] = []

            for row in rows {
                // Try comma first, then semicolons and tabs as fallback
                let sep: Character = row.contains(",") ? ","
                                   : row.contains(";") ? ";"
                                   : "\t"
                let cols = row.split(separator: sep, omittingEmptySubsequences: true)
                              .map { $0.trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 2 else { continue }
                // Skip header rows (first cell is not numeric)
                guard let t = Double(cols[0]), let v = Double(cols[1]) else { continue }
                pairs.append((t: t, v: v))
            }

            guard pairs.count >= 2 else {
                csvLoadError = "Aucune donnée numérique trouvée"
                csvRefPoints = []
                csvFileName  = ""
                return
            }

            // Sort by time (safety), then build phase-plane
            pairs.sort { $0.t < $1.t }
            csvRefPoints = phasePlanePoints(from: pairs)
            csvFileName  = url.lastPathComponent
        } catch {
            csvLoadError = error.localizedDescription
            csvRefPoints = []
            csvFileName  = ""
        }
    }

    private func formatVal(_ v: Double) -> String {
        if abs(v) >= 100 { return String(format: "%.0f", v) }
        if abs(v) >= 1   { return String(format: "%.2g", v) }
        return String(format: "%.2e", v)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func paramRangeRow(label: String,
                                minVal: Binding<Double>, maxVal: Binding<Double>,
                                steps: Binding<Int>, spacing: Binding<GridSpacing>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Min").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24)
                TextField("min", value: minVal, format: .number)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10).monospacedDigit())
                Text("Max").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24)
                TextField("max", value: maxVal, format: .number)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10).monospacedDigit())
            }
            HStack(spacing: 4) {
                Text("Pts").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24)
                TextField("n", value: steps, format: .number)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10).monospacedDigit())
                    .frame(width: 40)
                Picker("", selection: spacing) {
                    ForEach(GridSpacing.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .labelsHidden().font(.system(size: 10))
            }
        }
    }

    @ViewBuilder
    private func bestRow(_ label: String, value: Double, unit: String) -> some View {
        HStack {
            Text(label + " :").foregroundStyle(.secondary)
            Text(formatVal(value) + (unit.isEmpty ? "" : " \(unit)")).fontWeight(.medium)
        }
        .font(.system(size: 11))
    }
}
