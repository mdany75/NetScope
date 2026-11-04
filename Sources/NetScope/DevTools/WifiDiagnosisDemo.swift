import Foundation
import NetScopeCore

/// Démonstration de la note 47 (diagnostic Wi-Fi). Aucun accès réseau, aucun ping.
///
/// Le téléphone Android du Scanner (Android_89UM1WTN, sur AP-ETG2 en 2,4 GHz canal 11 à −77 dBm)
/// donne un diagnostic complet : signal faible, voisin « UBNT-Logistik » fort sur le même canal,
/// resté en 2,4 GHz alors que la borne et le poste font le 5 GHz, une seule antenne et l'économie
/// d'énergie, cinq déconnexions dans l'heure ; passerelle, DNS et Internet normaux. Son historique
/// montre le problème qui revient le matin. Les bornes ont un port de switch fictif (AP-ENTREPOT à
/// 100 Mb/s avec des erreurs, AP-QUAI sans courant), AP-SALLE-CONF des changements de canal radar.
///
/// Captures : NETSCOPE_WIFI_DIAG=<MAC ou nom du client> (ou « borne:AP-ETG2 », « ssid:Invités »)
/// dessine la feuille du diagnostic par-dessus Wi-Fi › FortiAP (avec NETSCOPE_WIFI_VUE=fortiap) ;
/// NETSCOPE_RAPPORT_WIFIDIAG=1 coche la section « Diagnostic Wi-Fi » des Rapports.
@MainActor
enum WifiDiagnosisDemo {
    static let android = MACAddress("D6:4E:81:7A:33:C0")!
    static let receptionPhone = MACAddress("F2:6A:19:C4:0E:57")!

    // MARK: Capture

    /// Cible de la feuille dessinée dans la page pendant les captures.
    static var snapshotQuery: String? {
        guard RegEnvironment.isSnapshot else { return nil }
        let value = ProcessInfo.processInfo.environment["NETSCOPE_WIFI_DIAG"]?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    static func snapshotTarget(in overview: FortiWifiOverview) -> WifiDiagnosisTarget? {
        guard let query = snapshotQuery else { return nil }
        let lower = query.lowercased()
        if lower.hasPrefix("borne:") {
            let name = String(query.dropFirst(6))
            return overview.aps.first { $0.name.lowercased() == name.lowercased() }.map(WifiDiagnosisTarget.ap)
        }
        if lower.hasPrefix("ssid:") {
            let name = String(query.dropFirst(5))
            return overview.ssids.first { $0.ssid.lowercased() == name.lowercased() }.map(WifiDiagnosisTarget.ssid)
        }
        if let mac = MACAddress(query), let client = overview.client(mac: mac) { return .client(client) }
        return overview.clients.first { $0.hostname?.lowercased() == lower }.map { WifiDiagnosisTarget.client($0) }
    }

    // MARK: Détails des clients

    static func details(for client: FortiWifiClient) -> WifiClientDetails {
        switch client.mac {
        case android:
            return WifiClientDetails(standard: .wifi5, spatialStreams: 1, txRateMbps: 26, rxRateMbps: 6.5, powerSave: true, supports5GHz: true,
                                     authMethod: "802.1X (PEAP)", authFailures: 0, disconnects: 5, roams: 0, windowMinutes: 60, dhcpDelayMs: 850,
                                     signalHistory: [-71, -74, -79, -77, -81, -77])
        case FortiAPDemo.thisMac:
            return WifiClientDetails(standard: .wifi6, spatialStreams: 2, txRateMbps: 866.7, rxRateMbps: 780, powerSave: false, supports5GHz: true,
                                     authMethod: "802.1X (EAP-TLS)", authFailures: 0, disconnects: 0, roams: 1, windowMinutes: 60, dhcpDelayMs: 140,
                                     signalHistory: [-53, -52, -51, -52])
        case receptionPhone:
            return WifiClientDetails(standard: .wifi6, spatialStreams: 2, txRateMbps: 19.5, rxRateMbps: 24, powerSave: false, supports5GHz: true,
                                     authMethod: "Portail captif", authFailures: 0, disconnects: 2, roams: 1, windowMinutes: 60, dhcpDelayMs: 420)
        default:
            // Les autres : standard déduit du débit, rien d'autre.
            let rate = client.rateMbps ?? 0
            return WifiClientDetails(standard: rate >= 500 ? .wifi6 : (rate >= 150 ? .wifi5 : nil), txRateMbps: client.rateMbps,
                                     supports5GHz: client.band == .ghz5 ? true : nil)
        }
    }

    // MARK: Mesures

    /// Port du switch de chaque borne de démonstration.
    static func uplink(for ap: FortiManagedAP) -> WifiUplinkStatus? {
        switch ap.name {
        case "AP-ACCUEIL":
            return WifiUplinkStatus(switchName: "SW-CORE-01", portName: "Gi1/0/12", linkUp: true, speedMbps: 1000, duplex: "full", rxErrors: 0,
                                    poeLabel: PoEDetectionStatus.deliveringPower.label, poePowerW: 13.1)
        case "AP-ETG2":
            return WifiUplinkStatus(switchName: "SW-ETG2-01", portName: "port7", linkUp: true, speedMbps: 1000, duplex: "full", rxErrors: 0,
                                    poeLabel: PoEDetectionStatus.deliveringPower.label, poePowerW: 12.4)
        case "AP-SALLE-CONF":
            return WifiUplinkStatus(switchName: "SW-ETG2-01", portName: "port18", linkUp: true, speedMbps: 2500, duplex: "full", rxErrors: 0,
                                    poeLabel: PoEDetectionStatus.deliveringPower.label, poePowerW: 21.7)
        case "AP-ENTREPOT":
            return WifiUplinkStatus(switchName: "FS-248E-ENTREPOT", portName: "port14", linkUp: true, speedMbps: 100, duplex: "full", rxErrors: 1240,
                                    poeLabel: PoEDetectionStatus.deliveringPower.label, poePowerW: 11.8)
        case "AP-QUAI":
            return WifiUplinkStatus(switchName: "FS-124F-QUAI", portName: "port22", linkUp: false, speedMbps: nil,
                                    poeLabel: PoEDetectionStatus.searching.label)
        case "AP-DIRECTION":
            return WifiUplinkStatus(switchName: "SW-CORE-01", portName: "Gi1/0/31", linkUp: true, speedMbps: 1000, duplex: "full", rxErrors: 3,
                                    poeLabel: PoEDetectionStatus.deliveringPower.label, poePowerW: 7.9)
        default:
            return nil
        }
    }

    static func measures(ap: FortiManagedAP?, vlan: Int?, site: String, state: AppState) -> WifiDiagnosisMeasures {
        var m = WifiDiagnosisMeasures()
        if let ap {
            m.uplink = uplink(for: ap)
            m.dfsChannelChanges = ap.name == "AP-SALLE-CONF" ? 2 : 0
        }
        return m
    }

    /// Pings fictifs depuis ce Mac : réseau sain derrière les bornes.
    static func paths() -> [WifiPathMeasure] {
        [WifiPathMeasure(target: .gateway, address: "10.182.122.1", sent: 8, received: 8, averageMs: 2.4, maxMs: 4.1, jitterMs: 0.9),
         WifiPathMeasure(target: .dns, address: "10.182.122.1", sent: 8, received: 8, averageMs: 2.6, maxMs: 3.8, jitterMs: 0.7),
         WifiPathMeasure(target: .internet, address: "1.1.1.1", sent: 8, received: 8, averageMs: 13.6, maxMs: 17.2, jitterMs: 1.4)]
    }

    // MARK: Historique

    /// Diagnostics passés du téléphone Android : le problème revient le matin.
    static func histories(now: Date = Date()) -> [String: WifiDiagnosisHistory] {
        let calendar = Calendar.current
        func daysAgo(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        var history = WifiDiagnosisHistory()
        let key = WifiDiagnosisSubject.client(mac: android.formatted(.upperColon), name: "").key
        history.records[key] = [
            WifiDiagnosisRecord(date: daysAgo(4, 9, 40), overall: .problem, primary: .signal, problems: [.signal, .band], rssi: -80),
            WifiDiagnosisRecord(date: daysAgo(3, 14, 30), overall: .watch, primary: .signal, problems: [], rssi: -72),
            WifiDiagnosisRecord(date: daysAgo(2, 10, 5), overall: .problem, primary: .signal, problems: [.signal], rssi: -79),
            WifiDiagnosisRecord(date: daysAgo(1, 9, 20), overall: .problem, primary: .interference, problems: [.interference, .signal], rssi: -78),
        ]
        return [SitesDemo.siegeKey: history]
    }

    /// Diagnostics retenus pour la section « Diagnostic Wi-Fi » du rapport de démonstration.
    static func reportResults(state: AppState) -> [WifiDiagnosisResult] {
        let store = WifiDiagnosisStore.shared
        let overview = FortiAPStore.shared.overview
        var results: [WifiDiagnosisResult] = []
        if let client = overview.client(mac: android) {
            results.append(store.diagnose(.client(client), paths: paths(), state: state))
        }
        if let ap = overview.aps.first(where: { $0.name == "AP-ENTREPOT" }) {
            results.append(store.diagnose(.ap(ap), paths: paths(), state: state))
        }
        return results
    }
}
