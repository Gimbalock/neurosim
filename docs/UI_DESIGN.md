# NeuroSim — Design de l'interface utilisateur

> Document de spec à destination des futures sessions d'implémentation UI.
> Décisions ratifiées : tool palette compacte verticale, fenêtre Plots
> toujours séparée dès le lancement.

## Vue d'ensemble

NeuroSim est une app macOS native (SwiftUI). Elle se compose de **deux
fenêtres principales** :

1. **Fenêtre principale** — l'éditeur de modèle (canvas central + panneaux
   latéraux ajustables).
2. **Fenêtre Plots** — flottante, détachable, indépendante. Lancée
   automatiquement à l'ouverture de l'app, peut être déplacée sur un second
   écran.

L'idée est de séparer clairement « **construction et configuration du
modèle** » (fenêtre principale) de « **observation des résultats** »
(fenêtre Plots), pour ne pas surcharger l'attention de l'utilisateur·rice.

## Layout de la fenêtre principale

```
┌────────────────────────────────────────────────────────────────────────┐
│  TOOLBAR  [▶] [⏸] [↺]  |  Demo: [Thalamic Relay ▼]  |  [⚙ Settings]    │
├────┬──────────────────────────────────────────────────┬────────────────┤
│    │                                                  │                │
│ T  │                                                  │   INSPECTOR    │
│ O  │                                                  │                │
│ O  │              CANVAS PRINCIPAL                    │  (paramètres   │
│ L  │              (modèle / réseau)                   │   du neurone   │
│ S  │                                                  │   ou synapse   │
│    │           Drag-zoom-pan, multi-sélection         │   sélectionné) │
│ ▌  │                                                  │                │
│    │                                                  │   éditable     │
│    │                                                  │   inline       │
│    │                                                  │                │
├────┴──────────────────────────────────────────────────┴────────────────┤
│  STATUS BAR  t = 124.3 ms · 200 ms/s · 2 spikes · 3 compartments       │
└────────────────────────────────────────────────────────────────────────┘
```

### Caractéristiques

- **Redimensionnable** dans toutes les directions (drag des bords/coins).
- **Plein écran** standard macOS (bouton vert / `⌃⌘F`).
- Panneaux latéraux **ajustables** : drag de la séparation pour élargir.
- Panneaux **rétractables** par bouton flèche (libère le canvas).
- Tailles de panneaux **persistées** entre sessions (`UserDefaults`).

## Panneau outils (gauche) — vertical compact

**Décision : icônes seules, 32×32 px**, alignées verticalement, tooltip au
survol et raccourci clavier dédié pour chaque outil.

```
┌────┐
│ ↖  │  Select / déplace                       (V)
│ ✋ │  Pan canvas                             (H)
│    │
│ ⊕  │  Ajouter neurone                        (N)
│ ⊕̧  │  Ajouter compartiment                   (C)
│    │     (sur le neurone sélectionné)
│ ↝  │  Tracer une synapse                     (S)
│ ⚡ │  Tracer un couplage axial               (A)
│    │     (entre 2 compartiments d'un même
│    │      neurone, gap junction interne)
│    │
│ 📌 │  Poser un stimulus                      (I)
│ 🔍 │  Mesure / probe                         (M)
│    │     (clic = ajouter au plot)
│    │
│ ─── │     séparateur visuel
│    │
│ 📚 │  Bibliothèque de modèles                (L)
│ 🗂  │  Bibliothèque de canaux                (K)
└────┘
```

Largeur cible : **48 px** (32 px d'icône + 16 px de marge). L'outil
sélectionné conditionne ce que fait le clic sur le canvas — paradigme
classique des éditeurs (Photoshop, OmniGraffle, Figma).

### Symboles SF (proposés)

- Select : `cursorarrow`
- Pan : `hand.draw`
- Add neuron : `circle.dashed`
- Add compartment : `circle.dotted.and.circle`
- Synapse : `arrow.forward`
- Axial coupling : `link`
- Stimulus : `bolt`
- Probe : `magnifyingglass`
- Model library : `books.vertical`
- Channel library : `slider.horizontal.3`

## Inspecteur (droite)

**Contextuel** selon ce qui est sélectionné dans le canvas. Le panneau
change de contenu sans changer de structure :

| Sélection | Contenu de l'inspecteur |
|:----------|:-------------------------|
| Aucune | Paramètres globaux (dt, durée, T, V_rest, intégrateur) |
| Neurone | Nom · liste des compartiments · soma flag · position |
| Compartiment | Capacitance · liste de canaux (+/−) · liste des couplages |
| Canal | gMax · reversal · espèce ionique · mini-plot α/β en V |
| Synapse | Type · gMax · reversal · τ_decay · pré/post |
| Stimulus | Type · paramètres spécifiques (start, durée, amplitude…) |

### Features à prévoir

- Édition inline (sliders + champs numériques avec unités)
- Aperçu mini-graphique pour les canaux (α(V) et β(V), ou m∞/τₘ)
- Bouton `Save as template…` (pour Step 5 / sauvegarde de modèles)
- Bouton `Reset to defaults` par section

## Fenêtre Plots — flottante, séparée, ouverte par défaut

**Décision : fenêtre indépendante dès le lancement de l'app.**
L'utilisateur·rice peut la fermer sans casser la simulation, la rouvrir
via le menu **Window → Plots** (`⌘2`).

```
┌─ Plots ──────────────────────────────────────┐
│  Onglets : [V(t)] [Conc] [Raster] [Phase]    │
├──────────────────────────────────────────────┤
│  ┌────────────────────────────────────────┐  │
│  │ V(t) soma                              │  │
│  │  ╱ ╲    ╱ ╲    ╱ ╲                     │  │
│  │ ╱   ╲__╱   ╲__╱   ╲___                 │  │
│  └────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────┐  │
│  │ V(t) dendrite                          │  │
│  │  __─── attenuated ripples ───___       │  │
│  └────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────┐  │
│  │ [Ca²⁺](t)  ─ échelle log ─             │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  Window: [────●────────────] 200 ms          │
└──────────────────────────────────────────────┘
```

### Caractéristiques

- **Plots empilés verticalement**, chacun avec axe Y propre, échelle
  ajustable (autoscale toggle ou bornes manuelles).
- **Échelle log** disponible (utile pour les concentrations qui varient
  de plusieurs ordres de grandeur).
- **Zoom horizontal commun** à tous les plots empilés (curseur de
  fenêtre temporelle en bas — comme un brush dans D3).
- **Drag-and-drop** : tirer une variable depuis l'inspecteur vers la
  fenêtre Plots → ajoute un nouveau tracé.
- **Onglets** : V(t), Concentrations, Raster (spike times), Phase plot
  (V vs gate, ou V vs [Ca²⁺]).
- **Export** par bouton sur chaque plot : PNG, SVG, CSV.

### Implémentation SwiftUI

```swift
@main
struct NeuroSimApp: App {
    @StateObject private var vm = SimulationViewModel.demoNetwork()

    var body: some Scene {
        WindowGroup("NeuroSim") {           // fenêtre principale
            ContentView().environmentObject(vm)
        }
        WindowGroup("Plots", id: "plots") { // fenêtre flottante
            PlotsWindow().environmentObject(vm)
        }
    }
}
```

Lancement automatique de la fenêtre Plots via `openWindow(id: "plots")`
dans un `onAppear` du `ContentView` au premier affichage.

## Toolbar (haut de la fenêtre principale)

```
[▶ Run] [⏸ Pause] [↺ Reset]   |   Demo: [▼ Thalamic Relay]   |   ⚙
                                                                  ▲
                                          ouvre les Settings ─────┘
```

### Run controls

- **Play/Pause** (`Espace`) — toggle l'intégration
- **Reset** (`⌘R`) — repart de l'état initial
- **Step** (caché derrière `⌘.` ou bouton avancé) — un seul `dt`

### Demo picker

`Picker` SwiftUI qui appelle `vm.loadDemo(.thalamicRelay)` et déclenche
un rebuild du simulator. La liste vient des fabriques de `Demos` (voir
plan d'étape sur les modèles génériques).

### Settings

Sheet ou popover avec :
- `dt` (intégration)
- Facteur temps réel (1× = realtime, 10× = accéléré)
- Température (37 °C / 22 °C / squid 6.3 °C / custom)
- V_rest par défaut
- Choix de l'intégrateur (RK4 / Forward Euler / RK45 plus tard)
- Réinitialisation des positions des fenêtres

## Status bar (bas de la fenêtre principale)

Une ligne fine, monospace, qui affiche en temps réel :

```
t = 124.3 ms · 200 ms/s · 2 spikes · 3 compartments · 12 traces
```

Champs envisagés : temps simulé · vitesse effective (ms simulés / s
réel) · nombre de spikes depuis le dernier reset · nombre de
compartiments actifs · nombre de tracés actifs dans Plots.

## Roadmap d'implémentation

| Step | Description | Charge estimée |
|:----:|:------------|:--------------:|
| 5a | NavigationSplitView 3 colonnes + panneaux rétractables | ~1h |
| 5b | Toolbar avec sélecteur de modèles + run controls étendus | ~30 min |
| 5c | Tool palette gauche + outil sélectionné conditionne canvas | ~1h |
| 5d | Inspecteur contextuel multi-niveau (neurone → compartiment → canal) | ~2h |
| 5e | Fenêtre Plots détachable, lancée au démarrage, avec onglets | ~1h30 |
| 5f | Drag-and-drop variables → plots, zoom synchronisé | ~1h |
| 5g | Plein écran propre, sauvegarde des tailles de panneaux | ~30 min |
| 5h | Status bar live | ~30 min |
| 5i | Settings sheet | ~30 min |

**Total estimé** : ~8h, étalées sur 4-5 sessions de travail.

## Conventions visuelles

- Police : **SF Pro** (système macOS), monospace pour les valeurs
  numériques (latences, voltages, etc.) → **SF Mono**.
- Mode **sombre** par défaut (suit les préférences système).
- Couleur d'accent : à définir, mais quelque chose de neutre style
  cyan/teal pour ne pas concurrencer les couleurs des tracés.
- Couleurs des tracés : palette catégorielle 8-couleurs accessible
  daltoniens (par ex. `Tableau 10` ou `Okabe-Ito`).
- Coins **arrondis 8 px** sur les panneaux et plots.
- Animations subtiles (`spring(duration: 0.25)`) pour
  l'apparition/rétractation des panneaux.

## Décisions à prendre plus tard

- Représentation visuelle d'un neurone multi-compartiment dans le
  canvas : graphe en arbre avec cercles pour les compartiments et
  traits épais pour les couplages axiaux ? Ou icône stylisée
  (silhouette de pyramidal) qu'on peut « déplier » ?
- Granularité du drag-and-drop pour les variables : par compartiment
  (`soma.V`, `dend1.V`, `soma.[Ca²⁺]`) ou par neurone agrégé ?
- Édition collaborative future ? Commentaires sur le réseau ?
  (Hors scope pour l'instant.)

## Notes pour les sessions futures

- Vérifier que `WindowGroup(id:)` se comporte bien sous macOS 14
  (notamment le focus au lancement).
- Les `Toolbar` SwiftUI peuvent être limitantes sur macOS pour
  certaines combinaisons — s'autoriser un `NSToolbar` custom si
  nécessaire (via `NSViewRepresentable`).
- Tester sur écrans de tailles variées (13", 27", multi-écrans).
- Penser accessibilité : labels VoiceOver, raccourcis clavier
  systématiques pour tous les outils.
