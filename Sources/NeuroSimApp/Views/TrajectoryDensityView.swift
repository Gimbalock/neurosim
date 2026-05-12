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

fileprivate struct ErrorPoint: Identifiable {
    let id = UUID()
    let iteration: Int
    let error: Double
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

    // Error history
    @State private var errorHistory: [ErrorPoint] = []

    // Optimizable parameters (built from the Modèle neuron)
    @State private var optimParams: [OptimParam] = []

    // Grid resolution
    private let nBinsV    = 100
    private let nBinsDvdt = 80

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

    // MARK: - Grid builder (display — clipped by dvdtMax)

    private func buildDisplayGrid(pts: [(v: Double, dvdt: Double)],
                                  dvdtMax: Double) -> DensityGrid? {
        let clipped = pts.filter { abs($0.dvdt) <= dvdtMax }
        return buildGrid(from: clipped)
    }

    private func buildGrid(from pts: [(v: Double, dvdt: Double)]) -> DensityGrid? {
        guard !pts.isEmpty else { return nil }
        let vs    = pts.map { $0.v }
        let dvdts = pts.map { $0.dvdt }
        guard let vMin = vs.min(), let vMax = vs.max(), vMax > vMin,
              let dMin = dvdts.min(), let dMax = dvdts.max(), dMax > dMin else { return nil }
        let vPad = (vMax - vMin) * 0.04; let dPad = (dMax - dMin) * 0.04
        let vLo = vMin - vPad; let vHi = vMax + vPad
        let dLo = dMin - dPad; let dHi = dMax + dPad
        return buildGridInRange(pts: pts, vLo: vLo, vHi: vHi, dLo: dLo, dHi: dHi)
    }

    private func buildGridInRange(pts: [(v: Double, dvdt: Double)],
                                  vLo: Double, vHi: Double,
                                  dLo: Double, dHi: Double) -> DensityGrid? {
        guard vHi > vLo, dHi > dLo else { return nil }
        let nV = nBinsV; let nD = nBinsDvdt
        var counts = [Int](repeating: 0, count: nV * nD)
        for p in pts {
            guard p.v >= vLo, p.v <= vHi, p.dvdt >= dLo, p.dvdt <= dHi else { continue }
            let ci = min(Int((p.v    - vLo) / (vHi - vLo) * Double(nV)), nV - 1)
            let ri = min(Int((p.dvdt - dLo) / (dHi - dLo) * Double(nD)), nD - 1)
            counts[ri * nV + ci] += 1
        }
        return DensityGrid(counts: counts, nV: nV, nDvdt: nD,
                           vMin: vLo, vMax: vHi, dvdtMin: dLo, dvdtMax: dHi,
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

                errorChartView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .onChange(of: rightNeuronID) { _, _ in rebuildOptimParams() }
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

    // MARK: - Left panel (Référence — import ou neurone)

    private var leftPanelView: some View {
        VStack(spacing: 0) {
            leftToolbar
            Divider().opacity(0.25)
            Group {
                if useImportLeft, let imp = importedTrace,
                   let grid = buildDisplayGrid(pts: imp.points, dvdtMax: leftDvdtMax) {
                    DensityCanvas(grid: grid)
                } else if let id = resolvedLeft,
                          let grid = buildDisplayGrid(pts: pointsFromNeuron(id),
                                                      dvdtMax: leftDvdtMax) {
                    DensityCanvas(grid: grid)
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
                if let id = resolvedRight,
                   let grid = buildDisplayGrid(pts: pointsFromNeuron(id),
                                               dvdtMax: rightDvdtMax) {
                    DensityCanvas(grid: grid)
                } else {
                    panelEmpty(hint: "Lance la simulation")
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
                if let e = currentError {
                    Text(String(format: "E courante = %.4e", e))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if errorHistory.isEmpty {
                Spacer()
                Text("L'historique s'affichera ici au fil des itérations d'optimisation")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.2))
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                Chart(errorHistory) { pt in
                    LineMark(
                        x: .value("Itération", pt.iteration),
                        y: .value("E", pt.error)
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    AreaMark(
                        x: .value("Itération", pt.iteration),
                        y: .value("E", pt.error)
                    )
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

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 4) {
                Text("PARAMÈTRES")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                quickSelectButton("gMax") {
                    for i in optimParams.indices {
                        optimParams[i].isActive = optimParams[i].label.hasSuffix("·gMax")
                    }
                }
                quickSelectButton("Tout") {
                    for i in optimParams.indices { optimParams[i].isActive = true }
                }
                quickSelectButton("Aucun") {
                    for i in optimParams.indices { optimParams[i].isActive = false }
                }
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
                            OptimParamRow(param: $p)
                            Divider().opacity(0.08)
                        }
                    }
                }
            }

            Divider().opacity(0.2)

            // ── Footer metrics ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("E =")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(currentError.map { String(format: "%.3e", $0) } ?? "—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange.opacity(currentError == nil ? 0.3 : 0.9))
                }
                Text("\(optimParams.filter(\.isActive).count) param(s) actif(s)  •  \(errorHistory.count) iter.")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.black)
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
    }

    // MARK: - Import

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Importer une trace expérimentale"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: checkbox + label + current value
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
                Text(fmtVal(param.currentValue))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            // Line 2: min … max (only when active)
            if param.isActive {
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

    private let mL: CGFloat = 50   // marginLeft
    private let mB: CGFloat = 32   // marginBottom
    private let mT: CGFloat = 6    // marginTop
    private let mR: CGFloat = 8    // marginRight

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

                for row in 0..<grid.nDvdt {
                    for col in 0..<grid.nV {
                        let n = grid.counts[row * grid.nV + col]
                        guard n > 0 else { continue }
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
            }

            // Rotated Y label
            Text("dV/dt  (mV/ms)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .position(x: 8, y: geo.size.height / 2)
        }
        .background(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func heatColor(_ t: Double) -> Color {
        let hue = (1.0 - t) * 0.67
        return Color(hue: hue, saturation: 1.0, brightness: t < 0.05 ? t * 20.0 : 1.0)
    }

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
