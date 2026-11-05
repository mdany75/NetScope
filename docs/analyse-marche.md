# NetScope face au marché — analyse et feuille de route

*Rapport pour Dany, 5 novembre 2026, après la publication de la 0.22.0.*

En bref :

- NetScope couvre déjà, dans une seule app Mac native et en français, ce qui demande ailleurs
  quatre ou cinq outils (scanner, MobaXterm, NetScanTools, MXToolbox, un peu de PRTG).
- Sa vraie force est unique sur Mac : **dire sur quel switch et quel port est branché un
  appareil**, site par site, avec une intégration Fortinet profonde en lecture seule.
- Depuis la 0.22.0, l’accès distant (terminal SSH, Telnet, console série, VNC) est intégré :
  l’écart avec Royal TSX, Termius ou Serial est en bonne partie comblé.
- Le plus gros risque n’est pas une fonction manquante : **presque rien n’a été essayé sur le
  vrai réseau** depuis la 0.3. La feuille de route proposée commence donc par la fiabilité.
- Vingt outils vraiment manquants sont proposés (notes 58 à 77), dont six de priorité haute ;
  les améliorations et les allègements sont regroupés dans les notes 78 et 79.

---

## 1. Ce que fait NetScope aujourd’hui (0.22.0)

| Module | En une phrase |
| --- | --- |
| Scanner (moteur) | Découvre en IPv4 plusieurs plages à la fois (ICMP sans droits, ARP, sondes TCP/UDP), donne à chaque appareil son nom avec sa source, son fabricant (registre IEEE complet) et son type, puis le situe sur un switch, un port et un VLAN (SNMP v2c ou API FortiGate). |
| Scanner (écran) | Tableau dense aux colonnes réglables, recherche multiple, filtres par plage et VLAN, menu contextuel (Ping, SSH, TFTP, WoL, navigateur, ports) et export CSV/JSON. |
| Sites | Sépare chaque client : plages, FortiGate, switchs, résultats, inventaire et notes. Détecte le site avec prudence (MAC de la passerelle, numéro de série de la FortiGate) et le synchronise par iCloud Drive. |
| Carte du réseau | Dessine la hiérarchie Internet → passerelle → switchs → bornes → groupes d’appareils, avec recherche, branche surlignée et lien vers l’Inventaire. |
| Inventaire | Fiches permanentes par site (clé MAC), chronologie des changements d’IP et de port, matériel et garantie, pièces jointes, archive, fusion des doublons, instantanés et comparaison de scans. |
| Fiche Appareil | Réseau, matériel, emplacement physique, Wi-Fi (FortiAP), ports et bannières, sonde web, ressources SNMP et notes du technicien, sur un seul écran. |
| Ping continu | Jusqu’à 9 cibles ICMP, statistiques complètes (P95, gigue), journal des coupures, pause par cible, MTR continu et export CSV. |
| Test MTU | Simple renvoi vers le Ping continu avec le bit DF et rappel des tailles types. |
| Switchs et ports | Client SNMP v2c maison et API FortiGate : façade du switch, MAC par port, PoE, trafic en direct, uplinks, « où est branché cet appareil ? ». |
| Wi-Fi (ce Mac) | Connexion en cours (RSSI, SNR, débit), graphe des canaux sur trois bandes, recommandations, jumeaux suspects, relevé par pièce (en mémoire seulement). |
| Wi-Fi (FortiAP) | Bornes, clients et SSID de chaque site lus par la FortiGate, avec « Diagnostiquer » guidé pour un client, une borne ou un SSID. |
| Adressage | Calculateur de sous-réseaux IPv4 et convertisseur MAC/OUI relié à l’Inventaire. |
| Diagnostic | Scan de ports TCP d’un hôte, DNS natif complet (comparaison, propagation, DNSSEC) et Whois. |
| Services | Wake-on-LAN, Test DHCP sans prendre de bail, occupation des étendues DHCP, capture LLDP/CDP (LLDP-MED, PoE), serveur et client TFTP. |
| Internet et parc Fortinet | État des grands services en ligne (avec « Bloqué ici »), WAN/SD-WAN/VPN, firmware et licences de toutes les FortiGate. |
| Courriel | Super outil, note de santé sur 100, MX, listes noires, SPF/DKIM/DMARC/BIMI/MTA-STS, diagnostic SMTP et analyse d’en-têtes. |
| Speedtest et iperf3 | Débit Internet multi-flux par quatre moteurs (Cloudflare, M-Lab, LibreSpeed, Ookla CLI) avec latence en charge, et interface pour iperf3 (Homebrew). |
| Capture de paquets | BPF ou tcpdump, une vingtaine de décodeurs, flux, statistiques, lecture pcap/pcapng et écriture pcap. |
| Vitesse des disques | Débit et IOPS d’un disque local, d’un NAS ou d’un dossier nuage, avec un bilan qui dit d’où vient la limite. |
| Surveillance | 24 types de sondes (du ping à la licence FortiGuard), dépendances, plages horaires, barre de menus, disponibilité sur 24 h. |
| Alertes | Courriel SMTP, webhooks Teams, Slack et JSON, anti-rafale et notifications macOS. |
| Journaux | Récepteur Syslog et traps SNMP sans droits, journaux de la FortiGate et « Comprendre une coupure ». |
| Trafic | FortiView par l’API (sources, applications, menaces), « Qui sature le lien ? » et analyse complète du réseau notée sur 100. |
| Analyse | Occupation d’un /24, courbe des appareils, répartition par fabricant et par type, alertes de l’Inventaire et comparaison de scans. |
| Rapports | Quatre modèles et 17 sections, en PDF, CSV, JSON ou HTML, « Depuis le dernier rapport » et rapports planifiés par site. |
| **Accès distant** (nouveau en 0.22.0) | Carnet par site rempli depuis le scan ; **terminal intégré en onglets** pour SSH (le `ssh` de macOS, clés de `~/.ssh`, mot de passe au Trousseau), Telnet (négocié par NetScope) et **console série** (adaptateurs FTDI, CP210x, CH340, Prolific, préréglage 9600 8N1, bouton Break) ; **session VNC intégrée** (qualité adaptative, Ctrl-Alt-Suppr, observation seule, presse-papiers texte) ; journal de session, extraits de commandes par marque (Cisco, FortiGate, Aruba, Linux). RDP reste dans Windows App. |
| Transferts | Client FTP/FTPS natif, SFTP par `/usr/bin/sftp`, navigateur en deux volets et serveur FTP temporaire. |
| Sauvegarde et réglages | Sauvegarde chiffrée AES-GCM, export et import par parties, identifiants au Trousseau, plusieurs FortiGate par site, relecture automatique. |

---

## 2. Le marché

Les prix sont ceux relevés en novembre 2026 (en dollars américains sauf mention) ; ils changent
souvent et certains viennent de revendeurs ou d’agrégateurs. La dernière colonne ne garde que
ce que NetScope **ne fait pas**.

### 2.1 Scanners et découverte

| Application | Plateforme | Prix | Ce qu’elle fait que NetScope ne fait pas |
| --- | --- | --- | --- |
| Fing Desktop et Fing Agent | macOS, Windows ; agent Linux, Raspberry Pi, Docker ; iOS, Android | Gratuit (perso) ; Starter 24,99 $/an ; Premium ≈ 59 $/an | Identification par base communautaire (modèle exact), agent 24/7 qui tourne sans le poste, tests de débit planifiés, blocage d’appareils, détection de caméras cachées |
| Angry IP Scanner | Windows, macOS, Linux (Java) | Gratuit, libre | Ligne de commande pour l’automatisation, scan de listes ou d’adresses aléatoires, « fetchers » extensibles |
| Advanced IP Scanner | Windows seulement | Gratuit | Liste et ouverture des partages SMB, extinction à distance des PC Windows, intégration Radmin |
| LanScan Pro | macOS (App Store) | 9,99 $ (IPv4), 14,99 $ (IPv6) | **IPv6** lien local et global, module NDI |
| iNet | macOS, iOS | 24,99 $ (achat unique) | Peu de chose de plus ; tout tient en barre des menus |
| Network Radar | macOS 12+ | ≈ 20 à 30 $ | **IPv6**, groupes et étiquettes libres, commandes SSH à distance (éteindre ou redémarrer un Mac) |
| SoftPerfect Network Scanner | Windows, macOS, Linux | 29 $ ; site 1 000 $ | **IPv6**, WMI et registre Windows, partages SMB, utilisateurs connectés, ports UDP, exécution de commandes à distance, scripts |
| Nmap et Zenmap | Windows, macOS, Linux | Gratuit, libre | Détection des versions de services et de l’OS, scripts NSE (vulnérabilités), scan UDP complet |
| ManageEngine OpUtils | Serveur Windows ou Linux, web | Gratuit limité ; ≈ 98 à 138 $/an | IPAM complet, blocage de port d’un intrus, navigateur SNMP, sauvegarde de configurations |
| Lansweeper | Nuage avec capteurs Windows/Linux, agent macOS | Gratuit jusqu’à 100 actifs ; ≈ 239 à 439 $/mois | Inventaire logiciel, Active Directory, fin de vie et vulnérabilités, découverte infonuagique |
| Auvik | SaaS avec collecteur local | Sur devis, par appareil | Topologie vivante couche 2/3 avec vrais liens, sauvegarde et historique des configurations, NetFlow, marque blanche MSP |
| NetBrain | Serveur ou nuage, web | Sur devis | Runbooks de dépannage automatisés, analyse de chemin de bout en bout |

### 2.2 Surveillance et journaux

| Application | Plateforme | Prix | Ce qu’elle fait que NetScope ne fait pas |
| --- | --- | --- | --- |
| PRTG Network Monitor | Serveur Windows ; web et mobile | ≈ 200 $/mois (500 capteurs) et plus | Fonctionne 24/7 sans poste ouvert, bande passante par port dans le temps, NetFlow/sFlow, sondes distantes chez les clients, rapports PDF envoyés seuls |
| Domotz Pro | SaaS ; collecteur sur Pi, NAS, Docker, Windows | 35 $ par site par mois (17,50 $ au volume) | SNMP v3, **cycle PoE** et prises intelligentes, sauvegarde des configurations, accès distant sans VPN par le collecteur, intégrations PSA |
| Zabbix | Serveur Linux, web | Gratuit (AGPL) | Modèles pour des milliers d’équipements, escalades, proxys de sites |
| LibreNMS | Linux, web | Gratuit | **Graphes de bande passante par port**, cartes de voisinage LLDP/CDP, OSPF/BGP, facturation de bande passante |
| Observium | Linux, web | Community gratuite ; Pro par abonnement | Capteurs matériels (température, alimentation, optique) par SNMP |
| Uptime Kuma | Auto-hébergé (Docker) | Gratuit | Pages de statut publiques, plus de 90 canaux de notification (ntfy, Pushover…), alerte d’expiration TLS |
| PingPlotter | macOS, Windows, iOS ; agents Cloud | Free ; Standard ≈ 7 $/mois ; Pro ≈ 29 $/mois | **Historique sur des jours**, rapport partageable pour le FAI, agents chez le client, IPv6 |
| SmokePing | Serveur Linux, web | Gratuit | Latence et dispersion dans la durée, sondes DNS/HTTP/TCP distribuées |
| OpManager, Nagios XI, Checkmk, NetCrunch | Serveurs Windows ou Linux, web | Sur devis ou ≈ 2 000 $ et plus (Nagios XI) ; Checkmk Raw gratuit | Rapports SLA, escalades, cartes par étage ou baie, actions automatiques sur alerte |
| Kiwi Syslog Server NG | Windows, web | Gratuit (5 sources) ; ≈ 439 à 999 $ | Syslog TCP, règles et actions, archivage planifié pour la conformité |
| Graylog, Papertrail | Linux (Graylog) ; SaaS (Papertrail) | Graylog Open gratuit ; Papertrail dès ≈ 7 $/mois | Recherche plein texte sur de gros volumes, pipelines, archivage longue durée |

### 2.3 Diagnostic, débit et paquets

| Application | Plateforme | Prix | Ce qu’elle fait que NetScope ne fait pas |
| --- | --- | --- | --- |
| mtr / WinMTR | macOS (Homebrew, sudo), Linux ; Windows | Gratuit | Traceroute **TCP et UDP**, IPv6, numéros d’AS |
| PingInfoView | Windows | Gratuit | Des dizaines d’hôtes dans un seul tableau, **ping TCP** |
| Wireshark et TShark | Windows, macOS, Linux | Gratuit | Milliers de protocoles, filtres d’affichage, déchiffrement TLS, VoIP |
| iperf3 | macOS (Homebrew), Linux, Windows | Gratuit | Mode serveur, UDP avec gigue et pertes, mode inverse et bidirectionnel |
| Speedtest by Ookla | macOS, Windows, mobile, CLI | Gratuit | Historique des mesures, barre des menus |
| LibreSpeed | Navigateur ; serveur auto-hébergé | Gratuit | Serveur de test installé chez le client |
| SolarWinds Engineer’s Toolset | Windows seulement | ≈ 1 585 $ (perpétuelle) | Navigateur MIB et MIB walk, comparaison de configurations, générateur de charge WAN |
| NetScanTools Pro | Windows seulement | Sur devis | Recherche de MTU réelle, traceroute IPv6, transfert de zone DNS, scanner de certificats SSL, partages SMB |
| Network Toolbox | iOS, iPadOS | Gratuit avec abonnement | Recherche Shodan, surveillance de sites |
| NetAlly LinkSprinter 300 | Testeur de poche matériel + Link-Live | ≈ 480 $ | **Bilan en un branchement** (lien, PoE, switch/port, DHCP, Internet) envoyé comme preuve de passage |
| NetAlly LinkRunner 10G / AT 3000 | Testeur matériel | ≈ 6 400 à 7 900 $ | AutoTest, PoE sous charge jusqu’à 90 W, **test de câble**, validation multi-gig |
| NetAlly AirCheck G3 Pro | Testeur Wi-Fi matériel | ≈ 3 600 à 5 300 $ | Analyseur de spectre, Bluetooth, localisation d’une borne à l’antenne |

### 2.4 Wi-Fi

| Application | Plateforme | Prix | Ce qu’elle fait que NetScope ne fait pas |
| --- | --- | --- | --- |
| WiFi Explorer Pro 3 | macOS seulement | 149,99 $ | **Éléments des balises** (802.11k/v/r, charge QBSS), historique du signal, capteurs distants, analyses enregistrées |
| Airtool 2 | macOS seulement | ≈ 39,99 $ | Capture de trames 802.11 (mode moniteur) |
| NetSpot | macOS, Windows, mobile | Gratuit (Inspecteur) ; Home ≈ 49 $ ; PRO et Enterprise plus chers | **Relevé sur plan** avec cartes de chaleur, planification prédictive, rapports |
| Ekahau AI Pro + Sidekick 2 | Windows, macOS | ≈ 5 995 $ par an | Conception prédictive, radios étalonnées, analyseur de spectre |
| Hamina (Planner, Onsite, Live) | Web ; Onsite natif Apple | Dès ≈ 590 $ par 6 mois | Planification, nomenclature, relevé sur site, dépannage en direct |
| inSSIDer / MetaGeek Plus | Surtout Windows | Gratuit ; Plus ≈ 150 à 200 $/an | Spectre Wi-Spy (peu utilisable sur un Mac récent) |
| Ubiquiti WiFiman | iOS, Android ; Desktop macOS 13+ | Gratuit | Découverte UniFi, VPN Teleport, carte du signal sur mobile |
| Diagnostic sans fil (macOS) | Inclus dans macOS | Gratuit | Renifleur 802.11, journaux EAPOL et DHCP détaillés |

### 2.5 Fabricants, MSP et gestion de parc

| Application | Plateforme | Prix | Ce qu’elle fait que NetScope ne fait pas |
| --- | --- | --- | --- |
| FortiExplorer / Go | iOS, Android, Mac Apple Silicon | Gratuit | Premier raccordement par USB, enregistrement FortiCloud |
| FortiGate Cloud / FortiLAN Cloud | Web, mobile | Palier gratuit (7 jours de journaux) | Gestion et provisionnement à distance, journaux sur un an (payant) |
| FortiManager / FortiAnalyzer | Appareil, VM, nuage | Sur devis | Configuration et firmware en masse, révisions et retour arrière, journaux longue durée |
| UniFi Network / Site Manager | Contrôleur UniFi, web, mobile | Gratuit (matériel requis) | Port Manager avec historique 24 h, verrouillage de port, gestion des mises à jour |
| Cisco Meraki Dashboard | Web, mobile, API | Licences par appareil | **Test de câble et cycle PoE** à distance, capture de paquets à distance |
| HPE Aruba Networking Central | Web, mobile | Abonnement par appareil | Provisionnement sans intervention, AIOps |
| Network Detective Pro | Windows, portail web | ≈ 499 $/mois | Rapports d’évaluation de risques et de conformité modifiables, scan de vulnérabilités |
| ConnectWise Automate, NinjaOne | Serveur ou SaaS, agents | Sur devis ; NinjaOne ≈ 1,50 à 3,75 $ par appareil par mois | RMM des postes (scripts, correctifs), NetFlow/sFlow/IPFIX, SNMP v3, modèles d’OID, intégration billetterie |
| phpIPAM | Web auto-hébergé | Gratuit | IPAM IPv4 et IPv6 complet, VRF, baies, scan planifié par cron |
| NetBox | Web auto-hébergé ou nuage | Community gratuit ; Cloud dès ≈ 7 500 $/an | Source de vérité : câblage, panneaux de brassage, circuits, API GraphQL |

### 2.6 Accès distant et transferts

| Application | Plateforme | Prix | Ce qu’elle fait que NetScope ne fait pas (après la 0.22.0) |
| --- | --- | --- | --- |
| Royal TSX | macOS (Royal TS sous Windows) | 49 € perpétuelle ; Lite gratuite (10 connexions) | **Tunnels SSH** intégrés (Secure Gateway), RDP intégré, identifiants hérités par dossier, import de carnets, tâches sur plusieurs connexions |
| Termius | macOS, Windows, Linux, mobile | Gratuit ; Pro 10 $/mois | Redirection de ports, Mosh, synchronisation avec le téléphone, autocomplétion par IA |
| SecureCRT | Windows, macOS, Linux | ≈ 179 à 230 $ | **Même commande envoyée à plusieurs sessions**, mosaïque, scripts Python, tunnels |
| iTerm2 | macOS | Gratuit | Volets divisés, déclencheurs sur expression régulière, tmux |
| MobaXterm | Windows seulement | Home gratuit ; Pro 69 $ | Serveur X11, RDP intégré, tunnels, macros, serveur NFS |
| Remote Desktop Manager | Windows, macOS, Linux, mobile | Free gratuit ; Team ≈ 400 $/an | Plus de 150 protocoles, injection des identifiants, coffre partagé, journaux d’audit |
| ZOC Terminal | Windows, macOS | ≈ 80 $ | Langage de script de 200 commandes, proxys SOCKS/HTTP |
| Serial | macOS | 39,99 $ | **XMODEM/YMODEM/ZMODEM** pour pousser un firmware, vue hexadécimale, horodatage des réceptions, série Bluetooth, Telnet RFC 2217 |
| CoolTerm | macOS, Windows, Linux | Gratuit | Rien d’utile de plus pour un technicien réseau |
| Transmit 5 / Cyberduck | macOS (et Windows pour Cyberduck) | 45 $ / gratuit | WebDAV, S3 et nuages, synchronisation de dossiers, transferts reprenables |
| Windows App | macOS, iOS, Windows, web | Gratuit | RDP (NetScope l’ouvre, à dessein) |
| RustDesk, TeamViewer | Toutes plateformes | RustDesk gratuit ; TeamViewer dès ≈ 50 $/mois | Prise en main d’un poste à travers Internet |

---

## 3. Ce qui rend NetScope unique

1. **Le seul outil Mac qui répond à « sur quel port est branché cet appareil ? »**, par SNMP
   multi-marques et, pour les FortiSwitch, par l’API FortiGate même quand FortiLink n’est pas
   joignable. Ailleurs, il faut OpUtils, Engineer’s Toolset ou NetScanTools (Windows seulement),
   ou un testeur NetAlly de 500 à 8 000 $.
2. **Un vrai fonctionnement multi-clients en local** : mêmes plages sur 20 sites sans mélange,
   sans le nuage ni l’abonnement par site de Domotz (35 $/mois) ou Auvik.
3. **Une intégration Fortinet profonde en lecture seule** (FortiSwitch, FortiAP, WAN, FortiView,
   firmware, licences, journaux) qu’aucun outil de bureau n’offre. FortiExplorer ne fait que le
   premier raccordement.
4. **L’équivalent de MobaXterm, NetScanTools et MXToolbox réunis, natif et en français.** Depuis
   la 0.22.0, le terminal SSH/Telnet, la console série et le VNC sont dans la même fenêtre que
   le scan : ce créneau est vide sur Mac.

### Position face aux concurrents Mac les plus proches

| Domaine | Concurrent Mac | Ce qu’il fait mieux que NetScope | Ce que NetScope fait et lui pas |
| --- | --- | --- | --- |
| Découverte | LanScan Pro, iNet, Network Radar, SoftPerfect, Fing Desktop, Angry IP | IPv6 (LanScan, Network Radar, SoftPerfect), WMI et partages SMB (SoftPerfect), agent 24/7 et identification communautaire (Fing) | Switch, port et VLAN, sites multiples, inventaire historisé, rapports clients |
| Wi-Fi | WiFi Explorer Pro 3, NetSpot, Diagnostic sans fil, WiFiman | Éléments des balises (802.11k/v/r, charge QBSS), relevé sur plan (NetSpot), historique du signal | Clients et bornes FortiAP de tous les sites, diagnostic guidé d’un client |
| Ping et MTR | PingPlotter, mtr par Homebrew | Historique sur des jours, rapport pour le FAI, TCP et UDP, IPv6 | Multi-cibles intégré au reste de l’app, sans droits administrateur |
| **Accès distant** | Royal TSX, Termius, SecureCRT, Serial | Tunnels SSH et saut par bastion, même commande envoyée à plusieurs sessions, XMODEM pour le firmware, RDP intégré (Royal TSX), synchronisation mobile (Termius) | **Depuis la 0.22.0** : terminal SSH/Telnet en onglets, console série avec Break et préréglage Cisco/Fortinet, VNC intégré, journal de session et extraits de commandes par marque, le tout **ouvert depuis le carnet rempli par le scan** du site |
| Surveillance | Rien de natif sur Mac (PRTG, Domotz, Auvik, Uptime Kuma passent par le web ou un serveur) | Fonctionnement continu sans poste ouvert, historique long, SLA | Aucun serveur à installer, sondes « nouveaux appareils » et « port de switch » |

### Faiblesses de fond, dites honnêtement

- **Rien n’a été essayé sur le vrai réseau** pour l’essentiel des fonctions livrées de la 0.3 à
  la 0.22 : FortiAP, WAN, FortiView, Syslog, SNMP v3, rapports planifiés, sites, et maintenant
  terminal, console série et VNC. C’est le plus gros risque, devant toute fonction manquante.
- **IPv4 seulement**, alors que trois concurrents Mac à 10–30 $ découvrent l’IPv6.
- **Ne tourne que si NetScope est ouvert** : pas de scan planifié, 24 h d’historique de
  surveillance, pas d’agent. Face à Fing Agent, Domotz ou PRTG, la surveillance reste un outil
  de passage.
- **Les modules de suivi dépendent presque tous de Fortinet** : un client sans FortiGate n’a
  plus de trafic, de WAN ni de firmware.

---

## 4. Outils manquants

### Déjà prévus dans A-FAIRE (pas renumérotés)

- Sauvegarde des configurations (FortiGate, switchs) et comparaison : note 40.
- Journal de l’app et « Exporter un diagnostic » : note 35.
- Préréglages du Ping continu et traceroute relancé tout seul : note 11 (en partie livrée en 0.21).
- Assistance à distance RustDesk : note 6.
- Interface en anglais : note 13.
- Idées sans numéro, notées dans `docs/feuille-de-route.html` (pas dans A-FAIRE) : navigateur
  SNMP et MIB walk, toner des imprimantes, test de câble, qualité VoIP (MOS), scan d’un VLAN
  tagué, relevé Wi-Fi sur plan, retour à la version précédente, IPv6.
- Terminal, console série et VNC intégrés : note 57, **livrée en 0.22.0**.

### Vraiment manquants (numéros proposés 58 à 77)

| N° | Outil | Ce qu’il apporte au technicien | Qui l’offre | Effort | Priorité |
| --- | --- | --- | --- | --- | --- |
| 58 | **Bilan de raccordement en un clic** (façon AutoTest) : lien et vitesse négociée, switch, port et VLAN par LLDP/CDP, PoE, DHCP, passerelle, DNS, Internet et débit, horodaté, archivé par site et comparé au précédent | La preuve de passage et l’« avant/après » en 30 s ; presque tout existe déjà, il manque l’enchaînement | NetAlly LinkSprinter, LinkRunner | Moyen | **Haute** |
| 59 | **SNMP v3** pour le relevé des switchs, les Ressources et les sondes | Beaucoup de parcs récents refusent le v2c ; le moteur v3 existe mais ne sert qu’au test | Domotz, NinjaOne, PRTG, LibreNMS | Moyen | **Haute** |
| 60 | **Fiche matériel remplie automatiquement** (sysDescr, ENTITY-MIB, inventaire FortiGate) | Inventaire et rapports justes sans saisie | Lansweeper, Auvik, Domotz | Petit à moyen | **Haute** |
| 61 | **Export de la carte** (PNG, PDF, SVG ou draw.io) et section « Carte » du rapport | Le schéma est le livrable que le client demande le plus | Auvik, Domotz, Zenmap | Petit | **Haute** |
| 62 | **Historique long de la Surveillance** (30 à 90 jours) et **rapport de disponibilité** | Prouver une panne au FAI ou au client, rapport mensuel | PRTG, Nagios XI, Uptime Kuma, PingPlotter | Moyen | **Haute** |
| 63 | **Scan planifié par site** qui alimente l’Analyse, les nouveaux appareils et les rapports planifiés | Aujourd’hui les rapports planifiés reprennent un vieux scan | Fing, Lansweeper, PRTG, phpIPAM | Moyen | **Haute** |
| 64 | **Surveillance en arrière-plan sans fenêtre** (agent de connexion ou LaunchAgent) | Sondes, Syslog et scans qui continuent après la fermeture de l’app | Fing Agent, Domotz | Moyen à gros | Moyenne |
| 65 | **Ping TCP et HTTP** dans le Ping continu, **traceroute TCP et UDP** | Caméras, serveurs et liens qui filtrent l’ICMP | PingInfoView, mtr, PingPlotter | Petit à moyen | Moyenne |
| 66 | **Tunnels SSH et saut par bastion** (`-L`, `-D`, `-J`) dans le carnet, réutilisables par le terminal et le VNC intégrés | Joindre le réseau FortiLink ou un site distant ; chiffrer le VNC, qui ne l’est pas | Royal TSX, Termius, SecureCRT | Petit (arguments du `ssh` déjà utilisé) | **Moyenne, montée d’un cran** depuis la 0.22 |
| 67 | **Envoi d’une commande à plusieurs sessions** et extraits personnalisés (les extraits par marque sont livrés en 0.22.0) | `show run` sur tous les switchs d’un site en une fois | SecureCRT, Royal TSX, iTerm2 | Petit | Moyenne |
| 68 | **Empreinte légère des services et du système**, sans Nmap (en-tête HTTP, certificat TLS, dialecte SMB, sysDescr, TXT mDNS, TTL) | Type et OS plus justes, versions dans le rapport Sécurité | Nmap, SoftPerfect, Lansweeper | Moyen | Moyenne |
| 69 | **Scan de ports UDP ciblé** (DNS, NTP, SNMP, TFTP, SIP, IPMI, mDNS) | Repérer SNMP ouvert, SIP et IPMI exposés | Nmap, SoftPerfect, NetScanTools | Petit à moyen | Moyenne |
| 70 | **Vérificateur de certificat TLS** (chaîne, SAN, expiration, versions) | Pare-feu, portails, imprimantes et NAS aux certificats expirés | NetScanTools, SSL Labs, Uptime Kuma | Petit | Moyenne |
| 71 | **Éléments des balises Wi-Fi** par CoreWLAN : 802.11k/v/r, charge QBSS, génération, WPA3 | Itinérance et borne saturée, même hors FortiAP | WiFi Explorer Pro 3 | Petit à moyen | Moyenne |
| 72 | **Partages SMB d’un hôte** par `smbutil view` | Trouver un partage, vérifier un NAS | Advanced IP Scanner, SoftPerfect | Petit | Basse |
| 73 | **Actions sur un port** : cycle PoE et redémarrage (API FortiGate ou SNMP en écriture) | Redémarrer à distance un téléphone IP, une borne ou une caméra figés | Meraki, Domotz, OpUtils | Moyen | Moyenne, **à décider** (rompt la lecture seule) |
| 74 | **Graphes de bande passante par port sur la durée** (compteurs SNMP) | Lien saturé vu dans le temps ; trafic de secours sans FortiGate | LibreNMS, PRTG, Observium | Moyen | Moyenne |
| 75 | **Collecteur NetFlow, sFlow, IPFIX** | « Qui sature le lien ? » sans FortiView | NinjaOne, Auvik, PRTG | Gros | Basse |
| 76 | **Notification sur téléphone** par ntfy ou Pushover | Alerte loin du Mac sans Teams | Uptime Kuma, PRTG | Petit | Basse |
| 77 | **Autres contrôleurs** (UniFi, Omada, Meraki) | Clients sans Fortinet | Domotz, WiFiman, Meraki | Gros pour chacun | Basse |

Aucun n’exige de bibliothèque externe ; ceux qui s’appuient sur un outil du système (`smbutil`,
`ssh`) le disent. Avec la 0.22.0, la note 67 a perdu sa moitié (les extraits par marque) et la
note 66 gagne en intérêt : le VNC intégré n’est pas chiffré, un tunnel SSH règle ce point.

---

## 5. À améliorer (note 78)

| Outil | Écart avec la référence du marché | Amélioration proposée |
| --- | --- | --- |
| **Test MTU** | Simple renvoi ; NetScanTools et `ping -D` cherchent la taille | Vraie recherche par dichotomie avec le bit DF, « MTU du chemin = N vers X », détection du PPPoE et des tunnels |
| **Ping continu** | PingInfoView suit des dizaines d’hôtes, PingPlotter garde des jours | Tableau compact au-delà de 9 cibles, session enregistrée, rapport « pour le FAI » en PDF, seuil par cible, notification macOS |
| **Surveillance** | PRTG et Nagios : maintenance, escalades, graphes | Heures ouvrables par site, fenêtres de maintenance, rappel si l’alerte n’est pas accusée, graphe de latence par sonde, SNMP v3 (n° 59) |
| **Carte du réseau** | Auvik et LibreNMS tracent les vrais liens et filtrent par VLAN | Liens entre switchs par les voisins LLDP déjà lus, filtre par VLAN, nœuds déplacés retenus, export (n° 61) |
| **Analyse** | phpIPAM gère toutes les tailles | Occupation de /23 à /16 (pages de /24), « prochaine IP libre hors DHCP », croisement avec les baux FortiGate |
| **Wi-Fi (ce Mac)** | WiFi Explorer et NetSpot : 5/6 GHz et relevés enregistrés | Meilleur canal en 5 et 6 GHz, relevé par pièce enregistré par site avec débit et latence, historique au-delà de 2 minutes |
| **Wake-on-LAN** | Network Radar et SoftPerfect vérifient le réveil | « Réveillé en N s », broadcast dirigé, envoi groupé |
| **Speedtest** | Fing fait des tests planifiés | Sonde « débit Internet » quotidienne avec courbe par site |
| **iperf3** | Binaire Homebrew obligatoire, pas de serveur | Mode serveur intégré compatible iperf3, ou test NetScope-à-NetScope |
| **Capture de paquets** | Loin de Wireshark, rien pour la VoIP | Décodeurs SIP, RTP, SNMP, Syslog, RADIUS, NTP ; constats automatiques ; « Ouvrir dans Wireshark » |
| **Rapports** | Network Detective : modifiables ; PRTG : envoyés seuls | Envoi automatique du rapport planifié par SMTP, export DOCX écrit à la main, graphes de disponibilité (n° 62) |
| **Alertes** | Événements typés chez PRTG et Uptime Kuma | Événements dédiés (licence, firmware, Syslog, WAN) ; ntfy/Pushover (n° 76) |
| **Journaux** | Kiwi et Graylog : TCP/TLS et transfert | Syslog TCP (RFC 6587), retransmission ; garder le port 5514 et mieux guider la configuration |
| **Inventaire** | Lansweeper remplit seul | Remplissage automatique (n° 60), rapprochement des MAC aléatoires, export NetBox, GLPI, Snipe-IT |
| **Accès distant** (après la 0.22.0) | Royal TSX injecte les identifiants et importe les carnets ; Serial pousse un firmware | Import de `~/.ssh/config`, nom d’utilisateur retenu aussi pour RDP et SFTP, tunnels (n° 66), commande à plusieurs sessions (n° 67), **XMODEM/YMODEM** et horodatage des lignes en console série, presse-papiers VNC au-delà du texte plus tard. Surtout : **essayer le tout sur de vrais équipements** |
| **Trafic** | Inutile sans FortiGate | Secours par compteurs SNMP (n° 74) ; seuils sur un écart dans le temps |
| **Vitesse des disques** | — | Ajouter SFTP et FTP comme emplacements ; le reste suffit |

---

## 6. Inutiles, redondants ou à ne pas faire (note 79)

### Dans NetScope

| Outil | Pourquoi | Que faire |
| --- | --- | --- |
| **Deux « analyses »** (l’écran Analyse et l’« Analyse complète du réseau » du Trafic) | Même nom pour deux choses différentes | **Renommer** : « Historique et adressage » et « Bilan de santé » |
| **Test MTU** | Il ne mesure rien | Le rendre réel (section 5), sinon le **retirer** |
| **Ookla par sa CLI** | Binaire Homebrew ; licence de la CLI apparemment limitée à l’usage personnel, à vérifier | **Cacher** par défaut, ou retirer après vérification |
| **Services grand public** (TikTok, Snapchat, Grok, Meta) | Peu utiles chez une entreprise | Garder (note 53) mais **masqués par défaut** |
| **Sept outils de courriel** côte à côte | Le Super outil fait déjà l’essentiel | **Fusionner** en un outil « Courriel » à onglets |
| **Ressources de ce Mac** | Le Moniteur d’activité fait pareil | Garder en **second plan**, ne plus investir |
| **TFTP en double** dans l’inventaire des modules | Un seul outil réel | Vérifier qu’une seule entrée existe dans la Boîte à outils |
| **« Ouvrir dans Terminal » et « Partage d’écran »** gardés dans le menu Connecter | Redondants avec les sessions intégrées, mais utiles tant que celles-ci ne sont pas éprouvées | Garder en **secours** ; revoir après les essais réels |
| **Note 6 RustDesk** | Le client RustDesk fait tout | La **garder petite** (carnet et lien `rustdesk://`) |

### À ne pas faire

- **Un scanner de vulnérabilités avec base de CVE** : base tierce à tenir à jour sans fin.
  L’empreinte légère (n° 68) et les ports risqués suffisent.
- **Une détection d’OS au niveau de Nmap** : sans sa base d’empreintes, travail sans fin.
- **RDP natif** : écarté avec raison par la note 57 (protocole trop vaste sans bibliothèque).
- **Le mode moniteur Wi-Fi** : impossible sans droits sur un macOS récent ; Airtool le fait.
- **La planification Wi-Fi prédictive** façon Ekahau ou Hamina : un autre métier.
- **Le travail d’équipe** (coffre partagé, rôles, SSO) : Dany travaille seul.
- **Un filtre Wireshark complet ou le déchiffrement TLS** : renvoyer vers Wireshark.
- **Un SaaS ou un collecteur multi-sites** façon Domotz ou Auvik : hors de la philosophie
  locale. L’agent local (n° 64) est la limite raisonnable.

---

## 7. Feuille de route révisée (0.23 à 0.30)

Principe : **geler les grosses nouveautés tant que les essais réels n’ont pas commencé.** Dix-neuf
versions n’ont jamais touché le vrai réseau ; chaque fonction nouvelle ajoute à la dette d’essai.

| Version | Thème | Contenu |
| --- | --- | --- |
| ~~0.22.0~~ | ~~Sessions intégrées~~ | **Livrée le 5 novembre 2026** : note 57 (terminal SSH/Telnet, console série avec Break, VNC, journal de session, extraits par marque) |
| **0.23.0** | Fiabilité terrain | 35 : journal et « Exporter un diagnostic » ; essais sur une vraie FortiGate, un site, un scan, et **les sessions de la 0.22** (câble console, serveurs VNC), corrigés au fil de l’eau ; 60 : fiche matériel remplie automatiquement |
| **0.24.0** | Sauvegarde des configurations | 40 : FortiGate par l’API, puis switchs en SSH grâce au terminal de la 0.22 ; 61 : export de la carte et section « Carte » du rapport |
| **0.25.0** | SNMP complet | 59 : SNMP v3 partout ; navigateur SNMP et MIB walk ; 74 : graphes de bande passante par port |
| **0.26.0** | Bilan de raccordement | 58 : bilan en un clic avec avant/après ; Test MTU réel ; 65 : ping TCP/HTTP et traceroute TCP/UDP |
| **0.27.0** | Surveillance de longue durée | 62 : historique de 30 à 90 jours et rapport de disponibilité ; maintenance et heures ouvrables par site ; envoi automatique du rapport planifié |
| **0.28.0** | Automatique en arrière-plan | 63 : scan planifié par site ; 64 : agent sans fenêtre ; sonde « débit Internet » planifiée |
| **0.29.0** | IPv6 | Voisins NDP (lus par sysctl, sans paquet), ping multicast lien local, ping et traceroute IPv6, calculateur IPv6 |
| **0.30.0** | Wi-Fi et accès distant pro | 71 : éléments des balises ; meilleur canal 5/6 GHz et relevé enregistré ; 66 et 67 : tunnels SSH et commande à plusieurs sessions ; XMODEM en console série |

**Plus tard, au choix :** note 11 (reste des préréglages du Ping), note 6 (RustDesk léger),
note 13 (anglais), n° 73 (cycle PoE, à trancher d’abord), relevé Wi-Fi sur plan, qualité VoIP
(SIP/RTP), n° 68 à 70 (empreinte, UDP, TLS), n° 72 (SMB), n° 75 à 77 (NetFlow, ntfy, autres
contrôleurs).

Variante possible : si les tunnels SSH (n° 66) deviennent urgents pour chiffrer le VNC ou
joindre le réseau FortiLink, les avancer en 0.24 (effort petit).

---

## 8. Décisions qui t’attendent

| # | Question | Ce que je propose |
| --- | --- | --- |
| 1 | Ajouter les notes 58 à 79 dans `docs/A-FAIRE.md` ? | Fait : ajoutées avec la version prévue de la feuille de route, « à valider par Dany » |
| 2 | Adopter la feuille de route 0.23 à 0.30 ? | Oui, avec la 0.23 réservée à la fiabilité et aux essais réels |
| 3 | Rompre la règle « lecture seule » pour le cycle PoE (n° 73) ? | À trancher avant la 0.24.0 ; si oui, avec une confirmation explicite à chaque action |
| 4 | Cacher ou retirer Ookla ? | Cacher par défaut, puis retirer si la licence de la CLI interdit l’usage chez des clients |
| 5 | Nouveaux noms pour les deux « analyses » ? | « Historique et adressage » et « Bilan de santé » |
| 6 | Fusionner les sept outils de courriel en un seul à onglets ? | Oui, dans une version de fiabilité (0.23 ou 0.24) |
| 7 | Avancer les tunnels SSH (n° 66) ? | Seulement si le VNC non chiffré ou FortiLink posent problème pendant les essais |
| 8 | Quand faire les essais réels des sessions de la 0.22 (câble console, VNC) ? | Au début de la 0.23, avant toute nouveauté |

---

## Sources

Projet : `CHANGELOG.md` (section 0.22.0), `docs/A-FAIRE.md` (notes 1 à 57), `docs/feuille-de-route.html`.

**Scanners et découverte**
- Fing : https://www.fing.com/desktop/ ; https://www.fing.com/pricing/
- Angry IP Scanner : https://angryip.org/
- Advanced IP Scanner : https://www.advanced-ip-scanner.com/
- LanScan : https://apps.apple.com/us/app/lanscan/id472226235?mt=12
- iNet : https://apps.apple.com/us/app/id403304796
- Network Radar : https://apps.apple.com/us/app/network-radar/id507659816?mt=12
- SoftPerfect Network Scanner : https://www.softperfect.com/products/networkscanner/ ; https://www.softperfect.com/order/
- Nmap : https://nmap.org/ ; https://nmap.org/changelog.html
- ManageEngine OpUtils : https://www.manageengine.com/products/oputils/
- Lansweeper : https://www.lansweeper.com/pricing/ ; https://www.capterra.com/p/126334/Lansweeper/pricing/
- Auvik : https://www.auvik.com/pricing/ ; https://www.capterra.com/p/145245/Auvik/
- NetBrain : https://www.netbrain.com/

**Surveillance et journaux**
- PRTG : https://www.paessler.com/prtg/pricing
- Domotz : https://www.domotz.com/pricing.php ; https://www.domotz.com/features.php
- Zabbix : https://www.zabbix.com/whats_new_7_4
- LibreNMS : https://www.librenms.org/
- Observium : https://www.observium.org/
- Uptime Kuma : https://github.com/louislam/uptime-kuma
- PingPlotter : https://www.pingplotter.com/products/purchase ; https://www.pingplotter.com/cloud/pricing
- ManageEngine OpManager : https://www.manageengine.com/network-monitoring/
- Nagios XI : https://www.nagios.com/products/nagios-xi/
- Checkmk : https://checkmk.com/pricing
- NetCrunch : https://www.adremsoft.com/netcrunch/
- Kiwi Syslog : https://www.solarwinds.com/kiwi-syslog-server
- Graylog : https://graylog.org/products/source-available/
- Papertrail : https://www.papertrail.com/plans/
- SmokePing : https://oss.oetiker.ch/smokeping/

**Diagnostic, débit et paquets**
- mtr : https://github.com/traviscross/mtr ; WinMTR : https://sourceforge.net/projects/winmtr/
- Wireshark : https://www.wireshark.org/docs/relnotes/wireshark-4.6.0.html ; https://www.wireshark.org/news/20260225.html
- tcpdump : https://www.tcpdump.org/
- iperf3 : https://software.es.net/iperf/news.html
- Speedtest by Ookla : https://apps.apple.com/app/id1153157709
- LibreSpeed : https://github.com/librespeed/speedtest
- SolarWinds Engineer’s Toolset : https://www.solarwinds.com/engineers-toolset
- NetScanTools Pro : https://www.netscantools.com/nstpromain.html
- Network Toolbox : https://apps.apple.com/us/app/network-toolbox-net-security/id651691453
- PingInfoView : https://www.nirsoft.net/utils/multiple_ping_tool.html
- NetAlly : https://www.netally.com/wp-content/uploads/LinkRunner-Family-Brochure.pdf ; https://www.cdw.com/product/netally-linksprinter-300-network-tester/3683479 ; https://www.shi.com/product/50125169/NetAlly-AirCheck-G3-Pro

**Wi-Fi**
- NetSpot : https://www.netspotapp.com/
- WiFi Explorer Pro 3 : https://www.intuitibits.com/products/wifiexplorerpro3/
- Airtool 2 : https://www.intuitibits.com/products/airtool2/
- Ekahau AI Pro : https://www.ekahau.com/products/ekahau-ai-pro/
- Hamina : https://www.hamina.com/pricing
- inSSIDer / MetaGeek : https://downloads.metageek.com/blog/oscium-metageek-macos-support/
- WiFiman : https://apps.apple.com/app/wifiman/id1385561119
- Diagnostic sans fil : https://eclecticlight.co/2021/12/23/coreservices-apps-wireless-diagnostics

**Fabricants, MSP et gestion de parc**
- FortiExplorer : https://apps.apple.com/us/app/id1157004084?l=en-us
- FortiGate Cloud : https://docs.fortinet.com/document/forticloud/22.4.0/forticloud-concept-guide/907377/fortigate-cloud
- UniFi Network : https://blog.ui.com/article/introducing-unifi-network-10-6
- Meraki : https://documentation.meraki.com/MS/Monitoring_and_Reporting/Using_the_MS_Live_Tools
- Aruba Central : https://www.securewirelessworks.com/Aruba-Central-SaaS-Subscription.asp
- Network Detective Pro : https://www.capterra.com/p/194232/Network-Detective/
- ConnectWise Automate : https://trustradius.com/products/connectwise-automate/pricing
- NinjaOne : https://ninjaone.com/features/network-management
- phpIPAM : https://phpipam.net
- NetBox : https://netboxlabs.com/pricing/

**Accès distant et transferts**
- Royal TSX : https://www.royalapps.com/ts/mac/features
- Termius : https://termius.com/pricing
- SecureCRT : https://www.vandyke.com/products/securecrt/mac_capabilities_features.html ; https://www.vandyke.com/pricing/
- iTerm2 : https://iterm2.com/features.html
- MobaXterm : https://mobaxterm.mobatek.net/download.html
- Remote Desktop Manager : https://devolutions.net/remote-desktop-manager/
- ZOC Terminal : https://www.emtec.com/zoc/
- Serial : https://www.decisivetactics.com/products/serial/
- CoolTerm : https://freeware.the-meiers.org/
- Transmit 5 : https://panic.com/transmit/
- Cyberduck : https://cyberduck.io/
- Windows App : https://techcommunity.microsoft.com/t5/windows-it-pro-blog/windows-app-updates-reliability-productivity-and-security/ba-p/4494681
- RustDesk : https://rustdesk.com/pricing
- TeamViewer : https://www.teamviewer.com/en/pricing/
