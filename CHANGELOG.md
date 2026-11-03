# Changements

## 0.1.0 — 2026-11-03

Première version publiée.

### Ajouté
- Scanner multi-plages : ping ICMP non privilégié, table ARP, DNS inverse, ports courants,
  fabricant et type d’appareil ; filtres, tri, panneau de détail, export CSV protégé contre
  les formules.
- Ping continu multi-cibles avec statistiques, graphes et journal ; traceroute et MTR.
- Switchs et ports : client SNMP v2c, table MAC, voisins LLDP, PoE, façade du switch et
  localisation d’un appareil par IP ou MAC.
- Analyseur Wi-Fi (CoreWLAN) : connexion actuelle, réseaux voisins, canaux, recommandations.
- Fiche appareil et boîte à outils : calculateur de sous-réseaux, MAC/OUI, scan de ports,
  DNS, Whois, Wake-on-LAN, sonde web.
- Inventaire permanent avec chronologie des changements, Analyse (occupation, répartition,
  alertes, comparaison de scans) et Carte du réseau.
- Accès distant (SSH, Telnet, série, RDP, VNC) et Speedtest (Internet et iperf3).
- Réglages : sites et plages, profils de scan, identifiants SNMP au Trousseau, interface
  réseau, mise à jour automatique depuis les Releases GitHub.
- Fenêtre principale (1440 × 900 par défaut, 1100 × 700 au minimum), interface claire.
- Barre latérale bleu nuit fidèle aux croquis : groupes Découverte, Diagnostic, Suivi et
  Accès, plages enregistrées, Réglages, interface active, version et pastille de mise à jour.
- Barre d’outils du contenu : titre de l’écran, recherche globale, actions propres à l’écran.
- Écrans provisoires (« En construction ») pour Surveillance et Rapports.
- Thème (couleurs, polices, rayons, styles de boutons) et composants communs : panneau,
  intertitre, ligne clé-valeur, puce, pastille d’état, étiquette de port, courbe, état vide.
- Moteur d’adressage : adresses IPv4, plages (CIDR, début-fin, adresse seule, listes, limite de
  65 536 adresses), calculateur de sous-réseaux et découpage, adresses MAC, table des fabricants
  et détection des adresses MAC aléatoires.
- Modèles partagés : appareil, plage enregistrée, profils de scan (Rapide, Complet, Ports
  courants, Personnalisé).
- Détection de l’interface active (sans trafic réseau) ; au premier lancement, la plage
  proposée est celle de son réseau.
- Enregistrement des plages et des noms personnalisés dans
  `~/Library/Application Support/NetScope/etat.json`.
- Captures hors écran (`--snapshot <dossier>`) et données de démonstration (`--demo`).
- Tests du moteur (`NetScopeSelfTest`), icône, `build.sh`.
