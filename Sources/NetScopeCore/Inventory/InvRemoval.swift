import Foundation

// Suppression d'appareils de l'inventaire (demande de Dany, 0.12.0) : un ou plusieurs appareils,
// d'un seul site à la fois (l'inventaire est propre au site). La suppression suit le modèle de
// `removeRecord` : la fiche ET ses événements (chronologie, alertes de l'Analyse) sont retirés ;
// les instantanés de scan (comparaison de deux scans, courbe des appareils en ligne) restent, car
// ils décrivent ce que les scans ont vu ce jour-là. Tout ce qui est retiré est rendu dans
// `InvRemoval` : « Annuler » (⌘Z) le remet exactement.
//
// « Ne plus suivre ces appareils » ajoute chaque appareil à la liste d'exclusion du site : un
// prochain scan ne le remet pas dans l'inventaire (par sa MAC ; sans MAC connue, par son adresse).
// Un appareil exclu reste pris en compte pour détecter les conflits IP et les adresses reprises :
// seule sa fiche n'est ni créée ni mise à jour.
//
// Sans « Ne plus suivre », l'appareil revient quand un scan le revoit APRÈS la suppression
// (`InvRemoval.holds` : les résultats déjà affichés dans le Scanner ne le remettent pas). S'il est
// revenu avant l'annulation, l'annulation remet sa fiche d'avant (notes, nom, historique) dans la
// fiche recréée.

/// Appareil qu'on ne suit plus : un scan ne le remet pas dans l'inventaire du site.
public struct InvExclusion: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    /// Clé de la fiche supprimée (« mac:… » ou « ip:… »).
    public var key: String
    public var mac: MACAddress?
    public var ip: IPv4Address
    /// Nom de la fiche au moment de la suppression.
    public var name: String
    public var date: Date

    public init(key: String, mac: MACAddress?, ip: IPv4Address, name: String, date: Date) {
        self.key = key
        self.mac = mac
        self.ip = ip
        self.name = name
        self.date = date
    }
}

/// Ce qu'une suppression a retiré, pour l'annuler.
public struct InvRemoval: Hashable, Sendable {
    public var records: [InvRecord]
    public var events: [InvEvent]
    /// Exclusions ajoutées par cette suppression (retirées à l'annulation).
    public var addedExclusions: [String]
    /// Note 10 : fiches archivées par ce retrait (retirées des archives à l'annulation). Vide :
    /// suppression définitive.
    public var addedArchives: [String] = []
    /// Place de chaque événement retiré dans le journal d'origine, et taille du journal restant :
    /// une annulation immédiate remet chaque événement exactement à sa place.
    var eventPositions: [Int] = []
    var remainingEvents = 0
    /// Premier et dernier événement du journal restant : le journal n'a pas bougé entre-temps.
    var remainingFirst: UUID?
    var remainingLast: UUID?
    /// Date de la suppression.
    public var date = Date.distantPast

    public init(records: [InvRecord] = [], events: [InvEvent] = [], addedExclusions: [String] = []) {
        self.records = records
        self.events = events
        self.addedExclusions = addedExclusions
    }

    public var isEmpty: Bool { records.isEmpty && addedExclusions.isEmpty }
    /// Retrait par archivage (restaurable depuis la vue « Archivés »).
    public var isArchive: Bool { !addedArchives.isEmpty }
    public var count: Int { records.count }

    /// Appareil du Scanner vu au plus tard à la suppression (résultats déjà affichés, fusion en
    /// attente) : il ne recrée pas la fiche supprimée. Revu par un scan après la suppression, il revient.
    public func holds(_ device: Device) -> Bool {
        guard device.lastSeen <= date else { return false }
        return records.contains { record in
            if let mac = device.mac { return record.mac == mac }
            return record.ip == device.ip
        }
    }
}

/// Résultat d'une annulation de suppression.
public struct InvRestoreResult: Hashable, Sendable {
    /// Fiches remises telles qu'elles étaient.
    public var restored = 0
    /// Fiches recréées entre-temps par un scan, complétées par la fiche d'avant (notes, historique).
    public var merged = 0
    public var total: Int { restored + merged }
    public init(restored: Int = 0, merged: Int = 0) {
        self.restored = restored
        self.merged = merged
    }
}

public extension InventoryStore {
    // MARK: Exclusions

    /// Appareils qu'on ne suit plus, du plus récent au plus ancien.
    var excluded: [InvExclusion] {
        (exclusions ?? [:]).values.sorted { ($0.date, $0.key) > ($1.date, $1.key) }
    }

    func isExcluded(key: String) -> Bool { exclusions?[key] != nil }

    /// Un appareil du scan est-il exclu ? Avec sa MAC : par sa MAC, ou par une exclusion « ip:… »
    /// (appareil exclu sans MAC connue) à la même adresse, comme la fusion rattache une fiche par IP
    /// à la MAC qui apparaît. Sans MAC (au-delà d'un routeur) : une fiche suivie à MAC de cette
    /// adresse l'emporte ; sinon exclu si un appareil exclu avait cette adresse.
    func isExcluded(_ device: Device) -> Bool { exclusionKey(for: device) != nil }

    /// Clé de l'exclusion qui écarte cet appareil du scan, nil s'il est suivi.
    func exclusionKey(for device: Device) -> String? {
        guard let exclusions, !exclusions.isEmpty else { return nil }
        if let mac = device.mac {
            let key = Self.key(mac: mac)
            if exclusions[key] != nil { return key }
            // Fiche suivie à cette MAC : jamais écartée par une exclusion d'adresse.
            guard records[key] == nil else { return nil }
            let ipKey = Self.key(ip: device.ip)
            if let byIP = exclusions[ipKey], byIP.mac == nil { return ipKey }
            return nil
        }
        // Sans MAC : la fiche suivie à MAC qui a cette adresse (même résolution qu'à la fusion).
        if records.values.contains(where: { $0.mac != nil && $0.ip == device.ip }) { return nil }
        let ipKey = Self.key(ip: device.ip)
        if exclusions[ipKey] != nil { return ipKey }
        return exclusions.values
            .filter { $0.mac != nil && $0.ip == device.ip }
            .max { $0.date < $1.date }?.key
    }

    /// Une exclusion par adresse rattrapée par la MAC de l'appareil devient une exclusion par MAC
    /// (l'appareil garde son exclusion s'il change d'adresse) ; une exclusion par MAC suit l'adresse
    /// de l'appareil (vu sans MAC au-delà d'un routeur, il est reconnu à sa dernière adresse).
    mutating func adoptMAC(of device: Device, exclusion key: String) {
        guard let mac = device.mac else { return }
        if key.hasPrefix("mac:") {
            if exclusions?[key]?.ip != device.ip { exclusions?[key]?.ip = device.ip }
            return
        }
        guard var exclusion = exclusions?[key] else { return }
        let macKey = Self.key(mac: mac)
        exclusions?[key] = nil
        exclusion.key = macKey
        exclusion.mac = mac
        exclusion.ip = device.ip
        exclusions?[macKey] = exclusion
    }

    /// Une fiche créée à la main (import CSV, type choisi au Scanner) lève l'exclusion qui la
    /// viserait : sinon elle resterait figée, jamais mise à jour par les scans.
    mutating func liftExclusions(for record: InvRecord) {
        guard let exclusions, !exclusions.isEmpty else { return }
        for (key, exclusion) in exclusions
        where key == record.key || (record.mac != nil && exclusion.mac == record.mac)
            || (exclusion.mac == nil && record.mac == nil && exclusion.ip == record.ip) {
            include(key)
        }
    }

    /// « Suivre de nouveau » : le prochain scan remettra l'appareil dans l'inventaire.
    mutating func include(_ key: String) {
        exclusions?[key] = nil
        if exclusions?.isEmpty == true { exclusions = nil }
    }

    // MARK: Suppression

    /// Supprime des fiches et leurs événements ; `exclude` : les appareils ne sont plus suivis ;
    /// `archive` (note 10) : la fiche et ses événements vont dans les archives du site (restaurables).
    /// Les clés inconnues sont ignorées. Renvoie de quoi annuler.
    @discardableResult
    mutating func removeRecords(_ keys: [String], exclude: Bool, archive toArchive: Bool = false, at date: Date = Date()) -> InvRemoval {
        var removal = InvRemoval()
        removal.date = date
        var seen: Set<String> = []
        for key in keys where !seen.contains(key) {
            seen.insert(key)
            guard let record = records[key] else { continue }
            removal.records.append(record)
            records[key] = nil
            if exclude, exclusions?[key] == nil {
                var list = exclusions ?? [:]
                list[key] = InvExclusion(key: key, mac: record.mac, ip: record.ip, name: record.displayName, date: date)
                exclusions = list
                removal.addedExclusions.append(key)
            }
        }
        guard !removal.records.isEmpty else { return removal }
        let removed = Set(removal.records.map(\.key))
        for (index, event) in events.enumerated() where removed.contains(event.key) {
            removal.events.append(event)
            removal.eventPositions.append(index)
        }
        events.removeAll { removed.contains($0.key) }
        if toArchive {
            var list = archive ?? [:]
            for record in removal.records {
                list[record.key] = InvArchiveEntry(record: record, events: removal.events.filter { $0.key == record.key }, date: date)
                removal.addedArchives.append(record.key)
            }
            archive = list
        }
        removal.remainingEvents = events.count
        removal.remainingFirst = events.first?.id
        removal.remainingLast = events.last?.id
        return removal
    }

    /// Annule une suppression : fiches, événements (à leur place dans le temps) et exclusions.
    /// Une fiche recréée entre-temps par un scan reçoit la fiche d'avant : champs saisis, première
    /// vue, historiques d'IP et de ports ; l'événement « Nouvel appareil » de sa recréation est retiré.
    @discardableResult
    mutating func restore(_ removal: InvRemoval) -> InvRestoreResult {
        var result = InvRestoreResult()
        for key in removal.addedExclusions { include(key) }
        for key in removal.addedArchives { archive?[key] = nil }
        if archive?.isEmpty == true { archive = nil }
        var recreated: Set<String> = []
        for record in removal.records {
            if let current = records[record.key] {
                records[record.key] = Self.reunite(old: record, recreated: current)
                recreated.insert(record.key)
                result.merged += 1
            } else {
                records[record.key] = record
                result.restored += 1
            }
        }
        if !recreated.isEmpty {
            events.removeAll { recreated.contains($0.key) && $0.kind == .nouveau && $0.date >= removal.date }
        }
        let back = removal.events
        guard !back.isEmpty else { return result }
        // Journal inchangé depuis la suppression : chaque événement reprend exactement sa place.
        if events.count == removal.remainingEvents, events.first?.id == removal.remainingFirst,
           events.last?.id == removal.remainingLast, removal.eventPositions.count == back.count {
            for (event, position) in zip(back, removal.eventPositions) {
                events.insert(event, at: min(position, events.count))
            }
            return result
        }
        let known = Set(events.map(\.id))
        let merged = events + back.filter { !known.contains($0.id) }
        // Tri stable par date : les événements reprennent leur place dans le journal.
        events = merged.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        return result
    }

    /// Fiche d'avant la suppression complétée par ce que le scan a vu depuis (adresse, état,
    /// ports, switch) ; les champs saisis à la main sont ceux d'avant.
    internal static func reunite(old: InvRecord, recreated new: InvRecord) -> InvRecord {
        var record = new
        record.annotations = old.annotations
        record.firstSeen = min(old.firstSeen, new.firstSeen)
        record.isImported = old.isImported && new.isImported
        if record.manual == nil { record.manual = old.manual }
        if record.attachments == nil { record.attachments = old.attachments }
        if record.attachmentFolder == nil { record.attachmentFolder = old.attachmentFolder }
        var ips = old.ipHistory
        if let last = ips.indices.last, ips[last].to == nil, ips[last].ip != new.ip { ips[last].to = new.firstSeen }
        for span in new.ipHistory where !(ips.last?.ip == span.ip && ips.last?.to == nil) { ips.append(span) }
        record.ipHistory = ips
        var ports = old.portHistory
        if let last = ports.indices.last, ports[last].to == nil,
           ports[last].switchName != new.switchName || ports[last].port != new.switchPort {
            if new.switchName != nil { ports[last].to = new.firstSeen }
        }
        for span in new.portHistory where !(ports.last.map { $0.switchName == span.switchName && $0.port == span.port && $0.to == nil } ?? false) {
            ports.append(span)
        }
        record.portHistory = ports
        if record.hostname == nil { record.hostname = old.hostname }
        if record.vendor == nil { record.vendor = old.vendor }
        if record.mac == nil { record.mac = old.mac }
        return record
    }
}
