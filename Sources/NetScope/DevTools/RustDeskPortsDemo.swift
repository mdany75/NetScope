import Foundation
import NetScopeCore

/// Démonstration de la note 6 (ports RustDesk) : serveur « srv-assistance » (Ubuntu, hbbs et hbbr
/// en Docker) et poste « Poste direction » avec l'accès IP direct. Aucun accès réseau : le test du
/// serveur renvoie un bilan fixe.
@MainActor
enum RustDeskPortsDemo {
    static let serverIP = "10.10.0.20"
    static let clientIP = "10.182.122.126"

    /// Test du serveur déjà fait (fiche Appareil de srv-assistance) : ID, relais et test NAT répondent,
    /// WebSocket du relais fermé (client web non utilisé).
    static func preload(_ model: RustDeskServerTestModel) {
        let date = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
        model.store(report(for: serverIP), for: serverIP, at: date)
    }

    static func report(for host: String) -> RustDeskPorts.ServerReport {
        guard host == serverIP else {
            return RustDeskPorts.ServerReport(results: RustDeskPorts.serverTestPorts.map { PortScanResult(port: $0, state: .filtered) })
        }
        return RustDeskPorts.ServerReport(results: [
            PortScanResult(port: 21115, state: .open, rttMs: 1.3),
            PortScanResult(port: 21116, state: .open, rttMs: 1.1),
            PortScanResult(port: 21117, state: .open, rttMs: 1.2),
            PortScanResult(port: 21118, state: .open, rttMs: 1.4),
            PortScanResult(port: 21119, state: .closed, rttMs: 0.9),
        ])
    }
}
