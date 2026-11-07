# Changements

## 1.2.2 — 2026-11-06

### Corrigé
- **Bilan de raccordement, PoE** : un FortiSwitch PoE n’annonce pas son alimentation par LLDP,
  et le bilan affichait « Non annoncé ». Il lit maintenant le PoE du port dans le dernier relevé
  du switch (FortiGate ou SNMP) : « Port PoE », ou la puissance fournie. Sans relevé, un modèle
  PoE (ex. FortiSwitch-108E-FPOE) donne « Switch PoE ».

## 1.2.1 — 2026-11-06

### Corrigé
- **Bilan de raccordement** : le port de switch, le VLAN et le PoE restaient « Non mesuré »
  quand l’accès direct aux trames n’est pas permis. Le bilan écoute maintenant lui-même les
  annonces LLDP/CDP avec l’autorisation d’administrateur (fenêtre de macOS), sans renvoyer vers
  la Capture LLDP/CDP. Si l’autorisation est refusée, il reprend la dernière annonce entendue
  sur ce même lien.
- **Capture LLDP/CDP** : le voisin est retenu dès qu’il est entendu, et non plus seulement à
  l’arrêt de la capture ; un bilan lancé pendant l’écoute le reprend.

## 1.2.0 — 2026-11-06

Onduleurs et historique des MAC (notes 98 et 99).

### Ajouté
- **Onduleurs (UPS)** par SNMP (UPS-MIB, puis APC, Eaton et CyberPower) : carte « Onduleur » de
  la fiche (alimentation, batterie, autonomie, charge, tensions, température, dernier test,
  date de pose de la batterie), type « Onduleur » détecté au scan, vue « Onduleurs » de
  l’Inventaire, sonde (sur batterie, autonomie basse, batterie à changer ; un autotest n’est
  pas une panne) et section des rapports. Relevés rangés sous la MAC.
- **Historique d’une adresse MAC** : ports de switch, IP, noms, VLAN et bornes Wi-Fi où un
  appareil a été vu, avec première et dernière vue ; recherche « Où était cet appareil ? »
  par MAC, IP ou nom et par date, chronologie dans la fiche, export CSV. Alimenté par les
  scans et les relevés déjà faits, sans rien de plus sur le réseau.

### Limites connues
- Rien n’a été essayé sur un vrai onduleur : certains numéros des MIB APC, Eaton et CyberPower
  sont à confirmer.
- L’historique des MAC commence avec la 1.2.0 (rien de rétroactif), site actif seulement.

## 1.1.0 — 2026-11-06

Sécurité du réseau (notes 96 et 97).

### Ajouté
- **Serveur DHCP pirate** : chaque serveur qui répond au Test DHCP est jugé attendu (déclaré),
  FortiGate du site ou pirate, avec sa MAC, sa passerelle, ses DNS et sa plage ; la demande ne
  prend jamais de bail. Sans serveur déclaré, un serveur inconnu reste « non vérifié ».
- **Conflits d’adresses IP** (Outils › Adressage) : même IP sur deux MAC, réponses ARP
  contradictoires (usurpation possible, la passerelle en tête), MAC qui change souvent d’IP ;
  d’après la table ARP de ce Mac, les scans et l’ARP de la FortiGate.
- **Bornes Wi-Fi pirates** (Wi-Fi › FortiAP › Pirates) : sosies d’un SSID du site, bornes
  inconnues branchées sur le réseau filaire (port du switch indiqué), bornes non autorisées
  dans FortiOS ; classes pirates, voisines et connues, « Accepter » avec confirmation,
  « Balayer depuis ce Mac ».
- Trois sondes de Surveillance (DHCP pirate, conflit d’IP, borne pirate) et une section
  « Pirates et conflits » des rapports.

### Limites connues
- Rien n’a été essayé sur un vrai réseau. Le lien entre une borne et sa MAC filaire est déduit
  (adresses proches) ; une imprimante en Wi-Fi Direct peut apparaître comme « branchée ».
- Conflits d’IP : site actif seulement, rien n’est gardé dans le temps.

## 1.0.0 — 2026-11-06

Première version stable de NetScope. Elle réunit tout ce qui est livré depuis la 0.1.0 et
termine les petits restes des versions 0.33 à 0.37 (note 95). Les versions suivantes
continuent en 1.x.

### Ajouté
- **Inventaire › Imprimantes** : imprimantes du site triées du consommable le plus bas au plus
  haut (relevés de la fiche et de la sonde « Consommable bas »).
- **Extraits dans la console série** ; extraits personnalisés relus à chaud quand un autre Mac
  les change.

### Modifié
- Ordre alphabétique des dernières listes : formats d’export (Inventaire, Carte, Rapport),
  sources (Trafic, Speedtest, import), préréglages de capture, types d’enregistrement courriel,
  menu des services UDP (les résultats gardent l’ordre des ports).
- Réglages › Sites et plages en petite fenêtre : panneau de droite plus coupé.
- Barre latérale un peu plus large : « Historique et adressage » s’affiche en entier ;
  colonnes de la Surveillance resserrées.
- Captures du README refaites.

### Limites connues
- Le plan du relevé Wi-Fi reste dans le même fichier que les mesures (synchronisation plus
  lourde) : le découpage demande de revoir le transport de la synchronisation.
- Six captures de la galerie montrent encore l’ancienne barre latérale.

## 0.37.0 — 2026-11-06

Imprimantes, VoIP et retour arrière (notes 91, 92 et 93).

### Ajouté
- **Consommables des imprimantes** (SNMP, Printer-MIB) : carte « Consommables » dans la fiche
  (toner ou encre par couleur, tambour, kit de maintenance, bac de récupération, compteur de
  pages, bourrage, bac vide, alertes de l’imprimante), lue sur clic. Sonde de Surveillance
  « Consommable bas » (15 % par défaut) et section « Imprimantes et consommables » des rapports.
- **Qualité VoIP** : note MOS (modèle E, G.107 simplifié) par appel dans les flux RTP de la
  capture de paquets ; « Test VoIP simulé » dans Outils › iperf3 (codec, nombre d’appels) ;
  section « Qualité VoIP » des rapports.
- **Revenir à une version précédente** : Réglages › Mises à jour › « Réinstaller cette
  version » depuis sa Release GitHub, signature Developer ID et équipe vérifiées, données
  gardées. La mise à jour automatique reste coupée jusqu’à « Réactiver ».

### Limites connues
- Rien n’a été essayé sur de vraies imprimantes ni de vrais appels ; le retour arrière n’a
  pas été essayé de bout en bout.
- Le MOS ne compte pas le délai dans un sens (invisible dans une capture) ; le test simulé
  demande iperf3 installé.
- La vue « Imprimantes » de l’Inventaire n’est pas faite (tri par niveau dans le rapport).

## 0.36.1 — 2026-11-06

### Modifié
- Barre latérale et menu Aller : le **Scanner** reprend la tête de la section Découverte ; les
  autres écrans restent en ordre alphabétique.

## 0.36.0 — 2026-11-06

Relevé Wi-Fi sur plan (note 94).

### Ajouté
- **Wi-Fi › Relevé sur plan** : plan d’étage importé (PDF ou image), échelle par deux points et
  une distance, plusieurs étages par site. Un clic sur le plan mesure le signal, le bruit, le
  débit, la borne et le canal captés par ce Mac (bornes voisines sur demande).
- Carte de chaleur du signal, du rapport signal/bruit, du débit, de la borne ou du canal ;
  zones mortes (sous −75 dBm), chevauchements de canaux, emplacement suggéré d’une borne et
  bilan de l’étage.
- Bornes FortiAP placées à la main sur le plan (liste lue sur la FortiGate) ; mesures nommées
  d’après la borne captée.
- Export PDF et section « Relevé Wi-Fi sur plan » dans les rapports ; relevés synchronisés
  entre les Mac avec le site.

### Limites connues
- Rien n’a été essayé sur un vrai Mac en Wi-Fi (mesure au clic, balayage des voisines, import
  d’un vrai plan).
- La carte ne tient pas compte des murs (interpolation par distance). Le plan est gardé dans
  le fichier du relevé, qui peut peser quelques Mo par étage.

## 0.35.0 — 2026-11-06

Câbles et VLAN (notes 89 et 90).

### Ajouté
- **Test de câble (TDR)** demandé au switch : clic droit sur un port › « Tester le câble… », ou
  section « Test de câble » du détail du port. Résultat par paire (correcte, ouverte,
  court-circuit, distance du défaut), historique du port, ajout au bilan de raccordement.
  Cisco, Aruba AOS-S et AOS-CX, FortiSwitch (SSH ou par la FortiGate). Désactivé par défaut
  (Réglages), confirmation qui prévient que le lien peut tomber ; liste fermée de commandes.
- **Scanner un VLAN tagué** depuis le Mac (Scanner › « VLAN tagué… ») : interface 802.1Q
  temporaire sur l’Ethernet (macOS demande le mot de passe administrateur), DHCP ou IP fixe,
  scan, puis retrait de l’interface, même après une erreur ou à la fermeture ; reste nettoyé
  au lancement suivant. VLAN proposés d’après LLDP/CDP, la FortiGate et les switchs.

### Limites connues
- Rien n’a été essayé sur de vrais switchs : formats de sortie TDR écrits d’après la
  documentation, à confirmer ; Aruba AOS-S ne dit pas quelle paire est en défaut.
- `networksetup -createVLAN` pas encore essayé en vrai ; macOS redemande le mot de passe
  administrateur pour retirer l’interface.

## 0.34.0 — 2026-11-06

Suite de l’Accès distant (note 67) et ordre alphabétique partout.

### Ajouté
- **Extraits personnalisés** dans le terminal intégré : bouton « + », pour une marque ou pour
  toutes les sessions, avec ou sans Entrée ; « Modifier… » et « Supprimer… » (avec confirmation)
  au clic droit. Ils s’affichent avant les extraits par marque.
- **Envoi à plusieurs sessions** (« Plusieurs sessions… ») : une commande ou un extrait, sessions
  ouvertes à cocher, confirmation qui nomme chaque destinataire (nom, adresse, site) et dit
  quelles lignes seront exécutées. ⌘Retour pour envoyer ou enregistrer.

### Modifié
- **Ordre alphabétique** (fr_CA, sans casse ni accents) : écrans dans chaque section de la barre
  latérale et du menu Aller, « Ouvrir dans › », types d’appareil, protocoles d’Accès distant,
  contrôleurs, sondes à ajouter, marques de sauvegarde, modèles de rapport, types de partage,
  guides par marque, événements des notifications. Les éléments d’ensemble restent en tête
  (« Général »…) et « Autre », « À propos »… à la fin. Les raccourcis clavier ne changent pas.

### Limites connues
- Aucun essai réel sur de vraies sessions SSH ou Telnet.
- Quelques listes gardent leur ordre (formats d’export, sources, préréglages de capture).

## 0.33.2 — 2026-11-06

### Ajouté
- Serveur RustDesk : bouton « Sauvegarder maintenant » dans le bandeau « Aucune sauvegarde
  récente de la clé et de la base », sans avoir à descendre jusqu’au panneau « Clé publique et
  sauvegarde » ; un échec s’affiche sous le bouton.

## 0.33.1 — 2026-11-06

Serveur RustDesk, actions (note 88). Chaque action demande une confirmation qui dit ce qui va se
passer ; la commande exacte se copie (sans secret) ; mot de passe sudo au Trousseau seulement.

### Ajouté
- **« Déconnecter… »** sur chaque session relayée en cours (aussi au clic droit) : la connexion
  de ce poste est fermée sur le serveur (`ss -K`), puis NetScope vérifie qu’elle a disparu ;
  sinon il le dit et propose, à part, de redémarrer hbbr (coupe toutes les sessions). Le poste
  peut se reconnecter aussitôt.
- **Panneau « Actions sur le serveur »** :
  - mettre à jour RustDesk : sessions signalées, compose relu, clé et base sauvegardées sur le
    serveur, image actuelle étiquetée, `docker compose pull` et `up -d`, puis versions, ports et
    clé vérifiés ; retour à l’image précédente si RustDesk ne repart pas ;
  - mettre à jour le système (apt ou dnf) : sécurité seulement ou tout, redémarrage permis ou non ;
  - historique des actions, synchronisé entre les Mac.
- **Mise à jour planifiée** : jour, heure, RustDesk, système ou les deux, sécurité seulement ou
  tout, redémarrage permis ou non, report si une session est en cours (nouvel essai toutes les
  15 min pendant 3 h) ; faite par l’agent d’un seul Mac choisi, même app fermée ; alerte en cas
  d’échec, d’abandon ou d’échéance manquée. Avertissement si l’agent n’est pas actif.

### Limites connues
- Rien n’a été essayé sur un vrai serveur : `ss -K` (selon le noyau), `docker compose` par sudo,
  sauvegarde dans `/var/backups` (jamais effacée automatiquement).
- « Sécurité seulement » avec apt demande unattended-upgrades sur le serveur.
- macOS peut demander l’accès au Trousseau pour l’agent ; sans lui, la mise à jour planifiée
  échoue et l’échec est noté.

## 0.33.0 — 2026-11-06

Serveur RustDesk, en lecture seulement (note 87) : rien n’est modifié sur le serveur.

### Ajouté
- **Accès distant › Serveur RustDesk** :
  - mises à jour à vérifier : version de RustDesk (image Docker comparée à Docker Hub, ou
    GitHub), mises à jour du système (apt ou dnf, correctifs de sécurité, redémarrage requis),
    nouvelle version du client ; au clic ou une fois par jour ;
  - santé : durée de fonctionnement, charge, processeur, mémoire, redémarrages de hbbs et hbbr ;
  - clé publique copiable, alerte si elle change (« C’est voulu » pour l’accepter) ;
  - « Sauvegarder la clé et la base » : copie chiffrée sur ce Mac, alerte sans copie de moins
    de 7 jours ;
  - historique des demandes gardé jour après jour, rapport mensuel par poste et par technicien
    (CSV, PDF) ;
  - tentatives suspectes : rafale depuis une même IP, ID hors carnet, refus de la FortiGate ;
  - colonne « Site probable » (WAN d’une FortiGate connue, indice seulement) ;
  - journaux de hbbs et hbbr avec recherche et filtre par ID ;
  - clic droit : se connecter, ajouter au carnet, ouvrir ou associer la fiche, nom et note,
    nommer le technicien, copier l’ID.
- **Nom et note sur chaque ID RustDesk**, synchronisés entre les Mac et affichés aussi dans
  l’assistance et le carnet.
- **ID associé à la MAC d’un poste**, proposé d’après le dernier scan ou les sessions de la
  FortiGate du site, confirmé à la main ; jamais par l’IP seule, seulement dans le site ouvert.
- **Sonde « Serveur RustDesk »** dans Surveillance (aussi par l’agent) : hbbs ou hbbr arrêté,
  disque plein, clé changée ; ports surveillés au choix.
- Réglages › RustDesk : mot de passe sudo (Trousseau seulement).

### Limites connues
- Rien n’a été essayé sur un vrai serveur : versions, journaux, lecture de la clé dans le volume
  Docker, sauvegarde (base copiée pendant que hbbs tourne).
- Les sondes de ports partent de ce Mac : elles ne prouvent pas qu’un port est joignable
  d’Internet.

## 0.31.0 — 2026-11-05

Les trois priorités réunies : sauvegarde des configurations de la FortiGate et des switchs, scans
planifiés et agent qui continue l’app fermée, et IPv6.

### Ajouté
- **Switchs et ports › Configurations** (note 40) : sauvegarde en lecture seule de la FortiGate
  (API REST, jeton du site) et des switchs par SSH (Cisco IOS, HPE Aruba, FortiSwitch, MikroTik ;
  liste fermée de commandes de lecture). Historique par équipement dans le dossier du site,
  nombre de versions gardées réglable, comparaison avant/après avec les secrets masqués, bandeau
  quand une configuration a changé. « Sauvegarder maintenant » ou « Sauvegarder le site ».
- **Scans planifiés par site** (note 63, Réglages › Surveillance) : jours, heure et profil ; ils
  alimentent Historique et adressage, l’alerte « nouvel appareil » et les rapports planifiés.
  Heure d’été gérée, échéance manquée pendant la veille rattrapée une fois, journal des exécutions.
- **Agent sans fenêtre** (note 64), désactivé par défaut : sondes de Surveillance, réception
  Syslog et scans planifiés continuent quand l’app est fermée ; l’app reprend la main dès
  qu’elle s’ouvre. macOS demande de l’autoriser à la première activation.
- **IPv6** : voisins IPv6 lus dans la table NDP, adresses IPv6 dans la fiche Appareil et une
  colonne IPv6 (masquable) dans le Scanner, ping et traceroute IPv6, calculateur IPv6 (préfixe,
  plage, découpage, formes courte et complète, EUI-64), état IPv6 de ce Mac dans la barre latérale.

### Modifié
- Boîte à outils : la section « Favoris » est retirée de la colonne de droite.

### Limites connues
- Rien n’a été essayé sur de vrais équipements : sortie SSH réelle de chaque marque, réponse de
  FortiOS au GET de sauvegarde (certaines versions exigent super_admin), agent après une veille,
  accès de l’agent aux secrets du Trousseau pour les alertes.
- L’alerte « configuration changée » reste dans l’app (pas encore par courriel ou téléphone), et
  les sauvegardes ne sont pas encore planifiées.

## 0.30.1 — 2026-11-05

Deux raccourcis demandés : fermer la fiche d’un appareil d’un clic, et voir les ressources d’un
poste directement depuis la Boîte à outils.

### Ajouté
- **Appareil › Fermer la fiche** (barre d’outils et menu Appareil, ⇧⌘W) : revient à « Ouvrir une
  fiche », comme si aucun appareil n’était choisi, le curseur dans le champ. Retour rouvre la
  fiche ; une saisie à la main n’est pas effacée.
- **Outils › Diagnostic › Ressources d’un poste** : tapez l’IP, le nom ou la MAC d’un poste du
  site actif (mêmes suggestions qu’« Ouvrir une fiche ») pour voir tout de suite son processeur,
  sa mémoire, ses disques et son trafic par SNMP, sans passer par sa fiche. Identifiants SNMP du
  site affichés, « Ouvrir la fiche complète », derniers postes consultés.

### Corrigé
- « Consultés récemment » ne double plus une fiche visitée avant qu’un site soit choisi.

### Limites connues
- Pas encore essayé sur un vrai poste SNMP ; un poste tapé à la main est interrogé aussitôt,
  même s’il n’a pas répondu en SNMP au scan.

## 0.30.0 — 2026-11-05

NetScope reconnaît mieux ce qui tourne sur chaque appareil (système, produit et version, sans
Nmap), sonde les ports UDP avec de vraies requêtes de chaque protocole, vérifie les certificats
TLS de tout un site, et lit les contrôleurs UniFi, Omada et Meraki pour les clients qui ne sont
pas en Fortinet.

Cette version comprend aussi la **0.29.0** (section suivante), publiée avec elle : toutes vos
données NetScope suivent d’un Mac à l’autre (synchronisation complète, Réglages ›
Synchronisation). Dans « Ouvrir une fiche », seuls les appareils du site actif sont proposés,
et les Réglages et la Boîte à outils sont en ordre alphabétique.

### Ajouté
- **Empreinte légère des appareils** : système, produit et version déduits des bannières (SSH,
  FTP, SMTP, Telnet, VNC), des en-têtes HTTP et du titre de page, du certificat TLS, du dialecte
  SMB, du sysDescr SNMP et du TTL, avec une confiance (faible, moyenne ou forte) et les indices
  qui la justifient.
- **Fiche Appareil, carte « Système et versions »** dans l’Aperçu (système, confiance, type
  indiqué, versions annoncées, services en clair, indices) et colonne « Produit et version »
  dans Ports et services.
- **Scanner** : colonnes facultatives « Système » et « Versions » (menu Colonnes) et ligne
  « Système » dans le panneau de détail.
- **Rapport Sécurité** : tableau « Versions visibles et services en clair » (Telnet, FTP, HTTP,
  SMB1, versions annoncées).
- **Scan de ports UDP ciblé** : chaque port reçoit une vraie requête de son protocole (DNS 53,
  TFTP 69, NTP 123, NetBIOS 137, SNMP 161, IPMI 623, SSDP 1900, SIP 5060, mDNS 5353) au lieu
  d’un paquet vide. Les états sont ouvert, ouvert|filtré, fermé (refus ICMP) ou filtré.
- **Fiche Appareil, section « Services UDP »** dans Ports et services (version DNS, strate NTP,
  sysDescr SNMP, User-Agent SIP, capacités IPMI, services mDNS…), avec export CSV ; le clic droit
  sur « Scanner les ports » lance l’UDP ciblé.
- **Scanner, « Scanner les ports › UDP ciblé… »** : une feuille avec les résultats de l’appareil
  choisi. Dans la Boîte à outils, l’outil Scan de ports propose « TCP » ou « UDP ciblé », avec la
  commande équivalente et l’historique des résultats.
- **Constats de sécurité UDP** : SNMP « public » ouvert, IPMI exposé ou anonyme, SIP exposé, NTP
  mode 6 (ntpq) et mode 7 (monlist, amplification), SNMP v2c en clair, TFTP joignable.
- **Outil « Certificat TLS »** dans la Boîte à outils : chaîne complète envoyée par le serveur,
  noms couverts (SAN), dates de validité et jours restants, clé (algorithme et taille),
  signature, empreintes SHA-256 et verdict de confiance de macOS avec sa raison.
- **Versions TLS acceptées** (TLS 1.0 à 1.3, chacune tentée seule) et suite négociée ; TLS 1.0
  et 1.1 encore acceptés sont signalés comme obsolètes.
- **Serveurs de courriel en STARTTLS** (SMTP 25 et 587, IMAP 143, POP3 110), en plus de HTTPS,
  8443, SMTPS, IMAPS, POP3S et LDAPS ; nom SNI au choix.
- **Problèmes signalés clairement** : nom qui ne correspond pas, certificat auto-signé, expiré ou
  qui expire bientôt (seuil réglable de 7 à 90 jours), chaîne incomplète, clé ou signature
  faible.
- **« Vérifier tous les HTTPS du site »** : d’un clic, tous les appareils du dernier scan avec
  443 ou 8443 ouvert sont vérifiés ; les certificats expirés ou bientôt expirés sont listés en
  premier.
- **Surveillance, sonde « Certificat TLS (jours restants) »** : une alerte avant l’expiration et
  une panne une fois le certificat expiré.
- **Réglages › Sites › Contrôleur** : ajouter le contrôleur UniFi Network, TP-Link Omada ou Cisco
  Meraki d’un site, en lecture seule. Le secret (clé d’API, mot de passe ou client secret) est
  gardé au Trousseau, le certificat est accepté par son empreinte, et un bouton « Tester »
  vérifie l’accès.
- **Switchs et ports** montre les switchs gérés par UniFi, Omada ou Meraki (« via UniFi »,
  « via Omada », « via Meraki ») : façade, ports, PoE, VLAN, voisins et appareils branchés, avec
  un bandeau du contrôleur et le bouton « Relire ».
- **Wi-Fi** gagne une partie pour le contrôleur du site : bornes (canaux, clients, utilisation,
  switch et port où elles sont branchées) et clients Wi-Fi (SSID, borne, bande, signal).
- **Scanner** : switch et port des appareils filaires lus par ces contrôleurs, et borne des
  clients Wi-Fi.
- **Démonstration** : empreintes, réponses UDP, certificats et contrôleurs fictifs, sans aucun
  envoi réel sur le réseau.

### Modifié
- **Scan de ports, case « Détection de services »** : lit aussi le certificat TLS des ports
  chiffrés et fait la négociation SMB2 sur le port 445 (dialecte, signature exigée, Samba), sans
  session ni authentification ; produit et version s’affichent dans le tableau.
- **Type d’appareil plus juste** quand l’empreinte est sûre (certificat Fortinet, en-tête
  d’imprimante, sysDescr…), sans jamais remplacer un type choisi à la main ni ce que dit la
  découverte SNMP.
- **Communauté SNMP au choix** pour le scan UDP : celle du site (gardée au Trousseau),
  « public » seulement si vous la choisissez, ou aucune (découverte SNMP v3 sans secret). Les
  tests NTP des modes 6 et 7 se désactivent dans le menu « Sondes ».
- **Sondes lancées seulement sur clic** : les adresses des plages exclues du site actif ne sont
  jamais sondées.

### Corrigé
- **Itinérance Wi-Fi** des clients vus par un contrôleur UniFi, Omada ou Meraki : elle ne lève
  plus d’alerte de port.
- **Sécurité** : aucune action sur les ports (coupure ou cycle PoE) n’est proposée pour un switch
  géré par UniFi, Omada ou Meraki ; NetScope lit ces contrôleurs sans jamais rien modifier.

### Limites connues
- L’empreinte est légère : elle ne lit que ce que les services annoncent d’eux-mêmes. Ce n’est
  pas une détection de système façon Nmap, et il n’y a aucune base de vulnérabilités (CVE) : une
  version affichée n’est pas jugée vulnérable ou non. Un service qui masque sa bannière reste
  « inconnu », et le TTL ne donne qu’un indice faible.
- En UDP, l’absence de réponse ne prouve rien : « ouvert|filtré » veut dire qu’on ne sait pas.
  Seuls les ports listés reçoivent une requête propre à leur protocole ; ce n’est pas un balayage
  UDP complet.
- Le verdict de confiance du certificat est celui de macOS sur ce Mac : une autorité interne non
  installée dans le Trousseau rend une chaîne « non approuvée ».
- Les contrôleurs UniFi, Omada et Meraki sont lus en lecture seule ; les données dépendent de la
  version du contrôleur et des droits du compte ou de la clé. Meraki passe par l’API infonuagique
  (accès Internet requis).
- Testé sur des données de démonstration et des réponses recopiées seulement ; essais réels à
  faire : imprimantes, NAS, pare-feu et serveurs variés pour l’empreinte, vrais services UDP
  (SNMP, NTP, SIP, IPMI), certificats de serveurs Web et de courriel, et vrais contrôleurs UniFi,
  Omada et Meraki.

## 0.29.0 — 2026-11-05 (publiée avec la 0.30.0)

Toutes vos données NetScope suivent maintenant d’un Mac à l’autre : sites, inventaires, Accès
distant, Surveillance, alertes, réglages et identifiants, avec les secrets chiffrés et remis au
Trousseau de chaque Mac.

### Ajouté
- **Synchronisation complète entre vos Mac** : sites, inventaires et derniers résultats, carnet
  d’Accès distant et tunnels, RustDesk, identifiants, sondes et rapports planifiés de la
  Surveillance, canaux d’alerte, saisies à la main, relevés Wi-Fi, historique Speedtest,
  réglages, raccourcis et profils de scan.
- **Tout est synchronisé par défaut**, par catégories qu’on peut décocher. Ce qui est propre à
  chaque Mac (interface active, fenêtres, captures, journal, base des fabricants, historiques
  bruts volumineux, état des mises à jour) ne l’est jamais.
- **Secrets protégés** : les mots de passe et jetons (FortiGate, SNMP, SSH, Telnet, VNC, FTP,
  SMB, RustDesk, SMTP, ntfy, Pushover…) sont chiffrés par le mot de passe de synchronisation et
  remis au Trousseau de chaque Mac ; ils ne sont jamais écrits en clair dans le dossier partagé.
- **Nouvelle section Réglages › Synchronisation** : Mac synchronisés avec leur version et leur
  dernière synchro, catégories avec compteurs, changements reçus récents, conflits avec
  « Rétablir l’autre version » et suppressions venues d’un autre Mac à confirmer.
- **Dossier au choix** : iCloud Drive par défaut, ou OneDrive, un NAS monté ou un dossier
  partagé.

### Modifié
- Les changements reçus s’appliquent sans redémarrer, quelques secondes après une modification
  sur un autre Mac ; seul un type de donnée que ce Mac ne sait pas relire à chaud attend
  « Redémarrer et appliquer ».
- Chaque Mac écrit son propre fichier, signé par le mot de passe de synchronisation ; la fusion
  se fait élément par élément et un fichier non signé ou altéré est refusé et signalé.
- Les rapports planifiés sont produits et envoyés par un seul Mac, indiqué sur les autres.
- La synchronisation iCloud Drive de la 0.18.0 est reprise telle quelle : les sites déjà
  synchronisés le restent, sans rien refaire.

### Corrigé
- Un Mac resté sur une version plus ancienne est signalé et n’efface jamais ce que sa version ne
  connaît pas.
- Un dossier choisi absent (partage non monté) n’est jamais recréé en local : NetScope demande
  de monter le partage.

### Limites connues
- Pas de serveur : la synchronisation passe par un dossier partagé et dépend de lui (iCloud
  Drive, OneDrive ou le NAS doivent avoir copié le fichier avant que l’autre Mac le voie).
- Sans mot de passe de synchronisation, un dossier autre qu’iCloud Drive n’échange ni Accès
  distant, ni alertes, ni identifiants, ni Surveillance, ni FortiGate ; l’écran le dit.
- Oublier le mot de passe de synchronisation rend les secrets déjà partagés illisibles sur les
  autres Mac : il faut les ressaisir.
- Les suppressions faites sur un autre Mac sont à confirmer, et les éléments supprimés sont
  oubliés après 180 jours.
- Testée sur des données de démonstration seulement : essai réel à faire entre deux Mac (et
  plus) avec iCloud Drive, puis un NAS.

## 0.28.0 — 2026-11-05

La carte du réseau s’exporte enfin en livrable pour le client (PNG, PDF, SVG, draw.io) et entre
dans les rapports ; l’écran Trafic reçoit les flux NetFlow, sFlow et IPFIX de toute marque ; la
fiche d’un appareil liste ses partages SMB ; et les alertes peuvent arriver sur téléphone par
ntfy ou Pushover.

### Ajouté
- **Carte du réseau, menu « Exporter »** : la carte entière (pas seulement la partie visible)
  en image PNG haute résolution, en PDF vectoriel, en dessin SVG ou en diagramme draw.io
  modifiable. L’export suit le site, le filtre VLAN, la recherche et les calques affichés, et
  rappelle ces choix et la date sous le titre ; il est toujours en clair, prêt à remettre au
  client ou à imprimer.
- **Carte en draw.io** : les appareils gardent leur place sur la carte et leurs couleurs par
  type, et les liens restent attachés aux appareils quand on les déplace.
- **Rapports, section « Carte du réseau »** (facultative) : image de la carte du site, sa
  légende et la liste des liens entre switchs, passerelle et points d’accès (ports, vitesse,
  source, liens redondants), en PDF, HTML et DOCX, et aussi dans les rapports planifiés.
- **Partages SMB d’un hôte** : la fiche Appareil (onglet Ports et services) liste les partages
  d’un NAS ou d’un poste Windows quand le port 445 est ouvert, et le menu contextuel du Scanner
  gagne « Partages SMB… ». La lecture passe par `smbutil`, fourni avec macOS, et ne se lance que
  sur un clic : en invité, puis en anonyme, ou avec un utilisateur (`DOMAINE\utilisateur`
  accepté). Le mot de passe n’apparaît jamais dans la commande ni dans le journal ; il est gardé
  au Trousseau seulement si vous le demandez.
- **Tableau des partages** (tableau standard : nom, type Disque, Imprimante ou IPC, commentaire,
  chemin). Les partages cachés (C$, ADMIN$, IPC$…) s’affichent sur demande. « Ouvrir dans le
  Finder » (macOS demande lui-même l’identifiant), copie du chemin smb:// ou Windows, copie en
  CSV. Messages clairs quand la lecture échoue : accès invité refusé, accès refusé, hôte en SMB1
  seulement, port 445 fermé, hôte injoignable ou introuvable, délai dépassé.
- **Trafic, source « Flux (NetFlow, sFlow, IPFIX) »** : NetScope reçoit les flux des routeurs,
  pare-feu et switchs de toute marque et répond à « Qui sature le lien ? » même sans FortiGate.
  Collecteur intégré sur les ports UDP 2055 (NetFlow v5 et v9), 4739 (IPFIX) et 6343 (sFlow v5),
  démarré seulement sur clic, ports modifiables, avertissement si le coupe-feu de macOS bloque
  l’écoute.
- **Trafic par flux** : sources (reliées à la fiche de l’appareil et au port de switch),
  destinations, applications (BitTorrent, Tor et le minage sont signalés), interfaces avec la
  charge du lien, conversations et exportateurs vus (paquets reçus et rejetés, gabarits,
  échantillonnage), sur 1 min, 5 min, 1 h ou 24 h, par exportateur ou tous. Nom de chaque
  exportateur, interface vers Internet et débits du forfait réglables, pour la charge du lien et
  « Qui sature le lien ? ».
- **Guide de configuration des flux** avec les commandes à copier vers ce Mac pour FortiGate,
  FortiSwitch, Cisco (NetFlow v9 et IPFIX), HP/Aruba, MikroTik et Ubiquiti.
- **Alertes sur téléphone par ntfy et Pushover**, à côté du courriel et des webhooks Teams,
  Slack et JSON, dans Réglages › Alertes. Les deux canaux sont désactivés par défaut.
- **ntfy** : ntfy.sh ou votre propre serveur en https, sujet (le bouton dé en génère un difficile
  à deviner), étiquettes, émoji de gravité, priorité selon la gravité (de minimale à urgente) et
  jeton d’accès facultatif gardé au Trousseau macOS.
- **Pushover** : jeton d’application et clé utilisateur gardés au Trousseau, son, appareil
  facultatif, priorité selon la gravité, jusqu’à l’urgence qui sonne toutes les 60 s jusqu’à
  l’accusé de réception.
- **Bouton « Envoyer un test »** avec confirmation pour ntfy et Pushover. Le journal des envois
  affiche leurs réussites et leurs erreurs expliquées (accès refusé, trop de messages, clé
  invalide…), sans jamais montrer un jeton ni une clé.
- **Démonstration** : exports de la carte, partages SMB (NAS Synology, postes Windows), trois
  exportateurs de flux dans trois formats et canaux ntfy et Pushover fictifs, sans aucun envoi ni
  aucune écoute réels.

### Modifié
- **Filtre propre à chaque canal de téléphone**, appliqué après les règles communes des alertes
  (types, gravité, heures de silence, anti-rafale) : toutes les gravités, alerte et critique, ou
  critique seulement, et tous les sites ou seulement certains. Un rétablissement ne part que si
  la panne qu’il clôt était passée par ce filtre.
- **Écran Trafic** : le choix de la source (FortiView ou Flux) masque les messages propres à
  FortiView en mode Flux ; tableaux exportables en CSV et « Ajouter au rapport ».
- **Trafic › Flux › Exportateurs** : « Rejetés » et « Gabarits » sont des colonnes
  facultatives, pour que « Dernier reçu » tienne sans être coupé.

### Corrigé
- **Carte du réseau** : le lien vers un groupe d’appareils en conflit d’adresse IP est dessiné
  sous les autres ; la descente partagée reste grise et seul son dernier tronçon est rouge, au
  lieu de teinter toute la descente du switch.

### Limites connues
- Les flux restent en mémoire sur ce Mac, 24 h au plus, en mémoire bornée ; rien n’est écrit sur
  disque : quitter NetScope efface l’historique des flux. Les flux ne
  sont reçus que lorsque l’app est ouverte et le collecteur démarré.
- Les débits par flux dépendent de l’échantillonnage annoncé par l’exportateur (sFlow surtout) :
  ce sont des estimations, pas des compteurs exacts.
- Partages SMB : un hôte qui n’accepte que SMB1 ne peut pas être lu par `smbutil` sur les
  versions récentes de macOS ; NetScope le signale sans pouvoir lister ses partages.
- ntfy et Pushover passent par Internet : sans accès Internet depuis le Mac, l’alerte ne part
  pas (l’erreur est notée au journal des envois).
- Testé sur des données de démonstration et des sorties recopiées seulement ; essais réels à
  faire : export de la carte ouvert dans draw.io et Illustrator, NAS et postes Windows, vrais
  exportateurs NetFlow, sFlow et IPFIX (FortiGate, Cisco, Aruba, MikroTik), et envois réels vers
  ntfy et Pushover.

## 0.27.3 — 2026-11-05

L’assistance RustDesk quitte la page « Sessions » d’Accès distant pour son propre onglet,
« Assistance RustDesk », à côté de « Serveur RustDesk », avec l’historique complet des sessions
dans un tableau.

### Ajouté
- **Onglet « Assistance RustDesk »** (Accès distant) : entre « Sessions » et « Serveur
  RustDesk », toujours présent. Sa pastille compte les sessions lancées aujourd’hui (elle se
  remet à zéro à minuit, même si l’app reste ouverte).
- **Aider un usager en trois étapes** : grand champ pour l’ID RustDesk de l’usager (espaces
  acceptés ; une adresse IPv4 ouvre l’accès IP direct), ajout au carnet avec le nom du poste et
  l’usager, marche à suivre en trois étapes et copie du lien d’assistance à envoyer à l’usager.
- **Historique complet des sessions** dans un tableau standard : recherche par poste, ID (même
  dicté par groupes, « 263 418 ») ou usager, tri et colonnes réglables ; reconnexion en un clic
  ou par double-clic, ajout au carnet d’un poste qui n’y est pas encore (puce « Hors carnet ») et
  copie de l’ID.
- **Accès direct à l’assistance** depuis Réglages › RustDesk (« Ouvrir l’assistance »), le menu
  Aller, le panneau d’un poste RustDesk (« Toutes les sessions ») et, par clic droit sur
  « Connecter par RustDesk », depuis la fiche d’un appareil ou de l’inventaire, avec l’ID déjà
  saisi.

### Modifié
- **Page « Sessions » allégée** : le bloc d’assistance RustDesk et la liste des derniers
  lancements passent dans le nouvel onglet.
- **Barre d’onglets en petite fenêtre** : sous une largeur étroite, les onglets fixes
  deviennent « Assistance » et « Serveur » (nom complet en bulle d’aide), pour ne plus chevaucher
  la liste des connexions.
- **Ajout au carnet d’un ID déjà connu** : le nom automatique et l’usager vide du poste sont
  complétés par la saisie ; sinon, un message dit ce qui n’a pas été repris.

### Corrigé
- **Touche Retour** : elle ne lance plus « Connecter » depuis la recherche ou le tableau de
  l’historique, seulement depuis le champ de l’ID.
- **Recherche par chiffres** : une adresse IP se compare telle quelle (« 1821 » ne trouve plus
  10.182.122.177), et un numéro trouve aussi un nom de poste (« 11 » trouve LAVAL-POSTE-11).

Limites : RustDesk ne prévient pas NetScope de la fin d’une session ; l’historique note
seulement l’heure de lancement (une session refusée ou qui a échoué y figure aussi), est gardé
sur ce Mac seulement et se limite aux 300 derniers lancements. Le client RustDesk doit être
installé sur ce Mac. Vérifié sur les données de démonstration ; l’essai réel sur le serveur de
Groupe Couture reste à faire.

## 0.27.2 — 2026-11-05

Correctif de l’Accès distant : le panneau de détails reste dans sa colonne et ne cache plus la
session, et NetScope ne se ferme plus en enregistrant une connexion ou un tunnel.

### Ajouté
- **Nom de dossier en bulle d’aide** : dans le panneau de détails, un nom de dossier abrégé
  s’affiche en entier au survol.

### Modifié
- **Panneau de détails, nom de dossier** : un nom de dossier long passe sous la pastille d’état
  de la connexion, sur toute la largeur du panneau, abrégé au milieu seulement s’il ne tient pas.
- **« Ouvrir une connexion enregistrée »** : les cases sont un peu plus larges, pour que le nom et
  l’adresse s’affichent sans être coupés.

### Corrigé
- **Accès distant, panneau de détails** : avec un nom de dossier long (« St-Georges GM /
  St-Georges Toyota »), le panneau débordait de sa colonne, recouvrait la session (bouton
  « Connecter », assistance RustDesk, tunnels) et sortait de la fenêtre. Il reste maintenant dans
  sa colonne à droite, même en très grande fenêtre, et son bouton de repli reste visible. Limite :
  un contenu exceptionnellement large est coupé au bord de la colonne plutôt que de la déborder.
- **Accès distant, enregistrement** : NetScope ne se ferme plus en enregistrant une connexion ou
  un tunnel SSH (rapports de plantage des 3, 4 et 5 novembre). Vérifié sur les données de
  démonstration ; l’essai sur de vraies connexions reste à faire.

## 0.27.1 — 2026-11-05

Moins de fausses alertes pour le Wi-Fi : un appareil qui passe d’une borne FortiAP à une autre
n’est plus signalé comme « déplacé sur un autre port », et la carte d’occupation distingue
d’un coup d’œil les appareils Wi-Fi, les appareils filaires et les adresses DHCP.

### Ajouté
- **Itinérance Wi-Fi dans l’historique** : quand un appareil Wi-Fi change de borne, son
  historique note « passé de la borne AP-ETG2 à la borne AP-ACCUEIL », sans alerte.
- **Carte d’occupation (Analyse)** : les appareils filaires restent en vert, les appareils Wi-Fi
  passent en cyan avec un symbole Wi-Fi. Un triangle dans le coin signale une adresse attribuée
  par bail DHCP de la FortiGate, un point une réservation ; une adresse fixe n’a pas de repère.
  Une légende est ajoutée sous la carte.
- **Adresse choisie et infobulles de la carte** : l’accès est indiqué (filaire avec son port, ou
  Wi-Fi avec la borne, le SSID et la bande), ainsi que l’attribution de l’adresse (bail DHCP,
  réservation ou fixe).

### Modifié
- **Reconnaissance des appareils Wi-Fi** : NetScope s’appuie sur plusieurs indices : client vu
  par la FortiGate, port de switch d’une borne (fiche ou voisin LLDP), port « Wi-Fi », interface
  Wi-Fi de ce Mac, téléphone mobile ou adresse MAC privée. Une borne qui change de port reste
  signalée.
- **Alertes à traiter** : les anciens changements de port d’appareils Wi-Fi ne comptent plus dans
  la pastille de la barre latérale ni dans la tuile ; le tableau les marque d’un symbole Wi-Fi.

### Corrigé
- **Historique et adressage, Surveillance** : un appareil Wi-Fi qui passe d’une borne FortiAP à
  une autre ne déclenche plus l’alerte « Appareil déplacé sur un autre port ». Un appareil
  filaire qui change de port garde son alerte.

### Limites connues
- La reconnaissance du Wi-Fi repose sur des indices : un appareil Wi-Fi que la FortiGate ne voit
  pas, derrière une borne non reconnue (sans LLDP ni fiche) et avec une adresse MAC fixe, peut
  encore être pris pour un appareil filaire et déclencher l’alerte. À l’inverse, un téléphone ou
  un appareil à MAC privée branché par câble est classé Wi-Fi.
- Les repères DHCP (bail, réservation) viennent des baux de la FortiGate : sans FortiGate
  configurée pour le site, aucune adresse n’est marquée DHCP.
- Testé sur des données de démonstration seulement ; essai réel à faire avec de vraies bornes
  FortiAP et une vraie FortiGate.

## 0.27.0 — 2026-11-05

Surveillance de longue durée et pages plus faciles à parcourir : Switchs et ports et Wi-Fi ›
FortiAP passent en onglets, la Surveillance garde 90 jours d’historique avec fenêtres de
maintenance et rapport de disponibilité, et de nombreux outils gagnent ce qui leur manquait
(meilleur canal Wi-Fi, plages exclues, Speedtest planifié, liens LLDP sur la Carte, Syslog en
TCP, décodeurs de la Capture de paquets, serveur iperf3, XMODEM en console série).

### Ajouté
- **Switchs et ports en onglets** : Switchs, Ports, Trafic, Appareils, et Voisins et liens,
  sous le bandeau du site. On trouve l’information sans faire défiler une longue page.
  - Six tuiles de résumé en haut (switchs en ligne, ports actifs, ports en erreur, PoE utilisé,
    appareils et VLAN, voisins LLDP) ; un clic ouvre l’onglet qui les détaille, déjà filtré.
  - **Ports** : nouveau tableau de tous les ports, le même pour les switchs SNMP et les
    FortiSwitch, avec les filtres Tous, Actifs, Inactifs, PoE, Uplinks et Erreurs, les erreurs
    récentes, et le détail et les actions du port à côté.
  - **Appareils** : la table MAC s’accompagne des appareils par VLAN ; un clic sur un VLAN
    filtre la table.
  - **Voisins et liens** : nouveau tableau des voisins LLDP de tous les switchs du site, avec la
    nature du lien (entre switchs, FortiLink, routeur, borne, téléphone), à côté de la
    topologie et de « Ce Mac est branché sur… ».
  - Un clic sur un port de la façade l’ouvre dans l’onglet Ports ; Retour (⌘[) ramène à
    l’onglet d’avant ; depuis une fiche Appareil, un port s’ouvre directement dans l’onglet
    Ports ; l’onglet choisi est retenu.
- **Wi-Fi › FortiAP en onglets** : Bornes, Clients, SSID, Canaux, Voisins et Conseils, avec le
  nombre d’éléments de chaque onglet ; le bandeau de la FortiGate et les tuiles restent en haut,
  et l’onglet choisi est retenu.
  - Un clic sur une borne (carte des canaux, conseils, colonne Borne des clients) ouvre
    l’onglet Bornes sur elle ; un clic sur une tuile ouvre l’onglet correspondant ; la fiche
    d’un appareil ouvre directement le bon onglet.
  - L’onglet SSID montre les clients et les bornes de chaque SSID, avec un lien vers ses
    clients.
- **Wi-Fi (ce Mac)** :
  - Nouveau panneau « Meilleur canal », avec le canal conseillé en 2,4, 5 et 6 GHz ; il
    signale les canaux DFS et PSC, propose un choix hors DFS ou plus étroit, et dit si le canal
    actuel convient.
  - Relevé par pièce enregistré par site : signal, bruit, débit du lien, latence de la
    passerelle et débit réel en option, mesurés à la demande ; tableau avec qualité et
    constats, et export CSV.
  - Historique du signal jusqu’à une heure (2, 10, 30 min ou 1 h), avec minimum, maximum,
    changements de borne et temps passé sous −70 dBm.
- **Sites et plages › Plages exclues** : par site, des adresses, intervalles ou sous-réseaux,
  avec une note, jamais sondés par le scan, la relecture automatique, le Scan de ports ni le
  Ping continu d’une plage ; une exclusion qui couvre toute une plage est signalée.
  - Scanner : « N adresses exclues » à côté des plages cochées, avec la raison en infobulle ;
    le total d’adresses à scanner tient compte des exclusions.
  - Inventaire : un appareil d’une plage exclue garde sa fiche, marquée « Exclu du scan », et
    n’est jamais déclaré disparu.
  - Plages exclues copiées avec le site : export, import et synchronisation de la
    configuration, « Dupliquer », colonne « exclusions » du CSV des sites.
- **Base des fabricants** : option « Mettre à jour automatiquement » dans Réglages › Base des
  fabricants, activée par défaut. NetScope vérifie le registre IEEE au plus une fois par mois
  quand la base a plus de 30 jours, jamais pendant un scan ni sur une connexion limitée
  (partage de connexion du téléphone, données réduites), et garde l’ancienne base en cas
  d’échec.
  - Date de la base, dernière vérification, préfixes ajoutés et prochaine vérification
    affichés ; notification discrète « Base des fabricants mise à jour : +N préfixes ».
- **Speedtest › Planifié** : un test de débit Internet par jour et par site, à l’heure choisie,
  avec seuils d’alerte en descente et en montée.
  - Le test est reporté pendant un scan, pendant un autre test ou sur une connexion limitée,
    puis rattrapé dans la journée ; sous le seuil, une notification « Débit Internet sous le
    seuil » ouvre l’onglet Planifié.
  - Courbe du débit planifié par site sur 30 jours, avec moyennes, minimum, jours sous le seuil
    et tableau de tous les sites.
- **Historique et adressage** : carte d’occupation de /24 à /16, parcourue par pages de /24,
  avec baux, réservations et étendues DHCP de la FortiGate et plages exclues.
  - « Prochaine IP libre hors étendue DHCP » pour chaque sous-réseau du site et pour chaque
    page de la carte, à copier ou à vérifier par ping.
- **Surveillance** :
  - Heures ouvrables propres à chaque site (jour par jour) ; le site d’une sonde se choisit
    dans l’éditeur ou se déduit de sa cible.
  - Fenêtres de maintenance planifiées (une fois, chaque jour, semaine ou mois, avec date de
    fin) pour tous les sites, un site ou des sondes précises. Les sondes continuent de tourner,
    les alertes sont suspendues et notées au journal, et ces vérifications sont écartées de la
    disponibilité.
  - Rappel d’une alerte non accusée après 15 min à 4 h (désactivé par défaut), au plus 3 fois,
    par notification et par les canaux des Alertes.
  - Graphe de latence de la sonde choisie sur 24 h ou 7 jours (moyenne, minimum–maximum,
    échecs, maintenance, seuil), et disponibilité des 30 derniers jours ; historique gardé
    jusqu’à 90 jours.
- **Rapports** :
  - Nouvelle section « Disponibilité (Surveillance) » : une case par jour pour chaque sonde,
    les pannes, la durée hors ligne et la latence moyenne.
  - Export DOCX (Word, Pages, LibreOffice), écrit sans dépendance.
  - Rapports planifiés : envoi automatique par le serveur SMTP des Alertes, à choisir pour
    chaque rapport (désactivé par défaut), avec des destinataires par site et un bouton
    « Envoyer un essai… ».
- **Carte du réseau** :
  - Les liens entre switchs sont tracés d’après les voisins LLDP relus par SNMP et la FortiGate
    (uplinks, ISL, FortiLink), avec le port de chaque bout ; les FortiSwitch hors des plages
    scannées apparaissent à leur place, et les liens redondants sont dessinés en tirets.
  - Filtre par VLAN : seuls les appareils du VLAN choisi restent, et les équipements qui ne le
    portent pas sont atténués.
  - Glissez un nœud pour le placer ; sa position est retenue pour chaque site, avec « Remettre
    à sa place » et « Réinitialiser la disposition ».
  - Le détail d’un switch liste ses liens LLDP (port, voisin, port distant, vitesse, VLAN).
- **Journaux** :
  - Réception Syslog aussi en TCP (RFC 6587), sur le même port 5514 que l’UDP, avec les deux
    cadrages (par longueur, mode « reliable » de FortiOS, et par saut de ligne), le nombre de
    messages reçus en TCP et les connexions ouvertes.
  - Transfert facultatif des messages reçus vers un autre serveur Syslog (SIEM, serveur du
    client), en UDP ou en TCP, avec gravité minimale, traps facultatives et compteurs des
    messages relayés ou perdus. Désactivé par défaut.
  - Guide de configuration par marque (FortiGate, FortiSwitch, Cisco, HP/Aruba AOS-S et AOS-CX,
    Ubiquiti UniFi et EdgeOS, Linux) : commandes à copier en UDP ou en TCP, commande de
    vérification et conseils.
- **Capture de paquets** :
  - Décodage SIP (avec SDP), RTP, RTCP, SNMP (communauté masquée, variables nommées), Syslog,
    RADIUS (mots de passe masqués) et NTP dans le détail par couche, avec de nouveaux filtres
    (sip.method, rtp.ssrc, radius.code, syslog.level…) et des filtres rapides « Téléphonie »,
    « Supervision » et « Authentification ».
  - Nouvel onglet « Constats » : retransmissions TCP, fenêtre nulle, connexions refusées ou
    coupées, requêtes sans réponse, échecs (nom inexistant, accès RADIUS refusé, erreurs SIP),
    perte et gigue de la voix (RTP) et horloge décalée ; latence par flux (TCP, DNS, HTTP, SNMP,
    RADIUS, NTP, SIP) ; « Voir les paquets » montre les paquets concernés.
  - Bouton « Ouvrir dans Wireshark » : la capture est écrite en .pcap et ouverte directement
    dans Wireshark s’il est installé.
- **iperf3** :
  - Serveur iperf3 intégré (vue « Serveur de ce Mac ») : un autre appareil mesure son débit
    vers ce Mac sans rien installer ; démarré sur un clic, port 5201, arrêt automatique après un
    délai sans test, un test à la fois, TCP dans les deux sens.
  - Moteur « Intégré » pour mesurer vers un autre Mac NetScope ou un serveur iperf3 sans
    installer iperf3, avec le débit seconde par seconde en direct.
- **Vitesse des disques** : les serveurs FTP, FTPS et SFTP s’ajoutent comme emplacements ; le
  fichier d’essai est envoyé puis reçu, sans montage, mot de passe au Trousseau (clés de
  ~/.ssh en SFTP), serveur nettoyé à la fin.
- **Accès distant › Console série** : bouton « Fichier… » pour envoyer ou recevoir des
  fichiers en XMODEM, XMODEM-CRC, XMODEM-1K et YMODEM (mises à jour de firmware par la
  console), avec avancement, temps restant, reprises et annulation.
- Démonstration : données réalistes pour toutes ces nouveautés (onglets des switchs et des
  bornes, relevé Wi-Fi, carte d’occupation, Speedtest planifié, disponibilité, constats de
  capture, serveur iperf3, transfert XMODEM).

### Modifié
- **Surveillance** : les heures ouvrables fixes (lun.–ven. 7 h – 18 h) sont remplacées par
  celles de chaque site.
- **Speedtest** : chaque test retient le site actif (colonne « Site » dans l’historique et
  l’export CSV) ; la courbe de l’Historique et la comparaison au forfait ne portent plus que
  sur le site actif.
- **Switchs et ports** : l’ancien tableau des ports d’un FortiSwitch est remplacé par le
  tableau commun de l’onglet Ports ; tous les panneaux d’avant sont toujours là, dans un
  onglet.

### Corrigé
- Les envois FTP de plusieurs mégaoctets pouvaient échouer en fin de transfert (« 426
  Transfert interrompu »).
- Speedtest : en petite fenêtre, la barre d’onglets passe sur deux lignes au lieu d’élargir la
  page.
- Console série : en petite fenêtre, les boutons passent sur une deuxième ligne au lieu de
  déborder.

### Limites connues
- Toutes ces nouveautés sont vérifiées sans réseau (tests du moteur et données de
  démonstration) : les essais sur de vrais switchs (LLDP d’autres marques, gros switchs
  empilés), de vraies bornes FortiAP, un vrai serveur SMTP et de vraies consoles série restent
  à faire.
- Le Speedtest planifié, les rapports envoyés par SMTP, les rappels d’alerte et la mise à jour
  automatique de la base des fabricants ne tournent que pendant que NetScope est ouvert ; un
  test manqué est rattrapé à l’ouverture suivante dans la journée (agent en arrière-plan prévu
  pour la 0.28.0).
- Le moteur iperf3 « Intégré » et le serveur de ce Mac ne font que du TCP ; l’UDP et le
  bidirectionnel demandent le moteur iperf3 installé.
- « Ouvrir dans Wireshark » demande que Wireshark soit installé ; sinon, enregistrez la
  capture en .pcap. Les décodeurs ne déchiffrent rien (SNMP v3, TLS) ; HTTP et SIP sont lus
  segment par segment, sans réassemblage ; une communauté SNMP v1 ou v2c reste lisible dans
  l’hexadécimal, puisqu’elle passe en clair sur le réseau.
- Syslog en TCP n’est pas chiffré (pas de TLS) ; le port reste 5514, à indiquer aux
  équipements.
- Le meilleur canal Wi-Fi ne voit que les réseaux captés par ce Mac à l’endroit où il se trouve ;
  ce n’est pas une planification Wi-Fi.
- L’export de la carte du réseau reste pour la 0.24.0 (note 61).

## 0.26.2 — 2026-11-05

Tableau de bord de votre serveur RustDesk, lu par SSH en lecture seule : sessions relayées,
demandes de connexion, postes enregistrés, état de hbbs et hbbr, et espace disque. L’écran
Appareil ouvre une fiche par IP, nom ou MAC, et un appareil absent du Scanner se saisit à la
main. Les clients Wi-Fi des FortiGate en FortiOS 7.4.13 s’affichent de nouveau.

### Ajouté
- **Accès distant › Serveur RustDesk** : nouvel onglet, un tableau de bord de votre serveur
  RustDesk Server OSS lu par SSH en lecture seule.
  - Sessions relayées en cours et débit ; demandes de connexion des dernières 24 h, avec le nom
    du poste quand son ID est dans le carnet ; nombre de postes enregistrés ; hbbs et hbbr en
    marche et depuis quand ; espace disque.
  - Tableaux standard des sessions relayées (durée, volume, débits actuel, moyen et max) et des
    demandes de connexion (heure locale, IP du technicien, ID visé, IP du poste, « relais »).
  - Graphe des six dernières heures, mesuré par ce Mac.
  - Boutons « Actualiser » et « Copier la commande » (la commande ssh équivalente, sans aucun
    secret).
- **Réglages › RustDesk** : choix du compte SSH du serveur (une connexion SSH du carnet, ou
  utilisateur@hôte avec un mot de passe facultatif gardé au Trousseau), rafraîchissement de
  15 s à 5 min (30 s par défaut) et bouton « Ouvrir le tableau de bord ».
- Démonstration : serveur RustDesk avec sessions, demandes et graphe réalistes.
- **Appareil › Ouvrir une fiche** : sans appareil choisi, l’écran propose un champ où taper une
  adresse IP, un nom ou une adresse MAC (deux-points, tirets, points Cisco ou sans
  séparateur). Les suggestions viennent en direct du Scanner, de l’Inventaire et des saisies
  du site actif ; ↑ ↓ choisissent, Entrée ouvre la fiche.
  - Les fiches consultées récemment sont listées sous le champ, avec leur état.
  - Une fiche d’inventaire ou un appareil d’un autre site absent du Scanner s’ouvre aussi.
- **Appareil › Saisir un appareil à la main** : IP, nom, MAC (avec son fabricant), type et
  notes, pour un appareil que le Scanner n’a pas vu. Un nom DNS n’est résolu que sur clic
  « Résoudre ».
  - La fiche porte la mention « Saisi à la main · pas encore vu par un scan ». « Vérifier
    maintenant » envoie un seul ping ; les outils de la fiche (ping continu, ports, web, SSH,
    fichiers, TFTP, Wake-on-LAN) travaillent sur son adresse, seulement sur clic.
  - « Ajouter à l’inventaire » ouvre la feuille d’ajout déjà remplie ; « Oublier cette
    saisie » la retire.
  - Quand un scan du même site voit ensuite la même MAC (ou la même IP), la saisie est
    rattachée à l’appareil trouvé, avec son nom, son type et ses notes.
  - Les saisies restent à part des résultats du Scanner et sont rangées par site.

### Modifié
- Sécurité : NetScope n’envoie au serveur que des commandes de lecture, d’une liste blanche
  testée, sans jamais utiliser sudo ; les commandes qui modifieraient hbbs ou hbbr (listes
  noires, débits, effacement des demandes…) sont refusées.
- Le tableau de bord ne se rafraîchit que lorsqu’il est affiché : aucune connexion SSH en
  arrière-plan.

### Corrigé
- **Wi-Fi › FortiAP : 0 client sur certaines FortiGate** (constaté à St-Georges Ford, FortiOS
  7.4.13). FortiOS glisse des données invalides (restes de mémoire) dans un champ de la liste des
  clients, ce qui faisait rejeter toute la réponse. NetScope la répare maintenant avant de la lire,
  pour toutes les lectures de la FortiGate, et le diagnostic indique les réponses réparées.
- **Wi-Fi › FortiAP : plus de 0 sans explication.** Une réponse illisible, un droit refusé ou des
  clients annoncés par les bornes mais absents de la liste sont signalés dans le bandeau et
  comptés en alerte dans « Conseils ».
- Messages clairs, avec la marche à suivre, quand le serveur est injoignable par SSH, quand la
  console de hbbr ne répond pas, quand hbbs est trop ancien pour lister les demandes ou quand le
  disque est presque plein, au lieu d’un tableau vide.

### Limites connues
- Seules les sessions **relayées** par hbbr sont visibles : une session en connexion directe
  entre le technicien et le poste ne passe pas par le serveur et n’apparaît pas.
- La liste des demandes dépend de la console de hbbs : un hbbs trop ancien ne la donne pas
  (le tableau de bord le dit).
- Le graphe est mesuré par ce Mac pendant que le tableau de bord est affiché : il a des trous
  quand l’écran est fermé, et il n’est pas partagé avec un autre Mac.
- Les conteneurs Docker ne sont lus que si le compte SSH est déjà dans le groupe docker, et le
  nombre de postes seulement si sqlite3 est installé et la base lisible (jamais de sudo).
- Essayé seulement sur des données de démonstration ; un essai sur le vrai serveur reste à
  faire.

## 0.26.1 — 2026-11-05

Assistance à distance par RustDesk avec votre propre serveur : carnet des postes, connexion en
un clic, réglages et vérifications du serveur, et ports RustDesk reconnus dans les scans.

### Ajouté
- **Accès distant : protocole RustDesk** (assistance à distance). Carnet des postes avec l’ID
  groupé « 123 456 789 », l’usager, le site et des notes ; « Connecter » ouvre le client
  RustDesk de ce Mac, avec un mot de passe permanent facultatif gardé au Trousseau.
  - **Assistance RustDesk** : collez l’ID donné par l’usager (espaces acceptés) pour vous
    connecter tout de suite, avec ou sans ajout au carnet. Les derniers lancements se relancent
    d’un clic.
  - « Copier l’ID » et « Copier le lien d’assistance pour l’usager » (message prêt à coller
    avec la page du client portable) ; lien « Télécharger RustDesk » si le client n’est pas
    installé sur ce Mac.
- **Réglages › RustDesk** : serveur d’ID, relais, clé publique et page d’assistance.
  - Import depuis le nom du client portable (`rustdesk-host=…,key=…,.exe`) ; ce nom est aussi
    reconstruit à partir des réglages, prêt à copier.
  - « Vérifier le client RustDesk de ce Mac » compare son serveur et sa clé aux réglages et dit
    quoi corriger.
  - « Tester le serveur », sur demande seulement : ports TCP 21115 à 21117 avec leur temps de
    réponse, échange RustDesk réel sur 21115 et sur UDP 21116.
  - « Vérifier les VIP » de la FortiGate, en lecture seule : repère un port manquant ou un VIP
    qui pointe sur l’adresse publique au lieu du serveur interne.
- **Inventaire et fiche Appareil** : champ « ID RustDesk » et « Connecter par RustDesk » d’un
  clic.
- **Ports ouverts** : les ports de RustDesk (21115 à 21119, et 21116 en UDP) sont nommés dans
  le Scanner, la fiche Appareil et le scan de ports.
  - Clic sur le port 21118 d’un poste : « Ouvrir dans RustDesk » ; sur les ports d’un serveur :
    rôle de chaque port et « Tester le serveur RustDesk » (connexions TCP, seulement sur clic).
  - Nouveau préréglage « Accès distant et RustDesk » (SSH, Telnet, RDP, VNC et 21115 à 21119)
    dans « Scanner les ports › … » et dans l’outil Scan de ports.
- **Reconnaissance des serveurs RustDesk** (type « Serveur RustDesk », rôle et constat dans la
  fiche) et des postes à accès IP direct, sans changer un type choisi à la main.
- Démonstration : serveur srv-assistance et Poste direction avec RustDesk.

### Modifié
- Chaque scan vérifie maintenant aussi les ports 21116 (serveur RustDesk) et 21118 (accès IP
  direct). La liste du profil Personnalisé n’est mise à jour que si vous ne l’aviez pas
  modifiée.
- Rapports : l’accès IP direct RustDesk est signalé comme un accès distant ; les ports d’un
  serveur RustDesk ne sont plus traités comme inconnus.
- Switchs : les erreurs des ports s’affichent en puce « 1 port en erreur » au bout de la ligne
  du nom (« ⚠ 1 » dans une carte étroite) au lieu d’une pastille sur l’icône.

### Corrigé
- Petite fenêtre : boutons de Réglages › RustDesk, de l’Inventaire et « Scanner les ports » du
  Scanner qui étaient tronqués.

### Limites connues
- NetScope ne remplace pas le client RustDesk : la session s’ouvre dans l’app RustDesk de ce
  Mac, qui doit être installée et réglée sur le même serveur.
- L’historique note seulement l’heure de lancement : RustDesk ne dit pas à NetScope quand la
  session se termine, donc pas de durée.
- Le mot de passe permanent sort du Trousseau au moment de « Connecter » : il est remis au
  client RustDesk dans le lien de connexion.
- Le test du serveur et la vérification des VIP n’ont été essayés que sur des données de
  démonstration ; ils attendent un essai sur le vrai serveur et la vraie FortiGate.

## 0.26.0 — 2026-11-05

Nouveau Bilan de raccordement en un clic avec mode avant/après, vrai Test MTU du chemin,
Ping continu en TCP et HTTP(S) jusqu’à 64 cibles, éléments des balises Wi-Fi, tunnels SSH et
saut par bastion dans Accès distant.

### Ajouté
- **Bilan de raccordement** (Boîte à outils) : en un clic sur la prise où le Mac est branché,
  NetScope vérifie le lien (vitesse, duplex), le switch et le port (LLDP/CDP), le VLAN, le PoE
  annoncé, le DHCP (sans prendre de bail), la passerelle (perte, latence), le DNS et l’accès
  Internet. Chaque étape est OK, en avertissement ou en échec, avec une explication en clair.
  - **Avant/après** : un bilan peut être retenu comme « avant » ; les bilans suivants lui sont
    comparés et les écarts (vitesse, port, VLAN, serveurs DHCP, pertes, temps de réponse) sont
    surlignés.
  - **VLAN attendu** facultatif : un port brassé dans le mauvais VLAN est signalé en échec ; un
    serveur DHCP hors de la liste des serveurs autorisés du Test DHCP aussi.
  - Historique des bilans par site, export PDF d’un bilan et nouvelle section facultative
    « Bilan de raccordement » dans les rapports.
- **Test MTU réel** : la Boîte à outils mesure le MTU du chemin vers une cible (pings « ne pas
  fragmenter » de taille variable, par dichotomie) et affiche « MTU du chemin = N octets
  vers X ».
  - Diagnostic probable du chemin (PPPoE, tunnel IPsec, GRE, WireGuard, VXLAN, DS-Lite, trames
    jumbo), MSS TCP conseillé, MTU de l’interface de ce Mac, et alerte quand un pare-feu jette
    les paquets trop grands sans prévenir (trou noir ICMP).
  - Étapes de la recherche détaillées, historique des mesures (un MTU qui a changé est
    signalé), nouvelle mesure en double-cliquant une ligne, export CSV ; option pour tester les
    trames jumbo jusqu’à 9000 octets.
- **Ping continu en TCP et HTTP(S)**, pour suivre les caméras, serveurs et sites qui bloquent
  le ping : le mode TCP mesure le temps de connexion à un port, le mode HTTP(S) le temps de
  réponse d’une page avec son code HTTP. Mêmes cartes, graphes, journal et export CSV.
  « hôte:port », « tcp://… » et « https://… » s’ajoutent directement dans le champ ; la carte
  d’une cible web détaille le temps DNS, TCP, TLS et l’attente du serveur.
- **Traceroute (MTR) en ICMP, UDP ou TCP** vers un port (proposé automatiquement pour les
  cibles TCP et web), pour suivre un chemin qui filtre l’ICMP.
- **Ping continu, tableau compact** : au-delà de 9 cibles, l’écran passe tout seul à un tableau
  (état, dernière mesure, courbe, perte, seuil) ; un bouton Auto / Cartes / Tableau impose l’un
  ou l’autre. On peut suivre jusqu’à 64 cibles.
- **Ping continu** : seuil de lenteur réglable pour chaque cible (clic droit sur la carte ou
  colonne « Seuil » du tableau) ; notification macOS quand une cible ne répond plus et quand
  elle revient (menu Session et Réglages › Notifications) ; session (cibles et réglages)
  enregistrée dans un fichier et rouverte, la dernière d’un clic depuis l’écran vide.
- **« Rapport pour le fournisseur Internet »** en PDF (Ping continu › Exporter) : perte,
  latence et gigue heure par heure, périodes de panne, disponibilité et constats en phrases
  simples.
- **Éléments des balises Wi-Fi** (Wi-Fi, ce Mac) : pour chaque BSSID, génération Wi-Fi (4, 5,
  6, 6E, 7), largeur annoncée jusqu’à 320 MHz, flux spatiaux, itinérance 802.11k/v/r, charge
  de la borne (clients associés, utilisation du canal en %), sécurité détaillée (WPA2,
  WPA3-SAE, OWE, PMF obligatoire ou facultative).
  - Nom de la borne quand l’élément propriétaire le donne (Cisco, Aruba, Fortinet, avec modèle
    et numéro de série pour Fortinet), sinon nom WPS des routeurs et imprimantes.
  - Nouvelles colonnes cachables (Génération, 11k/v/r, Charge, Clients, Nom de la borne, PMF)
    et panneau « Balise du BSSID » pour le réseau sélectionné.
  - Nouvelles recommandations : itinérance sans 802.11k/v/r ou incomplète (borne fautive
    nommée), borne saturée (plus de 70 % d’utilisation ou plus de 40 clients), WPA2 seul alors
    que WPA3 est possible, WPA2-Entreprise sans PMF.
- **Tunnels SSH** dans le carnet d’Accès distant : redirection locale (-L) et proxy SOCKS5
  (-D) par une connexion SSH, chacun dans son onglet de session (démarrer, arrêter, état,
  journal de ssh), avec un port local libre choisi automatiquement sur 127.0.0.1. RDP, VNC
  (session intégrée) ou le navigateur web s’ouvrent à travers un tunnel ouvert ; son adresse
  locale se copie.
- **Saut par bastion** (ProxyJump, -J) choisi parmi les connexions SSH du carnet ; il sert au
  terminal intégré, aux tunnels et à « Ouvrir dans Terminal ».
- **Import de `~/.ssh/config`** (Host, HostName, User, Port, ProxyJump, IdentityFile) dans le
  carnet, en lecture seule ; les clés ne sont jamais copiées.
- **Console série** : option « Horodater » qui ajoute l’heure à la milliseconde devant chaque
  ligne reçue, aussi dans le journal de session.
- **Inventaire** : export CSV pour NetBox, GLPI et Snipe-IT (menu Exporter), avec les noms de
  colonnes de leurs imports.
- **Wake-on-LAN** : réveil de plusieurs postes d’un coup (⌘-clic dans le tableau), broadcast
  dirigé automatique vers le sous-réseau d’un poste distant, et suivi par ping qui affiche
  « réveillé en N s ».

### Modifié
- **Wi-Fi** : le filtre « Signalés » inclut les bornes saturées ; l’export CSV ajoute la
  génération, 11k/v/r, l’utilisation du canal, les clients, la PMF et le nom de la borne.
- **Accès distant** : le nom d’utilisateur est aussi demandé et retenu pour RDP, et proposé
  pour SFTP (nom retenu, sinon le compte SSH de l’appareil).
- **Inventaire** : les appareils à adresse MAC aléatoire (adresse privée) sont rapprochés de
  leur ancienne fiche par le nom d’hôte ou le numéro de série et proposés dans « Doublons
  probables », jamais fusionnés sans votre accord.
- **Alertes** : une licence qui expire, un firmware à mettre à jour, un message Syslog grave et
  un WAN en panne ont maintenant leur propre type d’alerte et de notification, chacun
  activable à part, au lieu d’un « sonde en panne » général.

### Corrigé
- **Accès distant** : le mot de passe SSH enregistré au Trousseau est maintenant fourni même
  quand le nom d’utilisateur vient de `~/.ssh/config` ; une connexion dont le nom est dans ce
  fichier ne le demande plus.
- **Wi-Fi** : sans autorisation de localisation, macOS masque aussi les éléments des balises ;
  NetScope l’explique et propose de l’autoriser au lieu d’afficher des colonnes vides.

### Limites connues
- Tout ce qui précède est vérifié sur des données de démonstration ; les essais sur de vrais
  switchs, bornes, bastions et liens restent à faire.
- Le Bilan de raccordement dépend de ce que le switch annonce : sans LLDP ni CDP sur le port,
  le switch, le port, le VLAN et le PoE restent inconnus (avertissement, pas échec). Le PoE est
  celui que le switch annonce, pas une mesure électrique. La vitesse de connexion à Internet
  n’est pas mesurée par le bilan (Speedtest à part).
- Le Test MTU suppose que la cible répond au ping : si l’ICMP est filtré en route, NetScope ne
  peut que signaler un trou noir probable, sans valeur exacte.
- Le mode HTTP(S) du Ping continu mesure une requête complète, plus lourde qu’un ping : garder
  un intervalle raisonnable sur les serveurs des autres.
- Les éléments des balises Wi-Fi ne sont lus que pour les réseaux vus par ce Mac et exigent
  l’autorisation de localisation ; la charge (QBSS) n’est connue que si la borne l’annonce.
- Les tunnels SSH et le saut par bastion passent par `/usr/bin/ssh` : l’authentification par
  clé suit la configuration SSH du Mac.
- Le broadcast dirigé du Wake-on-LAN est souvent bloqué par les routeurs et les FortiGate
  (directed-broadcast désactivé par défaut).

## 0.25.0 — 2026-11-05

SNMP v3 partout et nouveau Navigateur SNMP, graphes du trafic de chaque port sur 30 jours, et
premières actions sur les ports (cycle PoE), désactivées par défaut et entourées de
garde-fous.

### Ajouté
- **SNMP v3 partout** : relevé des switchs, relecture automatique, Ressources de la fiche
  Appareil, sondes de la Surveillance, « Lire la fiche matériel » et découverte des switchs en
  fin de scan interrogent maintenant en SNMP v3 (noAuthNoPriv, authNoPriv, authPriv ; MD5,
  SHA-1 à SHA-512 ; DES, AES-128 à AES-256). La communauté v2c reste le repli.
- **Utilisateur SNMP v3 par site** (Réglages › Identifiants) : menu « S’applique à » ; les
  autres sites utilisent celui de tous les sites. Les mots de passe restent au Trousseau.
- **Navigateur SNMP** (Boîte à outils › Diagnostic) : GET, GETNEXT et parcours d’un OID en
  v2c ou v3, raccourcis vers les tables courantes (system, ifTable, ifXTable, ENTITY-MIB, LLDP,
  BRIDGE, Q-BRIDGE, PoE, HOST-RESOURCES), noms et valeurs lisibles, limite de lignes, arrêt,
  copie et export CSV.
- **Graphe du trafic de chaque port** (Switchs et ports) : 1 h, 24 h, 7 jours ou 30 jours,
  avec débits maximal et moyen, pourcentage de la vitesse du lien et erreurs par heure
  (valeurs au survol).
- **Historique du trafic des ports**, gardé par site sur ce Mac : 24 h à la résolution du
  relevé, 7 jours par tranches de 5 min, puis à l’heure jusqu’à 90 jours. Les compteurs
  32 bits qui bouclent et les compteurs remis à zéro sont gérés.
- **Trafic sans FortiView** : sans FortiGate prête (ou sans le droit FortiView), l’écran
  Trafic montre le trafic relevé sur les switchs (SNMP et FortiSwitch) : port le plus chargé,
  ports chargés, ports en erreur et tableau des ports les plus chargés.
- **Actions sur les ports** (note 73) : « Couper et rallumer le PoE » d’un port, pour
  redémarrer à distance un téléphone IP, une borne ou une caméra figés, depuis le détail du
  port (Switchs et ports) et depuis la fiche de l’appareil.
  - FortiSwitch géré par une FortiGate : cycle PoE et « Redémarrer le port » par l’API REST
    de la FortiGate. Le jeton doit avoir « WiFi & Switch Controller » en lecture-écriture ; un
    jeton en lecture seule est signalé clairement.
  - Autres switchs : cycle PoE par SNMP en écriture (v2c ou v3), durée de coupure réglable
    (5 s par défaut), avec des identifiants d’écriture dédiés, distincts de ceux de lecture et
    gardés au Trousseau.
  - Garde-fous : actions désactivées par défaut (Réglages › Switchs › Actions sur les ports) ;
    confirmation obligatoire qui nomme le switch, le port, l’appareil et son IP ; uplinks et
    port de ce Mac refusés par défaut ; le PoE est rallumé jusqu’à trois fois si la remise
    échoue.
  - Après l’action, NetScope suit le retour de l’appareil (« revenu en 52 s ») et note l’action
    au journal de l’app et dans la chronologie de l’appareil dans l’inventaire.

### Modifié
- **Fiche matériel en SNMP v3** : le châssis est trouvé par un vrai parcours d’ENTITY-MIB,
  comme en v2c, au lieu d’index devinés.
- **Réglages › Switchs** : la colonne SNMP indique l’utilisateur v3 utilisé pour chaque
  switch, et si la communauté sert de repli.
- **« Ports les plus chargés »** (Switchs et ports) : passe d’« En direct » à une période
  (1 h à 30 j) dans un tableau standard, aussi pour les FortiSwitch gérés par la FortiGate.
- **Bilan de santé** (ancienne « Analyse complète du réseau », note sur 100) : un port est
  signalé en erreur selon son rythme d’erreurs par heure, et non plus d’après le total
  accumulé depuis le démarrage du switch ; un port chargé à plus de 80 % en moyenne sur la
  dernière heure est signalé saturé. Le bilan est rappelé en tête de l’écran Historique et
  adressage, avec un lien vers son détail.
- **« Analyse » devient « Historique et adressage »**, pour ne plus le confondre avec le bilan
  de Trafic ; la recherche des Réglages le retrouve aussi par son ancien nom.
- **Boîte à outils** : un seul outil « Courriel » à onglets (Super outil, SMTP, en-têtes,
  santé, SPF/DKIM, MX, listes noires) remplace les sept outils séparés ; les anciens liens
  ouvrent le bon onglet.
- **Speedtest** : le moteur Ookla est masqué par défaut (licence pour un usage personnel et
  non commercial) ; il se réactive dans Serveurs › Sources, et un choix Ookla déjà fait est
  gardé.
- **État des services** : TikTok, Snapchat, Facebook, Instagram et Grok ne sont plus suivis
  par défaut ; une case les réactive dans « Modifier la liste ».
- **Barre latérale** un peu plus large, pour afficher les noms d’écran en entier.

### Corrigé
- **Fiche Appareil › Ressources** : l’en-tête indique la version SNMP vraiment utilisée
  (v3 avec le nom de l’utilisateur, ou v2c) au lieu de toujours « SNMP v2c ».
- **Fiche Appareil** : un nom contenant « œ » (« Switch cœur ») n’est plus coupé en bas.

### Limites connues
- **Vérifié en démonstration seulement** : SNMP v3, Navigateur SNMP, graphes des ports et
  actions sur les ports n’ont pas encore été essayés sur de vrais switchs, FortiSwitch ni
  FortiGate.
- **Les actions sur les ports modifient l’équipement** : c’est la première exception à la
  lecture seule de NetScope. Le cycle PoE coupe l’alimentation de l’appareil branché ; à
  essayer d’abord sur un port sans risque. Le cycle PoE par SNMP dépend de la prise en charge
  de POWER-ETHERNET-MIB en écriture par le switch, et « Redémarrer le port » n’existe que pour
  les FortiSwitch gérés par la FortiGate.
- **Graphes des ports** : l’historique ne se remplit que pendant que NetScope est ouvert et
  relit les switchs ; il commence vide à l’installation et garde des trous quand l’app est
  fermée.
- La 0.24.0 (sauvegarde des configurations, note 40, et export de la carte, note 61) n’est pas
  encore faite : elle viendra plus tard.

## 0.23.1 — 2026-11-05

Les cartes des switchs signalent les ports dont les erreurs augmentent, et Réglages › Mises à
jour montre toutes les versions publiées avec le résumé de leurs notes.

### Ajouté
- **Ports en erreur sur la carte du switch** (Switchs et ports) : l'icône passe en rouge avec
  une pastille du nombre de ports touchés, et l'infobulle les liste (« port4 : +37 erreurs en
  10 min »). Seuls comptent les ports qui gagnent au moins 10 erreurs en entrée en
  30 minutes, uplinks compris, pour les switchs SNMP comme pour les FortiSwitch lus par la
  FortiGate ; un ancien problème réglé ne reste plus affiché.
- **Historique complet des versions** (Réglages › Mises à jour) : toutes les versions publiées,
  avec leur date, la date d'installation sur ce Mac et leur résumé ; un clic déroule les points
  par rubrique (Ajouté, Modifié, Corrigé, Limites connues). Filtre « Installées sur ce Mac ».
  Les notes sont livrées avec l'app : aucun réseau n'est nécessaire.

### Modifié
- **Façade du switch** : la couleur « Erreurs » des ports, le compteur « Erreurs » et le détail
  du port (« +N en X min », en plus du total) suivent la même règle des erreurs récentes.
- **Historique d'installation** : gardé jusqu'à 200 versions au lieu de 20.

### Limites connues
- Les erreurs récentes demandent au moins deux relevés : juste après l'ouverture de NetScope,
  l'infobulle indique « mesure en cours ». Le suivi n'est pas gardé d'un lancement à l'autre.
- Vérifié en démonstration seulement, pas encore sur ton réseau.

## 0.23.0 — 2026-11-05

Une version de fiabilité : NetScope tient maintenant un journal de ses erreurs, prépare un
diagnostic à joindre à un signalement, et remplit tout seul le modèle, le numéro de série et le
firmware des équipements de l'inventaire.

### Ajouté
- **Journal de NetScope** (Réglages › Journal et diagnostic) : les erreurs et avertissements de
  chaque module (FortiGate, SNMP, alertes par courriel et webhooks, mises à jour, sauvegarde,
  synchronisation, scan…) sont gardés avec leur date et leur module ; filtres par niveau et par
  module, recherche, « Copier » et « Effacer le journal ».
- **Secrets masqués** : jetons, mots de passe, communautés SNMP, clés d'API et en-têtes
  d'autorisation sont masqués avant d'être écrits. Le journal est conservé dans
  `~/Library/Logs/NetScope` (3 fichiers de 1 Mo au plus, les plus anciens sont remplacés).
- **« Exporter un diagnostic… »** : une archive .zip à joindre à un signalement, avec le
  journal, les versions de NetScope et de macOS, le modèle du Mac, les interfaces actives, les
  sites et plages, les réglages et les rapports de plantage des 30 derniers jours. Aucun
  identifiant ni secret n'y figure.
- **Après une fermeture inattendue**, une bannière discrète le signale au lancement suivant,
  avec « Exporter un diagnostic » ou « Ignorer ».
- **Pastille sur Réglages** quand des erreurs récentes n'ont pas encore été consultées.
- **Fiche matériel remplie automatiquement** : le modèle, le numéro de série et la version du
  firmware des switchs, imprimantes, FortiGate, FortiSwitch et FortiAP sont lus par SNMP
  (ENTITY-MIB et sysDescr) ou par l'inventaire de la FortiGate, sans jamais écraser ce que vous
  avez saisi.
- **Bloc « Matériel détecté »** dans la fiche Inventaire, avec la source et la date de lecture ;
  « Reprendre » copie le numéro de série détecté quand aucun n'est saisi, et un numéro qui
  diffère de celui saisi est signalé.
- **« Lire la fiche matériel »** sur la fiche Inventaire et la fiche Appareil : lit un seul
  appareil, par SNMP v2c ou v3, ou par la FortiGate pour un appareil Fortinet (« Relire la fiche
  matériel » ensuite).

### Modifié
- **Fiche Appareil** : la carte Matériel affiche le modèle, le numéro de série, le firmware et
  leur source.
- **Inventaire** : colonnes « Modèle » et « Firmware » à cocher dans « Colonnes » ; l'export CSV
  gagne les colonnes Modèle, N° de série et Firmware, et la recherche trouve ces valeurs.
- **Rapports** : le modèle et la version des switchs viennent d'ENTITY-MIB quand l'équipement le
  prend en charge, sinon de sysDescr comme avant.

### Corrigé
- Aucun défaut de la 0.22.0 n'a été signalé : les essais réels sur une vraie FortiGate, un
  site et un scan, prévus pour cette version de fiabilité, n'ont pas encore eu lieu et leurs
  correctifs suivront. Une même erreur répétée en arrière-plan (synchronisation, mises à jour
  hors ligne) n'est notée qu'une fois au journal.

### Limites connues
- Pas encore essayé sur de vrais équipements : la lecture ENTITY-MIB, sysDescr et l'inventaire
  de la FortiGate sont vérifiés sur des données de démonstration seulement. Certains appareils
  (petits switchs, imprimantes) ne publient pas ENTITY-MIB ou n'y mettent pas de numéro de
  série : le bloc reste alors partiel.
- La fiche matériel ne se lit que si SNMP (ou le jeton de la FortiGate) est configuré pour le
  site ; rien n'est lu sur un appareil qui ne répond pas.
- Le journal ne garde que ce que NetScope écrit à partir de cette version ; les erreurs
  antérieures à la mise à jour n'y figurent pas.

## 0.22.0 — 2026-11-05

Les sessions à distance s'ouvrent maintenant dans NetScope : un terminal intégré pour SSH,
Telnet et la console série, et une session VNC intégrée, dans des onglets d'Accès distant.

### Ajouté
- **Terminal intégré** (Accès distant) : « Connecter » ouvre SSH, Telnet et la console série
  dans un onglet de NetScope (xterm-256color : couleurs, curseur, défilement de 10 000 lignes,
  copier-coller, recherche ⌘F, ⌘K pour effacer).
- **Onglets de session** : plusieurs sessions à la fois, état connecté ou déconnecté,
  « Reconnecter », confirmation avant de fermer une session active, et extraits de commandes
  selon l'appareil (Cisco, FortiGate, Aruba, Linux).
- **SSH intégré** : utilise le `ssh` de macOS (clés et `known_hosts` de `~/.ssh`) ; un serveur
  inconnu montre son empreinte et attend votre accord ; le mot de passe, facultatif, est rangé
  au Trousseau seulement, jamais sur le disque ni dans la ligne de commande.
- **Telnet intégré** : plus besoin d'installer `telnet` ; NetScope négocie lui-même l'écho, la
  taille de la fenêtre et le type de terminal. L'avertissement « non chiffré » reste affiché.
- **Console série intégrée** : choix du port `/dev/cu.*` avec l'adaptateur USB-série reconnu
  (FTDI, CP210x, CH340, Prolific), débit de 1200 à 921 600 bauds, bits, parité, bits d'arrêt,
  contrôle de flux, préréglage Cisco / Fortinet 9600 8N1 et bouton « Envoyer Break ».
- **Journal de session** : case « Journaliser la session » (texte brut dans
  `~/Library/Logs/NetScope`) et « Enregistrer le journal… » au format `.log` ; « Copier la
  sortie » copie tout l'historique.
- **Apparence du terminal** : Sombre, Claire ou Suivre le système, taille du texte réglable,
  Option comme touche Méta en option.
- **Session VNC intégrée** : « Connecter » ouvre les connexions VNC directement dans NetScope.
  Qualité « Adaptative » (moins de couleurs quand le lien ralentit) ou « Haute » (sans perte),
  mise à l'échelle « Ajuster » ou « 100 % » avec défilement aux bords, et plein écran.
- **Commandes de la session VNC** : bouton Ctrl-Alt-Suppr, mode « Observation seule »
  (regarder sans toucher), presse-papiers texte partagé et bouton « Envoyer le presse-papiers ».
  Le curseur affiché est celui de l'ordinateur distant.
- **Clavier et souris en VNC** : clavier, souris et molette transmis ; les raccourcis Commande
  vont à l'ordinateur distant, sauf Commande-Q et Ctrl-Commande-F.
- **Authentification VNC** : mot de passe VNC ou compte macOS demandé dans la session,
  mémorisable au Trousseau, jamais affiché ; le menu « … » permet d'oublier le mot de passe.

### Modifié
- **Accès distant** : le menu du bouton « Connecter » garde « Ouvrir dans Terminal » et
  « Partage d'écran » ; Partage d'écran est aussi proposé quand une session VNC échoue.
- **RDP** s'ouvre toujours dans Windows App ; l'aide explique pourquoi : le protocole est trop
  vaste pour être réécrit sans bibliothèque externe.

### Corrigé
- **Accès distant** : l'onglet de la session active reste toujours visible quand plusieurs
  sessions sont ouvertes.

### Limites connues
- Pas encore essayé sur de vrais équipements : SSH, Telnet et la console série (adaptateurs
  USB-série, câbles console), ni la session VNC sur de vrais serveurs (macOS, RealVNC,
  TightVNC, UltraVNC) ; certains serveurs ou encodages peu courants peuvent mal s'afficher.
- VNC : seul le texte passe par le presse-papiers partagé (pas d'images ni de fichiers), et la
  connexion n'est pas chiffrée par NetScope (passer par un VPN ou un tunnel SSH au besoin).
- RDP reste dans Windows App, qui doit être installée.

## 0.21.0 — 2026-11-04

Le parc Fortinet sous contrôle (firmware et licences), un écran « Journaux » qui reçoit le
Syslog et les traps SNMP, et un Ping continu qui met chaque cible en pause.

### Ajouté
- **Firmware et licences** (Boîte à outils, groupe Parc Fortinet) : versions FortiOS,
  FortiSwitch et FortiAP de chaque site, version disponible ou recommandée et état « à jour »,
  « mise à jour disponible » ou « inconnu », par site ou pour tous les sites (menu Site ▾).
- **Licences FortiGuard** (antivirus, IPS, filtrage web…) et contrats FortiCare avec leur date
  d'expiration et les jours restants : orange à 60 jours, rouge à 30 (seuils réglables).
- **Détail d'un équipement** : version installée et build, version disponible (Mature ou
  Feature), chemin de mise à jour publié par FortiOS, branche plus récente à planifier à part,
  et la marche à suivre sur la FortiGate. NetScope ne lance jamais de mise à jour : tout se lit
  par l'API en lecture seule.
- **Écran « Journaux »** (groupe Suivi) : messages Syslog et traps SNMP reçus par ce Mac, et
  journaux d'événements de la FortiGate, dans un même tableau. Recherche par heure, appareil,
  gravité et source (`appareil:`, `gravite:`, `source:`), messages répétés regroupés,
  double-clic vers la fiche de l'appareil, export CSV.
- **Récepteur Syslog** sur ce Mac (RFC 3164, RFC 5424, format FortiOS, Cisco, HPE Aruba) et
  **récepteur de traps SNMP** v1 et v2c (linkDown et linkUp avec le nom du port, coldStart,
  échec d'authentification, traps FortiGate courantes, informs acquittés).
- Réception démarrée seulement à la demande, avec arrêt automatique. Ports 5514 et 1162 par
  défaut, sans droits administrateur ; les commandes à copier sur la FortiGate, le FortiSwitch,
  Cisco ou HPE Aruba sont fournies, et le coupe-feu de macOS est signalé.
- **Journaux d'événements de la FortiGate** (système, VPN, utilisateurs, Wi-Fi) lus par l'API,
  en lecture seule, en mémoire ou sur disque.
- **« Comprendre une coupure »** : autour d'une heure choisie, les messages de tous les
  appareils mis en ordre, avec les constats (port qui tombe et remonte, redémarrage, accès
  refusé, tunnel tombé).
- **Surveillance** : nouvelles sondes « Licence bientôt expirée » (seuil en jours),
  « Firmware pas à jour », « Message Syslog de gravité ≥ X » et « Trap SNMP reçue ».
- **Ping continu** : chaque cible peut être mise en pause seule (bouton sur sa carte, dans la
  carte Terminal ou au clic droit) ; elle n'envoie plus rien, ses statistiques restent figées
  et sa carte affiche « En pause ». Le journal note la mise en pause et la reprise.

### Modifié
- **Rapports** : le drapeau « firmware à jour » des switchs est enfin rempli, les mises à jour
  disponibles et les licences proches de l'expiration deviennent des problèmes du rapport, et
  une section facultative « Firmware et licences » est ajoutée.
- **Diagnostic de la FortiGate** : les réponses brutes du firmware, des licences et des
  journaux y figurent (sans le jeton).
- **Journal gardé sur ce Mac**, borné à 50 000 messages ou 7 jours (réglable).
- **Ping continu** : l'écran s'ouvre vide, sans cibles ajoutées d'office ni ancien journal ;
  ajoutez vos cibles dans le champ, depuis le Scanner ou depuis la fiche d'un appareil.

### Corrigé
- **Ping continu** : le tableau MTR / Traceroute montre toutes ses colonnes, dont
  « Écart-type », dans une fenêtre normale ; quand il est trop large, il défile à gauche et à
  droite au lieu de couper des colonnes.
- **Ping continu** : l'export CSV ne compte plus de pertes pendant la pause d'une cible.

### Limites connues
- Pas encore essayé sur de vraies FortiGate : les champs du firmware, des licences et des
  journaux varient selon la version de FortiOS (6.4 à 7.6 prévues) ; le jeton doit avoir les
  droits de lecture voulus (sinon un message 403 l'explique).
- Les états « à jour » se comparent dans la même branche ; un équipement dont la version
  recommandée est introuvable reste « inconnu ».
- Les récepteurs n'écoutent que pendant que NetScope est ouvert et que la réception est
  démarrée ; les traps SNMP v3 ne sont pas encore décodées.

## 0.20.3 — 2026-11-04

L'onglet Ressources mesure l'activité des disques, et le réseau et les disques se lisent côte à côte.

### Modifié
- **Disques de ce Mac** : la jauge « Disque » et le panneau Disques montrent l'activité (lecture,
  écriture en Mo/s et part du temps occupé, comme le Moniteur d'activité) au lieu de l'espace
  libre. Un disque physique par ligne (SSD interne, disque externe), avec la courbe de lecture et
  d'écriture des 5 dernières minutes. Lecture locale des compteurs du système, sans trafic réseau.
- **Réseau par interface et Disques côte à côte**, de la même hauteur ; les disques passent
  dessous quand la fenêtre est étroite.

### Corrigé
- Les partages réseau montés n'apparaissent plus à « 100 % · 0 o libres » : la liste des volumes
  est remplacée par l'activité des disques physiques.

## 0.20.2 — 2026-11-04

Un Ping continu repensé avec Dany et un onglet Ressources plus lisible.

### Modifié
- **Ping continu** : un clic sur une carte la retourne et montre les dernières réponses de la
  cible comme dans Terminal (« 64 octets de 8.8.8.8 : seq=120 temps=16,0 ms », en orange au-delà
  du seuil, en rouge quand un paquet est perdu) ; un second clic la remet. Dessous, le
  traceroute (MTR) de la cible choisie et le journal des événements, côte à côte. Le grand
  graphe du bas est retiré : la courbe de chaque carte reste. Clic droit : « Copier les réponses ».
- **Ressources de la fiche Appareil** : quatre jauges rondes en haut (processeur, mémoire,
  disque de démarrage, réseau ; pour un appareil SNMP : processeur, mémoire, port le plus
  chargé), puis Processeur et Mémoire de la même hauteur, puis le réseau par interface. Les
  tuiles de résumé qui répétaient ces panneaux sont retirées.

### Ajouté
- **Disques de ce Mac** dans l'onglet Ressources : chaque volume monté (interne, externe,
  partage réseau déjà monté) avec la place utilisée et l'espace libre, lus localement.

## 0.20.1 — 2026-11-04

Une barre latérale plus simple : le site actif montre ses plages et un résumé, et Speedtest
rejoint la Boîte à outils.

### Modifié
- **Site sous le logo** : la carte du site actif montre maintenant ses plages (au plus trois,
  puis « +N plages ») et un résumé, par exemple « 21 appareils · 6 alertes ». Elle a le même
  style que la carte « Interface active » du bas.
- **Section « Sites » retirée** de la barre latérale : on change de site par la carte sous le
  logo (ou ⌘⇧S).
- **Speedtest et iperf3 dans la Boîte à outils** (groupe Performance) : ils s'ouvrent dans
  l'outil lui-même, sans écran à part ; Speedtest n'est plus dans le groupe Accès. Les anciens
  liens vers l'écran Speedtest ouvrent l'outil.
- **Petite fenêtre** : avec un outil pleine largeur (Speedtest, iperf3, capture de paquets…),
  la liste des outils devient un menu « Outil » pour laisser toute la place à l'outil.

## 0.20.0 — 2026-11-04

Les rapports de suivi et un Inventaire repensé : NetScope dit ce qui a changé depuis le dernier
rapport d’un site, produit des rapports à date fixe, et l’Inventaire devient un vrai registre
du parc, avec les appareils ajoutés à la main, l’archivage, les sites, les garanties et les
pièces jointes.

### Ajouté
- **Rapports, « Depuis le dernier rapport »** : nouvelle section qui compare l’état actuel au
  dernier rapport du même site, ou au dernier produit à une date choisie : appareils nouveaux,
  disparus et changés (IP, nom, type, port), problèmes réglés et nouveaux (Surveillance, ports
  en erreur, WAN, Wi-Fi, DHCP).
- Chaque rapport produit garde un instantané léger de son site ; liste des rapports passés par
  site, avec Ouvrir, Afficher dans le Finder, Comparer à ce rapport et Supprimer (le fichier va
  dans la Corbeille).
- **Rapports planifiés**, par site (un fichier par site) : chaque jour, chaque semaine tel jour
  ou chaque mois tel jour, à l’heure choisie, avec les sections, le format, le dossier et un
  nom de fichier daté.
- Notification « Rapport planifié produit » à la fin (Réglages › Notifications). L’option
  « Préparer le courriel » ouvre un brouillon dans Mail, pour relecture.
- **Inventaire, ajout à la main** d’un appareil absent des scans (imprimante hors réseau,
  matériel en stock) avec tous ses champs ; il est marqué « Ajouté à la main » et rapproché
  automatiquement de l’appareil que le scan du même site verra ensuite (même MAC, sinon même
  IP), sans perdre ce que vous avez saisi. On peut le modifier et le dupliquer.
- Option par site « Ajouter automatiquement les appareils scannés », activée par défaut.
  Désactivée, vous choisissez vous-même ce qui entre dans l’inventaire avec « Ajouter à
  l’inventaire » dans le Scanner (clic droit, aussi sur plusieurs appareils).
- Déplacer un ou plusieurs appareils vers un autre site (clic droit, « Déplacer vers un autre
  site ») : fiche, notes, garantie, historique et pièces jointes suivent l’appareil. Une même
  MAC vue sur deux sites est signalée.
- Fiche matériel : date d’achat, fin de garantie, fournisseur, numéro de série et prix
  facultatif, avec une alerte « garantie bientôt échue » (60 jours ou moins) dans la fiche et
  dans les alertes d’inventaire.
- Pièces jointes sur chaque fiche (factures, contrats, photos) : ajouter ou glisser des
  fichiers, les ouvrir, les retirer (vers la Corbeille).
- Étiquettes libres et nouveau menu « Filtrer » (par étiquette, garantie bientôt échue,
  appareils ajoutés à la main, MAC vue sur un autre site) ; nouvelles colonnes facultatives :
  fin de garantie, n° de série, fournisseur, pièces jointes, origine.
- Réglages › Sites et plages : nouvel encadré « Inventaire du site » pour l’ajout automatique,
  la liste « Ne plus réajouter » (retirer une entrée, ajouter une MAC) et le nombre d’appareils
  archivés.

### Modifié
- Inventaire : retirer un appareil propose maintenant **Archiver** (par défaut, restaurable
  depuis la nouvelle vue « Archivés ») ou **Supprimer définitivement**, avec la case « Ne plus
  réajouter cet appareil » ; le message qui suit a un bouton « Annuler ».
- Les inventaires de deux sites ne sont jamais fusionnés : un déplacement garde chaque site
  séparé.
- Les inventaires existants sont repris sans perte.

### Corrigé
- Rapports planifiés : un rapport n’est plus produit deux fois après une modification de sa
  planification ; un rapport qui n’a rien pu produire est indiqué « en échec ».
- Suivi : plus de faux « Réglé » ou « Nouveau » sur les problèmes d’un rapport à l’autre.
- Noms des rapports planifiés : la date n’est jamais coupée.
- Inventaire : « Dernière vue » vide et pastille « Non scanné » pour une fiche jamais scannée ;
  un appareil archivé n’est plus rapproché d’un ajout à la main ; « Modifier… » ne fige plus le
  type ni le fabricant venus du scan.
- Petite fenêtre : l’aperçu des Rapports ne défile plus horizontalement.

### Limites
- Les rapports planifiés ne sont produits que lorsque NetScope est ouvert ; une échéance
  manquée est rattrapée une seule fois au lancement suivant, sans rafale.
- Aucun scan n’est lancé pour un rapport planifié : il reprend le dernier scan du site et
  indique son âge.
- Rien n’est envoyé par courriel : « Préparer le courriel » ouvre seulement un brouillon dans
  Mail, à relire et envoyer vous-même.
- Le rapprochement d’un appareil ajouté à la main se fait seulement par MAC ou par IP, et
  seulement avec un scan du même site.
- Rien de tout cela n’a encore été essayé sur de vrais sites (rapports planifiés sur plusieurs
  jours, rapprochement des ajouts à la main par un vrai scan).

## 0.18.0 — 2026-11-04

Les transferts de fichiers et la configuration partagée : NetScope ouvre maintenant des
connexions FTP, FTPS et SFTP, sert ou récupère des fichiers en TFTP, mesure la vitesse d’un NAS
ou d’un partage, distingue un service bloqué par le pare-feu d’une vraie panne, et exporte,
importe ou synchronise sa configuration entre vos Mac.

### Ajouté
- **Accès distant, transferts de fichiers** : nouvelles connexions FTP (mode passif ou actif),
  FTPS (TLS explicite ou implicite) et SFTP (par SSH, avec un mot de passe, une clé ou les clés
  de `~/.ssh`).
- Navigateur de fichiers en deux volets, Ce Mac ↔ serveur : parcourir, glisser-déposer pour
  envoyer ou recevoir, créer un dossier, renommer, supprimer avec confirmation, voir les droits
  et les dates.
- File des transferts : progression, débit et temps restant, reprise automatique après une
  coupure, pause, reprise et annulation ; dossiers entiers envoyés ou reçus.
- « Transférer des fichiers › Ouvrir en FTP, FTPS ou SFTP » depuis le Scanner, l’Inventaire et
  la fiche Appareil, actif seulement si le port était ouvert au dernier scan, avec « Vérifier
  le port » pour le tester tout de suite.
- FTPS : un certificat autosigné (NAS, imprimante, switch) peut être accepté par son empreinte
  SHA-256 ; une empreinte qui change ensuite est refusée. SFTP : la clé d’un nouveau serveur
  est montrée avant d’être acceptée.
- Serveur FTP temporaire sur le Mac pour les appareils qui viennent chercher leur fichier
  (firmware, configuration) : dossier partagé, mot de passe tiré au hasard, lecture seule par
  défaut, arrêt automatique et journal.
- **Nouvel outil « TFTP »** (Boîte à outils) : serveur TFTP temporaire sur le Mac, avec
  l’adresse à donner à l’appareil affichée en grand, le dossier partagé, l’interface et le port
  au choix, la lecture seule ou la lecture et écriture, et un arrêt automatique après un délai
  sans transfert.
- Port 69 sans droits administrateur : NetScope écoute sur toutes les interfaces et ne répond
  qu’à celle choisie ; le port 6969 est proposé si le 69 est déjà pris.
- Client TFTP : récupérer ou envoyer un fichier vers un switch, une borne ou un téléphone IP,
  depuis l’outil, le menu du Scanner (« Transfert TFTP… ») ou la fiche Appareil.
- Options blksize, tsize, timeout et windowsize pour les gros firmwares, mode binaire par
  défaut ; retour automatique en TFTP de base pour les vieux appareils.
- Journal en direct des transferts TFTP, gardé par site : qui demande quel fichier,
  progression, débit, et réussite ou erreur en clair (fichier introuvable, accès refusé, délai
  dépassé).
- Cas d’usage prêts à copier, avec l’adresse du Mac : sauvegarde de la configuration d’un
  switch Cisco, mise à jour d’un switch Aruba, configuration et firmware d’une FortiGate,
  option DHCP 66 des téléphones IP.
- **État des services** : nouvelles catégories « Réseaux sociaux » (Facebook, Instagram,
  TikTok, Snapchat) et « Assistants IA » (Claude, ChatGPT, Microsoft Copilot, Grok), avec la
  page d’état officielle quand il y en a une (Claude, ChatGPT, Copilot) et le test depuis ce
  réseau pour tous.
- Nouvel état « Bloqué ici » : une page de blocage FortiGuard, le filtrage DNS de la FortiGate
  ou de Cisco Umbrella, un certificat de remplacement du pare-feu ou son portail
  d’authentification ne passent plus pour une panne ; la catégorie FortiGuard bloquée et quoi
  vérifier sur la FortiGate sont affichés.
- Catégories ou services masqués site par site (ex. réseaux sociaux bloqués exprès à un site) :
  cases « Catégories suivies au site », case « Ici » dans « Modifier la liste… » et boutons
  « Masquer ici ». Un service masqué n’est plus vérifié sur ce site.
- **Surveillance et historique des services** : un service bloqué par le filtrage est signalé
  comme « Bloqué ici », avec une notification quand le blocage apparaît et un événement quand
  il est levé.
- **Vitesse des disques** : bouton « Ajouter un emplacement… » pour mesurer un NAS ou un
  partage SMB, NFS, AFP ou WebDAV, ou n’importe quel dossier choisi dans le Finder.
- Le serveur se tape (nom ou IP) ou se choisit dans le Scanner ou l’Inventaire, et le type est
  proposé d’après ses ports ouverts ; on peut aussi coller une adresse (`smb://…`,
  `\\serveur\partage`, `serveur:/export`).
- Le partage est monté automatiquement au lancement du test s’il ne l’est pas déjà, puis
  démonté à la fin seulement si NetScope l’a monté.
- « Tester le serveur » : ping et ports 445, 139, 2049, 548, 80 et 443 avec un bilan en clair,
  et le bon type proposé si un autre service répond.
- Bilan et historique propres à chaque emplacement ajouté, y compris les tests faits avant son
  ajout ; emplacements enregistrés par site.
- **Réglages › Export et sauvegarde** : « Exporter la configuration… » enregistre toute la
  configuration de NetScope dans un seul fichier `.netscope-config` : sites et préréglages,
  FortiGate et leurs jetons, switchs et communautés SNMP, identifiants SSH et WMI, SMTP et
  webhooks, réglages, raccourcis, profils de scan, inventaires et historiques. Tout est coché
  par défaut et chaque partie se décoche.
- « Importer la configuration… » montre d’abord un aperçu de ce qui sera ajouté, remplacé ou
  en conflit, partie par partie ; les conflits ne sont jamais cochés d’office. Une sauvegarde
  de sécurité est faite avant l’import, les secrets vont au Trousseau de ce Mac et NetScope
  redémarre pour appliquer le reste. Une sauvegarde de NetScope peut aussi être importée.
- **Synchronisation entre vos Mac** par iCloud Drive (dossier NetScope › Sync), désactivée par
  défaut et choisie site par site : fiche du site, inventaire, notes des appareils, FortiGate
  et leurs jetons. État « Synchronisé il y a… » et bouton « Synchroniser maintenant », en plus
  d’une synchronisation au lancement et toutes les 15 min.
- Les sites présents sur vos autres Mac s’ajoutent en un clic (« Ajouter à ce Mac »).

### Modifié
- Mots de passe FTP, FTPS, SFTP et des partages rangés au Trousseau macOS, jamais en clair ;
  avertissement chaque fois qu’une connexion FTP n’est pas chiffrée.
- État des services : lecture des pages d’état incident.io (nouveau format de
  status.openai.com) ; Claude est lu sur status.claude.com.
- Vitesse des disques : erreurs expliquées en clair (mauvais mot de passe, partage
  introuvable, serveur qui ne parle que SMB1, droit d’écriture refusé, partage plein ou
  injoignable).
- L’export est obligatoirement chiffré par mot de passe dès qu’un jeton ou un secret est inclus
  (même chiffrement que les sauvegardes chiffrées).
- Les sites et les FortiGate importés ou synchronisés sont reconnus par leur identifiant,
  jamais par leur nom ni leurs plages IP : deux sites ne sont jamais fusionnés, et un site
  importé au même nom est ajouté à part.
- Synchronisation : fusion par date de modification ; un conflit est signalé, la version la
  plus récente est gardée et l’autre peut être rétablie. Les jetons sont chiffrés par un mot de
  passe de synchronisation gardé au Trousseau. Une suppression faite sur un autre Mac est
  signalée, jamais appliquée d’office.

### Corrigé
- Sécurité des transferts : jamais d’accès hors du dossier partagé (noms piégés comme « ../ »
  refusés, en FTP, SFTP et TFTP), aucun fichier existant écrasé sans confirmation, aucun
  fichier partiel laissé après une coupure, avertissement si le coupe-feu de macOS bloque le
  serveur.
- Serveur FTP temporaire : les commandes PORT et EPRT sont bornées et le « rebond FTP » vers un
  autre appareil est refusé ; les données passives ne sont acceptées que du client connecté.
- Client FTP : une reprise d’envoi n’a lieu que si le fichier distant est plus court ; un
  envoi en mode actif respecte le délai et s’annule ; la connexion anonyme ne boucle plus.
- Import d’une sauvegarde chiffrée : lue en mémoire, plus aucun secret en clair dans le
  dossier temporaire.
- Petite fenêtre : noms longs abrégés dans Accès distant au lieu de déborder, colonne
  « Progression » du TFTP assez large, feuilles de Vitesse des disques et d’État des services
  sans débordement horizontal.

### Limites
- Rien de tout cela n’a encore été essayé sur de vrais appareils : FTP, FTPS et SFTP, TFTP
  (switchs Cisco et Aruba, FortiGate, téléphones IP), NAS et partages, synchronisation entre
  deux Mac et détection « Bloqué ici » derrière une vraie FortiGate qui filtre.
- SFTP passe par l’outil `sftp` de macOS ; les clés et `known_hosts` sont ceux de `~/.ssh`.
- FTP, FTPS et SFTP ne sont pas encore proposés comme emplacements dans Vitesse des disques :
  ils y arriveront avec la connexion FTP.
- Meta (Facebook, Instagram), TikTok, Snapchat et Grok n’ont pas de page d’état lisible : ils
  sont seulement testés depuis ce réseau.
- La synchronisation demande iCloud Drive activé sur chaque Mac ; elle ne couvre que les sites
  choisis (fiche, inventaire, notes, FortiGate et jetons), pas les réglages ni les autres
  identifiants : pour eux, utiliser l’export et l’import de la configuration.
- Le serveur TFTP et le serveur FTP temporaire peuvent être bloqués par le coupe-feu de macOS ;
  NetScope l’indique mais ne le change pas.

## 0.17.0 — 2026-11-04

Le suivi automatique et le trafic : NetScope relit tout seul la FortiGate, les bornes et les
switchs du site actif, montre l’état du WAN et des VPN de chaque FortiGate, et un nouvel écran
« Trafic » dit qui consomme le lien, avec une analyse complète du réseau notée sur 100.

### Ajouté
- **Relecture automatique** : sans relancer de scan, NetScope relit à intervalle régulier la
  FortiGate du site actif (FortiSwitch, emplacement des appareils, table ARP et baux DHCP), ses
  bornes FortiAP et ses switchs SNMP.
- Intervalle réglable par site dans Réglages › Switchs › Relecture automatique : désactivée,
  1, 2, 5, 10, 15 ou 30 min (5 min par défaut).
- Indication « Relu il y a 2 min · prochaine dans 3 min » dans Switchs et ports et dans
  Wi-Fi › FortiAP, avec un menu pour changer l’intervalle du site actif.
- **Outil « WAN et VPN »** (Boîte à outils › Internet) : liens WAN de chaque FortiGate avec
  leur état, débit, latence, gigue, perte et SLA du SD-WAN ; tunnels VPN IPsec montés, partiels
  ou tombés, avec le détail des phases 2 ; utilisateurs VPN SSL connectés. Lecture seule par
  l’API REST.
- Vue de tous les sites dans « WAN et VPN » : le menu « Site ▾ » montre un, plusieurs ou tous
  les sites, avec un tableau qui résume chaque FortiGate (liens actifs, tunnels montés, état).
- Seuils réglables d’un lien dégradé (latence, gigue, perte) ; un SLA non respecté sur la
  FortiGate compte aussi. Conseils en clair pour un lien ou un tunnel en panne.
- **Nouvel écran « Trafic »** (groupe Suivi) : trafic de la FortiGate de chaque site lu par
  FortiView (sources, destinations, applications, catégories web, interfaces, politiques,
  sessions et menaces), en temps réel ou sur 5 min, 1 h, 24 h ou 7 jours, trié par débit,
  octets ou sessions. Menu « Site ▾ » avec « Tous les sites ».
- **« Qui sature le lien ? »** en un clic : charge de chaque lien WAN et appareils qui
  consomment le plus, avec leur application, leur destination et un conseil (par exemple, une
  sauvegarde nuage à déplacer hors des heures ouvrables).
- Chaque source du trafic est reliée à NetScope : son nom, son port de switch et sa borne
  Wi-Fi ; double-clic vers sa fiche Appareil, « Ouvrir dans › » vers les autres modules.
- **« Analyse complète du réseau »** : un bilan qui réunit trafic, sécurité, santé (WAN, ports
  de switch en erreur, Wi-Fi, étendues DHCP) et inventaire (appareils inconnus), avec une note
  sur 100 et des points classés par gravité, chacun expliqué, avec l’action conseillée et un
  bouton « Voir ».
- **Surveillance** : nouvelles sondes « Tunnel VPN tombé » et « Lien WAN dégradé » (un tunnel,
  un lien, « * » ou « Site / * », avec leurs propres seuils), « Lien saturé », « Appareil qui
  consomme trop » et « Nouvelle menace ».
- **Rapports** : nouvelles sections facultatives « WAN et VPN » (liens, tunnels, constats et
  conseils) et « Trafic et analyse » (liens WAN, plus gros consommateurs, applications, menaces
  et points de l’analyse complète).

### Modifié
- La relecture se met en pause pour tout site qui n’est pas le site actif, pendant un scan,
  quand le Mac est en veille ou hors réseau, et quand le jeton ou le certificat de la FortiGate
  est à régler.
- Une lecture faite au bouton, en fin de scan ou par la Surveillance repousse la relecture
  suivante : jamais deux lectures à la fois vers la même FortiGate.
- Réglages › Switchs : l’aide indique les droits « Log & Report » et « FortiView » en lecture
  à ajouter au profil de l’administrateur API.
- Diagnostic FortiGate : les réponses brutes du WAN, des VPN et de FortiView sont ajoutées au
  texte copié, sans le jeton.

### Corrigé
- Après une erreur de lecture, les essais s’espacent (le double à chaque échec, jusqu’à 1 h)
  et la dernière lecture réussie reste affichée, au lieu d’être effacée.
- Jamais de relecture SNMP d’un switch d’un autre site : la communauté ne part pas vers
  l’appareil qui porte la même adresse chez un autre client.

### Limites
- Tout est en lecture seule et n’a pas encore été essayé sur une vraie FortiGate : les champs
  renvoyés par FortiOS (SD-WAN, IPsec, VPN SSL, FortiView) peuvent varier selon la version.
- L’écran « Trafic » demande les droits « Log & Report » et « FortiView » en lecture sur le
  profil de l’administrateur API ; sans eux, il l’indique et reste vide. L’historique sur
  24 h ou 7 jours dépend de la journalisation (disque ou FortiAnalyzer) de la FortiGate.
- La relecture automatique ne touche que le site actif, et seulement quand NetScope est ouvert.

## 0.16.0 — 2026-11-04

Les clients Wi-Fi des bornes FortiAP en détail : par borne, par radio et par SSID, une fiche
complète pour chaque client avec l’historique de son signal, et un bouton « Diagnostiquer »
qui vérifie chaque cause possible d’un problème Wi-Fi et propose quoi faire, dans l’ordre.

### Ajouté
- **Wi-Fi › FortiAP, clients d’une borne** : un clic sur une borne affiche ses clients, par
  radio (2,4, 5 et 6 GHz) puis par SSID, avec le nombre de clients de chaque SSID.
- **Wi-Fi › Clients, vue « Par SSID »** : chaque SSID se déplie, avec son nombre de clients,
  ses bornes, ses bandes, sa sécurité et son VLAN ; filtres par SSID, borne, bande et signal
  faible.
- **Fiche complète d’un client Wi-Fi** (double-clic) : nom, fabricant, MAC, IP, VLAN, SSID,
  borne et radio, canal et largeur, standard (Wi-Fi 4 à 7), sécurité, authentification et
  utilisateur, débits montant et descendant, octets échangés, durée de connexion, itinérances
  et déconnexions ; liens vers la fiche Appareil, l’Inventaire et le Ping continu. Le bouton ‹
  ramène à la borne ou au SSID d’origine.
- **Historique du signal** de chaque client Wi-Fi (RSSI, SNR, débit, borne), gardé par site
  sur ce Mac et complété à chaque lecture des bornes, avec une courbe qui montre aussi les
  changements de borne.
- **Fiche Appareil, section Wi-Fi** : si l’appareil est un client Wi-Fi, elle donne tout ce
  qu’il faut pour le diagnostic (signal et son historique, borne et canal, charge de la radio,
  débits, problèmes repérés) et le bouton « Diagnostiquer ».
- **Diagnostic Wi-Fi** : bouton « Diagnostiquer » sur un client, une borne ou un SSID FortiAP.
  Il vérifie chaque cause possible : signal, client collant, canal et chevauchements,
  interférences et AP voisins, largeur, DFS, charge, clients lents, poste du client, bande
  2,4 GHz, authentification et déconnexions, DHCP et 169.254, réseau au-delà du Wi-Fi, lien
  de la borne vers son switch, limites du SSID.
- Un verdict par cause (OK, à surveiller, problème) avec les mesures qui le prouvent, la cause
  la plus probable en tête, des actions numérotées dans l’ordre et un canal conseillé.
- Ping facultatif de quelques secondes depuis ce Mac vers la passerelle, le DNS et Internet,
  pour savoir si le problème dépasse le Wi-Fi.
- Suivi dans le temps : le dernier diagnostic de chaque client est gardé dans le site, avec le
  diagnostic précédent et l’heure où le problème revient.
- « Copier » le résultat en texte et « Ajouter au rapport du site » ; nouvelle section
  facultative « Diagnostic Wi-Fi » dans les Rapports.
- **Wi-Fi › FortiAP** : menu « Diagnostiquer une borne, un SSID ou un client » dans les
  Conseils, bouton « Diagnostiquer la borne » dans la fiche de la borne et diagnostic direct
  des clients les plus faibles.

### Modifié
- Le diagnostic brut de la FortiGate liste les champs des clients Wi-Fi que cette version de
  FortiOS ne renvoie pas ; ils sont affichés « — » dans la fiche du client.

### Corrigé
- La colonne « Appareil du Scanner » des clients Wi-Fi ne rattache plus un client d’un autre
  site qui a la même adresse MAC.
- **Vitesse des disques, iCloud Drive** : une erreur d’envoi passagère d’iCloud ne fait plus
  échouer le test ; le message exact du service est affiché et gardé.

### Limites
- Lecture seule : le diagnostic ne modifie rien sur la FortiGate ni sur les bornes ; NetScope
  propose, le technicien applique.
- Certains champs (bruit, itinérances, déconnexions, utilisateur 802.1X…) dépendent de la
  version de FortiOS ; quand elle ne les renvoie pas, ils restent « — » et les causes qui en
  dépendent ne peuvent pas être tranchées.
- L’historique du signal ne se remplit qu’à chaque lecture des bornes par NetScope (la relecture
  automatique est prévue dans la 0.17.0) ; il reste sur ce Mac (14 jours au plus).
- Le ping du diagnostic part de ce Mac, pas du client : il dit si le réseau au-delà du Wi-Fi
  répond, pas ce que vit le poste du client. Le WAN du site n’est pas encore vérifié (note 39).
- Fonctions à essayer sur une vraie FortiGate avec bornes FortiAP.

## 0.15.0 — 2026-11-04

Choix du site toujours visible sous le logo NetScope, Switchs et ports et Wi-Fi consultables
pour n’importe quel site sans changer le site actif, un Retour qui nomme l’écran d’origine et
retrouve la ligne choisie, et un nom d’utilisateur demandé avant chaque connexion SSH rapide.

### Ajouté
- **Choix du site sous le logo NetScope** : nom du site actif et pastille de sa FortiGate
  (jointe, injoignable, jamais lue) ; liste des sites avec recherche (nom, plage, libellé,
  VLAN), « Aucun site », « Tous les sites », « Détecter mon site » et « Gérer les sites… ».
- Nouveau menu **« Site »** dans la barre de menus et raccourci ⌘⇧S « Choisir le site »
  (modifiable dans Réglages › Raccourcis) ; le site actif est rappelé dans le titre de la
  fenêtre.
- **Switchs et ports** : menu « Site ▾ » en haut de l’écran pour voir les switchs d’un autre
  site, ou de tous, sans changer le site actif. Une carte par site, un tableau commun avec
  colonne « Site » et recherche, la façade et le détail du port, et « Lire la FortiGate » à la
  demande (lecture seule).
- **Wi-Fi › FortiAP** : menu « Site ▾ » pour voir les bornes, clients, SSID et AP voisins d’un
  autre site, ou de plusieurs, avec colonne « Site » et « Lire les bornes » par site. Deux sites
  ne sont jamais mélangés, même s’ils utilisent les mêmes adresses.
- Messages clairs quand un site n’a ni FortiGate ni switch, quand sa FortiGate n’a pas encore
  été lue ou quand ses switchs SNMP doivent être relevés sur place.
- **Nom d’utilisateur SSH à la connexion** : NetScope le demande maintenant avant chaque
  connexion rapide (fiche Appareil, Scanner, Inventaire, scan des ports), dans une petite
  fenêtre préremplie avec le dernier nom utilisé pour l’appareil, sinon celui du site ou
  l’identifiant SSH des Réglages.
- Liste des noms déjà utilisés (admin, root, manager…) et saisie libre ; la forme
  `admin@10.0.0.2:2222` est acceptée dans la fenêtre, dans le champ Hôte d’Accès distant et
  dans sa recherche.
- Choix du port et de l’identification (automatique, clé privée, mot de passe), avec la
  commande exacte affichée avant l’ouverture dans Terminal (forme `ssh user@ip`).
- Nom retenu par appareil, même s’il change d’IP ; case « Ne plus demander pour cet appareil »
  (⌥-clic ou clic droit pour changer d’utilisateur ou l’oublier) et « Enregistrer dans le
  carnet » d’Accès distant.

### Modifié
- Le bouton **‹ Retour** nomme l’écran d’origine (« ‹ Inventaire », « ‹ Carte ») et le menu
  Aller dit « Retour à … ».
- Au retour sur l’Inventaire ou le Scanner, la ligne choisie revient en vue, à la même place
  dans la liste.
- Changer de site vide l’historique Retour / Avancer ; Switchs et Wi-Fi suivent le site de
  l’objet après un double-clic ou « Ouvrir dans › ».
- Une connexion SSH ou Telnet du carnet enregistrée sans utilisateur demande aussi le nom avant
  de s’ouvrir.
- Aucun mot de passe n’est retenu par NetScope : les secrets restent au Trousseau ou sont
  demandés par `ssh` dans Terminal.

### Corrigé
- « Ouvrir dans › Switchs et ports » sur un appareil d’un autre site ne propose plus le switch
  du site actif qui porte le même nom.

### Limites
- Les switchs SNMP d’un autre site ne sont pas interrogés à distance : ils se relèvent sur
  place, pendant un scan de ce site ; pour un site éloigné, seuls les FortiSwitch lus par sa
  FortiGate sont à jour.
- « Lire la FortiGate » et « Lire les bornes » ne lisent que les FortiGate joignables depuis le
  Mac (jeton au Trousseau, lecture seule) ; sans nouvelle lecture, l’écran montre la dernière
  lecture connue de ce site.
- La fenêtre du nom d’utilisateur ne vaut pour l’instant que pour SSH (et Telnet depuis le
  carnet) ; SFTP / FTP, RDP et VNC n’en profitent pas encore.
- Essais réels à faire sur les sites, FortiGate et bornes de Dany.

## 0.14.0 — 2026-11-04

Recherche dans la Carte du réseau, type « Téléphone IP » détecté automatiquement, occupation
des étendues DHCP de la FortiGate et sauvegardes chiffrées par mot de passe, secrets compris
pour passer d’un Mac à l’autre.

### Ajouté
- **Recherche dans la Carte du réseau** : la recherche de la barre d’outils trouve les appareils
  sur la carte (IP, nom, MAC, `switch:`, `port:`, `vlan:`, `type:`, `borne:`…). La carte se
  centre sur le premier résultat, surligne son nœud ou le groupe qui le contient (par exemple
  « Imprimantes ×2 ») et atténue le reste.
- Le détail de la Carte affiche alors la fiche de l’appareil trouvé (IP, MAC, switch et port,
  VLAN, borne Wi-Fi, place sur la carte) avec « Ouvrir la fiche » ; l’appareil est marqué dans
  la liste des membres de son groupe.
- Avec plusieurs résultats : compteur « 2 sur 5 » et boutons précédent / suivant (↩︎ et ⇧↩︎
  dans le champ, ⌘G et ⇧⌘G). Sans résultat, un message clair propose les scans précédents
  s’ils correspondent.
- Avec plusieurs sites, la recherche porte sur le site dessiné et propose « Aussi sur : … » ;
  un clic dessine cet autre site et montre son résultat.
- **Type d’appareil « Téléphone IP »** (Yealink, Poly, Cisco, Mitel, Grandstream, Snom, Fanvil,
  Avaya…), séparé de « Téléphone », qui reste pour les cellulaires. Il est proposé dans
  « Changer le type », l’Inventaire, la Carte (groupe « Téléphones IP ×N »), l’Analyse et les
  Rapports (« Tél. IP »).
- **Détection automatique des téléphones IP** : fabricant, ports SIP 5060 et 5061, nom d’hôte
  (SEP… de Cisco, SIP-T54W, VVX…), annonce « téléphone » par LLDP, LLDP-MED ou CDP sur les
  switchs relevés, et VLAN voix. Un cellulaire n’est jamais classé téléphone IP.
- La fiche Appareil d’un téléphone IP montre ses indices VoIP (LLDP / CDP, VLAN voix, SIP,
  fabricant).
- Recherche : `type:voip` ou `type:sip` trouve les téléphones IP ; l’import CSV accepte
  « Téléphone IP », « Tél. IP », « Téléphonie IP » et « VoIP ».
- **Outil « Étendues DHCP »** dans la Boîte à outils (groupe Services) : occupation de chaque
  étendue DHCP de la FortiGate du site (plages, exclusions, réservations, baux actifs, adresses
  libres, baux qui expirent bientôt), avec jauge, état et conseils.
- Détail d’une étendue : liste des baux et des réservations (y compris celles hors plage) ; un
  double-clic ouvre la fiche de l’appareil.
- Seuils d’occupation réglables (80 % pour l’avertissement et 95 % pour le critique par défaut)
  et alerte en clair, par exemple « Étendue VLAN 20 pleine à 96 % : 4 adresses libres ; des
  postes risquent de tomber en 169.254 ».
- Sans FortiGate, une estimation de l’occupation est faite à partir du Test DHCP et des
  appareils vus par le scan, clairement marquée « estimation ».
- **Surveillance** : nouveau type de sonde « Étendue DHCP presque pleine » et tuile « Étendues
  DHCP » qui montre les étendues proches de la saturation.
- **Rapports** : nouvelle section facultative « Étendues DHCP » (occupation de chaque étendue,
  constats et conseils).
- **Sauvegardes chiffrées** (Réglages › Export et sauvegarde) : option « Chiffrer par mot de
  passe ». Les sauvegardes deviennent des archives `.netscope-backup` chiffrées en AES-GCM
  256 bits, avec une clé tirée du mot de passe (PBKDF2, 600 000 itérations). Le mot de passe se
  saisit deux fois, un indicateur montre sa force, et un avertissement rappelle que sans lui la
  sauvegarde est perdue.
- Option « Inclure les jetons et secrets (pour un autre Mac) » : jetons FortiGate, communautés
  SNMP, identifiants SSH et WMI, mot de passe SMTP, webhooks, secret Graph. Ils ne sont rangés
  que dans la partie chiffrée et sont remis au Trousseau à la restauration, après confirmation :
  plus besoin de ressaisir chaque jeton sur un deuxième Mac.
- « Mémoriser dans le Trousseau » (décochée par défaut) rend la sauvegarde automatique
  quotidienne chiffrée ; sinon le mot de passe est demandé à chaque sauvegarde et n’est gardé
  nulle part.
- Nouvelle colonne « Chiffrée » dans la liste des sauvegardes (avec le nombre de secrets
  inclus).

### Modifié
- Les ports SIP 5060 et 5061 font maintenant partie des 22 ports essentiels sondés à chaque
  scan.
- **Rapports** : un VLAN rempli de téléphones IP s’appelle « Voix (téléphonie IP) », ou « Voix
  et Wi-Fi » s’il porte aussi une borne.
- La lecture des étendues DHCP se fait en lecture seule (GET) ; les refus (HTTP 403) et les
  adresses absentes (HTTP 404) sont expliqués, et les réponses brutes sont ajoutées au
  diagnostic de la FortiGate.
- La restauration d’une sauvegarde chiffrée demande son mot de passe et vérifie l’intégrité de
  toute l’archive avant de restaurer quoi que ce soit. Un mauvais mot de passe ou un fichier
  modifié donne un message clair, et rien n’est restauré.
- Sans mot de passe, la sauvegarde ne change pas et ne contient toujours aucun secret ; les
  anciennes sauvegardes non chiffrées se restaurent comme avant.

### Corrigé
- Un téléphone IP qui s’annonce « Bridge, Telephone » par LLDP n’est plus pris pour un uplink,
  et le poste branché derrière lui garde son port.
- Les numéros de port à quatre chiffres ne s’affichent plus avec une espace (« 5060 » et non
  « 5 060 »).

### Limites connues
- Tout a été vérifié avec des données de démonstration seulement : la lecture des étendues
  DHCP n’a pas encore été essayée sur une vraie FortiGate (droits du jeton, versions de FortiOS),
  ni la détection des téléphones IP sur un vrai réseau voix.
- L’estimation sans FortiGate ne voit que les appareils qui répondent au scan et l’offre du
  Test DHCP : elle peut sous-estimer l’occupation réelle.
- Un mot de passe de sauvegarde oublié ne se récupère pas : la sauvegarde chiffrée est alors
  perdue. Une sauvegarde qui inclut les secrets est aussi sûre que son mot de passe.
- La restauration d’une sauvegarde chiffrée sur un deuxième Mac reste à essayer en vrai.

## 0.13.0 — 2026-11-04

Navigation : chaque élément mène à sa suite logique d’un double-clic, un menu « Ouvrir dans › »
propose les autres modules, et Retour / Avancer ramènent à l’écran d’avant comme dans le
Finder ; les gros sites (milliers d’appareils, 20 sites) restent fluides.

### Ajouté
- **Double-clic partout** (et ↩︎ dans les tableaux) : un appareil ouvre sa fiche, un switch ses
  ports, une borne FortiAP le Wi-Fi sur cette borne, un client Wi-Fi sa fiche, une alerte de
  surveillance sa sonde, une sonde l’appareil ou le service qu’elle surveille, et une alerte de
  l’Analyse la fiche et la chronologie.
- **Menu contextuel « Ouvrir dans › »** : il propose les autres modules pertinents pour
  l’élément (fiche, Inventaire, Scanner, Carte, Switchs et ports, Wi-Fi, Ping continu,
  Surveillance, Analyse, Accès distant), avec les raccourcis ⌥⌘1 à ⌥⌘9 et ⌥⌘0 ; aussi dans le
  menu Appareil pour l’appareil choisi.
- **Retour et Avancer** comme dans le Finder : boutons ‹ › de la barre d’outils, ⌘[ et ⌘],
  menu Aller. On retrouve l’écran, la recherche, le filtre, la sélection et les sites d’avant.
- **Switchs et ports** : un double-clic sur un port de la façade ou du tableau des ports ouvre
  l’appareil branché. S’il y en a plusieurs, une petite liste permet de choisir, ou de les voir
  dans l’Inventaire. Un port vide, un uplink ou trunk, ou un appareil pas encore vu donne un
  message clair.
- **Carte du réseau → Inventaire** : « Inventaire » (et « Scanner ») dans le détail d’un groupe
  ou d’un switch, ou un double-clic sur un groupe, ouvre l’Inventaire filtré sur exactement ces
  appareils, dans le site dessiné. Le filtre s’affiche comme une étiquette retirable, par
  exemple « Carte : Téléphones ×11 · SW-ETG2-01 ».
- **Barre latérale** : un double-clic sur une plage ouvre le Scanner filtré sur cette plage, et
  un double-clic sur le site actif son Inventaire ; clic droit sur un site pour le voir sans en
  changer.
- **Essais de charge sans réseau** : 20 sites fictifs, plages de 65 536 adresses, 5 000
  appareils par site, FortiGate avec 10 FortiSwitch et 30 FortiAP ; les temps sont mesurés à
  chaque test (les gros essais avec `NETSCOPE_CHARGE=1`).

### Modifié
- Les boutons « Voir le port » des fiches ouvrent directement le bon switch et le bon port.
- **Fiche Appareil** : « appareil précédent / suivant » passe en ↑ ↓, pour ne pas se confondre
  avec Retour / Avancer.
- **Inventaire, Analyse et Carte** : les grands inventaires ne sont plus recalculés à chaque
  affichage ; l’écran reste fluide avec des milliers d’appareils.
- **Recherche** : dans l’Inventaire, la recherche d’un mot est jusqu’à 20 fois plus rapide sur
  20 000 fiches.
- **Rapports** : le rapport multisite est environ 10 fois plus rapide (20 sites et 68 000
  appareils en moins d’une seconde).
- **Sites** : « Tous les sites » lit les inventaires des autres sites en parallèle ; le
  changement de site est presque deux fois plus rapide.
- **Historique** : un très gros site (plus de 1 500 appareils) garde moins d’instantanés de
  scan (environ 30 pour 5 000 appareils), pour que son fichier d’inventaire reste léger ; les
  autres sites gardent toujours 100 scans.

### Corrigé
- **Inventaire** : l’enregistrement se fait en arrière-plan et regroupe les changements
  rapprochés ; modifier une fiche, accepter une alerte ou finir un scan ne fige plus l’écran
  sur les gros sites.

### Limites
- Les temps des essais de charge sont mesurés sur des données fictives, sur ce Mac ; le
  comportement sur un vrai réseau de plusieurs milliers d’appareils reste à essayer.
- L’enregistrement en arrière-plan regroupe les changements rapprochés : en cas d’arrêt brutal
  de l’app (plantage, coupure), les toutes dernières modifications de l’inventaire peuvent être
  perdues.
- Sur un très gros site, l’historique remonte moins loin (environ 30 scans au lieu de 100) :
  les instantanés les plus anciens sont retirés.
- Retour et Avancer retrouvent l’écran et ses filtres, pas la position de défilement des
  tableaux.
- Tous les éléments n’ont pas encore de suite logique : services en ligne, résultats d’outils,
  sauvegardes et connexions d’Accès distant restent à relier (note 34).

## 0.12.0 — 2026-11-04

Sites : un site par client ou par lieu, avec ses plages, ses FortiGate, ses switchs SNMP et son
propre inventaire ; on choisit le site dans le Scanner au lieu de reconstruire les plages à
chaque fois, et deux sites ne se mélangent plus, même sur les mêmes plages IP.

### Ajouté
- **Sites** : chaque site a un nom, ses plages (libellé, VLAN), ses FortiGate et ses switchs
  SNMP. Pas de niveau Client : le site porte au besoin le nom du client (« Clinique Exemple »,
  « Groupe X · Laval »).
- **Scanner** : menu « Site : <nom> ▾ » en haut des plages pour choisir un site, enregistrer
  les plages comme site, mettre à jour le site, détecter son site ou gérer les sites. Les plages
  modifiées et non enregistrées sont signalées.
- **Inventaire unique à chaque site** : fiches, historique, événements de l’Analyse, archive,
  exclusions, conflits IP, notes et types choisis à la main sont propres au site. La même IP ou
  la même MAC sur deux sites donne deux fiches distinctes.
- **Résultats par site** : changer de site met de côté les appareils, le bilan des switchs,
  l’état du scan et les nouveautés, puis les retrouve au retour. Scanner, Carte, Inventaire,
  Switchs, Wi-Fi FortiAP et Rapports ne mélangent plus deux sites.
- **« Détecter mon site »** reconnaît le site par la MAC de la passerelle, le numéro de série
  ou le nom de la FortiGate (le SSID aide à départager), jamais par l’adresse IP seule. Si
  plusieurs sites ont les mêmes plages, NetScope demande, puis retient la passerelle.
- **Réglages › Sites et plages** : tableau des sites (plages, FortiGate, switchs SNMP, appareils
  en inventaire, dernier scan) ; ajouter, renommer, dupliquer et supprimer (avec confirmation :
  son inventaire est supprimé aussi) ; « Créer depuis les FortiGate » ; import et export CSV
  `site;plages;fortigate`, sans aucun secret.
- **Réglages › Switchs** : chaque switch SNMP (non Fortinet) peut être associé à aucun, un ou
  plusieurs sites.
- **Switchs et ports** : bandeau « Site : <nom> · N switchs » avec « Afficher tous les
  switchs ».
- **Inventaire › suppression** : sélection multiple (⌘-clic, ⇧-clic, ⌘A), « Supprimer de
  l’inventaire… » au clic droit, touche ⌫ et bouton corbeille. La confirmation donne le nombre
  d’appareils et les sites touchés ; la case « Ne plus suivre ces appareils » les exclut du site
  (un scan ne les remet pas). Annuler (⌘Z) et Rétablir ; « N non suivis » pour les suivre de
  nouveau.
- **Choix d’un ou plusieurs sites** : menu « Site ▾ » dans l’Analyse, l’Inventaire, la Carte et
  les Rapports (un, plusieurs ou tous les sites), sans changer le site actif du Scanner et
  retenu par écran. Les lignes de deux sites ne sont jamais fusionnées ; la colonne « Site »
  s’affiche d’office avec plusieurs sites. Analyse : alertes regroupées par site ; Carte : un
  dessin par site ; Rapports : rapport multisite, une section par site.

### Modifié
- **Barre latérale** : la section « Sites » remplace « Plages enregistrées » ; le site actif y
  est marqué avec ses plages, et un clic change de site.
- **FortiGate** : celles du site actif sont lues. Le choix par plage IP (0.10.0) ne sert plus
  que sans site actif.
- **Switchs et ports** : seuls les switchs du site actif sont affichés et interrogés. Un switch
  sans site n’apparaît que s’il est dans les plages du dernier scan ; le relevé de fin de scan
  n’interroge jamais un switch associé à un autre site.
- **Inventaire et Rapports** : le nom du site actif est en évidence et figure dans l’en-tête du
  rapport. La recherche `site:` vise le vrai site.
- **Migration sans perte** : les plages, l’inventaire (avec son historique et les types choisis
  à la main), les noms, les notes et la FortiGate actuels deviennent ceux de « Site principal ».
  L’ancien inventaire est gardé en copie de sécurité (`inventory.avant-sites.json`). Les
  sauvegardes incluent les inventaires de tous les sites.

### Corrigé
- **Carte du réseau** : elle ne dessine plus que les appareils vus pendant le dernier scan,
  dans ses plages ; les appareils et switchs d’un scan précédent (autre plage ou autre site)
  n’y apparaissent plus. La case « Scans précédents » les remet.
- **Switchs et ports** : un switch SNMP hors des plages scannées (pas un Fortinet) n’est plus
  affiché avec le site en cours.
- **Analyse et Carte** : « Vu : Maintenant » seulement pour un appareil vu il y a moins de
  10 minutes ; « dernier scan » donne la date quand le scan n’est pas du jour.
- **Rapports** : la passerelle du Mac n’est notée que si elle est dans les plages du site.

### Limites
- Les sites n’ont pas encore été essayés sur les vrais sites de Dany : « Détecter mon site »,
  la migration d’un vrai inventaire et l’import CSV sont vérifiés sur des données de
  démonstration et par les tests.
- La détection a besoin d’avoir vu la passerelle (MAC apprise lors d’un scan du site) ou d’une
  FortiGate joignable ; sur un réseau jamais scanné et sans FortiGate, il faut choisir le site
  à la main.
- Changer de site ou supprimer le site actif est refusé pendant une interrogation des switchs
  ou une lecture FortiGate : attendre la fin ou l’arrêter.
- Supprimer un site supprime son inventaire (la copie de sécurité de la migration et les
  sauvegardes automatiques restent).
- Le fichier CSV ne contient ni jeton ni communauté SNMP : ils restent au Trousseau et sont à
  saisir sur un autre Mac.

## 0.11.0 — 2026-11-04

Recherche multiple dans tous les modules et Wi-Fi Fortinet : on combine plusieurs critères
(« switch:SW-ETG2 type:imprimante ») partout où il y a une recherche, et le module Wi-Fi lit
les bornes FortiAP de chaque site par sa FortiGate, avec un diagnostic en clair.

### Ajouté
- **Recherche multiple** : plusieurs mots à la fois (« SW-ETG2 imprimante »), préfixes de
  champ (« switch:SW-ETG2 type:imprimante », « vlan:30 », « fab:Brother », « site:Laval »),
  exclusion par « - » (« -type:imprimante ») et « "phrase exacte" » entre guillemets ; casse
  et accents ignorés.
- **Adresses et numéros précis** : adresses IP par début d’adresse ou par bloc
  (« ip:10.20. », « ip:10.20.0.0/16 »), MAC sans souci des séparateurs (« mac:94ddf8 »),
  VLAN et port exacts.
- **Étiquettes de critères** sous la barre d’outils, chacune retirable d’un clic, avec le
  nombre de résultats, le menu « Critères » des préfixes du module et une aide au survol ; le
  champ de recherche propose les préfixes pendant la saisie.
- **Wi-Fi › FortiAP** : par la FortiGate de chaque site et en lecture seule, les bornes
  FortiAP (état, modèle, firmware, radios, clients, utilisation du canal), les clients Wi-Fi,
  les SSID diffusés et les AP voisins ou non autorisés. Plusieurs sites sont fusionnés, chaque
  borne marquée de son site ; les FortiGate utilisées sont les mêmes que pour les switchs
  (choix par plage IP).
- **Diagnostic Wi-Fi automatique** : carte des canaux des bornes, chevauchements de canal,
  clients à signal faible, bornes hors ligne ou surchargées, conseils en clair ; les seuils
  sont réglables.
- **Scanner et fiche Appareil** : pour un appareil en Wi-Fi, borne FortiAP, SSID, bande et
  signal (colonnes facultatives « Borne Wi-Fi » et « SSID »).
- **Surveillance** : sondes « FortiAP hors ligne » et « Borne surchargée ».
- **Rapports** : section facultative « Wi-Fi FortiAP ».

### Modifié
- La recherche de la barre d’outils filtre désormais aussi la Surveillance (sondes et
  journal), l’Accès distant, la Boîte à outils (outils et historique), les Réglages et la
  table MAC des Switchs ; chaque module garde sa propre recherche.
- Les filtres des panneaux (sondes, connexions, outils, réglages, table MAC, réseaux Wi-Fi,
  serveurs de débit) acceptent la même syntaxe. Une recherche d’un seul mot donne le même
  résultat qu’avant.
- **Diagnostic FortiGate** : les réponses brutes copiées comprennent les appels Wi-Fi (le
  jeton est toujours retiré) ; un refus 403 explique le droit « WiFi & Switch Controller » à
  ajouter au profil de l’administrateur API.

### Corrigé
- « vlan:4 » ne trouve plus le VLAN 40, ni « port:1 » le port 12 : VLAN et ports se comparent
  désormais exactement.

### Limites
- La partie FortiAP n’a pas encore été essayée sur une vraie FortiGate avec des bornes : elle
  est faite d’après la documentation de l’API REST de FortiOS et vérifiée sur des données de
  démonstration. Les champs disponibles peuvent varier selon la version de FortiOS.
- Seules les bornes FortiAP gérées par une FortiGate sont lues ; les bornes d’autres marques
  ou autonomes n’apparaissent pas dans cette partie (l’analyse des réseaux voisins par le Mac
  reste disponible).
- Le profil de l’administrateur API doit avoir le droit « WiFi & Switch Controller » en
  lecture ; sans lui, la partie FortiAP reste vide et l’explique.
- Rien n’est modifié sur les FortiGate ni sur les bornes : NetScope ne fait que lire.

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
