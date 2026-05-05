//
//  NetworkDocument.swift
//  NeuroSimCore
//
//  Codable snapshot of the full network topology. Used to save/load sessions
//  to/from JSON on disk. Separate from the live model types so neither the
//  serialization format nor the runtime classes depend on each other.
//

import Foundation

// MARK: - Root

public struct NetworkDocument: Codable {
    public var neurons:  [NeuronDoc]
    public var synapses: [SynapseDoc]
    public var stimuli:  [StimulusEntry]   // keyed by compartment UUID

    public struct StimulusEntry: Codable {
        public var compartmentID: UUID
        public var stimulus: StimulusDoc
    }
}

// MARK: - Neuron

public struct NeuronDoc: Codable {
    public var id:              UUID
    public var name:            String
    public var positionX:       Double
    public var positionY:       Double
    public var somaID:          UUID
    public var compartments:    [CompartmentDoc]
    public var axialCouplings:  [AxialCouplingDoc]
}

public struct CompartmentDoc: Codable {
    public var id:          UUID
    public var name:        String
    public var capacitance: Double
    public var diameter:    Double
    public var length:      Double
    public var channels:    [ChannelDoc]

    public init(id: UUID, name: String, capacitance: Double,
                diameter: Double = 20.0, length: Double = 20.0,
                channels: [ChannelDoc]) {
        self.id          = id
        self.name        = name
        self.capacitance = capacitance
        self.diameter    = diameter
        self.length      = length
        self.channels    = channels
    }

    public init(from decoder: Decoder) throws {
        let c        = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,   forKey: .id)
        name         = try c.decode(String.self, forKey: .name)
        capacitance  = try c.decode(Double.self, forKey: .capacitance)
        diameter     = try c.decodeIfPresent(Double.self, forKey: .diameter) ?? 20.0
        length       = try c.decodeIfPresent(Double.self, forKey: .length)   ?? 20.0
        channels     = try c.decode([ChannelDoc].self, forKey: .channels)
    }
}

public struct AxialCouplingDoc: Codable {
    public var id:           UUID
    public var compartmentA: UUID
    public var compartmentB: UUID
    public var conductance:  Double
}

// MARK: - Channels (discriminated by `kind`)

public struct ChannelDoc: Codable {
    public var kind:     String   // "sodium" | "potassium" | "leak" | "tTypeCalcium" | "custom"
    public var gMax:     Double
    public var reversal: Double
    // Gate overrides — only gated channels fill these.
    // Each array entry encodes one gate's x∞ and τ overrides (may be nil).
    public var gateInfOverrides: [GateCurveDoc?]
    public var gateTauOverrides: [GateCurveDoc?]
    // Full definition — only present for kind == "custom".
    public var customDefinition: CustomChannelDefinition?

    public init(kind: String, gMax: Double, reversal: Double,
                gateInfOverrides: [GateCurveDoc?] = [],
                gateTauOverrides: [GateCurveDoc?] = [],
                customDefinition: CustomChannelDefinition? = nil) {
        self.kind = kind
        self.gMax = gMax
        self.reversal = reversal
        self.gateInfOverrides = gateInfOverrides
        self.gateTauOverrides = gateTauOverrides
        self.customDefinition = customDefinition
    }
}

// MARK: - GateCurve

public struct GateCurveDoc: Codable {
    public var kind:         String    // "sigmoid" | "polynomial"
    // sigmoid fields
    public var lo:           Double?
    public var hi:           Double?
    public var vHalf:        Double?
    public var k:            Double?
    // polynomial fields
    public var coefficients: [Double]?
    public var vCenter:      Double?
    // shared optional domain
    public var domainLo:     Double?
    public var domainHi:     Double?
}

// MARK: - Stimuli (discriminated by `kind`)

public enum StimulusDoc: Codable {
    case constant(amplitude: Double)
    case pulse(start: Double, duration: Double, amplitude: Double)
    case ramp(start: Double, duration: Double, from: Double, to: Double)
    case train(start: Double, period: Double, pulseWidth: Double,
               amplitude: Double, count: Int)
    case ouNoise(mean: Double, sigma: Double, tau: Double,
                 dt: Double, seed: UInt64)

    // -- Manual Codable because Swift won't synthesise for enums with
    //    associated values that map to flat JSON keys.

    private enum CodingKeys: String, CodingKey {
        case kind, amplitude, start, duration, from, to
        case period, pulseWidth, count
        case mean, sigma, tau, dt, seed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .constant(a):
            try c.encode("constant", forKey: .kind)
            try c.encode(a, forKey: .amplitude)
        case let .pulse(s, d, a):
            try c.encode("pulse", forKey: .kind)
            try c.encode(s, forKey: .start)
            try c.encode(d, forKey: .duration)
            try c.encode(a, forKey: .amplitude)
        case let .ramp(s, d, f, t):
            try c.encode("ramp", forKey: .kind)
            try c.encode(s, forKey: .start)
            try c.encode(d, forKey: .duration)
            try c.encode(f, forKey: .from)
            try c.encode(t, forKey: .to)
        case let .train(s, p, pw, a, ct):
            try c.encode("train", forKey: .kind)
            try c.encode(s, forKey: .start)
            try c.encode(p, forKey: .period)
            try c.encode(pw, forKey: .pulseWidth)
            try c.encode(a, forKey: .amplitude)
            try c.encode(ct, forKey: .count)
        case let .ouNoise(m, sigma, tau, dt, seed):
            try c.encode("ouNoise", forKey: .kind)
            try c.encode(m, forKey: .mean)
            try c.encode(sigma, forKey: .sigma)
            try c.encode(tau, forKey: .tau)
            try c.encode(dt, forKey: .dt)
            try c.encode(seed, forKey: .seed)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "constant":
            self = .constant(amplitude: try c.decode(Double.self, forKey: .amplitude))
        case "pulse":
            self = .pulse(start:     try c.decode(Double.self, forKey: .start),
                          duration:  try c.decode(Double.self, forKey: .duration),
                          amplitude: try c.decode(Double.self, forKey: .amplitude))
        case "ramp":
            self = .ramp(start:    try c.decode(Double.self, forKey: .start),
                         duration: try c.decode(Double.self, forKey: .duration),
                         from:     try c.decode(Double.self, forKey: .from),
                         to:       try c.decode(Double.self, forKey: .to))
        case "train":
            self = .train(start:      try c.decode(Double.self, forKey: .start),
                          period:     try c.decode(Double.self, forKey: .period),
                          pulseWidth: try c.decode(Double.self, forKey: .pulseWidth),
                          amplitude:  try c.decode(Double.self, forKey: .amplitude),
                          count:      try c.decode(Int.self,    forKey: .count))
        case "ouNoise":
            self = .ouNoise(mean:  try c.decode(Double.self, forKey: .mean),
                            sigma: try c.decode(Double.self, forKey: .sigma),
                            tau:   try c.decode(Double.self, forKey: .tau),
                            dt:    try c.decode(Double.self, forKey: .dt),
                            seed:  try c.decode(UInt64.self, forKey: .seed))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "Unknown stimulus kind: \(kind)")
        }
    }
}

// MARK: - Synapses (discriminated by `kind`)

public enum SynapseDoc: Codable {
    case chemical(id: UUID, pre: UUID, post: UUID, postComp: UUID?,
                  gMax: Double, reversal: Double,
                  tauDecay: Double, sMax: Double, weight: Double)
    case gapJunction(id: UUID, pre: UUID, post: UUID, postComp: UUID?,
                     conductance: Double, weight: Double)

    private enum CodingKeys: String, CodingKey {
        case kind, id, pre, post, postComp
        case gMax, reversal, tauDecay, sMax, weight
        case conductance
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .chemical(id, pre, post, postComp, gMax, rev, tau, sMax, w):
            try c.encode("chemical",  forKey: .kind)
            try c.encode(id,          forKey: .id)
            try c.encode(pre,         forKey: .pre)
            try c.encode(post,        forKey: .post)
            try c.encodeIfPresent(postComp, forKey: .postComp)
            try c.encode(gMax,        forKey: .gMax)
            try c.encode(rev,         forKey: .reversal)
            try c.encode(tau,         forKey: .tauDecay)
            try c.encode(sMax,        forKey: .sMax)
            try c.encode(w,           forKey: .weight)
        case let .gapJunction(id, pre, post, postComp, g, w):
            try c.encode("gapJunction", forKey: .kind)
            try c.encode(id,            forKey: .id)
            try c.encode(pre,           forKey: .pre)
            try c.encode(post,          forKey: .post)
            try c.encodeIfPresent(postComp, forKey: .postComp)
            try c.encode(g,             forKey: .conductance)
            try c.encode(w,             forKey: .weight)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "chemical":
            self = .chemical(
                id:       try c.decode(UUID.self,    forKey: .id),
                pre:      try c.decode(UUID.self,    forKey: .pre),
                post:     try c.decode(UUID.self,    forKey: .post),
                postComp: try c.decodeIfPresent(UUID.self, forKey: .postComp),
                gMax:     try c.decode(Double.self,  forKey: .gMax),
                reversal: try c.decode(Double.self,  forKey: .reversal),
                tauDecay: try c.decode(Double.self,  forKey: .tauDecay),
                sMax:     try c.decode(Double.self,  forKey: .sMax),
                weight:   try c.decode(Double.self,  forKey: .weight))
        case "gapJunction":
            self = .gapJunction(
                id:          try c.decode(UUID.self,   forKey: .id),
                pre:         try c.decode(UUID.self,   forKey: .pre),
                post:        try c.decode(UUID.self,   forKey: .post),
                postComp:    try c.decodeIfPresent(UUID.self, forKey: .postComp),
                conductance: try c.decode(Double.self, forKey: .conductance),
                weight:      try c.decode(Double.self, forKey: .weight))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "Unknown synapse kind: \(kind)")
        }
    }
}

// MARK: - Network → Document

public extension NetworkDocument {

    static func from(_ network: Network) -> NetworkDocument {
        let neuronDocs = network.neurons.map { n -> NeuronDoc in
            let compDocs = n.compartments.map { comp -> CompartmentDoc in
                CompartmentDoc(
                    id:          comp.id,
                    name:        comp.name,
                    capacitance: comp.capacitance,
                    diameter:    comp.diameter,
                    length:      comp.length,
                    channels:    comp.channels.map(ChannelDoc.from))
            }
            let couplingDocs = n.axialCouplings.map { ac in
                AxialCouplingDoc(id: ac.id,
                                 compartmentA: ac.compartmentA,
                                 compartmentB: ac.compartmentB,
                                 conductance:  ac.conductance)
            }
            return NeuronDoc(id:             n.id,
                             name:           n.name,
                             positionX:      n.positionX,
                             positionY:      n.positionY,
                             somaID:         n.somaCompartmentID,
                             compartments:   compDocs,
                             axialCouplings: couplingDocs)
        }

        let synapseDocs = network.synapses.map(SynapseDoc.from)

        let stimulusEntries = network.stimuli.compactMap { (compID, stim) -> StimulusEntry? in
            guard let doc = StimulusDoc.from(stim) else { return nil }
            return StimulusEntry(compartmentID: compID, stimulus: doc)
        }

        return NetworkDocument(neurons:  neuronDocs,
                               synapses: synapseDocs,
                               stimuli:  stimulusEntries)
    }

    // MARK: - Document → Network

    func toNetwork() -> Network {
        let net = Network()

        for nd in neurons {
            let comps = nd.compartments.map { cd -> Compartment in
                Compartment(id:          cd.id,
                            name:        cd.name,
                            capacitance: cd.capacitance,
                            diameter:    cd.diameter,
                            length:      cd.length,
                            channels:    cd.channels.map { $0.toChannel() })
            }
            let couplings = nd.axialCouplings.map { ac in
                AxialCoupling(id:          ac.id,
                              between:     ac.compartmentA,
                              and:         ac.compartmentB,
                              conductance: ac.conductance)
            }
            let neuron = HHNeuron(id:           nd.id,
                                  name:         nd.name,
                                  compartments: comps,
                                  couplings:    couplings,
                                  soma:         nd.somaID)
            neuron.positionX = nd.positionX
            neuron.positionY = nd.positionY
            net.addNeuron(neuron)
        }

        for sd in synapses {
            net.addSynapse(sd.toSynapse())
        }

        for entry in stimuli {
            net.setStimulus(entry.stimulus.toStimulus(),
                            onCompartment: entry.compartmentID)
        }

        return net
    }
}

// MARK: - ChannelDoc helpers

private extension ChannelDoc {

    static func from(_ ch: IonChannel) -> ChannelDoc {
        switch ch {
        case let s as SodiumChannel:
            return ChannelDoc(kind: "sodium", gMax: s.gMax, reversal: s.reversal,
                              gateInfOverrides: s.gateInfOverrides.map { $0.map(GateCurveDoc.from) },
                              gateTauOverrides: s.gateTauOverrides.map { $0.map(GateCurveDoc.from) })
        case let k as PotassiumChannel:
            return ChannelDoc(kind: "potassium", gMax: k.gMax, reversal: k.reversal,
                              gateInfOverrides: k.gateInfOverrides.map { $0.map(GateCurveDoc.from) },
                              gateTauOverrides: k.gateTauOverrides.map { $0.map(GateCurveDoc.from) })
        case let l as LeakChannel:
            return ChannelDoc(kind: "leak", gMax: l.gMax, reversal: l.reversal)
        case let ca as TTypeCalciumChannel:
            return ChannelDoc(kind: "tTypeCalcium", gMax: ca.gMax, reversal: ca.reversal,
                              gateInfOverrides: ca.gateInfOverrides.map { $0.map(GateCurveDoc.from) },
                              gateTauOverrides: ca.gateTauOverrides.map { $0.map(GateCurveDoc.from) })
        case let cc as CustomChannel:
            return ChannelDoc(kind: "custom", gMax: cc.gMax, reversal: cc.reversal,
                              gateInfOverrides: cc.gateInfOverrides.map { $0.map(GateCurveDoc.from) },
                              gateTauOverrides: cc.gateTauOverrides.map { $0.map(GateCurveDoc.from) },
                              customDefinition: cc.definition)
        default:
            return ChannelDoc(kind: "leak", gMax: ch.gMax, reversal: ch.reversal)
        }
    }

    func toChannel() -> IonChannel {
        let infs = gateInfOverrides.map { $0.map { GateCurve.from($0) } }
        let taus = gateTauOverrides.map { $0.map { GateCurve.from($0) } }
        switch kind {
        case "sodium":
            let ch = SodiumChannel(gMax: gMax, reversal: reversal)
            if infs.count == 2 { ch.gateInfOverrides = infs }
            if taus.count == 2 { ch.gateTauOverrides = taus }
            return ch
        case "potassium":
            let ch = PotassiumChannel(gMax: gMax, reversal: reversal)
            if infs.count == 1 { ch.gateInfOverrides = infs }
            if taus.count == 1 { ch.gateTauOverrides = taus }
            return ch
        case "tTypeCalcium":
            let ch = TTypeCalciumChannel(gMax: gMax, reversal: reversal)
            if infs.count == 2 { ch.gateInfOverrides = infs }
            if taus.count == 2 { ch.gateTauOverrides = taus }
            return ch
        case "custom":
            guard let def = customDefinition else {
                return LeakChannel(gMax: gMax, reversal: reversal)
            }
            let ch = CustomChannel(definition: def)
            if infs.count == def.gates.count { ch.gateInfOverrides = infs }
            if taus.count == def.gates.count { ch.gateTauOverrides = taus }
            return ch
        default: // "leak" or unknown
            return LeakChannel(gMax: gMax, reversal: reversal)
        }
    }
}

// MARK: - GateCurveDoc helpers

private extension GateCurveDoc {

    static func from(_ gc: GateCurve) -> GateCurveDoc {
        switch gc {
        case let .sigmoid(lo, hi, vHalf, k, domain):
            return GateCurveDoc(kind: "sigmoid",
                                lo: lo, hi: hi, vHalf: vHalf, k: k,
                                domainLo: domain?.lowerBound,
                                domainHi: domain?.upperBound)
        case let .polynomial(coeffs, vCenter, domain):
            return GateCurveDoc(kind: "polynomial",
                                coefficients: coeffs, vCenter: vCenter,
                                domainLo: domain?.lowerBound,
                                domainHi: domain?.upperBound)
        }
    }
}

private extension GateCurve {

    static func from(_ doc: GateCurveDoc) -> GateCurve {
        let domain: ClosedRange<Double>? = {
            guard let lo = doc.domainLo, let hi = doc.domainHi else { return nil }
            return lo...hi
        }()
        switch doc.kind {
        case "polynomial":
            return .polynomial(coefficients: doc.coefficients ?? [],
                               vCenter: doc.vCenter ?? 0,
                               domain: domain)
        default: // "sigmoid"
            return .sigmoid(lo: doc.lo ?? 0, hi: doc.hi ?? 1,
                            vHalf: doc.vHalf ?? -40, k: doc.k ?? 5,
                            domain: domain)
        }
    }
}

// MARK: - StimulusDoc helpers

private extension StimulusDoc {

    static func from(_ s: Stimulus) -> StimulusDoc? {
        switch s {
        case let p as PulseStimulus:
            return .pulse(start: p.start, duration: p.duration, amplitude: p.amplitude)
        case let c as ConstantStimulus:
            return .constant(amplitude: c.amplitude)
        case let r as RampStimulus:
            return .ramp(start: r.start, duration: r.duration, from: r.from, to: r.to)
        case let t as TrainStimulus:
            return .train(start: t.start, period: t.period, pulseWidth: t.pulseWidth,
                          amplitude: t.amplitude, count: t.count)
        case let ou as OUNoiseStimulus:
            return .ouNoise(mean: ou.mean, sigma: ou.sigma, tau: ou.tau,
                            dt: ou.dt, seed: ou.seed)
        default:
            return nil
        }
    }

    func toStimulus() -> Stimulus {
        switch self {
        case let .constant(a):
            return ConstantStimulus(amplitude: a)
        case let .pulse(s, d, a):
            return PulseStimulus(start: s, duration: d, amplitude: a)
        case let .ramp(s, d, f, t):
            return RampStimulus(start: s, duration: d, from: f, to: t)
        case let .train(s, p, pw, a, ct):
            return TrainStimulus(start: s, period: p, pulseWidth: pw,
                                 amplitude: a, count: ct)
        case let .ouNoise(m, sigma, tau, dt, seed):
            return OUNoiseStimulus(mean: m, sigma: sigma, tau: tau,
                                   dt: dt, seed: seed)
        }
    }
}

// MARK: - SynapseDoc helpers

private extension SynapseDoc {

    static func from(_ s: Synapse) -> SynapseDoc {
        switch s {
        case let ch as ChemicalSynapse:
            return .chemical(id: ch.id, pre: ch.preNeuronID, post: ch.postNeuronID,
                             postComp: ch.postCompartmentID,
                             gMax: ch.gMax, reversal: ch.reversal,
                             tauDecay: ch.tauDecay, sMax: ch.sMax, weight: ch.weight)
        case let gj as GapJunction:
            return .gapJunction(id: gj.id, pre: gj.preNeuronID, post: gj.postNeuronID,
                                postComp: gj.postCompartmentID,
                                conductance: gj.conductance, weight: gj.weight)
        default:
            // Fallback: encode as a silent chemical synapse to avoid data loss.
            return .chemical(id: s.id, pre: s.preNeuronID, post: s.postNeuronID,
                             postComp: s.postCompartmentID,
                             gMax: 0, reversal: 0, tauDecay: 5, sMax: 1, weight: 0)
        }
    }

    func toSynapse() -> Synapse {
        switch self {
        case let .chemical(id, pre, post, postComp, gMax, rev, tau, sMax, w):
            return ChemicalSynapse(id: id, from: pre, to: post,
                                   onCompartment: postComp,
                                   gMax: gMax, reversal: rev,
                                   tauDecay: tau, sMax: sMax, weight: w)
        case let .gapJunction(id, pre, post, postComp, g, w):
            return GapJunction(id: id, from: pre, to: post,
                               onCompartment: postComp,
                               conductance: g, weight: w)
        }
    }
}
