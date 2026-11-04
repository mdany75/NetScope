import Foundation

// Note 47 : diagnostic des problèmes Wi-Fi d'un client, d'une borne ou d'un SSID, avec solutions.
// Modèles du diagnostic : verdict par cause, preuves chiffrées, actions suggérées, seuils réglables,
// données facultatives du client (standard, flux, déconnexions…) et mesures facultatives (ping
// depuis ce Mac, port du switch de la borne, étendue DHCP, WAN). Lecture seule : NetScope propose,
// le technicien applique ; rien n'est modifié sur la FortiGate.

/// Verdict d'une cause.
public enum WifiVerdict: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Rien pour en juger (mesure absente, borne inconnue).
    case notMeasured = 0
    case ok = 1
    /// À surveiller : proche d'un seuil, ou indice sans preuve formelle.
    case watch = 2
    case problem = 3

    public static func < (lhs: WifiVerdict, rhs: WifiVerdict) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .notMeasured: return "Non vérifié"
        case .ok: return "OK"
        case .watch: return "À surveiller"
        case .problem: return "Problème"
        }
    }
}

/// Cause possible d'un problème Wi-Fi (note 47), dans l'ordre où on les vérifie.
public enum WifiCause: String, Codable, Sendable, CaseIterable {
    case signal, sticky, channel, interference, width, dfs, load, slowClients, client, band, connection, dhcp, network, uplink, wan, ssid

    public var title: String {
        switch self {
        case .signal: return "Signal"
        case .sticky: return "Client collant (itinérance)"
        case .channel: return "Canal et chevauchements"
        case .interference: return "Interférences et AP voisins"
        case .width: return "Largeur du canal"
        case .dfs: return "Canal DFS (radar)"
        case .load: return "Charge de la borne"
        case .slowClients: return "Clients lents sur la radio"
        case .client: return "Capacités du client"
        case .band: return "Bande utilisée"
        case .connection: return "Connexion et authentification"
        case .dhcp: return "Adresse IP (DHCP)"
        case .network: return "Au-delà du Wi-Fi (passerelle, DNS, Internet)"
        case .uplink: return "Lien de la borne vers son switch"
        case .wan: return "WAN du site"
        case .ssid: return "Limites du SSID"
        }
    }

    /// À verdict égal et force égale, la cause la plus probable d'abord (le signal explique la
    /// plupart des lenteurs ; le WAN, rarement un seul client).
    var rank: Int { WifiCause.allCases.firstIndex(of: self) ?? 0 }
}

/// Résultat d'une cause.
public struct WifiCauseResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String { cause.rawValue }
    public var cause: WifiCause
    public var verdict: WifiVerdict
    /// Une phrase en clair (« Le client reçoit −77 dBm : trop faible pour un bon débit. »).
    public var summary: String
    /// Mesures qui le prouvent (« RSSI −77 dBm (seuil −70 dBm) »).
    public var evidence: [String]
    /// Actions suggérées, dans l'ordre.
    public var actions: [String]
    /// Force de 0 à 1 : à verdict égal, la plus forte passe en tête.
    public var weight: Double

    public init(cause: WifiCause, verdict: WifiVerdict, summary: String, evidence: [String] = [], actions: [String] = [], weight: Double = 0) {
        self.cause = cause
        self.verdict = verdict
        self.summary = summary
        self.evidence = evidence
        self.actions = actions
        self.weight = min(1, max(0, weight))
    }

    public var title: String { cause.title }
}

/// Seuils du diagnostic (réglables ; ceux du signal et de la charge reprennent ceux de Wi-Fi › FortiAP).
public struct WifiDiagnosisThresholds: Codable, Hashable, Sendable {
    /// À surveiller sous ce RSSI, problème sous `badRSSI` (dBm).
    public var weakRSSI: Int
    public var badRSSI: Int
    /// À surveiller sous ce SNR, problème sous `badSNR` (dB).
    public var weakSNR: Int
    public var badSNR: Int
    /// Utilisation du canal : à surveiller au-delà de `busyUtilization`, problème au-delà de `saturatedUtilization` (%).
    public var busyUtilization: Double
    public var saturatedUtilization: Double
    /// Clients par radio au-delà desquels la borne est surchargée (à surveiller dès 75 % de ce nombre).
    public var maxClientsPerRadio: Int
    /// Bruit de fond au-dessus duquel la radio est bruyante (dBm).
    public var noisyFloor: Int
    /// Un AP voisin compte s'il est reçu plus fort que ce niveau (dBm).
    public var neighborRSSI: Int
    /// Débit négocié bas (Mb/s).
    public var lowRateMbps: Double
    /// Part des clients lents de la radio à partir de laquelle ils pèsent sur les autres.
    public var slowShare: Double
    /// Client collant : une autre borne entendue au moins ce nombre de dB plus fort.
    public var stickyMarginDB: Int
    /// Perte : à surveiller au-delà de `lossWatch`, problème au-delà de `lossProblem` (%).
    public var lossWatch: Double
    public var lossProblem: Double
    /// Latence vers la passerelle (ms).
    public var gatewayLatencyWatch: Double
    public var gatewayLatencyProblem: Double
    /// Latence vers Internet (ms).
    public var internetLatencyWatch: Double
    public var internetLatencyProblem: Double
    /// Gigue (ms).
    public var jitterWatch: Double
    /// Déconnexions sur la période observée : à surveiller, problème.
    public var disconnectsWatch: Int
    public var disconnectsProblem: Int
    /// Itinérances par heure au-delà desquelles le client « rebondit ».
    public var roamsPerHourWatch: Int
    /// Échecs d'authentification : problème dès ce nombre.
    public var authFailuresProblem: Int
    /// Délai d'obtention de l'adresse DHCP (ms) : à surveiller, problème.
    public var dhcpDelayWatch: Double
    public var dhcpDelayProblem: Double

    public init(weakRSSI: Int = -70, badRSSI: Int = -78, weakSNR: Int = 20, badSNR: Int = 12, busyUtilization: Double = 50,
                saturatedUtilization: Double = 70, maxClientsPerRadio: Int = 30, noisyFloor: Int = -85, neighborRSSI: Int = -80,
                lowRateMbps: Double = 24, slowShare: Double = 0.3, stickyMarginDB: Int = 8, lossWatch: Double = 1, lossProblem: Double = 5,
                gatewayLatencyWatch: Double = 20, gatewayLatencyProblem: Double = 50, internetLatencyWatch: Double = 80,
                internetLatencyProblem: Double = 150, jitterWatch: Double = 30, disconnectsWatch: Int = 3, disconnectsProblem: Int = 8,
                roamsPerHourWatch: Int = 6, authFailuresProblem: Int = 3, dhcpDelayWatch: Double = 2000, dhcpDelayProblem: Double = 5000) {
        self.weakRSSI = weakRSSI
        self.badRSSI = min(badRSSI, weakRSSI)
        self.weakSNR = weakSNR
        self.badSNR = min(badSNR, weakSNR)
        self.busyUtilization = busyUtilization
        self.saturatedUtilization = max(saturatedUtilization, busyUtilization)
        self.maxClientsPerRadio = max(1, maxClientsPerRadio)
        self.noisyFloor = noisyFloor
        self.neighborRSSI = neighborRSSI
        self.lowRateMbps = max(1, lowRateMbps)
        self.slowShare = min(1, max(0.05, slowShare))
        self.stickyMarginDB = max(1, stickyMarginDB)
        self.lossWatch = lossWatch
        self.lossProblem = max(lossProblem, lossWatch)
        self.gatewayLatencyWatch = gatewayLatencyWatch
        self.gatewayLatencyProblem = max(gatewayLatencyProblem, gatewayLatencyWatch)
        self.internetLatencyWatch = internetLatencyWatch
        self.internetLatencyProblem = max(internetLatencyProblem, internetLatencyWatch)
        self.jitterWatch = jitterWatch
        self.disconnectsWatch = max(1, disconnectsWatch)
        self.disconnectsProblem = max(disconnectsProblem, self.disconnectsWatch)
        self.roamsPerHourWatch = max(1, roamsPerHourWatch)
        self.authFailuresProblem = max(1, authFailuresProblem)
        self.dhcpDelayWatch = dhcpDelayWatch
        self.dhcpDelayProblem = max(dhcpDelayProblem, dhcpDelayWatch)
    }

    public static let standard = WifiDiagnosisThresholds()

    /// Seuils alignés sur ceux de Wi-Fi › FortiAP (signal faible, surcharge) ; le seuil « problème »
    /// du signal reste 8 dB plus bas.
    public init(forti: FortiWifiThresholds) {
        let d = WifiDiagnosisThresholds.standard
        self.init(weakRSSI: forti.weakRSSI, badRSSI: forti.weakRSSI - 8, weakSNR: forti.weakSNR, badSNR: max(5, forti.weakSNR - 8),
                  busyUtilization: min(d.busyUtilization, forti.maxChannelUtilization), saturatedUtilization: forti.maxChannelUtilization,
                  maxClientsPerRadio: forti.maxClientsPerRadio)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WifiDiagnosisThresholds.standard
        func int(_ key: CodingKeys, _ fallback: Int) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? fallback }
        func dbl(_ key: CodingKeys, _ fallback: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback }
        self.init(weakRSSI: int(.weakRSSI, d.weakRSSI), badRSSI: int(.badRSSI, d.badRSSI), weakSNR: int(.weakSNR, d.weakSNR),
                  badSNR: int(.badSNR, d.badSNR), busyUtilization: dbl(.busyUtilization, d.busyUtilization),
                  saturatedUtilization: dbl(.saturatedUtilization, d.saturatedUtilization),
                  maxClientsPerRadio: int(.maxClientsPerRadio, d.maxClientsPerRadio), noisyFloor: int(.noisyFloor, d.noisyFloor),
                  neighborRSSI: int(.neighborRSSI, d.neighborRSSI), lowRateMbps: dbl(.lowRateMbps, d.lowRateMbps),
                  slowShare: dbl(.slowShare, d.slowShare), stickyMarginDB: int(.stickyMarginDB, d.stickyMarginDB),
                  lossWatch: dbl(.lossWatch, d.lossWatch), lossProblem: dbl(.lossProblem, d.lossProblem),
                  gatewayLatencyWatch: dbl(.gatewayLatencyWatch, d.gatewayLatencyWatch),
                  gatewayLatencyProblem: dbl(.gatewayLatencyProblem, d.gatewayLatencyProblem),
                  internetLatencyWatch: dbl(.internetLatencyWatch, d.internetLatencyWatch),
                  internetLatencyProblem: dbl(.internetLatencyProblem, d.internetLatencyProblem),
                  jitterWatch: dbl(.jitterWatch, d.jitterWatch), disconnectsWatch: int(.disconnectsWatch, d.disconnectsWatch),
                  disconnectsProblem: int(.disconnectsProblem, d.disconnectsProblem),
                  roamsPerHourWatch: int(.roamsPerHourWatch, d.roamsPerHourWatch),
                  authFailuresProblem: int(.authFailuresProblem, d.authFailuresProblem),
                  dhcpDelayWatch: dbl(.dhcpDelayWatch, d.dhcpDelayWatch), dhcpDelayProblem: dbl(.dhcpDelayProblem, d.dhcpDelayProblem))
    }
}

// MARK: - Données facultatives du client

/// Génération Wi-Fi du client.
public enum WifiStandard: String, Codable, Sendable, CaseIterable, Comparable {
    /// 802.11a, b ou g.
    case legacy
    case wifi4, wifi5, wifi6, wifi6E, wifi7

    public static func < (lhs: WifiStandard, rhs: WifiStandard) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    public var label: String {
        switch self {
        case .legacy: return "802.11a/b/g"
        case .wifi4: return "Wi-Fi 4 (802.11n)"
        case .wifi5: return "Wi-Fi 5 (802.11ac)"
        case .wifi6: return "Wi-Fi 6 (802.11ax)"
        case .wifi6E: return "Wi-Fi 6E (802.11ax, 6\u{00A0}GHz)"
        case .wifi7: return "Wi-Fi 7 (802.11be)"
        }
    }

    /// Lit « 802.11ax », « 11ac », « ax », « Wi-Fi 6E », « be », « n », « g »…
    public static func parse(_ text: String?) -> WifiStandard? {
        guard var t = text?.lowercased().trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: "802.11", with: "").replacingOccurrences(of: "wi-fi", with: "wifi")
            .replacingOccurrences(of: " ", with: "")
        if t.contains("wifi7") || t.hasPrefix("be") || t.contains("11be") { return .wifi7 }
        if t.contains("wifi6e") || t.contains("6e") || (t.hasPrefix("ax") && t.contains("6g")) { return .wifi6E }
        if t.contains("wifi6") || t.hasPrefix("ax") || t.contains("11ax") || t == "he" { return .wifi6 }
        if t.contains("wifi5") || t.hasPrefix("ac") || t.contains("11ac") || t == "vht" { return .wifi5 }
        if t.contains("wifi4") || t.hasPrefix("n") || t.contains("11n") || t == "ht" { return .wifi4 }
        if t.hasPrefix("a") || t.hasPrefix("b") || t.hasPrefix("g") { return .legacy }
        return nil
    }
}

/// Borne entendue par le client (rapport de voisinage 802.11k, sondes), avec son niveau.
public struct WifiHeardAP: Codable, Hashable, Sendable {
    public var apName: String
    public var rssi: Int

    public init(apName: String, rssi: Int) {
        self.apName = apName
        self.rssi = rssi
    }
}

/// Ce que la FortiGate ou la fiche du client (note 46) sait en plus de la liste des clients.
/// Tout est facultatif : une donnée absente laisse la cause « non vérifiée » ou se contente du reste.
public struct WifiClientDetails: Codable, Hashable, Sendable {
    public var standard: WifiStandard?
    public var spatialStreams: Int?
    /// Débits négociés borne → client et client → borne (Mb/s).
    public var txRateMbps: Double?
    public var rxRateMbps: Double?
    /// Économie d'énergie active sur le poste.
    public var powerSave: Bool?
    /// Le client sait-il se connecter en 5 GHz (vu en 5 GHz, ou capacité annoncée) ?
    public var supports5GHz: Bool?
    public var supports6GHz: Bool?
    /// « 802.1X », « PSK », « WPA3-SAE ».
    public var authMethod: String?
    public var authFailures: Int?
    /// Dernière raison d'échec telle que lue (« mauvais mot de passe », « RADIUS refusé »).
    public var lastFailureReason: String?
    public var disconnects: Int?
    public var roams: Int?
    /// Période observée pour les compteurs ci-dessus (minutes).
    public var windowMinutes: Int?
    /// Délai d'obtention de l'adresse (ms).
    public var dhcpDelayMs: Double?
    /// Autres bornes entendues par le client.
    public var heardAPs: [WifiHeardAP]
    /// RSSI récents (du plus ancien au plus récent).
    public var signalHistory: [Int]

    public init(standard: WifiStandard? = nil, spatialStreams: Int? = nil, txRateMbps: Double? = nil, rxRateMbps: Double? = nil,
                powerSave: Bool? = nil, supports5GHz: Bool? = nil, supports6GHz: Bool? = nil, authMethod: String? = nil,
                authFailures: Int? = nil, lastFailureReason: String? = nil, disconnects: Int? = nil, roams: Int? = nil,
                windowMinutes: Int? = nil, dhcpDelayMs: Double? = nil, heardAPs: [WifiHeardAP] = [], signalHistory: [Int] = []) {
        self.standard = standard
        self.spatialStreams = spatialStreams
        self.txRateMbps = txRateMbps
        self.rxRateMbps = rxRateMbps
        self.powerSave = powerSave
        self.supports5GHz = supports5GHz
        self.supports6GHz = supports6GHz
        self.authMethod = authMethod
        self.authFailures = authFailures
        self.lastFailureReason = lastFailureReason
        self.disconnects = disconnects
        self.roams = roams
        self.windowMinutes = windowMinutes
        self.dhcpDelayMs = dhcpDelayMs
        self.heardAPs = heardAPs
        self.signalHistory = signalHistory
    }
}

// MARK: - Mesures facultatives

/// Cible d'une mesure de ping depuis ce Mac.
public enum WifiPathTarget: String, Codable, Sendable, CaseIterable {
    case gateway, dns, internet

    public var label: String {
        switch self {
        case .gateway: return "Passerelle"
        case .dns: return "DNS"
        case .internet: return "Internet"
        }
    }
}

/// Ping de quelques secondes vers une cible.
public struct WifiPathMeasure: Codable, Hashable, Sendable {
    public var target: WifiPathTarget
    public var address: String
    public var sent: Int
    public var received: Int
    public var averageMs: Double?
    public var maxMs: Double?
    public var jitterMs: Double?

    public init(target: WifiPathTarget, address: String, sent: Int, received: Int, averageMs: Double? = nil, maxMs: Double? = nil,
                jitterMs: Double? = nil) {
        self.target = target
        self.address = address
        self.sent = max(0, sent)
        self.received = min(max(0, received), max(0, sent))
        self.averageMs = averageMs
        self.maxMs = maxMs
        self.jitterMs = jitterMs
    }

    public init(target: WifiPathTarget, address: String, statistics: PingStatistics) {
        self.init(target: target, address: address, sent: statistics.sent, received: statistics.received,
                  averageMs: statistics.average, maxMs: statistics.max, jitterMs: statistics.jitter)
    }

    public var lossPercent: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }
}

/// Port du switch où la borne est branchée (FortiSwitch, note 33).
public struct WifiUplinkStatus: Codable, Hashable, Sendable {
    public var switchName: String
    public var portName: String
    public var linkUp: Bool?
    public var speedMbps: UInt64?
    public var duplex: String?
    public var rxErrors: UInt64?
    /// État PoE lisible (« Alimenté », « Défaut »).
    public var poeLabel: String?
    public var poeFault: Bool
    public var poePowerW: Double?

    public init(switchName: String, portName: String, linkUp: Bool? = nil, speedMbps: UInt64? = nil, duplex: String? = nil,
                rxErrors: UInt64? = nil, poeLabel: String? = nil, poeFault: Bool = false, poePowerW: Double? = nil) {
        self.switchName = switchName
        self.portName = portName
        self.linkUp = linkUp
        self.speedMbps = speedMbps
        self.duplex = duplex
        self.rxErrors = rxErrors
        self.poeLabel = poeLabel
        self.poeFault = poeFault
        self.poePowerW = poePowerW
    }

    public init(switchName: String, port: FortiSwitchPort) {
        let detection = port.poeDetection
        let fault = detection == .fault || detection == .otherFault
        self.init(switchName: switchName, portName: port.name, linkUp: port.linkUp, speedMbps: port.speedMbps, duplex: port.duplex,
                  rxErrors: port.rxErrors, poeLabel: detection?.label ?? port.poeState, poeFault: fault, poePowerW: port.poePowerW)
    }

    public var label: String { "\(switchName) \(portName)" }
}

/// Étendue DHCP du VLAN du client (note 37).
public struct WifiDHCPStatus: Codable, Hashable, Sendable {
    public var scopeName: String
    public var percent: Double
    public var free: Int
    public var poolSize: Int
    public var critical: Bool
    public var warning: Bool

    public init(scopeName: String, percent: Double, free: Int, poolSize: Int, critical: Bool = false, warning: Bool = false) {
        self.scopeName = scopeName
        self.percent = percent
        self.free = free
        self.poolSize = poolSize
        self.critical = critical
        self.warning = warning
    }

    public init(usage: DHCPScopeUsage) {
        self.init(scopeName: usage.alias.flatMap { $0.isEmpty ? nil : $0 } ?? usage.shortName, percent: usage.percent, free: usage.free,
                  poolSize: usage.poolSize, critical: usage.level == .critical, warning: usage.level == .warning)
    }
}

/// Lien WAN du site (note 39, quand elle sera livrée).
public struct WifiWANStatus: Codable, Hashable, Sendable {
    public var name: String
    public var up: Bool?
    public var latencyMs: Double?
    public var lossPercent: Double?
    public var jitterMs: Double?

    public init(name: String, up: Bool? = nil, latencyMs: Double? = nil, lossPercent: Double? = nil, jitterMs: Double? = nil) {
        self.name = name
        self.up = up
        self.latencyMs = latencyMs
        self.lossPercent = lossPercent
        self.jitterMs = jitterMs
    }
}

/// Mesures facultatives. Les pings partent de ce Mac (pas du client) : ils disent si le réseau
/// derrière la borne va bien, pas ce que vit le client.
public struct WifiDiagnosisMeasures: Codable, Hashable, Sendable {
    public var paths: [WifiPathMeasure]
    public var uplink: WifiUplinkStatus?
    public var dhcp: WifiDHCPStatus?
    public var wan: [WifiWANStatus]
    /// Changements de canal dus au radar (DFS) sur la radio, période récente.
    public var dfsChannelChanges: Int?

    public init(paths: [WifiPathMeasure] = [], uplink: WifiUplinkStatus? = nil, dhcp: WifiDHCPStatus? = nil, wan: [WifiWANStatus] = [],
                dfsChannelChanges: Int? = nil) {
        self.paths = paths
        self.uplink = uplink
        self.dhcp = dhcp
        self.wan = wan
        self.dfsChannelChanges = dfsChannelChanges
    }

    public static let none = WifiDiagnosisMeasures()
    public var isEmpty: Bool { paths.isEmpty && uplink == nil && dhcp == nil && wan.isEmpty && dfsChannelChanges == nil }
    public func path(_ target: WifiPathTarget) -> WifiPathMeasure? { paths.first { $0.target == target } }
}

// MARK: - Sujet et résultat

/// Ce qu'on diagnostique.
public enum WifiDiagnosisSubject: Codable, Hashable, Sendable {
    case client(mac: String, name: String)
    case ap(name: String)
    case ssid(name: String)

    /// Clé du suivi dans le temps (« client|3C:22:FB:7E:05:B1 »).
    public var key: String {
        switch self {
        case .client(let mac, _): return "client|" + mac.uppercased()
        case .ap(let name): return "borne|" + name
        case .ssid(let name): return "ssid|" + name
        }
    }

    public var name: String {
        switch self {
        case .client(_, let name): return name
        case .ap(let name): return name
        case .ssid(let name): return name
        }
    }

    public var kindLabel: String {
        switch self {
        case .client: return "Client"
        case .ap: return "Borne"
        case .ssid: return "SSID"
        }
    }
}

/// Diagnostic complet.
public struct WifiDiagnosisResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var subject: WifiDiagnosisSubject
    public var site: String
    public var date: Date
    /// « AP-ETG2 · radio 1 · 2,4 GHz canal 11 · SSID Groupe-Interne ».
    public var context: String
    /// Causes, la plus probable en tête (problèmes, puis à surveiller, OK, non vérifiées).
    public var causes: [WifiCauseResult]
    /// Actions suggérées, dans l'ordre, sans doublon.
    public var actions: [String]
    /// Mesures de ping faites pendant ce diagnostic.
    public var measured: Bool
    public var notes: [String]

    public init(id: UUID = UUID(), subject: WifiDiagnosisSubject, site: String, date: Date, context: String, causes: [WifiCauseResult],
                actions: [String], measured: Bool, notes: [String] = []) {
        self.id = id
        self.subject = subject
        self.site = site
        self.date = date
        self.context = context
        self.causes = causes
        self.actions = actions
        self.measured = measured
        self.notes = notes
    }

    /// Verdict d'ensemble : le pire des causes vérifiées.
    public var overall: WifiVerdict { causes.map(\.verdict).filter { $0 != .notMeasured }.max() ?? .notMeasured }
    /// Cause la plus probable (problème, sinon à surveiller).
    public var primary: WifiCauseResult? { causes.first { $0.verdict >= .watch } }
    public var problems: [WifiCauseResult] { causes.filter { $0.verdict == .problem } }
    public var watches: [WifiCauseResult] { causes.filter { $0.verdict == .watch } }
    public var oks: [WifiCauseResult] { causes.filter { $0.verdict == .ok } }
    public var unchecked: [WifiCauseResult] { causes.filter { $0.verdict == .notMeasured } }
    public func cause(_ kind: WifiCause) -> WifiCauseResult? { causes.first { $0.cause == kind } }

    /// « Cause la plus probable : signal faible… », ou « Aucun problème trouvé ».
    public var headline: String {
        guard let primary else {
            return overall == .ok ? "Aucun problème trouvé\u{00A0}: tout ce qui a pu être vérifié est normal." : "Rien n’a pu être vérifié."
        }
        let lead = primary.verdict == .problem ? "Cause la plus probable\u{00A0}: " : "Rien de bloquant\u{00A0}; à surveiller d’abord\u{00A0}: "
        return lead + primary.title.prefix(1).lowercased() + primary.title.dropFirst()
    }
}
