import Foundation

// Note 46 : « problèmes repérés » de la fiche d'un client Wi-Fi (fiche du client et section Wi-Fi
// de la fiche Appareil). Un premier tri, d'après les mêmes seuils que l'écran Wi-Fi : signal,
// SNR, bande, charge et utilisation du canal de la borne, standard, débit, itinérances et
// déconnexions de l'historique. Le diagnostic complet, avec les solutions, est celui du bouton
// « Diagnostiquer » (note 47). Fonctions pures.

public struct FortiWifiClientIssue: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case weakSignal, lowSNR, band24, busyChannel, crowdedRadio, oldStandard, lowRate, roaming, disconnects, falling, retries, healthy
    }

    public var id: String { kind.rawValue }
    public var kind: Kind
    public var severity: WifiRecommendation.Severity
    public var title: String
    public var detail: String
}

public enum FortiWifiClientIssues {
    /// Problèmes repérés pour un client, le plus grave d'abord ; un seul élément « Aucun problème
    /// repéré » (info) s'il n'y en a pas. `history` : historique du signal du site du client.
    public static func issues(_ client: FortiWifiClient, ap: FortiManagedAP?, history: FortiWifiSignalHistory? = nil,
                              thresholds: FortiWifiThresholds = .standard, now: Date = Date()) -> [FortiWifiClientIssue] {
        var result: [FortiWifiClientIssue] = []
        func add(_ kind: FortiWifiClientIssue.Kind, _ severity: WifiRecommendation.Severity, _ title: String, _ detail: String) {
            result.append(FortiWifiClientIssue(kind: kind, severity: severity, title: title, detail: detail))
        }
        let radio = ap.flatMap { ap in client.radioID.flatMap { id in ap.radios.first { $0.radioID == id } }
            ?? client.band.flatMap { ap.radio($0) } }

        if let rssi = client.rssi, rssi < thresholds.weakRSSI {
            add(.weakSignal, rssi < -80 ? .critique : .alerte, "Signal faible (\(WifiQuality.dbm(rssi)))",
                "Sous le seuil de \(WifiQuality.dbm(thresholds.weakRSSI))\u{00A0}: client loin de la borne ou derrière un obstacle.")
        }
        if let snr = client.snr, snr < thresholds.weakSNR {
            add(.lowSNR, snr < 10 ? .critique : .alerte, "Rapport signal/bruit bas (\(snr)\u{00A0}dB)",
                "Sous le seuil de \(thresholds.weakSNR)\u{00A0}dB\u{00A0}: le bruit du canal couvre le signal.")
        }
        if client.band == .ghz24, let ap, ap.radios.contains(where: { $0.isServing && ($0.band == .ghz5 || $0.band == .ghz6) }) {
            add(.band24, .conseil, "Client en 2,4\u{00A0}GHz",
                "\(ap.name) diffuse aussi en 5\u{00A0}GHz\u{00A0}: bande plus encombrée et plus lente pour ce client.")
        }
        if let radio, let util = radio.channelUtilization, util > thresholds.maxChannelUtilization {
            add(.busyChannel, .alerte, "Canal occupé à \(Int(util.rounded()))\u{00A0}%",
                "La radio \(radio.radioID) de la borne dépasse le seuil de \(Int(thresholds.maxChannelUtilization))\u{00A0}%.")
        }
        if let radio, let count = radio.clientCount, count > thresholds.maxClientsPerRadio {
            add(.crowdedRadio, .alerte, "Radio chargée (\(count) clients)",
                "Au-delà de \(thresholds.maxClientsPerRadio) clients sur la radio \(radio.radioID) de la borne.")
        }
        if let standard = client.standard, standard <= .wifi4 {
            add(.oldStandard, .conseil, "Standard ancien (\(standard.shortLabel))",
                "Un client \(standard.shortLabel) ralentit le temps d'antenne de toute la radio.")
        }
        if let rate = client.rateMbps, rate < 24 {
            add(.lowRate, .alerte, "Débit négocié bas (\(Self.rate(rate)))",
                "Moins de 24\u{00A0}Mb/s\u{00A0}: signal ou bande à revoir.")
        }
        if let retry = client.info.txRetryPercent, retry > 15 {
            add(.retries, .alerte, "Retransmissions élevées (\(Int(retry.rounded()))\u{00A0}%)",
                "Trames répétées vers le client\u{00A0}: interférences ou signal limite.")
        }
        if let history {
            let recent = history.roams(for: client.mac).filter { $0.date >= now.addingTimeInterval(-3600) }
            if recent.count >= 3 {
                add(.roaming, .alerte, "Itinérances fréquentes (\(recent.count) en 1\u{00A0}h)",
                    "Le client passe souvent d'une borne à l'autre\u{00A0}: couverture qui se chevauche mal ou client indécis.")
            }
            let lost = history.disconnections(for: client.mac).filter { $0 >= now.addingTimeInterval(-86_400) }
            if lost.count >= 2 {
                add(.disconnects, .alerte, "Déconnexions répétées (\(lost.count) en 24\u{00A0}h)",
                    "Absent de plusieurs lectures des bornes puis revenu.")
            }
            if history.trend(for: client.mac) == .falling {
                add(.falling, .conseil, "Signal en baisse", "Le RSSI des derniers relevés est nettement plus bas qu'au début de l'historique.")
            }
        }
        if result.isEmpty {
            add(.healthy, .info, "Aucun problème repéré", "Signal, bande et charge de la borne dans les seuils.")
        }
        return result.sorted { $0.severity < $1.severity }
    }

    static func rate(_ mbps: Double) -> String {
        (mbps == mbps.rounded() ? "\(Int(mbps))" : String(format: "%.1f", mbps).replacingOccurrences(of: ".", with: ",")) + "\u{00A0}Mb/s"
    }
}
