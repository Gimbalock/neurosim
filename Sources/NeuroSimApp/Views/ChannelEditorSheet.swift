//
//  ChannelEditorSheet.swift
//  NeuroSimApp
//
//  Éditeur de canal unifié — même fenêtre pour la bibliothèque, l'inspector
//  d'un compartiment, et les canaux HH intégrés.
//
//  Modes d'interpolation par gate :
//   x∞(V) : Boltzmann (sigmoid 4-param) ou Spline (PCHIP, points de contrôle)
//   τ(V)  : Gaussien (bell) ou Spline (PCHIP, points de contrôle)
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - Constantes partagées

let kGateColors: [Color] = [.blue, .orange, .green, .red, .purple]

// MARK: - PolyPoint

struct PolyPoint: Identifiable, Equatable {
    var id = UUID()
    var v: Double   // mV
    var y: Double   // valeur de x∞ ou τ
}

// MARK: - UnifiedGateDraft

struct UnifiedGateDraft: Identifiable {
    var id = UUID()
    var name: String
    var power: Int

    // ── x∞(V) ───────────────────────────────────────────────────────────
    var infMode:  InfMode = .boltzmann
    // Boltzmann
    var infLo:    Double = 0
    var infHi:    Double = 1
    var infVHalf: Double = -40
    var infSlope: Double = 7
    // Spline (PCHIP) — vide par défaut : peuplé depuis Boltzmann au 1er passage en mode spline
    var infPoints: [PolyPoint] = []

    // ── τ(V) ─────────────────────────────────────────────────────────────
    var tauMode:  TauMode = .gaussian
    // Gaussien
    var tauMin:   Double = 0.5
    var tauMax:   Double = 5.0
    var tauVPeak: Double = -40
    var tauWidth: Double = 20
    // Spline (PCHIP)
    var tauPoints: [PolyPoint] = []

    enum InfMode: String, CaseIterable, Identifiable {
        case boltzmann = "Boltzmann"; case polynomial = "Spline"
        var id: String { rawValue }
    }
    enum TauMode: String, CaseIterable, Identifiable {
        case gaussian = "Gaussien"; case polynomial = "Spline"
        var id: String { rawValue }
    }

    // MARK: Courbes effectives

    var infCurve: GateCurve {
        switch infMode {
        case .boltzmann:
            return .sigmoid(lo: infLo, hi: infHi, vHalf: infVHalf, k: infSlope, domain: nil)
        case .polynomial:
            return CurveFitter.fitSpline(points: infPoints.map { ($0.v, $0.y) })
                ?? .sigmoid(lo: infLo, hi: infHi, vHalf: infVHalf, k: infSlope, domain: nil)
        }
    }

    var tauCurve: GateCurve {
        switch tauMode {
        case .gaussian:
            return .gaussian(tauMin: tauMin, tauMax: tauMax,
                             vPeak: tauVPeak, width: tauWidth, domain: nil)
        case .polynomial:
            return CurveFitter.fitSpline(points: tauPoints.map { ($0.v, $0.y) })
                ?? .gaussian(tauMin: tauMin, tauMax: tauMax,
                             vPeak: tauVPeak, width: tauWidth, domain: nil)
        }
    }

    // MARK: Points par défaut

    static func defaultInfPoints() -> [PolyPoint] {
        [(-80, 0.02), (-60, 0.1), (-40, 0.5), (-20, 0.9), (0, 0.98)]
            .map { PolyPoint(v: $0.0, y: $0.1) }
    }

    static func defaultTauPoints() -> [PolyPoint] {
        [(-80, 0.5), (-60, 2.0), (-40, 5.0), (-20, 2.0), (0, 0.5)]
            .map { PolyPoint(v: $0.0, y: $0.1) }
    }

    // MARK: Initialiseurs

    init(from def: GateDef) {
        id = def.id; name = def.name; power = def.power
        infMode = .boltzmann
        infLo = 0; infHi = 1; infVHalf = def.vHalf; infSlope = def.slope
        tauMode = .gaussian
        tauMin = def.tauMin; tauMax = def.tauMax
        tauVPeak = def.vPeak; tauWidth = def.tauWidth
    }

    init(from channel: any HHGated, index: Int) {
        name = channel.gateNames[safe: index] ?? "g\(index)"
        power = 1

        if let ov = channel.gateInfOverrides[safe: index] ?? nil {
            switch ov {
            case let .sigmoid(lo, hi, vHalf, k, _):
                infMode = .boltzmann; infLo = lo; infHi = hi; infVHalf = vHalf; infSlope = k
            case let .spline(xs, ys, _, _):
                infMode = .polynomial
                infPoints = zip(xs, ys).map { PolyPoint(v: $0, y: $1) }
            case let .polynomial(_, vC, domain):
                // Legacy: resample old polynomial overrides into control points
                infMode = .polynomial
                infPoints = Self.sampleCurve(ov, domain: domain ?? (-80...0), count: 7)
                _ = vC
            default:
                infMode = .boltzmann
                let (vH, k, lo, hi) = Self.fitSigmoidParams(channel: channel, index: index)
                infVHalf = vH; infSlope = k; infLo = lo; infHi = hi
            }
        } else {
            infMode = .boltzmann
            let (vH, k, lo, hi) = Self.fitSigmoidParams(channel: channel, index: index)
            infVHalf = vH; infSlope = k; infLo = lo; infHi = hi
        }

        if let ov = channel.gateTauOverrides[safe: index] ?? nil {
            switch ov {
            case let .gaussian(tMin, tMax, vP, w, _):
                tauMode = .gaussian; tauMin = tMin; tauMax = tMax; tauVPeak = vP; tauWidth = w
            case let .spline(xs, ys, _, _):
                tauMode = .polynomial
                tauPoints = zip(xs, ys).map { PolyPoint(v: $0, y: $1) }
            case let .polynomial(_, vC, domain):
                // Legacy: resample old polynomial overrides into control points
                tauMode = .polynomial
                tauPoints = Self.sampleCurve(ov, domain: domain ?? (-80...0), count: 7)
                _ = vC
            default:
                tauMode = .gaussian
                let (tMin, tMax, vP, w) = Self.fitGaussianParams(channel: channel, index: index)
                tauMin = tMin; tauMax = tMax; tauVPeak = vP; tauWidth = w
            }
        } else {
            tauMode = .gaussian
            let (tMin, tMax, vP, w) = Self.fitGaussianParams(channel: channel, index: index)
            tauMin = tMin; tauMax = tMax; tauVPeak = vP; tauWidth = w
        }
    }

    // MARK: Fit numérique sigmoid

    static func fitSigmoidParams(channel: any HHGated, index: Int)
            -> (vHalf: Double, k: Double, lo: Double, hi: Double) {
        let lo = channel.gateInf(index, voltage: -100)
        let hi = channel.gateInf(index, voltage:   60)
        let target  = (lo + hi) / 2
        let ascending = hi >= lo          // false pour les gates d'inactivation (h)
        var va = -100.0, vb = 60.0
        for _ in 0..<60 {
            let vm  = (va + vb) / 2
            let fvm = channel.gateInf(index, voltage: vm)
            // Pour une courbe décroissante on inverse la direction de recherche
            if ascending ? (fvm < target) : (fvm > target) { va = vm } else { vb = vm }
        }
        let vHalf = (va + vb) / 2
        let dv    = 0.5
        let dx    = channel.gateInf(index, voltage: vHalf + dv)
                  - channel.gateInf(index, voltage: vHalf - dv)
        let dxdv  = dx / (2 * dv)
        // dy/dV|_{vHalf} = (hi-lo)*0.25/k  →  k = (hi-lo)*0.25/dxdv
        // (l'ancienne formule xm*(1-xm)/dxdv donnait un k négatif pour h)
        let k = abs(dxdv) > 1e-9 ? (hi - lo) * 0.25 / dxdv : 7.0
        return (vHalf, k, lo, hi)
    }

    // MARK: Fit numérique gaussien

    static func fitGaussianParams(channel: any HHGated, index: Int)
            -> (tauMin: Double, tauMax: Double, vPeak: Double, width: Double) {
        let vs   = Array(stride(from: -100.0, through: 60.0, by: 1.0))
        let taus = vs.map { channel.gateTau(index, voltage: $0) }
        let tMax = taus.max() ?? 5
        let tMin = taus.min() ?? 0.5
        let pi   = taus.indices.max(by: { taus[$0] < taus[$1] }) ?? vs.count / 2
        let vP   = vs[pi]
        let half = tMin + (tMax - tMin) * 0.5
        let above = vs.enumerated().filter { taus[$0.offset] >= half }
        let w: Double = {
            guard let f = above.first?.element, let l = above.last?.element else { return 20 }
            return max((l - f) / 2.355, 5)
        }()
        return (tMin, tMax, vP, w)
    }

    // MARK: Échantillonnage d'une GateCurve → PolyPoints

    static func sampleCurve(_ curve: GateCurve, domain: ClosedRange<Double>, count: Int) -> [PolyPoint] {
        let step = (domain.upperBound - domain.lowerBound) / Double(count - 1)
        return (0..<count).compactMap { i in
            let v = domain.lowerBound + Double(i) * step
            guard let y = curve.evaluate(at: v) else { return nil }
            return PolyPoint(v: v, y: y)
        }
    }

    // MARK: Points initiaux depuis la courbe Boltzmann/Gaussien courante

    mutating func populateInfPointsFromBoltzmann() {
        let curve = GateCurve.sigmoid(lo: infLo, hi: infHi,
                                      vHalf: infVHalf, k: infSlope, domain: nil)
        let k = max(abs(infSlope), 2.0)
        // 7 points centrés sur vHalf, espacement ∝ k. Dédupliqués après clamping.
        let raw = [-4.0, -2.0, -1.0, 0.0, 1.0, 2.0, 4.0]
            .map { infVHalf + $0 * k }
            .map { max(-100.0, min(60.0, $0)) }
        let vs = Self.dedup(raw, minSpacing: 1.0)
        infPoints = vs.map { v in PolyPoint(v: v, y: curve.evaluate(at: v) ?? 0.5) }
    }

    mutating func populateTauPointsFromGaussian() {
        let curve = GateCurve.gaussian(tauMin: tauMin, tauMax: tauMax,
                                       vPeak: tauVPeak, width: tauWidth, domain: nil)
        let w = max(abs(tauWidth), 5.0)
        // 9 points dans ±2σ — dense près du pic, puis les épaules
        let raw = [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0]
            .map { tauVPeak + $0 * w }
            .map { max(-100.0, min(60.0, $0)) }
        let vs = Self.dedup(raw, minSpacing: 1.0)
        tauPoints = vs.map { v in PolyPoint(v: v, y: curve.evaluate(at: v) ?? tauMin) }
    }

    /// Supprime les quasi-doublons après clamping (espacement minimum `minSpacing` mV).
    /// Évite une matrice de Vandermonde singulière quand plusieurs offsets tombent sur la même borne.
    private static func dedup(_ sorted: [Double], minSpacing: Double) -> [Double] {
        var out: [Double] = []
        for v in sorted.sorted() {
            if out.isEmpty || v - out.last! >= minSpacing { out.append(v) }
        }
        return out
    }

    /// Convertit en GateDef (pour CustomChannel).
    func toGateDef() -> GateDef {
        GateDef(id: id, name: name, power: power,
                vHalf: infVHalf, slope: infSlope,
                tauMin: tauMin, tauMax: tauMax,
                vPeak: tauVPeak, tauWidth: tauWidth)
    }
}

// MARK: - Contexte

enum ChannelEditorContext {
    case library(draft: CustomChannelDefinition, onSave: (CustomChannelDefinition) -> Void)
    case compartment(channel: any HHGated, onSave: (any HHGated) -> Void)

    var saveLabel: String {
        switch self { case .library: return "Enregistrer dans la bibliothèque"
                      case .compartment: return "Appliquer" }
    }
    var isLibrary: Bool { if case .library = self { return true }; return false }
}

// MARK: - ChannelEditorSheet

struct ChannelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var channelName: String
    @State private var ionSymbol:   String?
    @State private var gMax:        Double
    @State private var reversal:    Double
    @State private var gates:       [UnifiedGateDraft]
    @State private var expandedGate: UUID? = nil

    let context: ChannelEditorContext

    init(draft: CustomChannelDefinition, context: ChannelEditorContext) {
        _channelName = State(initialValue: draft.name)
        _ionSymbol   = State(initialValue: draft.ionSymbol)
        _gMax        = State(initialValue: draft.gMax)
        _reversal    = State(initialValue: draft.reversal)
        _gates       = State(initialValue: draft.gates.map { UnifiedGateDraft(from: $0) })
        self.context = context
    }

    init(channel: any HHGated, context: ChannelEditorContext) {
        _channelName = State(initialValue: channel.name)
        _ionSymbol   = State(initialValue: channel.species?.symbol)
        _gMax        = State(initialValue: channel.gMax)
        _reversal    = State(initialValue: channel.reversal)
        _gates       = State(initialValue: (0..<channel.stateCount).map {
            UnifiedGateDraft(from: channel, index: $0)
        })
        self.context = context
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(channelName.isEmpty ? "Canal" : channelName).font(.title3.bold())
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Button(context.saveLabel) { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(channelName.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { formSection; gatesSection }
                        .padding(16)
                }
                .frame(width: 420)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { previewSection }.padding(16)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: Sauvegarde

    private func save() {
        switch context {
        case let .library(draft, onSave):
            var d = draft
            d.name = channelName; d.ionSymbol = ionSymbol
            d.gMax = gMax; d.reversal = reversal
            d.gates = gates.map { $0.toGateDef() }
            onSave(d)
        case let .compartment(channel, onSave):
            channel.gMax = gMax; channel.reversal = reversal
            for (i, g) in gates.enumerated() {
                if i < channel.gateInfOverrides.count {
                    channel.gateInfOverrides[i] = g.infCurve
                    channel.gateTauOverrides[i]  = g.tauCurve
                }
            }
            if let cc = channel as? CustomChannel {
                for (i, g) in gates.enumerated() where i < cc.definition.gates.count {
                    cc.definition.gates[i] = g.toGateDef()
                }
            }
            onSave(channel)
        }
    }

    // MARK: Formulaire

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canal").font(.headline)
            HStack {
                Text("Nom").frame(width: 80, alignment: .leading)
                TextField("Nom du canal", text: $channelName)
            }
            if context.isLibrary {
                HStack {
                    Text("Ion").frame(width: 80, alignment: .leading)
                    Picker("", selection: $ionSymbol) {
                        Text("Aucun / mixte").tag(Optional<String>.none)
                        Divider()
                        ForEach(IonSpecies.allCanonical, id: \.symbol) { sp in
                            Text("\(sp.symbol)\(sp.valence > 0 ? "+" : "")  (\(sp.valence > 0 ? "+" : "")\(sp.valence))")
                                .tag(Optional(sp.symbol))
                        }
                    }.labelsHidden().pickerStyle(.menu)
                    .onChange(of: ionSymbol) { _, sym in
                        if let sp = sym.flatMap(IonSpecies.canonical(symbol:)) { reversal = sp.defaultReversal() }
                    }
                }
            }
            NumericSlider(label: "g_max", value: $gMax,     range: 0...500,    format: "%.2f", unit: "mS/cm²", labelWidth: 80)
            NumericSlider(label: "E_rev", value: $reversal, range: -100...200, format: "%.1f", unit: "mV",     labelWidth: 80)
        }
    }

    // MARK: Gates

    private var gatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gates").font(.headline)
                Spacer()
                if context.isLibrary {
                    Button {
                        let g = UnifiedGateDraft(from: GateDef(name: defaultGateName()))
                        gates.append(g); expandedGate = g.id
                    } label: { Label("Ajouter", systemImage: "plus.circle").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                }
            }
            if gates.isEmpty {
                Text("Aucun gate — canal passif pur (leak).").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(gates.indices, id: \.self) { i in
                UnifiedGateEditorRow(
                    gate: $gates[i],
                    color: kGateColors[i % kGateColors.count],
                    isExpanded: expandedGate == gates[i].id,
                    canDelete: context.isLibrary,
                    onToggle: { let gid = gates[i].id; expandedGate = expandedGate == gid ? nil : gid },
                    onDelete: { gates.remove(at: i) }
                )
            }
        }
    }

    private func defaultGateName() -> String {
        let used = Set(gates.map(\.name))
        return ["m","h","n","p","q","r","s"].first { !used.contains($0) } ?? "x\(gates.count)"
    }

    // MARK: Preview interactif

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Aperçu").font(.headline)
            if gates.isEmpty {
                Text("Ajoutez au moins un gate.").font(.caption).foregroundStyle(.secondary)
            } else {
                InteractivePreviewChart(gates: $gates, title: "x∞(V)",
                                        yLabel: "Probabilité", yRange: 0...1, isInf: true)
                InteractivePreviewChart(gates: $gates, title: "τ(V)",
                                        yLabel: "τ (ms)", yRange: nil, isInf: false)
            }
        }
    }
}

// MARK: - InteractivePreviewChart

/// Grand graphe d'aperçu (droite de l'éditeur).
/// En mode polynomial, les points de contrôle sont déplaçables directement par drag.
private struct InteractivePreviewChart: View {
    @Binding var gates: [UnifiedGateDraft]
    let title:  String
    let yLabel: String
    let yRange: ClosedRange<Double>?
    let isInf:  Bool

    @State private var dragging: (gi: Int, pi: Int)? = nil

    private struct LP: Identifiable { let id: String; let v, y: Double; let gate: String }
    private struct CP: Identifiable {
        let id: UUID; let v, y: Double; let gi, pi: Int; let gate: String; let color: Color
    }
    private struct GP: Identifiable { let id: String; let v, y: Double }   // ghost point

    private var linePts: [LP] {
        var out: [LP] = []
        for (i, gate) in gates.enumerated() {
            let label = "\(gate.name) (×\(gate.power))"
            let curve = isInf ? gate.infCurve : gate.tauCurve
            for v in stride(from: -100.0, through: 60.0, by: 0.5) {
                if let y = curve.evaluate(at: v) { out.append(LP(id: "\(i)\(v)", v: v, y: y, gate: label)) }
            }
        }
        return out
    }

    private var ctrlPts: [CP] {
        var out: [CP] = []
        for (i, gate) in gates.enumerated() {
            let label = "\(gate.name) (×\(gate.power))"
            let pts = isInf
                ? (gate.infMode == .polynomial ? gate.infPoints : [])
                : (gate.tauMode == .polynomial ? gate.tauPoints : [])
            for (j, pt) in pts.enumerated() {
                out.append(CP(id: pt.id, v: pt.v, y: pt.y, gi: i, pi: j,
                              gate: label, color: kGateColors[i % kGateColors.count]))
            }
        }
        return out
    }

    /// Courbe de l'autre mode (grisée) : Boltzmann si on est en Polynomial, et vice-versa.
    private var ghostPts: [GP] {
        var out: [GP] = []
        for (i, gate) in gates.enumerated() {
            let ghostCurve: GateCurve?
            if isInf {
                switch gate.infMode {
                case .boltzmann:
                    guard gate.infPoints.count >= 2 else { continue }
                    ghostCurve = CurveFitter.fitSpline(
                        points: gate.infPoints.map { ($0.v, $0.y) })
                case .polynomial:
                    ghostCurve = .sigmoid(lo: gate.infLo, hi: gate.infHi,
                                          vHalf: gate.infVHalf, k: gate.infSlope, domain: nil)
                }
            } else {
                switch gate.tauMode {
                case .gaussian:
                    guard gate.tauPoints.count >= 2 else { continue }
                    ghostCurve = CurveFitter.fitSpline(
                        points: gate.tauPoints.map { ($0.v, $0.y) })
                case .polynomial:
                    ghostCurve = .gaussian(tauMin: gate.tauMin, tauMax: gate.tauMax,
                                           vPeak: gate.tauVPeak, width: gate.tauWidth, domain: nil)
                }
            }
            guard let curve = ghostCurve else { continue }
            for v in stride(from: -100.0, through: 60.0, by: 1.0) {
                if let y = curve.evaluate(at: v) {
                    out.append(GP(id: "g\(i)\(v)", v: v, y: y))
                }
            }
        }
        return out
    }

    var body: some View {
        let lpts   = linePts
        let cpts   = ctrlPts
        let gpts   = ghostPts
        let domain = gates.indices.map { "\(gates[$0].name) (×\(gates[$0].power))" }
        let colors = gates.indices.map { kGateColors[$0 % kGateColors.count] }
        let hasGhost = !gpts.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                if !cpts.isEmpty {
                    Text("— glisser les points pour les déplacer")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if hasGhost {
                    HStack(spacing: 3) {
                        Rectangle().fill(.gray.opacity(0.45))
                            .frame(width: 16, height: 1.5)
                        Text(isInf ? (gates.first?.infMode == .boltzmann ? "poly" : "Boltzmann")
                                   : (gates.first?.tauMode == .gaussian  ? "poly" : "Gaussien"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Chart {
                ForEach(lpts) { pt in
                    LineMark(x: .value("V (mV)", pt.v), y: .value(yLabel, pt.y))
                        .foregroundStyle(by: .value("Gate", pt.gate))
                        .interpolationMethod(.catmullRom)
                }
                ForEach(cpts) { pt in
                    PointMark(x: .value("V (mV)", pt.v), y: .value(yLabel, pt.y))
                        .foregroundStyle(pt.color)
                        .symbolSize(dragging.map { $0.gi == pt.gi && $0.pi == pt.pi } == true ? 180 : 90)
                }
                // Courbe fantôme : l'autre mode en grisé pour comparaison
                ForEach(gpts) { pt in
                    LineMark(x: .value("V (mV)", pt.v), y: .value(yLabel, pt.y))
                        .foregroundStyle(.gray.opacity(0.38))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartForegroundStyleScale(domain: domain, range: colors)
            .chartXAxisLabel("V (mV)").chartYAxisLabel(yLabel)
            .ifCondition(yRange != nil) { $0.chartYScale(domain: yRange!) }
            .frame(height: 240)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { drag in
                                    let frame = geo[proxy.plotAreaFrame]
                                    let loc = CGPoint(x: drag.location.x - frame.minX,
                                                      y: drag.location.y - frame.minY)
                                    guard let dv: Double = proxy.value(atX: loc.x),
                                          let dy: Double = proxy.value(atY: loc.y)
                                    else { return }

                                    if dragging == nil {
                                        // Point le plus proche sur l'axe V
                                        let nearest = cpts.min(by: { abs($0.v - dv) < abs($1.v - dv) })
                                        dragging = nearest.map { ($0.gi, $0.pi) }
                                    }
                                    guard let d = dragging else { return }
                                    var cy = dy
                                    if let r = yRange { cy = max(r.lowerBound, min(r.upperBound, cy)) }
                                    if isInf {
                                        gates[d.gi].infPoints[d.pi].v = dv
                                        gates[d.gi].infPoints[d.pi].y = cy
                                    } else {
                                        gates[d.gi].tauPoints[d.pi].v = dv
                                        gates[d.gi].tauPoints[d.pi].y = cy
                                    }
                                }
                                .onEnded { _ in dragging = nil }
                        )
                }
            }
        }
    }
}

// MARK: - UnifiedGateEditorRow

struct UnifiedGateEditorRow: View {
    @Binding var gate: UnifiedGateDraft
    let color: Color
    let isExpanded: Bool
    let canDelete: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(gate.name.isEmpty ? "(sans nom)" : gate.name).font(.callout.bold())
                    Text("×\(gate.power)").font(.caption2).foregroundStyle(.secondary)
                    Text(gate.infMode == .boltzmann
                         ? "V½=\(String(format: "%.0f", gate.infVHalf))"
                         : "\(gate.infPoints.count) pts spline")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                    if canDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    // Nom + puissance
                    HStack(spacing: 12) {
                        HStack {
                            Text("Nom").font(.caption).frame(width: 40, alignment: .leading)
                            TextField("m", text: $gate.name).frame(width: 60)
                        }
                        HStack {
                            Text("Puissance").font(.caption).frame(width: 60, alignment: .leading)
                            Stepper("\(gate.power)", value: $gate.power, in: 1...8).fixedSize()
                        }
                    }

                    // ── x∞(V) ──────────────────────────────────────────
                    HStack {
                        Text("x∞(V)").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $gate.infMode) {
                            ForEach(UnifiedGateDraft.InfMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                        .onChange(of: gate.infMode) { _, newMode in
                            if newMode == .polynomial && gate.infPoints.isEmpty {
                                gate.populateInfPointsFromBoltzmann()
                            }
                        }
                    }
                    if gate.infMode == .boltzmann {
                        NumericSlider(label: "V½",    value: $gate.infVHalf, range: -100...40,  format: "%.1f", unit: "mV", labelWidth: 60)
                        NumericSlider(label: "Pente", value: $gate.infSlope, range: -30...30, step: 0.5, format: "%.1f", unit: "mV", labelWidth: 60)
                        NumericSlider(label: "lo",    value: $gate.infLo,    range: 0...1,    step: 0.01, format: "%.2f", unit: "",   labelWidth: 60)
                        NumericSlider(label: "hi",    value: $gate.infHi,    range: 0...1,    step: 0.01, format: "%.2f", unit: "",   labelWidth: 60)
                    } else {
                        HStack {
                            Spacer()
                            Button("↺ Recalculer depuis Boltzmann") {
                                gate.populateInfPointsFromBoltzmann()
                            }
                            .font(.caption2).buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        polyPointsEditor(points: $gate.infPoints,
                                         yLabel: "x∞", yMin: 0, yMax: 1)
                    }

                    // ── τ(V) ───────────────────────────────────────────
                    HStack {
                        Text("τ(V)").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $gate.tauMode) {
                            ForEach(UnifiedGateDraft.TauMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                        .onChange(of: gate.tauMode) { _, newMode in
                            if newMode == .polynomial && gate.tauPoints.isEmpty {
                                gate.populateTauPointsFromGaussian()
                            }
                        }
                    }
                    if gate.tauMode == .gaussian {
                        NumericSlider(label: "τ_min",  value: $gate.tauMin,   range: 0.01...50,  format: "%.2f", unit: "ms", labelWidth: 60)
                        NumericSlider(label: "τ_max",  value: $gate.tauMax,   range: 0.01...200, format: "%.2f", unit: "ms", labelWidth: 60)
                        NumericSlider(label: "V_pic",  value: $gate.tauVPeak, range: -100...40,  format: "%.1f", unit: "mV", labelWidth: 60)
                        NumericSlider(label: "Largeur",value: $gate.tauWidth, range: 1...100,    format: "%.1f", unit: "mV", labelWidth: 60)
                    } else {
                        HStack {
                            Spacer()
                            Button("↺ Recalculer depuis Gaussien") {
                                gate.populateTauPointsFromGaussian()
                            }
                            .font(.caption2).buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        polyPointsEditor(points: $gate.tauPoints,
                                         yLabel: "τ", yMin: 0.01, yMax: 200)
                    }
                }
                .padding(10)
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    private func polyPointsEditor(
        points: Binding<[PolyPoint]>,
        yLabel: String, yMin: Double, yMax: Double
    ) -> some View {
        let yStep: Double = yMax <= 1.1 ? 0.05 : 0.5
        let yRange: ClosedRange<Double>? = yMax <= 1.1 ? 0...1 : nil
        return AnyView(

        VStack(alignment: .leading, spacing: 6) {
            // ── Points count + ajouter ────────────────────────────
            HStack(spacing: 12) {
                Text("PCHIP Spline").font(.caption.bold()).foregroundStyle(.secondary)
                Text("(\(points.wrappedValue.count) points)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    let lastV = points.wrappedValue.last?.v ?? -40
                    let lastY = points.wrappedValue.last?.y ?? (yMin + yMax) / 2
                    points.wrappedValue.append(PolyPoint(v: lastV + 20, y: lastY))
                } label: { Label("Point", systemImage: "plus.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help("Ajouter un point")
            }

            // ── Translation globale ───────────────────────────────
            HStack(spacing: 4) {
                Text("ΔV").font(.caption2).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                ForEach([-5, -1, +1, +5], id: \.self) { dv in
                    Button(dv > 0 ? "+\(dv)" : "\(dv)") {
                        for i in points.wrappedValue.indices { points.wrappedValue[i].v += Double(dv) }
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
                Text("mV").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Δy").font(.caption2).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                Button("-") {
                    for i in points.wrappedValue.indices {
                        let ny = points.wrappedValue[i].y - yStep
                        points.wrappedValue[i].y = yRange.map { max($0.lowerBound, ny) } ?? ny
                    }
                }
                .buttonStyle(.bordered).controlSize(.mini)
                Button("+") {
                    for i in points.wrappedValue.indices {
                        let ny = points.wrappedValue[i].y + yStep
                        points.wrappedValue[i].y = yRange.map { min($0.upperBound, ny) } ?? ny
                    }
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }

            // ── Table des points ──────────────────────────────────
            ForEach(points.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text("V").font(.caption2).frame(width: 14)
                    TextField("V", value: points[i].v, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder).frame(width: 68)
                    Text(yLabel).font(.caption2).frame(width: 14)
                    TextField(yLabel, value: points[i].y, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder).frame(width: 68)
                    Button(role: .destructive) {
                        if points.wrappedValue.count > 2 { points.wrappedValue.remove(at: i) }
                    } label: { Image(systemName: "minus.circle").font(.caption) }
                    .buttonStyle(.borderless)
                }
            }
        })
    }
}

// MARK: - GateEditorRow alias

typealias GateEditorRow = UnifiedGateEditorRow

// MARK: - Extensions

extension View {
    @ViewBuilder
    func ifCondition<C: View>(_ condition: Bool, transform: (Self) -> C) -> some View {
        if condition { transform(self) } else { self }
    }
}
