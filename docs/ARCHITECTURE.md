# Architecture de NeuroSim

## Couches

```
┌─────────────────────────────────────────────────┐
│  NeuroSimApp  (SwiftUI / AppKit)                │
│  ─ ContentView, NetworkEditorView, PlotView…    │
│  ─ SimulationViewModel  (@MainActor, @Published)│
└────────────────────┬────────────────────────────┘
                     │  dépend de
                     ▼
┌─────────────────────────────────────────────────┐
│  NeuroSimCore   (Foundation uniquement)         │
│  ─ HHNeuron, IonChannel, channels concrets      │
│  ─ Synapse, Network, Stimulus                   │
│  ─ RK4 / ForwardEuler, Simulator                │
└─────────────────────────────────────────────────┘
```

`NeuroSimCore` est pur Foundation — il compile et se teste sur Linux, ce qui
permet d'envisager du CI ou un backend de batch sans toucher à l'UI.

## Modèle de Hodgkin-Huxley

Pour un neurone à un compartiment :

```
C_m · dV/dt = -Σ_k I_k(V, gates_k) + I_inj(t)

I_k       = g_max,k · f_k(gates_k) · (V - E_k)
dgates/dt = α(V) · (1 - gates) - β(V) · gates
```

Conventions implantées :
- `V` en **mV**, temps en **ms**
- conductances en **mS/cm²**, courants en **µA/cm²**, capacité en **µF/cm²**
- repos par défaut : `V_rest = -65 mV`
- canaux par défaut (`HHNeuron.defaultChannels`) :
  - **Na+** : `g = 120`, `E = +50`, gates `m`, `h`, factor `m³h`
  - **K+**  : `g = 36`,  `E = -77`, gate `n`, factor `n⁴`
  - **Leak**: `g = 0.3`, `E = -54.4`, sans porte

Les rate constants suivent Hodgkin & Huxley (1952) avec décalage moderne de
+65 mV (`V_rest = -65 mV` au lieu de 0 mV historique). Voir
`SodiumChannel.swift` et `PotassiumChannel.swift`.

## Layout du vecteur d'état

`Network` aplatit toutes les variables d'état dans un seul `[Double]` que
l'intégrateur consomme :

```
indices : 0  1   2   3   4   5     6  7   8   9   10
contenu : V₀ m₀  h₀  n₀  V₁  m₁ … │ s₀ s₁ │
          neuron 0  │ neuron 1 …  │ synapse states
```

- Les offsets sont recalculés par `rebuildLayout()` après chaque mutation
  structurelle.
- Les synapses sans état (gap junctions) occupent zéro slot.

## Détection de spike

Pour les synapses chimiques, un spike du neurone pré-synaptique est détecté
**après** chaque pas RK4 par franchissement vers le haut de
`spikeThreshold` (par défaut 0 mV). Lorsqu'un franchissement est détecté,
`Simulator.dispatchSpikes()` applique un saut discret sur la variable de
gating de chaque synapse sortante (`s += 1`, plafonné à `sMax`).

L'intégration continue est ainsi découplée des événements discrets — RK4
voit une dynamique lisse entre deux spikes.

## Ajouter un nouveau canal ionique

1. Créer une classe conforme à `IonChannel` dans
   `Sources/NeuroSimCore/Channels/`.
2. Implémenter `stateCount`, `initialState`, `current`, `gateDerivatives`.
3. L'instancier dans `HHNeuron.channels` (soit en remplaçant
   `defaultChannels()`, soit dynamiquement après création).

Exemple — canal calcium type-T simplifié :

```swift
public final class TTypeCalciumChannel: IonChannel {
    public var name = "Ca_T"
    public var gMax = 0.5            // mS/cm²
    public var reversal = 120.0      // mV
    public var stateCount: Int { 2 } // m, h

    public func initialState(atVoltage v: Double) -> [Double] {
        [mInf(v), hInf(v)]
    }
    public func current(voltage v: Double, gates: ArraySlice<Double>) -> Double {
        let m = gates[gates.startIndex], h = gates[gates.startIndex + 1]
        return gMax * m * m * h * (v - reversal)
    }
    public func gateDerivatives(voltage v: Double,
                                gates: ArraySlice<Double>,
                                into output: inout [Double], offset: Int) {
        let m = gates[gates.startIndex], h = gates[gates.startIndex + 1]
        output[offset]     = (mInf(v) - m) / tauM(v)
        output[offset + 1] = (hInf(v) - h) / tauH(v)
    }
    private func mInf(_ v: Double) -> Double { 1.0 / (1 + exp(-(v + 57) / 6.2)) }
    private func hInf(_ v: Double) -> Double { 1.0 / (1 + exp((v + 81) / 4.0)) }
    private func tauM(_ v: Double) -> Double { 0.612 + 1 / (exp(-(v + 132) / 16.7) + exp((v + 16.8) / 18.2)) }
    private func tauH(_ v: Double) -> Double {
        v < -80 ? exp((v + 467) / 66.6) : exp(-(v + 22) / 10.5) + 28
    }
}
```

Aucune autre modification du moteur n'est nécessaire — `HHNeuron` allouera
automatiquement les deux nouveaux slots dans le vecteur d'état.

## Ajouter un nouveau modèle de synapse

Conformer une classe à `Synapse`. Les synapses bi-exponentielles (rise +
decay distincts) demandent `stateCount = 2`, le reste est analogue à
`ChemicalSynapse`. La méthode `applySpike` reçoit le slice global et
l'offset pour appliquer un saut discret sur n'importe quelle variable.

## Performance

Coûts approximatifs (M1, debug build) :
- 1 pas RK4 sur 1 neurone HH : ~ 5 µs
- 1 pas RK4 sur 100 neurones + 200 synapses : ~ 400 µs
- Avec `realtimeFactor = 1` à `dt = 0.01` ms, on calcule 1 660 pas par
  seconde de wall-clock — confortablement dans le budget temps réel.

Pour des réseaux > 1 000 neurones, déplacer la boucle `tick()` du
ViewModel sur un `DispatchQueue` dédié (ou Accelerate / Metal pour le
calcul vectoriel).

## Conventions de signe

- `IonChannel.current(...)` retourne **I = g · f(gates) · (V - E)** :
  positif vers l'extérieur de la cellule, négatif vers l'intérieur.
- Dans `HHNeuron.writeDerivatives` : `Cm · dV/dt = -I_ionic + I_inj`.
- `Synapse.currentToPost(...)` suit la **même convention** : positive en
  sortie de la post-synaptique. `Network` applique le signe `-` lors de
  l'addition à `iInj`.
- `applySpike` modifie directement le vecteur d'état — c'est la seule
  porte d'entrée pour les événements discrets.
