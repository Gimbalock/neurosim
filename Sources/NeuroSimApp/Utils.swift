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
