import Foundation

// Note 78 (0.26.0) : session du ping continu enregistrée et rouverte (liste des cibles et
// réglages, pas l'historique des mesures), seuil de lenteur par cible, disposition (cartes ou
// tableau compact) et notification macOS d'une cible qui tombe ou revient. Aucun réseau ici.

/// Disposition des cibles : cartes, ou tableau compact (automatique au-delà de 9 cibles).
public enum PingLayoutChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, cards, table

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .cards: return "Cartes"
        case .table: return "Tableau compact"
        }
    }

    /// Au-delà de ce nombre de cibles, l'automatique passe au tableau compact.
    public static let cardLimit = 9

    /// Vrai si les cibles s'affichent en tableau compact.
    public func usesTable(targetCount: Int) -> Bool {
        switch self {
        case .automatic: return targetCount > Self.cardLimit
        case .cards: return false
        case .table: return true
        }
    }
}

/// Seuils de lenteur proposés pour une cible (millisecondes).
public enum PingThreshold {
    public static let choices: [Double] = [5, 10, 15, 20, 30, 50, 80, 100, 150, 200, 300, 500]
    public static let range: ClosedRange<Double> = 1...5_000

    /// « 20 ms ».
    public static func label(_ value: Double) -> String {
        PingFormat.decimal(value, digits: value.rounded() == value ? 0 : 1) + "\u{00A0}ms"
    }

    /// Seuil ramené dans les bornes (nil si illisible).
    public static func clamped(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Fichier de session du ping continu (JSON, extension .netscope-ping) : cibles et réglages.
public struct PingSessionFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileExtension = "netscope-ping"
    /// Nombre de cibles au plus dans une session.
    public static let maxTargets = 64

    public struct Target: Codable, Equatable, Sendable {
        /// Texte saisi (adresse, nom d'hôte).
        public var input: String
        public var name: String
        public var role: String
        /// Seuil de lenteur ; nil : seuil par défaut selon l'adresse.
        public var thresholdMs: Double?
        public var isPaused: Bool

        public init(input: String, name: String = "", role: String = "", thresholdMs: Double? = nil, isPaused: Bool = false) {
            self.input = input
            self.name = name
            self.role = role
            self.thresholdMs = thresholdMs
            self.isPaused = isPaused
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = try c.decode(String.self, forKey: .input)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
            thresholdMs = PingThreshold.clamped(try? c.decodeIfPresent(Double.self, forKey: .thresholdMs))
            isPaused = (try? c.decodeIfPresent(Bool.self, forKey: .isPaused)) ?? false
        }
    }

    public var version: Int
    public var savedAt: Date
    public var interval: TimeInterval
    public var payloadSize: Int
    public var soundOnLoss: Bool
    /// Notification macOS quand une cible tombe ou revient.
    public var notifyChanges: Bool
    public var layout: PingLayoutChoice
    public var targets: [Target]

    public init(savedAt: Date = Date(), interval: TimeInterval = 1, payloadSize: Int = 56, soundOnLoss: Bool = true,
                notifyChanges: Bool = true, layout: PingLayoutChoice = .automatic, targets: [Target] = []) {
        version = Self.currentVersion
        self.savedAt = savedAt
        self.interval = interval
        self.payloadSize = payloadSize
        self.soundOnLoss = soundOnLoss
        self.notifyChanges = notifyChanges
        self.layout = layout
        self.targets = targets
        sanitize()
    }

    /// Lecture tolérante : clé absente → valeur par défaut ; valeurs hors bornes ramenées.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        savedAt = (try? c.decodeIfPresent(Date.self, forKey: .savedAt)) ?? Date(timeIntervalSince1970: 0)
        interval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .interval)) ?? 1
        payloadSize = (try? c.decodeIfPresent(Int.self, forKey: .payloadSize)) ?? 56
        soundOnLoss = (try? c.decodeIfPresent(Bool.self, forKey: .soundOnLoss)) ?? true
        notifyChanges = (try? c.decodeIfPresent(Bool.self, forKey: .notifyChanges)) ?? true
        layout = (try? c.decodeIfPresent(String.self, forKey: .layout)).flatMap { $0.flatMap(PingLayoutChoice.init(rawValue:)) } ?? .automatic
        // Une cible illisible n'empêche pas de rouvrir les autres.
        let raw = (try? c.decodeIfPresent([LossyTarget].self, forKey: .targets)) ?? []
        targets = raw.compactMap(\.value)
        sanitize()
    }

    private struct LossyTarget: Decodable {
        let value: Target?
        init(from decoder: Decoder) throws { value = try? Target(from: decoder) }
    }

    /// Intervalle et taille ramenés aux valeurs proposées, cibles vides ou en double retirées.
    private mutating func sanitize() {
        if !PingOptions.intervals.contains(interval) {
            interval = PingOptions.intervals.min { abs($0 - interval) < abs($1 - interval) } ?? 1
        }
        if !PingOptions.payloadSizes.contains(payloadSize) { payloadSize = payloadSize > 1000 ? 1472 : 56 }
        var seen = Set<String>()
        targets = targets.compactMap { target in
            var target = target
            target.input = target.input.trimmingCharacters(in: .whitespacesAndNewlines)
            target.name = AlertText.singleLine(target.name)
            target.role = AlertText.singleLine(target.role)
            guard !target.input.isEmpty, target.input.count <= 253, seen.insert(target.input.lowercased()).inserted else { return nil }
            return target
        }
        if targets.count > Self.maxTargets { targets = Array(targets.prefix(Self.maxTargets)) }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PingSessionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(PingSessionFile.self, from: data)
            guard file.version <= currentVersion else { throw PingSessionError.newerVersion(file.version) }
            return file
        } catch let error as PingSessionError {
            throw error
        } catch {
            throw PingSessionError.unreadable
        }
    }

    /// « 6 cibles · 1 s · 56 octets ».
    public var summary: String {
        let count = targets.count
        return "\(count) \(count > 1 ? "cibles" : "cible") · \(PingFormat.duration(interval)) · \(payloadSize) octets"
    }
}

public enum PingSessionError: Error, Equatable, LocalizedError {
    case unreadable
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Ce fichier n’est pas une session de ping continu lisible."
        case .newerVersion(let version): return "Session écrite par une version plus récente de NetScope (format \(version))."
        }
    }
}

// MARK: - Notifications

/// Notification macOS d'une cible du ping continu qui tombe ou revient (Réglages › Notifications :
/// « Cible du ping continu hors ligne » et « … rétablie »).
public enum PingNotification {
    /// Événement commun pour un événement du journal ; nil si ce n'est ni une coupure ni un retour.
    public static func event(for event: PingEvent, name: String, address: String) -> NetScopeEvent? {
        let label = name == address || name.isEmpty ? address : "\(name) (\(address))"
        switch event.level {
        case .coupure:
            return NetScopeEvent(id: "ping-\(address)-\(Int(event.date.timeIntervalSince1970))", kind: .pingTargetDown,
                                 title: "\(label) ne répond plus",
                                 detail: "Ping continu\u{00A0}: \(event.message).", date: event.date,
                                 link: .screen("ping"), source: "ping-" + address)
        case .retabli:
            return NetScopeEvent(id: "ping-\(address)-\(Int(event.date.timeIntervalSince1970))", kind: .pingTargetUp,
                                 title: "\(label) répond de nouveau",
                                 detail: "Ping continu\u{00A0}: \(event.message).", date: event.date,
                                 link: .screen("ping"), source: "ping-" + address)
        case .alerte, .info:
            return nil
        }
    }
}
