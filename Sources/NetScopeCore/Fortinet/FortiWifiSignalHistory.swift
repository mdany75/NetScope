import Foundation

// Note 46 : historique du signal des clients Wi-Fi, un fichier par site
// (sites/<site>/wifi-signal.json). Chaque lecture des bornes ajoute un relevé par client (RSSI,
// SNR, débit, borne, bande, canal) ; la série de chaque client est bornée (nombre et âge), le
// nombre de clients aussi. Les dates des lectures sont gardées pour compter les déconnexions (un
// client présent à une lecture, absent à la suivante) et retrouver les itinérances (changement
// de borne d'un relevé au suivant). Fonctions pures ; l'app lit et écrit le fichier.

/// Un relevé du signal d'un client.
public struct FortiWifiSignalSample: Codable, Hashable, Sendable {
    public var date: Date
    public var rssi: Int?
    public var snr: Int?
    public var rateMbps: Double?
    public var apName: String?
    public var band: WifiBand?
    public var channel: Int?

    public init(date: Date, rssi: Int? = nil, snr: Int? = nil, rateMbps: Double? = nil, apName: String? = nil,
                band: WifiBand? = nil, channel: Int? = nil) {
        self.date = date
        self.rssi = rssi
        self.snr = snr
        self.rateMbps = rateMbps
        self.apName = apName
        self.band = band
        self.channel = channel
    }

    public init(_ client: FortiWifiClient, at date: Date) {
        self.init(date: date, rssi: client.rssi, snr: client.snr, rateMbps: client.rateMbps, apName: client.apName,
                  band: client.band, channel: client.channel)
    }
}

/// Passage d'une borne (ou d'une bande) à une autre entre deux relevés.
public struct FortiWifiRoam: Hashable, Sendable, Identifiable {
    public var id: String { "\(date.timeIntervalSince1970)|\(from ?? "")|\(to ?? "")" }
    public var date: Date
    public var from: String?
    public var to: String?
    public var fromBand: WifiBand?
    public var toBand: WifiBand?
    public var rssiBefore: Int?
    public var rssiAfter: Int?

    /// « AP-ACCUEIL → AP-ETG2 », « AP-ETG2 (5 GHz → 2,4 GHz) ».
    public var label: String {
        if from == to, let f = fromBand, let t = toBand { return "\(to ?? "Borne") (\(f.label) → \(t.label))" }
        return "\(from ?? "?") → \(to ?? "?")"
    }
}

/// Tendance du signal sur l'historique.
public enum FortiWifiSignalTrend: String, Hashable, Sendable {
    case falling, stable, rising, unknown

    public var label: String {
        switch self {
        case .falling: return "en baisse"
        case .stable: return "stable"
        case .rising: return "en hausse"
        case .unknown: return "pas assez de relevés"
        }
    }
}

/// Historique du signal des clients d'UN site.
public struct FortiWifiSignalHistory: Codable, Hashable, Sendable {
    /// Bornes de l'historique.
    public struct Limits: Hashable, Sendable {
        /// Relevés gardés par client (les plus anciens tombent).
        public var samplesPerClient: Int
        /// Âge maximal d'un relevé, en secondes.
        public var maxAge: TimeInterval
        /// Clients gardés (les moins récemment vus tombent).
        public var clients: Int
        /// Écart minimal entre deux lectures enregistrées (une lecture plus rapprochée est ignorée).
        public var minInterval: TimeInterval

        public init(samplesPerClient: Int = 288, maxAge: TimeInterval = 14 * 86_400, clients: Int = 2000, minInterval: TimeInterval = 30) {
            self.samplesPerClient = max(2, samplesPerClient)
            self.maxAge = max(60, maxAge)
            self.clients = max(1, clients)
            self.minInterval = max(0, minInterval)
        }

        public static let standard = Limits()
    }

    public static let fileName = "wifi-signal.json"
    public static let currentVersion = 1

    public var version: Int
    /// Relevés par client : MAC (« AA:BB:CC:DD:EE:FF ») → relevés du plus ancien au plus récent.
    public var series: [String: [FortiWifiSignalSample]]
    /// Dates des lectures enregistrées (du plus ancien au plus récent), bornées comme les relevés.
    public var readings: [Date]

    public init(series: [String: [FortiWifiSignalSample]] = [:], readings: [Date] = []) {
        version = Self.currentVersion
        self.series = series
        self.readings = readings
    }

    public var isEmpty: Bool { series.isEmpty }

    static func key(_ mac: MACAddress) -> String { mac.formatted(.upperColon) }

    /// Ajoute une lecture des bornes : un relevé par client. Une lecture trop proche de la
    /// précédente (`minInterval`) ou plus ancienne est ignorée (vrai : enregistrée).
    @discardableResult
    public mutating func record(_ clients: [FortiWifiClient], at date: Date, limits: Limits = .standard) -> Bool {
        if let last = readings.last, date.timeIntervalSince(last) < limits.minInterval { return false }
        readings.append(date)
        var seen = Set<String>()
        for client in clients {
            let k = Self.key(client.mac)
            guard seen.insert(k).inserted else { continue }
            series[k, default: []].append(FortiWifiSignalSample(client, at: date))
        }
        prune(now: date, limits: limits)
        return true
    }

    /// Retire ce qui dépasse les bornes : relevés trop vieux ou trop nombreux, clients en trop.
    public mutating func prune(now: Date, limits: Limits = .standard) {
        let oldest = now.addingTimeInterval(-limits.maxAge)
        readings.removeAll { $0 < oldest }
        if readings.count > limits.samplesPerClient * 4 { readings.removeFirst(readings.count - limits.samplesPerClient * 4) }
        for (k, list) in series {
            var kept = list.filter { $0.date >= oldest }
            if kept.count > limits.samplesPerClient { kept.removeFirst(kept.count - limits.samplesPerClient) }
            series[k] = kept.isEmpty ? nil : kept
        }
        if series.count > limits.clients {
            let byLast = series.map { ($0.key, $0.value.last?.date ?? .distantPast) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            for (k, _) in byLast.dropFirst(limits.clients) { series[k] = nil }
        }
    }

    /// Relevés d'un client, du plus ancien au plus récent.
    public func samples(for mac: MACAddress) -> [FortiWifiSignalSample] { series[Self.key(mac)] ?? [] }

    /// Relevés des `seconds` dernières secondes avant `now`.
    public func samples(for mac: MACAddress, within seconds: TimeInterval, now: Date) -> [FortiWifiSignalSample] {
        samples(for: mac).filter { $0.date >= now.addingTimeInterval(-seconds) && $0.date <= now }
    }

    /// Itinérances : changement de borne (ou de bande sur la même borne) d'un relevé au suivant.
    public func roams(for mac: MACAddress) -> [FortiWifiRoam] {
        let list = samples(for: mac)
        guard list.count > 1 else { return [] }
        var result: [FortiWifiRoam] = []
        for i in 1..<list.count {
            let a = list[i - 1], b = list[i]
            let apChanged = a.apName != nil && b.apName != nil && a.apName?.lowercased() != b.apName?.lowercased()
            let bandChanged = !apChanged && a.band != nil && b.band != nil && a.band != b.band
            guard apChanged || bandChanged else { continue }
            result.append(FortiWifiRoam(date: b.date, from: a.apName, to: b.apName, fromBand: a.band, toBand: b.band,
                                        rssiBefore: a.rssi, rssiAfter: b.rssi))
        }
        return result
    }

    /// Déconnexions vues : lectures où le client, présent à la lecture précédente, n'était plus là
    /// (dates de ces lectures). Avant son premier relevé, le client n'est pas compté.
    public func disconnections(for mac: MACAddress) -> [Date] {
        let list = samples(for: mac)
        guard let first = list.first?.date else { return [] }
        let present = Set(list.map(\.date))
        var result: [Date] = []
        var wasPresent = false
        for date in readings where date >= first {
            let here = present.contains(date)
            if wasPresent && !here { result.append(date) }
            wasPresent = here
        }
        return result
    }

    /// Tendance du RSSI : moyenne du dernier tiers comparée à celle du premier tiers (écart de
    /// 4 dB ou plus). Moins de quatre relevés avec un signal : inconnue.
    public func trend(for mac: MACAddress) -> FortiWifiSignalTrend {
        let values = samples(for: mac).compactMap(\.rssi)
        guard values.count >= 4 else { return .unknown }
        let third = max(1, values.count / 3)
        let head = Double(values.prefix(third).reduce(0, +)) / Double(third)
        let tail = Double(values.suffix(third).reduce(0, +)) / Double(third)
        if tail - head <= -4 { return .falling }
        if tail - head >= 4 { return .rising }
        return .stable
    }

    /// RSSI le plus faible, le plus fort et moyen de l'historique.
    public func range(for mac: MACAddress) -> (min: Int, max: Int, average: Int)? {
        let values = samples(for: mac).compactMap(\.rssi)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return (lo, hi, Int((Double(values.reduce(0, +)) / Double(values.count)).rounded()))
    }

    // MARK: Fichier

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// Lecture tolérante : fichier illisible ou d'une version future → nil (l'app repart d'un
    /// historique vide sans écraser un fichier plus récent qu'elle ne comprend pas).
    public static func decode(_ data: Data) -> FortiWifiSignalHistory? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let history = try? decoder.decode(FortiWifiSignalHistory.self, from: data),
              history.version <= currentVersion else { return nil }
        return history
    }

    public static func url(in files: SiteFiles, siteKey: String) -> URL {
        files.folder(for: siteKey).appendingPathComponent(fileName)
    }
}

/// Historiques de plusieurs sites (un par site, jamais fusionnés).
public struct FortiWifiSignalBook: Hashable, Sendable {
    public var sites: [String: FortiWifiSignalHistory]

    public init(sites: [String: FortiWifiSignalHistory] = [:]) {
        self.sites = sites
    }

    /// Enregistre la lecture de chaque site dans SON historique (clé du site → clients lus).
    /// Rend les clés des sites modifiés (à écrire sur le disque).
    @discardableResult
    public mutating func record(_ readings: [String: [FortiWifiClient]], at date: Date,
                                limits: FortiWifiSignalHistory.Limits = .standard) -> [String] {
        var changed: [String] = []
        for (siteKey, clients) in readings.sorted(by: { $0.key < $1.key }) {
            var history = sites[siteKey] ?? FortiWifiSignalHistory()
            if history.record(clients, at: date, limits: limits) {
                sites[siteKey] = history
                changed.append(siteKey)
            }
        }
        return changed
    }

    public func history(site: String) -> FortiWifiSignalHistory { sites[site] ?? FortiWifiSignalHistory() }
}
