# À faire — NetScope (notes d’essai de la 0.2.1)

> Les phases 2, 3 et 4 (notes 6, 10 et 11) peuvent se faire dans n'importe quel ordre
> (décision de Dany).

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

## 12. « Suis-je sur un port PoE ? » — À PLANIFIER (demande de Dany)

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

## 13. Réglages encore « Bientôt » — À PLANIFIER (demande de Dany)

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
- Autres « bientôt » de Réglages, à traiter avec : langue anglaise, thème sombre (note 9),
  « Test SNMP » des identifiants, identifiants SSH et WMI, choix des méthodes de découverte dans
  les profils de scan, plusieurs sites (avec la gestion par site, note 10).

## 14. Outils courriel et DNS (style « super outil ») — À PLANIFIER (demande de Dany)

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

## 15. État des grands services en ligne — À PLANIFIER (demande de Dany)

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
