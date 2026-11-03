# Standard des projets de Dany (mdany75)

Un seul standard pour tous les projets, quel que soit leur type (application Mac en Swift,
script shell ou PowerShell, site web). Il décrit ce qu'on trouve sur GitHub, sur le Mac, et
la façon de travailler. La commande `/standard-projet` vérifie et corrige un projet.

## 1. Sur GitHub

- Un dépôt par projet, chez `mdany75`. Le nom du dépôt est celui du dossier local.
- Branche principale `main`, seule branche tant qu'on travaille seul.
- Description renseignée : une phrase complète en français qui dit ce que fait le projet.
  Sujets (*topics*) renseignés : `macos`, `swift`, `powershell`, `fujifilm`…
- Fichiers obligatoires à la racine : `README.md`, `CHANGELOG.md`, `CLAUDE.md`,
  `.gitignore`, `.editorconfig`. `LICENSE` (MIT) sur les dépôts publics.
- **Jamais de fichiers produits dans git** : pas de `.app`, `.dmg`, `.zip`, `.pkg`,
  `.exe`, ni de dossier `build/`, `dist/`, `.build/`. Ils vont dans une *Release*.
- **Jamais de secrets dans git** : ni certificat ni clé de signature ou de notarisation
  (`.p8`, `.p12`, `.pem`, `.cer`, profils), ni `.env`, ni `CLAUDE.local.md` (notes
  personnelles de Claude Code). Le `.gitignore` commun les exclut.
- **Versions** : tag `vX.Y` (ou `vX.Y.Z` quand il y a un correctif) sur le commit publié,
  et *Release* GitHub du même nom. Le même numéro est écrit dans le projet (`Info.plist`,
  `VERSION=` ou `# Version :` en tête d'un script…). On ne retagge jamais une version déjà
  publiée : une erreur se corrige par la version suivante.
- Ce que contient la Release, selon le type (voir §3) : le `.dmg` (app-mac), le `.zip`
  notarisé (outil avec `build.sh`), l'archive ou le script (shell, PowerShell), ou rien
  (site, outil sans `build.sh`) ; les notes de la Release sont la section de cette version dans
  `CHANGELOG.md`, pas le fichier entier.
- Le fichier joint garde le même nom d'une version à l'autre. Le README pointe vers
  `https://github.com/mdany75/<Nom>/releases/latest/download/<Fichier>` : l'adresse ne
  change jamais et donne toujours la dernière version. GitHub remplace les espaces du nom
  par des points dans l'adresse (`Transfert Infuse.dmg` → `Transfert.Infuse.dmg`). Sur un
  dépôt privé, ce lien demande d'être connecté à GitHub.
- La capture d'écran principale du README est `docs/capture.png`.

## 2. Sur le Mac

- Tous les projets dans `~/Developer/<NomDuDépôt>` (directement, pas dans un sous-dossier),
  un dossier par dépôt, clone de GitHub. **Jamais dans iCloud Drive, Documents ou le
  Bureau** : iCloud ajoute des attributs qui font échouer la signature des applications et
  peut abîmer le dossier `.git`. GitHub est la sauvegarde ; le dossier local peut être
  recloné à tout moment.
- `.git` est un vrai dossier (pas l'astuce `.git.nosync`, qui ne servait que dans iCloud).
- Identité git : `mdany75` / `328797345+mdany75@users.noreply.github.com` (réglée en
  global une fois ; un projet qui en diverge la règle pour lui seul).

## 3. Arborescence

```
NomDuProjet/
├── README.md        présentation, capture, Fonctions, Installer, Reconstruire, Tests, Organisation
├── CHANGELOG.md     une section par version, la plus récente en premier
├── CLAUDE.md        règles du projet pour Claude Code (voir modèle)
├── LICENSE          dépôts publics seulement
├── .gitignore       commun à tous les projets (voir modèle)
├── .editorconfig    commun à tous les projets
├── build.sh         point d'entrée de construction (quand il y a quelque chose à produire)
├── scripts/         autres scripts (icône, outils, exports…), en minuscules
├── docs/            capture.png, cahier des charges (SPEC.md), guides écrits à la main
├── Sources/, Tests/ code et tests (projets Swift ; absents d'un script ou d'un site)
├── Resources/       Info.plist, icône, fichiers embarqués
└── build/           tout ce qui est produit ; ignoré par git en entier
```

Adaptations par type. Le type est écrit dans `CLAUDE.md` (ligne
« Type de projet : `outil` ») : le vérificateur le lit, et ne le devine qu'à défaut.

| Type | Comment le deviner si `CLAUDE.md` ne le dit pas | Particularités |
| --- | --- | --- |
| `app-mac` : application Mac (Swift, SwiftPM ou `swiftc` direct, sans Xcode) | tout projet Swift (`Package.swift`, ou `Resources/Info.plist` avec des `Sources/*.swift`) qui n'est pas un `outil` | `build.sh` compile, signe avec le certificat « Developer ID Application » (ad hoc s'il manque), produit `build/<Nom>.dmg` et le notarise chez Apple (profil `notarisation` de `notarytool`) ; `build.sh --install` installe aussi dans `/Applications`. Une Release ne contient qu'un `.dmg` notarisé. Le `.dmg` est la pièce jointe de la Release. `docs/capture.png` montre la fenêtre réelle. |
| `outil` : outil Swift sans fenêtre (ligne de commande, serveur MCP, module d'une autre app) | projet Swift dont `build.sh` produit un `.zip`, ou sans `build.sh` ni `Resources/Info.plist` | `build.sh` compile, signe avec Developer ID et produit `build/<Nom>.zip`, notarisé (un `.zip` ne peut pas être agrafé : macOS vérifie en ligne au premier lancement). Le `.zip` est la pièce jointe de la Release. Sans `build.sh`, il se construit depuis les sources (`swift build -c release`) et la Release n'a pas de pièce jointe. |
| `powershell` ou `shell` : script | `powershell` : un `*.ps1` à la racine (même avec un `index.html`). `shell` : un `install.sh`, ou un `*.sh` principal à la racine autre que `build.sh`, `install.sh`, `uninstall.sh`, et pas d'`index.html` | Le script principal à la racine, `install.sh` / `uninstall.sh` si besoin. Pas de compilation : s'il y a plusieurs fichiers à installer, `build.sh` produit l'archive `build/<nom>.zip` (scripts, gabarits, README) qui est la pièce jointe de la Release ; un script seul est joint tel quel. Un `.ps1` qui contient des accents est en UTF-8 **avec BOM** et fins de ligne CRLF : sans BOM, Windows PowerShell 5.1 le lit en ANSI et casse les accents. |
| `site` : site ou page web (GitHub Pages) | `index.html` à la racine | Ressources à côté, `docs/` pour les captures, Pages activé sur `main`. Un tag et une Release **sans pièce jointe** à chaque mise en ligne notable (les notes = le CHANGELOG). |
| `autre` : tout le reste (mod de Claude Code, pages HTML construites par `build.sh`…) | rien de ce qui précède | Release avec pièce jointe s'il y a un `build.sh` ou un `install.sh`, sinon sans. Décrire dans le README et le CLAUDE.md ce qui s'installe et comment. |

Documents dérivés (PDF, guide imprimable) : soit produits par un script de `scripts/` et
publiés en Release, jamais commités ; soit écrits à la main dans `docs/` et mis à jour dans
le même envoi que le README. Un document ne recopie jamais un script : il renvoie au dépôt.

## 4. README.md : sections, dans cet ordre

1. Titre = nom du projet, puis une ou deux phrases qui disent ce que c'est et pour qui.
2. Capture d'écran `docs/capture.png` pour tout ce qui a une interface.
3. `## Fonctions` : liste à puces, une fonction par puce, du point de vue de l'utilisateur.
4. `## Installer` : lien `releases/latest/download/…`, étapes, configuration requise
   (macOS 14…), autorisations demandées au premier lancement.
5. `## Reconstruire` (obligatoire s'il y a un `build.sh`) : outils nécessaires, la commande,
   ce qu'elle produit.
6. `## Tests` (obligatoire s'il y a un dossier `Tests/`) : la commande autonome, et ce que
   les tests ne touchent jamais.
7. `## Organisation` : les dossiers et leur rôle.

## 5. CHANGELOG.md

```
# Changements

## 1.1 — 2026-10-12
### Ajouté
- …
### Modifié
- …
### Corrigé
- …

## 1.0 — 2026-10-05
Première version publiée.
```

Numéros : `MAJEUR.MINEUR[.CORRECTIF]`. Nouvelle fonction → MINEUR ; correction seule →
CORRECTIF ; changement qui casse les habitudes → MAJEUR. Le même numéro est dans le projet,
dans le tag et dans la Release.

## 6. CLAUDE.md

Court, en français, et vrai : ce qu'un nouveau venu (ou Claude) doit savoir pour
travailler sans casser le projet. Sections : but du projet, ligne « Type de projet : `…` »
(un des types du §3), commandes (construire, tester,
publier, dans l'ordre exact), où vont les fichiers produits, règles à ne jamais enfreindre
(par exemple « ne jamais écrire sous /Volumes »), façon de livrer (README + CHANGELOG +
capture si interface + Release dans le même envoi), langue et ton. Modèle : `assets/CLAUDE.md`.

## 7. Façon de travailler

- Commits en français, un par fonctionnalité : la première ligne dit *quoi*, le corps dit
  *pourquoi* quand ce n'est pas évident.
- Chaque fonctionnalité envoyée sur GitHub part avec son README, son CHANGELOG, sa capture
  d'écran (si interface) et, si ce qu'on installe a changé, une nouvelle version : numéro +
  CHANGELOG → construire et tester → commit → `git push origin main` → tag →
  `git push origin vX.Y` → `gh release create --verify-tag`.
- Rien n'est poussé sans que la construction et les tests passent : c'est la condition du
  travail directement sur `main` (*trunk-based development*). Relire `git status` et ajouter
  les fichiers voulus plutôt que `git add -A` à l'aveugle.
- Pousser sur `main` directement ; pas de branches tant qu'on est seul. Un commit qui casse
  se corrige par `git revert`, jamais en réécrivant l'historique.
- Un nouveau projet démarre du dépôt modèle, depuis `~/Developer` :
  `gh repo create mdany75/<Nom> --template mdany75/modele-projet --private --clone`.
- `/standard-projet` dans la session d'un projet vérifie tout cela et corrige ce qui manque.
