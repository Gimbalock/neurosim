//
//  ChannelEditorSheet.swift
//  NeuroSimApp
//
//  Éditeur générique de canal — utilisé à la fois depuis la bibliothèque et
//  depuis l'inspector d'un compartiment. Seul le contexte (label du bouton
//  "Enregistrer" et callback onSave) diffère entre les deux usages.
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - Constantes

let kGateColors: [Color] = [.blue, .orange, .green, .red, .purple]

// MARK: - Contexte

enum ChannelEditorContext {
    case library(onSave: (CustomChannelDefinition) -> Void)
    case compartment(onSave: (CustomChannelDefinition) -> Void)

    var saveLabel: String {
        switch self {
        case .library:     return "Enregistrer dans la bibliothèque"
        case .compartment: return "Appliquer"
        }
    }

    func callSave(_ def: CustomChannelDefinition) {
        switch self {
        case .library(let cb), .compartment(let cb): cb(def)
        }
    }
}

// MARK: - ChannelEditorSheet

struct ChannelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomChannelDefinition
    @State private var expandedGate: UUID? = nil
    let context: ChannelEditorContext

    init(draft: CustomChannelDefinition, context: ChannelEditorContext) {
        _draft = State(initialValue: draft)
        self.context = context
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "Canal" : draft.name).font(.title3.bold())
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                Button(context.saveLabel) { context.callSave(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.isEmpty || draft.gates.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { formSection; gatesSection }
                        .padding(16)
                }
                .frame(width: 360)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { previewSection }.padding(16)
                }
            }
        }
        .frame(minWidth: 750, minHeight: 520)
    }

    // MARK: Formulaire

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canal").font(.headline)
            HStack {
                Text("Nom").frame(width: 80, alignment: .leading)
                TextField("ex. Kv4.2", text: $draft.name)
            }
            HStack {
                Text("Ion").frame(width: 80, alignment: .leading)
                Picker("", selection: $draft.ionSymbol) {
                    Text("Aucun / mixte").tag(Optional<String>.none)
                    Divider()
                    ForEach(IonSpecies.allCanonical, id: \.symbol) { sp in
                        Text("\(sp.symbol)\(sp.valence > 0 ? "+" : "")  (\(sp.valence > 0 ? "+" : "")\(sp.valence))")
                            .tag(Optional(sp.symbol))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .onChange(of: draft.ionSymbol) { _, sym in
                    if let sp = sym.flatMap(IonSpecies.canonical(symbol:)) {
                        draft.reversal = sp.defaultReversal()
                    }
                }
                if let sym = draft.ionSymbol, let sp = IonSpecies.canonical(symbol: sym) {
                    Text(ionLabel(sp)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            NumericSlider(label: "g_max", value: $draft.gMax,     range: 0...200,    format: "%.2f", unit: "mS/cm²", labelWidth: 80)
            NumericSlider(label: "E_rev", value: $draft.reversal, range: -100...140, format: "%.1f", unit: "mV",     labelWidth: 80)
            if let sym = draft.ionSymbol, let sp = IonSpecies.canonical(symbol: sym) {
                Text("E_rev (Nernst) = \(String(format: "%.1f", sp.defaultReversal())) mV  ·  [in]=\(cLabel(sp.defaultConcentrationIn)) [out]=\(cLabel(sp.defaultConcentrationOut)) mM")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ionLabel(_ sp: IonSpecies) -> String {
        "[in]=\(cLabel(sp.defaultConcentrationIn)) mM  [out]=\(cLabel(sp.defaultConcentrationOut)) mM"
    }
    private func cLabel(_ c: Double) -> String {
        c < 0.01 ? String(format: "%.1e", c) : String(format: "%.1f", c)
    }

    // MARK: Gates

    private var gatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gates").font(.headline)
                Spacer()
                Button {
                    let g = GateDef(name: defaultGateName())
                    draft.gates.append(g)
                    expandedGate = g.id
                } label: { Label("Ajouter", systemImage: "plus.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
            }
            if draft.gates.isEmpty {
                Text("Aucun gate — canal passif pur (leak).").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(draft.gates.indices, id: \.self) { i in
                GateEditorRow(
                    gate: $draft.gates[i],
                    color: kGateColors[i % kGateColors.count],
                    isExpanded: expandedGate == draft.gates[i].id,
                    onToggle: {
                        let gid = draft.gates[i].id
                        expandedGate = expandedGate == gid ? nil : gid
                    },
                    onDelete: { draft.gates.remove(at: i) }
                )
            }
        }
    }

    private func defaultGateName() -> String {
        let used = Set(draft.gates.map(\.name))
        return ["m", "h", "n", "p", "q", "r", "s"].first { !used.contains($0) } ?? "x\(draft.gates.count)"
    }

    // MARK: Aperçu

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aperçu").font(.headline)
            if draft.gates.isEmpty {
                Text("Ajoutez au moins un gate pour voir les courbes.").font(.caption).foregroundStyle(.secondary)
            } else {
                previewChart("x∞(V)", yLabel: "Probabilité d'ouverture", yRange: 0...1) { g, v in
                    guard abs(g.slope) > 1e-12 else { return v < g.vHalf ? 0 : 1 }
                    return 1.0 / (1.0 + exp(-(v - g.vHalf) / g.slope))
                }
                previewChart("τ(V)", yLabel: "Constante de temps (ms)", yRange: nil) { g, v in
                    let s = max(g.tauWidth, 1e-6)
                    let u = (v - g.vPeak) / s
                    return g.tauMin + (g.tauMax - g.tauMin) * exp(-0.5 * u * u)
                }
            }
        }
    }

    private func previewChart(_ title: String, yLabel: String, yRange: ClosedRange<Double>?,
                               valueFor: (GateDef, Double) -> Double) -> some View {
        struct Pt: Identifiable { let id: String; let v, y: Double; let gate: String }
        var pts: [Pt] = []
        for (i, gate) in draft.gates.enumerated() {
            let label = "\(gate.name) (×\(gate.power))"
            for v in stride(from: -100.0, through: 40.0, by: 1.0) {
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
                domain: draft.gates.enumerated().map { "\($1.name) (×\($1.power))" },
                range: draft.gates.indices.map { kGateColors[$0 % kGateColors.count] }
            )
            .chartXAxisLabel("V (mV)").chartYAxisLabel(yLabel)
            .ifCondition(yRange != nil) { $0.chartYScale(domain: yRange!) }
            .frame(height: 160)
        }
    }
}

// MARK: - GateEditorRow

struct GateEditorRow: View {
    @Binding var gate: GateDef
    let color: Color
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(gate.name.isEmpty ? "(sans nom)" : gate.name).font(.callout.bold())
                    Text("pow=\(gate.power)").font(.caption2).foregroundStyle(.secondary)
                    Text("V½=\(String(format: "%.0f", gate.vHalf))mV").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
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
                    Text("Activation x∞(V) — Boltzmann").font(.caption.bold()).foregroundStyle(.secondary)
                    NumericSlider(label: "V½",    value: $gate.vHalf,  range: -100...40, format: "%.1f", unit: "mV", labelWidth: 60)
                    NumericSlider(label: "Pente", value: $gate.slope,  range: -30...30,  step: 0.5, format: "%.1f", unit: "mV", labelWidth: 60)
                    Text("Constante de temps τ(V) — Gaussienne").font(.caption.bold()).foregroundStyle(.secondary)
                    NumericSlider(label: "τ_min",  value: $gate.tauMin,   range: 0.01...50,  format: "%.2f", unit: "ms",  labelWidth: 60)
                    NumericSlider(label: "τ_max",  value: $gate.tauMax,   range: 0.01...200, format: "%.2f", unit: "ms",  labelWidth: 60)
                    NumericSlider(label: "V_pic",  value: $gate.vPeak,    range: -100...40,  format: "%.1f", unit: "mV",  labelWidth: 60)
                    NumericSlider(label: "Largeur",value: $gate.tauWidth, range: 1...100,    format: "%.1f", unit: "mV",  labelWidth: 60)
                }
                .padding(10)
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

// MARK: - View helper

extension View {
    @ViewBuilder
    func ifCondition<C: View>(_ condition: Bool, transform: (Self) -> C) -> some View {
        if condition { transform(self) } else { self }
    }
}
