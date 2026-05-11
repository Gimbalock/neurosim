//
//  Network+Duplicate.swift
//  NeuroSimCore
//
//  Deep-copy a neuron within the network, assigning fresh UUIDs to avoid
//  conflicts. Channels are cloned via the ChannelDoc round-trip (same path
//  as save/load) so all parameters are faithfully reproduced.
//

import Foundation

public extension Network {

    /// Deep-copy the neuron identified by `id`, place the copy 80 pt to the
    /// lower-right of the original, and add it to this network.
    ///
    /// Returns `(newNeuron, compIDMap)` where `compIDMap` maps each original
    /// compartment UUID to the corresponding new compartment UUID. The caller
    /// can use this map to clone synapses referencing the original if desired.
    ///
    /// Stimuli and synaptic-noise sources targeting the original's compartments
    /// are automatically cloned onto the copy.
    ///
    /// Returns `nil` if `id` does not match any neuron in the network.
    @discardableResult
    func duplicateNeuron(id: UUID) -> (HHNeuron, [UUID: UUID])? {
        guard let original = neurons.first(where: { $0.id == id }) else { return nil }

        // Build compartment ID remap
        var compIDMap: [UUID: UUID] = [:]
        for comp in original.compartments { compIDMap[comp.id] = UUID() }

        // Deep-copy compartments (channels via ChannelDoc round-trip)
        let newComps = original.compartments.map { comp -> Compartment in
            let newComp = Compartment(
                id:          compIDMap[comp.id]!,
                name:        comp.name,
                capacitance: comp.capacitance,
                diameter:    comp.diameter,
                length:      comp.length,
                channels:    comp.channels.map { ChannelDoc.from($0).toChannel() }
            )
            newComp.displayAngle          = comp.displayAngle
            newComp.branchFraction        = comp.branchFraction
            newComp.concentrationDynamics = comp.concentrationDynamics.map {
                ConcentrationDynamic(ionSymbol:   $0.ionSymbol,
                                     restingConc: $0.restingConc,
                                     tauDecay:    $0.tauDecay)
            }
            return newComp
        }

        let newCouplings = original.axialCouplings.map { ac in
            AxialCoupling(id:          UUID(),
                          between:     compIDMap[ac.compartmentA]!,
                          and:         compIDMap[ac.compartmentB]!,
                          conductance: ac.conductance)
        }

        let newNeuron = HHNeuron(
            id:           UUID(),
            name:         original.name + " copie",
            compartments: newComps,
            couplings:    newCouplings,
            soma:         compIDMap[original.somaCompartmentID]!
        )
        newNeuron.positionX = original.positionX + 80
        newNeuron.positionY = original.positionY + 80
        addNeuron(newNeuron)

        // Clone stimuli targeting original compartments
        for (compID, stim) in stimuli {
            if let newCompID = compIDMap[compID] {
                setStimulus(stim, onCompartment: newCompID)
            }
        }

        // Clone synaptic-noise sources
        for (compID, src) in synapticNoises {
            if let newCompID = compIDMap[compID] {
                setSynapticNoise(src.params, onCompartment: newCompID)
            }
        }

        return (newNeuron, compIDMap)
    }
}
