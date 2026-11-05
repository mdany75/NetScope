import Foundation

// Modèles de l'inventaire permanent : fiches d'appareils, événements, instantanés de scan.

/// Champs saisis par le technicien sur une fiche (jamais écrasés par un scan).
public struct InvAnnotations: Codable, Hashable, Sendable {
    public var customName: String?
    /// Type choisi à la main ; nil : type détecté par le scan.
    public var customType: DeviceType?
    public var tags: [String]
    public var location: String
    public var wallJack: String
    public var owner: String
    public var assetNumber: String
    public var notes: String
    public var isFavorite: Bool
    /// Fabricant saisi à la main (note 10 : appareil ajouté à la main) ; nil : celui du scan ou de l'OUI.
    /// Optionnel pour relire les fichiers d'avant la 0.20.0.
    public var customVendor: String?
    /// Fiche matériel : achat, garantie, fournisseur, numéro de série, prix (note 10, 0.20.0).
    public var hardware: InvHardware?

    public init(customName: String? = nil, customType: DeviceType? = nil, tags: [String] = [],
                location: String = "", wallJack: String = "", owner: String = "", assetNumber: String = "",
                notes: String = "", isFavorite: Bool = false, customVendor: String? = nil, hardware: InvHardware? = nil) {
        self.customName = customName
        self.customType = customType
        self.tags = tags
        self.location = location
        self.wallJack = wallJack
        self.owner = owner
        self.assetNumber = assetNumber
        self.notes = notes
        self.isFavorite = isFavorite
        self.customVendor = customVendor
        self.hardware = hardware
    }

    /// Libellés des champs qui diffèrent (pour la chronologie : « nom, local, notes »).
    public func changedFields(from old: InvAnnotations) -> [String] {
        var fields: [String] = []
        if (customName ?? "") != (old.customName ?? "") { fields.append("nom") }
        if customType != old.customType { fields.append("type") }
        if tags != old.tags { fields.append("étiquettes") }
        if location != old.location { fields.append("local") }
        if wallJack != old.wallJack { fields.append("prise") }
        if owner != old.owner { fields.append("responsable") }
        if assetNumber != old.assetNumber { fields.append("n° d’actif") }
        if notes != old.notes { fields.append("notes") }
        if (customVendor ?? "") != (old.customVendor ?? "") { fields.append("fabricant") }
        if (hardware ?? InvHardware()) != (old.hardware ?? InvHardware()) { fields.append("garantie") }
        return fields
    }
}

/// Période pendant laquelle un appareil a eu une adresse IP.
public struct InvIPSpan: Codable, Hashable, Sendable {
    public var ip: IPv4Address
    public var from: Date
    /// nil : adresse actuelle.
    public var to: Date?

    public init(ip: IPv4Address, from: Date, to: Date? = nil) {
        self.ip = ip
        self.from = from
        self.to = to
    }
}

/// Période pendant laquelle un appareil a été branché sur un port de switch.
public struct InvPortSpan: Codable, Hashable, Sendable {
    public var switchName: String
    public var port: String
    public var vlan: Int?
    public var from: Date
    public var to: Date?

    public init(switchName: String, port: String, vlan: Int? = nil, from: Date, to: Date? = nil) {
        self.switchName = switchName
        self.port = port
        self.vlan = vlan
        self.from = from
        self.to = to
    }

    public var label: String { "\(switchName) · \(port)" }
}

/// État d'une fiche, pour l'affichage.
public enum InvStatus: String, Codable, Sendable, CaseIterable {
    case enLigne, horsLigne, disparu, conflit

    public var label: String {
        switch self {
        case .enLigne: return "En ligne"
        case .horsLigne: return "Hors ligne"
        case .disparu: return "Disparu"
        case .conflit: return "Conflit IP"
        }
    }
}

/// Fiche permanente d'un appareil. Clé : « mac:aa:bb:… » si la MAC est connue, sinon « ip:a.b.c.d ».
public struct InvRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }

    public var key: String
    public var mac: MACAddress?
    /// Adresse IP actuelle (la dernière vue).
    public var ip: IPv4Address
    public var hostname: String?
    public var vendor: String?
    public var detectedType: DeviceType
    public var isOnline: Bool
    public var latencyMs: Double?
    public var openPorts: [UInt16]
    public var switchName: String?
    public var switchPort: String?
    public var vlan: Int?
    public var rangeLabel: String?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Moment où l'appareil a cessé de répondre.
    public var offlineSince: Date?
    /// Autres MAC vues sur la même IP : non vide tant qu'un conflit est actif.
    public var conflictWith: [MACAddress]
    public var annotations: InvAnnotations
    public var ipHistory: [InvIPSpan]
    public var portHistory: [InvPortSpan]
    /// Fiche créée par un import CSV, jamais vue par un scan.
    public var isImported: Bool
    /// Appareil ajouté à la main (note 10) ; nil : vu par un scan ou importé. Optionnel (fichiers
    /// d'avant la 0.20.0).
    public var manual: InvManualEntry?
    /// Pièces jointes (factures, contrats, photos), copiées dans
    /// Application Support/NetScope/Inventaire/<site>/<dossier>/ (voir InvHardware.swift).
    public var attachments: [InvAttachment]?
    /// Dossier des pièces jointes, choisi à la première pièce et gardé ensuite (la clé de la fiche
    /// change quand une MAC apparaît, le dossier non).
    public var attachmentFolder: String?

    public init(key: String, mac: MACAddress?, ip: IPv4Address, hostname: String? = nil, vendor: String? = nil,
                detectedType: DeviceType = .inconnu, isOnline: Bool = true, latencyMs: Double? = nil,
                openPorts: [UInt16] = [], switchName: String? = nil, switchPort: String? = nil, vlan: Int? = nil,
                rangeLabel: String? = nil, firstSeen: Date, lastSeen: Date, offlineSince: Date? = nil,
                conflictWith: [MACAddress] = [], annotations: InvAnnotations = InvAnnotations(),
                ipHistory: [InvIPSpan] = [], portHistory: [InvPortSpan] = [], isImported: Bool = false,
                manual: InvManualEntry? = nil) {
        self.key = key
        self.mac = mac
        self.ip = ip
        self.hostname = hostname
        self.vendor = vendor
        self.detectedType = detectedType
        self.isOnline = isOnline
        self.latencyMs = latencyMs
        self.openPorts = openPorts
        self.switchName = switchName
        self.switchPort = switchPort
        self.vlan = vlan
        self.rangeLabel = rangeLabel
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.offlineSince = offlineSince
        self.conflictWith = conflictWith
        self.annotations = annotations
        self.ipHistory = ipHistory
        self.portHistory = portHistory
        self.isImported = isImported
        self.manual = manual
    }

    /// Nom à afficher : nom saisi, sinon nom d'hôte, sinon l'IP (sinon la MAC, pour un appareil
    /// ajouté à la main sans adresse).
    public var displayName: String {
        if let name = annotations.customName, !name.isEmpty { return name }
        if let name = hostname, !name.isEmpty { return name }
        if !hasAddress { return mac?.formatted(.upperColon) ?? "Appareil sans adresse" }
        return ip.description
    }

    /// Faux pour un appareil ajouté à la main sans adresse IP (matériel en stock, hors réseau) :
    /// son adresse vaut alors 0.0.0.0, jamais vue par un scan.
    public var hasAddress: Bool { ip.value != 0 }

    /// « 10.0.0.5 », ou « — » sans adresse.
    public var addressLabel: String { hasAddress ? ip.description : "—" }

    /// Ajouté à la main (rapproché ou non d'un appareil scanné depuis).
    public var isManual: Bool { manual != nil }

    /// Ajouté à la main et jamais vu par un scan depuis.
    public var isAwaitingScan: Bool { manual != nil && manual?.matched == nil }

    public var attachmentList: [InvAttachment] { attachments ?? [] }

    public var type: DeviceType { annotations.customType ?? detectedType }

    public var vendorLabel: String {
        if let custom = annotations.customVendor, !custom.isEmpty { return custom }
        if let vendor, !vendor.isEmpty { return vendor }
        guard let mac else { return OUIDatabase.unknownLabel }
        return OUIDatabase.builtIn.label(for: mac)
    }

    /// MAC aléatoire, ou ni fabricant ni nom saisi : un technicien doit confirmer la fiche.
    public var isUnidentified: Bool {
        if let name = annotations.customName, !name.isEmpty { return false }
        if isManual { return false }
        guard let mac else { return true }
        if mac.isRandomized { return true }
        return (vendor ?? "").isEmpty && OUIDatabase.builtIn.vendor(for: mac) == nil
    }

    public var hasConflict: Bool { !conflictWith.isEmpty }

    public var switchLocation: String? {
        switch (switchName, switchPort) {
        case let (name?, port?): return "\(name) · \(port)"
        case let (name?, nil): return name
        case let (nil, port?): return port
        default: return nil
        }
    }

    /// Hors ligne depuis plus de `days` jours.
    /// Un appareil ajouté à la main et jamais scanné n'est pas « disparu ».
    public func isGone(now: Date = Date(), days: Double = 30) -> Bool {
        !isOnline && !isAwaitingScan && now.timeIntervalSince(lastSeen) > days * 86_400
    }

    public func status(now: Date = Date()) -> InvStatus {
        if hasConflict { return .conflit }
        if isOnline { return .enLigne }
        return isGone(now: now) ? .disparu : .horsLigne
    }

    /// Recherche multiple (champs de l'Inventaire) : IP, MAC, noms, fabricant, étiquettes, local,
    /// prise… ; un mot seul lit les mêmes colonnes qu'avant.
    public func matches(_ query: String) -> Bool {
        matchesSearch(query)
    }
}

// MARK: - Événements

public enum InvEventKind: String, Codable, Sendable, CaseIterable {
    case nouveau, changementIP, changementPort, horsLigne, retour, conflitIP, fiche, fusion, importCSV
    /// Serveur DHCP non autorisé signalé depuis le Test DHCP de la Boîte à outils.
    case dhcpNonAutorise

    /// Libellé court de la chronologie.
    public var label: String {
        switch self {
        case .nouveau: return "Détection"
        case .changementIP: return "Adresse IP"
        case .changementPort: return "Port de switch"
        case .horsLigne, .retour: return "Disponibilité"
        case .conflitIP: return "Conflit IP"
        case .fiche, .fusion: return "Fiche"
        case .importCSV: return "Import"
        case .dhcpNonAutorise: return "Serveur DHCP"
        }
    }

    /// Événement à présenter comme une alerte (les modifications de fiche n'en sont pas).
    public var isAlert: Bool {
        switch self {
        case .fiche, .fusion, .importCSV: return false
        default: return true
        }
    }
}

public enum InvSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case critique, alerte, info

    public var label: String {
        switch self {
        case .critique: return "Critique"
        case .alerte: return "Alerte"
        case .info: return "Info"
        }
    }

    private var rank: Int {
        switch self {
        case .critique: return 0
        case .alerte: return 1
        case .info: return 2
        }
    }

    public static func < (lhs: InvSeverity, rhs: InvSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// Traitement d'une alerte par le technicien.
public enum InvEventStatus: String, Codable, Sendable {
    case aTraiter, accepte, ignore
}

public struct InvEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: InvEventKind
    public var severity: InvSeverity
    /// Fiche concernée.
    public var key: String
    public var ip: IPv4Address
    public var title: String
    public var detail: String
    /// Vrai pour les événements du tout premier scan (référence) : ce ne sont pas des alertes.
    public var baseline: Bool
    public var status: InvEventStatus
    public var statusDate: Date?

    public init(id: UUID = UUID(), date: Date, kind: InvEventKind, severity: InvSeverity, key: String,
                ip: IPv4Address, title: String, detail: String, baseline: Bool = false,
                status: InvEventStatus = .aTraiter, statusDate: Date? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.severity = severity
        self.key = key
        self.ip = ip
        self.title = title
        self.detail = detail
        self.baseline = baseline
        self.status = status
        self.statusDate = statusDate
    }

    /// Alerte affichée dans l'écran Analyse.
    public var isAlert: Bool { kind.isAlert && !baseline }
}

// MARK: - Instantanés de scan

/// Résumé d'un appareil dans un instantané (assez pour comparer deux scans).
public struct InvSnapshotEntry: Codable, Hashable, Sendable {
    public var key: String
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var name: String
    public var isOnline: Bool
    public var switchLocation: String?
    public var vlan: Int?
    public var openPorts: [UInt16]

    public init(key: String, ip: IPv4Address, mac: MACAddress?, name: String, isOnline: Bool,
                switchLocation: String?, vlan: Int?, openPorts: [UInt16]) {
        self.key = key
        self.ip = ip
        self.mac = mac
        self.name = name
        self.isOnline = isOnline
        self.switchLocation = switchLocation
        self.vlan = vlan
        self.openPorts = openPorts
    }
}

public struct InvSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var entries: [InvSnapshotEntry]

    public init(id: UUID = UUID(), date: Date, entries: [InvSnapshotEntry]) {
        self.id = id
        self.date = date
        self.entries = entries
    }

    public var total: Int { entries.count }
    public var onlineCount: Int { entries.filter(\.isOnline).count }
}

/// Une ligne de comparaison entre deux scans.
public struct InvDiffRow: Hashable, Sendable, Identifiable {
    public var id: String { key + "|" + before + "|" + after }
    public var key: String
    public var ip: IPv4Address
    public var name: String
    public var mac: String
    public var before: String
    public var after: String
}

public struct InvDiff: Hashable, Sendable {
    public var added: [InvDiffRow] = []
    public var removed: [InvDiffRow] = []
    public var modified: [InvDiffRow] = []

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }
}

/// Deux fiches qui désignent probablement le même appareil (ex. Wi-Fi et Ethernet d'un même Mac).
public struct InvDuplicate: Hashable, Sendable, Identifiable {
    public var id: String { keep + "+" + absorb }
    /// Fiche conservée (la plus récente).
    public var keep: String
    /// Fiche à rattacher.
    public var absorb: String
    public var reason: String
}

/// Quelles fiches absentes d'un scan doivent passer hors ligne.
public enum InvCoverage: Sendable {
    /// Aucune : seules les indications `isOnline` des appareils reçus comptent.
    case none
    /// Les /24 des appareils reçus.
    case subnetsOfIncoming
    /// Les plages effectivement scannées.
    case ranges([IPRange])
}

// MARK: - Mise en forme

public enum InvFormat {
    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = pattern
        return formatter
    }

    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let timeFormatter = formatter("HH:mm")
    private static let stampFormatter = formatter("yyyy-MM-dd HH:mm")

    /// « 2026-03-12 »
    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// « 08:42 »
    public static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    /// « 2026-03-12 08:42 »
    public static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
    public static func parseStamp(_ text: String) -> Date? {
        stampFormatter.date(from: text) ?? dayFormatter.date(from: text)
    }

    /// « 23 min », « 3 h », « 12 j ».
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "moins d’une minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return "\(hours) h" }
        return "\(Int((seconds / 86_400).rounded())) j"
    }

    /// « À l’instant », « Il y a 3 min », « Il y a 2 h », « 2026-08-14 (81 j) ».
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "À l’instant" }
        if seconds < 3600 { return "Il y a \(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "Il y a \(Int((seconds / 3600).rounded())) h" }
        return "\(day(date)) (\(Int((seconds / 86_400).rounded())) j)"
    }

    /// « Maintenant » pour un appareil en ligne vu il y a moins de 10 min, sinon `relative` :
    /// un appareil en ligne au scan d'un autre jour (autre site) n'est pas « vu maintenant ».
    public static func seen(_ date: Date, online: Bool, now: Date = Date()) -> String {
        online && now.timeIntervalSince(date) < 600 ? "Maintenant" : relative(date, now: now)
    }

    /// Heure seule le jour même, sinon date et heure : « 08:42 », « 2026-11-02 11:43 ».
    public static func timeOrStamp(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time(date) : stamp(date)
    }

    /// Écrit « .87 → .111 » quand les deux adresses partagent leurs trois premiers octets.
    public static func ipChange(_ old: IPv4Address, _ new: IPv4Address) -> String {
        if old.value >> 8 == new.value >> 8 {
            return ".\(old.octets.3) → .\(new.octets.3)"
        }
        return "\(old) → \(new)"
    }
}
