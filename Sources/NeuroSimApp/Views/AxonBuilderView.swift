//
//  AxonBuilderView.swift
//  NeuroSimApp
//
//  Constructeur d'axone multi-compartiment.
//
//  L'axone est **attaché au neurone sélectionné** dans l'éditeur (neurone ou
//  compartiment soma). Les nouveaux compartiments sont ajoutés au neurone
//  existant via des couplages axiaux — aucun stimulus n'est nécessaire car
//  les PA se propagent depuis le soma.
//
//  Workflow
//  ────────
//  1. Sélectionner un neurone (ou compartiment soma) dans l'éditeur
//  2. Ouvrir le constructeur (icône câble dans la palette)
//  3. Régler longueur / diamètre / myéline
//  4. Cliquer « Attacher »
//
//  ─── Physique des couplages axiaux ──────────────────────────────────────────
//
//  Modèle demi-longueur (ρ_a = 100 Ω·cm) :
//
//      g_ij = 50 000 / (L_i + L_j)   [mS/cm²]
//
//  Application soma↔axone[0] :
//      L_i = soma.length   (µm)
//      L_j = dx            (longueur du premier segment axonal)
//
//  ─── Correction d'aire pour les compartiments allongés ──────────────────────
//
//  NeuroSim calcule l'aire comme une sphère (π·d²·1e-8 cm²).
//  Pour les cylindres où L ≠ d, on multiplie les densités par (L / d).
//
import SwiftUI
import NeuroSimCore

// MARK: - Parameters

struct AxonParams {
    var totalLength:     Double = 1000    // µm
    var diameter:        Double = 5.0     // µm
    var myelinated:      Bool   = false
    // Myelinated-only
    var internodeLength: Double = 500     // µm  (≈ 100 × d)
    var nodeLength:      Double = 1.5     // µm
    // Axial resistivity (Ω·cm)
    var rhoA:            Double = 100.0
}

// MARK: - View

struct AxonBuilderView: View {

    @EnvironmentObject var vm: SimulationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var p = AxonParams()
    @State private var replaceExisting = true   // purge existing non-soma compartments

    // MARK: - Attachment target

    /// Neuron + compartment to attach the axon to, derived from current selection.
    private var target: (neuron: HHNeuron, soma: Compartment)? {
        switch vm.selection {
        case .neuron(let nid):
            guard let n = vm.network.neurons.first(where: { $0.id == nid }),
                  let soma = n.compartments.first(where: { $0.id == n.somaCompartmentID })
            else { return nil }
            return (n, soma)
        case .compartment(let cid):
            guard let n = vm.network.neurons.first(where: { n in
                n.compartments.contains(where: { $0.id == cid })
            }),
                  let soma = n.compartments.first(where: { $0.id == cid })
            else { return nil }
            return (n, soma)
        default:
            return nil
        }
    }

    private var hasExistingAxon: Bool {
        guard let t = target else { return false }
        return t.neuron.compartments.count > 1
    }

    // MARK: - Computed geometry

    private var segDx: Double { p.diameter }    // segment length = d for unmyelinated

    private var nSegUnmyel: Int {
        max(2, Int((p.totalLength / segDx).rounded()))
    }

    private var nInternodesMyel: Int {
        max(1, Int((p.totalLength / (p.nodeLength + p.internodeLength)).rounded()))
    }
    private var nNodesMyel: Int { nInternodesMyel + 1 }
    private var nCompsMyel: Int { nNodesMyel + nInternodesMyel }

    private var nCompartments: Int {
        p.myelinated ? nCompsMyel : nSegUnmyel
    }

    // Space constant λ (µm) — unmyelinated
    private var lambda_um: Double {
        let d_cm = p.diameter * 1e-4
        let gL_S = 0.3e-3           // S/cm² (HH leak)
        return sqrt(d_cm / (4 * p.rhoA * gL_S)) * 1e4
    }

    // Rushton conduction velocity estimate (m/s)
    private var vConduction: Double {
        p.myelinated
            ? 6.0 * (p.diameter / 0.7) / 1000.0
            : 0.55 * sqrt(p.diameter)
    }

    private var tooMany: Bool { nCompartments > 500 }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────
            HStack {
                Image(systemName: "cable.connector.horizontal")
                    .foregroundStyle(.cyan)
                Text("Constructeur d'axone")
                    .font(.headline)
                Spacer()
                Button("Fermer") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // ── Cible d'attachement ────────────────────────────────────
                    attachmentSection

                    // ── Géométrie ──────────────────────────────────────────────
                    paramGroup("Géométrie") {
                        sliderRow("Longueur totale",   value: $p.totalLength,
                                  in: 50...10000, step: 50, fmt: "%.0f", unit: "µm")
                        sliderRow("Diamètre axonal",   value: $p.diameter,
                                  in: 0.5...20, step: 0.5, fmt: "%.1f", unit: "µm")
                    }

                    // ── Myéline ────────────────────────────────────────────────
                    paramGroup("Myélinisation") {
                        Toggle("Axone myélinisé", isOn: $p.myelinated)
                            .toggleStyle(.switch)

                        if p.myelinated {
                            sliderRow("Long. internodale",     value: $p.internodeLength,
                                      in: 20...3000, step: 20, fmt: "%.0f", unit: "µm")
                            sliderRow("Long. nœud de Ranvier", value: $p.nodeLength,
                                      in: 0.5...5, step: 0.5,  fmt: "%.1f", unit: "µm")
                        }
                    }

                    // ── Aperçu physique ────────────────────────────────────────
                    paramGroup("Aperçu physique") {
                        physicsGrid()
                    }

                    // ── Diagramme ──────────────────────────────────────────────
                    axonDiagram()
                        .frame(height: 56)
                }
                .padding(14)
            }

            Divider()

            // ── Footer ──────────────────────────────────────────────────────────
            HStack {
                Text("\(nCompartments) compartiment\(nCompartments == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attacher") {
                    attachAxon()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil || tooMany)
            }
            .padding(14)
        }
        .frame(minWidth: 480, minHeight: 500)
        .onChange(of: p.diameter) {
            p.internodeLength = min(3000, max(20, p.diameter * 100))
        }
        .onChange(of: p.myelinated) {
            if p.myelinated { p.internodeLength = min(3000, max(20, p.diameter * 100)) }
        }
    }

    // MARK: - Attachment section

    @ViewBuilder
    private var attachmentSection: some View {
        paramGroup("Attachement au neurone") {
            if let t = target {
                // ── Cible identifiée ──────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.neuron.name)
                            .font(.callout.weight(.semibold))
                        HStack(spacing: 4) {
                            Text("Compartiment d'attache :")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(t.soma.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.cyan.opacity(0.9))
                        }
                    }
                    Spacer()
                    // Conductance soma↔axone[0]
                    let dx = p.myelinated ? p.nodeLength : segDx
                    let gSoma = 50_000.0 / (max(t.soma.length, dx) + dx)
                    Text(String(format: "g = %.0f mS/cm²", gSoma))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Warning si l'axone existant sera remplacé
                if hasExistingAxon {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Ce neurone a déjà \(t.neuron.compartments.count - 1) compartiment\(t.neuron.compartments.count > 2 ? "s" : "") non-soma.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Remplacer l'axone existant avant d'attacher",
                           isOn: $replaceExisting)
                        .toggleStyle(.switch)
                        .font(.callout)
                }

            } else {
                // ── Aucune sélection ──────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.circle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aucun neurone sélectionné")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("Sélectionnez un neurone ou un compartiment soma\ndans l'éditeur, puis revenez ici.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func paramGroup<C: View>(_ title: String,
                                     @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func sliderRow(_ label: String, value: Binding<Double>,
                           in range: ClosedRange<Double>, step: Double,
                           fmt: String, unit: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .frame(width: 170, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(String(format: fmt, value.wrappedValue) + " " + unit)
                .font(.callout.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func physicsGrid() -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Compartiments ajoutés").font(.caption).foregroundStyle(.secondary)
                Text("\(nCompartments)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tooMany ? .red : .primary)
            }
            if !p.myelinated {
                GridRow {
                    Text("Longueur de segment").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f µm", segDx)).font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("Constante d'espace λ").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.0f µm", lambda_um)).font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("Seg. par λ").font(.caption).foregroundStyle(.secondary)
                    let nPerLambda = lambda_um / segDx
                    Text(String(format: "%.0f", nPerLambda)
                         + (nPerLambda < 5 ? " ⚠ faible résolution" : " ✓"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(nPerLambda < 5 ? .orange : .primary)
                }
            } else {
                GridRow {
                    Text("Nœuds de Ranvier").font(.caption).foregroundStyle(.secondary)
                    Text("\(nNodesMyel)").font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("Internodes").font(.caption).foregroundStyle(.secondary)
                    Text("\(nInternodesMyel)").font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("Long. internodal / d").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.0f×", p.internodeLength / p.diameter))
                        .font(.caption.monospacedDigit())
                }
            }
            GridRow {
                Text("Vitesse cond. (Rushton)").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.2f m/s", vConduction)).font(.caption.monospacedDigit())
            }
            GridRow {
                Text("Couplage axial g₁₂").font(.caption).foregroundStyle(.secondary)
                let g = p.myelinated
                    ? 50000.0 / (p.nodeLength + p.internodeLength)
                    : 50000.0 / (segDx + segDx)
                Text(String(format: "%.1f mS/cm²", g)).font(.caption.monospacedDigit())
            }
            if tooMany {
                GridRow {
                    Text("").gridCellUnsizedAxes(.horizontal)
                    Text("⚠ Trop de compartiments (max 500)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .gridCellColumns(2)
                }
            }
        }
    }

    // Mini-schéma de l'axone (soma à gauche + segments)
    @ViewBuilder
    private func axonDiagram() -> some View {
        Canvas { ctx, size in
            let midY  = size.height / 2
            let somaR = size.height * 0.36
            let somaX = somaR + 2           // centre du soma

            // ── Cercle soma ──────────────────────────────────────────────────
            let somaRect = CGRect(x: somaX - somaR, y: midY - somaR,
                                  width: somaR * 2, height: somaR * 2)
            ctx.fill(Path(ellipseIn: somaRect),
                     with: .color(Color(red: 0.95, green: 0.75, blue: 0.25).opacity(0.9)))
            ctx.draw(
                Text("S").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.black),
                at: CGPoint(x: somaX, y: midY)
            )

            // ── Segments axonaux à droite ────────────────────────────────────
            let axonStart = somaX + somaR + 3
            let axonWidth = size.width - axonStart - 4

            if p.myelinated {
                let nodeW: CGFloat = 7
                let nVisualNodes     = min(nNodesMyel, 20)
                let nVisualInternodes = min(nInternodesMyel, nVisualNodes - 1)
                let totalNodeW = CGFloat(nVisualNodes) * nodeW
                let usableW    = axonWidth - totalNodeW
                let intW = nVisualInternodes > 0
                    ? usableW / CGFloat(nVisualInternodes)
                    : usableW

                var x: CGFloat = axonStart
                let items = nVisualNodes + nVisualInternodes
                for i in 0..<items {
                    let isNode = (i % 2 == 0)
                    if isNode {
                        let r = CGRect(x: x, y: midY - size.height * 0.38,
                                       width: nodeW, height: size.height * 0.76)
                        ctx.fill(Path(r), with: .color(.orange.opacity(0.9)))
                        x += nodeW
                    } else {
                        let w = min(intW, size.width - x - nodeW)
                        let outer = CGRect(x: x, y: midY - size.height * 0.46,
                                           width: w, height: size.height * 0.92)
                        let inner = CGRect(x: x, y: midY - size.height * 0.18,
                                           width: w, height: size.height * 0.36)
                        ctx.fill(Path(outer),
                                 with: .color(Color(red: 0.75, green: 0.88, blue: 1.0).opacity(0.7)))
                        ctx.fill(Path(inner), with: .color(.gray.opacity(0.45)))
                        x += w
                    }
                }
                if nNodesMyel > 20 {
                    ctx.draw(Text("…").foregroundColor(.white).font(.system(size: 11)),
                             at: CGPoint(x: size.width - 8, y: midY))
                }
            } else {
                let n = min(nSegUnmyel, 80)
                let w = axonWidth / CGFloat(max(n, 1))
                for i in 0..<n {
                    let x = axonStart + CGFloat(i) * w
                    let r = CGRect(x: x + 0.5, y: midY - size.height * 0.32,
                                   width: w - 1, height: size.height * 0.64)
                    let alpha: Double = i % 2 == 0 ? 0.55 : 0.75
                    ctx.fill(Path(r), with: .color(Color.cyan.opacity(alpha)))
                }
                if nSegUnmyel > 80 {
                    ctx.draw(Text("…").foregroundColor(.white).font(.system(size: 11)),
                             at: CGPoint(x: size.width - 8, y: midY))
                }
            }
        }
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            let label = p.myelinated ? "🟡 soma  🟠 nœud  🟦 internode"
                                     : "🟡 soma  ■ segment HH"
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 5)
                .padding(.bottom, 3)
        }
    }

    // MARK: - Generation

    private func attachAxon() {
        guard let t = target else { return }
        if p.myelinated {
            attachMyelinated(neuron: t.neuron, soma: t.soma)
        } else {
            attachUnmyelinated(neuron: t.neuron, soma: t.soma)
        }
        dismiss()
    }

    // ── Sans myéline ───────────────────────────────────────────────────────────

    private func attachUnmyelinated(neuron: HHNeuron, soma: Compartment) {
        let N  = nSegUnmyel
        let dx = p.totalLength / Double(N)
        let af = dx / p.diameter       // area-factor = L / d

        var comps: [Compartment] = []
        for i in 0..<N {
            comps.append(Compartment(
                name:        "axone[\(i+1)/\(N)]",
                capacitance: 1.0 * af,
                diameter:    p.diameter,
                length:      dx,
                channels: [
                    SodiumChannel  (gMax: 120.0 * af, reversal:  50.0),
                    PotassiumChannel(gMax:  36.0 * af, reversal: -77.0),
                    LeakChannel    (gMax:   0.3 * af, reversal: -54.4)
                ]
            ))
        }

        var newCouplings: [AxialCoupling] = []
        // Soma → axone[0] : longueur effective du soma = max(soma.length, dx)
        let somaL = max(soma.length, dx)

        // Correction d'aire asymétrique soma↔axone.
        // La formule symétrique g = 50 000/(L_i+L_j) donne la conductance densité
        // correcte pour le compartiment de plus petit diamètre (l'axone), mais
        // est (d_axone/d_soma)² fois trop grande pour le soma.
        // G_abs [µS] = g_axone × A_sphère_axone = g_axone × π·d_axone²·1e-8 cm²
        // g_soma = G_abs / A_sphère_soma = g_axone × (d_axone/d_soma)²
        let gAxonEnd = 50_000.0 / (somaL + dx)
        let dRatio   = p.diameter / max(soma.diameter, 0.1)    // d_axone / d_soma
        let gSomaEnd = gAxonEnd * dRatio * dRatio              // ≤ gAxonEnd

        newCouplings.append(AxialCoupling(
            between: soma.id, and: comps[0].id,
            conductance: gSomaEnd,       // densité pour le soma (compartmentA)
            conductanceFarEnd: gAxonEnd  // densité pour l'axone[0] (compartmentB)
        ))
        // Chaîne axonale
        let gChain = 50_000.0 / (dx + dx)
        for i in 0..<(N - 1) {
            newCouplings.append(AxialCoupling(
                between: comps[i].id, and: comps[i + 1].id,
                conductance: gChain
            ))
        }

        applyToNeuron(id: neuron.id, comps: comps, couplings: newCouplings)
    }

    // ── Myélinisé ─────────────────────────────────────────────────────────────

    private func attachMyelinated(neuron: HHNeuron, soma: Compartment) {
        let afNode = p.nodeLength      / p.diameter
        let afInt  = p.internodeLength / p.diameter
        let cmMyelin = 0.005
        let gLMyelin = 0.005

        var comps: [Compartment] = []
        for i in 0..<nNodesMyel {
            comps.append(Compartment(
                name:        "nœud[\(i+1)]",
                capacitance: 1.0 * afNode,
                diameter:    p.diameter,
                length:      p.nodeLength,
                channels: [
                    SodiumChannel  (gMax: 120.0 * afNode, reversal:  50.0),
                    PotassiumChannel(gMax:  36.0 * afNode, reversal: -77.0),
                    LeakChannel    (gMax:   0.3  * afNode, reversal: -54.4)
                ]
            ))
            if i < nInternodesMyel {
                comps.append(Compartment(
                    name:        "internode[\(i+1)]",
                    capacitance: cmMyelin * afInt,
                    diameter:    p.diameter,
                    length:      p.internodeLength,
                    channels: [
                        LeakChannel(gMax: gLMyelin * afInt, reversal: -70.0)
                    ]
                ))
            }
        }

        var newCouplings: [AxialCoupling] = []
        // Soma → premier nœud (même correction asymétrique que l'axone non-myélinisé)
        let somaL = max(soma.length, p.nodeLength)
        let gNodeEnd  = 50_000.0 / (somaL + p.nodeLength)
        let dRatioM   = p.diameter / max(soma.diameter, 0.1)
        let gSomaEndM = gNodeEnd * dRatioM * dRatioM
        newCouplings.append(AxialCoupling(
            between: soma.id, and: comps[0].id,
            conductance: gSomaEndM,      // densité pour le soma
            conductanceFarEnd: gNodeEnd  // densité pour le nœud[0]
        ))
        // Chaîne nœud/internode
        for i in 0..<(comps.count - 1) {
            let g = 50_000.0 / (comps[i].length + comps[i + 1].length)
            newCouplings.append(AxialCoupling(
                between: comps[i].id, and: comps[i + 1].id,
                conductance: g
            ))
        }

        applyToNeuron(id: neuron.id, comps: comps, couplings: newCouplings)
    }

    // ── Injection dans le neurone existant ────────────────────────────────────

    private func applyToNeuron(id: UUID,
                               comps: [Compartment],
                               couplings: [AxialCoupling]) {
        vm.network.updateNeuron(id: id) { n in
            if replaceExisting && n.compartments.count > 1 {
                let somaID = n.somaCompartmentID
                n.compartments.removeAll(where: { $0.id != somaID })
                n.axialCouplings.removeAll()
            }
            for c in comps    { n.compartments.append(c) }
            for c in couplings { n.axialCouplings.append(c) }
        }
        vm.network.notifyStructuralChange()
        vm.rebuildSimulatorPublic()
    }
}
