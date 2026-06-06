// Utils.swift
// NeuroSimApp

import Foundation
import SwiftUI

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Shared heat colormap (blue → cyan → green → yellow → red)
// t ∈ [0, 1], where 0 = coldest (best / lowest error) and 1 = hottest.

func heatColor(_ t: Double) -> Color {
    let hue = (1.0 - t) * 0.67
    return Color(hue: hue, saturation: 1.0, brightness: t < 0.05 ? t * 20.0 : 1.0)
}

// MARK: - Phase-plane point extraction

/// Convert a voltage trace into (V, dV/dt) phase-plane points.
///
/// Uses **central differences** — `dV/dt[i] = (V[i+1] − V[i−1]) / (t[i+1] − t[i−1])` — which
/// halves the derivative noise compared to a forward difference and is placed at the centre
/// sample V[i].  The span `dt2 = t[i+1]−t[i−1]` must be > 0 and < 4 ms (two forward steps);
/// |dV/dt| must be < 5000 mV/ms to reject numerical noise.
func phasePlanePoints(
    from trace: [(t: Double, v: Double)]
) -> [(v: Double, dvdt: Double)] {
    guard trace.count >= 3 else { return [] }
    var pts: [(v: Double, dvdt: Double)] = []
    pts.reserveCapacity(trace.count - 2)
    for i in 1..<trace.count - 1 {
        let dt2 = trace[i+1].t - trace[i-1].t   // spans two steps
        guard dt2 > 0, dt2 < 4.0 else { continue }
        let dvdt = (trace[i+1].v - trace[i-1].v) / dt2
        guard abs(dvdt) < 5000 else { continue }
        pts.append((v: trace[i].v, dvdt: dvdt))  // V at the centre point
    }
    return pts
}

// MARK: - Shared V(t) comparison preview

/// A compact canvas that overlays a reference V(t) trace (blue) and a candidate
/// V(t) trace (orange) for live visual comparison during sweeps / optimisation.
/// Both traces are auto-scaled to a shared Y range.
struct TracePreviewCanvas: View {
    /// Reference trace — blue.
    var refPts: [(t: Double, v: Double)]
    /// Current candidate trace — orange.
    var simPts: [(t: Double, v: Double)]

    var body: some View {
        Canvas { ctx, size in
            let all = refPts + simPts
            guard all.count >= 2 else { return }

            var tMin = all[0].t,  tMax = all[0].t
            var vMin = all[0].v,  vMax = all[0].v
            for p in all {
                if p.t < tMin { tMin = p.t }
                if p.t > tMax { tMax = p.t }
                if p.v < vMin { vMin = p.v }
                if p.v > vMax { vMax = p.v }
            }
            let tSpan = max(tMax - tMin, 1e-6)
            let vSpan = max(vMax - vMin, 1e-6)

            // Map a (t, v) point to canvas coordinates.
            func xy(_ t: Double, _ v: Double) -> CGPoint {
                CGPoint(x: (t - tMin) / tSpan * size.width,
                        y: (1.0 - (v - vMin) / vSpan) * size.height)
            }

            // Draw one trace, striding to ≤ maxPts segments.
            func draw(_ pts: [(t: Double, v: Double)], color: Color, width: CGFloat) {
                guard pts.count >= 2 else { return }
                let maxPts = 600
                let st = max(1, pts.count / maxPts)
                var path = Path()
                var moved = false
                var i = 0
                while i < pts.count {
                    let p = xy(pts[i].t, pts[i].v)
                    if !moved { path.move(to: p); moved = true } else { path.addLine(to: p) }
                    i += st
                }
                // Always include the last point
                if pts.count % st != 0 {
                    path.addLine(to: xy(pts.last!.t, pts.last!.v))
                }
                ctx.stroke(path, with: .color(color), lineWidth: width)
            }

            draw(refPts, color: Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.85), width: 1.0)
            draw(simPts, color: Color(red: 1.00, green: 0.50, blue: 0.10).opacity(0.95), width: 1.0)
        }
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomTrailing) {
            // Tiny legend
            HStack(spacing: 4) {
                Capsule().fill(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 10, height: 2)
                Text("Réf")
                Capsule().fill(Color(red: 1.00, green: 0.50, blue: 0.10))
                    .frame(width: 10, height: 2)
                Text("Test")
            }
            .font(.system(size: 8))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.bottom, 3)
        }
    }
}
