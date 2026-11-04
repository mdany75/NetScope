import Foundation

// Note 46 : fiche complète d'un client Wi-Fi. Détails lus dans la même réponse de
// /api/v2/monitor/wifi/client (aucun appel de plus) : débits montant et descendant, débit maximal,
// standard (Wi-Fi 4 à 7), sécurité et authentification, utilisateur, octets échangés, largeur du
// canal, capacités d'itinérance (802.11k/v/r), retransmissions. Chaque champ est facultatif : une
// version de FortiOS qui ne le donne pas laisse « — » dans la fiche, et le diagnostic brut le dit.
//
// Noms relevés dans la documentation publique de FortiOS (monitor/wifi/client : sta_txrate,
// sta_rxrate, sta_maxrate, data_txrate_bps, data_rxrate_bps, radio_type, security_str,
// authentication, 11k_capable…) ; les autres noms sont essayés par prudence.

/// Génération Wi-Fi d'un client (d'après la norme radio annoncée).
public enum WifiStandard: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// 802.11a, b ou g (avant le Wi-Fi 4).
    case legacy
    case wifi4, wifi5, wifi6, wifi6E, wifi7

    /// « Wi-Fi 6 (802.11ax) ».
    public var label: String {
        switch self {
        case .legacy: return "802.11a/b/g (ancien)"
        case .wifi4: return "Wi-Fi 4 (802.11n)"
        case .wifi5: return "Wi-Fi 5 (802.11ac)"
        case .wifi6: return "Wi-Fi 6 (802.11ax)"
        case .wifi6E: return "Wi-Fi 6E (802.11ax, 6\u{00A0}GHz)"
        case .wifi7: return "Wi-Fi 7 (802.11be)"
        }
    }

    /// « Wi-Fi 6 ».
    public var shortLabel: String {
        switch self {
        case .legacy: return "11a/b/g"
        case .wifi4: return "Wi-Fi 4"
        case .wifi5: return "Wi-Fi 5"
        case .wifi6: return "Wi-Fi 6"
        case .wifi6E: return "Wi-Fi 6E"
        case .wifi7: return "Wi-Fi 7"
        }
    }

    private var rank: Int { WifiStandard.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: WifiStandard, rhs: WifiStandard) -> Bool { lhs.rank < rhs.rank }

    /// Norme d'après le texte de FortiOS (« 802.11ax-5G », « 11ac », « 802.11n-2G », « 11be »,
    /// « HE », « VHT », « HT ») et la bande (802.11ax en 6 GHz : Wi-Fi 6E). nil si rien ne la dit.
    public static func parse(_ text: String?, band: WifiBand? = nil) -> WifiStandard? {
        guard let raw = text?.lowercased().replacingOccurrences(of: " ", with: ""), !raw.isEmpty else { return nil }
        // Formes courtes (« be », « ax », « ac », « n », « g ») : nom de la norme seul.
        switch raw.replacingOccurrences(of: "802.11", with: "") {
        case "be": return .wifi7
        case "ax": return band == .ghz6 ? .wifi6E : .wifi6
        case "ac": return .wifi5
        case "n": return .wifi4
        case "a", "b", "g": return .legacy
        default: break
        }
        if raw.contains("11be") || raw.contains("wifi7") || raw.contains("wi-fi7") || raw.hasPrefix("eht") { return .wifi7 }
        if raw.contains("11ax") || raw.contains("wifi6") || raw.contains("wi-fi6") || raw.hasPrefix("he") {
            if raw.contains("6e") || raw.contains("6g") || band == .ghz6 { return .wifi6E }
            return .wifi6
        }
        if raw.contains("11ac") || raw.contains("wifi5") || raw.contains("wi-fi5") || raw.hasPrefix("vht") { return .wifi5 }
        if raw.contains("11n") || raw.contains("wifi4") || raw.contains("wi-fi4") || raw.hasPrefix("ht") { return .wifi4 }
        if raw.contains("11a") || raw.contains("11b") || raw.contains("11g") { return .legacy }
        return nil
    }
}

/// Ce que la FortiGate dit de plus sur un client (fiche complète, note 46).
public struct FortiWifiClientDetails: Codable, Hashable, Sendable {
    /// Débit de la borne vers le client (descendant), en Mb/s.
    public var txRateMbps: Double?
    /// Débit du client vers la borne (montant), en Mb/s.
    public var rxRateMbps: Double?
    /// Débit maximal que le client peut négocier, en Mb/s.
    public var maxRateMbps: Double?
    /// Octets envoyés par la borne au client (descendant).
    public var bytesToClient: Int64?
    /// Octets reçus du client par la borne (montant).
    public var bytesFromClient: Int64?
    /// Norme radio telle que donnée (« 802.11ax-5G »).
    public var standardText: String?
    public var standard: WifiStandard?
    /// Sécurité de l'association (« WPA2 Personal », « wpa2-only-enterprise »).
    public var security: String?
    /// Méthode d'authentification (« PSK », « 802.1X », « EAP-PEAP »).
    public var authentication: String?
    /// Utilisateur authentifié (802.1X, portail captif).
    public var user: String?
    /// Interface VAP (« wifi-interne »).
    public var vapName: String?
    /// Largeur du canal négociée, en MHz.
    public var widthMHz: Int?
    /// Capacités d'itinérance assistée.
    public var supports11k: Bool?
    public var supports11v: Bool?
    public var supports11r: Bool?
    /// Trames retransmises vers le client, en %.
    public var txRetryPercent: Double?
    /// Inactivité du client, en secondes.
    public var idleSeconds: TimeInterval?

    public init(txRateMbps: Double? = nil, rxRateMbps: Double? = nil, maxRateMbps: Double? = nil, bytesToClient: Int64? = nil,
                bytesFromClient: Int64? = nil, standardText: String? = nil, standard: WifiStandard? = nil, security: String? = nil,
                authentication: String? = nil, user: String? = nil, vapName: String? = nil, widthMHz: Int? = nil,
                supports11k: Bool? = nil, supports11v: Bool? = nil, supports11r: Bool? = nil, txRetryPercent: Double? = nil,
                idleSeconds: TimeInterval? = nil) {
        self.txRateMbps = txRateMbps
        self.rxRateMbps = rxRateMbps
        self.maxRateMbps = maxRateMbps
        self.bytesToClient = bytesToClient
        self.bytesFromClient = bytesFromClient
        self.standardText = standardText
        self.standard = standard ?? WifiStandard.parse(standardText)
        self.security = security
        self.authentication = authentication
        self.user = user
        self.vapName = vapName
        self.widthMHz = widthMHz
        self.supports11k = supports11k
        self.supports11v = supports11v
        self.supports11r = supports11r
        self.txRetryPercent = txRetryPercent
        self.idleSeconds = idleSeconds
    }

    /// Aucun détail lu.
    public var isEmpty: Bool { self == FortiWifiClientDetails() }

    /// « 802.11k, 802.11v » (capacités annoncées), « aucune » si toutes absentes mais lues.
    public var roamingCapabilities: String? {
        let flags: [(String, Bool?)] = [("802.11k", supports11k), ("802.11v", supports11v), ("802.11r", supports11r)]
        guard flags.contains(where: { $0.1 != nil }) else { return nil }
        let yes = flags.filter { $0.1 == true }.map(\.0)
        return yes.isEmpty ? "aucune" : yes.joined(separator: ", ")
    }

    /// Authentification en clair : la méthode donnée, sinon déduite de la sécurité (« 802.1X »,
    /// « Clé partagée (PSK) », « Ouvert »).
    public var authenticationLabel: String? {
        if let authentication, !authentication.isEmpty { return authentication }
        guard let s = security?.lowercased(), !s.isEmpty else { return nil }
        if s.contains("enterprise") || s.contains("1x") || s.contains("radius") || s.contains("eap") { return "802.1X (entreprise)" }
        if s.contains("sae") { return "SAE (WPA3 personnel)" }
        if s.contains("personal") || s.contains("psk") || s.contains("wpa") { return "Clé partagée (PSK)" }
        if s.contains("open") || s.contains("none") { return "Ouvert" }
        return nil
    }
}

extension FortiWifiClient {
    /// Détails de la fiche (vides si la réponse n'en donnait pas).
    public var info: FortiWifiClientDetails { details ?? FortiWifiClientDetails() }

    /// Standard du client : celui lu, sinon déduit de la bande (6 GHz : au moins Wi-Fi 6E).
    public var standard: WifiStandard? {
        if let s = info.standard { return s == .wifi6 && band == .ghz6 ? .wifi6E : s }
        return band == .ghz6 ? .wifi6E : nil
    }
}

extension FortiWifiParsers {
    /// Débit en Mb/s : champ en b/s (« *_bps »), sinon valeur en Mb/s, ou en kb/s si elle dépasse 20 000.
    static func rate(_ item: FortiObject, bps: [String], mbps: [String]) -> Double? {
        if let v = FortiJSON.double(item.value(bps)), v > 0 { return v / 1_000_000 }
        if let v = FortiJSON.double(item.value(mbps)), v > 0 {
            let value = v > 20_000 ? v / 1000 : v
            return value < 100_000 ? value : nil
        }
        return nil
    }

    static func bytes(_ value: Any?) -> Int64? {
        guard let d = FortiJSON.double(value), d.isFinite, d >= 0, d < 9.0e18 else { return nil }
        return Int64(d)
    }

    /// Détails d'un client (fiche complète, note 46), lus dans le même objet que le client.
    static func clientDetails(_ item: FortiObject, band: WifiBand?) -> FortiWifiClientDetails? {
        let standardText = item.string("radio_type", "radio-type", "protocol", "phy_mode", "phymode", "standard", "sta_mode",
                                       "wireless_mode", "802_11_mode")
        // « security » est parfois un code numérique : on garde le texte seulement.
        var security = item.string("security_str", "security-str", "security_mode", "security-mode", "encryption")
        if security == nil, let s = item.string("security"), Double(s) == nil { security = s }
        let retry = FortiJSON.double(item.any("tx_retry_percentage", "tx-retry-percentage", "retry_percentage", "tx_retries_percent"))
        var details = FortiWifiClientDetails(
            txRateMbps: rate(item, bps: ["data_txrate_bps", "data-txrate-bps", "tx_rate_bps"], mbps: ["sta_txrate", "sta-txrate", "txrate"]),
            rxRateMbps: rate(item, bps: ["data_rxrate_bps", "data-rxrate-bps", "rx_rate_bps"], mbps: ["sta_rxrate", "sta-rxrate", "rxrate", "rx_rate"]),
            maxRateMbps: rate(item, bps: ["max_rate_bps", "sta_maxrate_bps"], mbps: ["sta_maxrate", "sta-maxrate", "max_rate", "maxrate"]),
            bytesToClient: bytes(item.any("tx_bytes", "tx-bytes", "bytes_tx", "txbytes", "total_tx_bytes", "sta_tx_bytes", "bytes_sent")),
            bytesFromClient: bytes(item.any("rx_bytes", "rx-bytes", "bytes_rx", "rxbytes", "total_rx_bytes", "sta_rx_bytes", "bytes_received")),
            standardText: standardText,
            standard: WifiStandard.parse(standardText, band: band),
            security: security,
            authentication: item.string("authentication", "auth", "auth_type", "authentication_method", "auth_method", "eap_type"),
            user: item.string("user", "username", "user_name", "auth_user", "radius_user", "identity", "user_id"),
            vapName: item.string("vap_name", "vap-name", "vap"),
            widthMHz: width(item.any("channel_bandwidth", "channel-bandwidth", "channel_width", "chan_width")),
            supports11k: item.bool("11k_capable", "11k-capable", "dot11k", "rrm_capable"),
            supports11v: item.bool("11v_capable", "11v-capable", "dot11v", "btm_capable"),
            supports11r: item.bool("11r_capable", "11r-capable", "dot11r", "ft_capable"),
            txRetryPercent: retry.flatMap { $0.isFinite && $0 >= 0 ? min($0, 100) : nil },
            idleSeconds: duration(item.any("idle_time", "idle-time", "idle")))
        if details.standard == nil, band == .ghz6 { details.standard = .wifi6E }
        return details.isEmpty ? nil : details
    }
}

// MARK: - Champs absents (diagnostic brut)

public enum FortiWifiClientFields {
    /// Champs de la fiche complète qu'AUCUN client de la lecture ne donne (la version de FortiOS ou
    /// les droits de l'API ne les renvoient pas) : affichés « — » dans la fiche, et notés ici dans le
    /// diagnostic brut. Liste vide : tout est lu (ou aucun client).
    public static func missing(_ clients: [FortiWifiClient]) -> [String] {
        guard !clients.isEmpty else { return [] }
        let checks: [(String, (FortiWifiClient) -> Bool)] = [
            ("signal (signal, rssi)", { $0.rssi != nil }),
            ("bruit (noise)", { $0.noise != nil }),
            ("débit négocié (data_rate_bps)", { $0.rateMbps != nil }),
            ("débit descendant (sta_txrate, data_txrate_bps)", { $0.info.txRateMbps != nil }),
            ("débit montant (sta_rxrate, data_rxrate_bps)", { $0.info.rxRateMbps != nil }),
            ("octets échangés (tx_bytes, rx_bytes)", { $0.info.bytesToClient != nil || $0.info.bytesFromClient != nil }),
            ("standard (radio_type)", { $0.standard != nil }),
            ("sécurité (security_str)", { $0.info.security != nil }),
            ("authentification (authentication)", { $0.info.authentication != nil }),
            ("utilisateur (user)", { $0.info.user != nil }),
            ("largeur du canal (channel_bandwidth)", { $0.info.widthMHz != nil }),
            ("VLAN (vlan_id)", { $0.vlan != nil }),
            ("durée d’association (association_time)", { $0.associatedFor != nil }),
        ]
        return checks.filter { _, present in !clients.contains(where: present) }.map(\.0)
    }

    /// Ligne du diagnostic brut : « Champs des clients Wi-Fi absents de la réponse : … », ou nil.
    public static func diagnosticLine(_ clients: [FortiWifiClient]) -> String? {
        let absent = missing(clients)
        guard !absent.isEmpty else { return nil }
        return "Champs des clients Wi-Fi absents de la réponse (affichés «\u{00A0}—\u{00A0}» dans la fiche du client)\u{00A0}: "
            + absent.joined(separator: ", ") + "."
    }
}
