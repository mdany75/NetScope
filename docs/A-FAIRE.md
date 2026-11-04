# À faire — NetScope

> Les phases 2, 3 et 4 (notes 6, 10 et 11) peuvent se faire dans n'importe quel ordre
> (décision de Dany).

## Priorités (revues le 4 novembre 2026, réorganisées avec les notes 45 à 53)

Notes 1 à 5 : livrées dans la 0.3.0 ; note 18 dans la 0.3.1 ; notes 8, 19, 20 et 9 dans la 0.4.0 ; types Console de jeu et Domotique dans la 0.4.1 ; notes 12, 21, 17 et 16 dans la 0.5.0 ; notes 15 et 14 dans la 0.6.0 ; notes 7 et 22 dans la 0.7.0 ; notes 13 et 23 dans la 0.8.0 ; note 24 dans la 0.9.0 ; note 25 dans la 0.10.0 ; notes 26 et 27 dans la 0.11.0 ; note 28 et correction de la Carte dans la 0.12.0 ; notes 34, 33, 31 et 36 dans la 0.13.0.

1. **0.13.x, retours d'essai** (0.8.1 : plantage de Vitesse des disques sur le NAS corrigé ; 0.9.0 : FortiGate essayée avec succès ; 0.10.0 : plusieurs FortiGate à essayer ; 0.11.0 : recherche multiple et FortiAP à essayer ; 0.12.0 : sites à essayer ; 0.13.0 : navigation et gros sites à essayer) : essais réels de la 0.3.x (localisation, DHCP, capture,
   notifications, VNC, mise à jour), de la 0.4.0 (menus de colonnes, type, ports, sombre) et
   des 0.5.0 à 0.8.0 (voir ci-dessous) ; 0.13.1 au besoin.
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
11. **Ordre proposé pour la suite** (analyse du 4 novembre 2026, acceptée par Dany ;
    réorganisé le même jour pour placer les notes 45 à 53, ordre accepté par Dany) :
    - **0.13.1** : essais réels (sites, FortiGate, FortiAP, navigation) et correctifs ; note 35
      (journal et diagnostic).
    - **0.14.0, Carte, VoIP, DHCP, sauvegarde** (en cours) : notes 32 (recherche dans la Carte),
      30 (Téléphonie IP), 37 (étendues DHCP), 38 (sauvegarde chiffrée).
    - **0.15.0, sites et navigation** : notes 49 (site sous le logo), 48 (site dans Switchs et
      Wi-Fi), 45 (fin du Retour : bouton qui nomme l'écran, position dans la liste, historique
      vidé au changement de site), 52 (nom d'utilisateur SSH).
    - **0.16.0, Wi-Fi des clients** : notes 46 (clients par borne et par SSID, fiche complète),
      47 (diagnostic Wi-Fi d'un client, avec solutions).
    - **0.17.0, suivi automatique et trafic** : notes 29 (relire en automatique), 39 (WAN des
      FortiGate), 54 (FortiView : trafic et analyse complète du réseau).
    - **0.18.0, transferts et services** : notes 50 (FTP, FTPS, SFTP), 51 (TFTP), 53 (réseaux
      sociaux et assistants IA dans les services en ligne).
    - **0.19.0, parc Fortinet** : notes 40 (sauvegarde des configurations), 41 (firmware et
      licences).
    - **0.20.0, rapports et Inventaire** : notes 42 (rapport de suivi), 10 (Inventaire phase 3).
    - **0.21.0, journaux et aide** : notes 43 (Syslog et traps), 44 (aide et accueil).
    - **Plus tard** : notes 11 (Ping continu), 6 (RustDesk), anglais ; idées d’un cran en dessous :
      navigateur SNMP, toner des imprimantes, test de câble, qualité VoIP (MOS), scan d’un VLAN
      tagué, relevé Wi-Fi sur plan, synchronisation entre deux Mac, retour à la version
      précédente, contrôle IPv6.

## Index par module

| Module | Livrées | À venir |
| --- | --- | --- |
| Scanner et sites | 18, 19, 20, 26, 28 | 49 et 48 (0.15.0) |
| Navigation entre les modules | 31, 33, 34, 36 | 45, fin (0.15.0) |
| Switchs et ports, Fortinet | 12, 24, 25 | 29, 39 et 54 (0.17.0), 40 et 41 (0.19.0) |
| Wi-Fi | 1, 27 | 46 et 47 (0.16.0) |
| Carte du réseau | — | 32 (0.14.0) |
| Inventaire | 8 | 30 (0.14.0), 10 (0.20.0) |
| Ping continu | — | 11 (plus tard) |
| Boîte à outils | 2, 7, 14, 15, 16, 17, 21, 22 | 37 (0.14.0), 51 et 53 (0.18.0) |
| Accès distant | 5 | 52 (0.15.0), 50 (0.18.0), 6 (plus tard) |
| Surveillance et alertes | 3, 23 | 43 (0.21.0) |
| Rapports | 4 | 42 (0.20.0) |
| Réglages, sauvegarde, aide | 9, 13 | 35 (0.13.1), 38 (0.14.0), 44 (0.21.0) |

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

## 6. Assistance à distance façon AnyDesk : par RustDesk (choix de Dany) — PHASE 2

> **Reporté en phase 2 (décision de Dany)** : ni serveur RustDesk, ni client, ni protocole
> RustDesk dans NetScope lors du « procède » actuel. Garder ces notes pour plus tard.

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

- Relecture périodique, sans relancer de scan, de la FortiGate (FortiSwitch, FortiAP), des
  switchs SNMP et des emplacements des appareils (aujourd'hui : boutons « Relire la FortiGate »,
  « Relire les bornes », « Interroger les switchs » ou fin de scan).
- Intervalle réglable par site, pause quand le site n'est pas le site actif.

## 30. Type « Téléphonie IP » — 0.14.0 (demande de Dany)

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

## 35. Journal de l’app et « Exporter un diagnostic » — 0.13.1 (analyse, retenue par Dany)

- Journal interne consultable (erreurs, avertissements, appels FortiGate/SNMP en échec, avec date
  et module), visible dans l’app ; export .zip « diagnostic » sans aucun secret (jetons,
  communautés, mots de passe masqués) ; rapport des plantages précédents au lancement.

## 36. Essais de charge sans réseau (analyse, retenue par Dany)

**Livrée dans la 0.13.0** (4 novembre 2026), avec l’inventaire enregistré en arrière-plan et les lenteurs corrigées ; essai réel à faire sur un très gros site.

- Tests de performance avec des données fictives : 20 sites, plages de 65 536 adresses, gros
  inventaires et historiques ; temps d’ouverture des écrans, de changement de site, d’écriture
  de l’inventaire (aujourd’hui réécrit en entier à chaque changement).

## 37. Occupation des étendues DHCP — 0.14.0 (analyse, retenue par Dany)

- Par la FortiGate (baux et étendues) et le Test DHCP : taux d’occupation de chaque étendue,
  alerte « étendue presque pleine », sonde de Surveillance, ligne dans les rapports.

## 38. Sauvegarde chiffrée par mot de passe — 0.14.0 (analyse, retenue par Dany)

- Archive de sauvegarde chiffrée (mot de passe choisi), jetons et secrets inclus en option
  (chiffrés) pour restaurer un 2e Mac sans ressaisir 20 jetons ; sans mot de passe : comme
  aujourd’hui, jamais de secret.

## 39. État du WAN de chaque FortiGate — 0.17.0 (analyse, retenue par Dany)

- Liens WAN et SD-WAN (état, latence, perte, gigue), tunnels VPN IPsec (montés ou tombés),
  par site ; sondes « tunnel tombé » et « lien WAN dégradé » ; vue de tous les sites.

## 40. Sauvegarde des configurations — 0.19.0 (analyse, retenue par Dany)

- Copie de la configuration de chaque FortiGate (API, lecture), puis des switchs en SSH ;
  historique par site, comparaison avant/après (différences surlignées), avant une intervention.

## 41. Firmware et licences du parc — 0.19.0 (analyse, retenue par Dany)

- Versions FortiOS, FortiSwitch et FortiAP de chaque site, versions recommandées, contrats
  FortiGuard et dates d’expiration ; tableau de tous les sites et drapeau « firmware à jour » du
  rapport enfin rempli ; alertes avant expiration.

## 42. Rapport de suivi et rapports planifiés — 0.20.0 (analyse, retenue par Dany)

- « Depuis le dernier rapport » : nouveaux appareils, disparus, problèmes réglés ou nouveaux
  (réutilise la comparaison de l’Analyse) ; rapports produits à date fixe par site.

## 43. Récepteur Syslog et traps SNMP — 0.21.0 (analyse, retenue par Dany)

- Réception Syslog et traps SNMP sur le Mac, journaux de la FortiGate par l’API ; recherche
  par heure, appareil et gravité, pour comprendre une coupure intermittente.

## 44. Aide intégrée et accueil au premier lancement — 0.21.0 (analyse, retenue par Dany)

- Accueil au premier lancement (autorisations, premier site, FortiGate), bouton « ? » dans
  chaque écran, menu Aide rempli (aujourd’hui vide).

## 45. Retour à l'écran d'avant, dans tous les modules — 0.15.0 (demande de Dany)

**En grande partie livrée dans la 0.13.0** (note 34 : Retour / Avancer ⌘[ ⌘], recherche,
filtre et sélection rendus tels quels). Reste pour la 0.15.0 : le bouton qui nomme l'écran
d'origine, la position dans la liste et l'historique vidé au changement de site.

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

## 47. Diagnostic des problèmes Wi-Fi d'un client, avec solutions — 0.16.0 (demande de Dany)

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
