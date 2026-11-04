import Foundation

// Note 54 : « Analyse complète du réseau ». Un bilan qui réunit le trafic (plus gros consommateurs,
// applications inattendues, pays inhabituels), la sécurité (menaces, appareils visés), la santé
// (WAN et SD-WAN quand ils sont lus, ports de switch saturés ou en erreur, Wi-Fi, étendues DHCP) et
// l'inventaire (appareils inconnus). Chaque point a une gravité, une explication et une action
// conseillée. Règles pures et testées ; l'application fournit ce qu'elle a déjà lu.

/// Gravité d'un point de l'analyse.
public enum NetworkFindingSeverity: Int, Codable, Sendable, Comparable, CaseIterable {
    case critical = 0, warning, advice, ok

    public var label: String {
        switch self {
        case .critical: return "Critique"
        case .warning: return "Alerte"
        case .advice: return "Conseil"
        case .ok: return "Bon"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Domaine d'un point.
public enum NetworkFindingArea: String, Codable, Sendable, CaseIterable {
    case traffic, security, health, inventory

    public var label: String {
        switch self {
        case .traffic: return "Trafic"
        case .security: return "Sécurité"
        case .health: return "Santé"
        case .inventory: return "Inventaire"
        }
    }

    public var symbol: String {
        switch self {
        case .traffic: return "arrow.up.arrow.down"
        case .security: return "lock.shield"
        case .health: return "stethoscope"
        case .inventory: return "list.bullet"
        }
    }
}

/// Ce que montre « Voir » d'un point.
public enum NetworkFindingTarget: Hashable, Sendable {
    case device(ip: String, mac: String?, site: String)
    case link(name: String, site: String)
    case trafficView(TrafficView)
    case accessPoint(name: String, site: String)
    case switchPort(host: String, port: String)
    case dhcpScope(id: String)
    case wan(site: String)
    case inventory(site: String)
    case none
}

public struct NetworkFinding: Hashable, Sendable, Identifiable {
    public var id: String
    public var severity: NetworkFindingSeverity
    public var area: NetworkFindingArea
    public var title: String
    public var explanation: String
    public var action: String
    public var site: String?
    public var target: NetworkFindingTarget

    public init(id: String, severity: NetworkFindingSeverity, area: NetworkFindingArea, title: String, explanation: String,
                action: String, site: String? = nil, target: NetworkFindingTarget = .none) {
        self.id = id
        self.severity = severity
        self.area = area
        self.title = title
        self.explanation = explanation
        self.action = action
        self.site = site
        self.target = target
    }
}

/// État d'un lien WAN ou d'un tunnel (fourni par la lecture du WAN, note 39, quand elle existe).
public struct NetworkWANStatus: Hashable, Sendable {
    public var site: String
    public var name: String
    public var isTunnel: Bool
    public var isUp: Bool
    public var latencyMs: Double?
    public var lossPercent: Double?
    public var jitterMs: Double?

    public init(site: String, name: String, isTunnel: Bool = false, isUp: Bool, latencyMs: Double? = nil,
                lossPercent: Double? = nil, jitterMs: Double? = nil) {
        self.site = site
        self.name = name
        self.isTunnel = isTunnel
        self.isUp = isUp
        self.latencyMs = latencyMs
        self.lossPercent = lossPercent
        self.jitterMs = jitterMs
    }
}

/// Port de switch en difficulté.
public struct NetworkPortIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Compteur d'erreurs en entrée (depuis le démarrage du switch).
        case errors(UInt64)
        /// Charge du lien (%).
        case saturated(Double)
    }

    public var site: String
    public var switchName: String
    public var host: String
    public var port: String
    public var kind: Kind

    public init(site: String, switchName: String, host: String, port: String, kind: Kind) {
        self.site = site
        self.switchName = switchName
        self.host = host
        self.port = port
        self.kind = kind
    }
}

/// Appareil inconnu de l'inventaire.
public struct NetworkUnknownDevice: Hashable, Sendable {
    public var site: String
    public var ip: String
    public var mac: String?
    public var name: String
    public var firstSeen: Date

    public init(site: String, ip: String, mac: String? = nil, name: String, firstSeen: Date) {
        self.site = site
        self.ip = ip
        self.mac = mac
        self.name = name
        self.firstSeen = firstSeen
    }
}

/// Ce dont l'analyse a besoin ; nil : partie non lue (dite dans la couverture).
public struct NetworkAnalysisInput: Sendable {
    public var traffic: TrafficOverview?
    public var trafficThresholds: TrafficThresholds
    public var wan: [NetworkWANStatus]?
    /// Seuils d'un lien dégradé : ceux de l'onglet WAN, pour que l'analyse et l'onglet concordent.
    public var wanThresholds: WANThresholds
    public var ports: [NetworkPortIssue]?
    public var wifi: FortiWifiDiagnosis?
    public var dhcp: DHCPScopeOverview?
    public var dhcpThresholds: DHCPScopeThresholds
    public var unknownDevices: [NetworkUnknownDevice]?
    public var now: Date

    public init(traffic: TrafficOverview? = nil, trafficThresholds: TrafficThresholds = .standard, wan: [NetworkWANStatus]? = nil,
                wanThresholds: WANThresholds = .standard, ports: [NetworkPortIssue]? = nil, wifi: FortiWifiDiagnosis? = nil, dhcp: DHCPScopeOverview? = nil,
                dhcpThresholds: DHCPScopeThresholds = .standard, unknownDevices: [NetworkUnknownDevice]? = nil, now: Date = Date()) {
        self.traffic = traffic
        self.trafficThresholds = trafficThresholds
        self.wan = wan
        self.wanThresholds = wanThresholds
        self.ports = ports
        self.wifi = wifi
        self.dhcp = dhcp
        self.dhcpThresholds = dhcpThresholds
        self.unknownDevices = unknownDevices
        self.now = now
    }
}

/// Partie de l'analyse et ce qu'elle a pu lire.
public struct NetworkCoverage: Hashable, Sendable, Identifiable {
    public var id: String { part }
    public var part: String
    public var analyzed: Bool
    public var detail: String
}

public struct NetworkAnalysisResult: Hashable, Sendable {
    public var findings: [NetworkFinding]
    public var coverage: [NetworkCoverage]
    /// Note sur 100 (100 : rien à signaler).
    public var score: Int
    public var date: Date

    public func count(_ severity: NetworkFindingSeverity) -> Int { findings.filter { $0.severity == severity }.count }
    public func findings(_ area: NetworkFindingArea) -> [NetworkFinding] { findings.filter { $0.area == area } }

    /// « 2 points critiques, 3 alertes et 4 conseils ».
    public var summary: String {
        let critical = count(.critical)
        let warning = count(.warning)
        let advice = count(.advice)
        if critical + warning + advice == 0 { return "Aucun problème relevé dans les parties analysées." }
        var parts: [String] = []
        if critical > 0 { parts.append("\(critical) point\(critical > 1 ? "s" : "") critique\(critical > 1 ? "s" : "")") }
        if warning > 0 { parts.append("\(warning) alerte\(warning > 1 ? "s" : "")") }
        if advice > 0 { parts.append("\(advice) conseil\(advice > 1 ? "s" : "")") }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " et " + parts.last! : parts[0]
    }

    /// Appréciation de la note.
    public var grade: String {
        switch score {
        case 90...: return "Réseau en bonne santé"
        case 70..<90: return "Quelques points à surveiller"
        case 40..<70: return "Plusieurs problèmes à corriger"
        default: return "Problèmes importants"
        }
    }
}

public enum NetworkAnalysis {
    /// Seuil d'erreurs d'un port signalé (compteur depuis le démarrage du switch).
    public static let portErrorThreshold: UInt64 = 1000
    /// Un appareil inconnu vu depuis moins de 24 h est « nouveau ».
    public static let recentUnknown: TimeInterval = 86_400

    public static func analyze(_ input: NetworkAnalysisInput) -> NetworkAnalysisResult {
        var findings: [NetworkFinding] = []
        var coverage: [NetworkCoverage] = []
        let nbsp = "\u{00A0}"

        // MARK: Trafic et sécurité
        if let traffic = input.traffic, !traffic.isEmpty {
            coverage.append(NetworkCoverage(part: "Trafic (FortiView)", analyzed: true,
                                            detail: traffic.sites.joined(separator: ", ") + " · " + traffic.period.span))
            findings += trafficFindings(traffic, thresholds: input.trafficThresholds)
            findings += securityFindings(traffic)
        } else {
            coverage.append(NetworkCoverage(part: "Trafic (FortiView)", analyzed: false,
                                            detail: "Aucune lecture FortiView\(nbsp): relisez la FortiGate dans l’écran Trafic."))
        }

        // MARK: Santé
        if let wan = input.wan {
            coverage.append(NetworkCoverage(part: "WAN et SD-WAN", analyzed: true, detail: "\(wan.count) lien\(wan.count > 1 ? "s" : "") ou tunnel\(wan.count > 1 ? "s" : "")"))
            findings += wanFindings(wan, thresholds: input.wanThresholds)
        } else {
            coverage.append(NetworkCoverage(part: "WAN et SD-WAN", analyzed: false,
                                            detail: "État des liens et des tunnels non lu (latence, perte, tunnels VPN)."))
        }
        if let ports = input.ports {
            coverage.append(NetworkCoverage(part: "Ports de switch", analyzed: true, detail: ports.isEmpty ? "aucun port en difficulté" : "\(ports.count) port\(ports.count > 1 ? "s" : "") signalé\(ports.count > 1 ? "s" : "")"))
            findings += portFindings(ports)
        } else {
            coverage.append(NetworkCoverage(part: "Ports de switch", analyzed: false, detail: "Aucun switch interrogé (SNMP ou FortiSwitch)."))
        }
        if let wifi = input.wifi {
            coverage.append(NetworkCoverage(part: "Wi-Fi (FortiAP)", analyzed: true, detail: "bornes et clients lus"))
            findings += wifiFindings(wifi)
        } else {
            coverage.append(NetworkCoverage(part: "Wi-Fi (FortiAP)", analyzed: false, detail: "Bornes FortiAP non lues."))
        }
        if let dhcp = input.dhcp, !dhcp.scopes.isEmpty {
            coverage.append(NetworkCoverage(part: "Étendues DHCP", analyzed: true,
                                            detail: dhcp.isEstimate ? "estimation par le Test DHCP" : "\(dhcp.scopes.count) étendue\(dhcp.scopes.count > 1 ? "s" : "")"))
            findings += dhcpFindings(dhcp, thresholds: input.dhcpThresholds)
        } else {
            coverage.append(NetworkCoverage(part: "Étendues DHCP", analyzed: false, detail: "Étendues non lues."))
        }

        // MARK: Inventaire
        if let unknown = input.unknownDevices {
            coverage.append(NetworkCoverage(part: "Inventaire", analyzed: true, detail: "\(unknown.count) appareil\(unknown.count > 1 ? "s" : "") inconnu\(unknown.count > 1 ? "s" : "")"))
            findings += inventoryFindings(unknown, now: input.now)
        } else {
            coverage.append(NetworkCoverage(part: "Inventaire", analyzed: false, detail: "Aucun inventaire."))
        }

        findings.sort { ($0.severity, areaOrder($0.area), $0.title) < ($1.severity, areaOrder($1.area), $1.title) }
        let critical = findings.filter { $0.severity == .critical }.count
        let warning = findings.filter { $0.severity == .warning }.count
        let advice = findings.filter { $0.severity == .advice }.count
        // Note dégressive : chaque point pèse moins quand il y en a déjà beaucoup (jamais 0 d'office).
        let weight = 1 + 0.25 * Double(critical) + 0.08 * Double(warning) + 0.02 * Double(advice)
        let score = Int((100 / weight).rounded())
        if findings.isEmpty, coverage.contains(where: \.analyzed) {
            findings.append(NetworkFinding(id: "ok", severity: .ok, area: .health, title: "Rien à signaler",
                                           explanation: "Aucun problème relevé dans les parties analysées.",
                                           action: "Relancer l’analyse après un scan ou une relecture des FortiGate."))
        }
        return NetworkAnalysisResult(findings: findings, coverage: coverage, score: score, date: input.now)
    }

    static func areaOrder(_ area: NetworkFindingArea) -> Int { NetworkFindingArea.allCases.firstIndex(of: area) ?? 0 }

    // MARK: Règles du trafic

    static func trafficFindings(_ traffic: TrafficOverview, thresholds: TrafficThresholds) -> [NetworkFinding] {
        var result: [NetworkFinding] = []
        let nbsp = "\u{00A0}"
        let multi = traffic.isMultiSite
        func at(_ site: String) -> String { multi ? " (\(site))" : "" }

        // Liens saturés.
        let usages = TrafficAnalysis.linkUsage(traffic, thresholds: thresholds)
        for usage in usages where usage.level >= .warning {
            var scoped = traffic
            scoped.entries = traffic.entries.filter { $0.site == usage.link.site }
            scoped.sessions = traffic.sessions.filter { $0.site == usage.link.site }
            scoped.links = traffic.links.filter { $0.site == usage.link.site }
            let top = TrafficAnalysis.consumers(scoped, limit: 1).first
            var explanation = "Le lien Internet \(usage.link.label) est chargé à \(ResourceFormat.percent(usage.percent ?? 0)) de sa capacité \(traffic.period.span)."
            if let top {
                explanation += " Premier consommateur\(nbsp): \(TrafficAnalysis.describe(top)), \(ResourceFormat.percent(top.sharePercent)) du trafic"
                explanation += top.mainApplication.map { " (\($0))" } ?? ""
                explanation += "."
            }
            result.append(NetworkFinding(
                id: "lien|\(usage.link.id)", severity: usage.level == .critical ? .critical : .warning, area: .traffic,
                title: "Lien \(usage.link.name) saturé" + at(usage.link.site), explanation: explanation,
                action: "Ouvrir «\(nbsp)Qui sature le lien\(nbsp)?\(nbsp)», puis déplacer le transfert hors des heures ouvrables ou limiter son débit par une régulation de trafic.",
                site: usage.link.site, target: .link(name: usage.link.name, site: usage.link.site)))
        }

        // Appareils qui consomment trop.
        for consumer in TrafficAnalysis.consumers(traffic, limit: 10) {
            let entry = consumer.entry
            let mbps = entry.bandwidth / 1_000_000
            let heavyRate = traffic.period.isRealtime && mbps >= thresholds.deviceMbps
            let heavyShare = consumer.sharePercent >= thresholds.deviceSharePercent && traffic.entries(.sources).filter({ $0.site == entry.site }).count >= 3
            guard heavyRate || heavyShare else { continue }
            // Déjà nommé comme cause d'un lien saturé : le point du lien suffit.
            if result.contains(where: { $0.site == entry.site && $0.explanation.contains(TrafficAnalysis.describe(consumer)) }) { continue }
            var explanation = "\(TrafficAnalysis.describe(consumer)) représente \(ResourceFormat.percent(consumer.sharePercent)) du trafic des appareils"
            if heavyRate { explanation += ", soit \(ResourceFormat.bitsPerSecond(entry.bandwidth))" }
            explanation += " \(traffic.period.span)."
            if let app = consumer.mainApplication { explanation += " Application principale\(nbsp): \(app)." }
            result.append(NetworkFinding(
                id: "conso|\(entry.id)", severity: .warning, area: .traffic,
                title: "\(entry.name) consomme beaucoup" + at(entry.site), explanation: explanation,
                action: "Vérifier avec l’utilisateur que ce transfert est attendu (sauvegarde, mise à jour, diffusion vidéo).",
                site: entry.site, target: .device(ip: entry.ip?.description ?? entry.key, mac: entry.mac?.formatted(.upperColon), site: entry.site)))
        }

        // Applications inattendues.
        for app in TrafficAnalysis.unexpectedApplications(traffic).prefix(5) {
            let users = traffic.sessions.filter { $0.site == app.site && $0.application == app.name }.compactMap(\.source)
            let devices = Array(Set(users)).sorted().prefix(3).map { ip -> String in
                traffic.entries(.sources).first { $0.site == app.site && $0.ip == ip }.map { "\($0.name) (\(ip))" } ?? ip.description
            }
            var explanation = "\(app.name)"
            if let category = app.category { explanation += " (\(category))" }
            let amount = traffic.period.isRealtime && app.bandwidth > 0 ? ResourceFormat.bitsPerSecond(app.bandwidth) : TrafficFormat.bytes(app.bytes)
            explanation += " est utilisée sur le réseau\(at(app.site)), risque \(TrafficFormat.risk(app.risk).lowercased()), \(amount) \(traffic.period.span)."
            if !devices.isEmpty { explanation += " Appareil\(devices.count > 1 ? "s" : "")\(nbsp): " + devices.joined(separator: ", ") + "." }
            result.append(NetworkFinding(
                id: "app|\(app.id)", severity: (app.risk ?? 0) >= 5 ? .critical : .warning, area: .traffic,
                title: "Application inattendue\(nbsp): \(app.name)" + at(app.site), explanation: explanation,
                action: "Bloquer l’application ou sa catégorie dans le profil de contrôle des applications de la FortiGate, si elle n’est pas permise.",
                site: app.site,
                target: users.first.map { .device(ip: $0.description, mac: nil, site: app.site) } ?? .trafficView(.applications)))
        }

        // Pays inhabituels.
        let countries = TrafficAnalysis.unusualCountries(traffic, thresholds: thresholds)
        if !countries.isEmpty {
            let list = countries.prefix(4).map { "\($0.country) (\(TrafficFormat.bytes($0.bytes))\(multi ? ", " + $0.site : ""))" }
            result.append(NetworkFinding(
                id: "pays", severity: .advice, area: .traffic,
                title: "Trafic vers des pays inhabituels",
                explanation: "Destinations hors des pays attendus\(nbsp): " + list.joined(separator: ", ") + (countries.count > 4 ? " et \(countries.count - 4) autres." : "."),
                action: "Vérifier ces destinations dans l’onglet Destinations\(nbsp); au besoin, filtrer par géolocalisation sur la FortiGate.",
                target: .trafficView(.destinations)))
        }
        return result
    }

    // MARK: Règles de sécurité

    static func securityFindings(_ traffic: TrafficOverview) -> [NetworkFinding] {
        var result: [NetworkFinding] = []
        let nbsp = "\u{00A0}"
        let multi = traffic.isMultiSite
        func at(_ site: String) -> String { multi ? " (\(site))" : "" }
        var named = Set<String>()
        for device in TrafficAnalysis.threatenedDevices(traffic) {
            let worst = device.threats.first?.threatLevel ?? .medium
            let passed = device.threats.contains { !$0.isBlocked }
            let names = device.threats.prefix(3).map { $0.name + ($0.threatType.map { " (\($0))" } ?? "") }
            let total = device.threats.reduce(0) { $0 + $1.incidents }
            let severity: NetworkFindingSeverity = passed && worst <= .high ? .critical : .warning
            let explanation = "\(device.name) (\(device.ip)) est lié à \(total) événement\(total > 1 ? "s" : "") de sécurité\(nbsp): " + names.joined(separator: ", ")
                + (passed ? ". Au moins un n’a pas été bloqué." : ". Tout a été bloqué par la FortiGate, mais l’appareil reste suspect.")
            result.append(NetworkFinding(
                id: "menace|\(device.site)|\(device.ip)", severity: severity, area: .security,
                title: (passed ? "Appareil possiblement infecté\(nbsp): " : "Menace bloquée\(nbsp): ") + device.name + at(device.site),
                explanation: explanation,
                action: passed ? "Isoler l’appareil (débrancher ou mettre en quarantaine), puis lancer une analyse antivirus complète."
                               : "Lancer une analyse antivirus sur l’appareil et vérifier ce qu’il contactait.",
                site: device.site, target: .device(ip: device.ip.description, mac: nil, site: device.site)))
            for threat in device.threats { named.insert(threat.id) }
        }
        // Menaces sans appareil connu (vue agrégée par menace).
        let others = TrafficAnalysis.threats(traffic).filter { !named.contains($0.id) && ($0.threatLevel ?? .info) <= .high }
        for threat in others.prefix(5) {
            let blocked = threat.isBlocked
            result.append(NetworkFinding(
                id: "menace|\(threat.id)", severity: blocked ? .warning : .critical, area: .security,
                title: "\(threat.threatType ?? "Menace")\(nbsp): \(threat.name)" + at(threat.site),
                explanation: "\(threat.incidents) événement\(threat.incidents > 1 ? "s" : "") de niveau \((threat.threatLevel ?? .medium).label.lowercased()) \(traffic.period.span)"
                    + (blocked ? ", tous bloqués." : ", pas tous bloqués."),
                action: "Ouvrir l’onglet Menaces pour voir les appareils concernés.",
                site: threat.site, target: .trafficView(.threats)))
        }
        return result
    }

    // MARK: Règles de santé

    static func wanFindings(_ wan: [NetworkWANStatus], thresholds: WANThresholds = .standard) -> [NetworkFinding] {
        let multi = Set(wan.map(\.site)).count > 1
        func at(_ site: String) -> String { multi ? " (\(site))" : "" }
        var result: [NetworkFinding] = []
        for link in wan {
            let kind = link.isTunnel ? "Tunnel VPN" : "Lien WAN"
            if !link.isUp {
                result.append(NetworkFinding(
                    id: "wan|\(link.site)|\(link.name)", severity: .critical, area: .health,
                    title: "\(kind) \(link.name) tombé" + at(link.site),
                    explanation: link.isTunnel ? "Le tunnel IPsec \(link.name) est hors service\u{00A0}: le site distant n’est plus joignable par ce tunnel."
                                               : "Le lien \(link.name) ne répond plus aux sondes de santé de la FortiGate.",
                    action: link.isTunnel ? "Vérifier la connexion Internet des deux sites et la phase 1 du tunnel."
                                          : "Vérifier le modem et le fournisseur d’accès\u{00A0}; le trafic passe par le lien de secours s’il existe.",
                    site: link.site, target: .wan(site: link.site)))
                continue
            }
            var problems: [String] = []
            if let latency = link.latencyMs, latency > thresholds.latencyMs { problems.append("latence \(ToolFormat.milliseconds(latency))") }
            if let loss = link.lossPercent, loss > thresholds.lossPercent { problems.append("perte \(ResourceFormat.percent(loss))") }
            if let jitter = link.jitterMs, jitter > thresholds.jitterMs { problems.append("gigue \(ToolFormat.milliseconds(jitter))") }
            guard !problems.isEmpty else { continue }
            result.append(NetworkFinding(
                id: "wan|\(link.site)|\(link.name)", severity: .warning, area: .health,
                title: "\(kind) \(link.name) dégradé" + at(link.site),
                explanation: "Qualité mesurée par la FortiGate\u{00A0}: " + problems.joined(separator: ", ") + ". La voix et la vidéo en souffrent les premières.",
                action: "Comparer avec un Speedtest et signaler au fournisseur d’accès si cela dure.",
                site: link.site, target: .wan(site: link.site)))
        }
        return result
    }

    static func portFindings(_ ports: [NetworkPortIssue]) -> [NetworkFinding] {
        let multi = Set(ports.map(\.site)).count > 1
        return ports.map { issue in
            let at = multi ? " (\(issue.site))" : ""
            switch issue.kind {
            case .errors(let count):
                return NetworkFinding(
                    id: "port|\(issue.host)|\(issue.port)", severity: count >= portErrorThreshold * 10 ? .warning : .advice, area: .health,
                    title: "Port \(issue.switchName) · \(issue.port) en erreur" + at,
                    explanation: "\(ToolFormat.integer(count)) erreurs en réception depuis le démarrage du switch\u{00A0}: câble abîmé, prise murale ou négociation de vitesse.",
                    action: "Tester le câble et la prise, puis forcer la vitesse et le duplex des deux côtés si les erreurs continuent.",
                    site: issue.site, target: .switchPort(host: issue.host, port: issue.port))
            case .saturated(let percent):
                return NetworkFinding(
                    id: "port|\(issue.host)|\(issue.port)", severity: percent >= 95 ? .critical : .warning, area: .health,
                    title: "Port \(issue.switchName) · \(issue.port) saturé" + at,
                    explanation: "Le port est chargé à \(ResourceFormat.percent(percent)) de sa vitesse.",
                    action: "Voir l’appareil branché sur ce port\u{00A0}; passer le lien à une vitesse supérieure ou agréger deux ports.",
                    site: issue.site, target: .switchPort(host: issue.host, port: issue.port))
            }
        }
    }

    static func wifiFindings(_ wifi: FortiWifiDiagnosis) -> [NetworkFinding] {
        wifi.advice.compactMap { advice in
            let severity: NetworkFindingSeverity
            switch advice.severity {
            case .critique: severity = .critical
            case .alerte: severity = .warning
            case .conseil: severity = .advice
            case .info: return nil
            }
            guard advice.kind != .healthy, advice.kind != .note else { return nil }
            let target: NetworkFindingTarget = advice.apName.map { .accessPoint(name: $0, site: advice.site ?? "") } ?? .none
            return NetworkFinding(id: "wifi|\(advice.id)", severity: severity, area: .health, title: "Wi-Fi\u{00A0}: " + advice.title,
                                  explanation: advice.detail, action: wifiAction(advice.kind), site: advice.site, target: target)
        }
    }

    static func wifiAction(_ kind: FortiWifiAdvice.Kind) -> String {
        switch kind {
        case .offline: return "Vérifier l’alimentation PoE et le port de switch de la borne."
        case .rogue: return "Localiser l’AP non autorisé et le retirer, ou le déclarer comme voisin connu."
        case .overlap: return "Changer le canal d’une des deux bornes (ou laisser la FortiGate choisir, DARRP)."
        case .weakSignal: return "Rapprocher le client d’une borne ou ajouter une borne dans cette zone."
        case .overload: return "Répartir les clients sur une autre borne ou activer l’équilibrage de charge."
        case .openSSID: return "Protéger le SSID par WPA2 ou WPA3."
        case .width24: return "Passer la radio 2,4 GHz à 20 MHz."
        case .note, .healthy: return "Ouvrir Wi-Fi › FortiAP."
        }
    }

    static func dhcpFindings(_ dhcp: DHCPScopeOverview, thresholds: DHCPScopeThresholds) -> [NetworkFinding] {
        let scopes = DHCPScopeAnalysis.relevel(dhcp.scopes, thresholds: thresholds).filter { $0.level >= .warning }
        return scopes.compactMap { scope in
            guard let text = DHCPScopeAnalysis.alertText(scope) else { return nil }
            return NetworkFinding(id: "dhcp|\(scope.id)", severity: scope.level == .critical ? .critical : .warning, area: .health,
                                  title: text + (dhcp.isMultiSite ? " (\(scope.site))" : ""),
                                  explanation: "Occupation \(scope.percentLabel) (\(scope.usedLabel))" + (dhcp.isEstimate ? ", estimation par le Test DHCP." : "."),
                                  action: DHCPScopeAnalysis.advice(scope), site: scope.site, target: .dhcpScope(id: scope.id))
        }
    }

    // MARK: Règles de l'inventaire

    static func inventoryFindings(_ unknown: [NetworkUnknownDevice], now: Date) -> [NetworkFinding] {
        guard !unknown.isEmpty else { return [] }
        var result: [NetworkFinding] = []
        for site in Array(Set(unknown.map(\.site))).sorted() {
            let list = unknown.filter { $0.site == site }.sorted { $0.firstSeen > $1.firstSeen }
            let recent = list.filter { now.timeIntervalSince($0.firstSeen) < recentUnknown }
            let names = list.prefix(4).map { "\($0.name) (\($0.ip))" }.joined(separator: ", ")
            result.append(NetworkFinding(
                id: "inconnus|\(site)", severity: recent.isEmpty ? .advice : .warning, area: .inventory,
                title: "\(list.count) appareil\(list.count > 1 ? "s" : "") inconnu\(list.count > 1 ? "s" : "")" + (recent.isEmpty ? "" : ", dont \(recent.count) nouveau\(recent.count > 1 ? "x" : "")") + (unknown.count == list.count ? "" : " (\(site))"),
                explanation: "Ni nom saisi ni fabricant reconnu (MAC aléatoire ou inconnue)\u{00A0}: " + names + (list.count > 4 ? "…" : "."),
                action: "Identifier chaque appareil dans l’Inventaire (nom, type, propriétaire) ou le bloquer s’il n’a rien à faire sur le réseau.",
                site: site, target: list.count == 1 ? .device(ip: list[0].ip, mac: list[0].mac, site: site) : .inventory(site: site)))
        }
        return result
    }

    /// Ports en erreur relevés sur les switchs (SNMP ou FortiSwitch convertis).
    public static func portIssues(_ snapshots: [SNMPSwitchSnapshot], site: String, threshold: UInt64 = portErrorThreshold) -> [NetworkPortIssue] {
        snapshots.flatMap { snapshot in
            snapshot.interfaces.compactMap { iface -> NetworkPortIssue? in
                guard let errors = iface.inErrors, errors >= threshold, iface.isPhysical else { return nil }
                return NetworkPortIssue(site: snapshot.controllerName ?? site, switchName: snapshot.displayName, host: snapshot.id,
                                        port: iface.name, kind: .errors(errors))
            }
        }
    }
}
