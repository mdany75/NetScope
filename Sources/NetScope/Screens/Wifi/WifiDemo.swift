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
        // Note 78 : une heure d'historique ; visite de la salle 204 (autre borne) il y a 38 à 21 minutes.
        let now = Date()
        let roamOut = now.addingTimeInterval(-38 * 60)
        let roamBack = now.addingTimeInterval(-21 * 60)
        store.loadDemo(
            connection: WifiStore.Connection(interfaceName: "en0", network: connected, transmitRate: 866, transmitPower: 63,
                                             countryCode: "CA", hardwareAddress: "3c:22:fb:7e:05:b1", powerOn: true),
            networks: networks,
            timeline: timeline(now: now, rssi: connected.rssi, roamOut: roamOut, roamBack: roamBack),
            roams: [
                WifiStore.Roam(time: roamOut, from: "70:4C:A5:1E:22:A0 (canal 44)", to: "70:4C:A5:3B:91:18 (canal 36) · salle 204",
                               rssiBefore: -74, rssiAfter: -58),
                WifiStore.Roam(time: roamBack, from: "70:4C:A5:3B:91:18 (canal 36)", to: "70:4C:A5:1E:22:A0 (canal 44) · accueil",
                               rssiBefore: -70, rssiAfter: -51),
            ])
    }

    /// Une heure de signal : relevés toutes les 10 s (écran caché), puis toutes les 2 s les 10
    /// dernières minutes (écran ouvert) ; baisse avant le passage à l'autre borne, et une autre il y a 8 min.
    static func timeline(now: Date, rssi: Int, roamOut: Date, roamBack: Date) -> WifiSignalTimeline {
        var timeline = WifiSignalTimeline()
        var t = now.addingTimeInterval(-3600)
        while t <= now {
            let age = now.timeIntervalSince(t)
            let k = age / 10
            var value = Double(rssi) + 2 * sin(k * 0.45) + 1.4 * cos(k * 0.17)
            var bssid = "70:4C:A5:1E:22:A0"
            var channel = 44
            if t >= roamOut, t < roamBack {
                bssid = "70:4C:A5:3B:91:18"
                channel = 36
                value = -61 - 9 * max(0, 1 - roamBack.timeIntervalSince(t) / 240) + 1.5 * sin(k * 0.6)
            } else if t < roamOut, roamOut.timeIntervalSince(t) < 300 {
                value -= 20 * (1 - roamOut.timeIntervalSince(t) / 300)
            } else if abs(age - 480) < 45 {
                value -= 13 * (1 - abs(age - 480) / 45)
            }
            timeline.append(WifiSignalSample(time: t, rssi: Int(value.rounded()), noise: -92 + Int((sin(k * 0.3) * 1.5).rounded()),
                                             channel: channel, bssid: bssid))
            t = t.addingTimeInterval(age > 600 ? 10 : 2)
        }
        return timeline
    }
}
