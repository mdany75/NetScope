import Foundation

// Note 74 : fichier de l'historique du trafic des ports, un par site :
//
//   ~/Library/Application Support/NetScope/sites/<clé du site>/trafic-ports.json
//
// JSON compact : chaque point est un tableau de nombres [écart avec le point précédent, durée,
// secondes mesurées, débits moyens et maximaux en kb/s, erreurs], pour garder le fichier petit
// (de l'ordre de 100 Ko par port actif suivi 90 jours, une dizaine de Mo pour une centaine de ports). Aucun secret : seulement
// des adresses de switchs, des noms de ports et des compteurs. À la lecture, ce qui a dépassé sa
// durée de conservation est regroupé ou oublié ; un fichier d'une version future ou illisible est
// ignoré (et laissé de côté), jamais une cause de plantage.

public enum PortHistoryFile {
    public static let fileName = "trafic-ports.json"
    public static let version = 1

    public static func url(in files: SiteFiles, siteKey: String) -> URL {
        files.folder(for: siteKey).appendingPathComponent(fileName)
    }

    // MARK: Format

    struct Document: Codable {
        var version: Int
        var savedAt: Date
        var switches: [SwitchEntry]
    }

    struct SwitchEntry: Codable {
        var host: String
        var name: String
        var ports: [PortEntry]
    }

    struct PortEntry: Codable {
        var index: Int
        var name: String
        var alias: String?
        var speed: UInt64?
        var up: Bool?
        var base: PortCounterBaseline?
        var points: [[Double]]
    }

    /// Débit en kb/s, au dixième (les ports presque inactifs gardent leur faible trafic).
    static func kbps(_ bitsPerSecond: Double) -> Double { (bitsPerSecond / 100).rounded() / 10 }

    /// Point → [écart avec la fin du point précédent (s), durée (s), secondes mesurées, débit moyen
    /// entrant et sortant (kb/s), débit max entrant et sortant (kb/s), erreurs].
    static func encodePoint(_ p: PortTrafficPoint, after previous: Date?) -> [Double] {
        let offset = previous.map { p.start.timeIntervalSince($0) } ?? p.start.timeIntervalSince1970
        return [offset.rounded(), p.end.timeIntervalSince(p.start).rounded(), p.covered.rounded(),
                kbps(p.inAverage), kbps(p.outAverage), kbps(p.inPeak), kbps(p.outPeak), Double(p.errors)]
    }

    static func decodePoint(_ values: [Double], after previous: Date?) -> PortTrafficPoint? {
        guard values.count >= 5, values.allSatisfy(\.isFinite) else { return nil }
        let start = previous.map { $0.addingTimeInterval(values[0]) } ?? Date(timeIntervalSince1970: values[0])
        let end = start.addingTimeInterval(max(0, values[1]))
        let covered = max(0, values[2])
        func at(_ i: Int) -> Double? { values.count > i ? max(0, values[i]) * 1000 : nil }
        let errors = values.count > 7 && values[7] >= 0 && values[7] < 1e18 ? UInt64(values[7]) : 0
        let inAverage = max(0, values[3]) * 1000, outAverage = max(0, values[4]) * 1000
        return PortTrafficPoint(start: start, end: end, covered: covered,
                                inBytes: inAverage * covered / 8, outBytes: outAverage * covered / 8,
                                inPeak: at(5).map { max($0, inAverage) }, outPeak: at(6).map { max($0, outAverage) }, errors: errors)
    }

    static func encodePoints(_ points: [PortTrafficPoint]) -> [[Double]] {
        // L'écart est calculé depuis la fin du point précédent telle qu'elle sera relue (arrondie) :
        // les arrondis ne s'accumulent pas d'un point à l'autre.
        var previous: Date?
        return points.map { point in
            let row = encodePoint(point, after: previous)
            let start = previous.map { $0.addingTimeInterval(row[0]) } ?? Date(timeIntervalSince1970: row[0])
            previous = start.addingTimeInterval(row[1])
            return row
        }
    }

    static func decodePoints(_ rows: [[Double]]) -> [PortTrafficPoint] {
        var previous: Date?
        var result: [PortTrafficPoint] = []
        for row in rows {
            guard let point = decodePoint(row, after: previous) else { continue }
            result.append(point)
            previous = point.end
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Contenu du fichier.
    public static func encode(_ history: PortTrafficHistory, savedAt: Date = Date()) -> Data? {
        let switches = history.switches.values.sorted { $0.host < $1.host }.map { entry in
            SwitchEntry(host: entry.host, name: entry.name, ports: entry.orderedPorts.map { series in
                PortEntry(index: series.ifIndex, name: series.name, alias: series.alias.isEmpty ? nil : series.alias,
                          speed: series.speedMbps, up: series.isUp, base: series.baseline,
                          points: encodePoints(series.points))
            })
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(Document(version: version, savedAt: savedAt, switches: switches))
    }

    /// Lecture d'un fichier ; nil s'il est illisible ou d'une version plus récente. Les points
    /// anciens sont regroupés et ceux de plus de 90 jours oubliés (`now`).
    public static func decode(_ data: Data, now: Date = Date()) -> PortTrafficHistory? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let document = try? decoder.decode(Document.self, from: data), document.version >= 1, document.version <= version else {
            return nil
        }
        var switches: [String: PortSwitchHistory] = [:]
        for entry in document.switches where !entry.host.isEmpty {
            var history = switches[entry.host] ?? PortSwitchHistory(host: entry.host, name: entry.name)
            for port in entry.ports {
                let points = decodePoints(port.points)
                history.ports[port.index] = PortTrafficSeries(ifIndex: port.index, name: port.name, alias: port.alias ?? "",
                                                              speedMbps: port.speed, isUp: port.up ?? true,
                                                              points: points, baseline: port.base)
            }
            switches[entry.host] = history
        }
        var history = PortTrafficHistory(switches: switches)
        history.compact(now: now)
        return history
    }

    // MARK: Disque

    /// État d'un fichier lu.
    public enum LoadResult {
        case missing
        case loaded(PortTrafficHistory)
        case unreadable
    }

    public static func load(from url: URL, now: Date = Date()) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let history = decode(data, now: now) else { return .unreadable }
        return .loaded(history)
    }

    /// Écrit le fichier (atomique). Un historique vide efface le fichier.
    public static func save(_ history: PortTrafficHistory, to url: URL, now: Date = Date()) throws {
        if history.isEmpty && history.switches.values.allSatisfy({ $0.ports.values.allSatisfy { $0.baseline == nil } }) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = encode(history, savedAt: now) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Fichier illisible : mis de côté (trafic-ports.illisible-<date>.json) plutôt qu'écrasé.
    @discardableResult
    public static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let aside = url.deletingLastPathComponent().appendingPathComponent("trafic-ports.illisible-\(Int(now.timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            return nil
        }
    }
}

// MARK: - Relevés d'un switch

extension PortCounterReading {
    /// Compteurs des ports d'un relevé complet (SNMP ifHC* ou FortiGate). Les ports sans compteur
    /// d'octets sont écartés ; seuls les ports physiques sont suivis.
    public static func readings(from snapshot: SNMPSwitchSnapshot) -> [PortCounterReading] {
        snapshot.physicalPorts.compactMap { iface in
            guard let inOctets = iface.inOctets, let outOctets = iface.outOctets else { return nil }
            return PortCounterReading(ifIndex: iface.index, name: iface.name, alias: iface.alias, speedMbps: iface.speedMbps,
                                      isUp: iface.isUp, inOctets: inOctets, outOctets: outOctets, width: .bits64,
                                      inErrors: iface.inErrors)
        }
    }

    /// Compteurs du panneau « Trafic du port » (IF-MIB, 64 bits ou 32 bits), limités aux ports `keep`.
    public static func readings(from ports: [SNMPPortCounters], keep: Set<Int>? = nil) -> [PortCounterReading] {
        ports.compactMap { port in
            if let keep, !keep.contains(port.index) { return nil }
            return PortCounterReading(ifIndex: port.index, name: port.name, alias: port.alias, speedMbps: port.counters.speedMbps,
                                      isUp: port.isUp, inOctets: port.counters.inOctets, outOctets: port.counters.outOctets,
                                      width: port.counters.width, inErrors: port.counters.inErrors)
        }
    }
}
