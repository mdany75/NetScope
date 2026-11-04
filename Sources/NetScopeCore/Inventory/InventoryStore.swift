import Foundation

/// Base permanente de tous les appareils jamais vus, avec leurs événements et l'historique des scans.
/// Valeur pure (aucune entrée-sortie hors `load`/`save`), donc facile à tester.
public struct InventoryStore: Codable, Sendable {
    public static let currentVersion = 1
    public static let maxEvents = 5_000
    public static let maxSnapshots = 100
    /// Deux MAC différentes sur la même IP à moins de ce délai : conflit IP.
    public static let conflictWindow: TimeInterval = 15 * 60

    public var version = InventoryStore.currentVersion
    public internal(set) var records: [String: InvRecord] = [:]
    /// Du plus ancien au plus récent.
    public internal(set) var events: [InvEvent] = []
    /// Du plus ancien au plus récent.
    public private(set) var snapshots: [InvSnapshot] = []
    /// Date de la dernière fusion d'un scan.
    public private(set) var lastMerge: Date?
    /// Appareils qu'on ne suit plus (« Ne plus suivre ces appareils », Inventaire.swift) : un scan
    /// ne les remet pas dans l'inventaire. Optionnel pour relire les fichiers d'avant la 0.12.0.
    /// Voir InvRemoval.swift.
    var exclusions: [String: InvExclusion]?

    public init() {}

    // MARK: Clés et lecture

    public static func key(mac: MACAddress) -> String { "mac:" + mac.formatted(.colon) }
    public static func key(ip: IPv4Address) -> String { "ip:" + ip.description }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    public func record(_ key: String) -> InvRecord? { records[key] }

    /// Fiches triées par IP.
    public var sortedRecords: [InvRecord] {
        records.values.sorted { ($0.ip, $0.key) < ($1.ip, $1.key) }
    }

    /// Fiche la plus récemment vue à cette adresse.
    public func record(forIP ip: IPv4Address) -> InvRecord? {
        records.values.filter { $0.ip == ip }.max { $0.lastSeen < $1.lastSeen }
    }

    /// Événements d'une fiche, du plus ancien au plus récent.
    public func events(for key: String) -> [InvEvent] {
        events.filter { $0.key == key }
    }

    /// IP en conflit actuellement.
    public var conflictIPs: Set<IPv4Address> {
        Set(records.values.filter(\.hasConflict).map(\.ip))
    }

    // MARK: Fusion d'un scan

    /// Fusionne le résultat d'un scan et renvoie les événements produits.
    /// - `coverage` : plages réellement sondées ; une fiche en ligne qui y était attendue et qui manque passe hors ligne.
    /// - `snapshot` : ajoute un instantané résumé si le résultat diffère du précédent.
    @discardableResult
    public mutating func merge(_ devices: [Device], at date: Date = Date(), coverage: InvCoverage = .none,
                               snapshot: Bool = true) -> [InvEvent] {
        // Appareils qu'on ne suit plus : jamais remis dans l'inventaire par un scan.
        let devices = devices.filter { !isExcluded($0) }
        let baseline = records.isEmpty
        var produced: [InvEvent] = []
        func emit(_ kind: InvEventKind, _ severity: InvSeverity, key: String, ip: IPv4Address, date eventDate: Date? = nil,
                  title: String, detail: String) {
            produced.append(InvEvent(date: eventDate ?? date, kind: kind, severity: severity, key: key, ip: ip,
                                     title: title, detail: detail, baseline: baseline))
        }

        // 1. Clé de chaque appareil reçu (une fiche connue par IP gagne sa MAC dès qu'elle apparaît).
        var resolved: [(key: String, device: Device)] = []
        var seenKeys: [String: Int] = [:]
        for device in devices {
            let key = resolveKey(for: device)
            if let position = seenKeys[key] {
                // Même appareil deux fois dans le scan : on garde la vue en ligne la plus récente.
                let other = resolved[position].device
                if device.isOnline && (!other.isOnline || device.lastSeen >= other.lastSeen) {
                    resolved[position] = (key, device)
                }
            } else {
                seenKeys[key] = resolved.count
                resolved.append((key, device))
            }
        }
        let incomingKeys = Set(resolved.map(\.key))

        // 2. Conflits IP : plusieurs MAC sur la même IP dans ce scan…
        var conflicts: [IPv4Address: Set<MACAddress>] = [:]
        var macsByIP: [IPv4Address: Set<MACAddress>] = [:]
        for (_, device) in resolved where device.isOnline {
            if let mac = device.mac { macsByIP[device.ip, default: []].insert(mac) }
        }
        for (ip, macs) in macsByIP where macs.count > 1 { conflicts[ip] = macs }

        // … ou entre deux scans rapprochés ; sinon l'ancienne fiche a simplement perdu son adresse.
        var keysByIP: [IPv4Address: [String]] = [:]
        for record in records.values { keysByIP[record.ip, default: []].append(record.key) }
        var displaced: [String: (by: Device, key: String)] = [:]
        for (key, device) in resolved where device.isOnline {
            for otherKey in keysByIP[device.ip] ?? [] where otherKey != key && !incomingKeys.contains(otherKey) {
                guard let other = records[otherKey], other.isOnline else { continue }
                if let otherMAC = other.mac, let mac = device.mac, otherMAC != mac,
                   date.timeIntervalSince(other.lastSeen) <= Self.conflictWindow {
                    conflicts[device.ip, default: []].formUnion([otherMAC, mac])
                } else {
                    displaced[otherKey] = (device, key)
                }
            }
        }

        // 3. Mise à jour ou création des fiches.
        for (key, device) in resolved {
            if var record = records[key] {
                update(&record, with: device, at: date, emit: emit)
                records[key] = record
            } else {
                let record = makeRecord(key: key, device: device, at: date)
                records[key] = record
                let detail = describe(record)
                if baseline {
                    emit(.nouveau, .info, key: key, ip: device.ip, date: record.firstSeen,
                         title: "Première détection", detail: detail)
                } else {
                    emit(.nouveau, .info, key: key, ip: device.ip, date: record.firstSeen,
                         title: "Nouvel appareil : \(record.displayName)", detail: detail)
                }
            }
        }

        // 4. Adresses reprises par un autre appareil.
        for (otherKey, taker) in displaced {
            guard var other = records[otherKey], other.isOnline else { continue }
            other.isOnline = false
            other.offlineSince = date
            other.latencyMs = nil
            other.conflictWith = []
            records[otherKey] = other
            let takerName = records[taker.key]?.displayName ?? taker.by.ip.description
            emit(.horsLigne, severityForOffline(other), key: otherKey, ip: other.ip,
                 title: "Hors ligne : \(other.displayName)",
                 detail: "Adresse \(other.ip) reprise par \(takerName)" + (taker.by.mac.map { " (\($0.formatted(.upperColon)))" } ?? ""))
        }

        // 5. Appareils attendus dans les plages sondées mais absents.
        let covers = coverageTest(coverage, incoming: resolved.map(\.device))
        if let covers {
            for (key, record) in records where record.isOnline && !incomingKeys.contains(key) && displaced[key] == nil {
                guard covers(record.ip) else { continue }
                var updated = record
                updated.isOnline = false
                updated.offlineSince = date
                updated.latencyMs = nil
                records[key] = updated
                emit(.horsLigne, severityForOffline(updated), key: key, ip: updated.ip,
                     title: "Hors ligne : \(updated.displayName)",
                     detail: "\(updated.ip) · dernière réponse \(InvFormat.stamp(updated.lastSeen))")
            }
        }

        // 6. Conflits : ouverture (un seul événement par adresse) et fermeture.
        for (ip, macs) in conflicts.sorted(by: { $0.key < $1.key }) {
            let involved = macs.compactMap { records[Self.key(mac: $0)] }
            let wasActive = involved.contains { $0.hasConflict && $0.ip == ip }
            for record in involved {
                var updated = record
                updated.conflictWith = macs.filter { $0 != record.mac }.sorted()
                records[record.key] = updated
            }
            if !wasActive {
                let sortedMACs = macs.sorted().map { $0.formatted(.upperColon) }
                let places = involved.sorted { ($0.mac ?? MACAddress(value: 0)) < ($1.mac ?? MACAddress(value: 0)) }
                    .compactMap(\.switchLocation)
                let key = resolved.first { $0.device.ip == ip && $0.device.mac != nil }?.key ?? involved.first?.key ?? Self.key(ip: ip)
                emit(.conflitIP, .critique, key: key, ip: ip,
                     title: "Conflit IP \(ip) : \(macs.count) MAC (\(sortedMACs.joined(separator: " et ")))",
                     detail: places.isEmpty ? "Plusieurs appareils répondent à la même adresse"
                         : places.joined(separator: " et ") + " · plusieurs appareils répondent à la même adresse")
            }
        }
        for (key, record) in records where record.hasConflict && conflicts[record.ip] == nil {
            // Conflit levé quand l'autre MAC ne répond plus sur cette adresse depuis le délai de conflit.
            let stillThere = record.conflictWith.contains { mac in
                guard let other = records[Self.key(mac: mac)] else { return false }
                return other.isOnline && other.ip == record.ip && date.timeIntervalSince(other.lastSeen) <= Self.conflictWindow
            }
            if !stillThere || !record.isOnline {
                var updated = record
                updated.conflictWith = []
                records[key] = updated
            }
        }

        // 7. Journal, instantané.
        events.append(contentsOf: produced.sorted { $0.date < $1.date })
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        lastMerge = date
        if snapshot {
            // L'instantané décrit l'état des réseaux sondés : toutes les fiches de leurs /24, vues ou non.
            let networks = Set(resolved.map { $0.device.ip.value >> 8 })
            let keys = records.values.filter { incomingKeys.contains($0.key) || networks.contains($0.ip.value >> 8) }.map(\.key)
            addSnapshot(keys, at: date)
        }
        return produced
    }

    /// Clé d'un appareil reçu ; re-clé une fiche connue par IP quand sa MAC apparaît.
    private mutating func resolveKey(for device: Device) -> String {
        if let mac = device.mac {
            let key = Self.key(mac: mac)
            let ipKey = Self.key(ip: device.ip)
            if records[key] == nil, var old = records[ipKey], old.mac == nil {
                records[ipKey] = nil
                old.key = key
                old.mac = mac
                records[key] = old
                for index in events.indices where events[index].key == ipKey { events[index].key = key }
            }
            return key
        }
        // Sans MAC (appareil derrière un routeur) : la fiche à MAC qui a cette IP, sinon une fiche par IP.
        if let match = records.values.filter({ $0.mac != nil && $0.ip == device.ip }).max(by: { $0.lastSeen < $1.lastSeen }) {
            return match.key
        }
        return Self.key(ip: device.ip)
    }

    private func makeRecord(key: String, device: Device, at date: Date) -> InvRecord {
        let first = min(device.firstSeen, date)
        var record = InvRecord(key: key, mac: device.mac, ip: device.ip, hostname: device.hostname,
                               vendor: device.vendor, detectedType: device.deviceType, isOnline: device.isOnline,
                               latencyMs: device.latencyMs, openPorts: device.openPorts.sorted(),
                               switchName: device.switchName, switchPort: device.switchPort, vlan: device.vlan,
                               rangeLabel: device.rangeLabel, firstSeen: first, lastSeen: min(device.lastSeen, date),
                               offlineSince: device.isOnline ? nil : min(device.lastSeen, date))
        if let name = device.customName, !name.isEmpty { record.annotations.customName = name }
        record.ipHistory = [InvIPSpan(ip: device.ip, from: first)]
        if let name = device.switchName, let port = device.switchPort {
            record.portHistory = [InvPortSpan(switchName: name, port: port, vlan: device.vlan, from: first)]
        }
        return record
    }

    private func update(_ record: inout InvRecord, with device: Device, at date: Date,
                        emit: (InvEventKind, InvSeverity, String, IPv4Address, Date?, String, String) -> Void) {
        let key = record.key
        // Adresse IP
        if record.ip != device.ip {
            let old = record.ip
            if let last = record.ipHistory.indices.last, record.ipHistory[last].to == nil { record.ipHistory[last].to = date }
            record.ipHistory.append(InvIPSpan(ip: device.ip, from: date))
            record.ip = device.ip
            record.conflictWith = []
            emit(.changementIP, .info, key, device.ip, nil, "IP changée : \(InvFormat.ipChange(old, device.ip))",
                 "\(record.displayName) · \(old) → \(device.ip)" + (record.mac.map { " · MAC \($0.formatted(.upperColon))" } ?? ""))
        }
        // Port de switch
        if let newSwitch = device.switchName, let newPort = device.switchPort {
            if let oldSwitch = record.switchName, let oldPort = record.switchPort {
                if oldSwitch != newSwitch || oldPort != newPort {
                    if let last = record.portHistory.indices.last, record.portHistory[last].to == nil { record.portHistory[last].to = date }
                    record.portHistory.append(InvPortSpan(switchName: newSwitch, port: newPort, vlan: device.vlan ?? record.vlan, from: date))
                    let sameSwitch = oldSwitch == newSwitch
                    emit(.changementPort, .alerte, key, device.ip, nil,
                         "Changement de port : \(record.displayName) de \(oldSwitch) \(oldPort) à " + (sameSwitch ? newPort : "\(newSwitch) \(newPort)"),
                         "\(device.ip) · \(oldSwitch) · \(oldPort) → \(newSwitch) · \(newPort)" + ((device.vlan ?? record.vlan).map { " · VLAN \($0)" } ?? ""))
                }
            } else {
                record.portHistory.append(InvPortSpan(switchName: newSwitch, port: newPort, vlan: device.vlan ?? record.vlan, from: date))
            }
            record.switchName = newSwitch
            record.switchPort = newPort
        }
        // Disponibilité
        if device.isOnline && !record.isOnline {
            let since = record.offlineSince ?? record.lastSeen
            emit(.retour, .info, key, device.ip, nil, "De retour en ligne : \(record.displayName)",
                 "Hors ligne pendant \(InvFormat.duration(date.timeIntervalSince(since)))")
            record.offlineSince = nil
        } else if !device.isOnline && record.isOnline {
            record.offlineSince = max(record.lastSeen, min(device.lastSeen, date))
            record.conflictWith = []
            emit(.horsLigne, severityForOffline(record), key, device.ip, nil, "Hors ligne : \(record.displayName)",
                 "\(device.ip) · dernière réponse \(InvFormat.stamp(record.offlineSince ?? date))")
        }
        record.isOnline = device.isOnline
        // Autres champs observés (les champs saisis à la main ne sont jamais écrasés).
        if let hostname = device.hostname, !hostname.isEmpty { record.hostname = hostname }
        if let vendor = device.vendor, !vendor.isEmpty { record.vendor = vendor }
        if device.deviceType != .inconnu { record.detectedType = device.deviceType }
        if let vlan = device.vlan { record.vlan = vlan }
        if let label = device.rangeLabel { record.rangeLabel = label }
        if record.mac == nil, let mac = device.mac { record.mac = mac }
        if (record.annotations.customName ?? "").isEmpty, let name = device.customName, !name.isEmpty {
            record.annotations.customName = name
        }
        if device.isOnline {
            record.latencyMs = device.latencyMs
            if !device.openPorts.isEmpty { record.openPorts = device.openPorts.sorted() }
            record.lastSeen = max(record.lastSeen, min(device.lastSeen, date))
        } else {
            record.latencyMs = nil
        }
        record.firstSeen = min(record.firstSeen, device.firstSeen)
        record.isImported = false
    }

    private func severityForOffline(_ record: InvRecord) -> InvSeverity {
        switch record.type {
        case .routeur, .switch, .pointAcces, .serveur, .camera: return .alerte
        default: return .info
        }
    }

    private func describe(_ record: InvRecord) -> String {
        var parts = [record.ip.description]
        if let location = record.switchLocation { parts.append(location) }
        if let vlan = record.vlan { parts.append("VLAN \(vlan)") }
        if let mac = record.mac { parts.append("MAC \(mac.formatted(.upperColon)) (\(record.vendorLabel))") }
        return parts.joined(separator: " · ")
    }

    private func coverageTest(_ coverage: InvCoverage, incoming: [Device]) -> ((IPv4Address) -> Bool)? {
        switch coverage {
        case .none:
            return nil
        case .subnetsOfIncoming:
            let networks = Set(incoming.map { $0.ip.value >> 8 })
            return { networks.contains($0.value >> 8) }
        case .ranges(let ranges):
            return { address in ranges.contains { $0.contains(address) } }
        }
    }

    private mutating func addSnapshot(_ keys: [String], at date: Date) {
        let entries = keys.compactMap { key -> InvSnapshotEntry? in
            guard let record = records[key] else { return nil }
            return InvSnapshotEntry(key: key, ip: record.ip, mac: record.mac, name: record.displayName,
                                    isOnline: record.isOnline, switchLocation: record.switchLocation,
                                    vlan: record.vlan, openPorts: record.openPorts)
        }
        .sorted { $0.key < $1.key }
        if let last = snapshots.last, last.entries == entries { return }
        snapshots.append(InvSnapshot(date: date, entries: entries))
        if snapshots.count > Self.maxSnapshots { snapshots.removeFirst(snapshots.count - Self.maxSnapshots) }
    }

    // MARK: Fiches

    /// Remplace les champs saisis d'une fiche ; consigne un événement « Fiche modifiée » si un champ change
    /// (le favori seul n'en produit pas).
    public mutating func setAnnotations(_ annotations: InvAnnotations, for key: String, at date: Date = Date(),
                                        recordEvent: Bool = true) {
        guard var record = records[key] else { return }
        var cleaned = annotations
        if let name = cleaned.customName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            cleaned.customName = name
        } else {
            cleaned.customName = nil
        }
        let changed = cleaned.changedFields(from: record.annotations)
        record.annotations = cleaned
        records[key] = record
        if recordEvent && !changed.isEmpty {
            events.append(InvEvent(date: date, kind: .fiche, severity: .info, key: key, ip: record.ip,
                                   title: "Fiche modifiée", detail: "Champs mis à jour : " + changed.joined(separator: ", ")))
        }
    }

    public mutating func setFavorite(_ favorite: Bool, for key: String) {
        records[key]?.annotations.isFavorite = favorite
    }

    // MARK: Type choisi à la main (note 20)

    /// Fiche existante d'un appareil du scan, résolue comme à la fusion : par MAC ; sans MAC, la fiche
    /// à MAC qui a cette IP (la plus récente), sinon la fiche par IP.
    public func existingKey(for device: Device) -> String? {
        if let mac = device.mac {
            let key = Self.key(mac: mac)
            return records[key] == nil ? nil : key
        }
        if let match = records.values.filter({ $0.mac != nil && $0.ip == device.ip }).max(by: { $0.lastSeen < $1.lastSeen }) {
            return match.key
        }
        let ipKey = Self.key(ip: device.ip)
        return records[ipKey] == nil ? nil : ipKey
    }

    /// Type choisi à la main pour un appareil du scan : celui de sa fiche (même résolution qu'à la fusion).
    public func manualType(for device: Device) -> DeviceType? {
        existingKey(for: device).flatMap { records[$0]?.annotations.customType }
    }

    /// Type affiché d'un appareil : choix de session (par IP, appareils sans MAC), sinon choix de la
    /// fiche, sinon type détecté par le scan.
    public func typeChoice(for device: Device, session: [String: DeviceType] = [:]) -> DeviceTypeChoice {
        let manual = device.mac == nil ? (session[device.id] ?? manualType(for: device)) : manualType(for: device)
        return DeviceTypeChoice(detected: device.deviceType, manual: manual)
    }

    /// Retient le type choisi à la main (nil : revenir au type détecté) sur la fiche de l'appareil :
    /// celle de la MAC, créée au besoin ; sans MAC, la fiche existante (à MAC de même IP, sinon par IP).
    /// Faux, sans rien changer, pour un appareil sans MAC qui n'a pas encore de fiche.
    @discardableResult
    public mutating func setManualType(_ type: DeviceType?, for device: Device, at date: Date = Date()) -> Bool {
        guard let mac = device.mac else {
            guard let key = existingKey(for: device), var annotations = records[key]?.annotations else { return false }
            annotations.customType = type
            setAnnotations(annotations, for: key, at: date)
            return true
        }
        let key = Self.key(mac: mac)
        if records[key] == nil {
            var record = makeRecord(key: key, device: device, at: date)
            record.isOnline = device.isOnline
            records[key] = record
        }
        guard var annotations = records[key]?.annotations else { return false }
        annotations.customType = type
        setAnnotations(annotations, for: key, at: date)
        return true
    }

    /// Appareils dont le type est remplacé par le type choisi à la main (Carte, Rapports).
    public func applyingManualTypes(to devices: [Device], session: [String: DeviceType] = [:]) -> [Device] {
        devices.map { device in
            var copy = device
            copy.deviceType = typeChoice(for: device, session: session).type
            return copy
        }
    }

    /// Accepter, ignorer ou remettre à traiter une alerte.
    /// Ajoute une alerte signalée par un outil (Test DHCP). Refusée (faux) si la même alerte
    /// (type et adresse) est déjà à traiter depuis moins de 24 h.
    @discardableResult
    public mutating func addAlert(_ event: InvEvent) -> Bool {
        let duplicate = events.contains {
            $0.kind == event.kind && $0.ip == event.ip && $0.status == .aTraiter
                && abs(event.date.timeIntervalSince($0.date)) < 86_400
        }
        guard !duplicate else { return false }
        events.append(event)
        return true
    }

    public mutating func setEventStatus(_ status: InvEventStatus, for id: UUID, at date: Date = Date()) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].status = status
        events[index].statusDate = status == .aTraiter ? nil : date
    }

    /// Supprime une fiche et ses événements (appareil retiré du parc).
    public mutating func removeRecord(_ key: String) {
        records[key] = nil
        events.removeAll { $0.key == key }
    }

    // MARK: Doublons

    /// Fiches au même nom d'hôte, à MAC différentes du même fabricant (ou aléatoires), jamais en ligne ensemble.
    public func probableDuplicates() -> [InvDuplicate] {
        var byHost: [String: [InvRecord]] = [:]
        for record in records.values {
            guard let host = record.hostname?.lowercased(), host.count > 2, record.mac != nil,
                  IPv4Address(host) == nil else { continue }
            byHost[host, default: []].append(record)
        }
        var result: [InvDuplicate] = []
        for (_, group) in byHost where group.count > 1 {
            let sorted = group.sorted { $0.lastSeen > $1.lastSeen }
            let keep = sorted[0]
            for other in sorted.dropFirst() {
                guard let a = keep.mac, let b = other.mac else { continue }
                let sameVendor = a.oui == b.oui || a.isRandomized || b.isRandomized
                guard sameVendor, !(keep.isOnline && other.isOnline) else { continue }
                var reason = "Même nom d’hôte (\(keep.hostname ?? ""))"
                if a.oui == b.oui { reason += ", MAC du même fabricant (\(a.oui))" }
                reason += ", jamais en ligne en même temps."
                result.append(InvDuplicate(keep: keep.key, absorb: other.key, reason: reason))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Rattache la fiche `absorb` à `keep` : historiques réunis, champs saisis complétés, fiche absorbée retirée.
    public mutating func absorb(_ absorbKey: String, into keepKey: String, at date: Date = Date()) {
        guard absorbKey != keepKey, var keep = records[keepKey], let other = records[absorbKey] else { return }
        keep.ipHistory = (keep.ipHistory + other.ipHistory.map { span in
            var closed = span
            if closed.to == nil { closed.to = other.lastSeen }
            return closed
        }).sorted { $0.from < $1.from }
        keep.portHistory = (keep.portHistory + other.portHistory.map { span in
            var closed = span
            if closed.to == nil { closed.to = other.lastSeen }
            return closed
        }).sorted { $0.from < $1.from }
        keep.firstSeen = min(keep.firstSeen, other.firstSeen)
        var notes = keep.annotations
        let extra = other.annotations
        if (notes.customName ?? "").isEmpty { notes.customName = extra.customName }
        if notes.customType == nil { notes.customType = extra.customType }
        for tag in extra.tags where !notes.tags.contains(tag) { notes.tags.append(tag) }
        if notes.location.isEmpty { notes.location = extra.location }
        if notes.wallJack.isEmpty { notes.wallJack = extra.wallJack }
        if notes.owner.isEmpty { notes.owner = extra.owner }
        if notes.assetNumber.isEmpty { notes.assetNumber = extra.assetNumber }
        if notes.notes.isEmpty { notes.notes = extra.notes }
        notes.isFavorite = notes.isFavorite || extra.isFavorite
        keep.annotations = notes
        records[keepKey] = keep
        records[absorbKey] = nil
        for index in events.indices where events[index].key == absorbKey { events[index].key = keepKey }
        let mac = other.mac.map { "MAC \($0.formatted(.upperColon)) " } ?? ""
        events.append(InvEvent(date: date, kind: .fusion, severity: .info, key: keepKey, ip: keep.ip,
                               title: "Fiches fusionnées",
                               detail: "\(mac)(ancienne IP \(other.ip)) rattachée à cette fiche"))
    }

    // MARK: Comparaison de scans

    /// Ajoutés, disparus et modifiés entre deux instantanés (`before` plus ancien que `after`).
    public static func compare(_ before: InvSnapshot, _ after: InvSnapshot) -> InvDiff {
        var diff = InvDiff()
        let old = Dictionary(before.entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        func mac(_ entry: InvSnapshotEntry) -> String { entry.mac?.formatted(.upperColon) ?? "—" }
        func ports(_ list: [UInt16]) -> String { list.isEmpty ? "aucun" : list.map(String.init).joined(separator: ", ") }

        for entry in after.entries.sorted(by: { $0.ip < $1.ip }) where entry.isOnline {
            let previous = old[entry.key]
            if previous == nil || previous?.isOnline == false {
                diff.added.append(InvDiffRow(key: entry.key, ip: entry.ip, name: entry.name, mac: mac(entry),
                                             before: previous == nil ? "Absent" : "Hors ligne",
                                             after: "Ajouté" + (entry.switchLocation.map { " · \($0)" } ?? "")))
            }
        }
        for entry in before.entries.sorted(by: { $0.ip < $1.ip }) where entry.isOnline {
            let next = new[entry.key]
            if next == nil || next?.isOnline == false {
                diff.removed.append(InvDiffRow(key: entry.key, ip: entry.ip, name: entry.name, mac: mac(entry),
                                               before: "En ligne" + (entry.vlan.map { " · VLAN \($0)" } ?? ""),
                                               after: next == nil ? "Disparu" : "Hors ligne"))
            }
        }
        for entry in after.entries.sorted(by: { $0.ip < $1.ip }) {
            guard let previous = old[entry.key], previous.isOnline, entry.isOnline else { continue }
            if previous.ip != entry.ip {
                diff.modified.append(InvDiffRow(key: entry.key, ip: entry.ip, name: entry.name, mac: mac(entry),
                                                before: "IP \(previous.ip)", after: "IP \(entry.ip)"))
            }
            if let a = previous.switchLocation, let b = entry.switchLocation, a != b {
                diff.modified.append(InvDiffRow(key: entry.key, ip: entry.ip, name: entry.name, mac: mac(entry),
                                                before: a, after: b))
            }
            if previous.openPorts != entry.openPorts && !previous.openPorts.isEmpty && !entry.openPorts.isEmpty {
                diff.modified.append(InvDiffRow(key: entry.key, ip: entry.ip, name: entry.name, mac: mac(entry),
                                                before: "Ports " + ports(previous.openPorts),
                                                after: "Ports " + ports(entry.openPorts)))
            }
            if previous.name != entry.name {
                diff.modified.append(InvDiffRow(key: entry.key, ip: entry.ip, name: entry.name, mac: mac(entry),
                                                before: "Nom \(previous.name)", after: "Nom \(entry.name)"))
            }
        }
        return diff
    }

    // MARK: Persistance

    /// ~/Library/Application Support/NetScope/inventory.json
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("inventory.json")
    }

    /// Lit la base ; un fichier absent donne une base vide.
    public static func load(from url: URL) throws -> InventoryStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return InventoryStore() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InventoryStore.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Import CSV

    public struct ImportResult: Hashable, Sendable {
        public var created = 0
        public var updated = 0
        public var skipped = 0
    }

    /// Applique des lignes importées : fiche trouvée par MAC puis par IP, sinon créée (hors ligne).
    @discardableResult
    public mutating func importRows(_ rows: [InvCSVRow], at date: Date = Date()) -> ImportResult {
        var result = ImportResult()
        for row in rows {
            var key: String?
            if let mac = row.mac, records[Self.key(mac: mac)] != nil { key = Self.key(mac: mac) }
            if key == nil, let ip = row.ip { key = record(forIP: ip)?.key }
            if key == nil {
                guard let ip = row.ip else { result.skipped += 1; continue }
                let newKey = row.mac.map { Self.key(mac: $0) } ?? Self.key(ip: ip)
                var record = InvRecord(key: newKey, mac: row.mac, ip: ip, hostname: row.hostname,
                                       detectedType: row.type ?? .inconnu, isOnline: false,
                                       firstSeen: date, lastSeen: date, offlineSince: date,
                                       ipHistory: [InvIPSpan(ip: ip, from: date)], isImported: true)
                record.annotations = row.apply(to: InvAnnotations())
                records[newKey] = record
                events.append(InvEvent(date: date, kind: .importCSV, severity: .info, key: newKey, ip: ip,
                                       title: "Fiche importée (CSV)", detail: "Créée à partir d’un fichier importé"))
                result.created += 1
            } else if let key, let record = records[key] {
                let merged = row.apply(to: record.annotations)
                if merged != record.annotations {
                    setAnnotations(merged, for: key, at: date)
                    result.updated += 1
                } else {
                    result.skipped += 1
                }
            }
        }
        return result
    }
}
