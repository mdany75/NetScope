import Foundation
import NetScopeCore

/// Note 78 : relevé par pièce de démonstration (bureau « Bureau-Corp » du croquis Wifi.dc.html).
/// Aucune mesure réelle : ni ping, ni téléchargement, ni fichier.
///
/// Captures : NETSCOPE_WIFI_RELEVE=1 ouvre le mode relevé (formulaire de mesure) ;
/// NETSCOPE_WIFI_HISTO=2|10|30|60 choisit la durée du graphe du signal (minutes).
@MainActor
enum WifiSurveyDemo {
    static let accueil = "70:4C:A5:1E:22:A0"
    static let salle204 = "70:4C:A5:3B:91:18"

    static func survey(now: Date) -> WifiRoomSurvey {
        func m(_ room: String, _ minutesAgo: Double, _ bssid: String, _ channel: Int, _ rssi: Int, _ noise: Int, _ link: Double,
               _ latency: Double, _ jitter: Double, _ loss: Double, _ down: Double?, note: String? = nil) -> WifiRoomMeasure {
            WifiRoomMeasure(room: room, time: now.addingTimeInterval(-minutesAgo * 60), ssid: "Bureau-Corp", bssid: bssid,
                            band: .ghz5, channel: channel, rssi: rssi, noise: noise, linkRateMbps: link, latencyMs: latency,
                            jitterMs: jitter, lossPercent: loss, latencyTarget: "passerelle 10.182.122.1", downloadMbps: down, note: note)
        }
        return WifiRoomSurvey(measures: [
            m("Accueil", 52, accueil, 44, -47, -93, 1201, 2.1, 0.4, 0, 486.3),
            m("Bureau 101", 49, accueil, 44, -55, -92, 864.7, 2.8, 0.7, 0, 412.9),
            m("Salle de conférence", 45, salle204, 36, -61, -92, 720.6, 3.4, 1.1, 0, 356.2),
            m("Salle 204", 41, salle204, 36, -64, -86, 573.5, 6.2, 2.4, 0, 248.7),
            m("Cuisine", 37, salle204, 36, -68, -84, 390, 38.6, 14.2, 3.3, 61.4),
            m("Entrepôt", 33, accueil, 44, -79, -90, 58.5, 24.9, 9.8, 16.7, 12.8),
            m("Quai de livraison", 29, accueil, 44, -83, -91, 26, 41.2, 18.5, 33.3, nil,
              note: "débit non mesuré\u{00A0}: délai dépassé"),
            m("Accueil", 6, accueil, 44, -49, -93, 1201, 1.9, 0.3, 0, 501.6),
        ])
    }

    /// Mesure de démonstration d'un nouveau point : valeurs plausibles déduites du signal lu.
    static func complete(_ base: WifiRoomMeasure, throughput: Bool) -> WifiRoomMeasure {
        var measure = base
        let seed = Double(base.room.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 17)
        let weakness = Double(max(0, -50 - base.rssi))
        measure.latencyMs = 2 + weakness * 0.6 + seed * 0.1
        measure.jitterMs = 0.4 + weakness * 0.2
        measure.lossPercent = base.rssi < -75 ? 8.3 : 0
        measure.latencyTarget = "passerelle 10.182.122.1"
        if throughput { measure.downloadMbps = max(8, 480 - weakness * 14 - seed * 3) }
        return measure
    }

    /// Mode relevé ouvert d'office dans les captures (NETSCOPE_WIFI_RELEVE=1).
    static var opensSurvey: Bool {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_WIFI_RELEVE"] == "1"
    }

    /// Durée du graphe du signal dans les captures (NETSCOPE_WIFI_HISTO, en minutes).
    static var snapshotSpan: WifiSignalSpan? {
        guard CommandLine.arguments.contains("--snapshot"),
              let minutes = ProcessInfo.processInfo.environment["NETSCOPE_WIFI_HISTO"].flatMap(Int.init) else { return nil }
        return WifiSignalSpan(rawValue: minutes * 60)
    }
}
