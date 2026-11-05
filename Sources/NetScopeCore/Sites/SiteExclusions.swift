import Foundation

// Note 82 : plages exclues d'un site. Adresses seules (10.93.226.254), intervalles
// (10.93.226.1-50) ou sous-réseaux (10.255.1.0/24), avec une note facultative (« automates »,
// « FortiLink », « caméras fragiles »). Une adresse exclue n'est jamais sondée : ni ping, ni ARP
// actif, ni ports, ni SNMP, ni noms (scan, relecture automatique, Scan de ports, Ping continu
// d'une plage). Calcul par intervalles (jamais d'énumération des exclusions elles-mêmes) ; aucun
// accès réseau ici.
//
// Un sous-réseau exclu couvre TOUTES ses adresses, réseau et diffusion comprises : exclure
// 10.0.1.0/24 d'un scan de 10.0.0.0/23 retire bien 10.0.1.0 et 10.0.0.255… qui sont des hôtes du /23.

/// Une plage exclue telle que saisie dans Réglages › Sites et plages.
public struct ExcludedRange: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Texte saisi (« 10.93.226.1-50 », « 10.255.1.0/24 », « 10.93.226.254 », ou une liste).
    public var text: String
    /// Pourquoi elle est exclue (facultatif).
    public var note: String

    public init(id: UUID = UUID(), text: String, note: String = "") {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Intervalles couverts (bornes comprises) ; lève `IPRangeError` si le texte est illisible.
    public func intervals() throws -> [ClosedRange<UInt32>] {
        try IPRange.segments(parsing: text).map(AddressExclusions.interval(of:))
    }

    /// Vrai si le texte se lit.
    public var isValid: Bool { (try? intervals()) != nil }

    /// Nombre d'adresses couvertes (0 si illisible).
    public var addressCount: UInt64 {
        AddressExclusions.size(AddressExclusions.merge((try? intervals()) ?? []))
    }

    /// « Adresse », « Intervalle », « Sous-réseau » ou « Liste ».
    public var kindLabel: String {
        guard let segments = try? IPRange.segments(parsing: text) else { return "Illisible" }
        guard segments.count == 1 else { return "Liste" }
        switch segments[0] {
        case .single: return "Adresse"
        case .span: return "Intervalle"
        case .cidr: return "Sous-réseau"
        }
    }

    /// « 10.93.226.1-50 (automates) » : texte et note, pour une infobulle ou un journal.
    public var label: String { note.isEmpty ? text : "\(text) (\(note))" }

    enum CodingKeys: String, CodingKey { case id, text, note }

    /// Lecture tolérante : identifiant absent → nouveau ; note absente → vide.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let idText = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        id = idText.flatMap(UUID.init(uuidString:)) ?? UUID()
        text = (try c.decode(String.self, forKey: .text)).trimmingCharacters(in: .whitespacesAndNewlines)
        note = (((try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(note, forKey: .note)
    }
}

/// Ensemble des adresses exclues d'un site, prêt pour le scan : intervalles fusionnés et triés.
public struct AddressExclusions: Hashable, Sendable {
    /// Intervalles disjoints, triés, fusionnés (ceux qui se touchent ne font qu'un).
    public private(set) var intervals: [ClosedRange<UInt32>]
    /// Plages saisies lisibles, dans l'ordre (pour dire POURQUOI une adresse est exclue).
    public private(set) var entries: [ExcludedRange]
    private var entryIntervals: [[ClosedRange<UInt32>]]

    public static let none = AddressExclusions([])

    /// Les plages illisibles sont ignorées (la validation les signale à part).
    public init(_ entries: [ExcludedRange]) {
        var kept: [ExcludedRange] = []
        var lists: [[ClosedRange<UInt32>]] = []
        for entry in entries {
            guard let list = try? entry.intervals() else { continue }
            kept.append(entry)
            lists.append(list)
        }
        self.entries = kept
        entryIntervals = lists
        intervals = Self.merge(lists.flatMap { $0 })
    }

    public var isEmpty: Bool { intervals.isEmpty }

    /// Nombre total d'adresses exclues (chevauchements comptés une fois).
    public var addressCount: UInt64 { Self.size(intervals) }

    public func contains(_ address: IPv4Address) -> Bool {
        var low = 0, high = intervals.count - 1
        let value = address.value
        while low <= high {
            let mid = (low + high) / 2
            let r = intervals[mid]
            if value < r.lowerBound { high = mid - 1 } else if value > r.upperBound { low = mid + 1 } else { return true }
        }
        return false
    }

    /// Première plage saisie qui exclut cette adresse (nil : non exclue).
    public func reason(for address: IPv4Address) -> ExcludedRange? {
        for (index, list) in entryIntervals.enumerated() where list.contains(where: { $0.contains(address.value) }) {
            return entries[index]
        }
        return nil
    }

    /// Adresses de la plage à sonder vraiment : celles de `IPRange.addresses()` moins les exclues.
    public func addresses(in range: IPRange) -> [IPv4Address] {
        let all = range.addresses()
        return isEmpty ? all : all.filter { !contains($0) }
    }

    /// Adresses à sonder dans des plages (sans doublon entre plages).
    public func probeCount(in ranges: [IPRange]) -> Int {
        let covered = Self.merge(ranges.flatMap { $0.segments.map(Self.hostInterval(of:)) })
        return Int(Self.size(covered)) - excludedCount(in: ranges)
    }

    /// Adresses de ces plages (sans doublon) qui sont exclues : le « N adresses exclues » du Scanner.
    public func excludedCount(in ranges: [IPRange]) -> Int {
        guard !isEmpty else { return 0 }
        let covered = Self.merge(ranges.flatMap { $0.segments.map(Self.hostInterval(of:)) })
        return Int(Self.size(Self.intersection(covered, intervals)))
    }

    /// Plages saisies qui touchent ces plages, avec le nombre d'adresses retirées de chacune
    /// (infobulle du Scanner : « 10.182.122.200-210 (automates) : 11 »).
    public func breakdown(in ranges: [IPRange]) -> [(entry: ExcludedRange, count: Int)] {
        let covered = Self.merge(ranges.flatMap { $0.segments.map(Self.hostInterval(of:)) })
        var result: [(ExcludedRange, Int)] = []
        for (index, list) in entryIntervals.enumerated() {
            let count = Int(Self.size(Self.intersection(covered, Self.merge(list))))
            if count > 0 { result.append((entries[index], count)) }
        }
        return result
    }

    // MARK: Calcul par intervalles

    /// Intervalle d'une portion d'EXCLUSION : un sous-réseau couvre réseau et diffusion.
    static func interval(of segment: IPRange.Segment) -> ClosedRange<UInt32> {
        switch segment {
        case .cidr(let subnet): return subnet.network.value...subnet.broadcast.value
        case .span(let a, let b): return a.value...b.value
        case .single(let a): return a.value...a.value
        }
    }

    /// Intervalle d'une portion de plage SCANNÉE : les hôtes seulement (comme `IPRange.addresses()`).
    static func hostInterval(of segment: IPRange.Segment) -> ClosedRange<UInt32> {
        let bounds = segment.bounds
        return bounds.first.value...bounds.last.value
    }

    static func merge(_ list: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        let sorted = list.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<UInt32>] = []
        for r in sorted {
            if let last = result.last, last.upperBound == .max || r.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                result.append(r)
            }
        }
        return result
    }

    static func intersection(_ a: [ClosedRange<UInt32>], _ b: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        var result: [ClosedRange<UInt32>] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let low = max(a[i].lowerBound, b[j].lowerBound)
            let high = min(a[i].upperBound, b[j].upperBound)
            if low <= high { result.append(low...high) }
            if a[i].upperBound < b[j].upperBound { i += 1 } else { j += 1 }
        }
        return result
    }

    static func size(_ list: [ClosedRange<UInt32>]) -> UInt64 {
        list.reduce(0) { $0 + UInt64($1.upperBound - $1.lowerBound) + 1 }
    }
}

// MARK: - Validation

/// Remarque sur les plages exclues d'un site (Réglages › Sites et plages).
public struct ExclusionIssue: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// Texte illisible.
        case invalid
        /// L'exclusion couvre toute une plage du site : elle ne sera jamais scannée.
        case coversRange
        /// L'exclusion ne touche aucune plage du site (sans effet aujourd'hui).
        case outsideRanges
        /// Déjà couverte par une autre exclusion.
        case redundant
    }

    public var entryID: UUID
    public var kind: Kind
    public var message: String
    public var id: String { "\(entryID.uuidString)|\(kind.rawValue)|\(message)" }

    /// Une plage jamais scannée ou un texte illisible est une alerte ; le reste, une information.
    public var isWarning: Bool { kind == .invalid || kind == .coversRange }
}

public enum SiteExclusionCheck {
    /// Remarques, dans l'ordre des exclusions.
    public static func issues(_ exclusions: [ExcludedRange], ranges: [ScanRangeConfig]) -> [ExclusionIssue] {
        var issues: [ExclusionIssue] = []
        let parsedRanges: [(config: ScanRangeConfig, intervals: [ClosedRange<UInt32>])] = ranges.compactMap { config in
            guard let range = try? config.parsed() else { return nil }
            return (config, AddressExclusions.merge(range.segments.map(AddressExclusions.hostInterval(of:))))
        }
        let allRanges = AddressExclusions.merge(parsedRanges.flatMap(\.intervals))
        var readable: [(entry: ExcludedRange, intervals: [ClosedRange<UInt32>])] = []
        for entry in exclusions {
            do {
                readable.append((entry, AddressExclusions.merge(try entry.intervals())))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "format inconnu"
                issues.append(ExclusionIssue(entryID: entry.id, kind: .invalid,
                                             message: "«\u{00A0}\(entry.text)\u{00A0}» est illisible\u{00A0}: \(reason)"))
            }
        }
        for (index, item) in readable.enumerated() {
            for range in parsedRanges where !range.intervals.isEmpty {
                let hit = AddressExclusions.size(AddressExclusions.intersection(range.intervals, item.intervals))
                if hit == AddressExclusions.size(range.intervals) {
                    let name = range.config.label.trimmingCharacters(in: .whitespaces)
                    issues.append(ExclusionIssue(entryID: item.entry.id, kind: .coversRange,
                                                 message: "«\u{00A0}\(item.entry.text)\u{00A0}» couvre toute la plage «\u{00A0}\(name.isEmpty ? range.config.text : name)\u{00A0}» (\(range.config.text))\u{00A0}: elle ne sera jamais scannée."))
                }
            }
            if !allRanges.isEmpty, AddressExclusions.intersection(allRanges, item.intervals).isEmpty {
                issues.append(ExclusionIssue(entryID: item.entry.id, kind: .outsideRanges,
                                             message: "«\u{00A0}\(item.entry.text)\u{00A0}» ne touche aucune plage du site (sans effet pour l’instant)."))
            }
            // Déjà couverte en entier par une exclusion PLUS HAUT dans la liste (la première reste).
            let size = AddressExclusions.size(item.intervals)
            if let first = readable.prefix(index).first(where: {
                AddressExclusions.size(AddressExclusions.intersection($0.intervals, item.intervals)) == size
            }) {
                issues.append(ExclusionIssue(entryID: item.entry.id, kind: .redundant,
                                             message: "«\u{00A0}\(item.entry.text)\u{00A0}» est déjà couverte par «\u{00A0}\(first.entry.text)\u{00A0}»."))
            }
        }
        return issues
    }
}

// MARK: - Inventaire

extension InvRecord {
    /// Note 82 : un appareil d'une plage exclue n'est plus sondé ; il garde sa fiche et n'est
    /// jamais déclaré disparu (son dernier état connu reste « en ligne » ou « hors ligne »).
    public func status(now: Date = Date(), excluded: Bool) -> InvStatus {
        guard excluded else { return status(now: now) }
        if hasConflict { return .conflit }
        return isOnline ? .enLigne : .horsLigne
    }

    /// « Disparu » seulement s'il est encore scanné.
    public func isGone(now: Date = Date(), excluded: Bool) -> Bool {
        !excluded && isGone(now: now)
    }
}
