# À faire — NetScope

> Ordre des versions : voir « Feuille de route révisée » (point 20). Reste de l’ancienne
> organisation par phases : la fin de la note 11 (phase 4, préréglages du Ping), « plus tard » ;
> la note 6 (phase 2, RustDesk) est livrée dans la 0.26.1, avec le tableau de bord du serveur
> dans la 0.26.2.

## Priorités (revues le 5 novembre 2026, réorganisées avec les notes 45 à 79 après l’analyse du marché)

Notes 1 à 5 : livrées dans la 0.3.0 ; note 18 dans la 0.3.1 ; notes 8, 19, 20 et 9 dans la 0.4.0 ; types Console de jeu et Domotique dans la 0.4.1 ; notes 12, 21, 17 et 16 dans la 0.5.0 ; notes 15 et 14 dans la 0.6.0 ; notes 7 et 22 dans la 0.7.0 ; notes 13 et 23 dans la 0.8.0 ; note 24 dans la 0.9.0 ; note 25 dans la 0.10.0 ; notes 26 et 27 dans la 0.11.0 ; note 28 et correction de la Carte dans la 0.12.0 ; notes 34, 33, 31 et 36 dans la 0.13.0 ; notes 32, 30, 37 et 38 dans la 0.14.0 ; notes 49, 48, 45 et 52 dans la 0.15.0 ; notes 46 et 47, et correctif iCloud de Vitesse des disques, dans la 0.16.0 ; notes 29, 39 et 54 dans la 0.17.0 ; notes 50, 51, 53, 55 et 56 dans la 0.18.0 ; notes 42 et 10 dans la 0.20.0 ; notes 41 et 43, et la note 11 en partie (pause par cible, tableau MTR, écran vide), dans la 0.21.0 ; note 57 dans la 0.22.0 ; notes 35 et 60 dans la 0.23.0 ; erreurs récentes des ports dans la 0.23.1 ; notes 59, 73, 74 et 79, la partie « Trafic » de la note 78 et le navigateur SNMP dans la 0.25.0 ; notes 58, 65, 66 et 71, et les parties « Test MTU », « Ping continu », « Inventaire », « Wake-on-LAN », « Alertes » et « Accès distant » de la note 78 dans la 0.26.0 ; note 6 (RustDesk) dans la 0.26.1 ; tableau de bord du serveur RustDesk (note 6), « Ouvrir une fiche » et saisie à la main dans Appareil, et correctif des clients Wi-Fi de FortiOS 7.4.13 dans la 0.26.2 ; notes 62, 80, 81, 82 et 83 et le reste de la note 78 (Surveillance, Carte du réseau, Analyse, Wi-Fi ce Mac, Speedtest, iperf3, Capture de paquets, Rapports, Journaux, XMODEM/YMODEM, Vitesse des disques) dans la 0.27.0 ; note 84 dans la 0.27.1 ; correctif d’affichage de l’Accès distant (panneau de détails qui recouvrait la session et dépassait de la fenêtre, signalé par Dany le 5 novembre 2026) et fermeture de l’app à l’enregistrement d’une connexion dans la 0.27.2 ; note 85 (onglet « Assistance RustDesk ») dans la 0.27.3 ; notes 61, 72, 75 et 76 (demandées par Dany le 5 novembre 2026) dans la 0.28.0 (la 0.24.0, note 40, reste à faire).

1. **0.13.x à 0.22.x, retours d'essai** (0.8.1 : plantage de Vitesse des disques sur le NAS corrigé ; 0.9.0 : FortiGate essayée avec succès ; 0.10.0 : plusieurs FortiGate à essayer ; 0.11.0 : recherche multiple et FortiAP à essayer ; 0.12.0 : sites à essayer ; 0.13.0 : navigation et gros sites à essayer ; 0.14.0 : recherche de la Carte, téléphones IP, étendues DHCP et sauvegarde chiffrée à essayer ; 0.15.0 : choix du site, Switchs et Wi-Fi d'un autre site, Retour et nom d'utilisateur SSH à essayer ; 0.16.0 : clients Wi-Fi, fiche du client, historique du signal et diagnostic Wi-Fi à essayer sur de vraies bornes FortiAP ; 0.17.0 : relecture automatique, WAN et VPN, Trafic FortiView et analyse complète à essayer sur de vraies FortiGate ; 0.18.0 : FTP, FTPS, SFTP, TFTP, « Bloqué ici », NAS dans Vitesse des disques, export, import et synchronisation à essayer sur de vrais appareils et deux Mac ; 0.20.0 : rapport de suivi, rapports planifiés et Inventaire repensé à essayer sur les vrais sites ; 0.21.0 : firmware et licences, Syslog, traps SNMP, journaux de la FortiGate et pause par cible du Ping à essayer sur de vrais équipements ; 0.22.0 : terminal intégré SSH, Telnet et série, et session VNC intégrée à essayer sur de vrais équipements, câbles console et serveurs VNC ; 0.23.0 : journal de l’app, « Exporter un diagnostic » et fiche matériel automatique à essayer sur de vrais switchs, imprimantes et FortiGate ; 0.25.0 : SNMP v3, navigateur SNMP, graphes des ports et cycle PoE à essayer sur de vrais switchs, FortiSwitch et FortiGate, d’abord sur un port sans risque) : essais réels de la 0.3.x (localisation, DHCP, capture,
   notifications, VNC, mise à jour), de la 0.4.0 (menus de colonnes, type, ports, sombre) et
   des 0.5.0 à 0.8.0 (voir ci-dessous) ; la 0.23.0 n’a pas encore reçu ces retours : ils passent à la 0.23.x, avant la 0.24.0 (point 20).
2. ~~**0.5.0, diagnostic du poste et du réseau local**~~ : livrée le 4 novembre 2026
   (notes 12, 21, 17 et 16) ; essais réels à faire (PoE sur une vraie switch, SNMP, M-Lab,
   LibreSpeed, Ookla, bouton Installer).
3. ~~**0.6.0, Internet et nuage**~~ : livrée le 4 novembre 2026 (notes 15 et 14) ; essais
   réels à faire (pages d’état, Microsoft Graph, listes noires, SMTP, propagation DNS).
4. ~~**0.7.0, analyse avancée**~~ : livrée le 4 novembre 2026 (notes 7 et 22) ; essais
   réels à faire (vraie capture, ChmodBPF, NAS SMB/NFS, dossiers OneDrive et iCloud Drive).
5. ~~**0.8.0, réglages et alertes**~~ : livrée le 4 novembre 2026 (notes 13 et 23) ; essais
   réels à faire (vrais serveurs SMTP, Microsoft 365 et Gmail, canaux Teams et Slack, SNMP v3,
   SSH, restauration d’une sauvegarde sur un autre Mac).
6. ~~**0.9.0, FortiGate et FortiSwitch**~~ : livrée le 4 novembre 2026 (note 24) ; essai
   réel à faire sur la FortiGate de Dany (jeton, empreinte, FortiSwitch, ports, appareils).
7. ~~**0.10.0, plusieurs FortiGate**~~ : livrée le 4 novembre 2026 (note 25) ; essai réel à
   faire sur les 20 sites de Dany (import CSV, jetons, choix par plage, « Tester tout »).
8. ~~**0.11.0, recherche et Wi-Fi Fortinet**~~ : livrée le 4 novembre 2026 (notes 26 et 27) ;
   essai réel à faire sur les FortiGate et bornes FortiAP de Dany (droit « WiFi & Switch
   Controller », clients, AP voisins, sondes) et de la recherche sur un vrai scan.
9. ~~**0.12.0, sites**~~ : livrée le 4 novembre 2026 (note 28 avec la suppression dans
   l'Inventaire et le choix d'un ou plusieurs sites, et correction de la Carte, dernier scan
   seulement) ; essai réel à faire sur les sites de Dany (« Détecter mon site »,
   migration de l'inventaire, import CSV, switchs SNMP associés).
10. ~~**0.13.0, navigation et charge**~~ : livrée le 4 novembre 2026 (notes 34, 33 et 31 :
    double-clic partout, « Ouvrir dans › », Retour / Avancer ⌘[ ⌘] ; note 36 : essais de charge
    et lenteurs corrigées) ; essai réel à faire sur un vrai scan et un très gros site.
11. ~~**0.14.0, Carte, VoIP, DHCP, sauvegarde**~~ : livrée le 4 novembre 2026 (notes 32 :
    recherche dans la Carte ; 30 : type Téléphone IP et détection ; 37 : étendues DHCP, sonde et
    rapport ; 38 : sauvegarde chiffrée, secrets inclus en option) ; essai réel à faire sur une
    vraie FortiGate (étendues DHCP), un réseau voix et la restauration sur un deuxième Mac.
12. ~~**0.15.0, sites et navigation**~~ : livrée le 4 novembre 2026 (notes 49 : site sous le
    logo, menu « Site » et ⌘⇧S ; 48 : site dans Switchs et Wi-Fi ; 45 : fin du Retour ; 52 : nom
    d'utilisateur SSH) ; essai réel à faire sur les sites, FortiGate et bornes de Dany.
13. ~~**0.16.0, Wi-Fi des clients**~~ : livrée le 4 novembre 2026 (notes 46 : clients par borne
    et par SSID, fiche complète du client, historique du signal, section Wi-Fi de la fiche
    Appareil ; 47 : diagnostic Wi-Fi d'un client, d'une borne ou d'un SSID, avec suivi et
    rapport ; correctif iCloud de Vitesse des disques) ; essai réel à faire sur les FortiGate
    et bornes FortiAP de Dany (champs renvoyés par FortiOS, diagnostic sur un vrai client).
14. ~~**0.17.0, suivi automatique et trafic**~~ : livrée le 4 novembre 2026 (notes 29 :
    relecture automatique du site actif, intervalle par site, pauses et essais espacés ; 39 :
    outil « WAN et VPN », vue de tous les sites, sondes et rapport ; 54 : écran « Trafic »
    FortiView, « Qui sature le lien ? », analyse complète du réseau, sondes et rapport) ; essai
    réel à faire sur les FortiGate de Dany (droits FortiView et Log & Report, champs SD-WAN,
    IPsec et VPN SSL, historique selon la journalisation).
15. ~~**0.18.0, transferts, services et configuration**~~ : livrée le 4 novembre 2026 (notes 50 :
    FTP, FTPS et SFTP dans Accès distant, navigateur en deux volets, file des transferts, serveur
    FTP temporaire ; 51 : outil TFTP, serveur et client ; 53 : réseaux sociaux, assistants IA et
    état « Bloqué ici » ; 55 : NAS et partages dans Vitesse des disques ; 56 : export, import et
    synchronisation de la configuration par iCloud Drive) ; essai réel à faire sur de vrais
    serveurs, switchs, téléphones IP, le NAS et deux Mac de Dany.
16. ~~**0.20.0, rapports et Inventaire**~~ : livrée le 4 novembre 2026, avant la 0.19.0
    (notes 42 : section « Depuis le dernier rapport », rapports passés par site, rapports
    planifiés par site avec rattrapage unique au lancement et notification ; 10 : Inventaire
    phase 3, ajout à la main et rapprochement par MAC ou IP, ajout automatique au choix par site,
    archivage et « Ne plus réajouter », déplacement entre sites, fiche matériel et garantie,
    pièces jointes, étiquettes et filtres) ; essai réel à faire sur les sites de Dany (rapports
    planifiés sur plusieurs jours, rapprochement par un vrai scan, reprise des inventaires).
17. ~~**0.21.0, firmware, journaux et Ping**~~ : livrée le 4 novembre 2026 (notes 41 :
    outil « Firmware et licences », licences FortiGuard et FortiCare, sondes et rapport ; 43 :
    écran « Journaux », récepteurs Syslog et traps SNMP, journaux d'événements de la FortiGate,
    « Comprendre une coupure », sondes ; 11 en partie : pause par cible, tableau MTR complet,
    écran vide à l'ouverture) ; essai réel à faire sur les FortiGate et switchs de Dany.
18. ~~**0.22.0, sessions intégrées**~~ : livrée le 5 novembre 2026 (note 57 : terminal
    intégré xterm-256color dans des onglets d'Accès distant pour SSH, Telnet et la console
    série, journal de session, extraits de commandes ; session VNC intégrée avec qualité
    adaptative, mise à l'échelle, plein écran, observation seule et presse-papiers ; RDP reste
    dans Windows App) ; essai réel à faire sur de vrais équipements, câbles console USB-série
    et serveurs VNC (macOS, RealVNC, TightVNC, UltraVNC).
    ~~**0.23.0, fiabilité terrain**~~ : livrée le 5 novembre 2026 (notes 35 : journal de l’app,
    secrets masqués, « Exporter un diagnostic… », bannière après une fermeture inattendue ;
    60 : modèle, numéro de série et firmware lus par ENTITY-MIB, sysDescr et la FortiGate) ;
    essai réel à faire sur les switchs, imprimantes, FortiSwitch, FortiAP et FortiGate de Dany.
    ~~**0.25.0, SNMP complet et actions sur les ports**~~ : livrée le 5 novembre 2026, avant la
    0.24.0 (notes 59 : SNMP v3 partout, utilisateur v3 par site ; navigateur SNMP et MIB walk ;
    74 : graphes du trafic de chaque port sur 30 jours, historique par site ; 78, partie
    « Trafic » : trafic des ports sans FortiView, erreurs au rythme par heure ; 73 : cycle PoE et
    redémarrage d’un port, désactivés par défaut ; 79 : « Historique et adressage », « Bilan de
    santé », outil Courriel à onglets, Ookla et services grand public masqués) ; essai réel à
    faire sur les switchs, FortiSwitch et FortiGate de Dany (v3, jeton en lecture-écriture,
    POWER-ETHERNET-MIB en écriture).
    ~~**0.26.0, bilan de raccordement**~~ : livrée le 5 novembre 2026 (notes 58 : Bilan de
    raccordement, avant/après, VLAN attendu, historique, PDF et section de rapport ; 78 : vrai
    Test MTU, Ping continu jusqu’à 64 cibles avec tableau, seuils, notifications, session et
    rapport pour le FAI, export Inventaire NetBox/GLPI/Snipe-IT et MAC aléatoires, Wake-on-LAN
    multiple, alertes dédiées ; 65 : ping TCP et HTTP(S), traceroute UDP et TCP ; 66 : tunnels
    SSH et bastion, import de `~/.ssh/config` ; 71 : éléments des balises Wi-Fi, avancées de la
    0.30.0) ; essai réel à faire sur de vraies prises, bastions, bornes et liens.
19. **Ordre proposé pour la suite** (analyse du 4 novembre 2026, acceptée par Dany ;
    réorganisé le même jour pour placer les notes 45 à 53, ordre accepté par Dany) :
    - **0.13.1** : essais réels (sites, FortiGate, FortiAP, navigation) et correctifs ; note 35
      (journal et diagnostic). Note 35 livrée dans la 0.23.0 ; les essais réels restent à faire.
    - ~~**0.14.0, Carte, VoIP, DHCP, sauvegarde**~~ (livrée) : notes 32 (recherche dans la
      Carte), 30 (Téléphonie IP), 37 (étendues DHCP), 38 (sauvegarde chiffrée).
    - ~~**0.15.0, sites et navigation**~~ (livrée) : notes 49 (site sous le logo), 48 (site dans
      Switchs et Wi-Fi), 45 (fin du Retour : bouton qui nomme l'écran, position dans la liste,
      historique vidé au changement de site), 52 (nom d'utilisateur SSH).
    - ~~**0.16.0, Wi-Fi des clients**~~ (livrée) : notes 46 (clients par borne et par SSID,
      fiche complète), 47 (diagnostic Wi-Fi d'un client, avec solutions).
    - ~~**0.17.0, suivi automatique et trafic**~~ (livrée) : notes 29 (relire en automatique),
      39 (WAN des FortiGate), 54 (FortiView : trafic et analyse complète du réseau).
    - ~~**0.18.0, transferts et services**~~ (livrée) : notes 50 (FTP, FTPS, SFTP), 51 (TFTP),
      53 (réseaux sociaux et assistants IA dans les services en ligne), 55 (NAS dans Vitesse des
      disques), 56 (export, import et synchronisation de la configuration).
    - **0.19.0, parc Fortinet** : note 40 (sauvegarde des configurations) ; la note 41
      (firmware et licences) est livrée dans la 0.21.0. Reprise dans la 0.24.0 (point 20).
    - ~~**0.20.0, rapports et Inventaire**~~ (livrée) : notes 42 (rapport de suivi), 10 (Inventaire phase 3).
    - ~~**0.21.0, journaux, firmware et Ping**~~ (livrée) : notes 43 (Syslog et traps), 41
      (firmware et licences), 11 en partie (pause par cible, MTR, écran vide) ; la note 44
      (aide et accueil) est retirée.
    - ~~**0.22.0, sessions intégrées**~~ (livrée) : note 57 (terminal SSH, Telnet et série,
      session VNC intégrés ; RDP dans Windows App).
    - **Plus tard** : remplacé par le point 20 ci-dessous.
20. **Feuille de route révisée** (analyse du marché du 5 novembre 2026, à valider par Dany ;
    notes 58 à 79, détails dans `docs/analyse-marche.md`). Principe : geler les grosses
    nouveautés tant que les essais réels n’ont pas commencé.
    - ~~**0.23.0, fiabilité terrain**~~ (livrée le 5 novembre 2026) : notes 35 (journal et
      « Exporter un diagnostic ») et 60 (fiche matériel remplie automatiquement). Les retours
      d’essai sur une vraie FortiGate, un site et un scan restent à faire et seront corrigés au
      fil de l’eau en 0.23.x.
    - **0.29.0, synchronisation complète entre les Mac** : note 86 (demande de Dany, 5 novembre 2026).
    - **0.30.0, sauvegarde des configurations** (ex-0.24.0, puis 0.29.0, renumérotée le 5 novembre
      2026 ; reprend la 0.19.0) : note 40 (FortiGate par
      l’API, puis switchs en SSH grâce au terminal de la 0.22.0) ; la note 61 (export de la carte
      et section « Carte » du rapport) est livrée dans la 0.28.0.
    - ~~**0.25.0, SNMP complet**~~ (livrée le 5 novembre 2026, avant la 0.24.0) : note 59 (SNMP
      v3 partout) ; navigateur SNMP et MIB walk (idée sans numéro, venue de l’ancienne feuille de
      route) ; note 74 (graphes de bande passante par port) ; partie « Trafic » de la note 78 ;
      avec en plus les notes 73 et 79, décidées par Dany.
    - ~~**0.26.0, bilan de raccordement**~~ (livrée le 5 novembre 2026) : note 58 (bilan en un
      clic, avant/après) ; Test MTU réel (note 78) ; note 65 (ping TCP/HTTP, traceroute TCP/UDP) ;
      avec en plus les notes 66 et 71 et plusieurs parties de la note 78, avancées de la 0.30.0
      et de « plus tard ».
    - ~~**0.26.1, assistance à distance par RustDesk**~~ (livrée le 5 novembre 2026) : note 6
      (avancée de « plus tard » à la demande de Dany, une fois son serveur RustDesk en place) :
      protocole RustDesk dans Accès distant, Réglages › RustDesk, ID RustDesk dans l’Inventaire
      et ports RustDesk reconnus dans les scans. Essai réel sur le serveur et la FortiGate à faire.
    - ~~**0.26.2, tableau de bord du serveur RustDesk**~~ (livrée le 5 novembre 2026), avec
      Appareil › « Ouvrir une fiche » par IP, nom ou MAC et saisie d’un appareil à la main
      (demande du 5 novembre 2026), et le correctif des clients Wi-Fi à 0 (FortiOS 7.4.13) : note 6
      (ajout du 5 novembre 2026) : onglet « Serveur RustDesk » d’Accès distant lu par SSH en
      lecture seule (sessions relayées, demandes de connexion, postes enregistrés, hbbs et hbbr,
      disque, graphe de six heures), compte SSH et rafraîchissement dans Réglages › RustDesk.
      Essai réel sur le serveur de Groupe Couture à faire.
    - ~~**0.27.0, surveillance de longue durée**~~ (livrée le 5 novembre 2026) : note 62 (historique
      jusqu’à 90 jours, graphe de latence, rapport de disponibilité) ; fenêtres de maintenance,
      heures ouvrables par site et rappel des alertes ; envoi automatique du rapport planifié par
      SMTP et export DOCX (note 78). Avancées dans la même version : notes 80 (FortiAP en
      onglets), 81 (base IEEE automatique), 82 (plages exclues), 83 (Switchs et ports en
      onglets) et toutes les parties restantes de la note 78 (Carte du réseau, Analyse, Wi-Fi ce
      Mac, Speedtest planifié, iperf3, Capture de paquets, Journaux, XMODEM/YMODEM, Vitesse des
      disques). Essais réels à faire (vrais switchs LLDP, FortiAP, SMTP, Wireshark, consoles).
    - ~~**0.27.1, appareils Wi-Fi et repères DHCP**~~ (livrée le 5 novembre 2026) : note 84
      (plus d’alerte « Appareil déplacé » pour l’itinérance Wi-Fi, notée dans l’historique ; carte
      d’occupation Wi-Fi / filaire avec repères DHCP, réservation et légende). Essai réel avec de
      vraies bornes FortiAP à faire.
    - ~~**0.27.2, correctif de l’Accès distant**~~ (livrée le 5 novembre 2026) : **Livrée dans la
      0.27.2.** Correctif d’affichage signalé par Dany le 5 novembre 2026 (panneau de détails qui
      recouvrait la session et dépassait de la fenêtre avec un nom de dossier long) et fermeture
      de l’app en enregistrant une connexion ou un tunnel. Essai réel sur le Mac de Dany à faire.
    - ~~**0.27.3, onglet « Assistance RustDesk »**~~ (livrée le 5 novembre 2026) : **Livrée dans
      la 0.27.3.** Note 85 (demande de Dany du 5 novembre 2026) : l’assistance RustDesk quitte la
      page « Sessions » pour son propre onglet, comme « Serveur RustDesk », avec l’historique
      complet des sessions en tableau. Essai réel sur le serveur de Groupe Couture à faire.
    - ~~**0.28.0, carte exportée, flux, partages SMB et alertes sur téléphone**~~ (livrée le 5
      novembre 2026) : **Livrée dans la 0.28.0.** Notes 61 (export de la carte en PNG, PDF, SVG
      et draw.io, section « Carte du réseau » des rapports), 72 (partages SMB d’un hôte), 75
      (collecteur NetFlow, sFlow et IPFIX dans Trafic) et 76 (notifications ntfy et Pushover),
      demandées par Dany le 5 novembre 2026 et avancées de « plus tard ». Essais réels à faire
      (draw.io, NAS et postes Windows, vrais exportateurs de flux, vrais envois ntfy et Pushover).
    - **0.31.0, automatique en arrière-plan** (prévue en 0.28.0, repoussée par la
      livraison des notes 61, 72, 75 et 76) : notes 63 (scan planifié par site) et 64 (agent
      sans fenêtre) ; sonde « débit Internet » planifiée (note 78, livrée dans la 0.27.0).
    - **0.32.0, IPv6** (idée sans numéro, venue de l’ancienne feuille de route) : découverte par
      la table des voisins NDP (lue par sysctl, sans paquet), ping multicast lien local, ping et
      traceroute IPv6, calculateur IPv6.
    - **0.33.0, accès distant, suite** : note 67 (commande envoyée à plusieurs sessions) ;
      le meilleur canal, le relevé enregistré, la note 80 et XMODEM/YMODEM (note 78) sont livrés
      dans la 0.27.0. Notes 71 et 66 et import de `~/.ssh/config` livrés dans la 0.26.0.
    - ~~**À décider avec Dany avant la 0.24.0**~~ : notes 73 (cycle PoE) et 79 (Ookla caché,
      nouveaux noms des deux « analyses », outils de courriel regroupés) décidées et livrées dans
      la 0.25.0 ; reste à décider : avancer la note 66 (tunnels SSH) en 0.24.0 si le VNC non chiffré ou
      le réseau FortiLink posent problème pendant les essais (livrée dans la 0.26.0).
    - **Plus tard** : note 13 (anglais) ; la note 11 est retirée par Dany le 5 novembre 2026 ; notes 68 à 70 (empreinte des services, ports UDP, certificats
      TLS), 77 (autres contrôleurs ; les notes 72, 75 et 76 sont livrées dans la 0.28.0) ; idées
      d’un cran en dessous : relevé Wi-Fi sur plan, qualité VoIP (MOS) avec les décodeurs
      SIP/RTP, toner des imprimantes, test de câble, scan d’un VLAN tagué, retour à la version
      précédente.

## Index par module

| Module | Livrées | À venir |
| --- | --- | --- |
| Scanner et sites | 18, 19, 20, 26, 28, 48, 49, 81, 82 (0.27.0), 72 (0.28.0) | 63 (0.31.0), IPv6 (0.32.0), 68, 69 (plus tard) |
| Navigation entre les modules | 31, 33, 34, 36, 45 | — |
| Switchs et ports, Fortinet | 12, 24, 25, 29, 39, 41, 54, 59, 73, 74, navigateur SNMP / MIB walk (0.25.0), 83 (0.27.0), 75 (0.28.0) | 40 (0.30.0), 77 (plus tard) |
| Wi-Fi | 1, 27, 46, 47, 71 (0.26.0), 80 et 78 : meilleur canal, relevé (0.27.0) | — |
| Carte du réseau | 32, 78 : liens LLDP, VLAN, disposition (0.27.0), 61 (0.28.0) | — |
| Inventaire | 8, 10, 30 | 60 (0.23.0) |
| Ping continu | 11 (en partie, 0.21.0 ; reste retiré par Dany), 65 (0.26.0) | — |
| Boîte à outils | 2, 7, 14, 15, 16, 17, 21, 22, 37, 51, 53, 55, 58 (0.26.0) | 70 (plus tard) |
| Accès distant | 5, 50, 52, 57, 66 (0.26.0), 6 (0.26.1 ; tableau de bord du serveur, 0.26.2), 85 (0.27.3) | 67 (0.33.0) |
| Surveillance, alertes et journaux | 3, 23, 43, 62 et 78 (0.27.0), 76 (0.28.0) | 64 (0.31.0) |
| Rapports | 4, 42, 62 et 78 : SMTP, DOCX (0.27.0), 61 (0.28.0) | — |
| Réglages, sauvegarde, aide | 9, 13, 38, 56 | 86 (0.29.0), 35 (0.23.0), 13 (plus tard) |
| Toute l’app (analyse du marché) | 79 (0.25.0), 78 en partie (Trafic, 0.25.0 ; Test MTU, Ping continu, Inventaire, Wake-on-LAN, Alertes, Accès distant, 0.26.0), 78 (reste, 0.27.0) | — |

## 1. Wi-Fi : « Autoriser la localisation » n'ouvre pas la fenêtre d'autorisation

- Constat de Dany : le clic sur le bouton ne fait rien, aucune fenêtre de macOS.
- Causes probables (vérifiées dans le code, non corrigées) :
  - l'app est signée avec le runtime durci, mais sans le droit
    `com.apple.security.personal-information.location` : macOS refuse alors la localisation
    sans rien afficher (`codesign -d --entitlements -` ne montre aucun droit) ;
  - `Info.plist` n'a que `NSLocationWhenInUseUsageDescription` ; ajouter aussi
    `NSLocationUsageDescription` (clé lue par macOS) ;
  - si l'accès est déjà refusé ou restreint, la fenêtre ne revient jamais : le bouton doit alors
    ouvrir Réglages Système › Confidentialité et sécurité › Service de localisation.
- Correction prévue : fichier de droits dans `Resources/`, `build.sh` qui signe avec
  `--entitlements`, clé ajoutée, bouton qui gère les états (non déterminé, refusé, restreint),
  message clair. Voir `Sources/NetScope/Screens/Wifi/WifiStore.swift:114`.

## 2. Outils : réaliser « Test DHCP » et « Capture LLDP/CDP » (aujourd'hui « Bientôt »)

- **Test DHCP** : envoyer un DHCPDISCOVER (ou DHCPINFORM) en broadcast et écouter toutes les
  offres pendant quelques secondes ; afficher chaque serveur qui répond (IP, MAC, adresse
  proposée, masque, passerelle, DNS, bail, options) et signaler un serveur DHCP **non autorisé**
  (pas dans la liste des serveurs attendus, réglable). Difficulté : les réponses arrivent sur
  le port UDP 68, déjà tenu par macOS (configd) ; prévoir SO_REUSEPORT, ou un assistant
  privilégié si macOS refuse. Ne jamais accepter le bail (pas de DHCPREQUEST).
- **Capture LLDP/CDP** : écouter les trames LLDP (EtherType 0x88CC) et CDP (SNAP 01:00:0C:CC:CC:CC)
  sur l'interface Ethernet pour afficher le switch, le port, le VLAN, l'adresse de gestion, le
  modèle et le PoE **où le Mac est branché**, sans SNMP. Demande BPF (`/dev/bpf*`), réservé à
  root : utiliser l'accès s'il existe déjà (ChmodBPF de Wireshark), sinon un petit assistant
  lancé avec l'autorisation d'administrateur (fenêtre de macOS), en lecture seule, arrêté à la
  fin de la capture. LLDP passe toutes les 30 s, CDP toutes les 60 s : capture de 60 à 90 s avec
  compte à rebours. Afficher aussi le résultat dans Switchs et ports (« Ce Mac est branché sur… »).
- Tests : décodage de trames LLDP/CDP et de réponses DHCP fixes (octets capturés) ; aucun envoi
  réel pendant les tests.

## 3. Construire l'écran Surveillance (aujourd'hui « En construction »)

- Fidèle au croquis `docs/croquis/Surveillance.dc.html` : état global (sondes actives, en
  alerte, hors ligne), liste des sondes avec interrupteur, intervalle, dernière valeur et barre
  de disponibilité 24 h, éditeur de sonde, journal des alertes avec filtres et « Accuser
  réception ».
- Types de sondes : Ping, TCP (port), HTTP(S) (code, mot-clé, certificat qui expire), DNS,
  SNMP (valeur d'un OID, température, PoE), port de switch (alerte si un appareil change de
  port), nouveaux appareils sur une plage, DHCP non autorisé (lié à la note 2), scan planifié,
  RSSI Wi-Fi.
- Seuils (latence, perte, N échecs de suite), plage horaire, dépendance (« ignorer si la
  passerelle est hors ligne »).
- Alertes : notification macOS (UserNotifications), son, et plus tard courriel ou webhook
  (Teams, Slack) ; **icône dans la barre de menus** (MenuBarExtra) avec l'état, la latence de la
  passerelle, les alertes et « Scan rapide ».
- Les sondes continuent quand la fenêtre est fermée (l'app reste dans la barre de menus) ;
  historique gardé dans Application Support ; badge de la barre latérale = alertes non lues.
- Tests : machine d'états des sondes (seuils, N échecs, retour à la normale, dépendance) sur des
  séries fixes, sans réseau.

## 4. Construire l'écran Rapports (aujourd'hui « En construction »)

- Fidèle au croquis `docs/croquis/Rapport.dc.html` : configuration à gauche (modèle : Audit
  réseau complet / Inventaire simple / Sécurité / Intervention technique ; client, site,
  technicien, date, logo de l'entreprise choisi par l'utilisateur ; sections à cocher), aperçu
  page par page à droite (format lettre, pagination).
- Sections alimentées par les vraies données : résumé (appareils, plages, VLAN, switchs, AP,
  problèmes), plan d'adressage et occupation, inventaire, switchs et ports (emplacement de
  chaque appareil), Wi-Fi, ports ouverts / sécurité (Telnet, SMB, RDP exposés…), problèmes et
  recommandations (conflits IP, DHCP non autorisé, appareils hors ligne, firmware), annexe brute.
- Exports : **PDF** (rendu natif, pages lettre, en-tête, pied « Page N de M », signature du
  technicien), et aussi CSV, JSON et HTML ; « Enregistrer comme modèle » ; liste des rapports
  récents. « Envoyer par courriel » ouvre Mail avec le PDF joint (rien n'est envoyé sans Dany).
- Tests : génération des sections et du PDF à partir de données de démonstration (nombre de
  pages, textes présents), sans réseau.

## 5. Accès distant : RDP et VNC en mode fenêtre ou plein écran

- Choix « Fenêtre / Plein écran » par connexion (enregistré avec elle) et rappelé dans le panneau
  de détail, plus un choix rapide au moment de « Connecter ».
- **RDP** : dans le fichier .rdp généré, `screen mode id:i:1` (fenêtre) ou `:i:2` (plein écran) ;
  en fenêtre : taille choisie (Ajuster à la fenêtre, 1280 × 800, 1440 × 900, 1920 × 1080,
  personnalisée) avec `desktopwidth`, `desktopheight`, `smart sizing:i:1` et
  `dynamic resolution:i:1` ; option « Tous les écrans » (`use multimon:i:1`).
- **VNC** (Partage d'écran de macOS) : pas de paramètre dans l'adresse vnc:// ; mettre Partage
  d'écran en plein écran après l'ouverture (vérifier ce que l'app accepte : préférence, menu
  Présentation › Plein écran par AppleScript, qui demanderait l'accessibilité) ; sinon le dire
  honnêtement. Option échelle : « Ajuster à la fenêtre » / taille réelle.
- Tests : contenu du .rdp pour chaque mode.

## 6. Assistance à distance façon AnyDesk : par RustDesk (choix de Dany) — 0.26.1 et 0.26.2

**Livrée dans la 0.26.2** (5 novembre 2026) pour le tableau de bord du serveur (voir le
paragraphe « Tableau de bord du serveur » plus bas) ; le reste de la note est livré dans la 0.26.1.

> **Livrée dans la 0.26.1** (5 novembre 2026) : protocole RustDesk dans Accès distant (carnet
> des postes, « Assistance RustDesk » par ID, lien d’assistance pour l’usager), Réglages ›
> RustDesk (serveur, clé, client portable, vérification du client, test du serveur, VIP de la
> FortiGate), ID RustDesk dans l’Inventaire et la fiche Appareil, ports 21115 à 21119 reconnus
> dans les scans. Reste : essai réel sur le serveur de Groupe Couture ; le client portable sur
> 911.groupecouture.ca se fait dans le projet AssistanceDistance.
>
> Ancienne décision (dépassée) : reporté en phase 2, ni serveur RustDesk, ni client, ni
> protocole RustDesk dans NetScope lors du « procède » d’alors.

- Principe : serveur RustDesk auto-hébergé (hbbs + hbbr, gratuit, AGPL ; ports TCP 21115-21117,
  UDP 21116) ; client RustDesk chez l'usager installé comme service Windows (voit l'invite UAC :
  le technicien tape ses identifiants admin, l'usager reste utilisateur standard ; au départ du
  technicien, rien ne reste élevé).
- Dans NetScope (Accès distant) : protocole « RustDesk » à côté de SSH/RDP/VNC ; connexion par
  `rustdesk://connect/<ID>` ou `rustdesk --connect <ID>` ; réglage du serveur (adresse hbbs, clé
  publique) dans Réglages ; carnet des postes (ID, nom, usager) ; historique des sessions ;
  détection de RustDesk installé sur le Mac du technicien (sinon lien de téléchargement).
- Site 911.groupecouture.ca (projet AssistanceDistance) : proposer le client RustDesk préconfiguré
  à la place d'AnyDesk — à faire dans ce projet-là, plus tard, avec l'accord de Dany.
- **Décidé (Dany)** : serveur RustDesk chez Groupe Couture, sur le serveur Ubuntu (Docker ou
  paquets .deb hbbs/hbbr), nom DNS du genre `rustdesk.groupecouture.ca`, ports TCP 21115-21117 et
  UDP 21116 ouverts vers lui ; clé publique `id_ed25519.pub` reprise dans NetScope et le client.
- **Décidé (Dany)** : lien de téléchargement d'un client **portable** préconfiguré pour l'usager
  (exe renommé `rustdesk-host=<serveur>,key=<clé>.exe`, rien à installer ni à régler).
  En portable, pas de service : l'élévation admin passe par « Demander l'élévation » (le
  technicien transmet les identifiants admin ou l'usager accepte l'UAC) ; proposer aussi
  l'installation en service pour les postes suivis régulièrement. Lien publié sur
  911.groupecouture.ca (projet AssistanceDistance) et copiable depuis NetScope.
- **Décidé (Dany)** : RustDesk Server OSS, gratuit (hbbs + hbbr). Pas de console web ni de
  générateur de client : le carnet des postes et l'historique se font dans NetScope, le client
  portable est préconfiguré par son nom de fichier.
- **Tableau de bord du serveur** (ajout du 5 novembre 2026, demande de Dany) : **Livré dans la
  0.26.2** (5 novembre 2026). Onglet « Serveur RustDesk » d’Accès distant, lu par une connexion
  SSH en lecture seule (jamais de sudo, liste blanche testée des commandes des consoles de hbbs
  et hbbr) : sessions relayées en cours avec durée, volume et débits ; demandes de connexion des
  dernières 24 h avec le nom du poste quand son ID est au carnet ; postes enregistrés ; hbbs et
  hbbr en marche et depuis quand ; espace disque ; graphe des six dernières heures mesuré par ce
  Mac ; messages avec la marche à suivre (SSH injoignable, console hbbr muette, hbbs trop
  ancien, disque presque plein). Réglages › RustDesk : compte SSH (carnet ou utilisateur@hôte,
  mot de passe au Trousseau), rafraîchissement de 15 s à 5 min, seulement quand l’écran est
  affiché. Limites : sessions directes (sans relais) invisibles ; graphe local à ce Mac. Reste :
  essai réel sur le serveur de Groupe Couture.

## 7. Capture et inspection de paquets, façon Wireshark (demande de Dany)

**Livrée dans la 0.7.0** (4 novembre 2026) ; essais réels à faire (vraie capture, ChmodBPF).

- Nouvel outil (écran ou onglet de la Boîte à outils) : choix de l'interface, filtre de capture
  (syntaxe BPF : `host 10.0.0.5`, `port 53`, `arp`…) et préréglages simples, démarrer / arrêter,
  limite de durée, de paquets et de taille.
- Liste des paquets en direct (n°, temps, source, destination, protocole, longueur, résumé),
  filtre d'affichage, couleurs par protocole ; détail en arbre par couche ; vue hexadécimale et
  ASCII avec surlignage du champ choisi.
- Décodeurs : Ethernet, VLAN 802.1Q, ARP, IPv4/IPv6, ICMP, TCP (drapeaux, numéros de séquence),
  UDP, DNS, DHCP, LLDP/CDP (note 2), NetBIOS, mDNS, HTTP (en clair), en-tête TLS (SNI).
- « Suivre le flux TCP/UDP », statistiques (protocoles, conversations, plus gros émetteurs),
  repérage des retransmissions et des réinitialisations.
- Enregistrer en .pcap (ouvrable dans Wireshark) et ouvrir un .pcap existant.
- Accès : même mécanisme que la note 2 (BPF si ChmodBPF, sinon autorisation administrateur) ;
  réutiliser le lecteur BPF/pcap de la note 2.
- Limite honnête : pas les milliers de décodeurs de Wireshark ; déchiffrement TLS impossible.
- Tests : décodage de paquets fixes et de fichiers pcap d'exemple écrits à la main, sans capture.

## 8. Tableaux standard dans tous les modules (demande de Dany)

- Même tableau partout, sur le modèle du Scanner : tri en cliquant sur l'en-tête (flèche),
  colonnes qu'on élargit ou rétrécit, et en plus **colonnes qu'on masque ou qu'on ajoute**.
- Choix des colonnes : clic droit sur l'en-tête (cases à cocher) et bouton « Colonnes » dans la
  barre de l'écran ; « Rétablir les colonnes par défaut ».
- Colonnes facultatives, masquées par défaut, ajoutables quand l'information existe (ex. Scanner :
  type, première vue, description SNMP, site, plage, interface, nom NetBIOS, source du nom ;
  Inventaire : local, prise, responsable…). Une nouvelle option qui apporte une donnée ajoute sa
  colonne à la liste.
- Ordre, largeurs, colonnes visibles et tri retenus par tableau d'un lancement à l'autre.
- Contenu qui suit la largeur : la colonne « Ports ouverts » affiche autant d'étiquettes de port
  que la largeur le permet, puis « +N » pour le reste (infobulle avec la liste complète) ; plus la
  colonne est large, plus on voit de ports. Même principe pour les autres listes dans une cellule.
- Réalisation : un composant commun (SwiftUI Table avec TableColumnCustomization et
  customizationID, état enregistré par tableau) dans Shared/, adopté par tous les tableaux :
  Scanner, Inventaire (et son détail), Wi-Fi, Switchs et ports, Appareil, Outils (scan de ports,
  DNS), et les nouveaux écrans (Surveillance, Rapports, DHCP, capture de paquets).
- À faire après la fusion des notes 1 à 5 (elles touchent les mêmes écrans).

## 9. Style Mac et petite fenêtre (demande de Dany)

- **Style Mac** : donner à l'application l'allure d'une app macOS native. Choix retenu par défaut
  (Dany peut le corriger) : barre latérale translucide de macOS, barre d'outils unifiée, contrôles,
  menus, champs et couleurs du système, couleur d'accent de macOS, **mode sombre automatique** ;
  on garde la disposition, la densité et les libellés des croquis, pas leur habillage (bleu nuit,
  boutons dessinés). Mettre à jour la règle des croquis dans CLAUDE.md en conséquence.
- **Petite fenêtre** : quand la fenêtre est très réduite, le panneau de droite (détail, réglages
  de l'écran, éditeurs) défile de haut en bas au lieu d'être coupé ; même chose pour la barre
  latérale et les panneaux de gauche. Revoir la taille minimale (aujourd'hui 1100 × 700) : la
  baisser, et replier ou superposer le panneau de droite sous une certaine largeur.
- Vérifier chaque écran en capture à plusieurs tailles (1440 × 900, 1100 × 700 et plus petit).
- À faire après la note 8 (mêmes fichiers d'interface).

## 10. Repenser le module Inventaire — PHASE 3 (demande de Dany)

**Livrée dans la 0.20.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Reporté en phase 3 : revoir le module Inventaire en entier (rôle, disposition, données,
  usage au quotidien). À préciser avec Dany avant de commencer : ce qui ne lui convient pas
  aujourd'hui et ce qu'il attend (ex. inventaire par client ou par site, fiches matériel,
  garanties, pièces jointes, étiquettes, lien avec les rapports).
- **Ajout manuel** (demande de Dany) : créer à la main un appareil absent des scans (imprimante
  hors réseau, appareil d'un autre site, équipement éteint, matériel en stock) avec tous les champs
  (nom, IP, MAC, fabricant, type, local, prise, switch/port, responsable, notes) ; le marquer
  « Ajouté à la main » ; le rapprocher automatiquement d'un appareil scanné ensuite (même MAC ou
  même IP) sans perdre les champs saisis ; modifier, dupliquer et supprimer.
- **Gestion par site** (demande de Dany) : chaque appareil appartient à un site (client,
  bâtiment, succursale) ; sélecteur de site en haut de l'Inventaire, vue « Tous les sites »,
  compteurs par site ; site déduit automatiquement de la plage scannée (sites et plages de
  Réglages) et modifiable à la main ; déplacer des appareils d'un site à l'autre ; filtres,
  exports et rapports par site ; même MAC vue sur deux sites signalée.
- **Ajout et suppression** (demande de Dany) : choisir ce qui entre dans l'inventaire au lieu de
  tout y mettre : option « Ajouter automatiquement les appareils scannés » (activable), sinon
  « Ajouter à l'inventaire » depuis le Scanner (clic droit, sélection multiple) ; retirer un ou
  plusieurs appareils (avec confirmation), au choix archiver (historique gardé, restaurable) ou
  supprimer définitivement ; « Ne plus réajouter cet appareil » (liste d'exclusion modifiable) ;
  annuler la dernière suppression.
- Ne rien changer à l'Inventaire d'ici là, sauf l'adoption des tableaux standard (note 8) et
  du style Mac (note 9).

## 11. Repenser le module Ping continu — PHASE 4 (demande de Dany)

**Livrée en partie dans la 0.21.0** (4 novembre 2026) : pause par cible, tableau MTR complet qui défile à gauche et à droite, écran vide à l'ouverture. **Le reste (préréglages, traceroute relancé tout seul) est retiré à la demande de Dany le 5 novembre 2026** : la note est close.

- **Disposition livrée dans la 0.20.2** (croquis C choisi par Dany) : clic sur une carte → elle
  se retourne en Terminal (réponses de la cible), traceroute (MTR) et journal dessous, grand
  graphe retiré. Reste : préréglages (ci-dessous) et traceroute relancé tout seul.
- **Demandes de Dany après la 0.20.3** (4 novembre 2026), pour la 0.21.0 :
  - mettre **une cible en pause** individuellement (et la reprendre), sans arrêter les autres ;
  - tableau **MTR / Traceroute** : toutes les colonnes visibles (« Écart-type » coupé), et
    pouvoir faire défiler le tableau à gauche et à droite quand il est trop large ;
  - **l'écran s'ouvre vide** : aucune cible ajoutée d'office et aucun ancien journal à
    l'ouverture ; les cibles viennent seulement de Dany (champ, Scanner, fiche Appareil).
- **Constat de Dany** (4 novembre 2026) : « j'aime pas la fenêtre de ping en continu, je sais
  pas pourquoi ». Avant de coder, proposer des croquis de dispositions différentes et choisir
  avec lui (voir aussi ce qui gêne : densité, graphe, place des cibles, journal).
- Reporté en phase 4 : revoir le module Ping continu en entier (disposition, graphes, journal,
  multi-cibles, traceroute/MTR). À préciser avec Dany avant de commencer : ce qui ne lui
  convient pas aujourd'hui et ce qu'il attend.
- **Préréglages de ping continu** (demande de Dany) : ensembles enregistrés et nommés de cibles et
  d'options (intervalle, taille de paquet, délai, seuils d'alerte), lancés en un clic. Exemples
  fournis : « Passerelle + DNS + Internet », « Test MTU » (tailles croissantes, ne pas fragmenter),
  « Surveillance d'un appareil », « Ping rapide » ; création, modification, duplication,
  suppression, import et export ; préréglages par site.
- Ne rien changer au Ping continu d'ici là, sauf l'adoption des tableaux standard (note 8) et
  du style Mac (note 9).

## 12. « Suis-je sur un port PoE ? » (demande de Dany)

**Livrée dans la 0.5.0.**

- Répondre clairement, pour **ce Mac** (ou l'appareil de test branché) et pour **n'importe quel
  appareil** de l'inventaire : est-il branché sur un port PoE de la switch, et est-il alimenté
  par PoE en ce moment ?
- Ce Mac : à partir de la capture LLDP/CDP (note 2) : TLV 802.3 « Power via MDI » (port PSE,
  PoE activé, classe, type 802.3af/at/bt, puissance demandée et allouée) et TLV PoE de CDP ;
  LLDP-MED « Extended Power ». Afficher « Port PoE : oui / non », « Alimentation fournie :
  oui / non », classe et puissance.
- Autres appareils : par SNMP sur la switch (POWER-ETHERNET-MIB : pethPsePortAdminEnable,
  pethPsePortDetectionStatus « deliveringPower », pethPsePortPowerClassifications, et MIB
  propriétaires Cisco/HPE pour les watts) sur le port où l'appareil a été localisé.
- Afficher dans la fiche appareil, la colonne « PoE » du Scanner (colonne facultative, note 8),
  Switchs et ports (déjà la façade) et l'encart « Ce Mac est branché sur… ».
- Limite : un Mac ne consomme pas de PoE ; pour lui, la réponse dit seulement si le port de la
  switch est PoE et s'il fournit du courant.

## 13. Réglages encore « Bientôt » (demande de Dany)

**Livrée dans la 0.8.0** (4 novembre 2026) ; restent à venir : plusieurs sites (avec la note 10)
et la langue anglaise (reportée). Essais réels à faire (sauvegarde et restauration, SNMP v3, SSH).

Sections de Réglages à réaliser, fidèles au croquis `docs/croquis/Reglages.dc.html` :

- **Notifications** : notifications macOS (bannières et historique), choix des événements
  (sonde en panne, nouvel appareil, serveur DHCP non autorisé, mise à jour…), son, heures de
  silence (de… à…), bouton « Envoyer une notification de test ». Lié à la Surveillance (note 3).
- **Export et sauvegarde** : sauvegarde automatique quotidienne (réglages, sites, profils,
  inventaire et historiques), « Sauvegarder maintenant », liste des sauvegardes avec
  restauration, dossier choisi, nombre gardé ; formats d'export par défaut (CSV, JSON, PDF…).
  Les secrets du Trousseau ne sont jamais copiés en clair.
- **Raccourcis** : liste des raccourcis clavier de l'application et de la barre de menus
  (lancer le scan, ping de l'appareil choisi, ouvrir la fiche, copier l'IP/la MAC…), modifiables,
  avec détection des conflits ; menus de l'app mis à jour en conséquence.
- **Langue anglaise : reportée** (décision de Dany, 3 nov. 2026), gros chantier à part.
- Autres « bientôt » de Réglages, à traiter avec : thème sombre (note 9),
  « Test SNMP » des identifiants, identifiants SSH et WMI, choix des méthodes de découverte dans
  les profils de scan, plusieurs sites (avec la gestion par site, note 10).

## 14. Outils courriel et DNS (style « super outil ») (demande de Dany)

**Livrée dans la 0.6.0** (4 novembre 2026) ; essais réels à faire sur de vrais domaines et serveurs.

Nouveaux outils dans la Boîte à outils, sur le modèle d'une barre d'outils courriel/DNS :

- **Super outil** : un seul champ qui devine quoi faire (domaine, IP, adresse courriel, nom
  d'hôte) et lance les vérifications utiles, avec un bilan par couleur (OK, avertissement, erreur).
- **Recherche MX** : serveurs MX par priorité, leur IP, DNS inverse, cohérence (PTR qui revient
  au même nom).
- **Listes noires** : vérifier une IP ou un domaine dans les principales listes DNSBL/RBL
  (requêtes DNS) ; nombre de listes, lesquelles, lien de retrait ; contrôles répartis, limités.
- **DMARC** (et **SPF**, **DKIM**, **BIMI**, **MTA-STS**, **TLS-RPT**) : lire et expliquer
  l'enregistrement, détecter les erreurs (plus de 10 recherches DNS SPF, « +all », politique
  « none », syntaxe), sélecteurs DKIM courants à essayer.
- **Diagnostic SMTP** : connexion au port 25/587 du serveur, bannière, temps de réponse,
  STARTTLS et certificat, correspondance du DNS inverse ; aucun courriel envoyé, pas de test de
  relais ouvert sans accord explicite. Avertir si le port 25 sortant est bloqué par le FAI.
- **Santé courriel** : bilan d'un domaine (MX, SPF, DKIM, DMARC, listes noires, SMTP, DNSSEC)
  avec note et recommandations, exportable dans les Rapports (note 4).
- **Recherche DNS** : déjà là ; ajouter SOA, SRV, CAA, DNSKEY/DS, choix du serveur DNS,
  comparaison entre plusieurs serveurs, propagation.
- **Analyse d'en-têtes** : coller les en-têtes d'un courriel, afficher le trajet (chaque saut
  « Received » avec délai), SPF/DKIM/DMARC du message, expéditeur réel, alertes d'usurpation ;
  tout se fait en local, rien n'est envoyé.
- Tests : analyse d'enregistrements SPF/DMARC/DKIM et d'en-têtes fixes, sans réseau.

## 15. État des grands services en ligne (demande de Dany)

**Livrée dans la 0.6.0** (4 novembre 2026) ; essais réels à faire (pages d’état, Microsoft Graph).

Outil (Boîte à outils, et tuile dans Surveillance / barre de menus) qui montre d'un coup d'œil si
les grands services fonctionnent : Microsoft 365 (Outlook, Teams, SharePoint, OneDrive), Azure,
Apple (iCloud, App Store…), AWS, Google (Workspace, Cloud), Cloudflare, GitHub, Zoom, Slack,
Dropbox, Zscaler, fournisseurs Internet courants… liste modifiable.

- **Deux sources pour chaque service** :
  1. la page d'état officielle (flux JSON ou RSS publics : Apple System Status, AWS Health
     Dashboard, Azure Status, Google Workspace et Cloud, pages « Statuspage » `/api/v2/summary.json`
     de Cloudflare, GitHub, Zoom, Slack, Dropbox…) ; Microsoft 365 : page publique d'état, et
     santé détaillée du locataire par Microsoft Graph (Service Health) si Dany fournit un accès
     d'application, jeton au Trousseau ;
  2. un test **depuis ce réseau** : résolution DNS, connexion TLS et réponse HTTPS des adresses
     clés (ex. outlook.office365.com, login.microsoftonline.com), avec latence.
- Bilan qui distingue « panne chez eux » (page d'état en incident) et « problème chez nous »
  (page d'état OK mais injoignable d'ici : DNS, pare-feu, proxy, lien Internet).
- Liste des incidents en cours avec titre, services touchés, début, dernière mise à jour et lien
  vers la page officielle ; historique.
- Rafraîchissement réglable (5 min par défaut), notifications en cas de nouvel incident (note 13),
  alerte possible dans la Surveillance (note 3).
- Tests : analyse de réponses JSON/RSS fixes de chaque format, sans réseau.

## 16. Speedtest : choix du serveur (demande de Dany)

**Livrée dans la 0.5.0.**

- Remplacer « Choix d'un autre serveur (Ookla, serveur du fournisseur) : bientôt » par un vrai
  sélecteur de serveur : le plus proche automatiquement, ou un serveur choisi dans une liste
  (ville, opérateur, distance, latence mesurée), favoris, serveur personnalisé (adresse).
- Sources possibles, à vérifier avant de construire :
  - **Ookla (Speedtest.net)** : pas d'API publique libre ; leur outil officiel `speedtest`
    (CLI) a sa propre licence. Option honnête : si Dany l'a installé, NetScope le lance et lit
    son résultat JSON (avec mention de la licence) ; sinon, lien de téléchargement.
  - **Serveurs ouverts** : M-Lab (NDT7, gratuit, nombreux serveurs dont au Canada), serveurs
    LibreSpeed (souvent hébergés par des fournisseurs), Cloudflare (déjà utilisé ?), serveurs
    iperf3 publics pour le débit local/étendu.
  - **Serveur du fournisseur** : beaucoup de fournisseurs hébergent un serveur Ookla ou
    LibreSpeed ; le proposer en tête quand on le détecte (nom du fournisseur via l'IP publique).
- Historique : retenir le serveur utilisé pour chaque test et pouvoir comparer par serveur.
- Tests : analyse des listes de serveurs et des résultats fixes, sans réseau.

## 17. Bouton « Installer » pour les outils manquants (demande de Dany)

**Livrée dans la 0.5.0.**

- Là où NetScope dit qu'un outil manque (iperf3 dans Speedtest › Local, telnet dans Accès
  distant, et tout outil externe ajouté plus tard), afficher un bouton **« Installer »** au lieu
  du seul message.
- Si Homebrew est présent (`/opt/homebrew/bin/brew` ou `/usr/local/bin/brew`) : ouvrir Terminal
  avec `brew install iperf3` (commande fixe, visible avant de lancer ; Dany voit tout et peut
  annuler), puis revérifier la présence de l'outil quand Terminal a fini (bouton « Vérifier de
  nouveau », détection automatique).
- Si Homebrew est absent : expliquer et proposer « Installer Homebrew » (ouvre brew.sh, la
  commande officielle s'exécute dans Terminal, jamais en cachette), ou un lien vers le
  téléchargement officiel de l'outil.
- Rien n'est installé sans clic de Dany ; aucune élévation de droits cachée.
- Rappel côté appareil cible : pour iperf3, afficher aussi la commande `iperf3 -s` à lancer sur
  l'autre appareil (bouton Copier), et pour un Windows, le lien de téléchargement officiel.

## 18. Bilan des switchs périmé quand on change de plage — À PLANIFIER (demande de Dany)

- Constat : après un scan de 192.168.1.0/24, le Scanner affiche encore « Switch trouvé mais
  relevé impossible (10.182.122.124)… », qui vient d'un scan précédent sur 10.182.122.0/24.
  Cette information n'est plus valide pour la plage affichée.
- Correction : chaque bilan (switchs découverts, relevés impossibles, appareils localisés) est
  rattaché aux plages du scan qui l'a produit ; il disparaît, ou passe en « ancien scan » grisé,
  dès que les plages scannées ou affichées ne contiennent plus ces adresses (changement de plage,
  de réseau ou d'interface, ou nouveau scan sans ces switchs).
- Même principe pour les autres informations liées au réseau : passerelle, VLAN, emplacements
  Switch / Port, alertes d'Analyse, encart « Ce Mac est branché sur… » (périmé si l'interface
  ou le réseau change).
- Le message peut aussi préciser la plage concernée (« Plage 10.182.122.0/24 : … »).
- Tests : bilan conservé pour la même plage, effacé ou marqué ancien pour une autre plage.

## 19. Scanner : choisir le préréglage de ports sur place — À PLANIFIER (demande de Dany)

- Clic droit sur l'en-tête de la colonne « Ports ouverts » : menu des préréglages de ports
  (ceux de Réglages › Profils de scan : 20 ports essentiels, ports courants, ~1 000 ports,
  personnalisé…), avec coche sur celui en vigueur, « Modifier les préréglages… » (ouvre
  Réglages) et « Rescanner les ports avec ce préréglage ».
  **Remplacé dans la 0.4.0** : l'en-tête d'un `Table` SwiftUI ne prend ni menu ni clic droit à
  nous (son clic droit ne montre que les cases des colonnes) ; ce menu, identique, est celui du
  bouton « Ports : … » de la barre d'outils. **Reporté** : le mettre aussi sur l'en-tête si le
  tableau passe un jour à un en-tête AppKit (NSTableHeaderView).
- Même menu au clic droit sur un ou plusieurs appareils : « Scanner les ports › <préréglage> »
  (remplace l'actuel scan approfondi unique).
- Rappel visible du préréglage choisi près du bouton « Lancer le scan » (ex. « Ports : 20
  essentiels »), et choix aussi possible depuis ce bouton.
- Le choix fait dans le Scanner est retenu et reste cohérent avec Réglages (même liste, même
  source) ; un préréglage ajouté dans Réglages apparaît dans le menu.
- À faire avec les tableaux standard (note 8), qui gèrent déjà le clic droit sur l'en-tête.

## 20. Scanner : colonne « Type d'équipement » modifiable (demande de Dany)

- Ajouter au Scanner une colonne **Type** (icône + libellé : poste, serveur, imprimante, caméra,
  switch, point d'accès, routeur/pare-feu, téléphone, objet connecté, inconnu…), triable, visible
  par défaut.
- **Clic droit sur un ou plusieurs appareils › « Changer le type › … »** (liste des types, coche
  sur le type actuel, « Revenir au type détecté »). Aussi depuis le panneau de détail.
- Le type choisi à la main est celui de l'inventaire (`customType` d'InvModels, déjà modifiable
  dans le détail de l'Inventaire) : une seule source, retenue par MAC, reprise par la Carte,
  l'Analyse, les Rapports, la Surveillance et les scans suivants ; une petite marque indique
  « type choisi à la main ».
- Un scan ne remplace jamais un type choisi à la main.
- À faire avec les tableaux standard (note 8), dans la même version.

## 21. Ressources : processeur, mémoire, réseau (demande de Dany)

**Livrée dans la 0.5.0.**

- **Ce Mac** : processeur (total et par cœur), mémoire (utilisée, compressée, pression),
  réseau par interface (débit entrant/sortant en direct, totaux, erreurs), avec courbes sur
  quelques minutes ; lecture locale seulement (host_statistics, sysctl, getifaddrs), aucun
  trafic.
- **Appareils du réseau** (switchs, serveurs, imprimantes, NAS) par SNMP en lecture :
  processeur et mémoire (HOST-RESOURCES-MIB, MIB Cisco/HPE/Fortinet courantes), et surtout
  **trafic par port** (IF-MIB ifHCInOctets/ifHCOutOctets, erreurs, rejets) avec débit calculé et
  pourcentage de la vitesse du lien ; « top ports » les plus chargés d'un switch.
- Où : nouvel onglet dans la fiche Appareil et dans Switchs et ports (port choisi), tuile dans la
  barre de menus pour ce Mac, et sondes de Surveillance « Processeur > X % », « Mémoire > X % »,
  « Port saturé > X % » (note 3).
- Historique court en mémoire, export CSV ; intervalle réglable.
- Tests : calcul des débits à partir de compteurs fixes (y compris le retour à zéro des
  compteurs 32 bits), analyse des réponses SNMP fixes, sans réseau.

## 22. Test de vitesse des disques : local, réseau et nuage (demande de Dany)

**Livrée dans la 0.7.0** (4 novembre 2026) ; essais réels à faire (NAS, dossiers nuage).

- Nouvel outil (Speedtest ou Boîte à outils) qui mesure la vitesse d'écriture et de lecture
  d'un emplacement au choix :
  - **disque local** (SSD interne, disque externe USB/Thunderbolt) ;
  - **partage réseau** monté (SMB, NFS, AFP, NAS) : utile pour comparer au débit du lien ;
  - **dossiers nuage** : OneDrive, Google Drive, iCloud Drive, Dropbox (dossiers File Provider).
- Mesures : écriture et lecture séquentielles (Mo/s), accès aléatoires 4 Kio (IOPS, latence),
  en direct sur des jauges et une courbe ; taille du fichier d'essai au choix (1, 5, 10 Gio) et
  nombre de passes ; cache du système contourné (F_NOCACHE) pour des chiffres honnêtes.
- Nuage : la copie locale va vite, l'envoi réel se fait ensuite. Mesurer les deux : vitesse
  d'écriture dans le dossier, puis **temps jusqu'à « envoyé »** (état de synchronisation lu
  par les attributs du fichier quand le service les fournit), et débit Internet effectif ;
  le dire clairement quand un service ne donne pas cet état.
- Partage réseau : afficher à côté le débit du lien (Ethernet/Wi-Fi) et la latence vers le
  serveur, pour savoir si la limite vient du disque, du réseau ou du serveur.
- Sécurité : fichier d'essai dans un dossier « NetScope-test » supprimé à la fin (et au
  lancement suivant s'il reste), vérification de l'espace libre avant, bouton Arrêter ; aucun
  autre fichier touché ; avertir avant d'écrire plusieurs Gio dans un dossier nuage (quota,
  forfait).
- Historique des tests par emplacement, export CSV, ajout possible dans un Rapport (note 4).
- Tests : calculs de débit/IOPS sur des durées fixes, choix des emplacements, nettoyage, sans
  écrire de gros fichiers.

## 23. Alertes par courriel et webhook (demande de Dany)

**Livrée dans la 0.8.0** (4 novembre 2026) ; essais réels à faire (vrais serveurs SMTP,
Microsoft 365 et Gmail, canaux Teams et Slack).

- Réglages › Alertes : courriel (SMTP, STARTTLS sur 587 ou TLS sur 465, compte) et webhooks
  Microsoft Teams (Workflows), Slack ou JSON générique ; désactivées par défaut.
- Secrets (mot de passe SMTP, adresses des webhooks, en-tête d’authentification) au Trousseau.
- Règles : événements, gravité minimale, anti-rafale, regroupement, heures de silence ; journal
  des envois sans secret ; erreurs expliquées en français.
- Surveillance : canaux de chaque sonde dans l’éditeur, exclusion possible, colonne « Alertes
  externes ».
- Limites : authentification SMTP par mot de passe seulement (pas d’OAuth 2).

## 24. FortiGate et FortiSwitch gérés : lire la FortiGate (demande de Dany)

**Livrée dans la 0.9.0** (4 novembre 2026) ; essai réel à faire sur une vraie FortiGate
(versions de FortiOS, noms des champs, réponses brutes à copier au besoin).

Réseau de Dany : FortiGate, FortiSwitch gérés par FortiLink (et FortiManager), adresses des
switchs dans 10.255.1.0/24, réseau FortiLink non routé vers le LAN : NetScope ne les voit pas.

- Choix : interroger la FortiGate par son API REST (HTTPS, jeton d’un administrateur « API
  REST » en lecture seule, hôtes de confiance limités au Mac), sans router 10.255.1.0/24 ni
  activer SNMP sur les switchs.
- Réglages › Switchs : source « Contrôleur FortiGate » (adresse, port HTTPS, jeton au
  Trousseau, certificat autosigné accepté par empreinte, bouton Tester, rafraîchissement).
- Données : FortiSwitch gérés (nom, modèle, série, firmware, état, IP FortiLink), ports (lien,
  vitesse, PoE, VLAN), appareils détectés par port (MAC → switch, port, VLAN), table ARP et
  baux DHCP de la FortiGate.
- Effet : l’écran Switchs et ports montre les FortiSwitch ; le Scanner remplit Switch / port et
  VLAN par la FortiGate, avant SNMP.
- Limites : noms des champs selon la version de FortiOS (lecture tolérante, réponse brute
  copiable pour ajuster) ; FortiManager (plusieurs sites) plus tard ; rien d’essayé sur une
  vraie FortiGate avant l’essai de Dany.

## 25. Plusieurs FortiGate : une clé par site, choisie par plage IP (demande de Dany)

**Livrée dans la 0.10.0** (4 novembre 2026) ; essai réel à faire sur plusieurs sites (import
CSV, un jeton par site, choix par plage, chevauchements, « Tester tout »).

Essais de la 0.9.0 réussis sur le réseau de Dany. Il a 20 sites, chacun avec sa FortiGate et son
jeton API.

- Réglages › Switchs › Contrôleurs FortiGate : liste (site, adresse, port, VDOM, plages couvertes,
  jeton au Trousseau par entrée, empreinte du certificat par entrée, état).
- Plages couvertes saisies ou remplies au « Tester » d’après les sous-réseaux des interfaces de la
  FortiGate.
- Choix de la clé : plage scannée, sinon IP du Mac ; plage la plus précise en cas de chevauchement
  (conflit signalé) ; aucun site : pas de clé, SNMP ; plusieurs sites scannés : chaque FortiGate
  concernée.
- Import CSV `site;adresse;port;vdom;plages` (sans jeton), « Tester tout », bandeau « FortiGate
  utilisée : … » dans Switchs et ports.
- Migration : la FortiGate de la 0.9.0 devient la première entrée, sans ressaisie.
- Jetons jamais exportés (sauvegardes, CSV, journaux).

## 26. Recherche multiple dans tous les modules (demande de Dany)

**Livrée dans la 0.11.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan.

« Dans recherche, peu importe le module, pouvoir faire une recherche multiple : numéro de switch
+ type par exemple. »

- Plusieurs mots = tous à la fois (ET) ; préfixes de champ (`switch:`, `port:`, `vlan:`, `type:`,
  `fab:`, `ip:`, `mac:`, `nom:`, `site:`…) ; `-mot` pour exclure ; "phrase exacte" ; mot sans
  préfixe = toutes les colonnes (rien ne change pour une recherche simple).
- Chaque critère devient une étiquette retirable ; menu des préfixes du module.
- Un seul moteur dans NetScopeCore, branché sur toutes les recherches (Scanner, Inventaire,
  Switchs et ports, Analyse, Surveillance, Accès distant, Outils, Réglages…).

## 27. Module Wi-Fi : FortiAP, analyse et diagnostic (demande de Dany)

**Livrée dans la 0.11.0** (4 novembre 2026) ; essai réel à faire sur une vraie FortiGate avec
des bornes FortiAP (droit « WiFi & Switch Controller » en lecture).

- Par la FortiGate de chaque site (liste de la 0.10.0), en lecture seule : FortiAP gérés (état,
  modèle, firmware, IP, radios : canal, largeur, puissance, clients, utilisation du canal),
  clients Wi-Fi (MAC, IP, nom, SSID, borne, bande, RSSI/SNR, débit), SSID diffusés, AP voisins et
  non autorisés.
- Diagnostic : carte des canaux et chevauchements, clients à signal faible, bornes hors ligne ou
  surchargées, conseils en clair.
- Scanner et fiche Appareil : borne FortiAP et SSID d'un appareil en Wi-Fi (comme Switch / port).
- Surveillance (sonde FortiAP hors ligne, borne surchargée) et section Wi-Fi des Rapports.
- Droit « WiFi » en lecture à ajouter au profil API si nécessaire.

## 28. Sites : préréglages du Scanner, switchs associés, mêmes plages sur plusieurs sites (demande de Dany)

**Livrée dans la 0.12.0** (4 novembre 2026), avec la correction de la Carte du réseau (dernier
scan seulement), la suppression dans l'Inventaire et le choix d'un ou plusieurs sites ; essai réel à faire sur les sites de Dany (détection, migration, import CSV).

« Je voudrais avoir des presets de site dans le Scanner, car je delete et reconstruis à chaque
fois. » « Dans Switchs et ports, il affiche aussi la switch qui n'est pas dans le range du scan
(pas une switch Fortinet). Associer dans les réglages des switchs une switch non Fortinet à un
site. Il est possible d'avoir plusieurs sites sous la même plage IP. »

- Le site devient la référence : nom, plages (libellé, VLAN), FortiGate associée(s), switchs SNMP
  associés.
- Pas de niveau Client (décision de Dany) : un site porte au besoin le nom du client
  (« Clinique Exemple », « Groupe X · Laval »). Plusieurs sites peuvent avoir les mêmes plages : l'IP seule ne choisit jamais le site.
- Scanner : menu « Site » en haut des plages ; choisir un site remplace les plages ; enregistrer
  les plages comme site, mettre à jour le site ; « Détecter mon site » par la passerelle (MAC,
  numéro de série ou nom de la FortiGate), jamais par la seule IP ; création des sites depuis les
  FortiGate de la 0.10.0 ; import et export CSV.
- Résultats par site : changer de site met les résultats de côté et les retrouve au retour ;
  Scanner, Carte et Inventaire ne mélangent plus deux sites.
- Inventaire unique à chaque site (demande de Dany) : appareils suivis, historique, archive,
  exclusions et types choisis à la main propres au site ; l'inventaire actuel va au « Site principal ».
- Réglages › Switchs : chaque switch SNMP (non Fortinet) peut être associé à un site.
  Switchs et ports n'affiche que les switchs du site actif (FortiSwitch par sa FortiGate, switchs
  SNMP associés) ; un switch sans site n'apparaît que s'il est dans les plages scannées.
- FortiGate : choisie d'abord par le site actif ; la plage IP ne sert qu'en l'absence de site.
- Barre latérale « Sites », Réglages › Sites et plages (fin du « Plusieurs sites : bientôt »),
  préfixe `site:` de la recherche.
- Inventaire : suppression d'appareils (demande de Dany) : sélection multiple, clic droit,
  touche ⌫ et corbeille ; confirmation avec le nombre d'appareils et les sites touchés, case
  « Ne plus suivre ces appareils » (exclusion du site) ; Annuler et Rétablir.
- Choix d'un ou plusieurs sites (menu « Site ▾ ») dans l'Analyse, l'Inventaire, la Carte et les
  Rapports, sans changer le site actif du Scanner ; lignes jamais fusionnées entre sites, colonne
  « Site », rapport multisite (une section par site), un dessin de carte par site.

## 29. Relire en automatique — 0.17.0 (demande de Dany)

**Livrée dans la 0.17.0** (4 novembre 2026) ; essai réel à faire sur les FortiGate de Dany (intervalles, pauses, essais espacés après une erreur).

- Relecture périodique, sans relancer de scan, de la FortiGate (FortiSwitch, FortiAP), des
  switchs SNMP et des emplacements des appareils (aujourd'hui : boutons « Relire la FortiGate »,
  « Relire les bornes », « Interroger les switchs » ou fin de scan).
- Intervalle réglable par site, pause quand le site n'est pas le site actif.

## 30. Type « Téléphonie IP » — 0.14.0 (demande de Dany)

**Livrée dans la 0.14.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Nouveau type pour les téléphones IP (Yealink, Poly, Cisco, Mitel, Grandstream, Fanvil, Snom…),
  distinct de « Téléphone » (cellulaires).
- Détection : fabricant (OUI), ports SIP 5060/5061, annonce LLDP-MED, VLAN voix.
- Clic droit « Changer le type », import CSV, Carte, Rapports, comme les autres types.

## 31. Carte → Inventaire filtré sur la branche choisie (demande de Dany)

**Livrée dans la 0.13.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Dans la Carte du réseau, quand on choisit une branche ou un groupe (ex. « Téléphones ×11 », un
  switch et ce qui est branché dessous) puis « Inventaire », l'Inventaire s'ouvre filtré sur ces
  appareils seulement (aujourd'hui : il s'ouvre sans filtre).
- Le filtre s'affiche comme une étiquette retirable (recherche multiple, note 26), par exemple
  « Carte : Téléphones ×11 · SW-ETG2-01 », et garde le site affiché sur la Carte.
- Même chose vers le Scanner et Switchs et ports depuis le détail du nœud.

## 32. Recherche dans la Carte du réseau — 0.14.0 (demande de Dany)

**Livrée dans la 0.14.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Une recherche dans la Carte (ex. une IP, un nom, une MAC, `switch:…`, recherche multiple de la
  note 26) trouve l'appareil et montre où il est : la carte se centre sur sa branche, le nœud (ou
  le groupe qui le contient, ex. « Téléphones ×11 ») est surligné, et le détail affiche sa fiche
  (IP, MAC, switch / port, VLAN, borne Wi-Fi) avec « Ouvrir la fiche ».
- Plusieurs résultats : liste à parcourir (suivant / précédent) ; aucun : message clair.
- Avec plusieurs sites (0.12.0) : cherche dans le site dessiné, et propose les autres sites où
  l'IP existe.

## 33. Switchs et ports : double-clic sur un port → l'appareil (demande de Dany)

**Livrée dans la 0.13.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Un double-clic sur un port (façade du switch ou tableau des ports, SNMP ou FortiSwitch) ouvre
  la fiche de l'appareil branché sur ce port (fiche Appareil, ou Inventaire du site si l'appareil
  n'est pas dans le dernier scan).
- Plusieurs appareils sur le port (téléphone + poste, petit switch, borne Wi-Fi) : liste à choisir,
  ou Inventaire filtré sur ce port (étiquette `switch:… port:…`).
- Port sans appareil connu : message clair (port vide, uplink/trunk, ou appareil pas encore vu).

## 34. Double-clic partout : une suite logique entre les modules (demande de Dany)

**Livrée dans la 0.13.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

« Si je double-clique sur n'importe quel élément, il y a une suite logique dans l'application
entre ces modules. » Règle commune à tout NetScope (englobe les notes 31 et 33) :

- Appareil (Scanner, Inventaire, Analyse, Carte, Surveillance, Wi-Fi clients) → sa fiche Appareil.
- Switch → Switchs et ports sur ce switch ; port → l'appareil branché (note 33).
- Borne FortiAP → Wi-Fi › FortiAP sur cette borne ; client Wi-Fi → sa fiche Appareil.
- Groupe ou branche de la Carte → Inventaire filtré sur ces appareils (note 31).
- Plage, VLAN ou site → Scanner (ou Inventaire) filtré sur cette plage, ce VLAN, ce site.
- Sonde ou alerte de Surveillance → la sonde, puis l'appareil ou le service concerné ;
  événement d'Analyse → l'appareil et sa chronologie.
- Service en ligne, résultat d'outil, sauvegarde, connexion d'Accès distant → leur détail.
- Toujours : le même geste partout (double-clic, ou ↩︎), un menu contextuel « Ouvrir dans… »
  qui propose les autres modules, et « Retour » (⌘[) vers l'écran d'où l'on vient.

## 35. Journal de l’app et « Exporter un diagnostic » — 0.23.0 (analyse, retenue par Dany)

**Livrée dans la 0.23.0** (5 novembre 2026) : Réglages › Journal et diagnostic, secrets masqués, « Exporter un diagnostic… » en .zip, bannière après une fermeture inattendue et pastille sur Réglages ; essai réel à faire sur de vraies erreurs FortiGate et SNMP.

- Journal interne consultable (erreurs, avertissements, appels FortiGate/SNMP en échec, avec date
  et module), visible dans l’app ; export .zip « diagnostic » sans aucun secret (jetons,
  communautés, mots de passe masqués) ; rapport des plantages précédents au lancement.

## 36. Essais de charge sans réseau (analyse, retenue par Dany)

**Livrée dans la 0.13.0** (4 novembre 2026), avec l’inventaire enregistré en arrière-plan et les lenteurs corrigées ; essai réel à faire sur un très gros site.

- Tests de performance avec des données fictives : 20 sites, plages de 65 536 adresses, gros
  inventaires et historiques ; temps d’ouverture des écrans, de changement de site, d’écriture
  de l’inventaire (aujourd’hui réécrit en entier à chaque changement).

## 37. Occupation des étendues DHCP — 0.14.0 (analyse, retenue par Dany)

**Livrée dans la 0.14.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Par la FortiGate (baux et étendues) et le Test DHCP : taux d’occupation de chaque étendue,
  alerte « étendue presque pleine », sonde de Surveillance, ligne dans les rapports.

## 38. Sauvegarde chiffrée par mot de passe — 0.14.0 (analyse, retenue par Dany)

**Livrée dans la 0.14.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- Archive de sauvegarde chiffrée (mot de passe choisi), jetons et secrets inclus en option
  (chiffrés) pour restaurer un 2e Mac sans ressaisir 20 jetons ; sans mot de passe : comme
  aujourd’hui, jamais de secret.

## 39. État du WAN de chaque FortiGate — 0.17.0 (analyse, retenue par Dany)

**Livrée dans la 0.17.0** (4 novembre 2026) ; essai réel à faire sur les FortiGate de Dany (champs SD-WAN, IPsec et VPN SSL renvoyés par FortiOS).

- Liens WAN et SD-WAN (état, latence, perte, gigue), tunnels VPN IPsec (montés ou tombés),
  par site ; sondes « tunnel tombé » et « lien WAN dégradé » ; vue de tous les sites.

## 40. Sauvegarde des configurations — 0.30.0, ex-0.24.0 (analyse, retenue par Dany)

- Copie de la configuration de chaque FortiGate (API, lecture), puis des switchs en SSH ;
  historique par site, comparaison avant/après (différences surlignées), avant une intervention.

## 41. Firmware et licences du parc — 0.21.0 (analyse, retenue par Dany)

**Livrée dans la 0.21.0** (4 novembre 2026) ; essai réel à faire sur les FortiGate, FortiSwitch et FortiAP de Dany (champs du firmware et des licences selon FortiOS, droits du jeton).

- Versions FortiOS, FortiSwitch et FortiAP de chaque site, versions recommandées, contrats
  FortiGuard et dates d’expiration ; tableau de tous les sites et drapeau « firmware à jour » du
  rapport enfin rempli ; alertes avant expiration.

## 42. Rapport de suivi et rapports planifiés — 0.20.0 (analyse, retenue par Dany)

**Livrée dans la 0.20.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

- « Depuis le dernier rapport » : nouveaux appareils, disparus, problèmes réglés ou nouveaux
  (réutilise la comparaison de l’Analyse) ; rapports produits à date fixe par site.

## 43. Récepteur Syslog et traps SNMP — 0.21.0 (analyse, retenue par Dany)

**Livrée dans la 0.21.0** (4 novembre 2026) ; essai réel à faire sur de vrais équipements (Syslog de la FortiGate, des FortiSwitch, Cisco et HPE Aruba, traps, coupe-feu de macOS, journaux d'événements par l'API).

- Réception Syslog et traps SNMP sur le Mac, journaux de la FortiGate par l’API ; recherche
  par heure, appareil et gravité, pour comprendre une coupure intermittente.

## 44. Aide intégrée et accueil au premier lancement — retirée (analyse, retirée par Dany)

**Retirée à la demande de Dany** (4 novembre 2026) : ne pas la réaliser.

- Accueil au premier lancement (autorisations, premier site, FortiGate), bouton « ? » dans
  chaque écran, menu Aide rempli (aujourd’hui vide).

## 45. Retour à l'écran d'avant, dans tous les modules — 0.15.0 (demande de Dany)

**Livrée dans la 0.15.0** (4 novembre 2026), après la 0.13.0 (note 34 : Retour / Avancer ⌘[ ⌘],
recherche, filtre et sélection rendus tels quels) : le bouton nomme l'écran d'origine, la ligne
choisie revient en vue et l'historique se vide au changement de site ; essai réel à faire sur un
vrai scan et les sites de Dany.

« Revenir à l'écran d'avant, peu importe le module, après un double-clic sur un élément. »
Exemple : Inventaire › double-clic sur une IP › fiche Appareil › Retour › Inventaire. Précise
le « Retour » de la note 34 :

- Un historique de navigation commun à toute l'app (dans `AppState`) : chaque saut par
  double-clic, ↩︎ ou « Ouvrir dans… » empile l'écran de départ.
- Bouton ‹ Retour dans la barre d'outils (et › Avancer), raccourcis ⌘[ et ⌘], menu
  Présentation › Retour ; le bouton nomme l'écran d'origine (« ‹ Inventaire »).
- Au retour, l'écran revient tel qu'on l'a laissé : filtre, recherche, tri, sélection et
  position dans la liste (ex. la même ligne de l'Inventaire sélectionnée).
- Un clic dans la barre latérale vers un autre module compte aussi comme un écran de
  l'historique ; l'historique se vide en changeant de site.

## 46. Wi-Fi : clients par borne et par SSID, fiche complète du client — 0.16.0 (demande de Dany)

**Livrée dans la 0.16.0** (4 novembre 2026) ; essai réel à faire sur les FortiGate et bornes FortiAP de Dany.

« Si je clique sur un AP, je vois qui est connecté ; dans la section Wi-Fi, clients vs SSID,
donc l'info complète du client. » Prolonge la note 27 (liste des clients livrée dans la 0.11.0) :

- Clic (ou double-clic) sur une borne FortiAP → la liste des clients connectés à cette borne,
  par radio (2,4 / 5 / 6 GHz) et par SSID, avec le nombre de clients de chaque SSID.
- Section Wi-Fi › Clients : vue regroupée par SSID (chaque SSID dépliable, avec son nombre de
  clients, ses bornes et sa bande), recherche par nom, IP ou MAC, tri et filtres (SSID, borne,
  bande, signal faible).
- Fiche complète du client : nom, fabricant (OUI), MAC, IP, VLAN, SSID, borne et radio, bande,
  canal, RSSI, SNR, débit montant et descendant, standard (Wi-Fi 4/5/6/6E/7), authentification
  (PSK, 802.1X, utilisateur), durée de connexion, octets échangés, historique d'itinérance
  entre bornes ; liens vers la fiche Appareil, l'Inventaire et le Ping continu (note 34).
- Retour vers la borne ou le SSID d'origine (note 45).
- Fiche Appareil (demande de Dany, 4 nov.) : si l'IP est un client Wi-Fi, la fiche Appareil montre
  toutes les informations utiles au diagnostic : signal (RSSI, SNR, bruit, historique du signal),
  borne et radio, SSID, bande, canal et largeur, standard, sécurité et authentification, VLAN,
  débits montant/descendant et négocié, octets, durée de connexion, itinérances, déconnexions,
  clients et utilisation du canal de la borne, problèmes repérés et bouton « Diagnostiquer »
  (note 47).

## 47. Diagnostic des problèmes Wi-Fi d'un client, avec solutions — 0.16.0 (demande de Dany)

**Livrée dans la 0.16.0** (4 novembre 2026), avec le correctif iCloud de Vitesse des disques
(fusionné en 4c18dbd) ; essai réel à faire sur un vrai client Wi-Fi.

« Diagnostiquer les troubles Wi-Fi des clients, la lenteur, toutes les possibilités, et
suggérer la résolution. » Va plus loin que le diagnostic général de la note 27 : un bouton
« Diagnostiquer » sur la fiche d'un client Wi-Fi (note 46), sur une borne et sur un SSID,
qui vérifie chaque cause possible, dit en clair ce qui ne va pas et propose quoi faire.

- Signal : RSSI faible ou SNR bas (client trop loin, obstacle) → rapprocher la borne, en
  ajouter une, vérifier la puissance d'émission ; client « collant » resté sur une borne
  éloignée → activer l'itinérance assistée (802.11k/v/r), seuil de RSSI minimal.
- Canal et interférences : canal saturé, chevauchement avec les bornes voisines ou les AP
  non autorisés, largeur trop grande en 2,4 GHz, DFS (changements de canal radar) → canal
  et largeur conseillés, plan de canaux.
- Charge : trop de clients sur la borne ou la radio, utilisation du canal élevée, clients
  lents (anciens standards, bas débits de base) qui ralentissent tout le monde → équilibrage
  de charge, pilotage de bande vers 5/6 GHz, retirer les débits anciens.
- Client : débit négocié bas, standard ancien (Wi-Fi 4), une seule antenne, pilote ou
  économie d'énergie, bande 2,4 GHz alors que 5 GHz est possible → conseils pour le poste.
- Connexion et authentification : échecs ou déconnexions répétées, itinérances trop
  fréquentes, mauvais mot de passe, 802.1X / RADIUS refusé, délai DHCP, pas d'IP ou IP
  169.254 → cause probable et correction.
- Au-delà du Wi-Fi : perte et latence vers la passerelle, le DNS et Internet (Ping continu,
  traceroute), lien de la borne vers son switch (port, PoE, vitesse, erreurs, note 33), WAN
  et SD-WAN du site (note 39), limite de bande passante ou mise en forme du trafic par SSID.
- Résultat : un verdict par cause (OK, à surveiller, problème), la cause la plus probable en
  tête, les mesures qui le prouvent, les actions suggérées dans l'ordre, et un export dans le
  rapport du site ; suivi dans le temps (le problème revient-il à certaines heures ?).
- Lecture seule sur la FortiGate : NetScope propose, le technicien applique.

## 48. Switchs et Wi-Fi : choisir le site — 0.15.0 (demande de Dany)

**Livrée dans la 0.15.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

« Dans les modules Switch et Wi-Fi, avoir la possibilité de choisir le site. » Étend aux deux
modules le menu « Site ▾ » que la note 28 donne à l'Analyse, à l'Inventaire, à la Carte et aux
Rapports :

- Menu « Site ▾ » en haut de Switchs et ports et de Wi-Fi, ouvert par défaut sur le site actif ;
  choisir un autre site n'y change pas le site actif du Scanner.
- Switchs : les FortiSwitch de la FortiGate du site choisi et les switchs SNMP associés à ce site ;
  Wi-Fi : ses FortiAP, SSID, clients et AP voisins (notes 27 et 46), par sa FortiGate.
- Option « Tous les sites » : liste groupée par site, colonne « Site », recherche commune ;
  jamais de mélange entre deux sites qui partagent les mêmes plages.
- Le site choisi est retenu par module et suit les sauts entre modules (double-clic sur une borne
  ou un port, note 34 ; Retour, note 45) ; message clair si le site n'a ni FortiGate ni switch.

## 49. Choix du site sous le logo NetScope — 0.15.0 (demande de Dany)

**Livrée dans la 0.15.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

« Pouvoir choisir le site sous le logo NetScope. » Un sélecteur de site unique, toujours visible
en haut de la barre latérale :

- Juste sous le logo NetScope : menu « Site ▾ » avec le nom du site actif (et sa pastille
  d'état : FortiGate jointe ou non) ; liste des sites avec recherche, « Tous les sites »,
  « Détecter mon site » et « Gérer les sites… » (Réglages › Sites et plages).
- Choisir un site ici change le site actif de toute l'app : plages du Scanner, Inventaire,
  Carte, Analyse, Switchs, Wi-Fi, Surveillance et Rapports (note 28) ; les menus « Site ▾ »
  propres à un module (note 48) restent des choix ponctuels qui ne touchent pas ce site actif.
- Raccourci clavier (⌘⇧S) et menu de la barre de menus pour changer de site ; le site actif
  est rappelé dans le titre de la fenêtre.
- Changer de site vide l'historique Retour (note 45) et retrouve les résultats laissés sur
  l'autre site (note 28).

## 50. Connexion FTP, FTPS et SFTP — 0.18.0 (demande de Dany)

**Livrée dans la 0.18.0** (4 novembre 2026) ; essai réel à faire sur de vrais serveurs FTP, FTPS (certificat autosigné d'un NAS) et SFTP, et le serveur FTP temporaire avec un vrai appareil.

« Pouvoir se connecter à un FTP. » Nouveau type de connexion dans Accès distant, à côté de
Terminal, SSH, Telnet, RDP et VNC :

- Protocoles : FTP (mode passif et actif), FTPS (TLS explicite et implicite) et SFTP (par SSH,
  mot de passe ou clé, avec les clés déjà connues d'Accès distant).
- Navigateur de fichiers en deux volets (Mac ↔ serveur) : parcourir, glisser-déposer pour
  envoyer ou recevoir, créer un dossier, renommer, supprimer (avec confirmation), droits et
  dates ; file des transferts avec progression, débit, reprise après coupure et annulation.
- Cas de technicien : envoyer un firmware ou une configuration à un switch, une borne ou une
  imprimante, récupérer des journaux ou une sauvegarde (note 40) ; mini serveur FTP/TFTP
  temporaire sur le Mac pour les appareils qui viennent chercher leur fichier eux-mêmes.
- Depuis un appareil (fiche Appareil, Scanner, Inventaire, clic droit) : « Ouvrir en FTP »,
  « FTPS » ou « SFTP » seulement si le port correspondant est ouvert au dernier scan (21, 990
  ou 22, ou le port réglé dans la connexion) ; port fermé ou inconnu : choix grisé, avec
  « Vérifier le port » pour le tester tout de suite (note 34) ; connexions enregistrées dans
  le carnet, par site.
- Mots de passe dans le trousseau macOS, jamais en clair ; avertissement quand le FTP n'est pas
  chiffré ; aucune dépendance externe (Network.framework et le SSH déjà présent).

## 51. Serveur et client TFTP dans la Boîte à outils — 0.18.0 (demande de Dany)

**Livrée dans la 0.18.0** (4 novembre 2026) ; essai réel à faire sur un switch Cisco ou Aruba, une FortiGate et un téléphone IP (port 69, coupe-feu de macOS, gros firmware).

« Une application TFTP dans Outils. » Nouvel outil « TFTP » dans la Boîte à outils (la note 50
n'en prévoyait qu'un mini serveur temporaire, côté Accès distant) :

- Serveur TFTP sur le Mac : choix du dossier partagé et de l'interface d'écoute (IP affichée en
  grand, à copier), port 69 (ou un autre port), lecture seule ou lecture et écriture ; démarrer
  et arrêter d'un bouton, arrêt automatique après un délai.
- Client TFTP : envoyer (put) ou récupérer (get) un fichier vers un appareil, par son IP ou
  depuis le Scanner / la fiche Appareil.
- Journal en direct : qui demande quel fichier, progression, débit, réussite ou erreur en clair
  (fichier introuvable, accès refusé, délai dépassé) ; historique des transferts par site.
- Options RFC : taille de bloc, fenêtre, délai et nombre d'essais (tsize, blksize, timeout),
  pour les gros firmwares ; mode binaire (octet) par défaut.
- Cas de technicien : sauvegarder ou restaurer la configuration d'un switch, d'un téléphone IP
  ou d'une borne, mettre à jour un firmware, servir les fichiers de provisionnement des
  téléphones (option DHCP 66, note 30).
- Sécurité : avertissement si le pare-feu macOS bloque le port, serveur jamais lancé tout seul,
  dossier limité au partage choisi (pas de « ../ »), alerte avant d'écraser un fichier ; aucune
  dépendance externe (Network.framework, UDP).

## 52. SSH : entrer le nom d'utilisateur à la connexion — 0.15.0 (demande de Dany)

**Livrée dans la 0.15.0** (4 novembre 2026) ; essai réel à faire sur un vrai scan et les sites de Dany.

« Quand je me connecte en SSH, avoir la possibilité d'entrer le nom d'utilisateur. »
Aujourd'hui le nom n'existe que dans une connexion enregistrée du carnet (Accès distant) ;
une connexion rapide (depuis le Scanner, la fiche Appareil ou l'Inventaire) part sans lui.

- Petite fenêtre avant chaque connexion SSH rapide : champ « Utilisateur » prérempli (dernier
  nom utilisé pour cet appareil, sinon le nom par défaut du site ou des Réglages), port, clé ou
  mot de passe ; ↩︎ pour se connecter, case « Ne plus demander pour cet appareil ».
- Liste des noms déjà utilisés (admin, root, manager…) et saisie libre ; forme `user@ip`
  acceptée dans le champ de connexion d'Accès distant et dans la recherche.
- Nom retenu par appareil et par site, avec « Enregistrer dans le carnet » ; mot de passe dans
  le trousseau macOS, jamais en clair.
- Même champ pour Telnet, SFTP / FTP (note 50), RDP et VNC quand ils demandent un compte.

## 53. Services en ligne : réseaux sociaux et assistants IA — 0.18.0 (demande de Dany)

**Livrée dans la 0.18.0** (4 novembre 2026) ; formats vérifiés le 4 novembre 2026 : Claude = Statuspage
(status.claude.com, status.anthropic.com y redirige), ChatGPT = incident.io (summary.json
compatible Statuspage), Copilot = page Microsoft 365 filtrée sur « Copilot » ; metastatus.com
(Meta), status.x.ai (Grok), TikTok et Snapchat : aucun flux lisible, test depuis ce réseau
seulement. Essai réel à faire derrière une FortiGate qui filtre (page de blocage FortiGuard,
filtrage DNS, inspection de certificat, contrôle des applications).

Ajouter au catalogue de la note 15 (`SvcCatalog.swift`, livré dans la 0.6.0) une catégorie
« Réseaux sociaux » et une catégorie « Assistants IA » :

- Réseaux sociaux : Facebook, Instagram (Meta, page d'état de Meta et test des adresses clés,
  ex. www.facebook.com, www.instagram.com, graph.facebook.com), TikTok, Snapchat.
- Assistants IA : Claude (status.anthropic.com, Statuspage JSON ; claude.ai, api.anthropic.com),
  ChatGPT (status.openai.com ; chatgpt.com, api.openai.com), Microsoft Copilot (page d'état
  Microsoft 365 et copilot.microsoft.com), Grok (x.ai ; grok.com, x.com).
- Pour chaque service : page d'état officielle quand elle existe (vérifier le format : Statuspage,
  incident.io, RSS…), sinon test depuis ce réseau seulement (DNS, TLS, HTTPS, latence), comme
  Zscaler et Okta ; « panne chez eux » vs « problème chez nous » (filtrage web, pare-feu).
- Utile pour le technicien : savoir si un site est bloqué par le filtrage de la FortiGate
  (catégorie web, contrôle des applications) plutôt qu'en panne ; services cochés ou non par
  site (ex. réseaux sociaux masqués là où ils sont bloqués exprès).

## 54. FortiView : trafic et analyse complète du réseau — 0.17.0 (demande de Dany)

**Livrée dans la 0.17.0** (4 novembre 2026) ; essai réel à faire sur les FortiGate de Dany (droits « Log & Report » et « FortiView », historique selon la journalisation).

« Ajouter FortiView, le trafic, une analyse complète du réseau. » Nouvel écran « Trafic »
(groupe SUIVI), lu sur la FortiGate de chaque site par l'API REST de FortiOS (moniteurs
FortiView), en lecture seule comme les notes 24 et 25 :

- Vues FortiView : sources (appareils et utilisateurs), destinations (IP, pays, domaines),
  applications (contrôle des applications), catégories web, interfaces et liens WAN,
  politiques de pare-feu, sessions en cours, menaces (IPS, antivirus, filtrage web bloqué).
- Périodes : temps réel, 5 min, 1 h, 24 h, 7 jours (selon ce que garde la FortiGate ou
  FortiAnalyzer / FortiGate Cloud s'il est relié) ; tri par débit, octets, sessions.
- Lien avec NetScope : chaque source reliée à sa fiche Appareil, son port de switch et sa borne
  Wi-Fi (double-clic, note 34) ; « Qui sature le lien ? » en un clic ; vue « Tous les sites ».
- Analyse complète du réseau : un bilan qui réunit trafic (plus gros consommateurs, applications
  inattendues, pays inhabituels), sécurité (menaces, appareils infectés ou bloqués), santé
  (WAN et SD-WAN, note 39 ; ports de switch saturés ou en erreur ; Wi-Fi, notes 46 et 47 ;
  étendues DHCP, note 37) et inventaire (appareils inconnus) ; points classés par gravité,
  avec explications et actions conseillées, et une section « Trafic » dans les Rapports.
- Surveillance : sondes « lien saturé », « appareil qui consomme trop », « nouvelle menace ».
- Droits du profil API à ajouter en lecture : « Log & Report » et « FortiView » si nécessaire.

## 55. Vitesse des disques : ajouter un NAS, un partage SMB ou un autre emplacement — 0.18.0 (demande de Dany)

**Livrée dans la 0.18.0** (4 novembre 2026), sauf FTP, FTPS et SFTP comme emplacements (à brancher sur la connexion de la note 50) ; essai réel à faire sur le NAS de Dany (SMB, NFS, montage et démontage, erreurs).

« Dans speeddisk, je veux avoir la possibilité d'ajouter un NAS, SMB, autre. » Dans Outils ›
Vitesse des disques, bouton « Ajouter un emplacement… » à côté des disques détectés :

- Types : NAS ou partage SMB (`smb://serveur/partage`), NFS, AFP, WebDAV, et « Autre » (un
  dossier quelconque choisi dans le Finder) ; FTP, FTPS et SFTP par la connexion de la note 50.
- Saisie : serveur (nom ou IP, ou un appareil choisi dans le Scanner ou l'Inventaire), partage,
  utilisateur ; mot de passe dans le trousseau macOS, jamais en clair.
- Montage par NetFS dans l'app si le partage n'est pas déjà monté, puis démontage après le test
  seulement si c'est NetScope qui l'a monté ; erreurs expliquées (mauvais mot de passe, partage
  introuvable, SMB1 refusé, droits d'écriture).
- « Tester le serveur » avant le test de vitesse : ping, ports 445 (SMB), 2049 (NFS), 548 (AFP),
  80/443 (WebDAV) ; emplacements enregistrés par site et retrouvés dans la liste.
- Bilan habituel (lien réseau du Mac, limite réseau ou disque) et historique par emplacement.

## 56. Configuration : exporter, importer et synchroniser entre Mac — 0.18.0 (demande de Dany)

**Livrée dans la 0.18.0** (4 novembre 2026) ; essai réel à faire entre deux Mac de Dany (export et import chiffrés, synchronisation iCloud Drive, conflits).

« Je veux importer et exporter la configuration de NetScope… et iCloud sync aussi, comme dans
mon cas plusieurs Mac. » Puis : « je veux tout inclure, pour une facilité de configuration. »

- Réglages › Sauvegarde : « Exporter la configuration… » et « Importer la configuration… » ;
  tout est coché par défaut : sites et préréglages, FortiGate et leurs jetons, switchs et
  communautés SNMP, identifiants SSH et WMI, SMTP et webhooks, réglages, raccourcis, profils de
  scan, inventaires et historiques ; on peut décocher une partie.
- Un seul fichier ; chiffrement par mot de passe obligatoire dès qu'un secret est inclus (même
  format que la sauvegarde chiffrée de la note 38) ; import en un clic sur un autre Mac, avec
  aperçu de ce qui sera remplacé ou ajouté, et secrets remis dans le trousseau de ce Mac.
- Synchronisation par iCloud Drive (dossier NetScope/Sync, pas de CloudKit) : par site,
  fusion par date de modification, conflits signalés (jamais écrasés sans le dire), secrets
  chiffrés par un mot de passe de synchronisation gardé au trousseau ; état « Synchronisé il
  y a… » et bouton « Synchroniser maintenant ».
- Jamais de fusion entre sites ; un même site reconnu par son identifiant, pas par ses plages IP.

## 57. Accès distant : sessions intégrées à NetScope — 0.22.0 (demande de Dany)

**Livrée dans la 0.22.0** (5 novembre 2026) ; essai réel à faire sur de vrais équipements (SSH, Telnet, câbles console USB-série) et serveurs VNC (macOS, RealVNC, TightVNC, UltraVNC).

« Terminal intégré : bientôt… à faire aussi. » Avant la 0.22.0, « Connecter » ouvrait Terminal,
Windows App ou Partage d'écran. Depuis, des onglets de session dans Accès distant (« Ouvrir dans
Terminal » et « Partage d'écran » restent en secours dans le menu de « Connecter ») :

- **Terminal intégré** (SSH, Telnet) : émulateur de terminal dans NetScope (xterm-256color :
  couleurs, curseur, défilement, copier-coller, redimensionnement, recherche), session lancée
  par un pseudo-terminal avec `/usr/bin/ssh` (clés de ~/.ssh, known_hosts, mots de passe au
  Trousseau) ; plusieurs onglets, journal de session enregistrable.
- **Console série** : ports `/dev/cu.*` (adaptateurs USB-série, câbles console Cisco/Fortinet),
  vitesse, parité, bits, contrôle de flux ; même terminal intégré.
- **VNC intégré** : client RFB dans NetScope (authentification VNC et macOS, encodages
  courants), plein écran, mise à l'échelle.
- **RDP** : le protocole est trop vaste pour être écrit sans bibliothèque externe (règle du
  projet) ; il reste ouvert dans Windows App, avec la session préparée par NetScope.
- Aucune dépendance externe ; aucun mot de passe en clair.

## 58. Bilan de raccordement en un clic — 0.26.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.26.0** (5 novembre 2026) : Bilan de raccordement dans la Boîte à outils (lien, switch et port par LLDP/CDP, VLAN, PoE annoncé, DHCP sans bail, passerelle, DNS, Internet), mode avant/après, VLAN attendu, historique par site, export PDF et section de rapport ; le débit n’est pas mesuré par le bilan ; essai réel à faire sur les prises et switchs de Dany.

- **Ce que ça apporte** : la preuve de passage et le « avant/après » d’une intervention en
  30 secondes. Un seul bouton enchaîne lien et vitesse négociée, switch, port et VLAN par
  LLDP/CDP, PoE, DHCP, passerelle, DNS, Internet et débit ; le bilan est horodaté, archivé par
  site, comparé au bilan précédent et repris dans une section de rapport. Presque tout existe
  déjà dans l’app : il ne manque que l’enchaînement.
- **Référence du marché** : NetAlly LinkSprinter et LinkRunner (Link-Live).
- **Effort** : moyen.

## 59. SNMP v3 pour le relevé des switchs, les Ressources et les sondes — 0.25.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.25.0** (5 novembre 2026) : relevé des switchs, relecture automatique, Ressources, sondes, fiche matériel et découverte de fin de scan en SNMP v3, communauté v2c en repli ; utilisateur v3 par site ; navigateur SNMP (GET, GETNEXT, parcours, export CSV) livré avec ; essai réel à faire sur les switchs de Dany.

- **Ce que ça apporte** : beaucoup de parcs récents refusent le v2c. Le moteur v3 existe déjà
  (`SNMPv3.swift`) mais ne sert qu’au Test SNMP ; il faut le brancher sur le relevé des
  switchs, les Ressources et les sondes de Surveillance.
- **Référence du marché** : Domotz, NinjaOne, PRTG, LibreNMS.
- **Effort** : moyen.

## 60. Fiche matériel remplie automatiquement — 0.23.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.23.0** (5 novembre 2026) : modèle, numéro de série et firmware lus par ENTITY-MIB, sysDescr et l’inventaire de la FortiGate, bloc « Matériel détecté », « Lire la fiche matériel », colonnes Modèle et Firmware ; essai réel à faire sur les switchs, imprimantes, FortiSwitch et FortiAP de Dany.

- **Ce que ça apporte** : inventaire et rapports justes sans saisie à la main. Modèle, numéro
  de série et firmware lus par sysDescr et ENTITY-MIB, et par l’inventaire de la FortiGate pour
  les FortiSwitch et FortiAP. Bon test de SNMP en vrai pendant la 0.23.0.
- **Référence du marché** : Lansweeper, Auvik, Domotz.
- **Effort** : petit à moyen.

## 61. Export de la carte et section « Carte » du rapport — 0.28.0 (analyse du marché, demandée par Dany le 5 novembre 2026)

**Livrée dans la 0.28.0** (5 novembre 2026) : menu « Exporter » de la Carte du réseau (carte entière en PNG haute résolution, PDF vectoriel, SVG et draw.io modifiable, avec le site, le filtre VLAN, la recherche et les calques affichés, toujours en clair) ; section facultative « Carte du réseau » des rapports (image, légende, liens entre équipements) en PDF, HTML et DOCX, rapports planifiés compris ; essai réel à faire sur un vrai site (ouverture dans draw.io et Illustrator, impression).

- **Ce que ça apporte** : le schéma est le livrable que le client demande le plus. Export en
  PNG et PDF (rendu SwiftUI vers une image), puis SVG ou draw.io (XML écrit à la main) ;
  section « Carte » dans les rapports.
- **Référence du marché** : Auvik, Domotz, Zenmap.
- **Effort** : petit.

## 62. Historique long de la Surveillance et rapport de disponibilité — 0.27.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.27.0** (5 novembre 2026) : historique gardé jusqu’à 90 jours, graphe de latence sur 24 h ou 7 jours, disponibilité des 30 derniers jours, section « Disponibilité (Surveillance) » des rapports.

- **Ce que ça apporte** : prouver une panne au FAI ou au client et produire un rapport
  mensuel. Historique de 30 à 90 jours (données agrégées) au lieu de 24 h, rapport de
  disponibilité par site, graphes dans les rapports.
- **Référence du marché** : PRTG, Nagios XI, Uptime Kuma, PingPlotter.
- **Effort** : moyen.

## 63. Scan planifié par site — 0.31.0 (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : aujourd’hui les rapports planifiés reprennent un vieux scan. Un scan
  à l’heure choisie (quand NetScope est ouvert, ou par l’agent de la note 64) alimente la courbe
  de l’Analyse, les nouveaux appareils et les rapports planifiés.
- **Référence du marché** : Fing, Lansweeper, PRTG, phpIPAM.
- **Effort** : moyen.

## 64. Surveillance en arrière-plan sans fenêtre — 0.31.0 (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : sondes, Syslog et scans planifiés qui continuent après la fermeture
  de l’app. Agent de connexion ou LaunchAgent qui fait tourner le moteur de sondes ; l’app
  reste l’interface. C’est la limite raisonnable : pas de collecteur en ligne.
- **Référence du marché** : Fing Agent, Domotz.
- **Effort** : moyen à gros.

## 65. Ping TCP et HTTP dans le Ping continu, traceroute TCP et UDP — 0.26.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.26.0** (5 novembre 2026) : modes TCP et HTTP(S) du Ping continu (détail DNS, TCP, TLS et attente du serveur), traceroute MTR en ICMP, UDP ou TCP ; essai réel à faire sur des caméras, serveurs et liens qui filtrent l’ICMP.

- **Ce que ça apporte** : suivre les caméras, serveurs et liens Internet qui filtrent l’ICMP.
  La Surveillance a déjà un repli TCP à réutiliser.
- **Référence du marché** : PingInfoView, mtr, PingPlotter.
- **Effort** : petit à moyen.

## 66. Tunnels SSH et saut par bastion — 0.30.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.26.0** (5 novembre 2026), avant la 0.30.0 prévue : tunnels -L et -D dans des onglets de session, port local libre sur 127.0.0.1, RDP, VNC et navigateur à travers le tunnel, saut par bastion (-J) ; essai réel à faire sur un vrai bastion et le réseau FortiLink.

- **Ce que ça apporte** : joindre le réseau FortiLink ou un site distant par un hôte relais.
  Tunnels `-L`, `-D` et saut `-J` dans le carnet d’Accès distant, réutilisables par RDP, VNC et
  le navigateur web ; s’appuie sur `/usr/bin/ssh`.
- **Référence du marché** : Royal TSX, Termius, SecureCRT.
- **Effort** : petit (arguments de `/usr/bin/ssh`).

## 67. Envoi d’une commande à plusieurs sessions et extraits personnalisés — 0.33.0 (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : `show run` sur tous les switchs d’un site en une fois. Envoi d’une
  même commande à plusieurs sessions ouvertes du terminal intégré (note 57) et extraits
  personnalisés, enregistrés par l’utilisateur ; les extraits par marque (Cisco, FortiGate,
  Aruba, Linux) sont livrés dans la 0.22.0.
- **Référence du marché** : SecureCRT, Royal TSX, iTerm2.
- **Effort** : petit (le terminal de la 0.22.0 est livré).

## 68. Empreinte légère des services et du système — plus tard (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : type et système plus justes, versions visibles dans le rapport
  Sécurité, sans Nmap : en-tête HTTP « Server », certificat TLS, dialecte SMB, sysDescr, TXT
  mDNS, TTL. Pas de base de CVE ni de détection d’OS façon Nmap (voir note 79).
- **Référence du marché** : Nmap, SoftPerfect, Lansweeper.
- **Effort** : moyen.

## 69. Scan de ports UDP ciblé — plus tard (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : repérer un SNMP ouvert, un SIP ou un IPMI exposés. Charge propre à
  chaque protocole : DNS 53, NTP 123, SNMP 161, TFTP 69, SIP 5060, IPMI 623, mDNS.
- **Référence du marché** : Nmap, SoftPerfect, NetScanTools.
- **Effort** : petit à moyen.

## 70. Vérificateur de certificat TLS — plus tard (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : trouver les pare-feu, portails, imprimantes et NAS aux certificats
  expirés. Outil de la Boîte à outils (chaîne, SAN, expiration, versions TLS) qui réutilise la
  sonde HTTP et le diagnostic SMTP.
- **Référence du marché** : NetScanTools, SSL Labs.
- **Effort** : petit.

## 71. Éléments des balises Wi-Fi — 0.30.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.26.0** (5 novembre 2026), avant la 0.30.0 prévue : génération, largeur, flux, 802.11k/v/r, charge QBSS, sécurité et PMF, nom de la borne, nouvelles colonnes, panneau « Balise du BSSID » et recommandations ; essai réel à faire sur les bornes FortiAP et d’autres marques.

- **Ce que ça apporte** : diagnostic d’itinérance et de borne saturée, même hors FortiAP.
  Lecture par CoreWLAN (`informationElementData`) : 802.11k/v/r, charge QBSS (clients,
  utilisation du canal), génération Wi-Fi, WPA3.
- **Référence du marché** : WiFi Explorer Pro 3.
- **Effort** : petit à moyen.

## 72. Partages SMB d’un hôte — 0.28.0 (analyse du marché, demandée par Dany le 5 novembre 2026)

**Livrée dans la 0.28.0** (5 novembre 2026) : section « Partages SMB » de la fiche Appareil (port 445 ou 139 ouvert, ou NAS) et « Partages SMB… » au menu du Scanner ; `smbutil view` sur clic seulement, en invité puis anonyme, ou avec un utilisateur (mot de passe tapé dans smbutil par un pseudo-terminal, gardé au Trousseau sur demande) ; tableau standard, partages cachés ($) sur demande, « Ouvrir dans le Finder », chemins smb:// et Windows ; essai réel à faire sur un NAS, un poste Windows et un hôte SMB1.

- **Ce que ça apporte** : trouver un partage, vérifier un NAS ou un poste, depuis la fiche
  Appareil et le menu du Scanner. S’appuie sur `smbutil view`, livré avec macOS.
- **Référence du marché** : Advanced IP Scanner, SoftPerfect.
- **Effort** : petit.

## 73. Actions sur un port : cycle PoE et redémarrage — à décider (analyse du marché, à valider par Dany)

**Livrée dans la 0.25.0** (5 novembre 2026) : cycle PoE et « Redémarrer le port » par l’API de la FortiGate (jeton en lecture-écriture sur « WiFi & Switch Controller »), cycle PoE par SNMP en écriture pour les autres switchs, actions désactivées par défaut, confirmation, uplinks refusés, suivi du retour de l’appareil ; essai réel à faire, d’abord sur un port sans risque.

- **À décider avec Dany : rompt la règle de lecture seule.** Aujourd’hui NetScope ne change
  rien sur les équipements (API FortiGate et SNMP en lecture).
- **Ce que ça apporte** : redémarrer à distance un téléphone IP, une borne ou une caméra figés,
  par l’API FortiGate ou par SNMP en écriture.
- **Référence du marché** : Meraki Live Tools, Domotz, OpUtils.
- **Effort** : moyen.

## 74. Graphes de bande passante par port sur la durée — 0.25.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.25.0** (5 novembre 2026) : graphe de chaque port sur 1 h à 30 jours, historique par site jusqu’à 90 jours, « Ports les plus chargés » par période, Trafic par les compteurs des switchs sans FortiView ; essai réel à faire sur de vrais switchs (historique rempli seulement quand l’app est ouverte).

- **Ce que ça apporte** : voir un lien saturé dans le temps, pas en instantané. Compteurs SNMP
  des interfaces, qui servent aussi de trafic de secours pour les réseaux sans FortiGate.
- **Référence du marché** : LibreNMS, PRTG, Observium.
- **Effort** : moyen.

## 75. Collecteur NetFlow, sFlow et IPFIX — 0.28.0 (analyse du marché, demandée par Dany le 5 novembre 2026)

**Livrée dans la 0.28.0** (5 novembre 2026) : source « Flux (NetFlow, sFlow, IPFIX) » de l’écran Trafic, collecteur sur les ports UDP 2055, 4739 et 6343 démarré sur clic (ports modifiables, avertissement du coupe-feu), sources, destinations, applications, interfaces, conversations et exportateurs sur 1 min à 24 h, « Qui sature le lien ? » sans FortiGate, guide de configuration par marque ; flux gardés en mémoire seulement, 24 h au plus ; essai réel à faire sur de vrais exportateurs (FortiGate, Cisco, Aruba, MikroTik) et le coupe-feu de macOS.

- **Ce que ça apporte** : « Qui sature le lien ? » sans FortiView, sur un réseau d’une autre
  marque. Priorité basse : le parc de Dany est en Fortinet.
- **Référence du marché** : NinjaOne, Auvik, PRTG.
- **Effort** : gros.

## 76. Notification sur téléphone par ntfy ou Pushover — 0.28.0 (analyse du marché, demandée par Dany le 5 novembre 2026)

**Livrée dans la 0.28.0** (5 novembre 2026) : canaux ntfy (ntfy.sh ou serveur auto-hébergé en https) et Pushover dans Réglages › Alertes, désactivés par défaut, secrets au Trousseau, priorité selon la gravité, filtre propre à chaque canal (gravité, sites), « Envoyer un test » confirmé et journal des envois sans secret ; essai réel à faire avec de vrais envois vers ntfy et Pushover.

- **Ce que ça apporte** : recevoir une alerte loin du Mac sans Teams. Nouveaux canaux d’Alertes
  par de simples requêtes HTTPS.
- **Référence du marché** : Uptime Kuma, PRTG.
- **Effort** : petit.

## 77. Autres contrôleurs : UniFi, Omada, Meraki — plus tard (analyse du marché, à valider par Dany)

- **Ce que ça apporte** : les clients sans Fortinet retrouvent switchs, bornes et clients Wi-Fi.
- **Référence du marché** : Domotz, WiFiman, Meraki Dashboard.
- **Effort** : gros pour chacun.

## 78. Améliorations issues de l’analyse du marché — 0.23.0 à 0.30.0 (analyse du marché, à valider par Dany)

**Livrée dans la 0.27.0** (5 novembre 2026) pour toutes les parties restantes (Surveillance, Carte du réseau sauf l’export, Analyse, Wi-Fi ce Mac, Speedtest, iperf3, Capture de paquets, Rapports, Journaux, XMODEM/YMODEM d’Accès distant, Vitesse des disques). Seule reste la commande envoyée à plusieurs sessions (note 67).

Écarts avec la référence du marché pour les outils existants ; la version indiquée suit la
feuille de route révisée, « plus tard » sinon.

- **Test MTU** (0.26.0) : **Livrée dans la 0.26.0** (5 novembre 2026). Vraie recherche par dichotomie avec le bit DF, résultat « MTU du
  chemin = N vers X », historique, détection du PPPoE et des tunnels. Sinon, le retirer (note 79).
- **Ping continu** (plus tard) : **Livrée dans la 0.26.0** (5 novembre 2026), jusqu’à 64 cibles. Mode tableau compact au-delà de 9 cibles, session enregistrée
  et rouverte, rapport « pour le FAI » en PDF, seuil réglable par cible, notification macOS (en
  plus de la note 11).
- **Surveillance** (0.27.0) : **Livrée dans la 0.27.0** (5 novembre 2026). heures ouvrables par site au lieu de lun.–ven. 7 h–18 h fixes,
  fenêtres de maintenance planifiées, rappel si l’alerte n’est pas accusée, graphe de latence
  par sonde, SNMP v3 (note 59).
- **Carte du réseau** (0.24.0 pour l’export, plus tard pour le reste) : **Livrée dans la 0.27.0** (5 novembre 2026) ; l’export reste pour la 0.24.0 (note 61). liens entre switchs par
  les voisins LLDP déjà relus par SNMP, filtre par VLAN, nœuds déplacés à la main retenus,
  export (note 61).
- **Analyse** (plus tard) : **Livrée dans la 0.27.0** (5 novembre 2026). carte d’occupation de /23 à /16 (pages de /24), « prochaine IP libre
  hors étendue DHCP », croisement avec les baux et réservations de la FortiGate.
- **Wi-Fi (ce Mac)** (0.30.0) : **Livrée dans la 0.27.0** (5 novembre 2026). meilleur canal en 5 et 6 GHz, relevé par pièce enregistré par
  site avec latence et débit par point, historique du signal au-delà de 2 minutes.
- **Wake-on-LAN** (plus tard) : **Livrée dans la 0.26.0** (5 novembre 2026). Ping de suivi « réveillé en N s », broadcast dirigé vers un
  autre sous-réseau, envoi à plusieurs appareils.
- **Speedtest** (0.28.0) : **Livrée dans la 0.27.0** (5 novembre 2026). sonde « débit Internet » planifiée (une fois par jour) avec courbe
  par site.
- **iperf3** (plus tard) : **Livrée dans la 0.27.0** (5 novembre 2026). mode serveur intégré compatible iperf3 (protocole JSON et TCP, sans
  dépendance), ou au minimum un test NetScope-à-NetScope entre deux Mac.
- **Capture de paquets** (plus tard) : **Livrée dans la 0.27.0** (5 novembre 2026). décodeurs SIP, RTP, SNMP, Syslog, RADIUS et NTP ;
  constats automatiques (retransmissions, fenêtre zéro, latence par flux) ; bouton « Ouvrir
  dans Wireshark ». Ne pas aller plus loin (note 79).
- **Rapports** (0.27.0 pour l’envoi) : **Livrée dans la 0.27.0** (5 novembre 2026). envoi automatique du rapport planifié par le canal SMTP
  déjà configuré dans Alertes ; export DOCX écrit à la main (ZIP et XML, comme l’archive de
  sauvegarde) ; graphes de disponibilité (note 62).
- **Alertes** (plus tard) : **Livrée dans la 0.26.0** (5 novembre 2026) pour les événements dédiés (licence, firmware, Syslog, WAN) au lieu de
  « sonde en panne » générique ; restent ntfy et Pushover (note 76).
- **Journaux** (plus tard) : **Livrée dans la 0.27.0** (5 novembre 2026). Syslog en TCP (RFC 6587), transfert vers un autre serveur Syslog ;
  garder le port 5514 (le 514 demande des droits) et mieux guider la configuration des
  équipements.
- **Inventaire** (0.23.0 pour le remplissage) : **Livrée dans la 0.26.0** (5 novembre 2026) ; remplissage livré dans la 0.23.0. Remplissage automatique (note 60),
  rapprochement des MAC aléatoires par nom d’hôte et numéro de série, export compatible
  NetBox, GLPI et Snipe-IT (CSV aux bons noms de colonnes).
- **Accès distant** (0.30.0) : **Livrée dans la 0.26.0** en grande partie (voir la fin). Nom d’utilisateur retenu aussi pour RDP et SFTP, import de
  `~/.ssh/config`, tunnels (note 66), commande envoyée à plusieurs sessions (note 67),
  XMODEM/YMODEM et horodatage des lignes en console série ; presse-papiers VNC au-delà du texte
  plus tard. **Livrée dans la 0.26.0** (5 novembre 2026), sauf la commande envoyée à plusieurs
  sessions (note 67), qui reste pour la 0.30.0 ; XMODEM/YMODEM **livrés dans la 0.27.0** (5 novembre 2026) (le Break et le préréglage Cisco/Fortinet sont livrés dans la 0.22.0).
- **Trafic** (0.25.0) : **Livrée dans la 0.25.0** (5 novembre 2026). Secours par les compteurs SNMP des interfaces (note 74) ; seuils sur un
  écart dans le temps plutôt que « 1 000 erreurs depuis le démarrage ».
- **Vitesse des disques** (plus tard) : **Livrée dans la 0.27.0** (5 novembre 2026). SFTP et FTP comme emplacements (le client existe
  déjà). Le reste suffit.

## 79. Allègements proposés — à décider (analyse du marché, à valider par Dany)

**Livrée dans la 0.25.0** (5 novembre 2026) : « Analyse » renommé « Historique et adressage », « Bilan de santé » sur 100 rappelé en tête de cet écran, outil « Courriel » à onglets, Ookla masqué par défaut, services grand public non suivis par défaut. Restent : TFTP (le Test MTU est refait dans la 0.26.0), menu « Connecter » à revoir après les essais réels.

Outils inutiles ou redondants dans NetScope, et ce qu’il vaut mieux ne pas faire.

### Dans NetScope

- **Deux « analyses »** (écran Analyse et « Analyse complète du réseau » de Trafic) : même nom
  pour deux choses différentes. **Décision en attente : renommer** l’écran Analyse en
  « Historique et adressage » et la note sur 100 en « Bilan de santé », placée aussi en tête de
  l’écran Analyse ou du rapport.
- **Test MTU** dans la Boîte à outils : il ne mesure rien. Le rendre réel (note 78, 0.26.0),
  sinon le retirer et garder le préréglage de la note 11.
- **Ookla par sa CLI** dans Speedtest : dépend d’un binaire Homebrew, et sa licence semble
  limitée à un usage personnel non commercial (à vérifier). Trois moteurs suffisent.
  **Décision en attente : cacher par défaut, ou retirer** après vérification de la licence.
- **Services en ligne grand public** (TikTok, Snapchat, Grok, Meta) : peu utiles chez une
  entreprise. Les garder (note 53, demandée par Dany) mais masqués par défaut.
- **Sept outils de courriel** côte à côte : le Super outil fait déjà MX, SPF, DKIM, DMARC et
  listes noires. **Décision en attente : regrouper** en un outil « Courriel » à onglets (Super
  outil, Diagnostic SMTP, Analyse d’en-têtes).
- **Ressources de ce Mac** : le Moniteur d’activité fait la même chose ; la valeur est dans les
  agents SNMP. Garder, en second plan, sans plus y investir.
- **TFTP** : vérifier qu’il n’existe qu’une seule entrée dans la Boîte à outils.
- **« Ouvrir dans Terminal » et « Partage d’écran »** dans le menu de « Connecter » : redondants
  avec les sessions intégrées de la 0.22.0, mais utiles tant que celles-ci ne sont pas
  éprouvées. Les garder en secours ; revoir après les essais réels.
- **Note 6 (RustDesk)** : le client RustDesk fait déjà tout ; la garder petite (carnet et
  lancement par `rustdesk://`).

### À ne pas faire

- Un scanner de vulnérabilités avec base de CVE (base tierce à tenir à jour) : l’empreinte
  légère (note 68) et les ports risqués suffisent.
- Une détection d’OS au niveau de Nmap : travail sans fin sans sa base d’empreintes.
- RDP natif : déjà écarté par la note 57.
- Le mode moniteur Wi-Fi ou une capture 802.11 : impossible sans droits sur un macOS récent
  (Airtool le fait).
- La planification Wi-Fi prédictive façon Ekahau ou Hamina : un autre métier ; le relevé sur
  plan suffit.
- Le travail d’équipe (coffre partagé, rôles, SSO) : Dany travaille seul.
- Un filtre d’affichage Wireshark complet ou le déchiffrement TLS : renvoyer vers Wireshark.
- Un SaaS ou un collecteur multi-sites façon Domotz ou Auvik : hors de la philosophie locale ;
  l’agent local (note 64) est la limite.

## 80. Wi-Fi › FortiAP : page divisée en onglets — 0.30.0 (demande de Dany, 5 novembre 2026)

**Livrée dans la 0.27.0** (5 novembre 2026).

- Constat de Dany : la partie FortiAP de l’écran Wi-Fi empile tout sur une seule longue page
  (tuiles, bornes, clients de la borne, carte des canaux, clients, SSID, bornes voisines, avec
  conseils et détail de la borne à côté) ; il est dur d’y trouver l’information.
- Garder en haut le bandeau de la FortiGate et les tuiles de résumé, puis des onglets natifs :
  - **Bornes** : tableau des bornes, détail de la borne choisie (radios, canal, émission) et ses
    clients par radio et par SSID ;
  - **Clients** : tous les clients, avec la fiche complète du client (note 46) ;
  - **SSID** : réseaux diffusés, clients et bornes par SSID ;
  - **Canaux** : carte des canaux par bande (2,4 / 5 / 6 GHz) ;
  - **Voisins** : bornes voisines et non autorisées ;
  - **Conseils** : diagnostic et recommandations, avec le nombre de constats sur l’onglet.
- Les liens entre onglets restent : un clic sur une borne dans Clients, Canaux ou Conseils ouvre
  l’onglet Bornes sur cette borne ; « Diagnostiquer » et le retour ‹ (note 45) continuent de
  marcher ; la fiche d’un appareil ouvre directement le bon onglet.
- Onglet choisi retenu ; une variable de capture par onglet ; vérifier en clair, en sombre et en
  1000 × 650.

## 81. Mise à jour automatique de la base des fabricants (IEEE) — 0.28.0 (demande de Dany, 5 novembre 2026)

**Livrée dans la 0.27.0** (5 novembre 2026).

- Aujourd’hui : Réglages › Base des fabricants met à jour le registre IEEE (oui.csv, mam.csv,
  oui36.csv) seulement à la demande, avec « Revenir à la base intégrée ».
- Ajouter une option « Mettre à jour automatiquement » (activée par défaut ou proposée au premier
  lancement, à décider) : vérification au plus une fois par mois, au lancement ou en arrière-plan,
  quand la base date de plus de 30 jours ; téléchargement discret, mêmes vérifications que la mise
  à jour manuelle (taille, nombre de préfixes, conversion), écriture atomique, ancienne base gardée
  si quelque chose échoue.
- Afficher la date de la base et de la dernière vérification, le nombre de préfixes ajoutés depuis
  la précédente, et une notification discrète (« Base des fabricants mise à jour : +312 préfixes »).
- Ne jamais télécharger pendant un scan ni sur une connexion limitée (partage de connexion du
  téléphone, NWPath « expensive » ou « constrained »).
- Tests sans réseau : décision « faut-il vérifier ? » (date, intervalle, connexion limitée),
  échec sans perte de la base en place.

## 82. Sites et plages : plages exclues — 0.24.0 (demande de Dany, 5 novembre 2026)

**Livrée dans la 0.27.0** (5 novembre 2026).

- Dans Réglages › Sites et plages, pour chaque site, une liste « Plages exclues » à côté des
  plages scannées : adresses seules (10.93.226.254), intervalles (10.93.226.1-50) ou sous-réseaux
  (10.255.1.0/24), avec une note facultative (« automates », « FortiLink », « caméras fragiles »).
- Les adresses exclues ne sont jamais sondées : ni ping, ni ARP actif, ni ports, ni SNMP, ni noms
  (scan manuel, relecture automatique, scan planifié, Scan de ports et Ping continu d’une plage).
  Le Scanner affiche « N adresses exclues » et l’infobulle dit pourquoi.
- Un appareil exclu déjà connu reste dans l’inventaire (marqué « exclu du scan »), sans être
  déclaré disparu.
- Exclusions copiées avec le site (export, import, synchronisation iCloud) ; validation : une
  exclusion qui couvre toute une plage est signalée.
- Tests sans réseau : calcul des adresses à sonder (plages moins exclusions, chevauchements,
  adresses de réseau et de diffusion), import et export.

## 83. Switchs et ports : page divisée en onglets — 0.27.0 (demande de Dany, 5 novembre 2026)

**Livrée dans la 0.27.0** (5 novembre 2026).

- Constat de Dany : « faire la même chose que la note 80 (FortiAP en onglets) à Switchs
  Fortinet ». L’écran Switchs et ports empilait tout sur une seule longue page (sources de la
  localisation, FortiGate, ce Mac, cartes, façade, ports, ports chargés, table MAC, détail du
  port, trafic, historique, topologie) ; la façade et les ports n’étaient visibles qu’en
  descendant. Fait :
- En haut, toujours : le bandeau du site (menu « Site ▾ », relecture automatique) et six tuiles
  de résumé sur une ligne, chacune ouvre l’onglet qui la détaille : Switchs en ligne, Ports
  actifs (Ports filtré « Actifs »), Ports en erreur (Ports du premier switch touché, filtré
  « Erreurs »), PoE utilisé sur le budget (Ports filtré « PoE »), Appareils et VLAN, Voisins LLDP
  et liens entre switchs.
- Puis des onglets natifs (contrôle segmenté, menu en petite fenêtre), avec leur compteur :
  - **Switchs (5)** : cartes des switchs, switchs trouvés par le scan, façade du switch choisi
    avec « Trouver un appareil », sources de la localisation et interrogation SNMP, FortiGate du
    site ; un clic sur un port de la façade l’ouvre dans l’onglet Ports ;
  - **Ports (1 en erreur)** : nouveau tableau standard de tous les ports (« switchs.ports »), le
    même pour les switchs SNMP et les FortiSwitch (il remplace l’ancien tableau des ports d’un
    FortiSwitch) : état, vitesse, VLAN, PoE, appareil branché, erreurs récentes, et en colonnes
    facultatives description, voisin LLDP, adresse IP, nombre de MAC, dernier changement ;
    filtres « Tous, Actifs, Inactifs, PoE, Uplinks, Erreurs » avec leurs nombres et champ
    « Filtrer » ; bandeau « Erreurs récentes » (ports dont les erreurs augmentent) ; détail du
    port à droite avec ses appareils, son voisin et les actions sur le port (note 73) ;
  - **Trafic** : ports les plus chargés (en direct ou 1 h à 30 j, jusqu’à 16 lignes), trafic en
    direct et historique du port choisi (note 74) ; un FortiSwitch n’a que l’historique ;
  - **Appareils** : table MAC du switch choisi, plus haute, et « Appareils par VLAN » (appareils,
    ports d’accès et trunks de chaque VLAN ; un clic filtre la table MAC sur le VLAN) ;
  - **Voisins et liens (19)** : « Ce Mac est branché sur… », nouveau tableau des voisins LLDP de
    tous les switchs du site (« switchs.voisins » : port local, voisin, port distant, nature —
    lien entre switchs, FortiLink, routeur, point d’accès, téléphone… —, vitesse, capacités,
    plateforme ; case « Liens d’infrastructure seulement ») et la topologie déduite par LLDP.
- Ports, Trafic et Appareils montrent un seul switch : le choix du switch est à droite des
  onglets (les cartes restent dans Switchs).
- Liens entre onglets : façade → Ports ; « Voir le port » de la table MAC et du tableau des
  voisins → Ports ; « Voir le trafic du port » et « Voir les appareils du port » (table MAC
  filtrée « port: ») depuis le tableau des ports ; « … et N autres : voir la table MAC » du
  détail du port → Appareils ; « Voir … dans l’onglet Ports » sous le trafic du port ; « Ouvrir
  le switch voisin ». Ces sauts passent par l’historique : Retour (⌘[) ramène à l’onglet quitté.
- Navigation : l’historique Retour / Avancer garde l’onglet (NavLocation.tab) ; un appareil, une
  fiche ou « Ouvrir dans › » qui montre un port ouvre l’onglet Ports sur ce port, un switch seul
  l’onglet Switchs ; « Trouver un appareil » et « Voir le port de switch » (DHCP) montrent la
  façade ; « Voir le port » de ce Mac ouvre Ports ; la recherche de la barre d’outils (table MAC)
  ouvre Appareils. La vue de plusieurs sites (note 48) ne change pas.
- Rien ne disparaît : tous les panneaux d’avant sont dans un onglet. Onglet retenu d’une visite et
  d’un lancement à l’autre. Les relevés de trafic du switch SNMP affiché tournent quel que soit
  l’onglet (l’historique des ports continue de se remplir).
- Moteur dans NetScopeCore/SwitchPages (onglets, lignes et filtres des ports, VLAN, voisins,
  tuiles), testé sans réseau (« Switchs en onglets », 7 scénarios).
- Captures : NETSCOPE_SWITCH_ONGLET=switchs | ports | trafic | appareils | voisins ;
  NETSCOPE_SWITCH_PORTS=tous | actifs | inactifs | poe | uplinks | erreurs. Sans onglet demandé,
  NETSCOPE_PORT (et les actions sur le port) ouvre Ports, NETSCOPE_SWITCH_HISTORIQUE ouvre Trafic.
  Vérifié en clair, en sombre et en 1000 × 650.
- À vérifier sur un vrai réseau : compteurs et filtres sur un gros switch (48 ports et plus,
  empilés), voisins LLDP d’autres marques (noms avec domaine, capacités absentes), FortiSwitch
  réels lus par la FortiGate (liens ISL et FortiLink).

## 84. Historique et adressage : appareils Wi-Fi et repères Wi-Fi / filaire / DHCP — 0.27.1, juste après la 0.27.0 (demande de Dany, 5 novembre 2026)

**Livrée dans la 0.27.1** (5 novembre 2026) : plus d’alerte « Appareil déplacé » pour l’itinérance Wi-Fi (notée dans l’historique), appareils Wi-Fi reconnus par plusieurs indices, carte d’occupation Wi-Fi / filaire avec repères DHCP et légende, infobulles et adresse choisie détaillées. Essai réel à faire avec de vraies bornes FortiAP.

- Constat de Dany : des alertes « Appareil déplacé sur un autre port » (événement `deviceMoved`)
  arrivent pour des appareils Wi-Fi. Normal : un client qui passe d’une borne FortiAP à une autre
  apparaît derrière un autre port de switch (celui de la nouvelle borne).
- Ne plus lever cette alerte pour un appareil Wi-Fi : client vu par la FortiGate (FortiAP), type
  ou interface Wi-Fi connus, ou port de switch qui mène à une borne FortiAP (LLDP, détection de
  la borne). À la place, noter l’itinérance dans l’historique de l’appareil (« passé de la borne
  X à la borne Y »), sans alerte. Un appareil filaire qui change de port garde son alerte.
- Carte d’occupation (les carrés verts) : une couleur pour les appareils filaires, une autre pour
  le Wi-Fi (couleurs dynamiques de Theme, lisibles en clair et en sombre, avec légende), et un
  petit repère « DHCP » pour une adresse attribuée par bail (baux de la FortiGate), différent d’une
  adresse fixe ou réservée. Infobulle : filaire ou Wi-Fi (borne, SSID), DHCP ou fixe.
- Tests sans réseau : classement Wi-Fi / filaire, suppression de l’alerte d’itinérance, alerte
  maintenue pour un filaire, légende de la carte.

## 85. Accès distant : « Assistance RustDesk » dans son propre onglet, comme « Serveur RustDesk » — 0.27.3 (demande de Dany, 5 novembre 2026)

**Livrée dans la 0.27.3** (5 novembre 2026) : onglet permanent « Assistance RustDesk » entre
« Sessions » et « Serveur RustDesk » (pastille : sessions lancées aujourd’hui), grand champ pour
l’ID, ajout au carnet avec nom et usager, marche à suivre en trois étapes, lien d’assistance à
copier, historique complet en tableau standard (recherche, tri, reconnexion, ajout au carnet,
copie de l’ID). Essai réel sur le serveur de Groupe Couture à faire.

- Demande de Dany : placer l’assistance RustDesk dans un onglet comme celui du serveur RustDesk,
  au lieu du bloc de la page « Sessions ».
- Ouvert aussi depuis Réglages › RustDesk (« Ouvrir l’assistance »), le menu Aller, le panneau
  d’un poste RustDesk (« Toutes les sessions ») et le clic droit sur « Connecter par RustDesk »
  dans la fiche Appareil et l’Inventaire (ID déjà saisi).
- Mêmes règles que le tableau de bord du serveur : colonne des détails masquée, pleine largeur en
  petite fenêtre ; sous 620 points, onglets fixes abrégés « Assistance » et « Serveur ».
- Moteur dans NetScopeCore/Remote/RustDeskAssistance (pastille du jour, recherche, présence au
  carnet, nom proposé), testé sans réseau. Capture : NETSCOPE_REMOTE_VIEW=rustdesk-assistance.
- Limites : RustDesk ne signale pas la fin d’une session (seule l’heure de lancement est notée) ;
  historique gardé sur ce Mac seulement, 300 lancements au plus.

## 86. Synchronisation complète des données entre tous les Mac — 0.29.0 (demande de Dany, 5 novembre 2026)

« Je veux la possibilité d’un data synchronisé entre tous mes Mac. » Proposition acceptée par
Dany : étendre la synchronisation iCloud Drive de la note 56 (0.18.0) au lieu de repartir de zéro.

- Tout synchronisé par défaut, catégories décochables : sites, inventaires, notes et derniers
  résultats ; carnet d’Accès distant, tunnels, RustDesk (carnet, historique, serveur), utilisateurs
  SSH retenus ; switchs SNMP, sondes de Surveillance, canaux d’alerte, rapports planifiés, seuils ;
  saisies à la main, relevés Wi-Fi par pièce, historique Speedtest, plages exclues ; réglages,
  raccourcis, profils de scan.
- Secrets (jetons, communautés, mots de passe SSH, SMB, ntfy, Pushover…) chiffrés par le mot de
  passe de synchronisation, remis au Trousseau de chaque Mac.
- Propre à chaque Mac : interface active, fenêtre, captures, journal de l’app, base des
  fabricants, historiques bruts volumineux (flux, signal seconde par seconde).
- Application à chaud, sans redémarrage ; synchro quasi continue (quelques secondes après un
  changement, et quand iCloud signale un fichier modifié par un autre Mac).
- Un fichier par Mac, fusion élément par élément, conflits signalés et rétablissables,
  suppressions venues d’ailleurs confirmées.
- Tableau de bord Réglages › Synchronisation (Mac vus, dernière synchro, changements, conflits) ;
  dossier au choix (iCloud Drive par défaut, OneDrive, NAS, dossier partagé).
- La sauvegarde des configurations (note 40) passe en 0.30.0, l’automatique en arrière-plan en
  0.31.0, IPv6 en 0.32.0 et la note 67 en 0.33.0.

