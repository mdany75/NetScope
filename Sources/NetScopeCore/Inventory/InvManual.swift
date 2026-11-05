import Foundation

// Note 10 (Inventaire, phase 3) : appareils ajoutés à la main, absents des scans (imprimante hors
// réseau, équipement éteint, matériel en stock). La fiche porte la clé « man:<uuid> » tant qu'aucun
// scan ne l'a vue ; elle est marquée « Ajouté à la main ».
//
// Rapprochement : quand un scan DU MÊME SITE (l'inventaire est propre au site) voit un appareil qui
// n'a pas encore de fiche, la fiche ajoutée à la main qui lui correspond devient la sienne : même MAC
// d'abord, sinon même adresse IP (si l'une des deux MAC est inconnue). La fiche prend alors la clé du
// scan (« mac:… » ou « ip:… ») ; les champs saisis (nom, type, fabricant, local, prise, responsable,
// notes, garantie) sont gardés, le scan ne fait que compléter les champs observés.

/// Origine « ajouté à la main » d'une fiche.
public struct InvManualEntry: Codable, Hashable, Sendable {
    public var created: Date
    /// Rapprochée d'un appareil scanné à cette date ; nil : jamais vue par un scan.
    public var matched: Date?

    public init(created: Date, matched: Date? = nil) {
        self.created = created
        self.matched = matched
    }
}

/// Champs du formulaire « Ajouter un appareil » (et « Modifier » d'une fiche ajoutée à la main).
public struct InvManualDraft: Hashable, Sendable {
    public var name: String
    public var ip: IPv4Address?
    public var mac: MACAddress?
    public var vendor: String
    public var type: DeviceType
    public var location: String
    public var wallJack: String
    public var switchName: String
    public var switchPort: String
    public var owner: String
    public var assetNumber: String
    public var notes: String
    public var tags: [String]

    public init(name: String = "", ip: IPv4Address? = nil, mac: MACAddress? = nil, vendor: String = "",
                type: DeviceType = .inconnu, location: String = "", wallJack: String = "", switchName: String = "",
                switchPort: String = "", owner: String = "", assetNumber: String = "", notes: String = "",
                tags: [String] = []) {
        self.name = name
        self.ip = ip
        self.mac = mac
        self.vendor = vendor
        self.type = type
        self.location = location
        self.wallJack = wallJack
        self.switchName = switchName
        self.switchPort = switchPort
        self.owner = owner
        self.assetNumber = assetNumber
        self.notes = notes
        self.tags = tags
    }

    /// Brouillon tiré d'une fiche (Modifier, Dupliquer).
    public init(record: InvRecord) {
        self.init(name: record.annotations.customName ?? record.hostname ?? "",
                  ip: record.hasAddress ? record.ip : nil, mac: record.mac,
                  vendor: record.annotations.customVendor ?? record.vendor ?? "",
                  type: record.type, location: record.annotations.location, wallJack: record.annotations.wallJack,
                  switchName: record.switchName ?? "", switchPort: record.switchPort ?? "",
                  owner: record.annotations.owner, assetNumber: record.annotations.assetNumber,
                  notes: record.annotations.notes, tags: record.annotations.tags)
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Il faut au moins un nom, une IP ou une MAC pour reconnaître l'appareil.
    public var isUsable: Bool { !Self.trimmed(name).isEmpty || ip != nil || mac != nil }
}

/// Refus d'un ajout ou d'une modification à la main.
public enum InvManualError: Error, Equatable, LocalizedError {
    /// Ni nom, ni IP, ni MAC.
    case empty
    /// Une fiche de ce site a déjà cette MAC (clé et nom de la fiche).
    case duplicateMAC(key: String, name: String)
    /// Un appareil archivé de ce site a cette MAC : le restaurer plutôt.
    case archivedMAC(key: String, name: String)
    /// Fiche introuvable, ou fiche vue par un scan (son IP et sa MAC viennent du scan).
    case notEditable

    public var errorDescription: String? {
        switch self {
        case .empty: return "Indiquez au moins un nom, une adresse IP ou une adresse MAC."
        case .duplicateMAC(_, let name): return "Cette MAC est déjà dans l’inventaire du site («\u{00A0}\(name)\u{00A0}»)."
        case .archivedMAC(_, let name): return "Cette MAC est celle d’un appareil archivé («\u{00A0}\(name)\u{00A0}»)\u{00A0}: restaurez-le plutôt."
        case .notEditable: return "Seule une fiche ajoutée à la main et pas encore vue par un scan peut changer d’IP ou de MAC."
        }
    }
}

public extension InventoryStore {
    /// Préfixe des clés des fiches ajoutées à la main pas encore rapprochées.
    static let manualPrefix = "man:"

    /// Fiches ajoutées à la main, pas encore vues par un scan.
    var awaitingScan: [InvRecord] { records.values.filter(\.isAwaitingScan).sorted { $0.key < $1.key } }

    /// Fiche d'un autre appareil qui a déjà cette IP (avertissement du formulaire, jamais un refus :
    /// une adresse est souvent reprise). `except` : la fiche modifiée.
    func recordUsingIP(_ ip: IPv4Address, except key: String? = nil) -> InvRecord? {
        records.values.filter { $0.ip == ip && $0.key != key }.max { $0.lastSeen < $1.lastSeen }
    }

    /// Crée une fiche « Ajouté à la main » ; renvoie sa clé.
    @discardableResult
    mutating func addManual(_ draft: InvManualDraft, at date: Date = Date(), id: UUID = UUID()) throws -> String {
        try checkManual(draft, except: nil)
        let key = Self.manualPrefix + id.uuidString.lowercased()
        let ip = draft.ip ?? IPv4Address(0)
        var record = InvRecord(key: key, mac: draft.mac, ip: ip, detectedType: .inconnu, isOnline: false,
                               firstSeen: date, lastSeen: date, ipHistory: draft.ip.map { [InvIPSpan(ip: $0, from: date)] } ?? [],
                               manual: InvManualEntry(created: date))
        apply(draft, to: &record, at: date)
        liftExclusions(for: record)
        records[key] = record
        events.append(InvEvent(date: date, kind: .fiche, severity: .info, key: key, ip: ip,
                               title: "Ajouté à la main",
                               detail: "Fiche créée à la main" + (record.hasAddress ? " · \(record.ip)" : " · sans adresse IP")
                                   + (record.mac.map { " · MAC \($0.formatted(.upperColon))" } ?? "")))
        return key
    }

    /// Modifie une fiche ajoutée à la main pas encore vue par un scan (tous ses champs).
    /// Une fiche rapprochée garde l'IP et la MAC du scan : seuls ses champs saisis changent.
    mutating func updateManual(_ key: String, with draft: InvManualDraft, at date: Date = Date()) throws {
        guard var record = records[key], record.isManual else { throw InvManualError.notEditable }
        if !record.isAwaitingScan {
            // Rapprochée : l'IP, la MAC et le port viennent des scans.
            guard draft.ip == (record.hasAddress ? record.ip : nil), draft.mac == record.mac else {
                throw InvManualError.notEditable
            }
        }
        try checkManual(draft, except: key)
        let old = record.annotations
        if record.isAwaitingScan {
            let newIP = draft.ip ?? IPv4Address(0)
            if newIP != record.ip {
                record.ip = newIP
                record.ipHistory = draft.ip.map { [InvIPSpan(ip: $0, from: date)] } ?? []
            }
            record.mac = draft.mac
        }
        apply(draft, to: &record, at: date)
        records[key] = record
        let changed = record.annotations.changedFields(from: old)
        events.append(InvEvent(date: date, kind: .fiche, severity: .info, key: key, ip: record.ip,
                               title: "Fiche modifiée",
                               detail: changed.isEmpty ? "Adresse, MAC ou port de switch mis à jour"
                                   : "Champs mis à jour : " + changed.joined(separator: ", ")))
    }

    /// Duplique une fiche (n'importe laquelle) en appareil ajouté à la main : mêmes champs saisis,
    /// sans IP ni MAC (deux appareils n'ont pas la même), nom suivi de « (copie) ».
    @discardableResult
    mutating func duplicate(_ key: String, at date: Date = Date(), id: UUID = UUID()) -> String? {
        guard let source = records[key] else { return nil }
        var draft = InvManualDraft(record: source)
        draft.ip = nil
        draft.mac = nil
        draft.name = (draft.name.isEmpty ? source.displayName : draft.name) + " (copie)"
        guard let newKey = try? addManual(draft, at: date, id: id) else { return nil }
        // La garantie n'est pas copiée (autre numéro de série) ; le reste des champs saisis l'est.
        records[newKey]?.annotations.isFavorite = false
        return newKey
    }

    private func checkManual(_ draft: InvManualDraft, except key: String?) throws {
        guard draft.isUsable else { throw InvManualError.empty }
        if let mac = draft.mac {
            if let other = records.values.first(where: { $0.mac == mac && $0.key != key }) {
                throw InvManualError.duplicateMAC(key: other.key, name: other.displayName)
            }
            if let archived = (archive ?? [:]).values.first(where: { $0.record.mac == mac }) {
                throw InvManualError.archivedMAC(key: archived.record.key, name: archived.record.displayName)
            }
        }
    }

    private func apply(_ draft: InvManualDraft, to record: inout InvRecord, at date: Date) {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var notes = record.annotations
        let name = clean(draft.name)
        notes.customName = name.isEmpty ? nil : name
        notes.customType = draft.type == .inconnu ? nil : draft.type
        let vendor = clean(draft.vendor)
        notes.customVendor = vendor.isEmpty ? nil : vendor
        notes.location = clean(draft.location)
        notes.wallJack = clean(draft.wallJack)
        notes.owner = clean(draft.owner)
        notes.assetNumber = clean(draft.assetNumber)
        notes.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        for tag in draft.tags.map(clean) where !tag.isEmpty && !tags.contains(where: { $0.lowercased() == tag.lowercased() }) {
            tags.append(tag)
        }
        notes.tags = tags
        record.annotations = notes
        // Switch et port : saisis pour une fiche jamais scannée ; ensuite, ils viennent des scans.
        if record.isAwaitingScan {
            let switchName = clean(draft.switchName)
            let port = clean(draft.switchPort)
            let newSwitch = switchName.isEmpty ? nil : switchName
            let newPort = port.isEmpty ? nil : port
            if newSwitch != record.switchName || newPort != record.switchPort {
                record.switchName = newSwitch
                record.switchPort = newPort
                if let newSwitch, let newPort {
                    record.portHistory = [InvPortSpan(switchName: newSwitch, port: newPort, from: date)]
                } else {
                    record.portHistory = []
                }
            }
        }
    }

    // MARK: Rapprochement

    /// Fiche ajoutée à la main qui correspond à un appareil du scan sans fiche : même MAC, sinon
    /// même IP (quand l'une des deux MAC est inconnue). Nil si l'appareil a déjà sa fiche.
    func manualMatch(for device: Device) -> String? {
        manualMatch(for: device, among: records.values.filter(\.isAwaitingScan))
    }

    /// Même chose parmi des fiches en attente déjà relevées (fusion d'un gros scan : relevées une fois).
    internal func manualMatch(for device: Device, among waiting: [InvRecord]) -> String? {
        guard !waiting.isEmpty else { return nil }
        if let mac = device.mac {
            if let byMAC = waiting.filter({ $0.mac == mac }).min(by: { $0.key < $1.key }) { return byMAC.key }
            // L'appareil a déjà une fiche (par sa MAC, ou par IP sans MAC que la fusion lui rattachera).
            if records[Self.key(mac: mac)] != nil { return nil }
            if let old = records[Self.key(ip: device.ip)], old.mac == nil { return nil }
        } else if existingKey(for: device) != nil {
            return nil
        }
        return waiting.filter { $0.hasAddress && $0.ip == device.ip && ($0.mac == nil || device.mac == nil) }
            .min { ($0.manual?.created ?? .distantPast, $0.key) < ($1.manual?.created ?? .distantPast, $1.key) }?.key
    }

    /// Rapproche la fiche ajoutée à la main `manualKey` de l'appareil scanné : elle prend la clé du
    /// scan, sa MAC et son adresse ; ses champs saisis restent. Renvoie la nouvelle clé (nil : rien fait).
    @discardableResult
    mutating func adoptManual(_ manualKey: String, for device: Device, at date: Date = Date()) -> String? {
        guard var record = records[manualKey], record.isAwaitingScan else { return nil }
        let newKey = device.mac.map { Self.key(mac: $0) } ?? record.mac.map { Self.key(mac: $0) } ?? Self.key(ip: device.ip)
        guard newKey == manualKey || records[newKey] == nil else { return nil }
        let byMAC = device.mac != nil && record.mac == device.mac
        records[manualKey] = nil
        record.key = newKey
        if record.mac == nil { record.mac = device.mac }
        if !record.hasAddress {
            record.ip = device.ip
            record.ipHistory = [InvIPSpan(ip: device.ip, from: date)]
        }
        // Rien n'est « de retour en ligne » : l'appareil n'avait jamais été vu.
        record.isOnline = device.isOnline
        record.offlineSince = nil
        record.manual?.matched = date
        record.firstSeen = min(record.firstSeen, date)
        records[newKey] = record
        for index in events.indices where events[index].key == manualKey { events[index].key = newKey }
        events.append(InvEvent(date: date, kind: .fiche, severity: .info, key: newKey, ip: device.ip,
                               title: "Rapproché d’un appareil scanné",
                               detail: "Ajouté à la main le \(InvFormat.day(record.manual?.created ?? date)), reconnu "
                                   + (byMAC ? "par sa MAC" : "par son adresse IP \(device.ip)")
                                   + " · champs saisis conservés"))
        return newKey
    }
}
