//
//  NumericSlider.swift
//  NeuroSimApp
//
//  Reusable numeric input combining a Slider and an editable text field.
//
//  Behaviour
//  ─────────
//  - Typing in the field is instantaneous — the bound value is only updated
//    on Return or when the field loses focus (no live-update-per-keystroke lag).
//  - Values typed in the field are NOT clamped to the slider range, so the
//    user can enter e.g. "2000 ms" even when the slider only goes to 500 ms.
//    (If a `step` is set, the value is snapped to the nearest step.)
//  - The slider itself is always displayed within its visual range; dragging
//    it does update the value live and syncs the field immediately.
//  - Both '.' and ',' are accepted as decimal separators (FR keyboards).
//

import SwiftUI

struct NumericSlider: View {

    // MARK: - Inputs

    var label: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.2f"
    var unit: String? = nil
    var labelWidth: CGFloat? = nil
    var fieldWidth: CGFloat = 60
    /// Width of the unit suffix slot. Always reserved so fields line up vertically.
    var unitWidth: CGFloat = 50
    /// When false the slider is hidden — only label + field + unit show.
    var showSlider: Bool = true

    // MARK: - State

    @State private var textInput: String = ""
    @FocusState private var isFocused: Bool

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .frame(width: labelWidth, alignment: .leading)
            }

            if showSlider { sliderView }

            TextField("", text: $textInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.caption, design: .monospaced))
                .frame(width: fieldWidth)
                .focused($isFocused)
                .onSubmit { commitText() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitText() }
                }

            Text(unit ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: unitWidth, alignment: .leading)
        }
        .onAppear { textInput = formatted(value) }
        .onChange(of: value) { _, newValue in
            // Only sync field from external changes when the user isn't typing.
            guard !isFocused else { return }
            textInput = formatted(newValue)
        }
    }

    // MARK: - Slider

    /// The slider is visually clamped to `range`; the underlying `value` may
    /// exceed the range when set via the text field.
    @ViewBuilder
    private var sliderView: some View {
        let sliderBinding = Binding<Double>(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { newVal in
                value = newVal
                if !isFocused { textInput = formatted(newVal) }
            }
        )
        if let step {
            Slider(value: sliderBinding, in: range, step: step)
        } else {
            Slider(value: sliderBinding, in: range)
        }
    }

    // MARK: - Commit

    /// Parse the text field and write `value` — no range clamping unless a
    /// `step` snapping is requested (keeps full numerical freedom for the user).
    private func commitText() {
        let normalized = textInput
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if let parsed = Double(normalized) {
            if let step, step > 0 {
                // Snap to nearest step within range
                let clamped = min(max(parsed, range.lowerBound), range.upperBound)
                let stepsFromMin = ((clamped - range.lowerBound) / step).rounded()
                value = range.lowerBound + stepsFromMin * step
            } else {
                // Accept any value — no clamping to slider range
                value = parsed
            }
        }
        textInput = formatted(value)
    }

    // MARK: - Formatting

    private func formatted(_ v: Double) -> String {
        String(format: format, v)
    }
}

#Preview {
    @Previewable @State var v: Double = 5.0
    return VStack(alignment: .leading, spacing: 12) {
        NumericSlider(label: "g_max",
                      value: $v,
                      range: 0...200,
                      format: "%.2f")
        NumericSlider(label: "Duration",
                      value: .constant(200),
                      range: 50...500,
                      format: "%.0f",
                      unit: "ms",
                      labelWidth: 90)
    }
    .padding()
    .frame(width: 380)
}
