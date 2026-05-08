//
//  ChannelEditorSheet.swift
//  NeuroSimApp
//
//  Éditeur de canal unifié — ouvre la même fenêtre que le canal vienne de la
//  bibliothèque, de l'inspector d'un compartiment ou d'un canal HH intégré.
//
//  Modes d'interpolation par gate :
//   x∞(V) : Boltzmann (sigmoid) ou Polynomial (coefficients)
//   τ(V)  : Gaussien (bell) ou Polynomial (coefficients)
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - Constantes partagées

let kGateColors: [Color] = [.blue, .orange, .green, .red, .purple]

// MARK: - UnifiedGateDraft

/// Draft d'édition pour une variable de gate — indépendant du format de stockage.
struct UnifiedGateDraft: Identifiable {
    var id = UUID()
    var name: String
    var power: Int

    // x∞(V)
    var infMode: InfMode = .boltzmann
    var infLo:    Double = 0
    var infHi:    Double = 1
    var infVHalf: Double = -40
    var infSlope: Double = 7     // k > 0 = activation, < 0 = inactivation

    // τ(V)
    var tauMode:  TauMode = .gaussian
    var tauMin:   Double = 0.5
    var tauMax:   Double = 5.0
    var tauVPeak: Double = -40
    var tauWidth: Double = 20

    // Polynomial : coefficients directs + vCenter
    var infPolyCoeffs:  [Double] = [0.5]
    var infPolyVCenter: Double   = -40
    var tauPolyCoeffs:  [Double] = [2.0]
    var tauPolyVCenter: Double   = -40

    enum InfMode: String, CaseIterable, Identifiable {
        case boltzmann = "Boltzmann"
        case polynomial = "Polynomial"
        var id: String { rawValue }
    }
    enum TauMode: String, CaseIterable, Identifiable {
        case gaussian = "Gaussien"
        case polynomial = "Polynomial"
        var id: String { rawValue }
    }

    // MARK: Courbes effectives pour preview et sauvegarde

    var infCurve: GateCurve {
        switch infMode {
        case .boltzmann:
            return .sigmoid(lo: infLo, hi: infHi, vHalf: infVHalf, k: infSlope, domain: nil)
        case .polynomial:
            return .polynomial(coefficients: infPolyCoeffs.isEmpty ? [0.5] : infPolyCoeffs,
                               vCenter: infPolyVCenter, domain: nil)
        }
    }

    var tauCurve: GateCurve {
        switch tauMode {
        case .gaussian:
            return .gaussian(tauMin: tauMin, tauMax: tauMax,
                             vPeak: tauVPeak, width: tauWidth, domain: nil)
        case .polynomial:
            return .polynomial(coefficients: tauPolyCoeffs.isEmpty ? [1.0] : tauPolyCoeffs,
                               vCenter: tauPolyVCenter, domain: nil)
        }
    }

    // MARK: Initialiseurs

    /// Depuis un GateDef (canal custom).
    init(from def: GateDef) {
        id = def.id
        name = def.name
        power = def.power
        infMode = .boltzmann
        infLo = 0; infHi = 1
        infVHalf = def.vHalf; infSlope = def.slope
        tauMode = .gaussian
        tauMin = def.tauMin; tauMax = def.tauMax
        tauVPeak = def.vPeak; tauWidth = def.tauWidth
    }

    /// Depuis un canal HHGated (canal intégré ou custom), pour le gate à l'index i.
    init(from channel: any HHGated, index: Int) {
        name = channel.gateNames[safe: index] ?? "g\(index)"
        power = 1

        // x∞ : utiliser l'override existant ou fitter un sigmoid sur la courbe intégrée
        if let ov = channel.gateInfOverrides[safe: index] ?? nil {
            switch ov {
            case let .sigmoid(lo, hi, vHalf, k, _):
                infMode = .boltzmann; infLo = lo; infHi = hi; infVHalf = vHalf; infSlope = k
            case let .polynomial(coeffs, vC, _):
                infMode = .polynomial; infPolyCoeffs = coeffs; infPolyVCenter = vC
            default:
                infMode = .boltzmann
                let (vH, k, lo, hi) = Self.fitSigmoid(channel: channel, index: index)
                infVHalf = vH; infSlope = k; infLo = lo; infHi = hi
            }
        } else {
            infMode = .boltzmann
            let (vH, k, lo, hi) = Self.fitSigmoid(channel: channel, index: index)
            infVHalf = vH; infSlope = k; infLo = lo; infHi = hi
        }

        // τ : utiliser l'override existant ou fitter un gaussien
        if let ov = channel.gateTauOverrides[safe: index] ?? nil {
            switch ov {
            case let .gaussian(tMin, tMax, vP, w, _):
                tauMode = .gaussian; tauMin = tMin; tauMax = tMax; tauVPeak = vP; tauWidth = w
            case let .polynomial(coeffs, vC, _):
                tauMode = .polynomial; tauPolyCoeffs = coeffs; tauPolyVCenter = vC
            default:
                tauMode = .gaussian
                let (tMin, tMax, vP, w) = Self.fitGaussian(channel: channel, index: index)
                tauMin = tMin; tauMax = tMax; tauVPeak = vP; tauWidth = w
            }
        } else {
            tauMode = .gaussian
            let (tMin, tMax, vP, w) = Self.fitGaussian(channel: channel, index: index)
            tauMin = tMin; tauMax = tMax; tauVPeak = vP; tauWidth = w
        }
    }

    // MARK: Fit numérique

    private static func fitSigmoid(channel: any HHGated, index: Int)
            -> (vHalf: Double, k: Double, lo: Double, hi: Double) {
        let lo = channel.gateInf(index, voltage: -100)
        let hi = channel.gateInf(index, voltage:   60)
        let target = (lo + hi) / 2
        var va = -100.0, vb = 60.0
        for _ in 0..<60 {
            let vm = (va + vb) / 2
            if channel.gateInf(index, voltage: vm) < target { va = vm } else { vb = vm }
        }
        let vHalf = (va + vb) / 2
        let dv = 0.5
        let dx = channel.gateInf(index, voltage: vHalf + dv)
             - channel.gateInf(index, voltage: vHalf - dv)
        let dxdv = dx / (2 * dv)
        let xm = channel.gateInf(index, voltage: vHalf)
        let k  = abs(dxdv) > 1e-9 ? xm * (1 - xm) / dxdv : 7.0
        return (vHalf, k, lo, hi)
    }

    private static func fitGaussian(channel: any HHGated, index: Int)
            -> (tauMin: Double, tauMax: Double, vPeak: Double, width: Double) {
        let vs = stride(from: -100.0, through: 60.0, by: 1.0).map { $0 }
        let taus = vs.map { channel.gateTau(index, voltage: $0) }
        let tauMax = taus.max() ?? 5
        let tauMin = taus.min() ?? 0.5
        let peakIdx = taus.indices.max(by: { taus[$0] < taus[$1] }) ?? vs.count / 2
        let vPeak = vs[peakIdx]
        let halfMax = tauMin + (tauMax - tauMin) * 0.5
        let above = vs.enumerated().filter { taus[$0.offset] >= halfMax }
        let width: Double
        if let first = above.first?.element, let last = above.last?.element {
            width = max((last - first) / 2.355, 5)
        } else {
            width = 20
        }
        return (tauMin, tauMax, vPeak, width)
    }

    /// Convertit ce draft en GateDef (pour CustomChannel uniquement).
    func toGateDef() -> GateDef {
        GateDef(id: id, name: name, power: power,
                vHalf: infVHalf, slope: infSlope,
                tauMin: tauMin, tauMax: tauMax,
                vPeak: tauVPeak, tauWidth: tauWidth)
    }
}

// MARK: - Contexte

enum ChannelEditorContext {
    /// Crée ou met à jour une entrée dans la bibliothèque.
    case library(draft: CustomChannelDefinition,
                 onSave: (CustomChannelDefinition) -> Void)
    /// Édite un canal HHGated existant dans un compartiment.
    case compartment(channel: any HHGated,
                     onSave: (any HHGated) -> Void)

    var saveLabel: String {
        switch self {
        case .library:     return "Enregistrer dans la bibliothèque"
        case .compartment: return "Appliquer"
        }
    }
}

// MARK: - ChannelEditorSheet

struct ChannelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Paramètres communs (gMax, reversal, ionSymbol, name)
    @State private var channelName:  String
    @State private var ionSymbol:    String?
    @State private var gMax:         Double
    @State private var reversal:     Double
    @State private var gates:        [UnifiedGateDraft]
    @State private var expandedGate: UUID? = nil

    let context: ChannelEditorContext

    // MARK: Init depuis la bibliothèque

    init(draft: CustomChannelDefinition, context: ChannelEditorContext) {
        _channelName = State(initialValue: draft.name)
        _ionSymbol   = State(initialValue: draft.ionSymbol)
        _gMax        = State(initialValue: draft.gMax)
        _reversal    = State(initialValue: draft.reversal)
        _gates       = State(initialValue: draft.gates.map { UnifiedGateDraft(from: $0) })
        self.context = context
    }

    // MARK: Init depuis un canal HHGated (inspector)

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

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { formSection; gatesSection }
                        .padding(16)
                }
                .frame(width: 400)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { previewSection }.padding(16)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    // MARK: Header

    private var headerBar: some View {
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
    }

    // MARK: Sauvegarde

    private func save() {
        switch context {
        case let .library(draft, onSave):
            var updated = draft
            updated.name      = channelName
            updated.ionSymbol = ionSymbol
            updated.gMax      = gMax
            updated.reversal  = reversal
            updated.gates     = gates.map { $0.toGateDef() }
            onSave(updated)

        case let .compartment(channel, onSave):
            channel.gMax    = gMax
            channel.reversal = reversal
            // Appliquer les overrides sur le canal existant
            for (i, g) in gates.enumerated() {
                if i < channel.gateInfOverrides.count {
                    channel.gateInfOverrides[i] = g.infCurve
                    channel.gateTauOverrides[i]  = g.tauCurve
                }
            }
            // Si c'est un CustomChannel, sync aussi les GateDef pour cohérence
            if let cc = channel as? CustomChannel {
                for (i, g) in gates.enumerated() {
                    if i < cc.definition.gates.count {
                        cc.definition.gates[i] = g.toGateDef()
                    }
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
            if case .library = context {
                HStack {
                    Text("Ion").frame(width: 80, alignment: .leading)
                    Picker("", selection: $ionSymbol) {
                        Text("Aucun / mixte").tag(Optional<String>.none)
                        Divider()
                        ForEach(IonSpecies.allCanonical, id: \.symbol) { sp in
                            Text("\(sp.symbol)\(sp.valence > 0 ? "+" : "")  (\(sp.valence > 0 ? "+" : "")\(sp.valence))")
                                .tag(Optional(sp.symbol))
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .onChange(of: ionSymbol) { _, sym in
                        if let sp = sym.flatMap(IonSpecies.canonical(symbol:)) {
                            reversal = sp.defaultReversal()
                        }
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
                if case .library = context {
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
                    canDelete: (context.isLibrary),
                    onToggle: { let gid = gates[i].id; expandedGate = expandedGate == gid ? nil : gid },
                    onDelete: { gates.remove(at: i) }
                )
            }
        }
    }

    private func defaultGateName() -> String {
        let used = Set(gates.map(\.name))
        return ["m", "h", "n", "p", "q", "r", "s"].first { !used.contains($0) } ?? "x\(gates.count)"
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aperçu").font(.headline)
            if gates.isEmpty {
                Text("Ajoutez au moins un gate pour voir les courbes.").font(.caption).foregroundStyle(.secondary)
            } else {
                previewChart("x∞(V)", yLabel: "Probabilité", yRange: nil) { g, v in
                    g.infCurve.evaluate(at: v) ?? 0
                }
                previewChart("τ(V)", yLabel: "τ (ms)", yRange: nil) { g, v in
                    g.tauCurve.evaluate(at: v) ?? 0
                }
            }
        }
    }

    private func previewChart(_ title: String, yLabel: String, yRange: ClosedRange<Double>?,
                               valueFor: (UnifiedGateDraft, Double) -> Double) -> some View {
        struct Pt: Identifiable { let id: String; let v, y: Double; let gate: String }
        var pts: [Pt] = []
        for (i, gate) in gates.enumerated() {
            let label = "\(gate.name) (×\(gate.power))"
            for v in stride(from: -100.0, through: 60.0, by: 1.0) {
                pts.append(Pt(id: "\(i)\(v)", v: v, y: valueFor(gate, v), gate: label))
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Chart(pts) { pt in
                LineMark(x: .value("V (mV)", pt.v), y: .value(yLabel, pt.y))
                    .foregroundStyle(by: .value("Gate", pt.gate))
                    .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(
                domain: gates.enumerated().map { "\($1.name) (×\($1.power))" },
                range: gates.indices.map { kGateColors[$0 % kGateColors.count] }
            )
            .chartXAxisLabel("V (mV)").chartYAxisLabel(yLabel)
            .ifCondition(yRange != nil) { $0.chartYScale(domain: yRange!) }
            .frame(height: 160)
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
            // En-tête (toujours visible)
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(gate.name.isEmpty ? "(sans nom)" : gate.name).font(.callout.bold())
                    Text("×\(gate.power)").font(.caption2).foregroundStyle(.secondary)
                    Text(gate.infMode == .boltzmann
                         ? "V½=\(String(format: "%.0f", gate.infVHalf))mV"
                         : "poly")
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

                    // x∞(V)
                    HStack {
                        Text("x∞(V)").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $gate.infMode) {
                            ForEach(UnifiedGateDraft.InfMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                    }
                    if gate.infMode == .boltzmann {
                        NumericSlider(label: "V½",    value: $gate.infVHalf,  range: -100...40,  format: "%.1f", unit: "mV", labelWidth: 60)
                        NumericSlider(label: "Pente", value: $gate.infSlope,  range: -30...30,   step: 0.5, format: "%.1f", unit: "mV", labelWidth: 60)
                        NumericSlider(label: "lo",    value: $gate.infLo,     range: 0...1,      step: 0.01, format: "%.2f", unit: "",  labelWidth: 60)
                        NumericSlider(label: "hi",    value: $gate.infHi,     range: 0...1,      step: 0.01, format: "%.2f", unit: "",  labelWidth: 60)
                    } else {
                        polyCoeffEditor(coeffs: $gate.infPolyCoeffs, vCenter: $gate.infPolyVCenter)
                    }

                    // τ(V)
                    HStack {
                        Text("τ(V)").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $gate.tauMode) {
                            ForEach(UnifiedGateDraft.TauMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                    }
                    if gate.tauMode == .gaussian {
                        NumericSlider(label: "τ_min",  value: $gate.tauMin,   range: 0.01...50,  format: "%.2f", unit: "ms", labelWidth: 60)
                        NumericSlider(label: "τ_max",  value: $gate.tauMax,   range: 0.01...200, format: "%.2f", unit: "ms", labelWidth: 60)
                        NumericSlider(label: "V_pic",  value: $gate.tauVPeak, range: -100...40,  format: "%.1f", unit: "mV", labelWidth: 60)
                        NumericSlider(label: "Largeur",value: $gate.tauWidth, range: 1...100,    format: "%.1f", unit: "mV", labelWidth: 60)
                    } else {
                        polyCoeffEditor(coeffs: $gate.tauPolyCoeffs, vCenter: $gate.tauPolyVCenter)
                    }
                }
                .padding(10)
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    @ViewBuilder
    private func polyCoeffEditor(coeffs: Binding<[Double]>, vCenter: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NumericSlider(label: "V_centre", value: vCenter, range: -100...60, format: "%.1f", unit: "mV", labelWidth: 60)
            Text("Coefficients c0, c1, c2, … (y = Σ cᵢ·(V−Vc)ⁱ)")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(coeffs.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text("c\(i)").font(.caption2).frame(width: 24, alignment: .trailing)
                    TextField("0", value: coeffs[i], format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
            }
            HStack(spacing: 8) {
                Button("+ coeff") { coeffs.wrappedValue.append(0) }
                    .buttonStyle(.borderless).font(.caption)
                if coeffs.wrappedValue.count > 1 {
                    Button("– coeff") { coeffs.wrappedValue.removeLast() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }
}

// MARK: - GateEditorRow (alias pour la bibliothèque — retro-compat)

typealias GateEditorRow = UnifiedGateEditorRow

// MARK: - Extensions

extension ChannelEditorContext {
    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

extension View {
    @ViewBuilder
    func ifCondition<C: View>(_ condition: Bool, transform: (Self) -> C) -> some View {
        if condition { transform(self) } else { self }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
