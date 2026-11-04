import Foundation
import NetScopeCore

// Fusion des notes 46 et 47 : détails de la fiche du client et historique du signal passés au
// diagnostic Wi-Fi. Données fixes, aucun réseau.

func registerWifiClientDetailsBridgeTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_700_000)
    let mac = MACAddress(bytes: [0x5C, 0xE9, 0x1E, 0x40, 0x00, 0x21])

    func client(ap: String, band: WifiBand, rssi: Int, details: FortiWifiClientDetails? = nil) -> FortiWifiClient {
        var c = FortiWifiClient(site: "Siège", mac: mac, hostname: "poste-21", ssid: "Groupe-Interne", apName: ap, radioID: band == .ghz24 ? 1 : 2,
                                band: band, channel: band == .ghz24 ? 11 : 36, rssi: rssi, noise: -95, rateMbps: 72)
        c.details = details
        return c
    }

    suite.add("Wi-Fi diagnostic : détails tirés de la fiche du client et de l'historique du signal") {
        var history = FortiWifiSignalHistory()
        let limits = FortiWifiSignalHistory.Limits(minInterval: 0)
        let other = FortiWifiClient(site: "Siège", mac: MACAddress(bytes: [0x5C, 0xE9, 0x1E, 0x40, 0x00, 0x99]), apName: "AP-ETG2")
        let start = now.addingTimeInterval(-50 * 60)
        history.record([client(ap: "AP-ETG2", band: .ghz5, rssi: -62), other], at: start, limits: limits)
        history.record([client(ap: "AP-ETG2", band: .ghz24, rssi: -70), other], at: start.addingTimeInterval(600), limits: limits)
        history.record([other], at: start.addingTimeInterval(1200), limits: limits)
        history.record([client(ap: "AP-ACCUEIL", band: .ghz24, rssi: -74), other], at: start.addingTimeInterval(1800), limits: limits)

        let info = FortiWifiClientDetails(txRateMbps: 72, rxRateMbps: 24, standardText: "802.11ac", security: "WPA2 Enterprise")
        let now24 = client(ap: "AP-ACCUEIL", band: .ghz24, rssi: -74, details: info)
        let d = WifiClientDetails(client: now24, history: history, now: now)
        try expectEqual(d.standard, .wifi5, "standard de la fiche")
        try expectEqual(d.txRateMbps, 72, "débit descendant")
        try expectEqual(d.rxRateMbps, 24, "débit montant")
        try expectEqual(d.authMethod, "802.1X (entreprise)", "authentification déduite de la sécurité")
        try expectEqual(d.supports5GHz, true, "vu en 5 GHz dans l'historique")
        try expectEqual(d.roams, 2, "itinérances de la dernière heure (bande puis borne)")
        try expectEqual(d.disconnects, 1, "lecture manquée")
        try expectEqual(d.windowMinutes, 60, "période observée")
        try expectEqual(d.signalHistory, [-62, -70, -74], "courbe du signal")

        let empty = WifiClientDetails(client: client(ap: "AP-ETG2", band: .ghz24, rssi: -60), history: nil, now: now)
        try expect(empty.roams == nil && empty.disconnects == nil && empty.signalHistory.isEmpty, "sans historique : non vérifié")
        try expectEqual(empty.supports5GHz, nil, "2,4 GHz seul : capacité inconnue")
    }

    suite.add("Wi-Fi diagnostic : les détails connus sont gardés, les autres complétés") {
        let known = WifiClientDetails(standard: .wifi6, disconnects: 5)
        let read = WifiClientDetails(standard: .wifi4, txRateMbps: 26, disconnects: 1, signalHistory: [-70, -72])
        let merged = known.filling(from: read)
        try expectEqual(merged.standard, .wifi6, "standard connu gardé")
        try expectEqual(merged.disconnects, 5, "compteur connu gardé")
        try expectEqual(merged.txRateMbps, 26, "débit complété")
        try expectEqual(merged.signalHistory, [-70, -72], "courbe complétée")
    }
}
