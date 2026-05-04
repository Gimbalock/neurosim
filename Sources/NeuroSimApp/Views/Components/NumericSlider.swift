//
//  NumericSlider.swift
//  NeuroSimApp
//
//  Reusable numeric input combining a Slider and an editable text field.
//
//  Behaviour
//  ─────────
//  - Each keystroke that produces a valid number updates the bound value
//    live (clamped to range). This keeps the slider in sync as you type.
//  - Partial entries that don't parse yet (e.g. "1." waiting for "1.5",
//    or just "-") stay in the field without disturbing the value.
//  - Pressing Return reformats the field to the canonical representation
//    and snaps to `step` if one is set.
//  - When the bound value changes from elsewhere (slider drag, programmatic
//    update), the field re-syncs unless the user's draft already represents
//    that exact value (within format precision).
//  - Both '.' and ',' are accepted as decimal separators (works for FR
//    keyboards).
//

import SwiftUI

struct NumericSlider: View {

    // MARK: - Inputs

    let label: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.2f"
    var unit: String? = nil
    var labelWidth: CGFloat? = nil
    var fieldWidth: CGFloat = 60
    /// Width of the unit suffix slot. Always reserved (even when `unit`
    /// is nil) so that fields line up vertically across rows.
    var unitWidth: CGFloat = 50

    // MARK: - State

    @State private var textInput: String = ""

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .frame(width: labelWidth, alignment: .leading)
            }

            slider

            TextField("", text: $textInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.caption, design: .monospaced))
                .frame(width: fieldWidth)
                .onSubmit { commit() }
                .onChange(of: textInput) { _, newText in
                    // Live-parse: as soon as the draft is a valid number,
                    // push it through the binding (clamped). If it doesn't
                    // parse yet — a lone "-", a trailing "." — leave value
                    // alone and let the user keep typing.
                    let normalized = newText.replacingOccurrences(of: ",", with: ".")
                    if let parsed = Double(normalized) {
                        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
                        if abs(clamped - value) > 1e-9 {
                            value = clamped
                        }
                    }
                }

            Text(unit ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: unitWidth, alignment: .leading)
        }
        .onAppear { textInput = formatted(value) }
        .onChange(of: value) { _, newValue in
            // Sync from external value changes (slider drag, programmatic),
            // but don't clobber the user's draft if it already represents
            // the same number — otherwise typing "5.50" would briefly turn
            // into "5.5" then back to "5.50" and the cursor would jump.
            if let parsed = Double(textInput.replacingOccurrences(of: ",", with: ".")),
               abs(parsed - newValue) < tolerance {
                return
            }
            textInput = formatted(newValue)
        }
    }

    // MARK: - Slider (with optional step)

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }

    // MARK: - Helpers

    /// Half of the smallest representable change at this format precision —
    /// used to decide whether to overwrite the user's draft.
    private var tolerance: Double {
        pow(10.0, -Double(fractionLength)) / 2
    }

    /// Best-effort parse of fraction-length from a `printf`-style format,
    /// e.g. `"%.3f"` → 3, `"%.0f"` → 0. Defaults to 2 if not found.
    private var fractionLength: Int {
        guard let dot = format.firstIndex(of: ".") else { return 2 }
        let tail = format[format.index(after: dot)...]
        let digits = tail.prefix(while: { $0.isNumber })
        return Int(digits) ?? 2
    }

    private func formatted(_ v: Double) -> String {
        String(format: format, v)
    }

    private func commit() {
        let normalized = textInput
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if let parsed = Double(normalized) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            if let step, step > 0 {
                let stepsFromMin = ((clamped - range.lowerBound) / step).rounded()
                value = range.lowerBound + stepsFromMin * step
            } else {
                value = clamped
            }
        }
        // Always reformat so the field shows the canonical value.
        textInput = formatted(value)
    }
}

#Preview {
    @Previewable @State var v: Double = 5.0
    return VStack(alignment: .leading, spacing: 12) {
        NumericSlider(label: "g_max",
                      value: $v,
                      range: 0...200,
                      format: "%.2f")
        NumericSlider(label: "Window",
                      value: .constant(200),
                      range: 50...2000,
                      step: 25,
                      format: "%.0f",
                      unit: "ms",
                      labelWidth: 90)
    }
    .padding()
    .frame(width: 380)
}
