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
/// dt must be > 0 and < 2 ms; |dV/dt| must be < 5000 mV/ms to filter noise.
func phasePlanePoints(
    from trace: [(t: Double, v: Double)]
) -> [(v: Double, dvdt: Double)] {
    guard trace.count >= 2 else { return [] }
    var pts: [(v: Double, dvdt: Double)] = []
    pts.reserveCapacity(trace.count)
    for i in 1..<trace.count {
        let dt = trace[i].t - trace[i-1].t
        guard dt > 0, dt < 2.0 else { continue }
        let dvdt = (trace[i].v - trace[i-1].v) / dt
        guard abs(dvdt) < 5000 else { continue }
        pts.append((v: trace[i-1].v, dvdt: dvdt))
    }
    return pts
}
