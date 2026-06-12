//
//  PropagationView.swift
//  NeuroSimApp
//
//  V(x, t) — visualisation de la propagation du potentiel d'action le long d'un axone
//
//  Layout
//  ──────
//  ┌──────────────────────────────────────────────────────────┐
//  │  Sélecteur d'axone       [neuron picker]                 │
//  ├─────────────────────────────┬────────────────────────────┤
//  │  V(x) — snapshot courant    │  Légende couleur            │
//  │  (ligne blanche sur fond    │  (plasma colormap)          │
//  │   noir, axes mV / µm)       │                             │
//  ├─────────────────────────────┴────────────────────────────┤
//  │  Kymographe V(x, t)  — image plasma (x=position,        │
//  │  y=temps, couleur=tension)                               │
//  └──────────────────────────────────────────────────────────┘
//
//  Performance
//  ───────────
//  • Le kymographe est rendu en CGImage (pixel RGBA) — O(pixels), pas
//    O(rectangles). Aucun Path fill par frame.
//  • `axonProfiles` est @Published dans SimulationViewModel ; la vue
//    ne se réabonne qu'aux changements de ce tableau (30 fps max).
//

import SwiftUI
import AppKit

// ────────────────────────────────────────────────────────────────────────────
// MARK: - PropagationView
// ────────────────────────────────────────────────────────────────────────────

struct PropagationView: View {
    @EnvironmentObject var vm: SimulationViewModel

    @State private var selectedNeuronID: UUID? = nil

    // ── current profile ──────────────────────────────────────────────────────
    private var profile: SimulationViewModel.AxonProfile? {
        guard let id = selectedNeuronID else { return vm.axonProfiles.first }
        return vm.axonProfiles.first { $0.neuronID == id }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Neuron selector ──────────────────────────────────────────────
            if vm.axonProfiles.count > 1 {
                neuronPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.background.secondary)
                Divider()
            }

            if vm.axonProfiles.isEmpty {
                emptyState
            } else if let prof = profile {
                VSplitView {
                    // Top panel: V(x) live snapshot + colour legend
                    HStack(alignment: .top, spacing: 0) {
                        VxSnapshotView(profile: prof)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                        colorLegend
                            .frame(width: 56)
                            .frame(maxHeight: .infinity)
                            .background(Color(white: 0.05))
                    }
                    .frame(minHeight: 80)

                    // Bottom panel: kymograph (space-time plot)
                    KymographView(profile: prof)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(Color.black)
                }
            }
        }
        .onChange(of: vm.axonProfiles.count) {
            // Auto-select first profile when axon is built
            if selectedNeuronID == nil || !vm.axonProfiles.contains(where: { $0.neuronID == selectedNeuronID }) {
                selectedNeuronID = vm.axonProfiles.first?.neuronID
            }
        }
    }

    // MARK: - Neuron picker

    private var neuronPicker: some View {
        Picker("Axone :", selection: Binding(
            get: { selectedNeuronID ?? vm.axonProfiles.first?.neuronID },
            set: { selectedNeuronID = $0 }
        )) {
            ForEach(vm.axonProfiles) { prof in
                Text(prof.neuronName).tag(Optional(prof.neuronID))
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Aucun axone multi-compartiment détecté")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Utilisez le constructeur d'axone (palette) pour créer\nun axone avec couplages axiaux.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Plasma color legend

    private var colorLegend: some View {
        VStack(spacing: 0) {
            Text("+50")
                .font(.system(size: 9, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 6)
            // Gradient bar
            LinearGradient(
                gradient: Gradient(colors: plasmaSwatchColors()),
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(width: 14)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                VStack {
                    Spacer()
                    Text("0")
                        .font(.system(size: 9, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Spacer()
                    Text("‑65")
                        .font(.system(size: 9, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Spacer()
                }
                .padding(.trailing, 2)
            }
            Text("‑90")
                .font(.system(size: 9, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 6)
            Text("mV")
                .font(.system(size: 8, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 4)
        }
    }

    /// 10 representative swatch colors spanning the plasma map
    private func plasmaSwatchColors() -> [Color] {
        stride(from: 0.0, through: 1.0, by: 0.1).map { t in
            let (r, g, b) = plasmaRGB(t)
            return Color(red: r, green: g, blue: b)
        }
    }
}

// ────────────────────────────────────────────────────────────────────────────
// MARK: - V(x) live snapshot
// ────────────────────────────────────────────────────────────────────────────

private struct VxSnapshotView: View {
    let profile: SimulationViewModel.AxonProfile

    private let vMin: Double = -90
    private let vMax: Double =  60
    private let hPad: Double = 40
    private let vPad: Double = 16

    // Most-recent slice
    private var latest: SimulationViewModel.PropagationSlice? { profile.history.last }

    var body: some View {
        Canvas { ctx, size in
            guard let slice = latest, !slice.voltages.isEmpty else {
                drawNoData(ctx: ctx, size: size)
                return
            }
            drawAxes(ctx: ctx, size: size)
            drawCurve(ctx: ctx, size: size, slice: slice)
        }
        .overlay(alignment: .topLeading) {
            if let t = latest?.time {
                Text(String(format: "t = %.1f ms", t))
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, CGFloat(hPad) + 4)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: – helpers

    private func plotRect(size: CGSize) -> CGRect {
        CGRect(x: hPad, y: vPad,
               width: size.width - hPad - 8,
               height: size.height - vPad * 2)
    }

    private func drawNoData(ctx: GraphicsContext, size: CGSize) {
        let txt = ctx.resolve(Text("En attente de données…")
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(Color.white.opacity(0.35)))
        ctx.draw(txt, at: CGPoint(x: size.width/2, y: size.height/2))
    }

    private func drawAxes(ctx: GraphicsContext, size: CGSize) {
        let r = plotRect(size: size)
        var path = Path()
        // Y axis
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        // X axis (at V = vMin reference)
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.5)

        // Y ticks: -90, -65, 0, +50 mV
        let tickV: [Double] = [-90, -65, 0, 50]
        for v in tickV {
            let y = yPx(v: v, rect: r)
            var tp = Path()
            tp.move(to: CGPoint(x: r.minX - 3, y: y))
            tp.addLine(to: CGPoint(x: r.minX, y: y))
            ctx.stroke(tp, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
            let label = v >= 0 ? "+\(Int(v))" : "\(Int(v))"
            ctx.draw(
                Text(label).font(.system(size: 8, weight: .light)).foregroundStyle(Color.white.opacity(0.5)),
                at: CGPoint(x: r.minX - 18, y: y)
            )
        }

        // X axis label (position)
        let xTicks = 5
        let totalLen = profile.positions.last ?? 1.0
        for i in 0...xTicks {
            let frac = Double(i) / Double(xTicks)
            let x = r.minX + frac * r.width
            var tp = Path()
            tp.move(to: CGPoint(x: x, y: r.maxY))
            tp.addLine(to: CGPoint(x: x, y: r.maxY + 3))
            ctx.stroke(tp, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
            let µm = Int(frac * totalLen)
            ctx.draw(
                Text("\(µm)").font(.system(size: 8, weight: .light)).foregroundStyle(Color.white.opacity(0.5)),
                at: CGPoint(x: x, y: r.maxY + 9)
            )
        }

        // Axis labels
        ctx.draw(
            Text("mV").font(.system(size: 9, weight: .light)).foregroundStyle(Color.white.opacity(0.45)),
            at: CGPoint(x: r.minX - 26, y: r.midY)
        )
        ctx.draw(
            Text("µm").font(.system(size: 9, weight: .light)).foregroundStyle(Color.white.opacity(0.45)),
            at: CGPoint(x: r.maxX + 6, y: r.maxY + 9)
        )
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize, slice: SimulationViewModel.PropagationSlice) {
        let r = plotRect(size: size)
        let vs = slice.voltages
        let n  = vs.count
        guard n > 1 else { return }

        var path = Path()
        for i in 0..<n {
            let x = r.minX + CGFloat(profile.positions[i] / (profile.positions.last ?? 1.0)) * r.width
            let y = yPx(v: vs[i], rect: r)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else       { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(.white), lineWidth: 1.5)

        // Overlay colored dots per compartment (voltage color)
        for i in 0..<n {
            let x = r.minX + CGFloat(profile.positions[i] / (profile.positions.last ?? 1.0)) * r.width
            let y = yPx(v: vs[i], rect: r)
            let t = (vs[i] - vMin) / (vMax - vMin)
            let (rr, gg, bb) = plasmaRGB(max(0, min(1, t)))
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                with: .color(red: rr, green: gg, blue: bb)
            )
        }
    }

    private func yPx(v: Double, rect: CGRect) -> CGFloat {
        let frac = (v - vMin) / (vMax - vMin)
        return rect.maxY - CGFloat(frac) * rect.height
    }
}

// ────────────────────────────────────────────────────────────────────────────
// MARK: - Kymograph
// ────────────────────────────────────────────────────────────────────────────

private struct KymographView: View {
    let profile: SimulationViewModel.AxonProfile

    private let vMin: Double = -90
    private let vMax: Double =  60
    private let hPad: Double = 40   // left margin for time axis
    private let vPad: Double = 24   // bottom margin for position axis

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let r = CGRect(x: hPad, y: 4,
                               width: size.width - hPad - 8,
                               height: size.height - vPad - 4)
                if let img = buildKymographImage(profile: profile,
                                                 width: Int(r.width),
                                                 height: Int(r.height)) {
                    ctx.draw(Image(decorative: img, scale: 1.0, orientation: .up),
                             in: r)
                }
                drawAxes(ctx: ctx, size: size, plotRect: r)
            }
        }
    }

    // MARK: – CGImage renderer

    private func buildKymographImage(profile: SimulationViewModel.AxonProfile,
                                     width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, !profile.history.isEmpty else { return nil }
        let nSlices = profile.history.count
        let nComp   = profile.compartmentIDs.count
        guard nComp > 1 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for row in 0..<height {
            // row 0 = top = most-recent time, row height-1 = bottom = oldest time
            let si = (nSlices - 1) - Int(Double(row) / Double(height - 1) * Double(nSlices - 1))
            let sliceIdx = max(0, min(nSlices - 1, si))
            let vs = profile.history[sliceIdx].voltages

            for col in 0..<width {
                let ci = Int(Double(col) / Double(width - 1) * Double(nComp - 1))
                let compIdx = max(0, min(nComp - 1, ci))
                let v = vs[compIdx]
                let t = (v - vMin) / (vMax - vMin)
                let (r, g, b) = plasmaRGB(max(0, min(1, t)))
                let base = (row * width + col) * 4
                pixels[base + 0] = UInt8(r * 255)
                pixels[base + 1] = UInt8(g * 255)
                pixels[base + 2] = UInt8(b * 255)
                pixels[base + 3] = 255
            }
        }

        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: – Axes

    private func drawAxes(ctx: GraphicsContext, size: CGSize, plotRect r: CGRect) {
        var border = Path()
        border.addRect(r)
        ctx.stroke(border, with: .color(.white.opacity(0.25)), lineWidth: 0.5)

        // Y = time axis (newest at top)
        let nSlices = profile.history.count
        if nSlices > 1 {
            let tOld = profile.history.first!.time
            let tNew = profile.history.last!.time
            let tTicks = 5
            for i in 0...tTicks {
                let frac = Double(i) / Double(tTicks)
                let y    = r.minY + CGFloat(frac) * r.height
                var tp   = Path()
                tp.move(to: CGPoint(x: r.minX - 3, y: y))
                tp.addLine(to: CGPoint(x: r.minX, y: y))
                ctx.stroke(tp, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                // frac=0 → tNew, frac=1 → tOld
                let tVal = tNew + frac * (tOld - tNew)
                ctx.draw(
                    Text(String(format: "%.0f", tVal))
                        .font(.system(size: 8, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.5)),
                    at: CGPoint(x: r.minX - 22, y: y)
                )
            }
        }
        ctx.draw(
            Text("ms").font(.system(size: 9, weight: .light)).foregroundStyle(Color.white.opacity(0.4)),
            at: CGPoint(x: r.minX - 26, y: r.minY - 8)
        )

        // X = position axis
        let totalLen = profile.positions.last ?? 1.0
        let xTicks = 5
        for i in 0...xTicks {
            let frac = Double(i) / Double(xTicks)
            let x    = r.minX + CGFloat(frac) * r.width
            var tp   = Path()
            tp.move(to: CGPoint(x: x, y: r.maxY))
            tp.addLine(to: CGPoint(x: x, y: r.maxY + 3))
            ctx.stroke(tp, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            let µm = Int(frac * totalLen)
            ctx.draw(
                Text("\(µm)").font(.system(size: 8, weight: .light)).foregroundStyle(Color.white.opacity(0.5)),
                at: CGPoint(x: x, y: r.maxY + 10)
            )
        }
        ctx.draw(
            Text("µm").font(.system(size: 9, weight: .light)).foregroundStyle(Color.white.opacity(0.4)),
            at: CGPoint(x: r.maxX + 10, y: r.maxY + 10)
        )
    }
}

// ────────────────────────────────────────────────────────────────────────────
// MARK: - Plasma colormap  (−90 mV = dark purple → 0 mV = orange → +60 mV = yellow)
// ────────────────────────────────────────────────────────────────────────────
//
// 8-stop approximation of matplotlib's 'plasma' colormap.
// t ∈ [0, 1]  (0 = vMin = -90 mV, 1 = vMax = +60 mV)
//
internal func plasmaRGB(_ t: Double) -> (Double, Double, Double) {
    // Control points: [t, R, G, B]
    let stops: [(Double, Double, Double, Double)] = [
        (0.00, 0.050, 0.030, 0.527),   // dark indigo
        (0.13, 0.232, 0.020, 0.611),   // violet
        (0.27, 0.406, 0.034, 0.616),   // purple
        (0.40, 0.563, 0.050, 0.580),   // magenta
        (0.53, 0.707, 0.118, 0.494),   // pink-red
        (0.67, 0.843, 0.252, 0.349),   // orange-red
        (0.80, 0.943, 0.431, 0.150),   // orange
        (0.93, 0.988, 0.651, 0.055),   // golden yellow
        (1.00, 0.940, 0.975, 0.131),   // bright yellow
    ]

    // Binary search lower bound
    var lo = 0, hi = stops.count - 1
    if t <= stops[lo].0 { return (stops[lo].1, stops[lo].2, stops[lo].3) }
    if t >= stops[hi].0 { return (stops[hi].1, stops[hi].2, stops[hi].3) }
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if stops[mid].0 <= t { lo = mid } else { hi = mid }
    }
    let (t0, r0, g0, b0) = stops[lo]
    let (t1, r1, g1, b1) = stops[hi]
    let s = (t - t0) / (t1 - t0)
    return (r0 + s*(r1-r0), g0 + s*(g1-g0), b0 + s*(b1-b0))
}
