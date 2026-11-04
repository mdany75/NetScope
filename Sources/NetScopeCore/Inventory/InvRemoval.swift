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
    /// Place de chaque événement retiré dans le journal d'origine, et taille du journal restant :
    /// une annulation immédiate remet chaque événement exactement à sa place.
    var eventPositions: [Int] = []
    var remainingEvents = 0

    public init(records: [InvRecord] = [], events: [InvEvent] = [], addedExclusions: [String] = []) {
        self.records = records
        self.events = events
        self.addedExclusions = addedExclusions
    }

    public var isEmpty: Bool { records.isEmpty && addedExclusions.isEmpty }
    public var count: Int { records.count }
}

public extension InventoryStore {
    // MARK: Exclusions

    /// Appareils qu'on ne suit plus, du plus récent au plus ancien.
    var excluded: [InvExclusion] {
        (exclusions ?? [:]).values.sorted { ($0.date, $0.key) > ($1.date, $1.key) }
    }

    func isExcluded(key: String) -> Bool { exclusions?[key] != nil }

    /// Un appareil du scan est-il exclu ? Par sa MAC ; sans MAC, par son adresse (fiche « ip:… »).
    func isExcluded(_ device: Device) -> Bool {
        guard let exclusions, !exclusions.isEmpty else { return false }
        if let mac = device.mac { return exclusions[Self.key(mac: mac)] != nil }
        return exclusions[Self.key(ip: device.ip)] != nil
    }

    /// « Suivre de nouveau » : le prochain scan remettra l'appareil dans l'inventaire.
    mutating func include(_ key: String) {
        exclusions?[key] = nil
        if exclusions?.isEmpty == true { exclusions = nil }
    }

    // MARK: Suppression

    /// Supprime des fiches et leurs événements ; `exclude` : les appareils ne sont plus suivis.
    /// Les clés inconnues sont ignorées. Renvoie de quoi annuler.
    @discardableResult
    mutating func removeRecords(_ keys: [String], exclude: Bool, at date: Date = Date()) -> InvRemoval {
        var removal = InvRemoval()
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
        removal.remainingEvents = events.count
        return removal
    }

    /// Annule une suppression : fiches, événements (à leur place dans le temps) et exclusions.
    /// Une fiche recréée entre-temps par un scan est gardée telle quelle (la plus récente gagne).
    mutating func restore(_ removal: InvRemoval) {
        for key in removal.addedExclusions { include(key) }
        var restored: Set<String> = []
        for record in removal.records where records[record.key] == nil {
            records[record.key] = record
            restored.insert(record.key)
        }
        let back = removal.events.filter { restored.contains($0.key) }
        guard !back.isEmpty else { return }
        // Journal inchangé depuis la suppression : chaque événement reprend exactement sa place.
        if back.count == removal.events.count, events.count == removal.remainingEvents,
           removal.eventPositions.count == removal.events.count {
            for (event, position) in zip(removal.events, removal.eventPositions) {
                events.insert(event, at: min(position, events.count))
            }
            return
        }
        let known = Set(events.map(\.id))
        let merged = events + back.filter { !known.contains($0.id) }
        // Tri stable par date : les événements reprennent leur place dans le journal.
        events = merged.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }
}
