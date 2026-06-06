//
//  TrajectoryDensityView.swift
//  NeuroSimApp
//
//  Layout:
//    ┌──────────────────┬──────────────────┬──────────┐
//    │ Référence        │ Modèle           │ Sidebar  │
//    │ (import/neurone) │ (neurone simulé) │ params   │
//    ├──────────────────┴──────────────────┤          │
//    │ Courbe erreur E vs itérations       │          │
//    └─────────────────────────────────────┴──────────┘
//
//  Resolution: per-panel dvdtMax slider clips the display range so the
//  user can zoom into subthreshold dynamics without losing spike info.
//  Error is computed on a shared axis range (union) for mathematical validity.
//

import SwiftUI
import Charts
import UniformTypeIdentifiers
import NeuroSimCore

// MARK: - Shared types (file-private)

fileprivate struct ImportedTrace {
    let name: String
    let points: [(v: Double, dvdt: Double)]
}

fileprivate struct DensityGrid {
    let counts: [Int]
    let nV: Int
    let nDvdt: Int
    let vMin: Double;    let vMax: Double
    let dvdtMin: Double; let dvdtMax: Double
    let maxCount: Int
    var total: Int { counts.reduce(0, +) }
}

// MARK: - Root view

struct TrajectoryDensityView: View {
    @EnvironmentObject var vm: SimulationViewModel

    // Panel selections
    @State private var leftNeuronID:  UUID? = nil
    @State private var rightNeuronID: UUID? = nil
    @State private var importedTrace: ImportedTrace? = nil
    @State private var useImportLeft  = false

    // Display range (for resolution control)
    @State private var leftDvdtMax:  Double = 500
    @State private var rightDvdtMax: Double = 500

    // Optimizable parameters (built from the Modèle neuron)
    @State private var optimParams: [OptimParam] = []

    // Optimizer
    @StateObject private var runner = OptimizationRunner()
    @State private var optimConfig  = OptimConfig()

    // Objective mode
    private enum ObjectiveMode: String, CaseIterable {
        case density = "Densité"
        case burst   = "Burst"
    }
    @State private var objectiveMode: ObjectiveMode = .density
    // Burst-counting objective config
    @State private var burstAISID:          UUID?   = nil    // nil → soma
    @State private var burstRestingV:       Double  = -80.0
    @State private var burstTargetBPS:      Double  = 1.0
    @State private var burstTargetAPs:      Double  = 12.5
    @State private var burstTargetPeriodMs: Double  = 1000.0

    // Grid resolution (higher → finer detail)
    private let nBinsV    = 180
    private let nBinsDvdt = 140

    // Density threshold — bins below this fraction of maxCount are hidden
    @State private var leftThreshold:  Double = 0.005   // 0.5 %
    @State private var rightThreshold: Double = 0.005

    // MARK: - Available neurons

    private var availableNeurons: [(id: UUID, name: String)] {
        vm.network.neurons.compactMap { n in
            guard let t = vm.traces[n.id], t.count >= 2 else { return nil }
            return (id: n.id, name: n.name)
        }
    }

    private var resolvedLeft: UUID? {
        if let id = leftNeuronID, availableNeurons.contains(where: { $0.id == id }) { return id }
        return availableNeurons.first?.id
    }

    private var resolvedRight: UUID? {
        if let id = rightNeuronID, availableNeurons.contains(where: { $0.id == id }) { return id }
        return availableNeurons.dropFirst().first?.id ?? availableNeurons.first?.id
    }

    // MARK: - Point extraction

    private func pointsFromNeuron(_ id: UUID) -> [(v: Double, dvdt: Double)] {
        guard let trace = vm.traces[id], trace.count >= 2 else { return [] }
        var pts: [(v: Double, dvdt: Double)] = []
        pts.reserveCapacity(trace.count)
        for i in 1..<trace.count {
            let dt = trace[i].t - trace[i-1].t
            guard dt > 0, dt < 2.0 else { continue }
            let dvdt = (trace[i].v - trace[i-1].v) / dt
            guard abs(dvdt) < 5000 else { continue }
            pts.append((v: trace[i-1].v, dvdt: dvdt))
        }
        return pts
    }

    // MARK: - Grid builder (display — clipped by dvdtMax + threshold zoom)

    /// Two-pass grid builder:
    ///  1. Full grid → find the extent of bins above `minFraction × maxCount`
    ///  2. Rebuild with those tighter bounds so axes zoom into the dense region.
    private func buildDisplayGrid(pts: [(v: Double, dvdt: Double)],
                                  dvdtMax: Double,
                                  minFraction: Double = 0) -> DensityGrid? {
        let clipped = pts.filter { abs($0.dvdt) <= dvdtMax }
        guard !clipped.isEmpty else { return nil }

        // Pass 1 — full range grid
        guard let full = buildGridInRange(pts: clipped) else { return nil }

        // If no threshold, return immediately
        guard minFraction > 0 else { return full }

        // Find axis extent of bins that survive the threshold
        let minCount = max(1, Int(Double(full.maxCount) * minFraction))
        var colMin = full.nV - 1;   var colMax = 0
        var rowMin = full.nDvdt - 1; var rowMax = 0
        var anyAbove = false
        for row in 0..<full.nDvdt {
            for col in 0..<full.nV {
                guard full.counts[row * full.nV + col] >= minCount else { continue }
                if col < colMin { colMin = col }; if col > colMax { colMax = col }
                if row < rowMin { rowMin = row }; if row > rowMax { rowMax = row }
                anyAbove = true
            }
        }
        guard anyAbove else { return full }

        // Convert bin indices → data coordinates with 5 % padding
        let vSpan  = full.vMax    - full.vMin
        let dSpan  = full.dvdtMax - full.dvdtMin
        let vBinW  = vSpan  / Double(full.nV)
        let dBinH  = dSpan  / Double(full.nDvdt)

        var vLo = full.vMin    + Double(colMin) * vBinW
        var vHi = full.vMin    + Double(colMax + 1) * vBinW
        var dLo = full.dvdtMin + Double(rowMin) * dBinH
        var dHi = full.dvdtMin + Double(rowMax + 1) * dBinH

        // 5 % padding so the outermost surviving bins aren't flush against the axes
        let vPad = (vHi - vLo) * 0.05; let dPad = (dHi - dLo) * 0.05
        vLo -= vPad; vHi += vPad; dLo -= dPad; dHi += dPad

        // Pass 2 — rebuild at cropped range
        return buildGridInRange(pts: clipped, vLo: vLo, vHi: vHi, dLo: dLo, dHi: dHi)
    }

    private func buildGridInRange(pts: [(v: Double, dvdt: Double)],
                                  vLo: Double? = nil, vHi: Double? = nil,
                                  dLo: Double? = nil, dHi: Double? = nil) -> DensityGrid? {
        guard !pts.isEmpty else { return nil }
        let vs    = pts.map(\.v);    let dvdts = pts.map(\.dvdt)
        guard let vMin = vLo ?? vs.min(),    let vMax = vHi ?? vs.max(),    vMax > vMin,
              let dMin = dLo ?? dvdts.min(), let dMax = dHi ?? dvdts.max(), dMax > dMin
        else { return nil }
        // Add padding only when computing from data (not when caller already passed bounds)
        let vLo2: Double; let vHi2: Double; let dLo2: Double; let dHi2: Double
        if vLo == nil {
            let p = (vMax - vMin) * 0.04; vLo2 = vMin - p; vHi2 = vMax + p
        } else { vLo2 = vMin; vHi2 = vMax }
        if dLo == nil {
            let p = (dMax - dMin) * 0.04; dLo2 = dMin - p; dHi2 = dMax + p
        } else { dLo2 = dMin; dHi2 = dMax }

        let nV = nBinsV; let nD = nBinsDvdt
        var counts = [Int](repeating: 0, count: nV * nD)
        for p in pts {
            guard p.v >= vLo2, p.v <= vHi2, p.dvdt >= dLo2, p.dvdt <= dHi2 else { continue }
            let ci = min(Int((p.v    - vLo2) / (vHi2 - vLo2) * Double(nV)), nV - 1)
            let ri = min(Int((p.dvdt - dLo2) / (dHi2 - dLo2) * Double(nD)), nD - 1)
            counts[ri * nV + ci] += 1
        }
        return DensityGrid(counts: counts, nV: nV, nDvdt: nD,
                           vMin: vLo2, vMax: vHi2, dvdtMin: dLo2, dvdtMax: dHi2,
                           maxCount: max(1, counts.max() ?? 1))
    }

    // MARK: - Error computation (shared axis range, full data)

    private var leftPoints: [(v: Double, dvdt: Double)] {
        if useImportLeft, let imp = importedTrace { return imp.points }
        if let id = resolvedLeft { return pointsFromNeuron(id) }
        return []
    }

    private var rightPoints: [(v: Double, dvdt: Double)] {
        guard let id = resolvedRight else { return [] }
        return pointsFromNeuron(id)
    }

    private var currentError: Double? {
        let lp = leftPoints; let rp = rightPoints
        guard !lp.isEmpty, !rp.isEmpty else { return nil }

        // Shared axis range = union
        let allV    = (lp + rp).map { $0.v }
        let allDvdt = (lp + rp).map { $0.dvdt }
        guard let vLo = allV.min(), let vHi = allV.max(), vHi > vLo,
              let dLo = allDvdt.min(), let dHi = allDvdt.max(), dHi > dLo else { return nil }

        guard let ga = buildGridInRange(pts: lp, vLo: vLo, vHi: vHi, dLo: dLo, dHi: dHi),
              let gb = buildGridInRange(pts: rp, vLo: vLo, vHi: vHi, dLo: dLo, dHi: dHi)
        else { return nil }

        let tA = max(1, ga.total); let tB = max(1, gb.total)
        var e = 0.0
        for i in 0..<ga.counts.count {
            let d = Double(ga.counts[i]) / Double(tA) - Double(gb.counts[i]) / Double(tB)
            e += d * d
        }
        return e
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    leftPanelView
                        .frame(maxWidth: .infinity)
                    Divider()
                    rightPanelView
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.3)

                HStack(spacing: 0) {
                    errorChartView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().opacity(0.2)
                    paramEvolutionView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            sidebarView
                .frame(width: 190)
        }
        .background(.black)
        .onAppear {
            let ids = availableNeurons.map { $0.id }
            if leftNeuronID  == nil { leftNeuronID  = ids.first }
            if rightNeuronID == nil { rightNeuronID = ids.dropFirst().first ?? ids.first }
            rebuildOptimParams()
            loadOptimSettings()
        }
        .onChange(of: rightNeuronID) { _, _ in rebuildOptimParams() }
        .onChange(of: optimConfig)   { _, _ in persistOptimSettings() }
        .onChange(of: optimParams)   { _, _ in persistOptimSettings() }
    }

    private func rebuildOptimParams() {
        guard let id = resolvedRight,
              let neuron = vm.network.neurons.first(where: { $0.id == id })
        else { return }
        // Preserve active flags and bounds for params that already exist
        let old = Dictionary(uniqueKeysWithValues: optimParams.map { ($0.target, $0) })
        var fresh = makeOptimParams(for: neuron)
        for i in fresh.indices {
            if let prev = old[fresh[i].target] {
                fresh[i].isActive  = prev.isActive
                fresh[i].minBound  = prev.minBound
                fresh[i].maxBound  = prev.maxBound
            }
        }
        optimParams = fresh
    }

    // Restore OptimConfig + param flags/bounds from the document (called on appear).
    private func loadOptimSettings() {
        guard let doc = vm.optimSettings else { return }
        optimConfig = doc.toConfig()
        let overrides = doc.paramOverrides()
        for i in optimParams.indices {
            if let saved = overrides[optimParams[i].target] {
                optimParams[i].isActive  = saved.isActive
                optimParams[i].minBound  = saved.minBound
                optimParams[i].maxBound  = saved.maxBound
            }
        }
    }

    // Write current settings back to the view model so the next Save includes them.
    private func persistOptimSettings() {
        vm.optimSettings = optimConfig.toDoc(params: optimParams)
    }

    // MARK: - Left panel (Référence — import ou neurone)

    private var leftPanelView: some View {
        VStack(spacing: 0) {
            leftToolbar
            Divider().opacity(0.25)
            Group {
                let leftGrid: DensityGrid? = {
                    if useImportLeft, let imp = importedTrace {
                        return buildDisplayGrid(pts: imp.points, dvdtMax: leftDvdtMax, minFraction: leftThreshold)
                    }
                    if let id = resolvedLeft {
                        return buildDisplayGrid(pts: pointsFromNeuron(id), dvdtMax: leftDvdtMax, minFraction: leftThreshold)
                    }
                    return nil
                }()
                if let grid = leftGrid {
                    ZStack(alignment: .bottomLeading) {
                        DensityCanvas(grid: grid, minFraction: leftThreshold)
                        thresholdControl(value: $leftThreshold)
                            .padding(6)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                    }
                } else {
                    panelEmpty(hint: useImportLeft ? "Importer un fichier" : "Lance la simulation")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftToolbar: some View {
        HStack(spacing: 8) {
            Text("Référence")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))

            Menu {
                ForEach(availableNeurons, id: \.id) { n in
                    Button(n.name) { useImportLeft = false; leftNeuronID = n.id }
                }
                if !availableNeurons.isEmpty { Divider() }
                Button("Importer un fichier…") { importFile() }
                if let imp = importedTrace {
                    Button("Trace importée : \(imp.name)") { useImportLeft = true }
                }
            } label: {
                pickerLabel(
                    text: useImportLeft
                        ? (importedTrace?.name ?? "Import")
                        : (availableNeurons.first(where: { $0.id == resolvedLeft })?.name ?? "—")
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            dvdtSlider(value: $leftDvdtMax)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black)
    }

    // MARK: - Right panel (Modèle simulé)

    private var rightPanelView: some View {
        VStack(spacing: 0) {
            rightToolbar
            Divider().opacity(0.25)
            Group {
                let pts: [(v: Double, dvdt: Double)] = {
                    if runner.isRunning && !runner.lastBestPoints.isEmpty {
                        return runner.lastBestPoints
                    }
                    if let id = resolvedRight { return pointsFromNeuron(id) }
                    return []
                }()
                if let grid = buildDisplayGrid(pts: pts, dvdtMax: rightDvdtMax, minFraction: rightThreshold) {
                    ZStack(alignment: .bottomLeading) {
                        DensityCanvas(grid: grid, minFraction: rightThreshold)
                        thresholdControl(value: $rightThreshold)
                            .padding(6)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                    }
                } else {
                    panelEmpty(hint: runner.isRunning ? "Calcul en cours…" : "Lance la simulation")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rightToolbar: some View {
        HStack(spacing: 8) {
            Text("Modèle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))

            Picker("", selection: Binding(
                get: { resolvedRight },
                set: { rightNeuronID = $0 }
            )) {
                ForEach(availableNeurons, id: \.id) { n in
                    Text(n.name).tag(Optional(n.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            Spacer()
            dvdtSlider(value: $rightDvdtMax)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black)
    }

    // MARK: - Density threshold control

    private func thresholdControl(value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.4))
            Slider(value: value, in: 0.0...0.10, step: 0.001)
                .frame(width: 64)
                .tint(.white.opacity(0.5))
            Text(String(format: "%.1f%%", value.wrappedValue * 100))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - dV/dt range slider

    private func dvdtSlider(value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.3))
            Slider(value: value, in: 15...1000, step: 5)
                .frame(width: 70)
                .tint(.white.opacity(0.35))
            Text(String(format: "±%.0f", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 44, alignment: .leading)
        }
    }

    // MARK: - Picker label

    private func pickerLabel(text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Error chart

    private var errorChartView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Convergence  E = Σ(p_ref − p_mod)²")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if runner.bestError < .infinity {
                    Text(String(format: "E = %.3e  (iter. %d)", runner.bestError, runner.iteration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                } else if let e = currentError {
                    Text(String(format: "E courante = %.4e", e))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if runner.errorHistory.isEmpty {
                Spacer()
                Text("L'historique de convergence s'affichera ici")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.2))
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                Chart(runner.errorHistory.indices, id: \.self) { i in
                    let pt = runner.errorHistory[i]
                    LineMark(x: .value("Iter", pt.iteration), y: .value("E", pt.error))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    AreaMark(x: .value("Iter", pt.iteration), y: .value("E", pt.error))
                        .foregroundStyle(.orange.opacity(0.08))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4)).foregroundStyle(.white.opacity(0.15))
                        AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4)).foregroundStyle(.white.opacity(0.15))
                        AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                    }
                }
                .chartXAxisLabel("Itération", alignment: .center)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(.black)
    }

    // MARK: - Radar parameter view

    private var paramEvolutionView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Paramètres normalisés")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if !runner.activeParamInfo.isEmpty {
                    Text("\(runner.activeParamInfo.count) param(s)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if runner.activeParamInfo.count < 3 || runner.paramSnapshots.isEmpty {
                Spacer()
                Text(runner.activeParamInfo.count < 3
                     ? "Activez ≥ 3 paramètres\npour afficher le radar"
                     : "Le radar s'affichera ici")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.2))
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                RadarParamChart(info: runner.activeParamInfo,
                                snapshots: runner.paramSnapshots)
                    .padding(8)
            }
        }
        .background(.black)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Paramètres header ────────────────────────────────────────────
            HStack(spacing: 4) {
                Text("PARAMÈTRES")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                quickSelectButton("gMax") {
                    for i in optimParams.indices { optimParams[i].isActive = optimParams[i].label.hasSuffix("·gMax") }
                }
                quickSelectButton("Tout")   { for i in optimParams.indices { optimParams[i].isActive = true  } }
                quickSelectButton("Aucun")  { for i in optimParams.indices { optimParams[i].isActive = false } }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.2)

            // ── Parameter list ───────────────────────────────────────────────
            if optimParams.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("Lance la simulation\npour voir les paramètres du modèle")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.25))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($optimParams) { $p in
                            let bestVal: Double? = {
                                guard runner.isRunning || !runner.bestParams.isEmpty,
                                      let idx = runner.activeParamInfo.firstIndex(where: { $0.label == p.label }),
                                      idx < runner.bestParams.count
                                else { return nil }
                                return runner.bestParams[idx]
                            }()
                            OptimParamRow(param: $p, bestValue: bestVal)
                                .disabled(runner.isRunning || runner.isPaused)
                            Divider().opacity(0.08)
                        }
                    }
                }
            }

            Divider().opacity(0.2)

            // ── Optimizer config ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {

                // Objective mode picker
                HStack(spacing: 6) {
                    Text("Objectif")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    Picker("", selection: $objectiveMode) {
                        ForEach(ObjectiveMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(runner.isRunning || runner.isPaused)
                }

                // Burst-specific controls (only shown when objectiveMode == .burst)
                if objectiveMode == .burst {
                    // AIS compartment picker
                    if let nid = resolvedRight,
                       let neuron = vm.network.neurons.first(where: { $0.id == nid }),
                       neuron.compartments.count > 1 {
                        HStack(spacing: 4) {
                            Text("Comptage AP")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                            Picker("", selection: $burstAISID) {
                                Text("Soma").tag(Optional<UUID>.none)
                                ForEach(neuron.compartments) { comp in
                                    Text(comp.name).tag(Optional(comp.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .disabled(runner.isRunning || runner.isPaused)
                        }
                    }
                    // Resting voltage
                    burstConfigSlider("V repos", value: $burstRestingV,
                                      range: -90 ... -55, format: "%.0f mV")
                    // Targets
                    burstConfigSlider("Bursts/s", value: $burstTargetBPS,
                                      range: 0.2 ... 5.0, format: "%.1f")
                    burstConfigSlider("AP/burst", value: $burstTargetAPs,
                                      range: 2 ... 30,    format: "%.0f")
                    burstConfigSlider("Période",  value: $burstTargetPeriodMs,
                                      range: 200 ... 3000, format: "%.0f ms")
                }

                // Algorithm picker
                HStack(spacing: 6) {
                    Text("Algo")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    Picker("", selection: $optimConfig.algorithm) {
                        ForEach(OptimizerAlgorithm.allCases) { a in
                            Text(a.shortName).tag(a)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(runner.isRunning || runner.isPaused)
                }

                // Simulation duration per eval
                HStack(spacing: 4) {
                    Text("Durée sim")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    Slider(value: $optimConfig.simDuration, in: 100...2000, step: 100)
                        .frame(maxWidth: .infinity)
                        .tint(.white.opacity(0.4))
                        .disabled(runner.isRunning || runner.isPaused)
                    Text(String(format: "%.0f ms", optimConfig.simDuration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 44)
                }

                // Max iterations
                HStack(spacing: 4) {
                    Text("Iter. max")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    Slider(value: Binding(
                        get:  { Double(optimConfig.maxIterations) },
                        set:  { optimConfig.maxIterations = Int($0) }
                    ), in: 20...500, step: 10)
                    .frame(maxWidth: .infinity)
                    .tint(.white.opacity(0.4))
                    .disabled(runner.isRunning || runner.isPaused)
                    Text("\(optimConfig.maxIterations)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider().opacity(0.2)

            // ── Status + Start / Pause / Resume / Stop ──────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text(runner.status)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(runner.isPaused ? .yellow.opacity(0.7) : .white.opacity(0.45))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if runner.isPaused {
                    // ── Paused: Reprendre + Arrêter ──────────────────────
                    HStack(spacing: 6) {
                        Button("Reprendre") { runner.resume(vm: vm) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.orange)
                        Button("Arrêter") { runner.stop() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                    }
                    Text("Simulation lancée librement pendant la pause.")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)

                } else if runner.isRunning {
                    // ── Running: Pause + Stop ────────────────────────────
                    HStack(spacing: 6) {
                        Button("Pause") { runner.pause() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.yellow)
                        Button("Stop") { runner.stop() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.orange)
                    }

                } else {
                    // ── Idle: Lancer ─────────────────────────────────────
                    Button("Lancer") {
                        guard let id = resolvedRight else { return }
                        switch objectiveMode {
                        case .density:
                            runner.start(
                                vm:        vm,
                                params:    optimParams,
                                neuronID:  id,
                                refPoints: leftPoints,
                                config:    optimConfig,
                                nBinsV:    nBinsV,
                                nBinsDvdt: nBinsDvdt
                            )
                        case .burst:
                            runner.start(
                                vm:       vm,
                                params:   optimParams,
                                neuronID: id,
                                config:   optimConfig,
                                objective: .burstCounting(
                                    aisCompartmentID:  burstAISID,
                                    restingVoltage:    burstRestingV,
                                    targetBPS:         burstTargetBPS,
                                    targetAPsPerBurst: burstTargetAPs,
                                    targetPeriodMs:    burstTargetPeriodMs
                                )
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }

                // ── V(t) comparison preview ──────────────────────────────
                if !runner.lastCandidateTrace.isEmpty {
                    let refID = resolvedLeft
                    let refRaw: [(t: Double, v: Double)] = {
                        guard let id = refID,
                              let trace = vm.traces[id], !trace.isEmpty else { return [] }
                        let st = max(1, trace.count / 600)
                        return Swift.stride(from: 0, to: trace.count, by: st)
                                   .map { (t: trace[$0].t, v: trace[$0].v) }
                    }()
                    if !refRaw.isEmpty {
                        TracePreviewCanvas(
                            refPts: refRaw,
                            simPts: runner.lastCandidateTrace
                        )
                        .frame(height: 68)
                        .padding(.horizontal, 4)
                    }
                }

                Text("\(optimParams.filter(\.isActive).count) param(s)  •  \(runner.iteration) iter.")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.black)
    }

    @ViewBuilder
    private func burstConfigSlider(_ label: String, value: Binding<Double>,
                                   range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: range)
                .frame(maxWidth: .infinity)
                .tint(.white.opacity(0.35))
                .disabled(runner.isRunning || runner.isPaused)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func quickSelectButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning || runner.isPaused)
    }

    // MARK: - Import

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Importer une trace expérimentale"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text,
                                     .data, .item]   // broad net for any extension
        panel.allowsOtherFileTypes = true             // never grey out a file
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        let name = url.deletingPathExtension().lastPathComponent
        var rawT: [Double] = []
        var rawV: [Double] = []
        var hasTwoColumns = false

        for line in text.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#"), !s.hasPrefix("//") else { continue }
            let sep = CharacterSet(charactersIn: ", \t;")
            let parts = s.components(separatedBy: sep).filter { !$0.isEmpty }
            if parts.count >= 2, let a = Double(parts[0]), let b = Double(parts[1]) {
                rawT.append(a); rawV.append(b); hasTwoColumns = true
            } else if parts.count == 1, let v = Double(parts[0]) {
                rawV.append(v)
            }
        }

        var pts: [(v: Double, dvdt: Double)] = []
        if hasTwoColumns, rawT.count == rawV.count {
            for i in 1..<rawT.count {
                let dt = rawT[i] - rawT[i-1]
                guard dt > 0, dt < 10 else { continue }
                let dvdt = (rawV[i] - rawV[i-1]) / dt
                guard abs(dvdt) < 5000 else { continue }
                pts.append((v: rawV[i-1], dvdt: dvdt))
            }
        } else {
            let dt = 0.1  // assume 10 kHz
            for i in 1..<rawV.count {
                let dvdt = (rawV[i] - rawV[i-1]) / dt
                guard abs(dvdt) < 5000 else { continue }
                pts.append((v: rawV[i-1], dvdt: dvdt))
            }
        }

        guard !pts.isEmpty else { return }
        importedTrace = ImportedTrace(name: name, points: pts)
        useImportLeft = true
    }

    // MARK: - Empty state

    private func panelEmpty(hint: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.1))
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.2))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - OptimParamRow

fileprivate struct OptimParamRow: View {
    @Binding var param: OptimParam
    var bestValue: Double? = nil   // non-nil when optimisation is running/done

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: checkbox + label + (best value if running, else current)
            HStack(spacing: 5) {
                Toggle("", isOn: $param.isActive)
                    .toggleStyle(.checkbox)
                    .scaleEffect(0.75)
                    .frame(width: 14)
                Text(param.label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(param.isActive ? .white.opacity(0.85) : .white.opacity(0.3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if let bv = bestValue {
                    Text(fmtVal(bv))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.85))
                        .transition(.opacity)
                } else {
                    Text(fmtVal(param.currentValue))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            // Line 2: min … max (only when active and not running)
            if param.isActive && bestValue == nil {
                HStack(spacing: 3) {
                    Spacer().frame(width: 18)
                    CompactNumField(value: $param.minBound)
                    Text("…")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.3))
                    CompactNumField(value: $param.maxBound)
                    Text(param.unit)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.25))
                        .lineLimit(1)
                        .frame(maxWidth: 30)
                }
            }
            // Line 2 (running): progress bar showing where best falls in [min, max]
            if param.isActive, let bv = bestValue {
                let pct = max(0, min(1, (bv - param.minBound) / max(param.maxBound - param.minBound, 1e-12)))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.07))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(0.5))
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(height: 3)
                .padding(.leading, 18)
                .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func fmtVal(_ v: Double) -> String {
        abs(v) < 0.001 || abs(v) >= 10000
            ? String(format: "%.2e", v)
            : String(format: "%.3g", v)
    }
}

// MARK: - CompactNumField

fileprivate struct CompactNumField: View {
    @Binding var value: Double
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: 46)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.white.opacity(focused ? 0.1 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .focused($focused)
            .onAppear { text = fmt(value) }
            .onChange(of: value) { _, v in if !focused { text = fmt(v) } }
            .onSubmit { commit() }
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        if let d = Double(text.replacingOccurrences(of: ",", with: ".")) { value = d }
        text = fmt(value)
    }

    private func fmt(_ v: Double) -> String {
        abs(v) < 0.001 || abs(v) >= 10000
            ? String(format: "%.2e", v)
            : String(format: "%.4g", v)
    }
}

// MARK: - DensityCanvas (stateless, reusable)

fileprivate struct DensityCanvas: View {
    let grid: DensityGrid
    var minFraction: Double = 0.005   // bins below this × maxCount are hidden

    private let mL: CGFloat = 50   // marginLeft
    private let mB: CGFloat = 32   // marginBottom
    private let mT: CGFloat = 6    // marginTop
    private let mR: CGFloat = 8    // marginRight

    @State private var hoverLoc: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let pW = size.width  - mL - mR
                let pH = size.height - mT - mB
                guard pW > 0, pH > 0 else { return }

                // Black plot area
                ctx.fill(Path(CGRect(x: mL, y: mT, width: pW, height: pH)), with: .color(.black))

                // Density cells
                let cW = pW / CGFloat(grid.nV)
                let cH = pH / CGFloat(grid.nDvdt)
                let logD = log(100.0)
                // Minimum absolute count to display (filters out rare transients)
                let minCount = max(1, Int(Double(grid.maxCount) * minFraction))

                for row in 0..<grid.nDvdt {
                    for col in 0..<grid.nV {
                        let n = grid.counts[row * grid.nV + col]
                        guard n >= minCount else { continue }
                        // Normalise relative to counts above threshold for full colour range
                        let t = log(1.0 + Double(n) / Double(grid.maxCount) * 99.0) / logD
                        let x = mL + CGFloat(col) * cW
                        let y = mT + pH - CGFloat(row + 1) * cH
                        ctx.fill(Path(CGRect(x: x, y: y,
                                             width: cW + 0.6, height: cH + 0.6)),
                                 with: .color(heatColor(t)))
                    }
                }

                // Axes
                var ax = Path()
                ax.move(to:    CGPoint(x: mL, y: mT))
                ax.addLine(to: CGPoint(x: mL, y: mT + pH))
                ax.addLine(to: CGPoint(x: mL + pW, y: mT + pH))
                ctx.stroke(ax, with: .color(.white.opacity(0.3)), lineWidth: 1)

                // X ticks
                let spanV = grid.vMax - grid.vMin
                let stepV = niceStep(span: spanV, n: max(3, Int(pW / 60)))
                var v = ceil(grid.vMin / stepV) * stepV
                while v <= grid.vMax + 1e-9 {
                    let x = mL + CGFloat((v - grid.vMin) / spanV) * pW
                    ctx.stroke(tickPath(x1: x, y1: mT + pH, x2: x, y2: mT + pH + 4),
                               with: .color(.white.opacity(0.3)), lineWidth: 1)
                    ctx.draw(Text(String(format: "%.0f", v)).font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.5)),
                             at: CGPoint(x: x, y: mT + pH + 12), anchor: .center)
                    v += stepV
                }

                // Y ticks
                let spanD = grid.dvdtMax - grid.dvdtMin
                let stepD = niceStep(span: spanD, n: max(3, Int(pH / 45)))
                var d = ceil(grid.dvdtMin / stepD) * stepD
                while d <= grid.dvdtMax + 1e-9 {
                    let y = mT + pH - CGFloat((d - grid.dvdtMin) / spanD) * pH
                    ctx.stroke(tickPath(x1: mL, y1: y, x2: mL - 4, y2: y),
                               with: .color(.white.opacity(0.3)), lineWidth: 1)
                    ctx.draw(Text(String(format: "%.0f", d)).font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.5)),
                             at: CGPoint(x: mL - 6, y: y), anchor: .trailing)
                    d += stepD
                }

                // X label
                ctx.draw(Text("V  (mV)").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4)),
                         at: CGPoint(x: mL + pW / 2, y: size.height - 2), anchor: .bottom)

                // Crosshair
                if let cp = hoverLoc,
                   cp.x >= mL, cp.x <= mL + pW,
                   cp.y >= mT, cp.y <= mT + pH {
                    var vLine = Path()
                    vLine.move(to:    CGPoint(x: cp.x, y: mT))
                    vLine.addLine(to: CGPoint(x: cp.x, y: mT + pH))
                    ctx.stroke(vLine, with: .color(.white.opacity(0.55)), lineWidth: 1)
                    var hLine = Path()
                    hLine.move(to:    CGPoint(x: mL,      y: cp.y))
                    hLine.addLine(to: CGPoint(x: mL + pW, y: cp.y))
                    ctx.stroke(hLine, with: .color(.white.opacity(0.55)), lineWidth: 1)
                }
            }

            // Rotated Y label
            Text("dV/dt  (mV/ms)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .position(x: 8, y: geo.size.height / 2)

            // Cursor label
            if let cp = hoverLoc {
                let pW = geo.size.width  - mL - mR
                let pH = geo.size.height - mT - mB
                if cp.x >= mL, cp.x <= mL + pW,
                   cp.y >= mT, cp.y <= mT + pH {
                    let v = grid.vMin    + Double(cp.x - mL) / Double(pW) * (grid.vMax    - grid.vMin)
                    let d = grid.dvdtMin + (1.0 - Double(cp.y - mT) / Double(pH)) * (grid.dvdtMax - grid.dvdtMin)
                    // Density at cursor bin
                    let col = max(0, min(grid.nV    - 1, Int((cp.x - mL) / pW * CGFloat(grid.nV))))
                    let row = max(0, min(grid.nDvdt - 1, Int((1.0 - (cp.y - mT) / pH) * CGFloat(grid.nDvdt))))
                    let count   = grid.counts[row * grid.nV + col]
                    let density = grid.total > 0 ? Double(count) / Double(grid.total) * 100.0 : 0.0
                    let lx = cp.x + 8 > geo.size.width - mR - 140 ? cp.x - 145 : cp.x + 8
                    Text(String(format: "V = %.2f mV\ndV/dt = %.1f mV/ms\nρ = %.3f %%", v, d, density))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                        .position(x: lx + 60, y: max(cp.y - 8, mT + 28))
                }
            }
        }
        .background(.black)
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc): hoverLoc = loc
            case .ended:           hoverLoc = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // heatColor is now a module-level function in Utils.swift

    private func tickPath(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
        return p
    }

    private func niceStep(span: Double, n: Int) -> Double {
        let raw  = span / Double(max(1, n))
        let mag  = pow(10, floor(log10(max(raw, 1e-10))))
        let norm = raw / mag
        return (norm < 2 ? 2 : norm < 5 ? 5 : 10) * mag
    }
}

// MARK: - RadarParamChart

/// Spider/radar chart showing normalised parameter values.
/// • Faint grey polygon  = initial state (first snapshot)
/// • Accent polygon      = current best  (last snapshot)
/// • Rings at 0.25 / 0.5 / 0.75 / 1.0
fileprivate struct RadarParamChart: View {

    let info:      [ActiveParamInfo]
    let snapshots: [(iteration: Int, values: [Double])]

    // Accent colour identical to the rest of the dark UI
    private let fillColor  = Color.accentColor
    private let initColor  = Color.white

    var body: some View {
        GeometryReader { geo in
            let n      = info.count
            let sz     = geo.size
            let cx     = sz.width  / 2
            let cy     = sz.height / 2
            // Leave room for labels (≈28 pt on each side)
            let radius = min(cx, cy) - 30

            ZStack {
                // ── Canvas: grid + polygons ───────────────────────────────
                Canvas { ctx, _ in
                    guard n >= 3 else { return }

                    // Grid rings
                    for ring in [0.25, 0.5, 0.75, 1.0] {
                        let r = radius * ring
                        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                        ctx.stroke(Path(ellipseIn: rect),
                                   with: .color(.white.opacity(ring == 1.0 ? 0.18 : 0.09)),
                                   lineWidth: ring == 1.0 ? 0.8 : 0.5)
                    }

                    // Ring labels (0.25 … 1.0) on the top axis
                    for (ring, label) in [(0.25,"0.25"),(0.5,"0.5"),(0.75,"0.75"),(1.0,"1")] {
                        let r   = radius * ring
                        let pt  = CGPoint(x: cx + 3, y: cy - r - 1)
                        ctx.draw(Text(label)
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white.opacity(0.25)),
                                 at: pt, anchor: .bottomLeading)
                    }

                    // Axis spokes
                    for i in 0..<n {
                        let a   = axisAngle(i, n)
                        let tip = CGPoint(x: cx + radius * cos(a), y: cy + radius * sin(a))
                        var p   = Path(); p.move(to: CGPoint(x: cx, y: cy)); p.addLine(to: tip)
                        ctx.stroke(p, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                    }

                    // Initial state polygon (first snapshot)
                    if let first = snapshots.first {
                        let nv = normValues(first.values)
                        let p  = polygon(nv, cx: cx, cy: cy, radius: radius, n: n)
                        ctx.fill(p,   with: .color(initColor.opacity(0.05)))
                        ctx.stroke(p, with: .color(initColor.opacity(0.25)), lineWidth: 1)
                    }

                    // Current best polygon (last snapshot)
                    if let last = snapshots.last {
                        let nv = normValues(last.values)
                        let p  = polygon(nv, cx: cx, cy: cy, radius: radius, n: n)
                        ctx.fill(p,   with: .color(fillColor.opacity(0.22)))
                        ctx.stroke(p, with: .color(fillColor.opacity(0.85)), lineWidth: 1.8)

                        // Vertex dots
                        for (i, v) in nv.enumerated() {
                            let a  = axisAngle(i, n)
                            let r  = radius * v
                            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                            let dot = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                            ctx.fill(Path(ellipseIn: dot), with: .color(fillColor))
                        }
                    }
                }
                .frame(width: sz.width, height: sz.height)

                // ── Axis labels (SwiftUI Text for proper font rendering) ───
                ForEach(0..<n, id: \.self) { i in
                    let a    = axisAngle(i, n)
                    let labR = radius + 18
                    let lx   = cx + labR * cos(a)
                    let ly   = cy + labR * sin(a)

                    Text(shortLabel(info[i].label))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize()
                        .position(x: lx, y: ly)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Angle of axis i (top = −π/2 so first axis points up).
    private func axisAngle(_ i: Int, _ n: Int) -> Double {
        Double(i) * 2 * .pi / Double(n) - .pi / 2
    }

    /// Normalise raw parameter values to [0, 1].
    private func normValues(_ raw: [Double]) -> [Double] {
        info.indices.map { i in
            guard i < raw.count else { return 0 }
            let range = info[i].hi - info[i].lo
            guard range > 0 else { return 0 }
            return ((raw[i] - info[i].lo) / range).clamped(to: 0...1)
        }
    }

    /// Build a closed radar polygon path.
    private func polygon(_ nv: [Double], cx: Double, cy: Double,
                          radius: Double, n: Int) -> Path {
        var path = Path()
        for i in 0..<n {
            let a  = axisAngle(i, n)
            let r  = radius * (i < nv.count ? nv[i] : 0)
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }

    /// Short label: keep the part after "·" if present, else truncate to 8 chars.
    private func shortLabel(_ label: String) -> String {
        if let idx = label.firstIndex(of: "·") {
            return String(label[label.index(after: idx)...])
        }
        return label.count > 8 ? String(label.prefix(8)) : label
    }
}
