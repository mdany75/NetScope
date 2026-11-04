import Foundation

// Note 39 : lecture du WAN d'une FortiGate (GET seulement), avec le même transport et le même
// jeton que les FortiSwitch. Système, configuration et état des interfaces, sondes et membres
// SD-WAN, configuration des SLA, tunnels IPsec et utilisateurs VPN SSL. Chaque partie absente de
// cette version de FortiOS (404) ou refusée au profil (403) est notée et ignorée ; seuls le
// système (jeton, hôte de confiance) et un refus de toutes les parties lèvent l'erreur.

/// Adresses de l'API utilisées pour le WAN (toutes en lecture).
public enum WANPaths {
    public static let system = FortiPaths.systemStatus
    /// Configuration des interfaces : rôle, alias, adressage, bande passante estimée.
    public static let interfaceConfig = FortiPaths.interfacesConfig
    public static let interfaceFields = "name|alias|role|type|status|mode|ip|interface|estimated-upstream-bandwidth|estimated-downstream-bandwidth"
    /// État des interfaces : lien, vitesse, compteurs.
    public static let interfaceStatus = FortiPaths.interfacesMonitor
    public static let healthCheck = "/api/v2/monitor/virtual-wan/health-check"
    /// FortiOS 7.0 et plus (absent en 6.4).
    public static let members = "/api/v2/monitor/virtual-wan/members"
    /// FortiOS 7.x, sinon system/virtual-wan-link (6.4).
    public static let sdwanConfig = "/api/v2/cmdb/system/sdwan"
    public static let sdwanConfigLegacy = "/api/v2/cmdb/system/virtual-wan-link"
    public static let ipsec = "/api/v2/monitor/vpn/ipsec"
    public static let ssl = "/api/v2/monitor/vpn/ssl"

    public static let all = [system, interfaceConfig, interfaceStatus, healthCheck, members, sdwanConfig, sdwanConfigLegacy, ipsec, ssl]
}

extension FortiGateReader {
    /// Lit l'état du WAN. Voir `readWANKeepingCalls`.
    public func readWAN(now: Date = Date()) async throws -> WANReadReport {
        do {
            return try await readWANKeepingCalls(now: now)
        } catch let failure as FortiReadFailure {
            throw failure.error
        }
    }

    /// Comme `readWAN`, mais une erreur emporte les appels déjà faits (`FortiReadFailure`).
    public func readWANKeepingCalls(now: Date = Date()) async throws -> WANReadReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readWANAll(now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    private func readWANAll(now: Date, calls: inout [FortiCallRecord]) async throws -> WANReadReport {
        var report = WANReadReport(readAt: now)

        let system = try await fetch(WANPaths.system)
        calls.append(system.record)
        if let error = system.error { throw error }
        if let body = system.response?.body { report.system = FortiParsers.system(body) }

        // Configuration des interfaces (rôle WAN) : facultative, le nom « wanN » sert sinon.
        let config = try await fetch(WANPaths.interfaceConfig, query: [URLQueryItem(name: "format", value: WANPaths.interfaceFields)])
        calls.append(config.record)
        var configured: [String: WANInterfaceStatus]?
        if let body = config.response?.body, config.error == nil, let map = WANParsers.interfaceConfig(body) {
            configured = map
        } else if let note = Self.wanNote("Rôle des interfaces", config.error, right: "Network") {
            report.notes.append(note + " Les liens WAN sont devinés d’après leur nom et le SD-WAN.")
        }

        let status = try await fetch(WANPaths.interfaceStatus, query: [URLQueryItem(name: "include_vlan", value: "true"),
                                                                       URLQueryItem(name: "include_aggregate", value: "true")])
        calls.append(status.record)
        var states: [String: WANInterfaceStatus] = [:]
        if let body = status.response?.body, status.error == nil, let map = WANParsers.interfaceStatus(body) {
            states = map
        } else if let note = Self.wanNote("État des interfaces", status.error, right: "System") {
            report.notes.append(note)
        }

        // SD-WAN : mesures des sondes, membres (7.0 et plus), configuration des SLA.
        let health = try await fetch(WANPaths.healthCheck)
        calls.append(health.record)
        if let body = health.response?.body, health.error == nil, let list = WANParsers.health(body, now: now) {
            report.health = list
        } else {
            report.sdwanRead = false
            if let note = Self.wanNote("Sondes SD-WAN", health.error, right: "Network") { report.notes.append(note) }
        }

        var members: [WANInterfaceStatus] = []
        let liveMembers = try await fetch(WANPaths.members)
        calls.append(liveMembers.record)
        if let body = liveMembers.response?.body, liveMembers.error == nil, let list = WANParsers.members(body) { members = list }

        var sdwan = try await fetch(WANPaths.sdwanConfig)
        calls.append(sdwan.record)
        if case .notFound? = sdwan.error {
            sdwan = try await fetch(WANPaths.sdwanConfigLegacy)
            calls.append(sdwan.record)
        }
        var configMembers: [WANInterfaceStatus] = []
        if let body = sdwan.response?.body, sdwan.error == nil, let parsed = WANParsers.sdwanConfig(body) {
            report.healthConfig = parsed.checks
            if parsed.enabled != false { configMembers = parsed.members }
        } else if case .forbidden? = sdwan.error {
            report.notes.append("Objectifs SLA du SD-WAN\u{00A0}: accès refusé (HTTP 403), ajoutez le droit «\u{00A0}Network\u{00A0}» en lecture au profil de l’administrateur API\u{00A0}; seuls les seuils de NetScope sont appliqués.")
        }

        report.interfaces = WANAnalysis.wanInterfaces(config: configured, states: states, members: members,
                                                      configMembers: configMembers, health: report.health)

        if report.sdwanRead, report.health.isEmpty, configMembers.isEmpty, members.isEmpty {
            report.notes.append("SD-WAN non configuré sur cette FortiGate\u{00A0}: latence et perte des liens non mesurées (aucune sonde de performance).")
        }

        // Tunnels VPN IPsec.
        let ipsec = try await fetch(WANPaths.ipsec)
        calls.append(ipsec.record)
        if let body = ipsec.response?.body, ipsec.error == nil, let list = WANParsers.tunnels(body, now: now) {
            report.tunnels = list
        } else {
            report.tunnelsRead = false
            if let note = Self.wanNote("Tunnels VPN IPsec", ipsec.error, right: "VPN") { report.notes.append(note) }
        }

        // VPN SSL (facultatif ; retiré de certains modèles en 7.6) : seulement noté s'il est refusé.
        let ssl = try await fetch(WANPaths.ssl)
        calls.append(ssl.record)
        if let body = ssl.response?.body, ssl.error == nil, let list = WANParsers.sslUsers(body, now: now) {
            report.sslUsers = list
        } else if case .forbidden? = ssl.error, let note = Self.wanNote("VPN SSL", ssl.error, right: "VPN") {
            report.notes.append(note)
        }

        // Tout refusé : rien à montrer, l'erreur explique le droit à ajouter.
        let refused = [status.error, health.error, ipsec.error].allSatisfy { if case .forbidden? = $0 { return true } else { return false } }
        if refused { throw FortiGateError.forbidden(path: WANPaths.interfaceStatus) }

        report.calls = calls
        return report
    }

    /// Explication d'une partie absente (404) ou refusée (403).
    static func wanNote(_ part: String, _ error: FortiGateError?, right: String) -> String? {
        switch error {
        case .notFound?: return "\(part)\u{00A0}: adresse absente de cette version de FortiOS."
        case .forbidden?: return "\(part)\u{00A0}: accès refusé (HTTP 403), ajoutez le droit «\u{00A0}\(right)\u{00A0}» en lecture au profil de l’administrateur API."
        case .some(let other): return "\(part)\u{00A0}: \(other.errorDescription ?? "lecture impossible.")"
        case nil: return nil
        }
    }
}

extension FortiGateError {
    /// Message propre au WAN pour un 403.
    public var wanDescription: String {
        if case .forbidden = self {
            return "Accès refusé (HTTP 403) au WAN de la FortiGate\u{00A0}: ajoutez les droits «\u{00A0}System\u{00A0}», «\u{00A0}Network\u{00A0}» et «\u{00A0}VPN\u{00A0}» en lecture au profil de l’administrateur API (System › Admin Profiles), ou vérifiez que ce Mac est dans ses hôtes de confiance."
        }
        return errorDescription ?? "Lecture impossible."
    }
}
