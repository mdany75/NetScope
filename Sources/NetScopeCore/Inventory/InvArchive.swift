import Foundation

// Note 10 (Inventaire, phase 3) : ce qui entre dans l'inventaire d'un site, et ce qui en sort.
//
// - Option du site « Ajouter automatiquement les appareils scannés » (activée par défaut : rien ne
//   change pour les inventaires existants). Désactivée, un scan met à jour les fiches existantes
//   (et rapproche les fiches ajoutées à la main) mais n'en crée plus : on choisit « Ajouter à
//   l'inventaire » depuis le Scanner. Les appareils écartés comptent toujours pour les conflits IP.
// - Retirer un appareil : « Archiver » (la fiche et son historique vont dans les archives du site,
//   restaurables à tout moment, vue « Archivés ») ou « Supprimer définitivement » (InvRemoval.swift).
//   Un appareil archivé revu par un scan revient avec sa fiche d'avant, sauf s'il est exclu
//   (« Ne plus réajouter cet appareil ») ou si l'ajout automatique est désactivé.
// - Liste d'exclusion du site : modifiable dans l'Inventaire et dans Réglages › Sites et plages.

/// Réglages de l'inventaire d'un site (gardés dans son fichier : ils suivent le site).
public struct InvSettings: Codable, Hashable, Sendable {
    /// « Ajouter automatiquement les appareils scannés » (vrai par défaut).
    public var autoAdd: Bool

    public init(autoAdd: Bool = true) {
        self.autoAdd = autoAdd
    }
}

/// Appareil archivé : sa fiche et ses événements, tels qu'au moment de l'archivage.
public struct InvArchiveEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { record.key }
    public var record: InvRecord
    public var events: [InvEvent]
    public var date: Date

    public init(record: InvRecord, events: [InvEvent], date: Date) {
        self.record = record
        self.events = events
        self.date = date
    }
}

/// Compte rendu de « Ajouter à l'inventaire » (Scanner).
public struct InvAddResult: Hashable, Sendable {
    /// Fiches créées.
    public var added = 0
    /// Fiches ajoutées à la main rapprochées de ces appareils.
    public var matched = 0
    /// Appareils archivés remis avec leur fiche d'avant.
    public var restored = 0
    /// Déjà dans l'inventaire.
    public var already = 0
    /// Clés des fiches ajoutées, rapprochées ou restaurées.
    public var keys: [String] = []

    public init() {}

    public var changed: Int { added + matched + restored }
}

public extension InventoryStore {
    // MARK: Réglages

    var settingsValue: InvSettings { settings ?? InvSettings() }

    /// « Ajouter automatiquement les appareils scannés ».
    var autoAdd: Bool { settingsValue.autoAdd }

    mutating func setAutoAdd(_ on: Bool) {
        var value = settingsValue
        value.autoAdd = on
        // Valeur par défaut : rien d'écrit (fichiers identiques à ceux d'avant la 0.20.0).
        settings = value == InvSettings() ? nil : value
    }

    // MARK: Archives

    /// Appareils archivés, du plus récent au plus ancien.
    var archived: [InvArchiveEntry] {
        (archive ?? [:]).values.sorted { ($0.date, $0.record.key) > ($1.date, $1.record.key) }
    }

    var archivedCount: Int { archive?.count ?? 0 }

    func archivedEntry(_ key: String) -> InvArchiveEntry? { archive?[key] }

    /// Archive d'un appareil du scan : par sa MAC, sinon (sans MAC) par son adresse.
    func archivedKey(for device: Device) -> String? {
        guard let archive, !archive.isEmpty else { return nil }
        if let mac = device.mac {
            let key = Self.key(mac: mac)
            if archive[key] != nil { return key }
            let ipKey = Self.key(ip: device.ip)
            if let entry = archive[ipKey], entry.record.mac == nil { return ipKey }
            return nil
        }
        let ipKey = Self.key(ip: device.ip)
        if archive[ipKey] != nil { return ipKey }
        return archive.values.filter { $0.record.mac != nil && $0.record.ip == device.ip }
            .max { $0.date < $1.date }?.record.key
    }

    /// Restaure des appareils archivés (« Restaurer ») : fiche, champs saisis et historique. Une fiche
    /// recréée entre-temps reçoit la fiche d'avant. Lève l'exclusion qui viserait l'appareil.
    @discardableResult
    mutating func restoreArchived(_ keys: [String], at date: Date = Date(), reason: String = "Restauré depuis les archives") -> InvRestoreResult {
        var result = InvRestoreResult()
        var back: [InvEvent] = []
        for key in keys {
            guard let entry = archive?.removeValue(forKey: key) else { continue }
            var record = entry.record
            if let current = records[key] {
                record = Self.reunite(old: entry.record, recreated: current)
                result.merged += 1
            } else {
                result.restored += 1
            }
            liftExclusions(for: record)
            records[key] = record
            back += entry.events
            back.append(InvEvent(date: date, kind: .fiche, severity: .info, key: key, ip: record.ip,
                                 title: reason, detail: "Archivé le \(InvFormat.day(entry.date))"))
        }
        if archive?.isEmpty == true { archive = nil }
        if !back.isEmpty { insertEvents(back) }
        return result
    }

    /// Supprime définitivement des appareils archivés ; renvoie ce qui est retiré (pour annuler et
    /// pour retirer leurs pièces jointes).
    @discardableResult
    mutating func purgeArchived(_ keys: [String]) -> [InvArchiveEntry] {
        var removed: [InvArchiveEntry] = []
        for key in keys {
            if let entry = archive?.removeValue(forKey: key) { removed.append(entry) }
        }
        if archive?.isEmpty == true { archive = nil }
        return removed
    }

    /// Remet des entrées d'archive (annulation d'une suppression définitive dans les archives).
    mutating func putBackArchived(_ entries: [InvArchiveEntry]) {
        guard !entries.isEmpty else { return }
        var list = archive ?? [:]
        for entry in entries where list[entry.record.key] == nil && records[entry.record.key] == nil {
            list[entry.record.key] = entry
        }
        archive = list.isEmpty ? nil : list
    }

    /// Événements remis dans le journal, à leur place dans le temps (sans doublon).
    internal mutating func insertEvents(_ back: [InvEvent]) {
        let known = Set(events.map(\.id))
        let merged = events + back.filter { !known.contains($0.id) }
        events = merged.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    // MARK: Exclusions écrites à la main

    /// Ajoute une MAC à la liste d'exclusion du site (Réglages, Inventaire) : un scan ne la mettra
    /// pas dans l'inventaire. Faux si une fiche suivie a déjà cette MAC (la retirer avec « Ne plus
    /// réajouter ») ou si la MAC est déjà exclue.
    @discardableResult
    mutating func exclude(mac: MACAddress, name: String, at date: Date = Date()) -> Bool {
        let key = Self.key(mac: mac)
        guard records[key] == nil, !records.values.contains(where: { $0.mac == mac }), exclusions?[key] == nil else { return false }
        var list = exclusions ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        list[key] = InvExclusion(key: key, mac: mac, ip: IPv4Address(0), name: trimmed.isEmpty ? mac.formatted(.upperColon) : trimmed, date: date)
        exclusions = list
        return true
    }

    // MARK: Ajouter à l'inventaire (Scanner)

    /// Ajoute des appareils du scan à l'inventaire, même si l'ajout automatique est désactivé ou
    /// s'ils étaient exclus (le choix est explicite) : fiche ajoutée à la main correspondante
    /// rapprochée, appareil archivé restauré, sinon fiche créée.
    @discardableResult
    mutating func addScanned(_ devices: [Device], at date: Date = Date()) -> InvAddResult {
        var result = InvAddResult()
        for device in devices {
            if let key = existingKey(for: device) {
                result.already += 1
                if isExcluded(key: key) { include(key) }
                continue
            }
            if let manual = manualMatch(for: device), let key = adoptManual(manual, for: device, at: date) {
                result.matched += 1
                result.keys.append(key)
                if var record = records[key] {
                    update(&record, with: device, at: date) { _, _, _, _, _, _, _ in }
                    records[key] = record
                }
                continue
            }
            if let key = archivedKey(for: device) {
                restoreArchived([key], at: date, reason: "Remis dans l’inventaire depuis le Scanner")
                result.restored += 1
                result.keys.append(key)
                if var record = records[key] {
                    update(&record, with: device, at: date) { _, _, _, _, _, _, _ in }
                    records[key] = record
                }
                continue
            }
            let key = device.mac.map { Self.key(mac: $0) } ?? Self.key(ip: device.ip)
            var record = makeRecord(key: key, device: device, at: date)
            record.isOnline = device.isOnline
            liftExclusions(for: record)
            if let exclusion = exclusionKey(for: device) { include(exclusion) }
            records[key] = record
            events.append(InvEvent(date: date, kind: .fiche, severity: .info, key: key, ip: device.ip,
                                   title: "Ajouté à l’inventaire depuis le Scanner", detail: describe(record)))
            result.added += 1
            result.keys.append(key)
        }
        return result
    }

    /// Appareils du scan qui ne sont pas dans l'inventaire (ni exclus) : ce que « Ajouter à
    /// l'inventaire » ajouterait.
    func notInInventory(_ devices: [Device]) -> [Device] {
        devices.filter { existingKey(for: $0) == nil && !isExcluded($0) }
    }
}
