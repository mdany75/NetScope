import Foundation

// Note 43 : journal des messages, borné (nombre et âge), filtres, regroupement des répétitions,
// « Comprendre une coupure », recherche multiple (note 26) et export CSV. Fonctions pures.

/// Conservation du journal.
public struct LogRetention: Codable, Equatable, Sendable {
    public var maxMessages: Int
    public var maxDays: Int

    public init(maxMessages: Int = 50_000, maxDays: Int = 7) {
        self.maxMessages = max(1_000, maxMessages)
        self.maxDays = max(1, maxDays)
    }

    public static let standard = LogRetention()
    /// Choix proposés.
    public static let messageChoices = [10_000, 50_000, 100_000, 200_000]
    public static let dayChoices = [1, 7, 14, 30]

    public var label: String {
        "\(LogJournal.groupedLabel(maxMessages))\u{00A0}messages ou \(maxDays)\u{00A0}jour\(maxDays > 1 ? "s" : "")"
    }
}

/// Journal des messages, du plus ancien au plus récent.
public struct LogJournal: Codable, Sendable {
    public private(set) var messages: [LogMessage] = []

    public init(messages: [LogMessage] = []) {
        self.messages = messages.sorted { $0.date < $1.date }
    }

    private enum CodingKeys: String, CodingKey { case messages }

    /// Un message illisible est écarté sans perdre les autres.
    private struct LossyMessage: Decodable {
        var message: LogMessage?
        init(from decoder: Decoder) throws { message = try? LogMessage(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.decode([LossyMessage].self, forKey: .messages).compactMap(\.message)
        messages = list.sorted { $0.date < $1.date }
    }

    public var isEmpty: Bool { messages.isEmpty }
    public var count: Int { messages.count }

    /// Clé d'un message lu sur la FortiGate : relire la même période ne le double pas.
    static func duplicateKey(_ m: LogMessage) -> String? {
        guard m.source == .fortigate else { return nil }
        return [m.siteKey, m.host, String(m.date.timeIntervalSince1970), m.eventID ?? "", m.message].joined(separator: "|")
    }

    /// Ajoute des messages (triés à leur place), écarte les doublons FortiGate, puis applique la conservation.
    /// Renvoie le nombre de messages ajoutés.
    @discardableResult
    public mutating func append(_ list: [LogMessage], retention: LogRetention, now: Date) -> Int {
        guard !list.isEmpty else { return 0 }
        // Doublons FortiGate : seuls les messages à partir de la plus ancienne date reçue peuvent l'être.
        var known = Set<String>()
        if let oldest = list.lazy.filter({ $0.source == .fortigate }).map(\.date).min() {
            let start = LogFilter.firstIndex(messages, atOrAfter: oldest)
            known = Set(messages[start...].compactMap(Self.duplicateKey))
        }
        var fresh: [LogMessage] = []
        for message in list.map({ $0.withTrustedClock() }) {
            if let key = Self.duplicateKey(message) {
                guard known.insert(key).inserted else { continue }
            }
            fresh.append(message)
        }
        guard !fresh.isEmpty else { return 0 }
        let sortedFresh = fresh.sorted { $0.date < $1.date }
        if let last = messages.last, let first = sortedFresh.first, first.date < last.date {
            messages = Self.merge(messages, sortedFresh)
        } else {
            messages += sortedFresh
        }
        prune(retention: retention, now: now)
        return fresh.count
    }

    static func merge(_ a: [LogMessage], _ b: [LogMessage]) -> [LogMessage] {
        var result: [LogMessage] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if b[j].date < a[i].date { result.append(b[j]); j += 1 } else { result.append(a[i]); i += 1 }
        }
        result += a[i...]
        result += b[j...]
        return result
    }

    /// Retire les messages plus vieux que la durée gardée, puis les plus anciens au-delà du nombre gardé.
    @discardableResult
    public mutating func prune(retention: LogRetention, now: Date) -> Int {
        let before = messages.count
        let limit = now.addingTimeInterval(-TimeInterval(retention.maxDays) * 86_400)
        if let first = messages.firstIndex(where: { $0.date >= limit }) {
            if first > 0 { messages.removeFirst(first) }
        } else {
            messages.removeAll()
        }
        if messages.count > retention.maxMessages { messages.removeFirst(messages.count - retention.maxMessages) }
        return before - messages.count
    }

    public mutating func removeAll(siteKeys: Set<String>? = nil) {
        if let siteKeys { messages.removeAll { siteKeys.contains($0.siteKey) } } else { messages.removeAll() }
    }

    /// Messages reçus depuis `date` (sondes de la Surveillance).
    public func messages(since date: Date) -> ArraySlice<LogMessage> {
        let start = messages.firstIndex { $0.arrival >= date } ?? messages.endIndex
        return messages[start...]
    }

    /// « 50 000 » (espace fine insécable des milliers).
    public static func groupedLabel(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, ch) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append("\u{202F}") }
            result.append(ch)
        }
        return result
    }
}

// MARK: - Filtres

/// Ce que l'écran montre.
public struct LogFilter: Sendable {
    public var from: Date?
    public var to: Date?
    public var minimumSeverity: LogSeverity
    public var sources: Set<LogSource>
    /// Sites montrés (clés) ; nil : tous.
    public var siteKeys: Set<String>?

    public init(from: Date? = nil, to: Date? = nil, minimumSeverity: LogSeverity = .debug,
                sources: Set<LogSource> = Set(LogSource.allCases), siteKeys: Set<String>? = nil) {
        self.from = from
        self.to = to
        self.minimumSeverity = minimumSeverity
        self.sources = sources
        self.siteKeys = siteKeys
    }

    public func matches(_ m: LogMessage) -> Bool {
        if let from, m.date < from { return false }
        if let to, m.date > to { return false }
        guard m.severity.isAtLeast(minimumSeverity), sources.contains(m.source) else { return false }
        if let siteKeys, !siteKeys.contains(m.siteKey) { return false }
        return true
    }

    /// Messages retenus (ordre gardé), puis la recherche.
    public func apply(_ messages: [LogMessage], search: SearchQuery? = nil, names: [String: String] = [:]) -> [LogMessage] {
        // Plage horaire : bornes cherchées par dichotomie (journal trié par date).
        var slice = messages[...]
        if let from {
            let start = LogFilter.firstIndex(messages, atOrAfter: from)
            slice = messages[start...]
        }
        let filtered = slice.filter(matches)
        guard let search, !search.isEmpty else { return filtered }
        return filtered.filter { search.matches(LogSearchItem($0, deviceName: names[$0.host])) }
    }

    static func firstIndex(_ messages: [LogMessage], atOrAfter date: Date) -> Int {
        var low = 0, high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

// MARK: - Recherche multiple (note 26)

public extension SearchAttribute {
    static let logDevice = SearchAttribute("appareil", label: "Appareil", aliases: ["device", "hote", "host", "nom", "name", "equipement"],
                                           example: "SW-ETG2")
    static let logSource = SearchAttribute("source", label: "Source", aliases: ["src", "origine"], example: "trap")
    static let logEvent = SearchAttribute("evenement", label: "Événement", aliases: ["event", "logid", "oid", "trap"], example: "linkDown")
    static let logApp = SearchAttribute("app", label: "Programme", aliases: ["programme", "tag", "process"], example: "sshd")
}

public extension SearchSchema {
    /// Journaux : messages Syslog, traps et journaux de la FortiGate.
    static let journaux = SearchSchema([
        .logDevice, .severity.with(example: "erreur"), .logSource, .ip, .site.with(example: "Laval"),
        .logEvent, .logApp, .message.with(example: "down"),
    ], example: "appareil:SW-ETG2 gravite:erreur")
}

/// Message du journal pour la recherche, avec le nom que NetScope donne à l'appareil.
public struct LogSearchItem: SearchableRecord {
    public static var searchSchema: SearchSchema { .journaux }

    public var message: LogMessage
    public var deviceName: String?

    public init(_ message: LogMessage, deviceName: String? = nil) {
        self.message = message
        self.deviceName = deviceName
    }

    public func searchValues(for field: SearchAttribute) -> [String] {
        let m = message
        switch field.key {
        case "appareil": return [deviceName, m.hostname, m.host].compactMap { $0 }
        case "gravite": return [m.severity.label, m.severity.keyword, String(m.severity.rawValue)]
        case "source": return m.source.searchValues
        case "ip": return [m.host] + [m.fields["srcip"], m.fields["agent"]].compactMap { $0 }
        case "site": return [m.siteName]
        case "evenement": return [m.eventID, m.fields["trap"]].compactMap { $0 }
        case "app": return [m.app].compactMap { $0 }
        case "message": return [m.message]
        default: return []
        }
    }

    public var searchFreeText: [String] {
        [deviceName, m.hostname, m.host, m.message, m.eventID, m.app, m.severity.label, m.source.label, m.siteName]
            .compactMap { $0 }
    }

    private var m: LogMessage { message }
}

// MARK: - Regroupement des messages répétés

/// Messages identiques (même appareil, même source, même gravité, même texte) réunis.
public struct LogGroup: Identifiable, Sendable {
    /// Identifiant : celui du message le plus récent du groupe.
    public var id: UUID { latest.id }
    public var latest: LogMessage
    public var count: Int
    public var firstDate: Date
    public var lastDate: Date
    public var memberIDs: [UUID]
}

public enum LogAnalysis {
    /// Clé de regroupement : site, appareil, source, gravité, événement et texte (espaces réduits).
    static func groupKey(_ m: LogMessage) -> String {
        let text = m.message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return [m.siteKey, m.host, m.source.rawValue, String(m.severity.rawValue), m.eventID ?? "", text].joined(separator: "\u{1}")
    }

    /// Regroupe les messages identiques ; un groupe est placé à la date de son dernier message.
    public static func group(_ messages: [LogMessage]) -> [LogGroup] {
        var order: [String] = []
        var groups: [String: LogGroup] = [:]
        for m in messages {
            let key = groupKey(m)
            if var group = groups[key] {
                group.count += 1
                group.memberIDs.append(m.id)
                if m.date >= group.lastDate {
                    group.latest = m
                    group.lastDate = m.date
                }
                group.firstDate = min(group.firstDate, m.date)
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = LogGroup(latest: m, count: 1, firstDate: m.date, lastDate: m.date, memberIDs: [m.id])
            }
        }
        return order.compactMap { groups[$0] }.sorted { $0.lastDate < $1.lastDate }
    }

    // MARK: Comprendre une coupure

    /// Ce que montre « Comprendre une coupure ».
    public struct OutageReport: Sendable {
        public var center: Date
        public var from: Date
        public var to: Date
        /// Messages de tous les appareils dans la fenêtre, en ordre chronologique.
        public var messages: [LogMessage]
        /// Appareils concernés (nom affiché) et leur nombre de messages, les plus bavards d'abord.
        public var devices: [(name: String, count: Int)]
        /// Premier message grave (erreur ou pire) de la fenêtre.
        public var firstSevere: LogMessage?
        /// Constats en français, dans l'ordre où ils sont arrivés.
        public var findings: [Finding]
    }

    public struct Finding: Sendable, Hashable {
        public enum Kind: String, Sendable { case linkFlap, linkDown, reboot, authFailure, vpnDown, haSwitch, power, firstSevere, quiet }
        public var kind: Kind
        public var date: Date
        public var title: String
        public var detail: String
        public var severity: LogSeverity
    }

    /// Messages de tous les appareils autour de `center` (± `span` secondes), mis en ordre, avec des
    /// constats : port qui tombe et remonte, redémarrage, authentification refusée, tunnel tombé…
    public static func outage(around center: Date, span: TimeInterval, messages: [LogMessage],
                              names: [String: String] = [:]) -> OutageReport {
        let from = center.addingTimeInterval(-span)
        let to = center.addingTimeInterval(span)
        let start = LogFilter.firstIndex(messages, atOrAfter: from)
        var window: [LogMessage] = []
        for m in messages[start...] {
            if m.date > to { break }
            window.append(m)
        }
        window.sort { $0.date < $1.date }
        func name(_ m: LogMessage) -> String { names[m.host] ?? m.deviceLabel }
        var counts: [String: Int] = [:]
        for m in window { counts[name(m), default: 0] += 1 }
        let devices = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let firstSevere = window.first { $0.severity.isAtLeast(.error) }
        var findings: [Finding] = []

        // Ports qui tombent puis remontent (traps linkDown/linkUp ou messages « down »/« up »).
        var openDowns: [String: LogMessage] = [:]
        for m in window {
            guard let port = linkPort(m) else { continue }
            let key = m.host + "|" + port.name
            if port.isDown {
                openDowns[key] = openDowns[key] ?? m
            } else if let down = openDowns.removeValue(forKey: key) {
                let seconds = m.date.timeIntervalSince(down.date)
                findings.append(Finding(kind: .linkFlap, date: down.date,
                                        title: "Port \(port.name) de \(name(m)) tombé puis remonté",
                                        detail: "Coupé pendant \(LogFormat.offset(seconds).replacingOccurrences(of: "+", with: "")), de \(LogFormat.time(down.date)) à \(LogFormat.time(m.date)). Câble, prise murale ou appareil branché à vérifier\u{00A0}; un port qui rebondit souvent trahit un câble abîmé ou une négociation de vitesse instable.",
                                        severity: .error))
            }
        }
        for (key, down) in openDowns {
            let port = String(key.split(separator: "|", maxSplits: 1).last ?? "")
            findings.append(Finding(kind: .linkDown, date: down.date, title: "Port \(port) de \(name(down)) tombé, pas remonté dans la fenêtre",
                                    detail: "Dernier état connu\u{00A0}: coupé depuis \(LogFormat.time(down.date)).", severity: .error))
        }
        for m in window {
            let event = (m.eventID ?? "").lowercased()
            let text = SearchText.fold(m.message)
            if event == "coldstart" || event == "warmstart" || text.contains("reboot") || text.contains("redemarr") || text.contains("restart") {
                findings.append(Finding(kind: .reboot, date: m.date, title: "\(name(m)) a redémarré",
                                        detail: m.message + ". Les appareils qui en dépendent ont pu perdre le réseau pendant le démarrage (souvent 1 à 3\u{00A0}minutes).",
                                        severity: .warning))
            } else if event == "authenticationfailure" || text.contains("authentication fail") || text.contains("login failed")
                        || text.contains("failed password") || text.contains("authentification refus") || (text.contains("admin login") && text.contains("fail")) {
                findings.append(Finding(kind: .authFailure, date: m.date, title: "Authentification refusée sur \(name(m))",
                                        detail: m.message, severity: .warning))
            } else if event == "fgtrapvpntundown" || (text.contains("tunnel") && text.contains("down")) {
                findings.append(Finding(kind: .vpnDown, date: m.date, title: "Tunnel VPN tombé (\(name(m)))", detail: m.message, severity: .error))
            } else if event.hasPrefix("fgtrapha") && event != "fgtraphamemberup" {
                findings.append(Finding(kind: .haSwitch, date: m.date, title: "Grappe HA de \(name(m))", detail: m.message, severity: .critical))
            } else if event == "fntrappowersupplyfailure" || text.contains("power supply") || text.contains("alimentation") {
                findings.append(Finding(kind: .power, date: m.date, title: "Alimentation de \(name(m))", detail: m.message, severity: .critical))
            }
        }
        // Constats répétés (5 refus d'authentification) : un seul, avec le nombre.
        findings = collapse(findings)
        // Premier message grave, s'il n'est pas déjà expliqué par un constat (à 5 s près).
        if let firstSevere, !findings.contains(where: { abs($0.date.timeIntervalSince(firstSevere.date)) <= 5 && $0.severity.isAtLeast(.error) }) {
            findings.append(Finding(kind: .firstSevere, date: firstSevere.date, title: "Premier message grave\u{00A0}: \(name(firstSevere))",
                                    detail: firstSevere.message, severity: firstSevere.severity))
        }
        if window.isEmpty {
            findings.append(Finding(kind: .quiet, date: center, title: "Aucun message dans cette fenêtre",
                                    detail: "Aucun équipement n’a rien signalé autour de cette heure. Élargissez la fenêtre, vérifiez que les équipements envoient bien leurs journaux à ce Mac, ou lisez les journaux de la FortiGate.",
                                    severity: .info))
        }
        findings.sort { $0.date < $1.date }
        return OutageReport(center: center, from: from, to: to, messages: window, devices: devices,
                            firstSevere: firstSevere, findings: findings)
    }

    static func collapse(_ findings: [Finding]) -> [Finding] {
        var result: [Finding] = []
        var seen: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for finding in findings {
            let key = finding.kind.rawValue + "|" + finding.title
            if let index = seen[key], finding.kind != .linkFlap {
                counts[key, default: 1] += 1
                result[index].detail = "\(counts[key]!) fois dans la fenêtre. " + finding.detail
                continue
            }
            seen[key] = result.count
            result.append(finding)
        }
        return result
    }

    /// Port d'un message de lien : trap linkDown/linkUp, mnémonique UPDOWN, ou texte « … down/up ».
    static func linkPort(_ m: LogMessage) -> (name: String, isDown: Bool)? {
        let event = (m.eventID ?? "").lowercased()
        if m.source == .trap, event == "linkdown" || event == "linkup" {
            let name = m.fields.first { $0.key.hasPrefix("1.3.6.1.2.1.31.1.1.1.1.") }?.value
                ?? m.fields.first { $0.key.hasPrefix("1.3.6.1.2.1.2.2.1.2.") }?.value
                ?? m.fields.first { $0.key.hasPrefix("1.3.6.1.2.1.2.2.1.1.") }.map { "ifIndex " + $0.value }
            guard let name else { return nil }
            return (name, event == "linkdown")
        }
        let text = m.message
        let lower = text.lowercased()
        // Cisco « changed state to down », HPE Aruba « port 14 is now off-line », Linux « link is down ».
        let down = lower.hasSuffix(" down") || lower.contains("changed state to down") || lower.contains("link down")
            || lower.contains("link is down") || lower.contains("is now off-line")
        let up = lower.hasSuffix(" up") || lower.contains("changed state to up") || lower.contains("link up")
            || lower.contains("link is up") || lower.contains("is now on-line")
        guard down || up else { return nil }
        // « Interface GigabitEthernet1/0/14, changed state to down », « port 14 link down », « port1/14 … ».
        let words = text.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        guard let name = words.first(where: { word in
            word.contains("/") && word.contains(where: \.isNumber) || word.lowercased().hasPrefix("port") && word.contains(where: \.isNumber)
        }) ?? words.enumerated().first(where: { $0.offset > 0 && words[$0.offset - 1].lowercased() == "port" && Int($0.element) != nil })?.element
        else { return nil }
        return (name, down && !up)
    }

    // MARK: Export

    /// CSV (séparateur « ; », champs protégés comme l'inventaire, fin de ligne CRLF).
    public static func csv(_ messages: [LogMessage], names: [String: String] = [:], counts: [UUID: Int] = [:]) -> String {
        var lines = ["Date;Appareil;Adresse;Site;Source;Gravité;Programme;Événement;Message" + (counts.isEmpty ? "" : ";Répétitions")]
        for m in messages {
            var fields = [LogFormat.iso(m.date), names[m.host] ?? m.deviceLabel, m.host, m.siteName, m.source.label,
                          m.severity.label, m.app ?? "", m.eventID ?? "", m.message]
            if !counts.isEmpty { fields.append(String(counts[m.id] ?? 1)) }
            lines.append(fields.map { InvCSV.quote($0, ";") }.joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
