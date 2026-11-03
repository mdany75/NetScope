# Changements

## 0.2.0 — 2026-11-03

Le Scanner se remplit tout seul : noms, ports, switchs, ports de switch et VLAN, sans clic droit.

### Ajouté
- Découverte automatique des switchs (activée par défaut) : à la fin de chaque scan, NetScope
  envoie des requêtes SNMP v2c en lecture seule aux appareils en ligne des plages scannées,
  ajoute les switchs qui répondent à « Switchs et ports » (mention « Découvert
  automatiquement »), relève leurs tables MAC et remplit les colonnes Switch / Port et VLAN.
- MAC des appareils des autres VLAN complétées par l’ARP SNMP de la passerelle et des switchs
  de niveau 3, avant la localisation.
- Noms d’hôte par mDNS (Bonjour) et NetBIOS en plus du DNS inverse, et sysName SNMP pour les
  équipements réseau ; la source du nom est affichée dans le panneau de détail
  (« mDNS (Bonjour) », « NetBIOS · groupe WORKGROUP »…).
- Étapes visibles pendant le scan : Ping → Table ARP → Noms et ports → Switchs (SNMP) →
  Emplacements, puis un bilan « Switchs : 2 découverts (…) · N appareils localisés ».
- Message clair quand aucun switch ne répond en SNMP, avec un bouton vers Réglages ›
  Identifiants.
- Réglages › Switchs : interrupteur « Découvrir les switchs automatiquement (SNMP) », liste des
  communautés à essayer (« public » par défaut) et switchs connus.

### Modifié
- Le profil Rapide (par défaut) sonde maintenant 20 ports essentiels (SSH, Telnet, web, SMB,
  RDP, VNC, impression, RTSP, MQTT…) : la colonne Ports se remplit sans clic droit. Un ancien
  réglage « Rapide » prend ce nouveau comportement.
- Le profil Complet sonde environ 1 000 ports et fait toujours la découverte SNMP.
- Le clic droit « Scanner les ports » devient un scan approfondi d’un appareil (environ
  1 000 ports).
- La communauté SNMP de « Switchs et ports » est préremplie depuis le Trousseau ; celle qui a
  répondu pour chaque switch découvert y est aussi gardée (jamais dans les préférences).
- Les noms Bonjour s’affichent sans « .local ».

### Corrigé
- Le type switch ne reposait que sur un « port 161 TCP » qui n’existe pas (SNMP passe par
  UDP) : le type vient maintenant de la découverte SNMP (switch, routeur, imprimante).
- Les appareils sans enregistrement DNS inverse n’avaient aucun nom.

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
