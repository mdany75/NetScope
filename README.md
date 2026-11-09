# NetScope

**L’outil du technicien réseau, natif sur Mac et en français.** NetScope découvre les appareils
sur plusieurs plages, dit sur quel switch et quel port chacun est branché, puis diagnostique,
surveille, documente et ouvre une session à distance, site par site, dans une seule fenêtre.

[![Version](https://img.shields.io/badge/version-1.7.0-blue)](https://github.com/mdany75/NetScope/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)](#installation)
[![Licence](https://img.shields.io/badge/licence-MIT-green)](LICENSE)

![NetScope : le Scanner avec trois plages, le switch et le port de chaque appareil](docs/captures/01-scanner.png)

[Télécharger NetScope.dmg](https://github.com/mdany75/NetScope/releases/latest/download/NetScope.dmg)
· [Nouveautés](CHANGELOG.md) · [Feuille de route](docs/feuille-de-route.html)

## Pourquoi NetScope

- **« Sur quel port est branché cet appareil ? »** : NetScope répond par SNMP (plusieurs
  marques) et, pour les FortiSwitch, par l’API de la FortiGate, même quand le réseau FortiLink
  n’est pas joignable depuis le Mac. À notre connaissance, aucun autre outil Mac ne le fait.
- **Plusieurs clients sans mélange, sans nuage** : chaque site garde ses plages, sa FortiGate,
  ses switchs, ses résultats et son inventaire, même quand deux sites utilisent les mêmes
  adresses. Tout reste sur le Mac (synchronisation entre tes Mac par iCloud Drive ou un dossier
  partagé, en option), sans abonnement par site.
- **Fortinet en profondeur** : FortiSwitch, bornes FortiAP, liens WAN et VPN, FortiView,
  firmware, licences et journaux, lus par l’API ; seules les actions sur les ports (cycle PoE,
  désactivées par défaut) modifient quelque chose, après confirmation.
- **Une seule fenêtre pour tout le travail** : scan, ping, Wi-Fi, switchs, outils de diagnostic,
  surveillance, rapports PDF, terminal SSH, Telnet et série, VNC et assistance RustDesk, sans
  passer d’une application à l’autre.
- **Sécurité du réseau** : serveur DHCP pirate, conflits d’adresses IP, bornes Wi-Fi pirates,
  certificats TLS, firmware et licences à mettre à jour, sauvegarde des configurations.
- **Même quand l’app est fermée** : un agent en arrière-plan garde les sondes, Syslog, les scans
  planifiés et la mise à jour planifiée du serveur RustDesk.

> **État du projet** : NetScope est stable depuis la 1.0.0 et utilisé sur de vrais réseaux
> (FortiGate, FortiSwitch, FortiAP, SNMP). Les fonctions les plus récentes (onduleurs, bornes
> pirates, test de câble, relevé Wi-Fi sur plan…) attendent encore des essais sur le terrain ;
> voir les limites connues de chaque version dans le [CHANGELOG](CHANGELOG.md).

## Fonctions

### Découverte

- Plusieurs plages IPv4 à la fois (`10.0.0.0/24`, `192.168.1.1-254`, liste…), ping ICMP sans droits
  administrateur, table ARP et 22 ports essentiels sondés à chaque scan ; voisins IPv6 (NDP),
  plages exclues, **scans planifiés** par site et **scan d’un VLAN tagué** depuis le Mac.
- Nom de chaque appareil avec sa source (DNS inverse, mDNS/Bonjour, NetBIOS, sysName SNMP),
  fabricant d’après le registre IEEE complet (environ 53 700 préfixes) et type d’appareil.
- Colonnes **Switch / Port** et **VLAN** remplies seules : découverte SNMP v2c ou v3 des switchs
  pendant le scan, ou FortiSwitch lus par la FortiGate.
- Sites avec leurs plages et leur FortiGate, reconnus par la passerelle ; recherche multiple
  dans tous les modules (`switch:`, `type:`, `ip:`, `vlan:`, `-mot`…).
- **Carte du réseau** hiérarchique (Internet, passerelle, switchs, bornes, groupes d’appareils)
  avec **export de la carte entière** en PNG, PDF, SVG ou draw.io modifiable,
  et **Inventaire** permanent : chronologie des changements d’IP et de port, garantie, pièces
  jointes, étiquettes, import et export CSV ; modèle, numéro de série et
  firmware lus tout seuls (SNMP ENTITY-MIB, sysDescr, FortiGate) ; vues **Imprimantes** (toner
  et consommables) et **Onduleurs** (batterie, autonomie).
- **Historique et adressage** : occupation de chaque plage, changements d’IP, et « Où était cet
  appareil ? » : ports, IP, VLAN et bornes où une adresse MAC a été vue, sur des mois.

### Diagnostic

- **Ping continu** (ICMP, TCP ou HTTP(S)) jusqu’à 64 cibles : statistiques
  (min, moyenne, max, gigue, perte, P95), journal des coupures, vue façon Terminal, traceroute et MTR.
- **Fiche Appareil** : réseau, matériel, emplacement physique, ports et bannières, sonde web,
  notes, **partages SMB** d’un NAS ou d’un poste Windows (par `smbutil`, sur clic), et onglet
  **Ressources** (processeur, mémoire, disques et trafic par SNMP). Onglet **Trafic** : en direct,
  le débit, les destinations, les applications, les sessions et les menaces de cette adresse, lus
  sur la FortiGate de son site, avec un résumé dans l’Aperçu.
  Sans appareil choisi, une fiche s’ouvre par IP, nom ou MAC, et un appareil absent du
  Scanner se saisit à la main.
- **CLI des FortiGate** (facultative, par SSH) : session interactive, extraits de commandes, et
  deux commandes de lecture pour trancher quel appareil a une adresse IP.
- **Bilan de raccordement** en un clic sur une prise : lien, switch et port, VLAN, PoE, DHCP,
  passerelle, DNS et Internet, avec comparaison avant/après ; **Capture LLDP/CDP** du switch,
  du port, du VLAN et du PoE où ce Mac est branché.
- **Test DHCP** sans prendre de bail : chaque serveur qui répond est jugé attendu ou **pirate** ;
  **Conflits d’adresses IP** (même IP sur deux MAC, réponses ARP contradictoires).
- Test MTU réel, traceroute UDP et TCP, empreinte du système et des services, scan de ports UDP,
  vérification des **certificats TLS**, **qualité VoIP** (note MOS des appels captés ou simulés).
- **Journal de l’app** (Réglages › Journal et diagnostic) : erreurs et avertissements de chaque
  module, secrets masqués, et « Exporter un diagnostic… » en .zip à joindre à un signalement.

### Wi-Fi

- Connexion de ce Mac (RSSI, bruit, SNR, canal, débit), réseaux voisins et graphe des canaux
  2,4, 5 et 6 GHz, avec recommandations.
- **Bornes FortiAP** de chaque site : état, radios, clients, SSID, AP voisins ou non autorisés ;
  onglet **Pirates** (sosies de tes SSID, bornes inconnues branchées sur un port de switch).
- **Relevé sur plan** : plan d’étage importé, mesures en marchant, carte de chaleur, zones
  mortes, chevauchements de canaux et emplacement suggéré d’une borne.
- **« Diagnostiquer »** un client, une borne ou un SSID : signal, canal, interférences, charge,
  authentification, DHCP, puis les actions à faire dans l’ordre.

### Switchs et Fortinet

- Plusieurs FortiGate, une par site, chacune avec son jeton au Trousseau.
- FortiSwitch gérés par FortiLink dans Switchs et ports et dans le Scanner ; autres switchs
  relus en SNMP v2c ou v3 (utilisateur v3 par site, mots de passe au Trousseau).
- **Graphe du trafic de chaque port** sur 1 h, 24 h, 7 jours ou 30 jours (débits maximal et
  moyen, pourcentage du lien, erreurs par heure), historique gardé par site jusqu’à 90 jours.
- **Cycle PoE d’un port** (et « Redémarrer le port » sur un FortiSwitch) pour relancer un
  téléphone IP, une borne ou une caméra figés : désactivé par défaut, confirmation qui nomme
  l’appareil, uplinks refusés, suivi du retour de l’appareil.
- Outil **WAN et VPN** : liens WAN et SD-WAN (latence, gigue, perte, SLA), tunnels IPsec,
  utilisateurs VPN SSL, pour un site ou tous.
- **Firmware et licences** : versions FortiOS, FortiSwitch et FortiAP, licences FortiGuard et
  FortiCare avec alerte avant l’expiration.
- **Étendues DHCP** de la FortiGate, avec leur taux d’occupation.
- **Configurations** : sauvegarde de la FortiGate (API) et des switchs (SSH, commandes de lecture
  seulement), historique et comparaison avant/après, secrets masqués.
- **Test de câble** demandé au switch (TDR) : état de chaque paire et distance du défaut ;
  désactivé par défaut, avec confirmation.
- Contrôleurs **UniFi, Omada et Meraki** en lecture seule.

### Suivi

- **Surveillance** : sondes ping, TCP, HTTP(S) (certificat, mot-clé), DNS, SNMP, port de switch,
  nouveaux appareils, licences et plus, avec seuils, plages horaires et dépendances ;
  disponibilité sur 24 h et icône dans la barre des menus ; aussi DHCP pirate, conflit d’IP,
  borne pirate, consommable d’imprimante bas, onduleur et serveur RustDesk. Un **agent** les
  garde actives quand l’app est fermée (désactivé par défaut).
- Alertes par notification macOS, courriel, webhook (Teams, Slack, JSON) ou sur téléphone par
  ntfy et Pushover, avec un filtre par canal.
- **Journaux** : récepteur Syslog et traps SNMP sur ce Mac, journaux d’événements de la
  FortiGate et « Comprendre une coupure ».
- **Trafic** lu par FortiView (sources, applications, destinations, menaces), « Qui sature le
  lien ? » et « Bilan de santé » noté sur 100 ; sans FortiView, trafic des ports relevé sur les
  switchs ou **flux NetFlow, sFlow et IPFIX** reçus de toute marque (collecteur démarré sur
  clic, guide de configuration par marque).

### Accès distant

- Carnet de connexions par site (SSH, Telnet, série, RDP, VNC, FTP, FTPS, SFTP), rempli depuis
  le scan.
- **Terminal intégré en onglets** pour SSH, Telnet et la console série : empreinte SSH à
  approuver, mots de passe au Trousseau, journal de session, extraits de commandes Cisco,
  FortiGate, Aruba et Linux.
- **Session VNC intégrée** : qualité adaptative, mise à l’échelle, plein écran, Ctrl-Alt-Suppr,
  observation seule, presse-papiers texte. RDP s’ouvre dans Windows App.
- Navigateur de fichiers en deux volets (FTP, FTPS, SFTP) et serveur FTP temporaire.
- **Assistance RustDesk** dans son propre onglet : ID de l’usager, ajout au carnet, lien
  d’assistance à copier et historique complet des sessions (recherche, reconnexion).
- **Serveur RustDesk** auto-hébergé (lu par SSH) : sessions relayées, santé, mises à jour de
  RustDesk et du système, clé publique et sauvegarde de la clé et de la base, historique et
  rapport mensuel, tentatives suspectes, journaux, nom et note par ID, ID associé à la MAC du
  poste ; « Déconnecter » une session, mise à jour (avec retour arrière) et mise à jour
  planifiée la nuit, toujours avec confirmation.
- **Serveur WireGuard** (wg-easy 15, sur le même serveur) : clients connectés, débit et graphe
  des six dernières heures, expirations, état du conteneur et journaux (lus par SSH, clés
  masquées) ; ajouter un client (.conf, code QR, lien à usage unique), activer, désactiver,
  renommer ou supprimer par l’API de wg-easy, avec confirmation et retour arrière ; mise à jour
  de l’image avec retour arrière. Lecture seule si le 2FA est actif ou si wg-easy 14 est trouvé.
  À l’ajout d’un client : IP autorisées, keepalive et brouillon de courriel avec les liens de
  WireGuard, le fichier du tunnel et son code QR (rien ne part sans votre clic sur Envoyer).
- Extraits personnalisés et **envoi d’une commande à plusieurs sessions**, avec confirmation.

### Rapports

- Rapport client en **PDF** (format lettre, pagination, signature), quatre modèles et des
  sections tirées du scan, de l’inventaire, des switchs, du Wi-Fi, de la carte du réseau, des
  pirates et conflits, des imprimantes, des onduleurs, de la VoIP et du relevé Wi-Fi sur plan.
- Exports CSV, JSON et HTML ; brouillon Mail avec le PDF joint.
- Section « Depuis le dernier rapport », rapports passés par site et rapports planifiés
  (chaque jour, semaine ou mois, quand NetScope est ouvert).

### Boîte à outils

- Calculateur de sous-réseaux avec découpage, convertisseur MAC/OUI, scan de ports, Wake-on-LAN.
- DNS complet (comparaison, propagation, DNSSEC), Whois et un outil **Courriel** à onglets
  (santé d’un domaine sur 100, MX, listes noires, SPF/DKIM/DMARC, diagnostic SMTP, en-têtes).
- **Navigateur SNMP** : GET, GETNEXT et parcours d’un OID en v2c ou v3, tables courantes
  nommées, export CSV.
- **Speedtest** (Cloudflare, M-Lab, LibreSpeed ; Ookla en option) et iperf3 ; **État des services** en
  ligne (Microsoft 365, Apple, AWS, Google…).
- **Capture de paquets** (filtres, détail par couche, suivi de flux, .pcap), serveur et client
  **TFTP**, **Vitesse des disques** (local, NAS, partage réseau).
- **Test NTP** (décalage de l’horloge, strate), **Testeur HTTP ou API** (requête libre, corps,
  redirections, minutages), **Test RADIUS** (essai PAP, secret au Trousseau), **Navigateur
  Bonjour** et **Table de routage** de ce Mac.

## Captures

Toutes les captures utilisent les données de démonstration (`--demo`) ; aucune ne montre un
vrai réseau.

| | |
| --- | --- |
| ![Scanner](docs/captures/01-scanner.png) | ![Carte du réseau](docs/captures/02-carte.png) |
| **Scanner** : trois plages, 21 appareils avec switch, port et VLAN, fiche de l’imprimante. | **Carte du réseau** : de l’Internet aux groupes d’appareils, avec le conflit IP signalé. |
| ![Inventaire](docs/captures/03-inventaire.png) | ![Fiche Appareil](docs/captures/04-appareil-apercu.png) |
| **Inventaire** : appareils connus, favoris, alertes et chronologie d’un appareil. | **Fiche Appareil** : réseau, matériel, emplacement (switch et port), services. |
| ![Ressources](docs/captures/05-appareil-ressources.png) | ![Ping continu](docs/captures/06-ping-terminal.png) |
| **Ressources** : jauges processeur et mémoire, courbes sur 5 minutes, trafic d’interface. | **Ping continu** : six cibles, une carte retournée en vue Terminal, MTR et journal. |
| ![Switchs et ports](docs/captures/07-switchs.png) | ![Wi-Fi FortiAP](docs/captures/08-wifi-fortiap.png) |
| **Switchs et ports** : « Ce Mac est branché sur… » et les switchs avec leur budget PoE. | **Wi-Fi, FortiAP** : bornes, clients par radio et conseils (AP non autorisé, canaux). |
| ![Firmware et licences](docs/captures/09-outils-firmware.png) | ![Étendues DHCP](docs/captures/10-outils-dhcp.png) |
| **Firmware et licences** : versions Fortinet et licence qui expire bientôt. | **Étendues DHCP** : occupation de chaque étendue, avec une étendue critique. |
| ![Surveillance](docs/captures/11-surveillance.png) | ![Journaux et traps](docs/captures/12-journaux.png) |
| **Surveillance** : sondes avec disponibilité sur 24 h, éditeur de sonde, alertes. | **Journaux et traps** : Syslog, traps et FortiGate regroupés. |
| ![Analyse du trafic](docs/captures/13-trafic-analyse.png) | ![Rapports](docs/captures/14-rapports.png) |
| **Trafic, analyse complète** : note sur 100 et constats classés. | **Rapports** : modèle, choix des sections et aperçu du PDF. |
| ![Terminal SSH](docs/captures/15-acces-terminal.png) | ![Session VNC](docs/captures/16-acces-vnc.png) |
| **Terminal SSH intégré** : sortie en couleurs, extraits de commandes, onglets. | **Session VNC intégrée** : bureau distant, qualité et mise à l’échelle. |
| ![Journal et diagnostic](docs/captures/17-reglages-journal.png) | |
| **Journal et diagnostic** : erreurs des modules, secrets masqués, export .zip à joindre. | |
| ![Scanner en mode sombre](docs/captures/20-scanner-sombre.png) | ![Carte en mode sombre](docs/captures/21-carte-sombre.png) |
| **Mode sombre** : le Scanner. | **Mode sombre** : la Carte du réseau. |
| ![Terminal en mode sombre](docs/captures/22-acces-terminal-sombre.png) | |
| **Mode sombre** : le terminal SSH. | |

## Installation

Télécharge [NetScope.dmg](https://github.com/mdany75/NetScope/releases/latest/download/NetScope.dmg)
(toujours la dernière version), ouvre-le et glisse NetScope dans Applications. Les mises à jour
suivantes arrivent par le menu « Rechercher les mises à jour… » (canal Stable ou Bêta, signature
vérifiée avant l’installation).

**Configuration requise** : macOS 14 (Sonoma) ou plus récent.

**Autorisations demandées par macOS** :

- l’accès au réseau local, au premier scan ;
- la localisation, pour lire le nom des réseaux Wi-Fi (bouton « Autoriser la localisation » de
  l’écran Wi-Fi) ;
- les notifications, pour la Surveillance ;
- l’Accessibilité, pour ouvrir Partage d’écran (app d’Apple) en plein écran ; la session VNC
  intégrée n’en a pas besoin ;
- l’accès BPF (ChmodBPF de Wireshark) ou l’autorisation d’administrateur, pour la capture
  LLDP/CDP et la capture de paquets.

## Démarrage rapide

1. **Premier scan** : au premier lancement, la plage proposée est celle du réseau de
   l’interface active. Clique sur Scanner : ping, table ARP, noms et ports, switchs (SNMP),
   puis emplacements s’affichent au fur et à mesure.
2. **Sites** : crée un site par client ou par lieu (sous le logo NetScope, ou ⌘⇧S), avec ses
   plages. NetScope le reconnaît ensuite par sa passerelle et garde ses résultats à part.
3. **FortiGate en lecture seule** : dans Réglages › Switchs › Contrôleurs FortiGate, ajoute la
   FortiGate du site avec un jeton d’API. L’aide de l’écran explique comment créer un
   administrateur API en lecture seule. FortiSwitch, FortiAP, WAN, trafic et firmware se
   remplissent alors seuls. Seules les actions sur les ports (cycle PoE, désactivées par
   défaut) demandent « WiFi & Switch Controller » en lecture-écriture.

## Confidentialité et sécurité

- **Secrets au Trousseau** : jetons FortiGate et mots de passe des connexions sont rangés
  dans le Trousseau de macOS. Les sauvegardes et exports qui incluent un
  secret sont chiffrés (AES-GCM 256 bits).
- **Lecture seule par défaut** : NetScope lit la FortiGate par son API et ne modifie rien.
  Les rares actions (cycle PoE, test de câble, actions sur les serveurs RustDesk et WireGuard) sont
  désactivées par défaut ou demandent une confirmation. L’empreinte du certificat de la
  FortiGate est acceptée une fois, de façon explicite.
- **Rien n’est envoyé sans toi** : pas de compte, pas de serveur NetScope, pas de télémétrie ;
  la synchronisation (iCloud Drive, OneDrive ou NAS) et les alertes par courriel, webhook, ntfy
  ou Pushover ne fonctionnent que si tu les actives. Le scan reste sur les plages choisies, la découverte
  SNMP ne vise que des adresses privées, les rapports partent en brouillon Mail et la base des
  fabricants se met à jour une fois par mois (désactivable). La vérification des mises à jour (GitHub) se
  désactive dans Réglages.
- Chaque nouvelle empreinte SSH est montrée avant la connexion, pour que tu l’approuves.

## Feuille de route

La feuille de route complète est dans [docs/feuille-de-route.html](docs/feuille-de-route.html),
et le détail des notes dans [docs/A-FAIRE.md](docs/A-FAIRE.md). Tout ce qui était prévu est
livré jusqu’à la 1.2 ; il reste l’interface en anglais, plus tard. L’historique de chaque
version est dans le [CHANGELOG](CHANGELOG.md).

## Construire depuis les sources

Il faut les outils de ligne de commande Xcode (Swift 6 ou plus récent). Aucune dépendance
externe, aucun projet Xcode : tout passe par SwiftPM.

```bash
./build.sh            # produit build/NetScope.dmg
./build.sh --install  # remplace aussi /Applications/NetScope.app
```

### Tests

```bash
swift build && ./.build/debug/NetScopeSelfTest
```

Les tests portent sur le moteur (adresses, plages, sous-réseaux, MAC, fabricants, scan, ping,
SNMP, DNS et courriel, Fortinet (FortiSwitch, FortiAP, WAN, firmware, trafic), journaux, sites,
inventaire, sauvegarde chiffrée, mise à jour, Speedtest, accès distant (terminal, VNC, transferts
de fichiers, TFTP), DHCP, LLDP/CDP, capture de paquets, surveillance, rapports). Ils n’envoient rien sur le réseau, sauf éventuellement vers 127.0.0.1.

### Captures

Une capture de chaque écran, hors écran, avec les données de démonstration :

```bash
swift build && ./.build/debug/NetScope --snapshot /tmp/netscope-snap --demo
# options : --appearance dark|light, --size 1000x650
```

### Organisation

- `Sources/NetScopeCore/` : moteur réseau sans interface (Foundation, Network, Darwin), un
  dossier par module (`Addressing/`, `Hardware/`, `Models/`, `System/`…)
- `Sources/NetScope/` : application SwiftUI ; `Theme.swift`, `Sidebar.swift`, `AppState.swift`,
  `Shared/Components.swift`, un fichier par écran dans `Screens/`, outils de développement dans
  `DevTools/` (captures, démonstration)
- `Sources/NetScopeSelfTest/` : tests du moteur (exécutable, sans XCTest)
- `scripts/make-icon.swift` : dessine l’icône
- `scripts/make-oui.py` : convertit le registre IEEE (oui.csv, mam.csv, oui36.csv) en
  `Resources/oui.tsv` ; ses règles de noms courts sont aussi écrites en Swift
  (`OUIRegistry.swift`) et vérifiées sur les mêmes exemples (`scripts/oui-name-examples.tsv`)
- `Resources/oui.tsv` : base des fabricants, copiée dans l’application par `build.sh`
- `Resources/Info.plist` : identité de l’application et autorisations
- `docs/captures/` : captures de la galerie ; `docs/croquis/` : croquis de conception des écrans
- `build.sh` : construction, signature, image disque, installation

## Licence

NetScope est distribué sous [licence MIT](LICENSE). © 2026 Dany Ménard.
