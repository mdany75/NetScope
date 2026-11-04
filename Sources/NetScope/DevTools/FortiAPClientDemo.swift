import Foundation
import NetScopeCore

/// Démonstration de la note 46 (clients Wi-Fi par borne et par SSID, fiche complète, historique du
/// signal). Aucun accès réseau, rien n'est lu ni écrit sur le disque.
///
/// - Chaque client de FortiAPDemo reçoit des détails réalistes : standard (Wi-Fi 4 à 6), débits
///   montant et descendant, sécurité et authentification (802.1X sur « Groupe-Interne », portail
///   captif sur « Invités »), utilisateur, octets (absents pour les invités et le téléphone Android,
///   comme sur une FortiGate qui ne les renvoie pas : la fiche montre « — »).
/// - Historique : trois heures de relevés toutes les 5 minutes au Siège. Le téléphone Android du
///   Scanner (10.182.122.133) a un signal en baisse : AP-ACCUEIL en 5 GHz, puis AP-ETG2 en 5 GHz,
///   puis AP-ETG2 en 2,4 GHz à −77 dBm, avec deux déconnexions.
///
/// Captures (avec NETSCOPE_WIFI_VUE=fortiap) :
/// - NETSCOPE_WIFI_BORNE=AP-ETG2 : cette borne choisie (clients par radio et par SSID) ;
/// - NETSCOPE_WIFI_CLIENTS=ssid : section Clients regroupée par SSID, tous les SSID dépliés
///   (NETSCOPE_WIFI_SSID=Invités : ce SSID seulement) ;
/// - NETSCOPE_WIFI_CLIENT=Android_89UM1WTN (nom ou MAC) : fiche complète de ce client ;
/// - fiche Appareil avec sa section Wi-Fi : NETSCOPE_DEVICE=10.182.122.133 (sans NETSCOPE_WIFI_VUE).
@MainActor
extension FortiAPDemo {
    // MARK: Détails des clients

    static func enrichClients(_ clients: [FortiWifiClient], guestSSID: String = "Invités") -> [FortiWifiClient] {
        clients.enumerated().map { index, client in
            var c = client
            let host = (client.hostname ?? "").lowercased()
            let guest = client.ssid == guestSSID
            let os = (client.os ?? "").lowercased()
            let rate = client.rateMbps ?? 0
            let standard: String
            if client.mac == android { standard = "802.11n-2G" }
            else if host.hasPrefix("zebra") { standard = client.band == .ghz24 ? "802.11n-2G" : "802.11ac" }
            else if os == "windows" && index % 3 == 0 { standard = "802.11ac" }
            else { standard = client.band == .ghz24 ? "802.11ax-2G" : "802.11ax-5G" }
            let parsed = WifiStandard.parse(standard, band: client.band)
            let maxRate: Double
            switch (parsed, client.band) {
            case (.wifi4?, _): maxRate = 144.4
            case (.wifi5?, _): maxRate = 866.7
            case (_, .ghz24?): maxRate = 286.8
            default: maxRate = 1201
            }
            let minutes = (client.associatedFor ?? 600) / 60
            let bytesDown = Int64(minutes * max(rate, 10) * 1_150_000)
            let mobile = os == "ios" || os == "android"
            let user: String? = guest ? nil : (client.mac == thisMac ? "GROUPE\\dmenard" : (client.mac == android ? "GROUPE\\mgagnon" : userName(host)))
            c.details = FortiWifiClientDetails(
                txRateMbps: rate > 0 ? rate : nil,
                rxRateMbps: rate > 0 ? (rate * (client.band == .ghz24 ? 0.7 : 0.6)).rounded() : nil,
                maxRateMbps: maxRate,
                bytesToClient: guest || client.mac == android ? nil : bytesDown,
                bytesFromClient: guest || client.mac == android ? nil : bytesDown / (mobile ? 6 : 4),
                standardText: standard,
                standard: parsed,
                security: guest ? "Open" : "WPA2 Enterprise",
                authentication: guest ? "Portail captif" : "802.1X (EAP-PEAP)",
                user: user,
                vapName: guest ? "wifi-invites" : "wifi-interne",
                widthMHz: client.band == .ghz24 ? 20 : (client.apName == "AP-SALLE-CONF" && client.radioID == 3 ? 40 : 80),
                supports11k: true,
                supports11v: os != "android" || host.hasPrefix("zebra"),
                supports11r: os == "ios" || os == "macos" || host.hasPrefix("zebra"),
                txRetryPercent: client.mac == android ? 22 : Double(2 + index % 7),
                idleSeconds: Double((index * 13) % 40))
            return c
        }
    }

    /// « LAP-COMPTA-03 » → « GROUPE\compta03 », « iPhone-de-Julie » → « GROUPE\julie ».
    private static func userName(_ host: String) -> String? {
        guard !host.isEmpty else { return nil }
        if let range = host.range(of: "-de-") { return "GROUPE\\" + host[range.upperBound...] }
        let parts = host.split(separator: "-")
        if parts.count >= 3, parts[0] == "lap" { return "GROUPE\\" + parts[1] + parts[2] }
        if parts.count >= 2 { return "GROUPE\\" + parts.dropFirst().joined() }
        return "GROUPE\\" + host
    }

    // MARK: Historique du signal

    /// Historiques de démonstration : Siège (36 relevés en 3 h) et Entrepôt Laval (12 relevés).
    static func signalBook(now: Date = Date()) -> FortiWifiSignalBook {
        FortiWifiSignalBook(sites: [SitesDemo.siegeKey: siegeHistory(now: now), SitesDemo.lavalKey: lavalHistory(now: now)])
    }

    static func siegeHistory(now: Date) -> FortiWifiSignalHistory {
        let report = siege(now: now)
        let end = report.readAt
        let count = 36
        let dates = (0..<count).map { end.addingTimeInterval(-Double(count - 1 - $0) * 300) }
        var history = FortiWifiSignalHistory(readings: dates)
        for (n, client) in report.clients.enumerated() {
            let key = client.mac.formatted(.upperColon)
            if client.mac == android {
                history.series[key] = androidSeries(dates)
                continue
            }
            let since = end.addingTimeInterval(-(client.associatedFor ?? 3 * 3600) - 60)
            var list: [FortiWifiSignalSample] = []
            for (k, date) in dates.enumerated() where date >= since || n % 4 == 0 {
                let jitter = [0, -1, 1, -2, 2, 0, -1, 1][(k + n) % 8]
                let rssi = client.rssi.map { k == count - 1 ? $0 : $0 + jitter }
                let snr = rssi.map { $0 - (client.noise ?? -95) }
                list.append(FortiWifiSignalSample(date: date, rssi: rssi, snr: snr, rateMbps: client.rateMbps, apName: client.apName,
                                                  band: client.band, channel: client.channel))
            }
            history.series[key] = list
        }
        return history
    }

    /// Téléphone Android : AP-ACCUEIL 5 GHz (−56), puis AP-ETG2 5 GHz (−64 à −68), puis AP-ETG2
    /// 2,4 GHz jusqu'à −77 ; absent à deux lectures (déconnexions), revenu il y a 12 minutes.
    static func androidSeries(_ dates: [Date]) -> [FortiWifiSignalSample] {
        var list: [FortiWifiSignalSample] = []
        let missing: Set<Int> = [29, 32]
        for (k, date) in dates.enumerated() where !missing.contains(k) {
            let sample: FortiWifiSignalSample
            switch k {
            case 0..<12:
                let rssi = -55 - (k % 3)
                sample = FortiWifiSignalSample(date: date, rssi: rssi, snr: rssi + 96, rateMbps: 433.3, apName: "AP-ACCUEIL", band: .ghz5, channel: 44)
            case 12..<22:
                let rssi = -63 - (k - 12) / 2
                sample = FortiWifiSignalSample(date: date, rssi: rssi, snr: rssi + 95, rateMbps: 200, apName: "AP-ETG2", band: .ghz5, channel: 36)
            default:
                let rssi = k == dates.count - 1 ? -77 : -70 - (k - 22) / 2
                sample = FortiWifiSignalSample(date: date, rssi: rssi, snr: rssi + 93, rateMbps: k < 30 ? 52 : 26, apName: "AP-ETG2",
                                               band: .ghz24, channel: 11)
            }
            list.append(sample)
        }
        return list
    }

    static func lavalHistory(now: Date) -> FortiWifiSignalHistory {
        let report = laval(now: now)
        let dates = (0..<12).map { report.readAt.addingTimeInterval(-Double(11 - $0) * 600) }
        var history = FortiWifiSignalHistory(readings: dates)
        for (n, client) in report.clients.enumerated() {
            history.series[client.mac.formatted(.upperColon)] = dates.enumerated().map { k, date in
                let rssi = client.rssi.map { $0 + [0, -1, 1, 0][(k + n) % 4] }
                return FortiWifiSignalSample(date: date, rssi: rssi, snr: rssi.map { $0 + 94 }, rateMbps: client.rateMbps,
                                             apName: client.apName, band: client.band, channel: client.channel)
            }
        }
        return history
    }

    // MARK: Captures

    /// Borne choisie par NETSCOPE_WIFI_BORNE (captures seulement).
    static var snapshotBorne: String? {
        CommandLine.arguments.contains("--snapshot") ? ProcessInfo.processInfo.environment["NETSCOPE_WIFI_BORNE"] : nil
    }

    /// Variables NETSCOPE_WIFI_BORNE, NETSCOPE_WIFI_CLIENTS, NETSCOPE_WIFI_SSID et NETSCOPE_WIFI_CLIENT.
    static func applySnapshotFocus(_ store: FortiAPStore) {
        guard CommandLine.arguments.contains("--snapshot") else { return }
        let env = ProcessInfo.processInfo.environment
        let overview = store.shownOverview
        if let name = snapshotBorne, let ap = overview.aps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            store.viewedAP = ap.id
        }
        if env["NETSCOPE_WIFI_CLIENTS"]?.lowercased() == "ssid" {
            store.clientsBySSID = true
            let groups = FortiWifiClientGroups.bySSID(overview)
            let wanted = env["NETSCOPE_WIFI_SSID"]
            store.expandedSSIDs = Set(groups.filter { wanted == nil || $0.ssid == wanted }.map(\.id))
        }
        if let wanted = env["NETSCOPE_WIFI_CLIENT"]?.lowercased(), !wanted.isEmpty {
            let mac = MACAddress(wanted)
            if let client = overview.clients.first(where: { $0.hostname?.lowercased() == wanted || (mac != nil && $0.mac == mac) }) {
                if let ap = store.ap(for: client) { store.viewedAP = ap.id }
                store.showClient(client.id)
            }
        }
    }
}
