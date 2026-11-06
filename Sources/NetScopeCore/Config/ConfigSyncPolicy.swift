import Foundation

// Note 86 : synchronisation COMPLÈTE des données entre les Mac (extension de la note 56).
//
// Ce fichier est le CLASSEMENT de tout ce que NetScope garde sur le disque et dans ses
// préférences : chaque fichier JSON du dossier de données (~/Library/Application Support/NetScope)
// et chaque préférence (UserDefaults) est soit SYNCHRONISÉ (dans une catégorie, qu'on peut
// décocher), soit PROPRE À CE MAC (jamais envoyé). Les catégories sont les parties de l'export de
// la configuration (`ConfigPart.builtIn`) : une seule liste pour l'export et la synchronisation.
//
// ┌──────────────────────────────────────┬───────────────────────────┬───────────────────────────┐
// │ Fichier / préférence                  │ Synchronisation           │ Granularité               │
// ├──────────────────────────────────────┼───────────────────────────┼───────────────────────────┤
// │ sites.json (fiche de chaque site)     │ par site (dossier <id>)   │ un élément par site       │
// │ sites/<id>/inventory.json             │ par site                  │ fichier entier            │
// │ sites/<id>/notes-appareils.json       │ par site                  │ fichier entier            │
// │ sites/<id>/resultats.json             │ par site (derniers résult.)│ fichier entier           │
// │ sites/<id>/wifi-releve.json           │ par site (relevé par pièce)│ fichier entier           │
// │ sites/<id>/carte-disposition.json     │ par site (carte à la main)│ fichier entier            │
// │ NetScope.fortigate.controleurs        │ par site (ses FortiGate)  │ une FortiGate par élément │
// │ connexions.json (carnet, tunnels)     │ global (_global)          │ une connexion par élément │
// │ rustdesk.json (carnet, historique)    │ global                    │ réglages + un lancement   │
// │ rustdesk-serveur.json                 │ global (mesures locales)  │ compte du serveur         │
// │ ssh-utilisateurs.json                 │ global                    │ fichier entier            │
// │ identifiants.json (SSH, WMI)          │ global                    │ un identifiant par élément│
// │ surveillance.json                     │ global : sondes, planning │ une sonde par élément ;   │
// │                                       │ (états, historique, journal│ états, historique et     │
// │                                       │  propres à ce Mac)        │ journal jamais envoyés    │
// │ rapports/planifies.json               │ global                    │ un rapport par élément    │
// │ outils.json, services-en-ligne.json   │ global                    │ fichier entier            │
// │ speedtest.json (historique)           │ global                    │ une mesure par élément    │
// │ speedtest-planifie.json, -serveurs    │ global                    │ fichier entier            │
// │ appareils-saisis.json                 │ global                    │ une saisie par élément    │
// │ bilans-raccordement.json              │ global                    │ fichier entier            │
// │ disques-emplacements.json, NAS        │ global                    │ fichier entier            │
// │ réglages, raccourcis, profils, seuils │ global (préférences)      │ une préférence par élément│
// │ switchs SNMP, plages exclues…         │ global (préférences)      │ une préférence par élément│
// ├──────────────────────────────────────┼───────────────────────────┼───────────────────────────┤
// │ etat.json (plages et noms en cours)   │ propre à ce Mac           │ session de scan de ce Mac │
// │ wifi-signal.json (signal / seconde)   │ propre à ce Mac           │ historique brut volumineux│
// │ trafic-ports.json (trafic brut)       │ propre à ce Mac           │ historique brut volumineux│
// │ journaux.json (Syslog reçus)          │ propre à ce Mac           │ récepteur de ce Mac       │
// │ diagnostics-wifi.json, disques.json   │ propre à ce Mac           │ mesures de CE Mac         │
// │ ping-session.json, mtu.json, tftp.json│ propre à ce Mac           │ session, outils locaux    │
// │ outils/historique.json, rapports/index│ propre à ce Mac           │ fichiers produits ici     │
// │ disques-en-cours.json, *.illisible-*  │ propre à ce Mac           │ travail en cours, copies  │
// │ oui.tsv, Captures, Logs, Sauvegardes  │ propre à ce Mac           │ pas du JSON de données    │
// │ sauvegarde.*, synchro.*, configuration│ propre à ce Mac           │ réglages de ce Mac        │
// │ onglets, tri, périodes, fenêtres (NS*)│ propre à ce Mac           │ état de l'interface       │
// │ NetScope.oui.*, diagnostic.*, flux.*  │ propre à ce Mac           │ base OUI, journal, NetFlow│
// │ journaux.*, tftp.*, terminal (taille) │ propre à ce Mac           │ services de ce Mac        │
// └──────────────────────────────────────┴───────────────────────────┴───────────────────────────┘
//
// Secrets du Trousseau : ceux des données synchronisées (jetons FortiGate avec leur site ;
// communautés et utilisateurs SNMP v3, SSH, WMI, Telnet, VNC, FTP, SFTP, SMB, RustDesk, SMTP,
// webhooks, ntfy, Pushover, Microsoft Graph, GitHub dans le global) voyagent CHIFFRÉS par le mot
// de passe de synchronisation, jamais en clair ; ni le mot de passe des sauvegardes ni celui de la
// synchronisation ne voyagent. Un fichier ou une préférence d'une future fonction, pas encore
// classé ici, est synchronisé dans la catégorie « Réglages » (comme à l'export) : rien n'est oublié.

/// Une liste à identifiants dans un fichier JSON synchronisé.
public struct ConfigSyncList: Sendable, Hashable {
    /// Clé du tableau dans l'objet JSON ; nil : le JSON est le tableau lui-même.
    public var arrayKey: String?
    public var idField: String
    /// Champ lu pour le libellé (« name », « host ») ; nil : l'identifiant.
    public var nameFields: [String]
    /// Champs propres à chaque Mac, ni comparés ni remplacés.
    public var volatileFields: [String]
    /// « Connexion », « Sonde ».
    public var elementLabel: String
    /// Liste d'historique élaguée toute seule (mesures de plus de 90 jours, lancements au-delà de
    /// 300) : un élément retiré n'est ni publié comme suppression ni signalé aux autres Mac.
    public var silentRemoval: Bool

    public init(arrayKey: String?, idField: String = "id", nameFields: [String] = ["name"], volatileFields: [String] = [],
                elementLabel: String, silentRemoval: Bool = false) {
        self.arrayKey = arrayKey
        self.idField = idField
        self.nameFields = nameFields
        self.volatileFields = volatileFields
        self.elementLabel = elementLabel
        self.silentRemoval = silentRemoval
    }

    /// Clé du tableau dans les clés d'éléments (« » pour la racine).
    public var token: String { arrayKey ?? "" }
}

/// Comment un fichier JSON global est découpé pour la synchronisation.
public struct ConfigSyncFileRule: Sendable, Hashable {
    public var pattern: String
    public var label: String
    /// Listes synchronisées élément par élément (deux Mac qui changent deux éléments différents
    /// fusionnent sans conflit).
    public var lists: [ConfigSyncList]
    /// Clés de premier niveau propres à ce Mac : jamais envoyées, gardées telles quelles à la réception.
    public var localKeys: [String]

    public init(pattern: String, label: String, lists: [ConfigSyncList] = [], localKeys: [String] = []) {
        self.pattern = pattern
        self.label = label
        self.lists = lists
        self.localKeys = localKeys
    }

    /// Clés jamais remplacées par le « reste » du fichier (listes et clés propres au Mac).
    public var preservedKeys: [String] { lists.compactMap(\.arrayKey) + localKeys }
}

public enum ConfigSyncPolicy {
    /// Dossier des données globales dans le dossier de synchronisation (jamais un identifiant de
    /// site : les versions 0.18 à 0.28 de NetScope l'ignorent).
    public static let globalFolder = "_global"
    /// Dossier des fiches des Mac (nom, modèle, version, dernière synchro).
    public static let devicesFolder = "_appareils"
    /// Identifiant des fichiers du dossier global.
    public static let globalID = UUID(uuidString: "00000000-0000-4000-8000-000000000086")!

    /// Catégories synchronisées par site (les autres le sont dans le dossier global).
    public static let siteCategories: Set<String> = ["sites", "fortigate", "inventaires"]

    // MARK: Propre à ce Mac

    /// Fichiers JSON jamais synchronisés (motif → raison).
    public static let localFiles: [(pattern: String, reason: String)] = [
        ("etat.json", "Plages et noms en cours de ce Mac"),
        ("disques-en-cours.json", "Travail en cours de ce Mac"),
        ("*.illisible-*", "Copie mise de côté"),
        ("*.autre-version-*", "Copie mise de côté"),
        ("*.avant-sites.json", "Copie de sécurité d’avant les sites"),
        ("wifi-signal.json", "Signal Wi-Fi seconde par seconde (historique brut)"),
        ("sites/*/wifi-signal.json", "Signal Wi-Fi seconde par seconde (historique brut)"),
        ("trafic-ports.json", "Trafic brut des ports (historique volumineux)"),
        ("journaux.json", "Journaux Syslog reçus par ce Mac"),
        ("diagnostics-wifi.json", "Diagnostics du Wi-Fi de ce Mac"),
        ("disques.json", "Mesures des disques de ce Mac"),
        ("ping-session.json", "Session de Ping en cours"),
        ("mtu.json", "Historique local de l’outil MTU"),
        ("tftp.json", "Serveur TFTP de ce Mac (dossier, interface)"),
        ("outils/*", "Historique local de la Boîte à outils"),
        ("rapports/index.json", "Rapports produits sur ce Mac"),
        ("rapports/suivi/*", "Rapports produits sur ce Mac"),
        ("Rapports/*", "Rapports produits sur ce Mac"),
        ("Inventaire/*", "Pièces jointes (pas du JSON de données)"),
    ]

    /// Préférences jamais synchronisées, en plus de celles que l'export laisse déjà
    /// (`ConfigPartRegistry.excludedPreferences` : sauvegarde, synchro, macOS).
    public static let localPreferences: [(pattern: String, reason: String)] = [
        ("*.onglet", "Onglet ouvert"),
        ("*.partie", "Partie d’écran ouverte"),
        ("*.periode", "Période affichée"),
        ("*.tri", "Tri affiché"),
        ("tableau.*", "Colonnes et tri des tableaux de ce Mac"),
        ("NetScope.trafic.source", "Source du trafic affichée"),
        ("NetScope.fortigate.actif", "FortiGate affichée"),
        ("NetScope.fortigate.migration", "Migration faite sur ce Mac"),
        ("NetScope.switchs.historique.*", "Historique affiché"),
        ("NetScope.wifi.historique", "Historique brut du Wi-Fi"),
        ("NetScope.oui.*", "Base des fabricants de ce Mac"),
        ("NetScope.flux.*", "Collecteur NetFlow de ce Mac"),
        ("NetScope.outils.voisin*", "Capture LLDP/CDP de ce Mac"),
        ("diagnostic.*", "Journal de l’app de ce Mac"),
        ("journaux.*", "Récepteur Syslog de ce Mac"),
        ("tftp.*", "Serveur TFTP de ce Mac"),
        ("acces.terminal.taille", "Taille de la fenêtre du terminal"),
        ("alertes.journal", "Journal des alertes envoyées par ce Mac"),
        ("sites-migration.*", "Migration faite sur ce Mac"),
        ("navigation.*", "Navigation de ce Mac"),
        ("reglages.majs.*", "Mises à jour de ce Mac (dernière vérification, versions installées)"),
    ]

    /// Fichiers et préférences synchronisés par les dossiers des sites (jamais dans le global).
    public static let siteHandledFiles = [SiteFiles.listName, SiteFiles.folderName + "/*"]
    public static let siteHandledPreferences = [ConfigCollection.fortiGates.key]

    /// Fichiers du dossier d'un site synchronisés avec lui.
    public static let siteFiles = [SiteFiles.inventoryName, SiteFiles.notesName, SiteFiles.resultsName,
                                   WifiRoomSurvey.fileName, TopoManualLayout.fileName]

    // MARK: Découpage des fichiers globaux

    /// Fichiers globaux découpés en éléments ; les autres se synchronisent en entier.
    public static let fileRules: [ConfigSyncFileRule] = [
        ConfigSyncFileRule(pattern: "connexions.json", label: "Carnet d’Accès distant",
                           lists: [ConfigSyncList(arrayKey: "connections", nameFields: ["name", "host"], elementLabel: "Connexion")]),
        ConfigSyncFileRule(pattern: "rustdesk.json", label: "RustDesk",
                           lists: [ConfigSyncList(arrayKey: "history", nameFields: ["name", "rustDeskID"], elementLabel: "Lancement RustDesk",
                                                  silentRemoval: true)]),
        // Compte du serveur synchronisé ; les mesures relevées par ce Mac restent ici.
        ConfigSyncFileRule(pattern: "rustdesk-serveur.json", label: "Serveur RustDesk", localKeys: ["samples", "samplesAccount"]),
        ConfigSyncFileRule(pattern: "identifiants.json", label: "Identifiants SSH et WMI",
                           lists: [ConfigSyncList(arrayKey: "credentials", nameFields: ["name", "username"], elementLabel: "Identifiant")]),
        // États des sondes, historique et journal : ce que CE Mac a mesuré, jamais envoyé.
        ConfigSyncFileRule(pattern: "surveillance.json", label: "Surveillance",
                           lists: [ConfigSyncList(arrayKey: "probes", nameFields: ["name", "target"], elementLabel: "Sonde")],
                           localKeys: ["trackers", "history", "journal"]),
        ConfigSyncFileRule(pattern: "rapports/planifies.json", label: "Rapports planifiés",
                           // Fichiers produits : chemins propres au Mac qui a produit le rapport.
                           lists: [ConfigSyncList(arrayKey: "schedules", volatileFields: ["lastFiles"], elementLabel: "Rapport planifié")]),
        ConfigSyncFileRule(pattern: "speedtest.json", label: "Historique Speedtest",
                           lists: [ConfigSyncList(arrayKey: "records", nameFields: ["serverName", "server"], elementLabel: "Mesure Speedtest",
                                                  silentRemoval: true)]),
        ConfigSyncFileRule(pattern: "appareils-saisis.json", label: "Appareils saisis à la main",
                           lists: [ConfigSyncList(arrayKey: "entries", nameFields: ["name", "ip"], elementLabel: "Appareil saisi")],
                           localKeys: ["recents"]),
    ]

    /// Libellés des fichiers globaux synchronisés en entier.
    static let fileLabels: [String: String] = [
        "ssh-utilisateurs.json": "Utilisateurs SSH retenus",
        "outils.json": "Boîte à outils",
        "services-en-ligne.json": "Services en ligne",
        "speedtest-planifie.json": "Speedtest planifié",
        "speedtest-serveurs.json": "Serveurs Speedtest",
        "bilans-raccordement.json": "Bilans de raccordement",
        "disques-emplacements.json": "Emplacements des disques",
        "emplacements-nas.json": "Emplacements NAS",
    ]

    public static func rule(for path: String) -> ConfigSyncFileRule? {
        fileRules.first { ConfigMatch.glob($0.pattern, path) }
    }

    // MARK: Classement

    /// Raison pour laquelle un fichier reste sur ce Mac ; nil s'il est synchronisé (par son site
    /// ou dans le global).
    public static func localReason(forFile path: String) -> String? {
        localFiles.first { ConfigMatch.glob($0.pattern, path) }?.reason
    }

    /// Vrai si le fichier va dans le dossier global (ni propre à ce Mac, ni d'un site).
    public static func isGlobalFile(_ path: String, registry: ConfigPartRegistry = .standard) -> Bool {
        guard registry.part(forFile: path) != nil, localReason(forFile: path) == nil else { return false }
        return !siteHandledFiles.contains { ConfigMatch.glob($0, path) }
    }

    public static func localReason(forPreference key: String) -> String? {
        localPreferences.first { ConfigMatch.glob($0.pattern, key) }?.reason
    }

    /// Vrai si la préférence va dans le dossier global.
    public static func isGlobalPreference(_ key: String, registry: ConfigPartRegistry = .standard) -> Bool {
        guard registry.part(forPreference: key) != nil, localReason(forPreference: key) == nil else { return false }
        return !siteHandledPreferences.contains(key)
    }

    /// Vrai si un secret voyage dans le dossier global (les jetons FortiGate voyagent avec leur site ;
    /// les mots de passe des sauvegardes et de la synchronisation, jamais).
    public static func isGlobalSecret(_ service: String) -> Bool {
        BackupKeychainScan.isOwnService(service) && !ConfigSecrets.neverCopied.contains(service)
            && service != BackupKeychainScan.servicePrefix + ".fortigate"
    }

    /// Vrai si le retrait d'un élément est publié aux autres Mac (pierre tombale) et leur est
    /// signalé. Jamais pour une préférence ni une FortiGate (qui suit la fiche de son site), ni
    /// pour un élément d'une liste d'historique élaguée toute seule.
    public static func signalsRemoval(ofKey key: String) -> Bool {
        switch ConfigSyncKey.parse(key) {
        case .preference, .fortiGate, .site, .other:
            return false
        case .element(let path, let arrayKey, _):
            return !(rule(for: path)?.lists.first { $0.arrayKey == arrayKey }?.silentRemoval ?? false)
        case .file, .document:
            return true
        }
    }

    /// Catégories refusées à la réception depuis un dossier partagé autre qu'iCloud Drive quand
    /// aucun mot de passe de synchronisation n'authentifie les fichiers des autres Mac.
    public static let sensitiveCategories: Set<String> = ["alertes", "acces", "identifiants", "surveillance", "fortigate"]

    /// Libellé lisible d'un fichier global.
    public static func label(forFile path: String) -> String {
        if let rule = rule(for: path) { return rule.label }
        if let label = fileLabels[path] { return label }
        let base = BackupEngine.label(for: path)
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}
