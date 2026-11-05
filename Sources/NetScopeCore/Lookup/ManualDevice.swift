import Foundation

// Écran Appareil : appareils ouverts sans être dans les résultats du Scanner. Saisis à la main
// (IP, nom, MAC, type, notes), ou repris d'une fiche d'inventaire ou d'un autre site. Ils restent
// à part des résultats du Scanner ; quand un scan voit le même appareil (même MAC, sinon même IP
// si l'une des deux MAC est inconnue), la saisie lui est rattachée : le nom saisi devient son nom
// personnalisé (s'il n'en a pas déjà un) et la saisie disparaît.

/// Un appareil ouvert dans l'écran Appareil sans être dans les résultats du Scanner.
public struct ManualDeviceEntry: Codable, Hashable, Identifiable, Sendable {
    /// D'où vient la fiche.
    public enum Source: Codable, Hashable, Sendable {
        /// Saisie à la main.
        case typed
        /// Fiche d'inventaire de ce site (nom du site).
        case inventory(site: String)
        /// Résultats enregistrés d'un autre site (nom du site).
        case otherSite(String)
    }

    /// Résultat de « Vérifier maintenant » (ping unique, sur clic).
    public struct Check: Codable, Hashable, Sendable {
        public var date: Date
        /// Latence en millisecondes ; nil : pas de réponse.
        public var latencyMs: Double?

        public init(date: Date, latencyMs: Double?) {
            self.date = date
            self.latencyMs = latencyMs
        }

        public var isOnline: Bool { latencyMs != nil }
    }

    public var id: UUID
    public var ip: IPv4Address
    public var mac: MACAddress?
    /// Nom donné (vide : nom d'hôte, sinon l'adresse).
    public var name: String
    /// Nom DNS saisi (résolu sur demande), s'il y en a un.
    public var hostname: String?
    public var type: DeviceType
    public var created: Date
    public var source: Source
    /// Appareil repris tel quel (fiche d'inventaire, autre site) : emplacement, ports, dates.
    public var base: Device?
    public var lastCheck: Check?

    public init(id: UUID = UUID(), ip: IPv4Address, mac: MACAddress? = nil, name: String = "", hostname: String? = nil,
                type: DeviceType = .inconnu, created: Date = Date(), source: Source = .typed, base: Device? = nil,
                lastCheck: Check? = nil) {
        self.id = id
        self.ip = ip
        self.mac = mac
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostname = hostname.flatMap { $0.isEmpty ? nil : $0 }
        self.type = type
        self.created = created
        self.source = source
        self.base = base
        self.lastCheck = lastCheck
    }

    /// Fiche reprise d'un appareil connu ailleurs (inventaire, autre site).
    public init(reference device: Device, source: Source, created: Date = Date()) {
        self.init(ip: device.ip, mac: device.mac, name: device.customName ?? "", hostname: device.hostname,
                  type: device.deviceType, created: created, source: source, base: device)
    }

    /// Identifiant de la fiche dans l'écran Appareil (le même que celui d'un appareil scanné : l'IP).
    public var deviceID: String { ip.description }

    public var isTyped: Bool { source == .typed }

    /// L'appareil affiché par la fiche. Jamais vérifié : hors ligne, « vu » à la date de la saisie.
    public var device: Device {
        var device = base ?? Device(ip: ip, isOnline: false, firstSeen: created, lastSeen: created)
        device.ip = ip
        if let mac { device.mac = mac }
        if let hostname { device.hostname = hostname }
        if !name.isEmpty { device.customName = name }
        device.deviceType = type
        if let lastCheck {
            device.isOnline = lastCheck.isOnline
            device.latencyMs = lastCheck.latencyMs
            if lastCheck.isOnline { device.lastSeen = max(device.lastSeen, lastCheck.date) }
        } else if base == nil {
            device.isOnline = false
            device.latencyMs = nil
        }
        return device
    }

    /// Ligne d'origine affichée sur la fiche.
    public var originLabel: String {
        switch source {
        case .typed:
            return "Saisi à la main · pas encore vu par un scan"
        case .inventory(let site):
            return "Fiche d’inventaire de «\u{00A0}\(site)\u{00A0}» · absente des résultats du Scanner"
        case .otherSite(let site):
            return "Résultat du site «\u{00A0}\(site)\u{00A0}» · pas dans le site actif"
        }
    }
}

/// Rattachement d'une saisie à l'appareil qu'un scan a vu.
public struct ManualDeviceAttachment: Hashable, Sendable {
    public var entry: ManualDeviceEntry
    /// Identifiant de l'appareil scanné (son IP, qui peut différer de celle saisie si la MAC concorde).
    public var deviceID: String
    /// Nom personnalisé à donner à l'appareil scanné (il n'en avait pas) ; nil : rien à changer.
    public var customName: String?
    /// Nom saisi qui n'a pas pu devenir le nom de l'appareil (il en avait déjà un) : à garder dans ses notes.
    public var nameForNotes: String?
}

public enum ManualDevices {
    /// Nombre de saisies gardées (les plus récentes).
    public static let keptCount = 20

    /// L'appareil scanné qui correspond à la saisie : même MAC d'abord ; sinon même IP, si l'une des
    /// deux MAC est inconnue. Une reprise d'un autre site ne se rattache que par la MAC.
    public static func match(_ entry: ManualDeviceEntry, in devices: [Device]) -> Device? {
        if let mac = entry.mac, let device = devices.first(where: { $0.mac == mac }) { return device }
        if case .otherSite = entry.source { return nil }
        return devices.first { $0.ip == entry.ip && (entry.mac == nil || $0.mac == nil) }
    }

    /// Rattachements à faire après un scan (une saisie, un appareil) et saisies qui restent.
    public static func attach(_ entries: [ManualDeviceEntry], to devices: [Device])
        -> (attached: [ManualDeviceAttachment], remaining: [ManualDeviceEntry]) {
        var attached: [ManualDeviceAttachment] = []
        var remaining: [ManualDeviceEntry] = []
        var taken = Set<String>()
        for entry in entries {
            guard let device = match(entry, in: devices), !taken.contains(device.id) else {
                remaining.append(entry)
                continue
            }
            taken.insert(device.id)
            let typed = entry.name
            let existing = device.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var attachment = ManualDeviceAttachment(entry: entry, deviceID: device.id)
            if !typed.isEmpty {
                if existing.isEmpty { attachment.customName = typed }
                else if existing.compare(typed, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                    attachment.nameForNotes = typed
                }
            }
            attached.append(attachment)
        }
        return (attached, remaining)
    }

    /// Ajoute ou remplace une saisie (même IP : la nouvelle remplace l'ancienne), la plus récente
    /// d'abord, au plus `keptCount`.
    public static func upsert(_ entry: ManualDeviceEntry, into entries: [ManualDeviceEntry]) -> [ManualDeviceEntry] {
        var list = entries.filter { $0.ip != entry.ip && $0.id != entry.id }
        list.insert(entry, at: 0)
        return Array(list.prefix(keptCount))
    }

    /// Notes reprises lors d'un rattachement : celles de l'appareil scanné, puis celles de la saisie
    /// (et le nom saisi qui n'a pas pu devenir son nom), sans doublon.
    public static func mergedNotes(scanned: String, typed: String, nameForNotes: String?) -> String {
        var parts: [String] = []
        let existing = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { parts.append(existing) }
        if !added.isEmpty, !existing.contains(added) { parts.append(added) }
        if let nameForNotes, !nameForNotes.isEmpty {
            let line = "Nom saisi à la main\u{00A0}: \(nameForNotes)"
            if !existing.contains(line) { parts.append(line) }
        }
        return parts.joined(separator: "\n")
    }
}

/// Un appareil consulté dans l'écran Appareil (liste « Consultés récemment »).
public struct DeviceRecentView: Codable, Hashable, Identifiable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var name: String
    public var type: DeviceType
    public var viewed: Date
    /// Fiche saisie à la main ou reprise (pas dans les résultats du Scanner) au moment de la visite.
    public var isManual: Bool

    public init(ip: IPv4Address, mac: MACAddress? = nil, name: String, type: DeviceType, viewed: Date, isManual: Bool = false) {
        self.ip = ip
        self.mac = mac
        self.name = name
        self.type = type
        self.viewed = viewed
        self.isManual = isManual
    }

    public init(device: Device, viewed: Date, isManual: Bool = false) {
        self.init(ip: device.ip, mac: device.mac, name: device.displayName, type: device.deviceType,
                  viewed: viewed, isManual: isManual)
    }

    public var id: String { mac.map { "mac|\($0)" } ?? "ip|\(ip)" }
}

public enum DeviceRecents {
    public static let keptCount = 8

    /// Retient une visite : la plus récente d'abord, une seule fois par appareil (même MAC, sinon même IP).
    public static func record(_ view: DeviceRecentView, in list: [DeviceRecentView],
                              limit: Int = keptCount) -> [DeviceRecentView] {
        var kept = list.filter { other in
            if let mac = view.mac, let otherMAC = other.mac { return mac != otherMAC }
            return other.ip != view.ip
        }
        kept.insert(view, at: 0)
        return Array(kept.prefix(max(0, limit)))
    }
}
