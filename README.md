# NetScope

Application macOS native pour le technicien réseau : découverte des appareils sur plusieurs
plages, emplacement physique (switch et port), diagnostic (ping continu, Wi-Fi, outils),
surveillance, rapports et accès distant, le tout en français.

![NetScope](docs/capture.png)

## Fonctions

Version 0.1.0 : les fondations. Les écrans existent et affichent ce qu’ils feront ; le moteur
d’adressage est en place et testé.

- Barre latérale à quatorze écrans : Scanner, Carte du réseau, Inventaire, Appareil, Ping
  continu, Switchs et ports, Wi-Fi, Outils, Surveillance, Analyse, Rapports, Accès distant,
  Speedtest et Réglages.
- Interface active affichée en bas de la barre latérale (« en0 · 10.182.122.135 · Wi-Fi »),
  avec la version et une pastille quand une mise à jour est disponible.
- Recherche globale par IP, MAC, nom, fabricant ou port de switch.
- Plages à scanner sous toutes les formes courantes : `10.182.122.0/24`, `192.168.1.1-254`,
  `10.10.0.1-10.10.0.50`, `10.0.0.5`, ou une liste ; limite de sécurité de 65 536 adresses.
- Calculateur de sous-réseaux : réseau, masque, masque inverse, broadcast, premier et dernier
  hôte, nombre d’hôtes, classe, privé ou public, masque en binaire, découpage.
- Fabricant d’après l’adresse MAC (table intégrée d’environ 230 préfixes courants) et
  reconnaissance des adresses MAC privées (aléatoires).
- Au premier lancement, la plage proposée est celle du réseau de l’interface active.
- Plages enregistrées et noms personnalisés conservés d’un lancement à l’autre.

## Installer

Télécharge [NetScope.dmg](https://github.com/mdany75/NetScope/releases/latest/download/NetScope.dmg)
(toujours la dernière version), ouvre-le et glisse NetScope dans Applications.

Configuration requise : macOS 14 ou plus récent. Au premier scan, macOS demande l’accès au
réseau local ; pour lire le nom des réseaux Wi-Fi, il demande aussi la localisation.

## Reconstruire

Outils de ligne de commande Xcode (Swift 6 ou plus récent). Aucune dépendance externe.

```bash
./build.sh            # produit build/NetScope.dmg
./build.sh --install  # remplace aussi /Applications/NetScope.app
```

Captures de chaque écran, hors écran, avec les données de démonstration des croquis :

```bash
swift build && ./.build/debug/NetScope --snapshot /tmp/netscope-snap --demo
```

## Tests

```bash
swift build && ./.build/debug/NetScopeSelfTest
```

Les tests portent sur le moteur (adresses, plages, sous-réseaux, MAC, fabricants, modèles). Ils
n’envoient rien sur le réseau : aucun scan, aucune requête, sauf éventuellement vers 127.0.0.1.

## Organisation

- `Sources/NetScopeCore/` : moteur réseau sans interface (Foundation, Network, Darwin), un
  dossier par module (`Addressing/`, `Hardware/`, `Models/`, `System/`…)
- `Sources/NetScope/` : application SwiftUI ; `Theme.swift`, `Sidebar.swift`, `AppState.swift`,
  `Shared/Components.swift`, un fichier par écran dans `Screens/`, outils de développement dans
  `DevTools/` (captures, démonstration)
- `Sources/NetScopeSelfTest/` : tests du moteur (exécutable, sans XCTest)
- `scripts/make-icon.swift` : dessine l’icône (radar bleu sur fond bleu nuit)
- `Resources/Info.plist` : identité de l’application et autorisations (réseau local, Bonjour, localisation)
- `docs/capture.png` : capture de la fenêtre
- `docs/croquis/` : croquis de conception des quatorze écrans (`Main.dc.html` pour le Scanner,
  `Ping.dc.html`, `Switch.dc.html`…, et `canvas.json` qui les assemble) ; ils font foi pour la
  disposition, les couleurs, la densité et les libellés
- `build.sh` : construction, signature, image disque, installation
