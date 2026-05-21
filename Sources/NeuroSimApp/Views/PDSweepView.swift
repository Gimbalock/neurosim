//
//  PDSweepView.swift
//  NeuroSimApp
//
//  UI for the PD parameter grid sweep.
//
//  Layout:
//    ┌────────────────┬─────────────────────────────────────────────────────┐
//    │  Sidebar       │  Results table (sorted best-first)                  │
//    │  · grid info   │  Score │ CaS v½ │ SK Kd │ Ih │ Bursts │ AP │ T   │
//    │  · progress    ├─────────────────────────────────────────────────────┤
//    │  · best params │  …rows…                                             │
//    │  · apply best  │                                                     │
//    └────────────────┴─────────────────────────────────────────────────────┘
//

import SwiftUI
import NeuroSimCore

struct PDSweepView: View {
    @EnvironmentObject var vm: SimulationViewModel
    @StateObject private var runner = PDSweepRunner()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, maxWidth: 250)
                .background(.background.secondary)

            resultsPanel
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Text("PD Sweep")
                    .font(.title3.bold())
                    .padding(.top, 4)

                // Grid summary
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        gridRow("CaS v½",
                                detail: "\(PDSweepRunner.casVHalfGrid.first.map { Int($0) } ?? -38)…\(PDSweepRunner.casVHalfGrid.last.map { Int($0) } ?? -22) mV",
                                icon: "waveform")
                        gridRow("SK Kd",
                                detail: "10…30 µM (5 pts)",
                                icon: "drop.fill")
                        gridRow("Ih gMax",
                                detail: "0.8…2.5 mS/cm² (5 pts)",
                                icon: "bolt.fill")
                        Divider()
                        Text("\(PDSweepRunner.gridSize) simulations × 3 s")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("Grille", systemImage: "square.grid.3x3.fill")
                        .font(.caption.bold())
                }

                // Run / Stop
                Button {
                    runner.isRunning ? runner.stop() : runner.start()
                } label: {
                    Label(runner.isRunning ? "Arrêter" : "Démarrer le sweep",
                          systemImage: runner.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(runner.isRunning ? .red : .accentColor)
                .disabled(vm.network.neurons.isEmpty)

                // Progress
                if runner.totalEvals > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: runner.progress)
                            .progressViewStyle(.linear)
                        Text(runner.status)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(String(format: "%d / %d",
                                    runner.doneEvals, runner.totalEvals))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                // Best result action
                if let best = runner.results.first, best.score > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Meilleur résultat", systemImage: "star.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.yellow)

                        bestParamRow("CaS v½", value: best.casVHalfStr)
                        bestParamRow("SK Kd",   value: best.skKdStr)
                        bestParamRow("Ih gMax", value: "\(best.ihGMaxStr) mS/cm²")
                        bestParamRow("Bursts",  value: "\(best.burstCount)")
                        bestParamRow("AP/burst",value: best.meanAPsStr)
                        bestParamRow("Période", value: best.periodStr)

                        HStack(spacing: 6) {
                            Button("Appliquer") {
                                runner.apply(result: best, vm: vm)
                            }
                            .buttonStyle(.bordered)
                            .disabled(runner.isRunning)

                            Button("Appliquer + Lancer") {
                                runner.apply(result: best, vm: vm)
                                vm.play()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(runner.isRunning)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Results panel

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            if runner.results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(runner.results.enumerated()), id: \.element.id) { idx, r in
                            resultRow(r, rank: idx + 1)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            colLabel("#",         width: 28,  align: .trailing)
            colLabel("Score",     width: 58,  align: .trailing)
            colLabel("CaS v½",   width: 72,  align: .trailing)
            colLabel("SK Kd",    width: 65,  align: .trailing)
            colLabel("Ih gMax",  width: 65,  align: .trailing)
            colLabel("Bursts",   width: 55,  align: .trailing)
            colLabel("AP/burst", width: 68,  align: .trailing)
            colLabel("Période",  width: 75,  align: .trailing)
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.tertiary)
    }

    @ViewBuilder
    private func resultRow(_ r: PDSweepResult, rank: Int) -> some View {
        let isGood = r.score > 15
        let isFair = r.score > 7

        HStack(spacing: 0) {
            colValue("\(rank)",      width: 28,  align: .trailing)
                .foregroundStyle(isGood ? Color.green : isFair ? Color.orange : .secondary)
            colValue(r.scoreStr,     width: 58,  align: .trailing)
                .fontWeight(isGood ? .semibold : .regular)
            colValue(r.casVHalfStr,  width: 72,  align: .trailing)
            colValue(r.skKdStr,      width: 65,  align: .trailing)
            colValue(r.ihGMaxStr,    width: 65,  align: .trailing)
            colValue("\(r.burstCount)", width: 55, align: .trailing)
            colValue(r.meanAPsStr,   width: 68,  align: .trailing)
            colValue(r.periodStr,    width: 75,  align: .trailing)
            Spacer()
            Button("Appliquer") {
                runner.apply(result: r, vm: vm)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(runner.isRunning)
            .padding(.trailing, 10)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isGood ? Color.green.opacity(0.06)
                    : isFair ? Color.orange.opacity(0.04)
                    : Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.xaxis.ascending")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Lancez le sweep pour explorer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("l'espace de paramètres du modèle PD")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(PDSweepRunner.gridSize) simulations de 3 s — résultats en temps réel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func gridRow(_ label: String, detail: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label + " :").foregroundStyle(.secondary)
            Text(detail).fontWeight(.medium)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func bestParamRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label + " :").foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func colLabel(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .frame(width: width, alignment: align)
    }

    @ViewBuilder
    private func colValue(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .frame(width: width, alignment: align)
    }
}
