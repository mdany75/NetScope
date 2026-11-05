# CLAUDE.md — NetScope

Application macOS native (Swift, SwiftUI, SwiftPM, sans projet Xcode), « l’outil ultime du
technicien réseau » : découverte des appareils sur plusieurs plages, emplacement physique
(switch et port), diagnostic, surveillance, rapports et accès distant. Interface entièrement
en français.

Type de projet : `app-mac`

Ce projet suit le standard commun des projets de Dany (`/standard-projet` le vérifie).

## Commandes

| Action | Commande |
| --- | --- |
| Construire | `./build.sh` (produit `build/NetScope.dmg`) |
| Construire et installer | `./build.sh --install` (remplace aussi `/Applications/NetScope.app`) |
| Tester le moteur | `swift build && ./.build/debug/NetScopeSelfTest` |
| Régénérer la base des fabricants | télécharger `oui.csv`, `mam.csv`, `oui36.csv` (standards-oui.ieee.org) dans un dossier vide, puis `python3 -I scripts/make-oui.py <dossier> Resources/oui.tsv` et `python3 -I scripts/make-oui.py --self-test` |
| Captures hors écran | `./.build/debug/NetScope --snapshot <dossier> --demo` (un PNG 1440 × 900 en clair par écran, aucune fenêtre visible) ; options `--appearance dark\|light` (mode sombre ou clair) et `--size <L>x<H>` (ex. `--size 1000x650` pour la petite fenêtre) |

`build/` et `.build/` sont ignorés par git : rien de compilé n’est commité. Le `.dmg` est une
pièce jointe de la Release ; le README pointe vers `releases/latest/download/NetScope.dmg`.

## Publier une version

Dans cet ordre :

1. Mettre `CFBundleShortVersionString` (et `CFBundleVersion`) à jour dans
   `Resources/Info.plist` et ajouter la section `## X.Y.Z — date` dans `CHANGELOG.md`.
2. `./build.sh` (produit `build/NetScope.dmg`) et
   `swift build && ./.build/debug/NetScopeSelfTest` : tout doit passer avant d’envoyer quoi
   que ce soit.
3. `git status`, puis `git add` des fichiers voulus (pas `git add -A` à l’aveugle),
   `git commit -m "Version X.Y.Z" && git push origin main`
4. `git tag -a vX.Y.Z -m "Version X.Y.Z" && git push origin vX.Y.Z`
5. `NOTES="$(~/.claude/skills/standard-projet/scripts/notes-version.sh X.Y.Z)" && gh release create vX.Y.Z "build/NetScope.dmg" --verify-tag --title "NetScope X.Y.Z" --notes "${NOTES}"`
   (en deux temps : si la section du CHANGELOG manque, rien n’est publié).

## Règles

- Répondre et écrire (commits, README, textes de l’interface, commentaires) en français ;
  typographie française dans l’interface (« guillemets », espace insécable avant « : », « ; »,
  « ? », « ! » et « % »).
- **Ne jamais lancer de scan réseau réel pendant les tests automatiques.** Les tests
  (`NetScopeSelfTest`) et les captures (`--snapshot`) n’envoient rien sur le réseau, sauf
  éventuellement vers 127.0.0.1. Lire l’état local (getifaddrs, NWPathMonitor) est permis.
- Ne pas piloter l’application avec des clics simulés ; vérifier l’interface avec
  `--snapshot <dossier> --demo` et regarder les PNG.
- Les croquis de `docs/croquis/` font foi pour la disposition, la densité, les libellés et les
  données de démonstration : `Main.dc.html` pour le Scanner, `Topologie.dc.html` pour la carte, etc.
  (correspondance dans `Screen.sketchFile`) ; les données viennent de `renderVals()` / `state` des
  croquis. L’habillage, lui, suit macOS : barre latérale et barre d’outils du système, contrôles
  natifs, couleur d’accent du système, mode clair ou sombre automatique (couleurs dynamiques de
  `Theme`, jamais de couleur littérale qui casse en sombre). Vérifier en clair, en sombre et en
  petite fenêtre (`--appearance dark`, `--size 1000x650`).
- Pas de dépendance externe (aucun paquet SwiftPM tiers). Mode de langage Swift 5
  (`swiftLanguageVersions: [.v5]`) ; garder les avertissements de concurrence au minimum.
- `NetScopeCore` n’importe ni SwiftUI ni AppKit (Foundation, Network, Darwin seulement).
- Chaque écran a son propre fichier dans `Sources/NetScope/Screens/` ; chaque module du moteur
  va dans `Sources/NetScopeCore/<Module>/`. L’état partagé passe par `AppState`
  (`@EnvironmentObject`), les composants communs par `Shared/Components.swift` et `Theme`.
- Avant de pousser une fonctionnalité : construction et tests réussis, README et CHANGELOG à
  jour, capture d’écran (`docs/capture.png`, copie de `01-scanner.png` produit par
  `--snapshot … --demo`) refaite si l’interface a changé, captures de `docs/captures/` touchées
  par le changement refaites (mêmes noms, mêmes vues : `NETSCOPE_ECRANS` et les variables
  `NETSCOPE_*` de l’écran, un écran par exécution, sans pastille de mise à jour), et une
  nouvelle version si ce qu’on installe a changé.
- Pousser sur `main` directement ; un commit qui casse se corrige par `git revert`, jamais
  en réécrivant l’historique.

## Organisation

- `Sources/NetScopeCore/` : moteur sans interface ; `Addressing/` (IPv4Address, IPRange,
  Subnet), `Hardware/` (MACAddress, OUIDatabase, OUIRegistry, OUIUpdater), `Models/` (Device, ScanRangeConfig,
  ScanProfile), `System/` (interfaces locales)
- `Sources/NetScope/` : application SwiftUI ; `NetScopeApp.swift` (lancement, `--snapshot`,
  `--demo`), `AppState.swift`, `Screen.swift`, `ContentView.swift`, `Sidebar.swift`,
  `Theme.swift`, `Shared/Components.swift`, `Screens/` (un fichier par écran), `DevTools/`
  (captures, données de démonstration)
- `Sources/NetScopeSelfTest/` : tests du moteur (exécutable, car XCTest n’est pas disponible sans Xcode)
- `scripts/make-icon.swift` : dessine l’icône
- `scripts/make-oui.py` : registre IEEE → `Resources/oui.tsv` ; les règles des noms courts sont
  écrites deux fois (Python et `NetScopeCore/Hardware/OUIRegistry.swift`) : modifier les deux et
  `scripts/oui-name-examples.tsv` ; `NETSCOPE_IEEE_CSV_DIR=<dossier> ./.build/debug/NetScopeSelfTest`
  vérifie que les deux conversions donnent le même fichier
- `Resources/oui.tsv` : base des fabricants (donnée commitée), copiée dans l’app par `build.sh` ;
  `OUIDatabase.builtIn` lit la plus récente (date de l’en-tête) de `~/Library/Application Support/NetScope/oui.tsv`,
  de l’app et du dépôt (à date égale, dans cet ordre), sinon la petite table intégrée
- `Resources/Info.plist` : identité et autorisations (réseau local, Bonjour, localisation)
- `docs/` : `capture.png`, `captures/` (captures de la galerie du README, données de
  démonstration), `analyse-marche.md` (analyse du marché), `croquis/` (quatorze croquis HTML
  et `canvas.json`)
- `build.sh` : construction, signature, image disque, installation
