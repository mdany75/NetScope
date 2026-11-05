import Foundation
import NetScopeCore

/// Données de démonstration de l'analyseur Wi-Fi (croquis Wifi.dc.html). Aucun appel à CoreWLAN.
@MainActor
enum WifiDemo {
    static func apply(to store: WifiStore) {
        func net(_ ssid: String?, _ bssid: String, _ band: WifiBand, _ channel: Int, _ width: Int, _ rssi: Int,
                 _ security: WifiSecurity, _ standard: String, connected: Bool = false) -> WifiNetwork {
            WifiNetwork(ssid: ssid, bssid: MACAddress(bssid), channel: channel, band: band, widthMHz: width, rssi: rssi,
                        noise: -92, security: security, standard: standard, isConnected: connected)
        }
        // Note 71 : balises de démonstration (DevTools/WifiBeaconDemo.swift).
        let networks = WifiBeaconDemo.decorate([
            net("Bureau-Corp", "70:4C:A5:1E:22:A0", .ghz5, 44, 80, -52, .wpa3Enterprise, "802.11ax", connected: true),
            net("Bureau-Corp", "70:4C:A5:1E:22:A8", .ghz24, 11, 20, -49, .wpa3Enterprise, "802.11ax"),
            net("Bureau-Corp", "70:4C:A5:3B:91:18", .ghz5, 36, 80, -66, .wpa3Enterprise, "802.11ax"),
            net("Bureau-Corp", "70:4C:A5:3B:91:10", .ghz24, 6, 20, -63, .wpa3Enterprise, "802.11ax"),
            net("Invite-Libre", "70:4C:A5:3B:91:11", .ghz24, 6, 20, -62, .open, "802.11ax"),
            net("Bureau-Corp", "02:1F:6B:A0:44:93", .ghz24, 6, 20, -58, .wpa2Personal, "802.11n"),
            net(nil, "9C:53:22:7B:0E:41", .ghz24, 6, 20, -74, .wpa2Personal, "802.11n"),
            net("Cafe-Voisin", "9C:53:22:5D:18:C2", .ghz24, 6, 20, -78, .wpa2Personal, "802.11n"),
            net("Entrepot-Nord", "94:B4:0F:62:7A:01", .ghz24, 6, 20, -71, .wpa2Enterprise, "802.11n"),
            net("Entrepot-Nord", "94:B4:0F:62:7A:11", .ghz5, 149, 80, -77, .wpa2Enterprise, "802.11ac"),
            net("UBNT-Logistik", "78:8A:20:4E:C3:05", .ghz24, 11, 20, -69, .wpa2Personal, "802.11n"),
            net("UBNT-Logistik", "78:8A:20:4E:C3:06", .ghz5, 100, 40, -73, .wpa2Personal, "802.11ac"),
            net("DIRECT-7D-DCP-L2640DW", "96:DD:F8:18:15:7D", .ghz24, 1, 20, -61, .wpa2Personal, "802.11n"),
            net("UBNT-Logistik", "78:8A:20:4E:C3:07", .ghz6, 37, 80, -80, .wpa3Personal, "802.11ax"),
            net("Voisin-6E", "3C:52:A1:09:7E:2C", .ghz6, 69, 160, -83, .wpa3Personal, "802.11be"),
        ])
        let connected = networks[0]
        let history: [Int?] = (0..<WifiStore.historyLength).map { i in
            Int((Double(connected.rssi) + 2 * sin(Double(i) * 0.45) + 1.4 * cos(Double(i) * 0.17)).rounded())
        }
        let now = Date()
        let calendar = Calendar.current
        func today(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        store.loadDemo(
            connection: WifiStore.Connection(interfaceName: "en0", network: connected, transmitRate: 866, transmitPower: 63,
                                             countryCode: "CA", hardwareAddress: "3c:22:fb:7e:05:b1", powerOn: true),
            networks: networks,
            history: history,
            roams: [
                WifiStore.Roam(time: today(10, 18), from: "70:4C:A5:1E:22:A0 (canal 44)", to: "70:4C:A5:3B:91:18 (canal 36) · salle 204",
                               rssiBefore: -74, rssiAfter: -58),
                WifiStore.Roam(time: today(10, 52), from: "70:4C:A5:3B:91:18 (canal 36)", to: "70:4C:A5:1E:22:A0 (canal 44) · accueil",
                               rssiBefore: -70, rssiAfter: -51),
            ],
            points: [
                WifiStore.SurveyPoint(room: "Accueil", rssi: -48, bssid: "70:4C:A5:1E:22:A0", time: today(9, 2)),
                WifiStore.SurveyPoint(room: "Salle 204", rssi: -67, bssid: "70:4C:A5:3B:91:18", time: today(9, 9)),
                WifiStore.SurveyPoint(room: "Entrepôt", rssi: -79, bssid: "70:4C:A5:1E:22:A0", time: today(9, 15)),
            ])
    }
}
