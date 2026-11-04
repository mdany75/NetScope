import Foundation

// Note 39 : analyse du WAN lu sur les FortiGate. Choix des interfaces WAN, débit calculé entre
// deux lectures, état de chaque lien (tombé, dégradé selon les seuils et les SLA), état des
// tunnels, vue de tous les sites, textes d'alerte et conseils. Fonctions pures, sans réseau.

/// État d'un lien WAN.
public enum WANLinkState: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Désactivé par l'administrateur : ni panne ni alerte.
    case disabled
    case up
    case unknown
    case degraded
    case down

    public static func < (a: WANLinkState, b: WANLinkState) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .disabled: return "Désactivé"
        case .up: return "Actif"
        case .unknown: return "Inconnu"
        case .degraded: return "Dégradé"
        case .down: return "Tombé"
        }
    }
}

/// Lien WAN d'un site, évalué.
public struct WANLinkUsage: Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var interface: WANInterfaceStatus
    /// Mesures des sondes SD-WAN de ce membre.
    public var measures: [WANHealthMeasure]
    public var state: WANLinkState
    /// Raisons de l'état (« perte 4 % (seuil 2 %) vers Google_DNS »).
    public var reasons: [String]
    /// Pires valeurs mesurées par les sondes qui répondent.
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?
    /// SLA : respectés / configurés (nil : aucun SLA connu).
    public var slaMet: Int?
    public var slaTotal: Int?

    public var id: String { "\(controllerID.uuidString)|\(interface.name)" }

    /// « 1/2 », « — ».
    public var slaLabel: String {
        guard let total = slaTotal, total > 0 else { return "—" }
        return "\(slaMet ?? 0)/\(total)"
    }
}

/// Tunnel IPsec d'un site.
public struct WANTunnelUsage: Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var tunnel: WANTunnel
    public var state: WANTunnelState { tunnel.state }
    public var id: String { "\(controllerID.uuidString)|\(tunnel.name)" }
}

/// Mesure d'une sonde SD-WAN d'un site, évaluée (tableau des membres SD-WAN et SLA).
public struct WANMemberUsage: Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var measure: WANHealthMeasure
    public var interfaceLabel: String
    /// Objectifs SLA de la sonde et ceux qui ne sont pas respectés.
    public var sla: [WANSLATarget]
    public var missedSLA: [WANSLATarget]
    public var servers: [String]
    public var state: WANLinkState
    public var id: String { "\(controllerID.uuidString)|\(measure.id)" }
}

/// Bilan d'un site.
public struct WANSiteSummary: Hashable, Sendable, Identifiable {
    public var controllerID: UUID
    public var site: String
    public var hostname: String
    public var version: String
    public var linksUp: Int
    public var linksTotal: Int
    public var tunnelsUp: Int
    public var tunnelsTotal: Int
    public var sslUsers: Int?
    /// Pire état des liens.
    public var worstLink: WANLinkState?
    public var worstTunnel: WANTunnelState?
    public var readAt: Date
    public var id: UUID { controllerID }

    /// Gravité du site : tombé (lien ou tunnel), dégradé, sinon bon.
    public var level: WANLevel {
        if worstLink == .down || worstTunnel == .down { return .critical }
        if worstLink == .degraded || worstTunnel == .partial { return .warning }
        if worstLink == .unknown || (linksTotal == 0 && tunnelsTotal == 0) { return .unknown }
        return .ok
    }
}

/// Gravité globale.
public enum WANLevel: Int, Codable, Sendable, Comparable {
    case ok, unknown, warning, critical
    public static func < (a: WANLevel, b: WANLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .ok: return "Bon"
        case .unknown: return "Inconnu"
        case .warning: return "Dégradé"
        case .critical: return "Panne"
        }
    }
}

/// Vue du WAN des sites lus.
public struct WANOverview: Hashable, Sendable {
    public var sites: [WANSiteSummary]
    public var links: [WANLinkUsage]
    public var members: [WANMemberUsage]
    public var tunnels: [WANTunnelUsage]
    public var sslUsers: [WANSSLUser]
    /// Remarques des lectures, préfixées du site si plusieurs.
    public var notes: [String]
    public var readAt: Date?
    /// Sondes SD-WAN configurées de chaque FortiGate (seuils propres d'une sonde de Surveillance).
    public var healthConfigs: [UUID: [WANHealthCheckConfig]] = [:]

    public init(sites: [WANSiteSummary] = [], links: [WANLinkUsage] = [], members: [WANMemberUsage] = [],
                tunnels: [WANTunnelUsage] = [], sslUsers: [WANSSLUser] = [], notes: [String] = [], readAt: Date? = nil) {
        self.sites = sites
        self.links = links
        self.members = members
        self.tunnels = tunnels
        self.sslUsers = sslUsers
        self.notes = notes
        self.readAt = readAt
    }

    public var isMultiSite: Bool { Set(sites.map(\.site)).count > 1 }
    public var isEmpty: Bool { sites.isEmpty }

    /// Liens tombés ou dégradés, les pires d'abord.
    public var alertingLinks: [WANLinkUsage] {
        links.filter { $0.state >= .degraded }.sorted { ($0.state, $0.lossPercent ?? 0) > ($1.state, $1.lossPercent ?? 0) }
    }

    /// Tunnels tombés ou partiels, les tombés d'abord.
    public var alertingTunnels: [WANTunnelUsage] {
        tunnels.filter { $0.state >= .partial }.sorted { ($0.state, $0.tunnel.name) > ($1.state, $1.tunnel.name) }
    }

    public var level: WANLevel { sites.map(\.level).max() ?? .unknown }
}

public enum WANAnalysis {
    // MARK: Interfaces WAN

    /// Interfaces WAN : rôle « wan » (configuration), membres SD-WAN (état, configuration ou
    /// sondes), sinon, sans configuration lisible, les noms « wanN ». Les tunnels (superpositions
    /// SD-WAN) restent dans le tableau des sondes et des tunnels. L'état est fusionné par nom.
    public static func wanInterfaces(config: [String: WANInterfaceStatus]?, states: [String: WANInterfaceStatus],
                                     members: [WANInterfaceStatus], configMembers: [WANInterfaceStatus],
                                     health: [WANHealthMeasure]) -> [WANInterfaceStatus] {
        var memberNames = Set(members.map { $0.name.lowercased() })
        memberNames.formUnion(configMembers.map { $0.name.lowercased() })
        memberNames.formUnion(health.filter(\.participates).map { $0.interface.lowercased() })
        var names: [String] = []
        func add(_ name: String) { if !names.contains(where: { $0.lowercased() == name.lowercased() }) { names.append(name) } }
        if let config {
            for (name, item) in config where item.role == "wan" && item.type != "tunnel" && item.type != "loopback" { add(name) }
            for (name, item) in config where memberNames.contains(name.lowercased()) && item.type != "tunnel" { add(name) }
        } else {
            for name in states.keys where isWANName(name) { add(name) }
        }
        // Membres SD-WAN absents de la configuration lue : gardés s'ils ne sont pas des tunnels connus.
        for name in members.map(\.name) + configMembers.map(\.name) + health.filter(\.participates).map(\.interface) {
            let known = config?.first { $0.key.lowercased() == name.lowercased() }?.value
            if known == nil || known?.type != "tunnel" { add(name) }
        }
        let byLower = { (map: [String: WANInterfaceStatus], name: String) in map.first { $0.key.lowercased() == name.lowercased() }?.value }
        var result: [WANInterfaceStatus] = []
        for name in names {
            var item = byLower(config ?? [:], name) ?? WANInterfaceStatus(name: name)
            item.name = name
            if let s = byLower(states, name) {
                item.alias = item.alias ?? s.alias
                item.linkUp = s.linkUp
                item.speedMbps = s.speedMbps
                // L'adresse obtenue par DHCP ou PPPoE est dans l'état, pas dans la configuration.
                if s.ip != nil { item.ip = s.ip; item.prefix = s.prefix }
                item.rxBytes = s.rxBytes
                item.txBytes = s.txBytes
                item.rxErrors = s.rxErrors
                item.txErrors = s.txErrors
            }
            if let c = configMembers.first(where: { $0.name.lowercased() == name.lowercased() }) {
                item.isSDWANMember = true
                item.gateway = item.gateway ?? c.gateway
                item.sdwanZone = item.sdwanZone ?? c.sdwanZone
            }
            if let m = members.first(where: { $0.name.lowercased() == name.lowercased() }) {
                item.isSDWANMember = true
                item.rxBps = m.rxBps ?? item.rxBps
                item.txBps = m.txBps ?? item.txBps
                item.gateway = m.gateway ?? item.gateway
                item.sdwanZone = m.sdwanZone ?? item.sdwanZone
                item.sessions = m.sessions ?? item.sessions
                item.stateChanged = m.stateChanged ?? item.stateChanged
                if item.linkUp == nil { item.linkUp = m.linkUp }
            }
            let measured = health.filter { $0.interface.lowercased() == name.lowercased() && $0.participates }
            if !measured.isEmpty {
                item.isSDWANMember = true
                if item.rxBps == nil { item.rxBps = measured.compactMap(\.rxBps).max() }
                if item.txBps == nil { item.txBps = measured.compactMap(\.txBps).max() }
                if item.sessions == nil { item.sessions = measured.compactMap(\.sessions).max() }
            }
            result.append(item)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// « wan », « wan1 », « wan2 », « internet1 », « isp2 » (sans la configuration des rôles).
    static func isWANName(_ name: String) -> Bool {
        name.range(of: #"^(wan|internet|isp)\d*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Débit

    /// Débit calculé entre deux lectures (compteurs d'octets) pour les liens sans débit SD-WAN.
    /// Un compteur remis à zéro (redémarrage) ou un intervalle trop court ne donne rien.
    public static func withRates(_ report: WANReadReport, previous: WANReadReport?) -> WANReadReport {
        guard let previous else { return report }
        let seconds = report.readAt.timeIntervalSince(previous.readAt)
        guard seconds >= 2, seconds <= 3600 else { return report }
        var next = report
        for index in next.interfaces.indices {
            let item = next.interfaces[index]
            guard let old = previous.interface(named: item.name) else { continue }
            if item.rxBps == nil, let a = old.rxBytes, let b = item.rxBytes, b >= a { next.interfaces[index].rxBps = Double(b - a) * 8 / seconds }
            if item.txBps == nil, let a = old.txBytes, let b = item.txBytes, b >= a { next.interfaces[index].txBps = Double(b - a) * 8 / seconds }
        }
        return next
    }

    // MARK: État d'un lien

    public static func evaluate(_ item: WANInterfaceStatus, health: [WANHealthMeasure], config: [WANHealthCheckConfig],
                                thresholds: WANThresholds) -> (state: WANLinkState, reasons: [String], slaMet: Int?, slaTotal: Int?) {
        let measures = health.filter { $0.interface.lowercased() == item.name.lowercased() && $0.participates }
        var slaMet: Int?
        var slaTotal: Int?
        for m in measures {
            guard let check = config.first(where: { $0.name == m.checkName }), !check.sla.isEmpty, m.isUp == true, let met = m.slaTargetsMet else { continue }
            slaTotal = (slaTotal ?? 0) + check.sla.count
            slaMet = (slaMet ?? 0) + check.sla.filter { met.contains($0.id) }.count
        }
        if item.adminUp == false { return (.disabled, ["désactivé sur la FortiGate"], slaMet, slaTotal) }
        if item.linkUp == false { return (.down, ["lien physique tombé (câble, modem ou fournisseur)"], slaMet, slaTotal) }
        if !measures.isEmpty, measures.allSatisfy({ $0.isUp == false }) {
            let names = measures.map(\.checkName).joined(separator: ", ")
            return (.down, ["aucune réponse des sondes SD-WAN (\(names))"], slaMet, slaTotal)
        }
        var reasons: [String] = []
        for m in measures where m.isUp == false { reasons.append("sonde \(m.checkName) sans réponse") }
        let up = measures.filter { $0.isUp == true }
        if let worst = up.filter({ ($0.lossPercent ?? 0) > thresholds.lossPercent }).max(by: { ($0.lossPercent ?? 0) < ($1.lossPercent ?? 0) }), let v = worst.lossPercent {
            reasons.append("perte \(MonFormat.percent(roundedPercent(v))) (seuil \(MonFormat.percent(thresholds.lossPercent))) vers \(worst.checkName)")
        }
        if let worst = up.filter({ ($0.latencyMs ?? 0) > thresholds.latencyMs }).max(by: { ($0.latencyMs ?? 0) < ($1.latencyMs ?? 0) }), let v = worst.latencyMs {
            reasons.append("latence \(ToolFormat.milliseconds(v)) (seuil \(MonFormat.number(thresholds.latencyMs))\u{00A0}ms) vers \(worst.checkName)")
        }
        if let worst = up.filter({ ($0.jitterMs ?? 0) > thresholds.jitterMs }).max(by: { ($0.jitterMs ?? 0) < ($1.jitterMs ?? 0) }), let v = worst.jitterMs {
            reasons.append("gigue \(ToolFormat.milliseconds(v)) (seuil \(MonFormat.number(thresholds.jitterMs))\u{00A0}ms) vers \(worst.checkName)")
        }
        for m in up {
            guard let check = config.first(where: { $0.name == m.checkName }), let met = m.slaTargetsMet else { continue }
            if check.sla.contains(where: { !met.contains($0.id) }) { reasons.append("SLA «\u{00A0}\(m.checkName)\u{00A0}» non respecté") }
        }
        if !reasons.isEmpty { return (.degraded, reasons, slaMet, slaTotal) }
        if item.linkUp == nil && measures.isEmpty { return (.unknown, ["état illisible dans la réponse de la FortiGate"], slaMet, slaTotal) }
        return (.up, [], slaMet, slaTotal)
    }

    /// Perte arrondie à une décimale (« 4 % », « 0,5 % »).
    static func roundedPercent(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    // MARK: Vue des sites

    public static func overview(_ sites: [WANSiteReport], thresholds: WANThresholds = .standard) -> WANOverview {
        var result = WANOverview()
        let multi = Set(sites.map(\.site)).count > 1
        for site in sites {
            let r = site.report
            var links: [WANLinkUsage] = []
            for item in r.interfaces {
                let e = evaluate(item, health: r.health, config: r.healthConfig, thresholds: thresholds)
                let up = r.health.filter { $0.interface.lowercased() == item.name.lowercased() && $0.isUp == true }
                links.append(WANLinkUsage(controllerID: site.controllerID, site: site.site, interface: item,
                                          measures: r.health.filter { $0.interface.lowercased() == item.name.lowercased() },
                                          state: e.state, reasons: e.reasons,
                                          latencyMs: up.compactMap(\.latencyMs).max(), jitterMs: up.compactMap(\.jitterMs).max(),
                                          lossPercent: up.compactMap(\.lossPercent).max(), slaMet: e.slaMet, slaTotal: e.slaTotal))
            }
            result.links += links
            for m in r.health {
                let check = r.healthConfig.first { $0.name == m.checkName }
                let sla = check?.sla ?? []
                let missed = (m.isUp == true) ? sla.filter { target in m.slaTargetsMet.map { !$0.contains(target.id) } ?? false } : []
                let label = r.interface(named: m.interface)?.displayName ?? m.interface
                var state: WANLinkState
                switch m.isUp {
                case false?: state = .down
                case nil: state = .disabled
                default:
                    let bad = (m.lossPercent ?? 0) > thresholds.lossPercent || (m.latencyMs ?? 0) > thresholds.latencyMs
                        || (m.jitterMs ?? 0) > thresholds.jitterMs || !missed.isEmpty
                    state = bad ? .degraded : .up
                }
                result.members.append(WANMemberUsage(controllerID: site.controllerID, site: site.site, measure: m, interfaceLabel: label,
                                                     sla: sla, missedSLA: missed, servers: check?.servers ?? [], state: state))
            }
            let tunnels = r.tunnels.map { WANTunnelUsage(controllerID: site.controllerID, site: site.site, tunnel: $0) }
            result.tunnels += tunnels
            result.sslUsers += r.sslUsers ?? []
            let counted = links.filter { $0.state != .disabled }
            let realTunnels = tunnels.filter { $0.state != .idle }
            result.sites.append(WANSiteSummary(controllerID: site.controllerID, site: site.site,
                                               hostname: r.system?.hostname ?? "", version: r.system?.version ?? "",
                                               linksUp: counted.filter { $0.state == .up || $0.state == .degraded }.count, linksTotal: counted.count,
                                               tunnelsUp: realTunnels.filter { $0.state == .up }.count, tunnelsTotal: realTunnels.count,
                                               sslUsers: r.sslUsers?.count,
                                               worstLink: counted.map(\.state).max(), worstTunnel: realTunnels.map(\.state).max(),
                                               readAt: r.readAt))
            result.healthConfigs[site.controllerID] = r.healthConfig
            result.notes += r.notes.map { multi ? "\(site.site)\u{00A0}: \($0)" : $0 }
            result.readAt = max(result.readAt ?? r.readAt, r.readAt)
        }
        return result
    }

    // MARK: Textes

    /// « Lien Vidéotron Câble (wan2) dégradé : perte 4 % (seuil 2 %) vers Google_DNS ».
    public static func alertText(_ link: WANLinkUsage) -> String? {
        switch link.state {
        case .down: return "Lien WAN \(link.interface.displayName) tombé" + (link.reasons.first.map { "\u{00A0}: \($0)" } ?? "")
        case .degraded: return "Lien WAN \(link.interface.displayName) dégradé\u{00A0}: " + link.reasons.joined(separator: ", ")
        default: return nil
        }
    }

    /// « Tunnel VPN-QUEBEC tombé (Vers Bureau Québec, 203.0.113.30) ».
    public static func alertText(_ tunnel: WANTunnelUsage) -> String? {
        let t = tunnel.tunnel
        var peer: [String] = []
        if let comments = t.comments?.trimmingCharacters(in: .whitespaces), !comments.isEmpty { peer.append(comments) }
        if let gw = t.remoteGateway { peer.append(gw) }
        let suffix = peer.isEmpty ? "" : " (\(peer.joined(separator: ", ")))"
        switch tunnel.state {
        case .down: return "Tunnel \(t.name) tombé" + suffix
        case .partial: return "Tunnel \(t.name) partiel\u{00A0}: \(t.phase2Up) phase\(t.phase2Up > 1 ? "s" : "") 2 sur \(t.phase2.count) montée\(t.phase2Up > 1 ? "s" : "")" + suffix
        default: return nil
        }
    }

    /// Conseil pour un lien tombé ou dégradé.
    public static func advice(_ link: WANLinkUsage) -> String {
        switch link.state {
        case .down:
            if link.interface.linkUp == false {
                return "Vérifier le câble et le modem du fournisseur, puis l’état du service chez lui. Si le SD-WAN a un autre lien, le trafic y passe déjà\u{00A0}: confirmer qu’il suffit en attendant."
            }
            return "Le lien est branché mais rien ne répond au-delà\u{00A0}: passerelle du fournisseur, adresse obtenue par DHCP ou PPPoE, ou panne chez le fournisseur. Tester la passerelle depuis la FortiGate (execute ping) et appeler le fournisseur."
        case .degraded:
            if (link.lossPercent ?? 0) > 0 {
                return "Une perte de paquets nuit à la voix et aux visioconférences\u{00A0}: vérifier les erreurs de l’interface, le câble et le modem, puis signaler la perte au fournisseur avec ces mesures. Les règles SD-WAN peuvent envoyer le trafic sensible sur l’autre lien."
            }
            return "Latence ou gigue élevées\u{00A0}: lien saturé (voir le débit) ou problème chez le fournisseur. Les règles SD-WAN peuvent envoyer le trafic sensible sur le meilleur lien."
        default:
            return ""
        }
    }

    /// Conseil pour un tunnel tombé ou partiel.
    public static func advice(_ tunnel: WANTunnelUsage) -> String {
        switch tunnel.state {
        case .down:
            return "Vérifier que le site distant a Internet (son lien WAN), puis la phase 1 sur les deux FortiGate (Moniteur IPsec, «\u{00A0}diagnose vpn ike gateway list\u{00A0}»)\u{00A0}: clé partagée, adresse distante ou propositions différentes après un changement d’un côté."
        case .partial:
            return "La phase 1 est montée mais une phase 2 manque\u{00A0}: les sous-réseaux des sélecteurs (phase 2) ne correspondent plus des deux côtés, ou une règle de pare-feu manque pour ce réseau."
        default:
            return ""
        }
    }
}

/// Mise en forme du WAN (typographie française, espaces insécables).
public enum WANFormat {
    /// « ↓ 312 Mb/s · ↑ 48 Mb/s », « — ».
    public static func throughput(rx: Double?, tx: Double?) -> String {
        guard rx != nil || tx != nil else { return "—" }
        return "↓\u{00A0}" + ResourceFormat.bitsPerSecond(rx) + " · ↑\u{00A0}" + ResourceFormat.bitsPerSecond(tx)
    }

    /// Octets en unités décimales : « 812 o », « 4,2 Mo », « 18,6 Go ».
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        let units = ["o", "ko", "Mo", "Go", "To", "Po"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let text = unit == 0 || amount >= 100 ? String(Int(amount.rounded())) : ToolFormat.decimal(amount)
        return text + "\u{00A0}" + units[unit]
    }

    /// « 1 Gb/s », « 100 Mb/s », « 2,5 Gb/s ».
    public static func speed(_ mbps: UInt64?) -> String {
        guard let mbps else { return "—" }
        if mbps >= 1000 {
            let g = Double(mbps) / 1000
            return (g == g.rounded() ? String(Int(g)) : ToolFormat.decimal(g)) + "\u{00A0}Gb/s"
        }
        return "\(mbps)\u{00A0}Mb/s"
    }

    /// « 3 j 4 h », « 5 h 12 min », « 42 min », « < 1 min ».
    public static func duration(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        // Date venue de la FortiGate : hors bornes (valeur sentinelle, bogue), elle ne doit jamais
        // faire déborder la conversion en entier.
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite, interval > -86_400, interval < 1e10 else { return "—" }
        guard interval >= 60 else { return "<\u{00A0}1\u{00A0}min" }
        let seconds = Int(interval)
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)\u{00A0}j" + (hours > 0 ? " \(hours)\u{00A0}h" : "") }
        if hours > 0 { return "\(hours)\u{00A0}h" + (minutes > 0 ? " \(minutes)\u{00A0}min" : "") }
        return "\(minutes)\u{00A0}min"
    }

    /// « 4 % », « 0,5 % », « — ».
    public static func loss(_ value: Double?) -> String {
        guard let value else { return "—" }
        return MonFormat.percent(WANAnalysis.roundedPercent(value))
    }

    /// « 6,8 ms », « 41 ms », « — ».
    public static func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ToolFormat.milliseconds(value)
    }
}
