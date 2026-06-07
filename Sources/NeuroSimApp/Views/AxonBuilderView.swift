//
//  AxonBuilderView.swift
//  NeuroSimApp
//
//  Constructeur d'axone multi-compartiment.
//
//  Génère soit un axone uniforme sans myéline (N segments HH en chaîne),
//  soit un axone myélinisé avec des nœuds de Ranvier (HH) séparés par des
//  internodes passifs à faible capacitance.
//
//  ─── Physique des couplages axiaux ──────────────────────────────────────────
//
//  Le couplage axial entre deux compartiments adjacents i et j est calculé
//  avec le modèle demi-longueur (ρ_a = 100 Ω·cm) :
//
//      R_a  = ρ_a × (L_i/2 + L_j/2) / A_cross        [Ω]
//      G_a  = 1 / R_a                                   [mS]
//      g_ij = G_a / A_comp                              [mS/cm²]
//
//  où A_comp = π × d² × 1e-8 cm² (modèle sphère de NeuroSim).
//
//  En développant (avec L_i, L_j, d en µm) :
//
//      g_ij = 50 000 / (L_i + L_j)   [mS/cm²]
//
//  — formule indépendante du diamètre une fois normalisée par l'aire sphère.
//
//  ─── Correction d'aire pour les compartiments allongés ──────────────────────
//
//  NeuroSim calcule l'aire comme une sphère (π·d²·1e-8 cm²), ce qui est exact
//  seulement si d = L.  Pour les compartiments où L ≠ d, on compense :
//
//      C_m_param  = C_m_vrai  × (L / d)
//      g_param    = g_vrai    × (L / d)
//
//  Cela garantit que la capacitance totale et la conductance totale du
//  compartiment correspondent à la vraie surface latérale π·d·L·1e-8 cm².
//  Les cinétiques membranaires (dV/dt = (-I_ionique + I_inj) / C_m) restent
//  correctes car numérateur et dénominateur sont scalés par le même facteur.
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
    // Axial resistivity (Ω·cm)  — fixed, could be exposed later
    var rhoA:            Double = 100.0
}

// MARK: - View

struct AxonBuilderView: View {

    @EnvironmentObject var vm: SimulationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var p = AxonParams()

    // MARK: Computed geometry

    private var segDx: Double { p.diameter }   // for unmyelinated: segment spacing = d

    private var nSegUnmyel: Int {
        max(2, Int((p.totalLength / segDx).rounded()))
    }

    private var nInternodesMyel: Int {
        max(1, Int((p.totalLength / (p.nodeLength + p.internodeLength)).rounded()))
    }
    private var nNodesMyel: Int   { nInternodesMyel + 1 }
    private var nCompsMyel: Int   { nNodesMyel + nInternodesMyel }

    private var nCompartments: Int {
        p.myelinated ? nCompsMyel : nSegUnmyel
    }

    // Space constant λ (µm) — unmyelinated
    private var lambda_um: Double {
        // λ = sqrt( d_cm / (4 × ρ_a × g_L_S) ) × 1e4   [µm]
        let d_cm = p.diameter * 1e-4
        let gL_S = 0.3e-3          // S/cm²  (HH leak)
        return sqrt(d_cm / (4 * p.rhoA * gL_S)) * 1e4
    }

    // Very rough Rushton conduction velocity estimate (m/s)
    private var vConduction: Double {
        if p.myelinated {
            // v ≈ 6 × (fibre diameter µm) → m/s;  fibre ≈ d / 0.7
            return 6.0 * (p.diameter / 0.7) / 1000.0
        } else {
            // v ≈ k × √d, k ≈ 0.55 m·s⁻¹·µm^{-0.5}
            return 0.55 * sqrt(p.diameter)
        }
    }

    private var tooMany: Bool { nCompartments > 500 }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ─────────────────────────────────────────────────────────
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

                    // ── Géométrie ───────────────────────────────────────────────
                    paramGroup("Géométrie") {
                        sliderRow("Longueur totale",   value: $p.totalLength,
                                  in: 50...10000, step: 50, fmt: "%.0f", unit: "µm")
                        sliderRow("Diamètre axonal",   value: $p.diameter,
                                  in: 0.5...20, step: 0.5, fmt: "%.1f", unit: "µm")
                    }

                    // ── Myéline ─────────────────────────────────────────────────
                    paramGroup("Myélinisation") {
                        Toggle("Axone myélinisé", isOn: $p.myelinated)
                            .toggleStyle(.switch)

                        if p.myelinated {
                            sliderRow("Long. internodale",  value: $p.internodeLength,
                                      in: 20...3000, step: 20,  fmt: "%.0f", unit: "µm")
                            sliderRow("Long. nœud de Ranvier", value: $p.nodeLength,
                                      in: 0.5...5, step: 0.5,   fmt: "%.1f", unit: "µm")
                        }
                    }

                    // ── Aperçu physique ─────────────────────────────────────────
                    paramGroup("Aperçu physique") {
                        physicsGrid()
                    }

                    // ── Diagramme ───────────────────────────────────────────────
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
                Button("Générer") {
                    generate()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .keyboardShortcut(.defaultAction)
                .disabled(tooMany)
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
                Text("Compartiments").font(.caption).foregroundStyle(.secondary)
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

    // Mini-schéma de l'axone
    @ViewBuilder
    private func axonDiagram() -> some View {
        Canvas { ctx, size in
            let midY = size.height / 2

            if p.myelinated {
                let nodeW: CGFloat = 7
                let nVisualNodes = min(nNodesMyel, 20)
                let nVisualInternodes = min(nInternodesMyel, nVisualNodes - 1)
                let totalNodeW = CGFloat(nVisualNodes) * nodeW
                let usableW = size.width - totalNodeW
                let intW = nVisualInternodes > 0
                    ? usableW / CGFloat(nVisualInternodes)
                    : usableW

                var x: CGFloat = 0
                let items = nVisualNodes + nVisualInternodes
                for i in 0..<items {
                    let isNode = (i % 2 == 0)
                    if isNode {
                        // Nœud — pleine hauteur, orange
                        let r = CGRect(x: x, y: midY - size.height * 0.38,
                                       width: nodeW, height: size.height * 0.76)
                        ctx.fill(Path(r), with: .color(.orange.opacity(0.9)))
                        x += nodeW
                    } else {
                        // Internode — large, bleuté + axone central gris
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
                // Points de suspension si trop de nœuds
                if nNodesMyel > 20 {
                    ctx.draw(Text("…").foregroundColor(.white).font(.system(size: 11)),
                             at: CGPoint(x: size.width - 8, y: midY))
                }
            } else {
                // Axone uniforme : segments alternés cyan/cyan-foncé
                let n = min(nSegUnmyel, 80)
                let w = size.width / CGFloat(max(n, 1))
                for i in 0..<n {
                    let x = CGFloat(i) * w
                    let r = CGRect(x: x + 0.5, y: midY - size.height * 0.32,
                                   width: w - 1, height: size.height * 0.64)
                    let alpha = i % 2 == 0 ? 0.55 : 0.75
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
            let label = p.myelinated
                ? "🟠 nœud  🟦 internode"
                : "■ segment HH"
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 5)
                .padding(.bottom, 3)
        }
    }

    // MARK: - Generation

    private func generate() {
        p.myelinated ? buildMyelinated() : buildUnmyelinated()
    }

    // ── Axone sans myéline ─────────────────────────────────────────────────────

    private func buildUnmyelinated() {
        let N  = nSegUnmyel
        let dx = p.totalLength / Double(N)   // longueur de chaque segment (µm)

        // Correction d'aire : pour un cylindre de diamètre d et longueur L,
        // l'aire vraie est π·d·L·1e-8 cm², mais NeuroSim utilise π·d²·1e-8 cm².
        // On corrige en multipliant les densités par (L / d).
        let af = dx / p.diameter    // area-factor = L/d

        var comps: [Compartment] = []
        for i in 0..<N {
            comps.append(Compartment(
                name:        i == 0 ? "axone[trigger]" : "axone[\(i+1)]",
                capacitance: 1.0 * af,
                diameter:    p.diameter,
                length:      dx,
                channels: [
                    SodiumChannel  (gMax:  120.0 * af, reversal:  50.0),
                    PotassiumChannel(gMax:  36.0 * af, reversal: -77.0),
                    LeakChannel    (gMax:   0.3 * af, reversal: -54.4)
                ]
            ))
        }

        buildNeuron(name: "Axone sans myéline (\(Int(p.totalLength)) µm)",
                    comps: comps, stimComp: comps[0])
    }

    // ── Axone myélinisé ────────────────────────────────────────────────────────
    //
    //  Séquence : nœud — internode — nœud — internode — … — nœud
    //
    //  Nœud de Ranvier :
    //    • Canaux HH standard (Na 120, K 36, Leak 0.3 mS/cm²)
    //    • C_m = 1.0 µF/cm² (membrane nue)
    //    • Correction d'aire : af_node = L_node / d
    //
    //  Internode :
    //    • Leak seul, très faible (myéline = isolant)
    //    • C_m_myeline = 0.005 µF/cm²  (≈ 200 couches de myéline)
    //    • g_L_myeline = 0.005 mS/cm²
    //    • Correction d'aire : af_int = L_int / d  (internode long >> d)

    private func buildMyelinated() {
        let afNode = p.nodeLength     / p.diameter   // area-factor nœud
        let afInt  = p.internodeLength / p.diameter  // area-factor internode

        let cmMyelin = 0.005    // µF/cm² — capacitance myéline vraie
        let gLMyelin = 0.005    // mS/cm² — conductance myéline vraie

        var comps: [Compartment] = []

        for i in 0..<nNodesMyel {
            // Nœud
            comps.append(Compartment(
                name:        "nœud[\(i+1)]",
                capacitance: 1.0 * afNode,
                diameter:    p.diameter,
                length:      p.nodeLength,
                channels: [
                    SodiumChannel  (gMax:  120.0 * afNode, reversal:  50.0),
                    PotassiumChannel(gMax:  36.0 * afNode, reversal: -77.0),
                    LeakChannel    (gMax:   0.3  * afNode, reversal: -54.4)
                ]
            ))
            // Internode (sauf après le dernier nœud)
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

        buildNeuron(name: "Axone myélinisé (\(nNodesMyel) nœuds, \(Int(p.internodeLength)) µm)",
                    comps: comps, stimComp: comps[0])
    }

    // ── Assemblage et injection dans le réseau ─────────────────────────────────

    private func buildNeuron(name: String,
                              comps: [Compartment],
                              stimComp: Compartment) {
        // Couplages axiaux : modèle demi-longueur, ρ_a = 100 Ω·cm
        //   g_ij = 50 000 / (L_i + L_j)   [mS/cm²]
        var couplings: [AxialCoupling] = []
        for i in 0..<(comps.count - 1) {
            let g = 50_000.0 / (comps[i].length + comps[i + 1].length)
            couplings.append(AxialCoupling(between: comps[i].id,
                                           and: comps[i + 1].id,
                                           conductance: g))
        }

        let neuron = HHNeuron(name: name,
                              compartments: comps,
                              couplings: couplings,
                              soma: comps[0].id)
        // Position arbitraire sur le canvas
        neuron.positionX = 300
        neuron.positionY = 300

        vm.network.addNeuron(neuron)

        // Stimulus déclencheur : impulsion courte et intense sur le premier compartiment
        vm.network.setStimulus(
            PulseStimulus(start: 5.0, duration: 0.5, amplitude: 500.0),
            onCompartment: stimComp.id
        )

        vm.rebuildSimulatorPublic()
    }
}
