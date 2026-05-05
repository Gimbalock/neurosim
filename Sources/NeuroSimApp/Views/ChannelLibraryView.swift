//
//  ChannelLibraryView.swift
//  NeuroSimApp
//
//  Two views in one file because they are tightly coupled:
//
//  ChannelLibrarySheet — presented as a sheet from the inspector's "+" button.
//    Lists built-in and custom channels; tapping one adds it to the current
//    compartment and closes the sheet.
//
//  CustomChannelEditorView — presented as a second sheet from inside
//    ChannelLibrarySheet (or directly from "New custom…" in the menu).
//    Edits a CustomChannelDefinition draft with live x∞(V) and τ(V) previews.
//    Saves to ChannelLibrary on confirm; optionally adds to a compartment.
//

import SwiftUI
import Charts
import NeuroSimCore

// MARK: - Palette (shared between both views)

private let kGateColors: [Color] = [.blue, .orange, .green, .red, .purple]

// MARK: - ChannelLibrarySheet

struct ChannelLibrarySheet: View {
    @EnvironmentObject var vm: SimulationViewModel
    @ObservedObject private var library = ChannelLibrary.shared
    @Environment(\.dismiss) private var dismiss

    let compartmentID: UUID
    let neuronID: UUID

    @State private var editorDraft: CustomChannelDefinition? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Channel Library")
                    .font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Built-in channels ────────────────────────────────
                    sectionHeader("Built-in")
                    ForEach(ChannelKind.allCases) { kind in
                        builtInRow(kind)
                    }

                    // ── Custom (library) ─────────────────────────────────
                    HStack {
                        sectionHeader("Custom")
                        Spacer()
                        Button {
                            editorDraft = CustomChannelDefinition()
                        } label: {
                            Label("New…", systemImage: "plus.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                    }

                    if library.channels.isEmpty {
                        Text("No custom channels yet. Click \"New…\" to create one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    } else {
                        ForEach(library.channels) { def in
                            customRow(def)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 440)
        .sheet(item: $editorDraft) { draft in
            CustomChannelEditorView(
                draft: draft,
                onConfirm: { saved in
                    library.upsert(saved)
                    vm.addCustomChannel(saved,
                                        toCompartment: compartmentID,
                                        in: neuronID)
                    dismiss()
                }
            )
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func builtInRow(_ kind: ChannelKind) -> some View {
        HStack {
            Label(kind.rawValue, systemImage: kind.systemImage)
                .font(.callout)
            Spacer()
            Button("Add") {
                vm.addChannel(kind, toCompartment: compartmentID, in: neuronID)
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func customRow(_ def: CustomChannelDefinition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.name).font(.callout.bold())
                Text("\(def.gates.count) gate\(def.gates.count == 1 ? "" : "s") · g_max \(String(format: "%.2f", def.gMax)) mS/cm²")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editorDraft = def
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button(role: .destructive) {
                library.delete(def)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete from library")

            Button("Add") {
                vm.addCustomChannel(def, toCompartment: compartmentID, in: neuronID)
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
    }
}

// MARK: - CustomChannelEditorView

struct CustomChannelEditorView: View {
    @Environment(\.dismiss) private var dismiss

    // The definition being edited. Starts as a copy; mutated locally until saved.
    @State private var draft: CustomChannelDefinition
    var onConfirm: (CustomChannelDefinition) -> Void

    // Which gate row is expanded
    @State private var expandedGate: UUID? = nil

    init(draft: CustomChannelDefinition,
         onConfirm: @escaping (CustomChannelDefinition) -> Void) {
        _draft = State(initialValue: draft)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(draft.name.isEmpty ? "New Channel" : draft.name)
                    .font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save to Library & Add") {
                    onConfirm(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.isEmpty || draft.gates.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                // ── Left: form ──────────────────────────────────────────
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        formSection
                        gatesSection
                    }
                    .padding(16)
                }
                .frame(width: 360)

                Divider()

                // ── Right: preview ─────────────────────────────────────
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        previewSection
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 750, minHeight: 520)
    }

    // MARK: - Form section

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Channel").font(.headline)

            HStack {
                Text("Name").frame(width: 80, alignment: .leading)
                TextField("e.g. Kv4.2", text: $draft.name)
            }

            NumericSlider(label: "g_max",
                          value: $draft.gMax,
                          range: 0...200,
                          format: "%.2f",
                          unit: "mS/cm²",
                          labelWidth: 80)

            NumericSlider(label: "E_rev",
                          value: $draft.reversal,
                          range: -100...140,
                          format: "%.1f",
                          unit: "mV",
                          labelWidth: 80)
        }
    }

    // MARK: - Gates section

    private var gatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gates").font(.headline)
                Spacer()
                Button {
                    let g = GateDef(name: defaultGateName())
                    draft.gates.append(g)
                    expandedGate = g.id
                } label: {
                    Label("Add gate", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

            if draft.gates.isEmpty {
                Text("No gates — channel acts as a pure conductance (leak).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    onDelete: {
                        draft.gates.remove(at: i)
                    }
                )
            }
        }
    }

    private func defaultGateName() -> String {
        let used = Set(draft.gates.map(\.name))
        let candidates = ["m", "h", "n", "p", "q", "r", "s"]
        return candidates.first { !used.contains($0) } ?? "x\(draft.gates.count)"
    }

    // MARK: - Preview section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview").font(.headline)

            if draft.gates.isEmpty {
                Text("Add at least one gate to see curves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                curveChart(title: "x∞(V)",
                           yLabel: "Open probability",
                           yRange: 0...1,
                           valueFor: { gate, v in
                    guard abs(gate.slope) > 1e-12 else { return v < gate.vHalf ? 0 : 1 }
                    return 1.0 / (1.0 + exp(-(v - gate.vHalf) / gate.slope))
                })

                curveChart(title: "τ(V)",
                           yLabel: "Time constant (ms)",
                           yRange: nil,
                           valueFor: { gate, v in
                    let sigma = max(gate.tauWidth, 1e-6)
                    let u = (v - gate.vPeak) / sigma
                    return gate.tauMin + (gate.tauMax - gate.tauMin) * exp(-0.5 * u * u)
                })
            }
        }
    }

    private func curveChart(title: String,
                             yLabel: String,
                             yRange: ClosedRange<Double>?,
                             valueFor: (GateDef, Double) -> Double) -> some View {
        let vValues = stride(from: -100.0, through: 40.0, by: 1.0).map { $0 }

        struct Point: Identifiable {
            let id: String
            let v: Double
            let y: Double
            let gate: String
        }

        var pts: [Point] = []
        for (i, gate) in draft.gates.enumerated() {
            let label = "\(gate.name) (×\(gate.power))"
            for v in vValues {
                pts.append(Point(id: "\(i)-\(v)", v: v, y: valueFor(gate, v), gate: label))
            }
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Chart(pts) { pt in
                LineMark(x: .value("V (mV)", pt.v),
                         y: .value(yLabel, pt.y))
                    .foregroundStyle(by: .value("Gate", pt.gate))
                    .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(domain: draft.gates.enumerated().map { (i, g) in
                "\(g.name) (×\(g.power))"
            }, range: draft.gates.indices.map { kGateColors[$0 % kGateColors.count] })
            .chartXAxisLabel("V (mV)")
            .chartYAxisLabel(yLabel)
            .if(yRange != nil) { $0.chartYScale(domain: yRange!) }
            .frame(height: 160)
        }
    }
}

// MARK: - GateEditorRow

private struct GateEditorRow: View {
    @Binding var gate: GateDef
    let color: Color
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                    Text(gate.name.isEmpty ? "(unnamed)" : gate.name)
                        .font(.callout.bold())
                    Text("pow=\(gate.power)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("V½=\(String(format: "%.0f", gate.vHalf))mV")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        HStack {
                            Text("Name").font(.caption).frame(width: 40, alignment: .leading)
                            TextField("m", text: $gate.name)
                                .frame(width: 60)
                        }
                        HStack {
                            Text("Power").font(.caption).frame(width: 40, alignment: .leading)
                            Stepper("\(gate.power)", value: $gate.power, in: 1...8)
                                .fixedSize()
                        }
                    }

                    Text("Activation x∞(V)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    NumericSlider(label: "V½",
                                  value: $gate.vHalf,
                                  range: -100...40,
                                  format: "%.1f",
                                  unit: "mV",
                                  labelWidth: 60)
                    NumericSlider(label: "Slope",
                                  value: $gate.slope,
                                  range: -30...30,
                                  step: 0.5,
                                  format: "%.1f",
                                  unit: "mV",
                                  labelWidth: 60)

                    Text("Time constant τ(V)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    NumericSlider(label: "τ_min",
                                  value: $gate.tauMin,
                                  range: 0.01...50,
                                  format: "%.2f",
                                  unit: "ms",
                                  labelWidth: 60)
                    NumericSlider(label: "τ_max",
                                  value: $gate.tauMax,
                                  range: 0.01...200,
                                  format: "%.2f",
                                  unit: "ms",
                                  labelWidth: 60)
                    NumericSlider(label: "V_peak",
                                  value: $gate.vPeak,
                                  range: -100...40,
                                  format: "%.1f",
                                  unit: "mV",
                                  labelWidth: 60)
                    NumericSlider(label: "Width",
                                  value: $gate.tauWidth,
                                  range: 1...100,
                                  format: "%.1f",
                                  unit: "mV",
                                  labelWidth: 60)
                }
                .padding(10)
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

// MARK: - Helpers

extension View {
    @ViewBuilder
    fileprivate func `if`<Content: View>(_ condition: Bool,
                                          transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
