import Foundation
import NetScopeCore

/// Démonstration des ajouts de la note 78 au ping continu (--demo, --snapshot) : 24 h
/// d'agrégats horaires réalistes pour le rapport « pour le fournisseur Internet » (soirées
/// chargées, une panne du lien la nuit), cibles supplémentaires pour le tableau compact et
/// disposition imposée pour les captures. Aucun paquet n'est envoyé.
///
/// Captures :
/// - NETSCOPE_PING_COMPACT=1 : 14 cibles, l'écran passe tout seul au tableau compact ;
/// - NETSCOPE_PING_DISPOSITION=tableau (ou cartes) : disposition imposée.
@MainActor
enum PingSessionDemo {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Cibles ajoutées pour la capture du tableau compact.
    static var extraInputs: [String] {
        environment["NETSCOPE_PING_COMPACT"] == "1" ? extraProfiles.map(\.input) : []
    }

    private static let extraProfiles: [PingDemo.Profile] = [
        .init(input: "10.182.122.3", name: "SW-ETG1-01", role: "Catalyst 9200-24P", base: 2.8, jitter: 1.4, loss: 0.003, burst: 0, spike: 0.02, threshold: 15),
        .init(input: "10.182.122.4", name: "SW-ETG2-01", role: "Catalyst 9200-48P", base: 3.1, jitter: 1.7, loss: 0.004, burst: 0, spike: 0.02, threshold: 15),
        .init(input: "10.182.122.20", name: "FAP-231F-Accueil", role: "Borne Wi-Fi · VLAN 30", base: 4.4, jitter: 2.6, loss: 0.01, burst: 0, spike: 0.05, threshold: 20),
        .init(input: "10.182.122.21", name: "FAP-231F-Entrepôt", role: "Borne Wi-Fi · VLAN 30", base: 5.1, jitter: 3.4, loss: 0.02, burst: 0.004, spike: 0.06, threshold: 20),
        .init(input: "10.182.122.30", name: "SRV-FICHIERS", role: "Serveur · VLAN 10", base: 0.9, jitter: 0.4, loss: 0, burst: 0, spike: 0.01, threshold: 5),
        .init(input: "10.182.122.40", name: "Imprimante 2e étage", role: "Imprimante · VLAN 20", base: 3.0, jitter: 1.2, loss: 0.005, burst: 0, spike: 0.02, threshold: 20),
        .init(input: "192.168.50.22", name: "Caméra-Cour", role: "Caméra · VLAN 40", base: 4.2, jitter: 2.1, loss: 0.01, burst: 0, spike: 0.03, threshold: 20),
        .init(input: "9.9.9.9", name: "Quad9", role: "Internet", base: 16.4, jitter: 2.2, loss: 0.004, burst: 0, spike: 0.015, threshold: 40),
    ]

    static func profile(for input: String) -> PingDemo.Profile? {
        extraProfiles.first { $0.input == input }
    }

    /// Disposition imposée pour les captures.
    static func adjust(_ controller: PingController) {
        switch environment["NETSCOPE_PING_DISPOSITION"]?.lowercased() {
        case "tableau", "table": controller.layoutChoice = .table
        case "cartes", "cards": controller.layoutChoice = .cards
        default: break
        }
        // Seuil réglé à la main sur la caméra (montré dans sa carte et le tableau).
        if let camera = controller.targets.first(where: { $0.input == "192.168.50.21" }) {
            controller.update(camera.id) { $0.thresholdMs = 30 }
        }
    }

    // MARK: Journal long (rapport pour le fournisseur Internet)

    /// Cibles qui ont 24 h de mesures : la passerelle et les trois résolveurs publics.
    static let longLogInputs: Set<String> = ["10.182.122.1", "8.8.8.8", "1.1.1.1", "9.9.9.9"]

    /// Panne nocturne du lien Internet : la plus récente nuit à 2 h 14, pendant 3 min 20 s.
    static let outageSeconds: TimeInterval = 200

    static func outageStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.date(bySettingHour: 2, minute: 14, second: 0, of: now) ?? now.addingTimeInterval(-12 * 3600)
        return today > now.addingTimeInterval(-3600) ? today.addingTimeInterval(-86_400) : today
    }

    /// 24 h de mesures toutes les 4 s : latence plus haute et pertes le soir (19 h à 22 h) sur
    /// Internet, panne de 3 min 20 s la nuit ; la passerelle reste propre.
    static func longLog(for input: String, threshold: Double, now: Date, calendar: Calendar = .current) -> PingLongLog {
        var log = PingLongLog()
        guard longLogInputs.contains(input) else { return log }
        let internet = input != "10.182.122.1"
        let base = PingDemo.profile(for: input)?.base ?? profile(for: input)?.base ?? 14
        var random = PingDemo.Random(state: 0x15F0_2026 ^ UInt64(input.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }))
        let step: TimeInterval = 4
        let start = now.addingTimeInterval(-24 * 3600)
        let outageStart = outageStart(now: now, calendar: calendar)
        var sequence = 0
        var date = start
        while date < now {
            sequence += 1
            let hour = calendar.component(.hour, from: date)
            let evening = internet && (19...21).contains(hour)
            var value: Double? = base + abs(random.gauss()) * (evening ? 9 : 1.4) + (evening ? base * 1.6 : 0)
            let loss = internet ? (evening ? 0.03 : 0.002) : 0.0005
            if random.next() < loss { value = nil }
            if internet, date >= outageStart, date < outageStart.addingTimeInterval(outageSeconds) { value = nil }
            log.record(PingSample(sequence: sequence, date: date, rttMs: value.map { ($0 * 10).rounded() / 10 }),
                       thresholdMs: threshold, calendar: calendar)
            date = date.addingTimeInterval(step)
        }
        return log
    }

    /// Rapport de démonstration (vérification du PDF pendant les captures).
    static func report(now: Date) -> PingISPReport {
        let inputs = ["10.182.122.1", "8.8.8.8", "1.1.1.1"].compactMap { input -> PingISPReport.Input? in
            guard let profile = PingDemo.profile(for: input) else { return nil }
            return PingISPReport.Input(name: profile.name, address: input, role: profile.role, thresholdMs: profile.threshold,
                                       log: longLog(for: input, threshold: profile.threshold, now: now))
        }
        return PingISPReport.make(inputs, generatedAt: now)
    }
}
