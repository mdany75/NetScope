# Changements

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
