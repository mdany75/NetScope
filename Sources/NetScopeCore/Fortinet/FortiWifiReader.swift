import Foundation

// Note 27 : lecture du Wi-Fi d'une FortiGate (GET seulement), avec le même transport et le même
// jeton que les FortiSwitch. La lecture des switchs (FortiGateReader.read) n'est pas touchée : le
// Wi-Fi est lu à part, après elle ou à la demande de l'écran Wi-Fi.

/// Adresses de l'API utilisées pour le Wi-Fi (toutes en lecture).
public enum FortiWifiPaths {
    public static let managedAP = "/api/v2/monitor/wifi/managed_ap"
    public static let client = "/api/v2/monitor/wifi/client"
    public static let vap = "/api/v2/cmdb/wireless-controller/vap"
    /// Champs demandés à vap : jamais les secrets (« passphrase », « sae-password », « mpsk-key »,
    /// secrets RADIUS ou de portail), que FortiOS renvoie chiffrés par une clé connue.
    public static let vapFields = "name|ssid|security|vlanid|broadcast-ssid|local-bridging|max-clients|portal-type|security-exempt-list"
    public static let rogueAP = "/api/v2/monitor/wifi/rogue_ap"
    public static let interferingAP = "/api/v2/monitor/wifi/interfering_ap"
    public static let apStatus = "/api/v2/monitor/wifi/ap_status"

    /// Tous les chemins, dans l'ordre de la lecture.
    public static let all = [managedAP, client, vap, rogueAP, interferingAP, apStatus]
}

extension FortiGateReader {
    /// Lit les bornes, les clients, les SSID et les AP voisins. Seules les bornes sont
    /// indispensables : 403 sur managed_ap lève l'erreur (droit « WiFi & Switch Controller » en
    /// lecture manquant) ; 404 rend un relevé « contrôleur Wi-Fi absent » ; les autres adresses
    /// absentes ou refusées sont notées et ignorées.
    public func readWifi(now: Date = Date()) async throws -> FortiWifiReport {
        do {
            return try await readWifiKeepingCalls(now: now)
        } catch let failure as FortiReadFailure {
            throw failure.error
        }
    }

    /// Comme `readWifi`, mais une erreur emporte les appels déjà faits (`FortiReadFailure`).
    public func readWifiKeepingCalls(now: Date = Date()) async throws -> FortiWifiReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readWifiAll(now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    private func readWifiAll(now: Date, calls: inout [FortiCallRecord]) async throws -> FortiWifiReport {
        var report = FortiWifiReport(readAt: now)

        let aps = try await fetch(FortiWifiPaths.managedAP)
        calls.append(aps.record)
        switch aps.error {
        case .notFound?:
            report.available = false
            report.notes.append("Contrôleur Wi-Fi absent de cette version de FortiOS (HTTP 404 sur managed_ap)\u{00A0}: aucune borne FortiAP à lire.")
            report.calls = calls
            return report
        case .some(let error):
            // 403 : droit manquant, expliqué ; autre erreur : la lecture Wi-Fi n'a pas de sens sans les bornes.
            throw error
        case nil:
            break
        }
        guard let body = aps.response?.body, let parsed = FortiWifiParsers.managedAPs(body, now: now) else {
            throw FortiGateError.invalidResponse(path: FortiWifiPaths.managedAP)
        }
        report.aps = parsed

        let clients = try await fetch(FortiWifiPaths.client)
        calls.append(clients.record)
        if let body = clients.response?.body, clients.error == nil, let list = FortiWifiParsers.clients(body, now: now) {
            report.clients = FortiWifiMerge.resolveAPNames(list, aps: parsed)
            // Liste lue mais vide alors que les bornes annoncent des clients : jamais un 0 silencieux.
            if report.clients.isEmpty, let note = Self.missingClients(parsed) { report.notes.append(note) }
        } else if let note = Self.note("Clients Wi-Fi", clients.error) {
            report.notes.append(note)
        } else if let note = Self.unreadable("Clients Wi-Fi", clients.response) {
            // Réponse reçue mais illisible : l'écart avec les bornes dit ce qui manque.
            report.notes.append(note + (Self.missingClients(parsed).map { " " + $0.replacingOccurrences(of: "Clients Wi-Fi\u{00A0}: l", with: "L") } ?? ""))
        }

        let vap = try await fetch(FortiWifiPaths.vap, query: [URLQueryItem(name: "format", value: FortiWifiPaths.vapFields)])
        calls.append(vap.record)
        if let body = vap.response?.body, vap.error == nil, let list = FortiWifiParsers.ssids(body) {
            report.ssids = list
        } else if let note = Self.note("SSID", vap.error) ?? Self.unreadable("SSID", vap.response) {
            report.notes.append(note)
        }

        // AP voisins : rogue_ap (classés), sinon interfering_ap (voisins entendus par les bornes).
        let rogue = try await fetch(FortiWifiPaths.rogueAP)
        calls.append(rogue.record)
        if let body = rogue.response?.body, rogue.error == nil, let list = FortiWifiParsers.rogues(body, now: now) {
            report.rogues = list
        } else {
            let interfering = try await fetch(FortiWifiPaths.interferingAP)
            calls.append(interfering.record)
            if let body = interfering.response?.body, interfering.error == nil, let list = FortiWifiParsers.rogues(body, now: now) {
                report.rogues = list
            } else if let note = Self.neighboursNote(rogue: rogue, interfering: interfering) {
                report.notes.append(note)
            }
        }

        // Bilan des bornes (selon la version) : gardé dans les réponses brutes du diagnostic.
        let status = try await fetch(FortiWifiPaths.apStatus)
        calls.append(status.record)

        report.calls = calls
        return report
    }

    /// AP voisins : la cause la plus parlante des deux adresses (réponse illisible, puis droit
    /// refusé, puis autre erreur, et seulement en dernier « adresse absente »).
    static func neighboursNote(rogue: Fetched, interfering: Fetched) -> String? {
        for fetched in [interfering, rogue] where fetched.error == nil {
            if let note = unreadable("AP voisins", fetched.response) { return note }
        }
        let errors = [rogue.error, interfering.error].compactMap { $0 }
        func isForbidden(_ e: FortiGateError) -> Bool { if case .forbidden = e { return true }; return false }
        func isNotFound(_ e: FortiGateError) -> Bool { if case .notFound = e { return true }; return false }
        let chosen = errors.first(where: isForbidden) ?? errors.first { !isNotFound($0) } ?? errors.first
        return note("AP voisins", chosen)
    }

    /// Réponse reçue (HTTP 2xx) mais illisible : dit au lieu d'afficher une liste vide.
    static func unreadable(_ part: String, _ response: FortiHTTPResponse?) -> String? {
        guard let response, !response.body.isEmpty else { return nil }
        return "\(part)\u{00A0}: réponse de la FortiGate illisible (JSON invalide)\u{00A0}; «\u{00A0}Copier les réponses brutes (diagnostic)\u{00A0}» dans Réglages › Switchs permet de la transmettre."
    }

    /// Bornes qui annoncent des clients alors que la liste des clients est vide.
    static func missingClients(_ aps: [FortiManagedAP]) -> String? {
        let announced = aps.filter { !$0.isOffline }.reduce(0) { $0 + $1.totalClients }
        guard announced > 0 else { return nil }
        return "Clients Wi-Fi\u{00A0}: les bornes annoncent \(announced) client\(announced > 1 ? "s" : ""), mais la FortiGate n’en a renvoyé aucun dans la liste des clients (monitor/wifi/client)."
    }

    /// Explication d'une partie facultative absente (404) ou refusée (403).
    static func note(_ part: String, _ error: FortiGateError?) -> String? {
        switch error {
        case .notFound?: return "\(part)\u{00A0}: adresse absente de cette version de FortiOS."
        case .forbidden?: return "\(part)\u{00A0}: accès refusé (HTTP 403), ajoutez le droit «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture au profil de l’administrateur API."
        case .some(let other): return "\(part)\u{00A0}: \(other.errorDescription ?? "lecture impossible.")"
        case nil: return nil
        }
    }
}

extension FortiGateError {
    /// Message propre au Wi-Fi pour un 403 sur les bornes.
    public var wifiDescription: String {
        if case .forbidden = self {
            return "Accès refusé (HTTP 403) aux bornes FortiAP\u{00A0}: ajoutez le droit «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture au profil de l’administrateur API (System › Admin Profiles), ou vérifiez que ce Mac est dans ses hôtes de confiance."
        }
        return errorDescription ?? "Lecture impossible."
    }
}
