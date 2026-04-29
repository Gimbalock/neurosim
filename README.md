# NeuroSim

Simulateur Mac natif (Swift / SwiftUI) de réseaux de neurones biologiques
basé sur le formalisme de Hodgkin-Huxley.

```
┌────────────────────────────────────┬─────────────────┐
│  Éditeur graphique du réseau       │   Inspecteur    │
│  (drag/drop neurones + synapses)   │   (paramètres)  │
├────────────────────────────────────┴─────────────────┤
│  Tracé V(t) en temps réel (Swift Charts)             │
└──────────────────────────────────────────────────────┘
```

## Caractéristiques

- **Cœur de simulation pur Swift**, sans dépendance UI : testable isolément,
  réutilisable depuis des scripts ou un futur backend headless.
- **Canaux ioniques extensibles** via le protocole `IonChannel` — Na+, K+ et
  fuite fournis par défaut, ajout de nouveaux canaux en quelques lignes.
- **Synapses chimiques** (excitatrices/inhibitrices, conductance exponentielle,
  déclenchées par franchissement de seuil) **et électriques** (gap junctions).
- **Protocoles de stimulation composables** : créneaux, rampes, trains,
  bruit Ornstein-Uhlenbeck, sommes arbitraires.
- **Intégrateur RK4** explicite (Forward Euler également disponible pour
  les diagnostics de convergence).
- **Éditeur graphique** : ajouter/déplacer/supprimer des neurones, dessiner
  des synapses par drag-and-drop ; les nœuds changent de couleur en fonction
  du potentiel de membrane instantané (bleu = hyperpolarisé, rouge = spike).
- **Tracé V(t) en temps réel** avec fenêtre glissante réglable.
- **Export CSV** des traces pour analyse offline.

## Compilation

NeuroSim est un *Swift Package* — pas besoin d'un projet Xcode pré-existant.

### Méthode 1 — Xcode (recommandée pour développer l'UI)

```bash
cd NeuroSim
open Package.swift
```

Xcode ouvre le package avec deux cibles :
- `NeuroSimCore` (bibliothèque de simulation, testable)
- `NeuroSimApp` (exécutable SwiftUI)

Sélectionne le schéma **NeuroSimApp**, puis ⌘R pour lancer.

### Méthode 2 — ligne de commande

```bash
cd NeuroSim
swift build -c release
swift run NeuroSimApp
swift test                    # exécute les tests du cœur
```

> ⚠️ Les exécutables construits via `swift run` ne sont pas des bundles `.app`
> signés. Pour distribuer, créer un projet d'app macOS dans Xcode pointant
> vers la library `NeuroSimCore` (voir `docs/ARCHITECTURE.md`).

## Prérequis

- macOS 14 (Sonoma) ou ultérieur
- Xcode 15.0+ / Swift 5.9+

## Usage rapide

1. Lancer l'app — un mini-réseau de démonstration (deux neurones + une
   synapse excitatrice) est créé automatiquement.
2. Cliquer **Run** dans la barre d'outils ou appuyer sur `Espace`.
3. Sélectionner un neurone pour ajuster ses canaux et son courant injecté
   dans l'inspecteur.
4. Basculer le mode d'édition sur **Connect** puis tirer d'un neurone vers
   un autre pour créer une synapse.
5. Exporter les traces en CSV via la barre d'outils ou `⌘E`.

## Tests

```bash
swift test
```

Couvre :
- État de repos stable (V se maintient à -65 mV ± 1 mV)
- Génération de potentiel d'action sur stimulus 10 µA/cm²
- Absence de spike sur stimulus 1 µA/cm² (sub-seuil)
- Cadence de tir attendue ~50–80 Hz sous courant constant 10 µA/cm²
- Propagation excitatrice via synapse chimique
- Suppression par inhibition (E_rev = -75 mV)
- Cohérence du graphe après suppression de neurones

## Pour aller plus loin

`docs/ARCHITECTURE.md` détaille les conventions de signe, le layout du
vecteur d'état, et comment ajouter un nouveau canal ionique ou un nouveau
modèle de synapse.
