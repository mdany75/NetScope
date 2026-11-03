# NetScope

Application macOS native pour le technicien réseau : découverte des appareils sur plusieurs
plages, emplacement physique (switch et port), diagnostic (ping continu, Wi-Fi, outils),
surveillance, rapports et accès distant, le tout en français.

![NetScope](docs/capture.png)

## Fonctions

Version 0.2.0 : douze écrans sur quatorze fonctionnent ; Surveillance et Rapports sont encore
en construction.

- **Scanner multi-plages qui se remplit tout seul** : plusieurs plages à la fois, ping ICMP
  sans droits administrateur, table ARP, noms d’hôte (DNS inverse, mDNS/Bonjour, NetBIOS,
  sysName SNMP, avec leur source), 20 ports essentiels sondés à chaque scan, fabricant, type
  d’appareil ; étapes visibles (Ping → Table ARP → Noms et ports → Switchs (SNMP) →
  Emplacements), filtres, tri, panneau de détail, export CSV.
- **Découverte automatique des switchs** (activée par défaut) : à la fin de chaque scan,
  NetScope interroge en SNMP v2c lecture seule les appareils en ligne (communauté des
  Identifiants, puis « public » ou la liste de Réglages › Switchs), ajoute les switchs qui
  répondent, relève leurs tables MAC, complète les MAC des autres VLAN par l’ARP SNMP de la
  passerelle et des switchs de niveau 3, puis remplit les colonnes **Switch / Port** et
  **VLAN** de chaque appareil.
- **Ping continu** multi-cibles (intervalle, taille de paquet pour le test MTU), statistiques
  (min, moyenne, max, gigue, perte, P95), graphes, journal des coupures, **traceroute et MTR**.
- **Switchs et ports** : client SNMP v2c intégré (table MAC BRIDGE-MIB / Q-BRIDGE-MIB, LLDP,
  interfaces, PoE) pour savoir **sur quel port de quel switch** chaque appareil est branché ;
  switchs découverts automatiquement ou ajoutés à la main, façade du switch dessinée,
  recherche par IP ou MAC.
- **Wi-Fi** : connexion actuelle (RSSI, bruit, SNR, canal, débit), analyse des réseaux
  voisins, graphe des canaux 2,4 / 5 / 6 GHz, recommandations.
- **Fiche appareil** : réseau, matériel, emplacement physique, ports et services avec
  bannières, sonde web, notes.
- **Boîte à outils** : calculateur de sous-réseaux avec découpage, convertisseur MAC/OUI,
  scan de ports, DNS (A, AAAA, MX, PTR, TXT, NS, CNAME), Whois, Wake-on-LAN.
- **Inventaire permanent** : tous les appareils jamais vus, champs éditables (local, prise,
  responsable…), chronologie des changements (IP, port de switch, hors ligne), import et
  export CSV.
- **Analyse** : indicateurs, carte d’occupation de la plage, répartition par fabricant et par
  type, alertes (nouvel appareil, conflit IP…), comparaison de deux scans.
- **Carte du réseau** construite à partir du scan (passerelle, switchs, groupes d’appareils).
- **Accès distant** : connexions SSH, Telnet, console série, RDP et VNC enregistrées par site,
  ouvertes dans Terminal, Windows App ou Partage d’écran ; import depuis le scan.
- **Speedtest** : débit Internet (multi-flux, latence au repos et en charge, gigue),
  débit local avec iperf3, historique.
- **Mise à jour automatique** depuis les Releases GitHub (canal Stable ou Bêta, vérification
  de la signature avant installation), menu « Rechercher les mises à jour… ».
- Barre latérale à quatorze écrans, fidèle aux croquis.
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

Les tests portent sur le moteur (adresses, plages, sous-réseaux, MAC, fabricants, scan, ping, SNMP, DNS, mise à jour, inventaire, Speedtest, accès distant). Ils
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
