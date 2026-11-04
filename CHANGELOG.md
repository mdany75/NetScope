# Changements

## 0.10.0 — 2026-11-04

Plusieurs FortiGate, une par site : NetScope garde une liste de FortiGate, chacune avec son
jeton et les plages IP qu’elle couvre, et lit à la fin d’un scan seulement celles qui couvrent
les plages scannées.

### Ajouté
- **Réglages › Switchs › Contrôleurs FortiGate** : liste des sites (adresse, port, VDOM,
  plages couvertes, jeton, état, dernier test), chacun avec son propre jeton au Trousseau et
  l’empreinte de son certificat.
- **« Tester »** propose les sous-réseaux des interfaces de la FortiGate comme plages
  couvertes, à cocher (le réseau FortiLink n’est pas coché).
- **« Tester tout »** vérifie chaque FortiGate, quatre à la fois, et affiche le résultat sur
  sa ligne.
- **Import et export CSV** de la liste des sites (`site;adresse;port;vdom;plages`) ; les lignes
  refusées sont expliquées. Le fichier ne contient jamais de jeton : il faut le saisir pour
  chaque site importé.
- **Switchs et ports** : bandeau « FortiGate utilisée : Siège (10.182.0.0/16) », une liste
  quand plusieurs sites sont scannés, ou « Aucune FortiGate pour cette plage : SNMP
  seulement » ; puce « via FortiGate · site » sur chaque FortiSwitch.

### Modifié
- **Choix automatique de la FortiGate** : à la fin d’un scan, seules les FortiGate qui couvrent
  les plages scannées sont lues (sinon celle de l’adresse du Mac). La plage la plus précise
  l’emporte ; s’il n’y en a aucune, SNMP seulement. Les plages qui se chevauchent entre deux
  FortiGate sont signalées.
- La source de l’emplacement d’un appareil (fiche Appareil, Scanner) indique le site de la
  FortiGate.
- La FortiGate de la 0.9.0 devient automatiquement le premier site, avec son jeton et son
  empreinte, sans rien ressaisir.
- **Sauvegardes** : la liste des jetons à ressaisir donne le site de chaque FortiGate. Les
  jetons ne sont jamais copiés.
- Les FortiSwitch de deux sites qui ont la même adresse FortiLink (10.255.1.2…) apparaissent
  tous, chacun avec son site.

### Corrigé
- Aucun défaut de la 0.9.0 n’a été signalé ; les corrections de cette version portent sur les
  nouveautés ci-dessus, avant leur publication.

### Limites
- Essayé sur une seule vraie FortiGate (celle de la 0.9.0) ; la liste de 20 sites, le choix
  par plage et l’import CSV ne sont vérifiés que par les tests et la démonstration.
- Les plages couvertes sont en IPv4 ; un seul VDOM par entrée (ajouter une entrée par VDOM).
- FortiManager n’est pas interrogé : chaque FortiGate est lue directement, avec son jeton.
- Lecture seule : NetScope ne change aucun réglage des FortiGate ni des FortiSwitch.

## 0.9.0 — 2026-11-04

FortiGate et FortiSwitch : les switchs FortiSwitch gérés par une FortiGate (FortiLink) sont lus
par l’API REST de la FortiGate, en lecture seule, sans jamais interroger les switchs eux-mêmes,
dont les adresses du réseau FortiLink (10.255.1.x) ne sont pas joignables depuis le Mac.

### Ajouté
- **Réglages › Switchs › Contrôleur FortiGate** : adresse, port HTTPS, VDOM facultatif, jeton
  d’API gardé au Trousseau, empreinte du certificat (souvent autosigné) à accepter une fois, et
  bouton « Tester » qui affiche le modèle, la version de FortiOS, le nombre de FortiSwitch et
  le nombre d’appareils détectés.
- **Aide pas à pas** pour créer sur la FortiGate un administrateur « API REST » en lecture
  seule, limité à l’adresse de ce Mac (hôtes de confiance).
- **Switchs et ports** : les FortiSwitch apparaissent avec l’étiquette « via FortiGate », leur
  façade et un tableau de leurs ports (état, vitesse, VLAN natif, PoE, appareil branché) ;
  bouton « Relire la FortiGate ».
- **Diagnostic** : bouton « Copier les réponses brutes » (sans le jeton), pour ajuster la
  lecture à votre version de FortiOS.

### Modifié
- **Scanner et fiche Appareil** : les colonnes Switch / Port et VLAN sont remplies par la
  FortiGate, prioritaire sur SNMP ; le nom d’un appareil inconnu est tiré de la FortiGate, et
  les MAC des autres VLAN sont complétées par la table ARP de la FortiGate. Le bilan des
  switchs du Scanner cite la FortiGate et ses FortiSwitch.
- La FortiGate est relue à la fin de chaque scan et avec « Interroger les switchs ».
- Un FortiSwitch sans PoE affiche « Non · aucun port PoE » au lieu d’un PoE inconnu.

### Corrigé
- Captures hors écran : la fenêtre n’est plus ramenée à la hauteur de l’écran
  (`--size 1440x2600` montre toute la page).

### Sécurité
- Le jeton ne figure jamais dans une adresse, un journal ni les réponses copiées ; il passe
  seulement dans l’en-tête de la requête HTTPS.
- Un certificat dont l’empreinte change après avoir été accepté est refusé.

### Limites
- Rien n’a encore été essayé sur une vraie FortiGate : la lecture est écrite d’après la
  documentation de FortiOS 6.4 à 7.6 et tolère des noms de champs différents, mais une version
  peut répondre autrement (les réponses brutes copiables servent à l’ajuster).
- Une seule FortiGate (et un seul VDOM) à la fois ; FortiManager et les sites multiples
  viendront plus tard.
- Lecture seule : NetScope ne change aucun réglage de la FortiGate ni des FortiSwitch.

## 0.8.1 — 2026-11-04

Correctif : « Vitesse des disques » ne ferme plus l’application à la fin d’un test sur un
partage réseau (NAS).

### Corrigé
- **Vitesse des disques** : quand l’interface donnait un débit de lien invalide (nul, presque
  nul ou infini), le calcul « C’est X % du débit du lien » du bilan devenait infini et
  l’application se fermait à la fin du test. Ce débit est maintenant ignoré (bilan « Débit du
  lien inconnu » ou « Limité par le serveur »), de même qu’une latence ou un débit montant
  invalides ; une valeur impossible s’affiche « — ».
- **Même famille de plantages ailleurs** : 22 conversions de mesures en nombres entiers sont
  protégées contre les valeurs infinies, NaN ou hors limites. Elles touchent le Speedtest
  (iperf3, Ookla, NDT7, forfait saisi), les Ressources, les seuils de Surveillance, l’état des
  services (port invalide), la capture de paquets (horodatages pcapng aberrants, très grandes
  trames), les délais des outils, les notifications, les alertes, le Wi-Fi et les durées
  affichées. Les valeurs normales s’affichent comme avant.

### Ajouté
- Tests « Nombres sûrs » et « bilan sans plantage avec des valeurs invalides » : NaN, infini,
  zéro et très grandes valeurs passés aux fonctions de calcul et d’affichage.

## 0.8.0 — 2026-11-04

Réglages et alertes : la plupart des sections « Bientôt » des Réglages fonctionnent (notifications,
raccourcis, export et sauvegarde, identifiants SSH et WMI, méthodes de découverte), et les
alertes peuvent partir hors du Mac, par courriel ou par webhook Teams, Slack ou JSON.

### Ajouté
- **Réglages › Notifications** : choix des événements signalés (sonde en panne, en alerte ou
  rétablie, nouvel appareil sur une plage surveillée, appareil déplacé, conflit d’adresse IP,
  serveur DHCP non autorisé, incident d’un service en ligne, mise à jour disponible, fin de
  scan), son au choix (aucun, critiques seulement, tous) et heures « Ne pas déranger » (de… à…,
  même par-dessus minuit), que les événements critiques peuvent passer outre.
- Les rafales sont regroupées : au-delà de 3 événements du même type en 5 minutes, une seule
  notification les résume.
- Bouton « Envoyer une notification de test », état de l’autorisation de macOS avec un
  raccourci vers Réglages Système si elle est refusée, et liste des derniers événements avec ce
  qui en a été fait.
- Nouvelles notifications : fin de scan (quand NetScope n’est pas au premier plan), conflit
  d’adresse IP, serveur DHCP non autorisé, mise à jour disponible. Un clic sur une notification
  ouvre directement la sonde, le service, l’appareil ou l’écran concerné.
- **Menus Scan, Appareil et Aller** : lancer, arrêter ou relancer un scan, rescanner les ports
  de la sélection, changer de profil, ping continu, fiche, copier l’IP ou la MAC, ouvrir dans le
  navigateur, aller à chaque écran (⌘1 à ⌘9), rechercher partout (⌘F), exporter (⌘E),
  Réglages (⌘,).
- **Réglages › Raccourcis** : tous les raccourcis se modifient (cliquer puis taper la
  combinaison) ; les conflits entre raccourcis ou avec macOS sont signalés ; retour aux valeurs
  par défaut.
- **Réglages › Export et sauvegarde** : sauvegarde automatique quotidienne et bouton
  « Sauvegarder maintenant » (réglages, plages, profils, inventaire, historiques de
  Surveillance, services en ligne, disques, identifiants), en archive .zip ou en dossier daté,
  avec manifeste ; dossier au choix, nombre de sauvegardes gardées, copie facultative dans
  iCloud Drive.
- Liste des sauvegardes (date, type, taille, contenu) avec restauration après confirmation :
  l’état actuel est d’abord gardé dans une sauvegarde de sécurité, puis NetScope redémarre ; on
  peut aussi restaurer une sauvegarde venue d’un autre Mac.
- Format d’export par défaut (CSV, JSON ou PDF) ; export JSON des résultats du Scanner.
- **Identifiants** : bouton « Tester » pour la communauté SNMP v2c et l’utilisateur SNMP v3,
  vers l’adresse choisie, qui affiche sysName, sysDescr et la durée de fonctionnement, ou une
  erreur expliquée (délai, port fermé, utilisateur inconnu, authentification, déchiffrement).
- **SNMP v3** pris en charge (authentification MD5 à SHA-512, chiffrement DES et AES).
- **Identifiants SSH et WMI** : liste, mot de passe ou clé ~/.ssh choisie, DOMAINE\utilisateur
  pour Windows, secrets au Trousseau, test SSH (« uname -a ») et test de joignabilité
  WMI/WinRM (ports 135, 5985, 5986).
- **Profils de scan** : choix des méthodes de découverte de chaque profil (ICMP, ARP, présence
  TCP, UDP, DNS inverse, mDNS, NetBIOS, SNMP, écoute LLDP/CDP passive), appliquées par le
  Scanner.
- **Réglages › Alertes**, alertes hors du Mac : par courriel (serveur SMTP, port, STARTTLS sur
  587 ou TLS sur 465, compte) et par webhook Microsoft Teams (Workflows), Slack ou JSON
  générique. Désactivées par défaut : rien n’est envoyé tant qu’elles ne sont pas activées.
- Bouton « Envoyer un test » sur chaque canal, avec confirmation avant l’envoi et résultat
  affiché sous le bouton.
- Règles d’envoi : choix des événements (sonde en panne, en alerte ou rétablie ; nouvel
  appareil ; serveur DHCP non autorisé ; incident d’un service en ligne ; fin de scan), gravité
  minimale, anti-rafale (au plus une alerte par événement et par intervalle), regroupement en un
  seul résumé, heures de silence où les alertes critiques peuvent passer quand même.
- Journal des envois : date, canal, alerte, résultat (envoyée ou échec) et détail, sans aucun
  secret.
- Surveillance : l’éditeur de sonde montre où partent les alertes de la sonde (courriel, Teams,
  Slack…) et permet de l’exclure des alertes ; colonne facultative « Alertes externes » dans le
  tableau des sondes.

### Modifié
- Le bouton « Exporter » du Scanner suit le format d’export par défaut.
- Les profils de scan existants gardent leur comportement : leurs méthodes de découverte
  reprennent celles d’avant.
- Le mot de passe SMTP, les adresses des webhooks et l’en-tête d’authentification sont gardés
  au Trousseau macOS, jamais dans les préférences ni dans le journal. Les sauvegardes ne copient
  jamais les secrets du Trousseau : seuls les noms des comptes à ressaisir sont notés.

### Corrigé
- Réglages › Général ne présente plus comme « bientôt » le thème sombre (NetScope suit déjà l’apparence de macOS) ni l’icône de la barre de menus (elle apparaît dès que des sondes de Surveillance existent).
- Erreurs d’envoi expliquées en français au lieu d’un code brut : authentification refusée
  (avec conseil pour Microsoft 365 et Gmail), port bloqué, certificat refusé, relais refusé,
  webhook révoqué ou introuvable.

### Limites connues
- Courriel : authentification SMTP par mot de passe seulement (AUTH PLAIN ou LOGIN), pas
  d’OAuth 2 ; pour Microsoft 365, il faut que l’envoi SMTP authentifié soit permis sur la boîte,
  et pour Gmail, un mot de passe d’application.
- WMI : seulement un test de joignabilité (ports 135, 5985, 5986) ; NetScope n’interroge pas
  encore WMI ni WinRM.
- Après une restauration, les mots de passe, communautés et jetons sont à ressaisir.
- Pas encore essayé sur de vrais serveurs SMTP, canaux Teams et Slack, ni de vrais équipements
  SNMP v3 : essais réels à faire.
- Toujours à venir dans les Réglages : plusieurs sites et la langue anglaise.

## 0.7.0 — 2026-11-04

Analyse avancée : capture et inspection de paquets façon Wireshark, et mesure de la vitesse des
disques (internes, externes, partages réseau et dossiers nuage), toutes deux dans la Boîte à
outils.

### Ajouté
- **Capture de paquets** (Boîte à outils), façon Wireshark : choix de l’interface, filtre de
  capture (syntaxe tcpdump) avec préréglages (hôte, port, ARP, DNS, DHCP, ICMP, LLDP/CDP) et
  limites de durée, de nombre de paquets et de taille.
- Liste des paquets en direct (n°, temps, source, destination, protocole, longueur, résumé), une
  couleur par protocole, retransmissions et réinitialisations TCP repérées.
- Filtre d’affichage simple (ex. « dns || tcp.port == 443 », « ip.addr == 10.0.0.0/24 »,
  « tls.sni contains office ») et filtres rapides.
- Détail de chaque paquet en arbre par couche, avec vue hexadécimale et ASCII où le champ choisi
  est surligné ; un clic sur un octet montre le champ qui le contient.
- Décodage d’Ethernet, VLAN 802.1Q, ARP, IPv4/IPv6, ICMP/ICMPv6, TCP, UDP, DNS, mDNS, NetBIOS,
  DHCP, HTTP, TLS (version, SNI), LLDP/CDP et STP.
- **Suivre le flux** : les données d’une conversation TCP ou UDP remises dans l’ordre, sans les
  retransmissions.
- Statistiques de capture : protocoles, conversations, plus gros émetteurs, retransmissions,
  paquets hors ordre, ACK en double et RST.
- Ouverture d’un fichier .pcap ou .pcapng ; enregistrement en .pcap (tous les paquets ou
  seulement ceux affichés), ouvrable dans Wireshark.
- Capture sans mot de passe si l’accès BPF est déjà donné (ChmodBPF de Wireshark), sinon une
  seule autorisation d’administrateur. La capture écoute seulement : rien n’est envoyé sur le
  réseau.
- **Vitesse des disques** (Boîte à outils, groupe Performance, aussi accessible depuis le
  Speedtest) : écriture et lecture d’un disque interne ou externe, d’un partage réseau monté
  (SMB, NFS, AFP) ou d’un dossier nuage (OneDrive, Google Drive, Dropbox, iCloud Drive).
- Mesures honnêtes : blocs de 1 Mio sans passer par le cache du système, accès aléatoires
  4 Kio (IOPS, latence moyenne et p95), jauges et courbe en direct, taille de 256 Mio à 10 Gio,
  plusieurs passes et bouton Arrêter.
- Partages réseau : débit du lien Wi-Fi ou Ethernet et latence vers le serveur affichés à côté,
  avec un bilan en clair (« Limité par le réseau Wi-Fi à 866 Mbit/s », limité par la latence
  ou par le serveur).
- Dossiers nuage : vitesse de la copie locale, puis temps jusqu’à « envoyé » quand le service
  le signale ; confirmation demandée avant d’écrire plus de 1 Gio.
- Historique des tests par emplacement, export CSV et nouvelle section facultative « Vitesse
  des disques » dans les Rapports.

### Modifié
- Speedtest : lien direct vers le nouvel outil « Vitesse des disques ».
- Vitesse des disques, sécurité : le fichier d’essai va seulement dans un dossier
  « NetScope-test », supprimé à la fin, à l’arrêt ou au lancement suivant ; l’espace libre est
  vérifié avant le test et aucun autre fichier n’est touché.

### Corrigé
- Capture de paquets : un filtre de capture ne peut plus glisser d’option dans tcpdump ;
  « Arrêter » pendant la préparation annule vraiment ; une capture sans paquet est signalée.
- Ouverture d’un gros .pcap sans figer l’interface (plafond de 200 000 paquets, avec avis
  « fichier tronqué ») ; plus de plantage du filtre d’affichage sur un nombre immense.
- Suivre le flux : copie conforme à l’affichage (ASCII ou hexadécimal) et message d’aide sans
  paquet TCP ou UDP ; sélection conservée après un filtre.
- Vitesse des disques : un test relancé juste après un arrêt n’est plus perturbé par le
  précédent ; bilan correct quand l’envoi nuage finit pendant l’écriture ; export CSV raté
  signalé.

### Limites
- Capture : pas de déchiffrement TLS (seuls la version et le SNI sont lus) ; les décodeurs sont
  de base, loin de la profondeur de Wireshark ; le filtre d’affichage ne couvre qu’une partie de
  sa syntaxe. Sans ChmodBPF, chaque capture demande l’autorisation d’administrateur.
- Vitesse des disques : un partage réseau ou un dossier nuage mesure aussi le réseau et le
  service ; plusieurs services nuage ne signalent pas l’état « envoyé », et NetScope le dit
  alors clairement au lieu de deviner.
- Ces deux outils n’ont pas encore été essayés en vrai en dehors des données de démonstration
  (vraie capture, vrais NAS et dossiers nuage) ; essais réels à faire.

## 0.6.0 — 2026-11-04

Internet et nuage : état des grands services en ligne (vu par leur page officielle et testé
depuis votre réseau) et nouveau groupe « Courriel » dans la Boîte à outils (santé d’un domaine,
MX, listes noires, SPF/DKIM/DMARC, diagnostic SMTP, analyse d’en-têtes), avec une Recherche DNS
plus complète.

### Ajouté
- **État des services** (Boîte à outils) : Microsoft 365 (Outlook, Teams, SharePoint,
  OneDrive), Azure, Apple, AWS, Google Workspace et Cloud, Cloudflare, Zscaler, Okta, GitHub,
  Atlassian, Zoom, Slack et Dropbox d’un coup d’œil.
- Pour chaque service, deux sources : sa page d’état officielle et un test **depuis votre
  réseau** (résolution DNS, connexion TLS, réponse HTTPS, avec latence). Le bilan distingue
  « panne chez eux » et « injoignable d’ici » (DNS, pare-feu, proxy ou lien Internet).
- Incidents en cours avec titre, services touchés, début, dernière mise à jour et lien vers la
  page officielle ; historique sur 30 jours.
- Liste des services modifiable : chaque service peut être désactivé, et on peut ajouter les
  siens (page Statuspage, RSS…, et adresses clés à tester).
- **Microsoft 365, en option** : santé détaillée de votre locataire par Microsoft Graph, le
  secret de l’application étant gardé au Trousseau.
- Vérification automatique réglable (toutes les 5 minutes par défaut) et notification macOS à
  chaque nouvel incident ou service injoignable.
- **Surveillance** : tuile « Services en ligne », section dans le menu de la barre de menus et
  nouveau type de sonde « Service en ligne ».
- **Nouveau groupe « Courriel »** dans la Boîte à outils :
  - **Super outil courriel** : un seul champ qui reconnaît un domaine, une adresse courriel,
    une adresse IP ou un nom d’hôte et lance les vérifications utiles, avec un bilan coloré
    (OK, alerte, erreur).
  - **Santé courriel** : note sur 100 d’un domaine (MX, SPF, DKIM, DMARC, listes noires,
    MTA-STS, TLS-RPT, DNSSEC, BIMI) avec recommandations classées par gravité ; bilan à copier
    ou à ajouter au rapport.
  - **Recherche MX** : serveurs par priorité, adresses IPv4 et IPv6, DNS inverse et cohérence
    (le PTR revient-il à la même adresse ?).
  - **Listes noires** : une IP ou un domaine (et les adresses de ses MX) dans 21 listes
    DNSBL/RBL (Spamhaus ZEN et DBL, Barracuda, SpamCop, UCEPROTECT, PSBL, Mailspike, SURBL,
    URIBL…), codes de retour expliqués et lien de retrait ; trois requêtes à la fois, espacées.
  - **SPF, DKIM, DMARC…** : lecture et explication terme à terme de SPF, DMARC, DKIM, BIMI,
    MTA-STS et TLS-RPT ; erreurs détectées (plus de 10 recherches DNS SPF, boucle d’include,
    « +all », politique DMARC « none », clé DKIM trop courte ou révoquée, fautes de syntaxe) ;
    arbre des include SPF ; 34 sélecteurs DKIM courants essayés, plus le vôtre.
  - **Diagnostic SMTP** d’un serveur ou des MX d’un domaine (ports 25, 587 et 465) : bannière,
    EHLO et extensions expliquées, STARTTLS, poignée TLS et certificat (émetteur, validité,
    noms couverts), temps de chaque étape et échange complet. **Aucun courriel n’est envoyé**
    (seulement EHLO, STARTTLS et QUIT). Avertit quand le port 25 sortant semble bloqué par le
    fournisseur d’accès, et vérifie la cohérence de la bannière, du DNS inverse (PTR confirmé)
    et du nom du certificat.
  - **Analyse d’en-têtes** : coller les en-têtes d’un courriel pour voir son trajet (chaque
    saut avec heure et délai, IP d’origine), les résultats SPF, DKIM et DMARC, et les alertes
    d’usurpation (domaine sosie, nom affiché trompeur, Reply-To ou Return-Path vers un autre
    domaine, échec DMARC). Tout reste sur le Mac.
- **Rapports** : section facultative « Santé courriel » (note, vérifications,
  recommandations), dans les exports PDF, CSV, JSON et HTML.

### Modifié
- **Recherche DNS** : nouveaux types SOA, SRV, CAA, DNSKEY et DS, avec une explication en clair
  de chaque enregistrement (numéro de clé DNSSEC, autorité de certification permise…).
- Recherche DNS : vue « Comparer » (la même question à plusieurs serveurs, réponses côte à
  côte, écarts signalés) et vue « Propagation » (dix résolveurs publics, dont CIRA Canadian
  Shield, pour voir qui a déjà la nouvelle réponse).

### Corrigé
- Outils courriel et état des services : corrections de relecture (libellés, colonnes des
  tableaux DNS et de l’état des services, tuiles et en-têtes, mode sombre et petite fenêtre).

### Limites
- L’état des services dépend des pages officielles publiques : un incident n’apparaît que
  lorsque le fournisseur le publie, et certaines pages (Apple, AWS, Azure…) donnent moins de
  détails que les pages Statuspage. La santé détaillée Microsoft 365 demande une application
  inscrite dans Entra ID (droit ServiceHealth.Read.All) ; sans elle, seule la page publique
  est lue.
- Listes noires : Spamhaus (et quelques autres listes) refusent les requêtes venant des
  résolveurs publics (8.8.8.8, 1.1.1.1…) ; ces refus sont signalés et ne sont pas comptés comme
  inscriptions, mais il faut un DNS du fournisseur ou un résolveur local pour un vrai résultat.
- Diagnostic SMTP : beaucoup de fournisseurs d’accès bloquent le port 25 sortant ; il faut
  alors tester sur 587 ou 465, ou depuis un autre réseau. Aucun test de relais ouvert n’est fait.
- DKIM : sans le sélecteur réel, une clé n’est trouvée que si elle porte un des 34 noms
  courants. La vue « Propagation » interroge directement des résolveurs publics (port 53) : un
  pare-feu qui force le DNS local peut fausser le résultat.
- Ces outils n’ont pas encore été essayés sur de vrais domaines et serveurs en dehors des
  données de démonstration ; essais réels à faire.

## 0.5.0 — 2026-11-04

Diagnostic du poste et du réseau local : PoE de ce Mac et des appareils, ressources
(processeur, mémoire, trafic) de ce Mac et des appareils SNMP, choix du serveur Speedtest et
bouton « Installer » pour les outils manquants.

### Ajouté
- **« Suis-je sur un port PoE ? »** (Outils › Capture LLDP/CDP) : pour ce Mac, port PoE oui ou
  non, alimentation fournie, type 802.3af/at/bt, classe, puissance demandée et allouée,
  d’après les annonces PoE du switch (802.3, LLDP-MED et CDP).
- **PoE port par port** dans Switchs et ports (activé, en charge, défaut, classe, priorité),
  avec les watts réels sur Cisco et HPE/Aruba ; la façade et le détail du port l’affichent
  (« Classe 4 · 18,4 W »).
- **Scanner : colonne facultative « PoE »** (Colonnes › PoE) : chaque appareil est-il
  alimenté par PoE sur son port de switch, et avec quelle puissance ; ligne « PoE » dans
  l’emplacement physique de la fiche Appareil.
- **Ressources** : nouvel onglet dans la fiche Appareil. Pour ce Mac : processeur total et
  par cœur (performance et efficacité), mémoire comme le Moniteur d’activité avec la
  pression, débit de chaque interface, sans aucun trafic réseau. Pour les appareils du réseau,
  par SNMP v2c en lecture : processeur et mémoire (HOST-RESOURCES-MIB, puis MIB Cisco,
  Fortinet et HPE) et trafic de chaque interface (compteurs 64 bits, ou 32 bits avec retour à
  zéro corrigé), en pourcentage de la vitesse du lien, avec erreurs et rejets.
- **Switchs et ports** : panneau « Ports les plus chargés » du switch (avec son processeur et
  sa mémoire) et panneau « Trafic du port » pour le port choisi : débit en direct, charge du
  lien, nouvelles erreurs, courbe des 5 dernières minutes.
- Courbes des 5 dernières minutes, intervalle de relevé réglable, pause et export CSV de
  l’historique.
- **Barre de menus** : tuile « Ce Mac » avec le processeur, la mémoire et le réseau en direct.
- **Surveillance** : sondes « Processeur > X % », « Mémoire > X % » et « Port saturé > X % »,
  pour ce Mac ou pour un appareil SNMP ; la pression mémoire critique et les nouvelles erreurs
  d’un port alertent aussi.
- **Speedtest › Serveurs** : choix du serveur de test : automatique (le plus proche), liste
  Cloudflare, M-Lab et LibreSpeed avec ville, opérateur et latence mesurée, favoris (étoile)
  et serveur personnalisé (compatible LibreSpeed).
- Speedtest : mesure par **M-Lab** (protocole NDT7) et par les serveurs **LibreSpeed**, en
  plus de Cloudflare ; par **Ookla** (Speedtest.net) quand son outil officiel est installé,
  avec mention de sa licence.
- **Bouton « Installer »** pour les outils manquants (iperf3, telnet, Speedtest d’Ookla) : la
  commande Homebrew est affichée, Terminal l’attend jusqu’à Entrée, puis NetScope détecte
  l’outil de lui-même ; sans Homebrew, explication et liens officiels.
- Speedtest › Réseau local : panneau « Sur l’appareil cible » avec la commande `iperf3 -s` à
  copier et les liens pour Mac, Linux et Windows.

### Modifié
- Switchs et ports : l’encart « Ce Mac est branché sur… » dit si le port est PoE et s’il
  fournit du courant.
- Speedtest › Internet : le panneau « Serveur de test » remplace « bientôt » par un vrai choix
  (automatique, favoris) et affiche le protocole utilisé.
- Speedtest › Historique : le serveur de chaque test est retenu ; une « Comparaison par
  serveur » montre les moyennes de descente, de montée et de latence ; colonne Source dans le
  tableau et dans l’export CSV.

### Corrigé
- Speedtest : plus d’état « en cours » sans fin (test terminé sans résultat, Ookla arrêté,
  M-Lab sans serveur) ; serveur et durée remis à zéro à chaque test.
- Bouton « Installer » : le message de fin s’affiche enfin dans Terminal.
- Surveillance : les sondes de ressources utilisent la communauté SNMP propre à l’appareil ;
  les seuils de latence et de perte sont masqués quand ils sont sans objet.

### Limites
- Un Mac ne consomme pas de PoE : pour lui, NetScope dit seulement si le port du switch est
  PoE et s’il fournit du courant, et seulement si le switch annonce son PoE en LLDP ou CDP
  (capture : accès BPF ou autorisation d’administrateur).
- Les watts réels par port ne sont lus que sur Cisco et HPE/Aruba ; ailleurs, l’état et la
  classe PoE seulement. Ressources et PoE des autres appareils demandent SNMP v2c en lecture.
- Le serveur du fournisseur n’est pas encore détecté automatiquement. Ookla n’est utilisé que
  si son outil officiel est installé ; NetScope ne l’installe jamais sans ton clic.

## 0.4.1 — 2026-11-03

### Ajouté
- Deux types d’appareil : **Console de jeu** et **Domotique**, au clic droit « Changer le type »,
  dans l’Inventaire et à l’import CSV. Détection automatique : Nintendo, Sony Interactive, Valve,
  noms Xbox / PS5 pour les consoles ; Philips Hue (Signify), Lutron, ecobee, Shelly, Tuya,
  Home Assistant (port 8123) pour la domotique.

## 0.4.0 — 2026-11-03

Tableaux standard dans tous les écrans, colonne Type modifiable, préréglages de ports dans le
Scanner et style Mac natif (mode sombre, petite fenêtre).

### Ajouté
- **Tableaux standard** dans tous les écrans (Scanner, Inventaire, Analyse, Switchs, Wi-Fi,
  Outils, Appareil, Surveillance, Ping continu, Speedtest, Accès distant, Réglages) : tri par
  en-tête, colonnes redimensionnables, masquables et ajoutables (menu « Colonnes », clic droit
  sur l’en-tête, « Rétablir les colonnes par défaut ») ; colonnes, largeurs et tri retenus par
  tableau. De nombreuses colonnes facultatives (première vue, OUI, plage, PoE, SNR…).
- La colonne « Ports ouverts » affiche autant de ports que la largeur le permet, puis « +N »,
  avec la liste complète en infobulle.
- **Scanner : colonne Type** (icône et libellé, triable) ; clic droit « Changer le type › … »
  sur un ou plusieurs appareils, aussi depuis le panneau de détail et la fiche Appareil, avec
  « Revenir au type détecté ». Le type choisi est retenu dans l’inventaire, repris par la Carte,
  l’Analyse, le Wi-Fi et les Rapports ; un scan ne le remplace jamais.
- **Scanner : préréglage de ports** : menu « Ports : 20 essentiels » dans la barre d’outils
  (« Rescanner les ports avec ce préréglage », « Modifier les préréglages… ») et clic droit
  « Scanner les ports › … » sur les appareils choisis, avec avancement et « Arrêter ».
- Wake-on-LAN : tableau de tous les postes réveillables ; Capture LLDP/CDP : tableau des
  voisins quand plusieurs répondent.

### Modifié
- **Style Mac natif** : barre latérale et barre d’outils du système, contrôles natifs, couleur
  d’accent de macOS.
- **Mode sombre** automatique sur tous les écrans.
- **Petite fenêtre** (jusqu’à 900 × 600) : les écrans défilent et se réorganisent au lieu
  d’être coupés ; le panneau de droite se replie ou passe sous le contenu.
- Les ports du profil Personnalisé n’ont plus qu’une source : Réglages › Profils de scan
  (l’ancienne liste est reprise automatiquement).
- « Profil : … » du Scanner devient un menu ; recherche globale plus courte.

### Corrigé
- Analyse : l’axe d’« Appareils en ligne » ne chevauche plus le premier point ; nombre et
  pourcentage par fabricant séparés.
- Espaces insécables avant « : ; ? ! % » dans les textes restants.

## 0.3.1 — 2026-11-03

Plus d’informations d’un autre réseau présentées comme actuelles.

### Corrigé
- Scanner : le bilan ne signale plus un switch d’un autre réseau (découvert lors d’un scan
  précédent) comme « trouvé mais relevé impossible ». En fin de scan, les switchs d’un autre
  réseau ne sont plus interrogés : pas d’attente inutile et pas de communauté SNMP envoyée
  ailleurs. Les switchs ajoutés à la main restent relevés (VLAN de gestion routé).
- Scanner : le bilan des switchs est rattaché aux plages et au réseau du scan qui l’a produit ;
  il est masqué si les plages cochées ne les recouvrent plus, filtré en cas de recouvrement
  partiel, grisé si le réseau a changé, et nomme la plage (« Plage 10.182.122.0/24 : … »).
- Emplacements Switch / Port et VLAN : présentés comme actuels seulement s’ils ont été relevés
  sur le réseau actuel et confirmés par la dernière découverte ; sinon grisés avec la raison
  (plage décochée, réseau changé, ancien relevé non confirmé), dans le Scanner, la fiche
  Appareil et la Carte du réseau.
- Switchs et ports : l’encart « Ce Mac est branché sur… » indique la date, l’interface et le
  réseau de la capture, et devient « Ce Mac était branché sur… », grisé, si l’interface, le
  sous-réseau, la passerelle ou le lien (câble déplacé) a changé.
- L’interface active, sa passerelle et ses DNS sont relus toutes les 15 s (lecture locale,
  sans trafic) ; l’interface choisie dans Réglages › Interface est gardée.

## 0.3.0 — 2026-11-03

Surveillance, Rapports, Test DHCP et capture LLDP/CDP : les deux derniers écrans en construction
et les deux outils « Bientôt » sont faits.

### Ajouté
- **Surveillance** : sondes Ping, TCP, HTTP(S) (code attendu, mot-clé, expiration du
  certificat), DNS, SNMP (valeur d’un OID), port de switch et nouveaux appareils ; seuils de
  latence, de perte et d’échecs consécutifs, plage horaire et dépendance entre sondes.
  - Barre de disponibilité 24 h par sonde, éditeur avec « Tester maintenant », journal des
    alertes avec filtres, « Accuser réception » et export CSV.
  - Notifications macOS des alertes et des retours à la normale.
  - Icône dans la barre de menus (état du réseau, latence de la passerelle, alertes,
    « Scan rapide », « Ouvrir NetScope ») ; les sondes continuent fenêtre fermée.
  - Badge de la barre latérale = alertes non lues ; historique dans
    `~/Library/Application Support/NetScope/surveillance.json`.
- **Rapports** : modèles Audit réseau complet, Inventaire simple, Sécurité et Intervention
  technique ; client, site, technicien, date, logo et sections à cocher.
  - Aperçu page par page au format lettre et export PDF natif (en-tête, « Page N de M »,
    bloc de signature) ; exports CSV (protégé contre les formules), JSON et HTML.
  - Sections tirées du scan, de l’inventaire, des switchs et du Wi-Fi : résumé, plan
    d’adressage, switchs et ports, points d’accès, ports ouverts à risque, problèmes et
    recommandations, inventaire avec l’emplacement physique, annexe brute.
  - « Enregistrer comme modèle », rapports récents, option « Masquer les adresses MAC », et
    « Envoyer par courriel », qui prépare un brouillon Mail avec le PDF joint sans rien envoyer.
- **Test DHCP** (Boîte à outils) : envoie un DHCPDISCOVER (jamais de DHCPREQUEST), liste chaque
  serveur qui répond avec son offre (adresse, masque, passerelle, DNS, domaine, bail, T1/T2,
  options 66, 67 et 43) et signale tout serveur DHCP non autorisé (liste réglable) ;
  « Créer une alerte » l’ajoute à Analyse.
- **Capture LLDP/CDP** (Boîte à outils) : switch, port, VLAN natif et voix, adresse de
  gestion, modèle, capacités et PoE du port où ce Mac est branché, avec compte à rebours ; encart
  « Ce Mac est branché sur… » dans Switchs et ports.
  - Accès aux trames par /dev/bpf s’il est déjà permis (ChmodBPF de Wireshark), sinon par
    tcpdump lancé une seule fois avec l’autorisation d’administrateur de macOS, en lecture
    seule, avec un filtre fixe et une durée bornée.
- **Accès distant** : Fenêtre ou Plein écran par connexion RDP et VNC, rappelé dans le panneau
  de détail, et menu du bouton « Connecter » pour choisir pour cette fois seulement.
  - RDP en fenêtre : taille au choix (Ajuster, 1280 × 800, 1440 × 900, 1920 × 1080 ou
    personnalisée) ; « Tous les écrans » en plein écran ; le fichier .rdp suit le choix.
  - VNC : mise à l’échelle de Partage d’écran (Ajuster à la fenêtre ou Taille réelle) et
    plein écran après l’identification, avec l’autorisation Accessibilité.
- `docs/A-FAIRE.md` (notes d’essai et suite prévue) et `docs/feuille-de-route.html`.

### Corrigé
- Wi-Fi : « Autoriser la localisation » affiche enfin la fenêtre de macOS (droit de
  localisation ajouté à la signature, clé NSLocationUsageDescription). Le bouton suit l’état de
  l’accès (désactivé, en attente, refusé ou restreint, autorisé), ouvre Réglages Système ›
  Service de localisation quand macOS ne redemande plus, et actualise les noms des réseaux une
  fois l’accès autorisé.
- Accès distant : le nom d’une connexion n’est plus tronqué dans le titre du panneau de détail.

## 0.2.1 — 2026-11-03

Les fabricants viennent maintenant du registre IEEE complet.

### Corrigé
- Beaucoup d’appareils affichaient « Inconnu » comme fabricant : la table intégrée ne comptait
  qu’environ 230 préfixes. Le Scanner, l’Inventaire, la fiche appareil et la Boîte à outils
  utilisent désormais la base complète ; les adresses aléatoires restent « Adresse privée
  (aléatoire) ».
- Le type d’appareil deviné d’après le fabricant compare des mots entiers (« Intelbras » n’est
  plus pris pour Intel, ni « Amazonia » pour Amazon).
- Une base téléchargée autrefois depuis l’IEEE ne masque plus la base plus récente fournie
  avec une nouvelle version de l’application : la plus récente l’emporte.

### Ajouté
- Base complète des fabricants du registre IEEE (MA-L, MA-M et MA-S : environ 53 700
  préfixes, plus long préfixe d’abord), fournie avec l’application, avec des noms courts
  lisibles (« Huawei », « TP-Link », « HPE Aruba »…).
- Réglages › Général › Base des fabricants : source, nombre de préfixes, bouton « Mettre à
  jour depuis l’IEEE » (téléchargement des trois fichiers du registre, vérification,
  conversion, seulement sur demande) et « Revenir à la base intégrée ».
- `scripts/make-oui.py` pour régénérer `Resources/oui.tsv` à partir du registre.

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
- Relecture du scan automatique :
  - le scan Rapide n’efface plus les ports trouvés par un scan approfondi, et la colonne
    Ports ne clignote plus vide pendant le scan ;
  - la découverte SNMP part dès la fin de l’ARP, en parallèle des noms et des ports, et le
    délai TCP du profil Rapide passe à 400 ms : le scan Rapide reste court sur un /24 plein ;
  - DNS inverse limité à 8 requêtes bloquantes à la fois et plafond de descripteurs relevé à
    4 096 au lancement (aucun port déclaré fermé à tort quand le DNS ne répond pas) ;
  - un switch de niveau 3 n’est ajouté qu’une fois, même s’il répond sur plusieurs VLAN ;
  - seuls les relevés réussis pendant le scan servent à localiser les appareils ; le bilan
    distingue switchs relevés, relevés impossibles et scan interrompu, et l’ancien bilan
    disparaît au scan suivant et après « Effacer » ;
  - un délai dépassé sur une table facultative (dot1qVlanFdbId, ipNetToPhysicalTable) ne fait
    plus échouer tout le relevé ; trois VLAN Cisco muets de suite arrêtent la lecture par VLAN ;
  - la découverte n’interroge que les adresses privées, et « Confirmer avant de scanner une
    plage publique » est enfin demandé au lancement du scan ;
  - un switch retiré n’est plus rajouté au scan suivant (liste « Switchs écartés ») ;
  - « Oublier les communautés retenues » dans Réglages › Switchs ; effacer la communauté des
    Identifiants efface aussi la copie retenue par switch ;
  - communautés à essayer masquées (bouton « Afficher ») et une par ligne (« , » et « ; »
    sont permis dans une communauté) ; interrupteur « Lire la table ARP de la passerelle » ;
  - le Trousseau n’est plus lu sur le fil principal (plus de gel à l’ouverture) ;
  - « Arrêter » pendant l’étape SNMP marque quand même hors ligne les appareils absents,
    interrompt aussitôt la résolution de noms et n’inscrit plus d’erreur sur les switchs ;
  - une interrogation manuelle ne peut plus tourner en même temps que la découverte ;
  - en démonstration, « Lancer le scan » et « Scanner les ports » n’envoient plus rien.

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
