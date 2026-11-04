# À faire — NetScope (notes d’essai de la 0.2.1)

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
- Reste à décider : Server OSS gratuit ou Server Pro (console web, carnet partagé, générateur de
  client à ton logo).
