import Foundation

// Note 78 (Wi-Fi de ce Mac) : relevé par pièce, enregistré par site. À chaque arrêt, l'utilisateur
// nomme la pièce et lance la mesure : signal, bruit, borne et débit du lien sont lus localement
// (CoreWLAN) ; la latence (ping de la passerelle) et, s'il le demande, le débit réel (court
// téléchargement) sont mesurés à ce moment-là seulement. Le relevé de chaque site va dans
// sites/<site>/wifi-releve.json ; il s'exporte en CSV.
//
// Modèle et calculs purs (aucun réseau) : les tests passent des mesures fixes.

/// Une mesure prise dans une pièce.
public struct WifiRoomMeasure: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var room: String
    public var time: Date
    public var ssid: String?
    public var bssid: String?
    public var band: WifiBand?
    public var channel: Int?
    public var rssi: Int
    public var noise: Int?
    /// Débit du lien annoncé par la carte Wi-Fi (Mb/s), sans trafic.
    public var linkRateMbps: Double?
    /// Latence vers la cible (médiane, ms) et sa gigue.
    public var latencyMs: Double?
    public var jitterMs: Double?
    /// Pings perdus, en %.
    public var lossPercent: Double?
    /// Cible de la latence (« passerelle 10.0.0.1 »).
    public var latencyTarget: String?
    /// Débit réel mesuré par un court téléchargement (Mb/s) ; nil : non demandé ou échoué.
    public var downloadMbps: Double?
    /// Remarque de la mesure (« débit non mesuré : serveur injoignable »).
    public var note: String?

    public init(id: UUID = UUID(), room: String, time: Date, ssid: String? = nil, bssid: String? = nil, band: WifiBand? = nil,
                channel: Int? = nil, rssi: Int, noise: Int? = nil, linkRateMbps: Double? = nil, latencyMs: Double? = nil,
                jitterMs: Double? = nil, lossPercent: Double? = nil, latencyTarget: String? = nil, downloadMbps: Double? = nil,
                note: String? = nil) {
        self.id = id
        self.room = room
        self.time = time
        self.ssid = ssid
        self.bssid = bssid
        self.band = band
        self.channel = channel
        self.rssi = rssi
        self.noise = noise
        self.linkRateMbps = linkRateMbps
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.latencyTarget = latencyTarget
        self.downloadMbps = downloadMbps
        self.note = note
    }

    public var snr: Int? { noise.map { rssi - $0 } }

    /// Constats de la mesure, du plus grave au moins grave.
    public var issues: [String] {
        var list: [String] = []
        if rssi < WifiRoomSurvey.weakRSSI { list.append("signal faible") }
        if let snr, snr < WifiRoomSurvey.weakSNR { list.append("bruit élevé (SNR \(snr)\u{00A0}dB)") }
        if let loss = lossPercent, loss >= WifiRoomSurvey.highLoss { list.append("pertes de \(WifiRoomSurvey.number(loss))\u{00A0}%") }
        if let latency = latencyMs, latency > WifiRoomSurvey.highLatency { list.append("latence élevée") }
        if let down = downloadMbps, down < WifiRoomSurvey.lowThroughput { list.append("débit faible") }
        return list
    }

    public var verdict: WifiRoomVerdict {
        if rssi < WifiRoomSurvey.weakRSSI || (lossPercent ?? 0) >= WifiRoomSurvey.severeLoss { return .faible }
        return issues.isEmpty ? .bon : .moyen
    }
}

/// Qualité d'une pièce.
public enum WifiRoomVerdict: String, Codable, Sendable, Comparable {
    case bon, moyen, faible

    public var label: String {
        switch self {
        case .bon: return "Bon"
        case .moyen: return "Moyen"
        case .faible: return "Faible"
        }
    }

    private var rank: Int { self == .bon ? 0 : (self == .moyen ? 1 : 2) }
    public static func < (lhs: WifiRoomVerdict, rhs: WifiRoomVerdict) -> Bool { lhs.rank < rhs.rank }
}

/// Résumé d'une pièce : sa dernière mesure et le nombre de mesures.
public struct WifiRoomSummary: Hashable, Sendable, Identifiable {
    public var room: String
    public var latest: WifiRoomMeasure
    public var count: Int
    public var id: String { room.lowercased() }
}

/// Relevé d'un site.
public struct WifiRoomSurvey: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "wifi-releve.json"
    /// Seuils des constats.
    public static let weakRSSI = -70
    public static let weakSNR = 20
    public static let highLatency = 30.0
    public static let highLoss = 2.0
    public static let severeLoss = 10.0
    public static let lowThroughput = 20.0
    /// Mesures gardées au plus (les plus anciennes partent d'abord).
    public static let maxMeasures = 2_000

    public var version: Int
    public var measures: [WifiRoomMeasure]

    public init(measures: [WifiRoomMeasure] = []) {
        version = Self.currentVersion
        self.measures = measures.sorted { $0.time < $1.time }
    }

    public var isEmpty: Bool { measures.isEmpty }

    /// Nom de pièce propre (espaces retirés) ; vide : « Point N ».
    public static func roomName(_ text: String, index: Int) -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Point \(index)" : name
    }

    public mutating func add(_ measure: WifiRoomMeasure) {
        measures.append(measure)
        measures.sort { $0.time < $1.time }
        if measures.count > Self.maxMeasures { measures.removeFirst(measures.count - Self.maxMeasures) }
    }

    public mutating func remove(_ ids: Set<UUID>) {
        measures.removeAll { ids.contains($0.id) }
    }

    /// Une ligne par pièce (nom sans tenir compte de la casse), la plus faible d'abord.
    public var rooms: [WifiRoomSummary] {
        var order: [String] = []
        var groups: [String: [WifiRoomMeasure]] = [:]
        for measure in measures {
            let key = measure.room.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(measure)
        }
        return order.compactMap { key in
            guard let list = groups[key], let latest = list.max(by: { $0.time < $1.time }) else { return nil }
            return WifiRoomSummary(room: latest.room, latest: latest, count: list.count)
        }
        .sorted { ($0.latest.verdict, $1.latest.rssi) > ($1.latest.verdict, $0.latest.rssi) }
    }

    /// « 6 pièces · 2 faibles · 1 moyenne ».
    public var summary: String {
        let list = rooms
        guard !list.isEmpty else { return "Aucune pièce mesurée" }
        let weak = list.filter { $0.latest.verdict == .faible }.count
        let average = list.filter { $0.latest.verdict == .moyen }.count
        var parts = ["\(list.count) pièce\(list.count > 1 ? "s" : "")"]
        if weak > 0 { parts.append("\(weak) faible\(weak > 1 ? "s" : "")") }
        if average > 0 { parts.append("\(average) moyenne\(average > 1 ? "s" : "")") }
        if weak == 0, average == 0 { parts.append("toutes bonnes") }
        return parts.joined(separator: " · ")
    }

    // MARK: Fichier

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(self)
    }

    /// Lecture tolérante : illisible ou d'une version future → nil (le fichier n'est pas écrasé).
    public static func decode(_ data: Data) -> WifiRoomSurvey? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let survey = try? decoder.decode(WifiRoomSurvey.self, from: data), survey.version <= currentVersion else { return nil }
        return survey
    }

    public static func url(in files: SiteFiles, siteKey: String) -> URL {
        files.folder(for: siteKey).appendingPathComponent(fileName)
    }

    // MARK: Export

    public static let csvHeader = ["Pièce", "Date", "Heure", "SSID", "BSSID", "Bande", "Canal", "Signal (dBm)", "Bruit (dBm)",
                                   "SNR (dB)", "Débit du lien (Mb/s)", "Latence (ms)", "Gigue (ms)", "Pertes (%)",
                                   "Cible de la latence", "Débit mesuré (Mb/s)", "Qualité", "Constats", "Remarque"]

    /// CSV (séparateur « ; », nombres à virgule) de toutes les mesures, de la plus ancienne à la plus récente.
    public func csv(site: String? = nil, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_CA")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let hour = DateFormatter()
        hour.locale = day.locale
        hour.timeZone = timeZone
        hour.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        if let site { lines.append(Self.csvLine(["Relevé Wi-Fi par pièce", site])) }
        lines.append(Self.csvLine(Self.csvHeader))
        for m in measures {
            lines.append(Self.csvLine([
                m.room, day.string(from: m.time), hour.string(from: m.time), m.ssid ?? "", m.bssid ?? "",
                m.band?.label.replacingOccurrences(of: "\u{00A0}", with: " ") ?? "", m.channel.map(String.init) ?? "",
                String(m.rssi), m.noise.map(String.init) ?? "", m.snr.map(String.init) ?? "",
                m.linkRateMbps.map(Self.number) ?? "", m.latencyMs.map(Self.number) ?? "", m.jitterMs.map(Self.number) ?? "",
                m.lossPercent.map(Self.number) ?? "", m.latencyTarget ?? "", m.downloadMbps.map(Self.number) ?? "",
                m.verdict.label, m.issues.joined(separator: ", ").replacingOccurrences(of: "\u{00A0}", with: " "), m.note ?? "",
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// « 12,4 », « 866 » (une décimale au plus, virgule).
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }

    static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            // Formules de tableur neutralisées (=, +, -, @ en tête), sauf les nombres négatifs.
            var text = field
            if let first = text.first, "=+@".contains(first) || (first == "-" && Double(text.replacingOccurrences(of: ",", with: ".")) == nil) {
                text = "'" + text
            }
            guard text.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        .joined(separator: ";")
    }
}
