// SynapticNoiseSheet.swift
// NeuroSimApp — Editor for Destexhe OU synaptic noise parameters.

import SwiftUI
import NeuroSimCore

struct SynapticNoiseSheet: View {
    @Binding var params: SynapticNoiseParams
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack {
                Image(systemName: "waveform.badge.plus").foregroundStyle(.orange)
                Text("Bruit synaptique (OU)").font(.headline)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Label("Supprimer", systemImage: "trash")
                }.buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // ── Excitatory ────────────────────────────────────────
                    GroupBox {
                        VStack(spacing: 10) {
                            NoiseSlider(label: "g̅ₑ moyen",  value: $params.geMean,
                                        range: 0...0.5,  unit: "mS/cm²")
                            NoiseSlider(label: "σₑ",        value: $params.geSigma,
                                        range: 0...0.1,  unit: "mS/cm²")
                            NoiseSlider(label: "τₑ",        value: $params.geTau,
                                        range: 0.1...50, unit: "ms")
                            NoiseSlider(label: "Eₑ",        value: $params.ee,
                                        range: -20...60, unit: "mV")
                        }
                    } label: {
                        Label("Excitatrice (AMPA)", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                    }

                    // ── Inhibitory ────────────────────────────────────────
                    GroupBox {
                        VStack(spacing: 10) {
                            NoiseSlider(label: "g̅ᵢ moyen",  value: $params.giMean,
                                        range: 0...0.5,  unit: "mS/cm²")
                            NoiseSlider(label: "σᵢ",        value: $params.giSigma,
                                        range: 0...0.1,  unit: "mS/cm²")
                            NoiseSlider(label: "τᵢ",        value: $params.giTau,
                                        range: 0.1...50, unit: "ms")
                            NoiseSlider(label: "Eᵢ",        value: $params.ei,
                                        range: (-90)...(-40), unit: "mV")
                        }
                    } label: {
                        Label("Inhibitrice (GABA-A)", systemImage: "minus.circle.fill")
                            .foregroundStyle(.orange)
                    }

                    // ── Seed ──────────────────────────────────────────────
                    HStack {
                        Text("Graine RNG").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        TextField("", value: Binding(
                            get: { Int(params.seed) },
                            set: { params.seed = UInt64(max(0, $0)) }
                        ), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 360, height: 520)
    }
}

// MARK: - Compact slider row

private struct NoiseSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 72, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%.4f", value))
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
        }
    }
}
