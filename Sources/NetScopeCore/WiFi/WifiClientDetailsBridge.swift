import Foundation

// Pont entre la fiche du client Wi-Fi (note 46 : détails lus dans /monitor/wifi/client et
// historique du signal) et les données facultatives du diagnostic (note 47). Rien n'est lu sur
// le réseau : tout vient de la dernière lecture et de l'historique déjà gardé.

extension WifiClientDetails {
    /// Détails du diagnostic tirés de la fiche du client et de l'historique de son site.
    /// - Parameters:
    ///   - window: période observée pour les itinérances, les déconnexions et la courbe (60 min).
    public init(client: FortiWifiClient, history: FortiWifiSignalHistory?, now: Date = Date(), window: TimeInterval = 3600) {
        let info = client.info
        self.init(standard: client.standard,
                  txRateMbps: info.txRateMbps ?? client.rateMbps,
                  rxRateMbps: info.rxRateMbps,
                  supports5GHz: (client.band == .ghz5 || client.band == .ghz6) ? true : nil,
                  supports6GHz: client.band == .ghz6 ? true : nil,
                  authMethod: info.authenticationLabel)
        guard let history else { return }
        let start = now.addingTimeInterval(-window)
        let samples = history.samples(for: client.mac, within: window, now: now)
        guard !samples.isEmpty else { return }
        roams = history.roams(for: client.mac).filter { $0.date >= start && $0.date <= now }.count
        disconnects = history.disconnections(for: client.mac).filter { $0 >= start && $0 <= now }.count
        windowMinutes = Int((window / 60).rounded())
        signalHistory = samples.compactMap(\.rssi)
        // Vu en 5 ou 6 GHz dans l'historique : le client sait s'y connecter.
        if samples.contains(where: { $0.band == .ghz5 || $0.band == .ghz6 }) { supports5GHz = true }
        if samples.contains(where: { $0.band == .ghz6 }) { supports6GHz = true }
    }

    /// Complète les champs absents par ceux de `other` (les champs déjà connus sont gardés).
    public func filling(from other: WifiClientDetails) -> WifiClientDetails {
        var d = self
        d.standard = d.standard ?? other.standard
        d.spatialStreams = d.spatialStreams ?? other.spatialStreams
        d.txRateMbps = d.txRateMbps ?? other.txRateMbps
        d.rxRateMbps = d.rxRateMbps ?? other.rxRateMbps
        d.powerSave = d.powerSave ?? other.powerSave
        d.supports5GHz = d.supports5GHz ?? other.supports5GHz
        d.supports6GHz = d.supports6GHz ?? other.supports6GHz
        d.authMethod = d.authMethod ?? other.authMethod
        d.authFailures = d.authFailures ?? other.authFailures
        d.lastFailureReason = d.lastFailureReason ?? other.lastFailureReason
        d.disconnects = d.disconnects ?? other.disconnects
        d.roams = d.roams ?? other.roams
        d.windowMinutes = d.windowMinutes ?? other.windowMinutes
        d.dhcpDelayMs = d.dhcpDelayMs ?? other.dhcpDelayMs
        if d.heardAPs.isEmpty { d.heardAPs = other.heardAPs }
        if d.signalHistory.isEmpty { d.signalHistory = other.signalHistory }
        return d
    }
}
