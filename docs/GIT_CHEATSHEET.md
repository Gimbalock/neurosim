# Git — aide-mémoire pour NeuroSim

Cheatsheet minimaliste, ciblée sur ton usage : un projet en solo, deux Macs
synchronisés via GitHub, des branches occasionnelles pour expérimenter.

## Initialisation (une seule fois, sur la première machine)

```bash
cd "/Users/GwenAir/Documents/Claude/Projects/Développement mac/NeuroSim"
git init
git add .
git commit -m "initial commit"
```

Puis lier à un dépôt GitHub vide créé via l'interface web :

```bash
git remote add origin git@github.com:<ton-user>/neurosim.git
git branch -M main
git push -u origin main
```

## Cloner sur une autre machine

```bash
cd ~/Documents/projets    # ou n'importe quel dossier parent
git clone git@github.com:<ton-user>/neurosim.git
```

## Le cycle quotidien (95 % de ton usage)

```bash
git status                 # qu'est-ce qui a changé ?
git diff                   # qu'est-ce qui a changé, en détail
git add .                  # je sélectionne tout pour le prochain commit
git commit -m "ajout canal Ca-T"   # je prends la photo
```

## Synchroniser entre deux machines

À ouvrir une session :

```bash
git pull                   # récupérer les commits faits depuis l'autre Mac
```

À fermer une session :

```bash
git push                   # envoyer mes commits sur GitHub
```

> **Règle d'or** : `git pull` AVANT de commencer à coder, `git push` APRÈS
> avoir commité. Si tu oublies le pull et que tu commit en parallèle sur les
> deux machines, tu auras un *merge conflict* à résoudre.

## Voir l'historique

```bash
git log --oneline                  # liste compacte
git log --oneline --graph --all    # avec arborescence des branches
git show HEAD                      # dernier commit en détail
```

## Annuler / revenir en arrière

```bash
git restore <fichier>      # annuler les modifications non commitées d'un fichier
git restore .              # tout annuler depuis le dernier commit
git reset HEAD~1           # défaire le dernier commit, garder les modifs
git reset --hard HEAD~1    # défaire le dernier commit ET les modifs (⚠ destructif)
```

## Brancher pour expérimenter

```bash
git checkout -b experiment-noise   # créer + basculer sur une nouvelle branche
# ... tu codes, tu commits ...
git checkout main                  # revenir à la branche stable
git merge experiment-noise         # fusionner si l'expérience était bonne
git branch -d experiment-noise     # supprimer la branche fusionnée

# si l'expérience était mauvaise, juste :
git checkout main
git branch -D experiment-noise     # suppression forcée (les commits sont perdus)
```

## Conflits de fusion

Si `git pull` ou `git merge` te dit qu'un fichier est en conflit :

1. Ouvre le fichier — tu y verras des marqueurs `<<<<<<<`, `=======`, `>>>>>>>`
2. Édite à la main pour garder ce que tu veux, supprime les marqueurs
3. `git add <fichier>`
4. `git commit` (sans `-m`, git te proposera un message tout fait)

## Ce qu'il NE faut PAS commit

Déjà géré par le `.gitignore` du projet :
- `.build/` (caches de compilation Swift)
- `.swiftpm/`, `DerivedData/` (état Xcode local)
- `.DS_Store` (poubelle macOS)
- `*.xcuserstate` (préférences Xcode personnelles)

Si tu ajoutes des fichiers lourds (datasets, vidéos), ajoute-les explicitement
au `.gitignore` avant de commiter.

## Configuration globale (une fois par machine)

```bash
git config --global user.name "Gwen"
git config --global user.email "glmbdx@gmail.com"
git config --global init.defaultBranch main
git config --global pull.rebase false      # merge style, plus simple en solo
```

## Commande de secours

> "Mince, j'ai cassé quelque chose et je ne comprends plus rien."

```bash
git reflog                 # historique de TOUS les états par lesquels tu es passé
                           # (même les commits "perdus" après un reset --hard)
git checkout <hash>        # remonter dans le temps en lecture seule
```

`git reflog` est le filet de sécurité ultime : tant qu'un commit est
référencé là (typiquement 30-90 jours), tu peux le récupérer.
