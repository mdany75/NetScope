import Foundation

// Note 99 : historique d'une adresse MAC (inspiré de Netdisco). Pour chaque MAC : les IP, les noms,
// les ports de switch, les VLAN et les bornes Wi-Fi où elle a été vue, avec les dates de première et
// de dernière vue. Alimenté par ce que NetScope lit déjà (scans, relevés des switchs, clients Wi-Fi
// de la FortiGate) : rien de plus sur le réseau. Un historique par site ; la clé est toujours la MAC.
// Tout est pur ici : l'application range le fichier et choisit la durée de conservation.

/// Nature d'une observation.
public enum MACSightingKind: String, Codable, CaseIterable, Sendable {
    case ip, name, switchPort, vlan, accessPoint

    public var label: String {
        switch self {
        case .ip: return "Adresse IP"
        case .name: return "Nom"
        case .switchPort: return "Port de switch"
        case .vlan: return "VLAN"
        case .accessPoint: return "Borne Wi-Fi"
        }
    }
}

/// D'où vient l'observation.
public enum MACSightingSource: String, Codable, CaseIterable, Sendable {
    case scan, switchTable, fortigate, wifi

    public var label: String {
        switch self {
        case .scan: return "Scan"
        case .switchTable: return "Relevé de switch"
        case .fortigate: return "FortiGate"
        case .wifi: return "Wi-Fi"
        }
    }
}

/// Une observation ponctuelle (avant fusion dans l'historique).
public struct MACObservation: Hashable, Sendable {
    public var mac: MACAddress
    public var kind: MACSightingKind
    public var value: String
    public var source: MACSightingSource

    public init(mac: MACAddress, kind: MACSightingKind, value: String, source: MACSightingSource) {
        self.mac = mac
        self.kind = kind
        self.value = value
        self.source = source
    }
}

/// Une valeur vue pour une MAC, avec la période où elle l'a été.
public struct MACSighting: Codable, Hashable, Sendable, Identifiable {
    public var mac: MACAddress
    public var kind: MACSightingKind
    public var value: String
    public var sources: [MACSightingSource]
    public var firstSeen: Date
    public var lastSeen: Date
    /// Nombre de relevés où la valeur a été vue.
    public var count: Int

    public var id: String { MACHistory.key(mac, kind, value) }

    public init(mac: MACAddress, kind: MACSightingKind, value: String, sources: [MACSightingSource],
                firstSeen: Date, lastSeen: Date, count: Int = 1) {
        self.mac = mac
        self.kind = kind
        self.value = value
        self.sources = sources
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
    }

    /// Vrai si la valeur était vue ce jour-là (de la première à la dernière vue, jours entiers).
    public func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: firstSeen)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastSeen)) ?? lastSeen
        return day >= start && day < end
    }
}

/// Résultat d'une recherche : une MAC et ses observations retenues.
public struct MACHistoryMatch: Hashable, Sendable, Identifiable {
    public var mac: MACAddress
    public var sightings: [MACSighting]
    public var id: MACAddress { mac }

    /// Dernier nom connu (« Imprimante accueil »).
    public var latestName: String? { sightings.filter { $0.kind == .name }.max { $0.lastSeen < $1.lastSeen }?.value }
    public var lastSeen: Date? { sightings.map(\.lastSeen).max() }
}

/// Historique des MAC d'un site.
public struct MACHistory: Codable, Hashable, Sendable {
    /// Durée de conservation proposée (jours) ; choix offerts dans l'application.
    public static let defaultRetentionDays = 180
    public static let retentionChoices = [30, 90, 180, 365, 730]

    public private(set) var sightings: [String: MACSighting]

    public init(sightings: [MACSighting] = []) {
        self.sightings = Dictionary(sightings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func key(_ mac: MACAddress, _ kind: MACSightingKind, _ value: String) -> String {
        "\(mac.description)|\(kind.rawValue)|\(value.lowercased())"
    }

    public var isEmpty: Bool { sightings.isEmpty }
    public var macCount: Int { Set(sightings.values.map(\.mac)).count }

    /// Fusionne les observations d'un relevé : prolonge la période d'une valeur déjà vue, ou
    /// en ouvre une nouvelle. Les MAC nulles, de diffusion ou de multidiffusion sont écartées.
    @discardableResult
    public mutating func record(_ observations: [MACObservation], at date: Date) -> Int {
        var added = 0
        var seen: Set<String> = []
        for observation in observations {
            let value = observation.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, observation.mac.value != 0, !observation.mac.isBroadcast, !observation.mac.isMulticast else { continue }
            let key = Self.key(observation.mac, observation.kind, value)
            if var existing = sightings[key] {
                existing.firstSeen = min(existing.firstSeen, date)
                existing.lastSeen = max(existing.lastSeen, date)
                if !seen.contains(key) { existing.count += 1 }
                if !existing.sources.contains(observation.source) { existing.sources.append(observation.source) }
                sightings[key] = existing
            } else {
                sightings[key] = MACSighting(mac: observation.mac, kind: observation.kind, value: value,
                                             sources: [observation.source], firstSeen: date, lastSeen: date)
                added += 1
            }
            seen.insert(key)
        }
        return added
    }

    /// Retire les valeurs plus vues depuis `retentionDays` jours ; rend le nombre retiré.
    @discardableResult
    public mutating func prune(retentionDays: Int, now: Date) -> Int {
        let limit = now.addingTimeInterval(-Double(max(1, retentionDays)) * 86_400)
        let before = sightings.count
        sightings = sightings.filter { $0.value.lastSeen >= limit }
        return before - sightings.count
    }

    /// Chronologie d'une MAC : la plus récente d'abord, puis par nature.
    public func timeline(for mac: MACAddress) -> [MACSighting] {
        sightings.values.filter { $0.mac == mac }.sorted(by: Self.order)
    }

    static func order(_ a: MACSighting, _ b: MACSighting) -> Bool {
        if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
        if a.kind != b.kind {
            return MACSightingKind.allCases.firstIndex(of: a.kind)! < MACSightingKind.allCases.firstIndex(of: b.kind)!
        }
        return a.value < b.value
    }

    /// « Où était cet appareil ? » : MAC (complète ou partielle, tous formats), IP ou nom (sans
    /// tenir compte des accents ni de la casse). Avec `day`, seules les valeurs vues ce jour-là sont
    /// gardées. Une MAC retenue rend toute sa chronologie (filtrée par la date), la plus récente d'abord.
    public func search(_ query: String, on day: Date? = nil, calendar: Calendar = .current) -> [MACHistoryMatch] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = Self.fold(text)
        let hex = text.lowercased().filter { $0.isHexDigit }
        let looksLikeMAC = hex.count >= 4 && text.allSatisfy { $0.isHexDigit || ":-. ".contains($0) }
        var macs: Set<MACAddress> = []
        for sighting in sightings.values {
            if text.isEmpty {
                macs.insert(sighting.mac)
                continue
            }
            let macHex = String(format: "%012llx", sighting.mac.value)
            if looksLikeMAC, macHex.contains(hex) { macs.insert(sighting.mac); continue }
            switch sighting.kind {
            case .ip:
                if sighting.value == text || (text.hasSuffix(".") && sighting.value.hasPrefix(text)) { macs.insert(sighting.mac) }
            case .name, .switchPort, .accessPoint:
                if Self.fold(sighting.value).contains(folded) { macs.insert(sighting.mac) }
            case .vlan:
                break
            }
        }
        return macs.compactMap { mac -> MACHistoryMatch? in
            var list = timeline(for: mac)
            if let day { list = list.filter { $0.covers(day, calendar: calendar) } }
            return list.isEmpty ? nil : MACHistoryMatch(mac: mac, sightings: list)
        }
        .sorted { ($0.lastSeen ?? .distantPast, $1.mac) > ($1.lastSeen ?? .distantPast, $0.mac) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
    }

    // MARK: Sources

    /// Observations d'un scan (ou de l'inventaire) : IP, nom, switch et port, VLAN des appareils à MAC.
    public static func observations(devices: [Device], source: MACSightingSource = .scan) -> [MACObservation] {
        devices.flatMap { device -> [MACObservation] in
            guard let mac = device.mac, device.isOnline else { return [] }
            var list = [MACObservation(mac: mac, kind: .ip, value: device.ip.description, source: source)]
            let name = (device.customName ?? device.hostname)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty { list.append(MACObservation(mac: mac, kind: .name, value: name, source: source)) }
            if let sw = device.switchName, let port = device.switchPort, !sw.isEmpty, !port.isEmpty {
                list.append(MACObservation(mac: mac, kind: .switchPort, value: "\(sw) · \(port)", source: source))
            }
            if let vlan = device.vlan { list.append(MACObservation(mac: mac, kind: .vlan, value: "\(vlan)", source: source)) }
            return list
        }
    }

    /// Observations des relevés des switchs : MAC apprises sur les ports d'accès (pas les uplinks),
    /// avec le VLAN ; IP de la table ARP des switchs de niveau 3.
    public static func observations(snapshots: [SNMPSwitchSnapshot], source: MACSightingSource = .switchTable) -> [MACObservation] {
        let uplinkMap = SNMPLocator.uplinks(in: snapshots)
        var list: [MACObservation] = []
        for snapshot in snapshots {
            let uplinks = uplinkMap[snapshot.host] ?? []
            for entry in snapshot.fdb {
                guard let index = entry.ifIndex, !uplinks.contains(index) else { continue }
                let port = snapshot.interface(index)?.name ?? "port \(entry.bridgePort)"
                list.append(MACObservation(mac: entry.mac, kind: .switchPort, value: "\(snapshot.displayName) · \(port)", source: source))
                if let vlan = entry.vlan ?? snapshot.pvid[index] {
                    list.append(MACObservation(mac: entry.mac, kind: .vlan, value: "\(vlan)", source: source))
                }
            }
            for (mac, ip) in snapshot.arp {
                list.append(MACObservation(mac: mac, kind: .ip, value: ip.description, source: source))
            }
        }
        return list
    }

    /// Observations des clients Wi-Fi lus sur la FortiGate : borne, IP, nom, VLAN.
    public static func observations(wifiClients: [FortiWifiClient]) -> [MACObservation] {
        wifiClients.flatMap { client -> [MACObservation] in
            var list: [MACObservation] = []
            if let ap = client.apName, !ap.isEmpty {
                let ssid = client.ssid.map { " (\($0))" } ?? ""
                list.append(MACObservation(mac: client.mac, kind: .accessPoint, value: ap + ssid, source: .wifi))
            }
            if let ip = client.ip { list.append(MACObservation(mac: client.mac, kind: .ip, value: ip.description, source: .fortigate)) }
            if let name = client.hostname, !name.isEmpty { list.append(MACObservation(mac: client.mac, kind: .name, value: name, source: .fortigate)) }
            if let vlan = client.vlan { list.append(MACObservation(mac: client.mac, kind: .vlan, value: "\(vlan)", source: .fortigate)) }
            return list
        }
    }

    // MARK: Export

    /// CSV (séparateur « ; », dates ISO 8601) : MAC, nature, valeur, première et dernière vue,
    /// nombre de relevés, sources.
    public static func csv(_ sightings: [MACSighting]) -> String {
        let formatter = ISO8601DateFormatter()
        func cell(_ text: String) -> String {
            let needsQuotes = text.contains(";") || text.contains("\"") || text.contains("\n")
            var safe = text.replacingOccurrences(of: "\"", with: "\"\"")
            // Pas de formule dans un tableur.
            if let first = safe.first, "=+-@".contains(first) { safe = "'" + safe }
            return needsQuotes ? "\"\(safe)\"" : safe
        }
        var lines = ["MAC;Nature;Valeur;Première vue;Dernière vue;Relevés;Sources"]
        for sighting in sightings {
            lines.append([sighting.mac.description, sighting.kind.label, sighting.value,
                          formatter.string(from: sighting.firstSeen), formatter.string(from: sighting.lastSeen),
                          "\(sighting.count)", sighting.sources.map(\.label).joined(separator: ", ")].map(cell).joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
