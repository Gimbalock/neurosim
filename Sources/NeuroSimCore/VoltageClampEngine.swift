//
//  VoltageClampEngine.swift
//  NeuroSimCore
//
//  Self-contained voltage clamp simulation.
//  Gates evolve via Rush-Larsen at the commanded voltage; currents are
//  computed per-channel at each step. No network, no synapses, no capacitance.
//

import Foundation

// MARK: - Protocol definition

public struct VoltageClampProtocol: Equatable, Codable, Sendable {
    public var vHold:  Double = -70.0   // mV
    public var vStart: Double = -80.0   // mV — first test voltage
    public var vEnd:   Double =  40.0   // mV — last test voltage
    public var nSteps: Int    = 13
    public var tPre:   Double = 50.0    // ms — duration at V_hold before each step
    public var tStep:  Double = 200.0   // ms — duration of each test step
    public var dt:     Double = 0.025   // ms

    public init() {}

    public var stepVoltages: [Double] {
        guard nSteps > 1 else { return [(vStart + vEnd) / 2] }
        return (0..<nSteps).map { i in
            vStart + Double(i) * (vEnd - vStart) / Double(nSteps - 1)
        }
    }
}

// MARK: - Output

public struct VClampChannelTrace: Sendable {
    public let channelName:        String
    public let stepVoltage:        Double    // mV
    public let times:              [Double]  // ms, 0 = start of test step (pre-step = negative t)
    public let currentsDensity:    [Double]  // µA/cm²
    public let steadyStateDensity: Double    // µA/cm² — mean over last 10 % of test step
}

public struct VClampResult: Sendable {
    public let vcProtocol:   VoltageClampProtocol
    public let channelNames: [String]
    /// traces[stepIndex][channelIndex]
    public let traces: [[VClampChannelTrace]]

    public init(vcProtocol: VoltageClampProtocol, channelNames: [String],
                traces: [[VClampChannelTrace]]) {
        self.vcProtocol   = vcProtocol
        self.channelNames = channelNames
        self.traces       = traces
    }

    /// steadyStateMatrix[channelIndex][stepIndex]
    public var steadyStateMatrix: [[Double]] {
        guard let first = traces.first else { return [] }
        return first.indices.map { ci in traces.map { $0[ci].steadyStateDensity } }
    }
}

// MARK: - Engine

public struct VoltageClampEngine {
    public let compartment: Compartment
    public let vcProtocol:  VoltageClampProtocol

    public init(compartment: Compartment, vcProtocol: VoltageClampProtocol) {
        self.compartment = compartment
        self.vcProtocol  = vcProtocol
    }

    /// Run a single step voltage (V_hold pre-step then vTest).
    /// Returns one VClampChannelTrace per channel.
    public func runStep(vTest: Double) -> [VClampChannelTrace] {
        let channels = compartment.channels
        let vHold    = vcProtocol.vHold
        let dt       = vcProtocol.dt
        let nPre     = max(1, Int(vcProtocol.tPre  / dt))
        let nStep    = max(1, Int(vcProtocol.tStep / dt))
        let total    = nPre + nStep
        let every    = max(1, total / 800)   // ≤ 800 recorded points per trace

        var gates: [[Double]] = channels.map { $0.initialState(atVoltage: vHold) }

        var times:    [Double]    = []
        var currents: [[Double]]  = Array(repeating: [], count: channels.count)
        var ssAcc:    [[Double]]  = Array(repeating: [], count: channels.count)
        let ssStart = nStep * 9 / 10

        // Pre-step at V_hold
        for k in 0..<nPre {
            advanceGates(&gates, voltage: vHold, dt: dt)
            if k % every == 0 {
                times.append(Double(k) * dt - vcProtocol.tPre)
                for (ci, ch) in channels.enumerated() {
                    currents[ci].append(ch.current(voltage: vHold, gates: gates[ci][0...]))
                }
            }
        }

        // Test step at vTest
        for k in 0..<nStep {
            advanceGates(&gates, voltage: vTest, dt: dt)
            if k % every == 0 {
                times.append(Double(k) * dt)
                for (ci, ch) in channels.enumerated() {
                    let I = ch.current(voltage: vTest, gates: gates[ci][0...])
                    currents[ci].append(I)
                    if k >= ssStart { ssAcc[ci].append(I) }
                }
            }
        }

        return channels.enumerated().map { (ci, ch) in
            let ss = ssAcc[ci].isEmpty ? 0.0
                : ssAcc[ci].reduce(0, +) / Double(ssAcc[ci].count)
            return VClampChannelTrace(channelName:        ch.name,
                                      stepVoltage:        vTest,
                                      times:              times,
                                      currentsDensity:    currents[ci],
                                      steadyStateDensity: ss)
        }
    }

    // MARK: - Gate update (Rush-Larsen for HHGated, Euler fallback otherwise)

    private func advanceGates(_ gates: inout [[Double]],
                               voltage v: Double,
                               dt: Double) {
        for (ci, ch) in compartment.channels.enumerated() {
            if let gated = ch as? any HHGated {
                for gi in 0..<ch.stateCount {
                    let xInf = gated.resolvedGateInf(gi, voltage: v)
                    let tau  = gated.resolvedGateTau(gi, voltage: v)
                    gates[ci][gi] = xInf + (gates[ci][gi] - xInf) * exp(-dt / tau)
                }
            } else if ch.stateCount > 0 {
                var derivs = [Double](repeating: 0, count: ch.stateCount)
                ch.gateDerivatives(voltage: v, gates: gates[ci][0...],
                                   into: &derivs, offset: 0)
                for gi in 0..<ch.stateCount {
                    gates[ci][gi] = max(-1e6, min(1e6, gates[ci][gi] + derivs[gi] * dt))
                }
            }
        }
    }
}
