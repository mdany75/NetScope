import NetScopeCore
import SwiftUI

// Lignes des tableaux standard de la vue « WAN et VPN » (note 39) : sites, liens WAN, sondes
// SD-WAN et SLA, tunnels IPsec.

enum WANTone {
    static func tone(_ state: WANLinkState) -> Tone {
        switch state {
        case .down: return .critical
        case .degraded: return .warning
        case .up: return .success
        case .unknown, .disabled: return .neutral
        }
    }

    static func tone(_ state: WANTunnelState) -> Tone {
        switch state {
        case .down: return .critical
        case .partial: return .warning
        case .up: return .success
        case .idle: return .neutral
        }
    }

    static func tone(_ level: WANLevel) -> Tone {
        switch level {
        case .critical: return .critical
        case .warning: return .warning
        case .ok: return .success
        case .unknown: return .neutral
        }
    }
}

/// Ligne du tableau « Tous les sites » (tableau standard « wan.sites »).
struct WANSiteRow: Identifiable {
    let summary: WANSiteSummary
    var id: UUID { summary.controllerID }

    var sortSite: String { SearchText.fold(summary.site) }
    var sortLinks: Int { summary.linksTotal - summary.linksUp }
    var sortTunnels: Int { summary.tunnelsTotal - summary.tunnelsUp }
    var sortLevel: Int { summary.level.rawValue }
    var sortRead: Date { summary.readAt }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "site", title: "Site", isRequired: true),
        StandardColumn(id: "fortigate", title: "FortiGate"),
        StandardColumn(id: "liens", title: "Liens WAN"),
        StandardColumn(id: "tunnels", title: "Tunnels IPsec"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "lecture", title: "Lecture"),
    ]

    static let sortKeys: [String: KeyPathComparator<WANSiteRow>] = [
        "site": KeyPathComparator(\WANSiteRow.sortSite),
        "fortigate": KeyPathComparator(\WANSiteRow.sortSite),
        "liens": KeyPathComparator(\WANSiteRow.sortLinks),
        "tunnels": KeyPathComparator(\WANSiteRow.sortTunnels),
        "etat": KeyPathComparator(\WANSiteRow.sortLevel, order: .reverse),
        "lecture": KeyPathComparator(\WANSiteRow.sortRead),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<WANSiteRow> {
        StandardTableModel(id: "wan.sites", columns: columns, sortKeys: sortKeys, defaultSort: "site")
    }
}

/// Ligne du tableau des liens WAN (tableau standard « wan.liens »).
struct WANLinkRow: Identifiable {
    let link: WANLinkUsage
    var id: String { link.id }

    var sortName: String { SearchText.fold(link.site + "|" + link.interface.name) }
    var sortAddress: UInt32 { link.interface.ip?.value ?? .max }
    var sortRate: Double { link.interface.rxBps ?? -1 }
    var sortLatency: Double { link.latencyMs ?? -1 }
    var sortJitter: Double { link.jitterMs ?? -1 }
    var sortLoss: Double { link.lossPercent ?? -1 }
    var sortSLA: Int { link.slaTotal.map { $0 - (link.slaMet ?? 0) } ?? -1 }
    var sortState: Int { link.state.rawValue }
    var sortSpeed: UInt64 { link.interface.speedMbps ?? 0 }
    var sortErrors: UInt64 { (link.interface.rxErrors ?? 0) + (link.interface.txErrors ?? 0) }
    var sortSessions: Int { link.interface.sessions ?? -1 }
    var sortGateway: UInt32 { link.interface.gateway?.value ?? .max }
    var sortSite: String { link.site }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "lien", title: "Lien WAN", isRequired: true),
        StandardColumn(id: "adresse", title: "Adresse IP"),
        StandardColumn(id: "debit", title: "Débit ↓ / ↑"),
        StandardColumn(id: "latence", title: "Latence"),
        StandardColumn(id: "gigue", title: "Gigue"),
        StandardColumn(id: "perte", title: "Perte"),
        StandardColumn(id: "sla", title: "SLA respectés"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "vitesse", title: "Vitesse du port", isDefaultVisible: false),
        StandardColumn(id: "erreurs", title: "Erreurs", isDefaultVisible: false),
        StandardColumn(id: "sessions", title: "Sessions", isDefaultVisible: false),
        StandardColumn(id: "passerelle", title: "Passerelle", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<WANLinkRow>] = [
        "lien": KeyPathComparator(\WANLinkRow.sortName),
        "adresse": KeyPathComparator(\WANLinkRow.sortAddress),
        "debit": KeyPathComparator(\WANLinkRow.sortRate),
        "latence": KeyPathComparator(\WANLinkRow.sortLatency),
        "gigue": KeyPathComparator(\WANLinkRow.sortJitter),
        "perte": KeyPathComparator(\WANLinkRow.sortLoss),
        "sla": KeyPathComparator(\WANLinkRow.sortSLA),
        "etat": KeyPathComparator(\WANLinkRow.sortState),
        "vitesse": KeyPathComparator(\WANLinkRow.sortSpeed),
        "erreurs": KeyPathComparator(\WANLinkRow.sortErrors),
        "sessions": KeyPathComparator(\WANLinkRow.sortSessions),
        "passerelle": KeyPathComparator(\WANLinkRow.sortGateway),
        "site": KeyPathComparator(\WANLinkRow.sortSite),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<WANLinkRow> {
        StandardTableModel(id: "wan.liens", columns: columns, sortKeys: sortKeys, defaultSort: "lien")
    }
}

/// Ligne du tableau des sondes SD-WAN (tableau standard « wan.sondes »).
struct WANMemberRow: Identifiable {
    let member: WANMemberUsage
    var id: String { member.id }

    var sortCheck: String { SearchText.fold(member.site + "|" + member.measure.checkName) }
    var sortMember: String { member.measure.interface }
    var sortLatency: Double { member.measure.latencyMs ?? -1 }
    var sortJitter: Double { member.measure.jitterMs ?? -1 }
    var sortLoss: Double { member.measure.lossPercent ?? -1 }
    var sortSLA: Int { member.missedSLA.count }
    var sortState: Int { member.state.rawValue }
    var sortChanged: Date { member.measure.stateChanged ?? .distantPast }
    var sortSite: String { member.site }

    /// « Respecté », « Non respecté », « — ».
    var slaText: String {
        guard !member.sla.isEmpty, member.measure.isUp == true, member.measure.slaTargetsMet != nil else { return "—" }
        return member.missedSLA.isEmpty ? "Respecté" : "Non respecté"
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "sonde", title: "Sonde SD-WAN", isRequired: true),
        StandardColumn(id: "membre", title: "Membre"),
        StandardColumn(id: "latence", title: "Latence"),
        StandardColumn(id: "gigue", title: "Gigue"),
        StandardColumn(id: "perte", title: "Perte"),
        StandardColumn(id: "sla", title: "SLA"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "depuis", title: "Changement d’état", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<WANMemberRow>] = [
        "sonde": KeyPathComparator(\WANMemberRow.sortCheck),
        "membre": KeyPathComparator(\WANMemberRow.sortMember),
        "latence": KeyPathComparator(\WANMemberRow.sortLatency),
        "gigue": KeyPathComparator(\WANMemberRow.sortJitter),
        "perte": KeyPathComparator(\WANMemberRow.sortLoss),
        "sla": KeyPathComparator(\WANMemberRow.sortSLA),
        "etat": KeyPathComparator(\WANMemberRow.sortState),
        "depuis": KeyPathComparator(\WANMemberRow.sortChanged),
        "site": KeyPathComparator(\WANMemberRow.sortSite),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<WANMemberRow> {
        StandardTableModel(id: "wan.sondes", columns: columns, sortKeys: sortKeys, defaultSort: "sonde")
    }
}

/// Ligne du tableau des tunnels IPsec (tableau standard « wan.tunnels »).
struct WANTunnelRow: Identifiable {
    let usage: WANTunnelUsage
    var id: String { usage.id }

    var sortName: String { SearchText.fold(usage.site + "|" + usage.tunnel.name) }
    var sortPeer: String { SearchText.fold(usage.tunnel.peerLabel) }
    var sortGateway: String { usage.tunnel.remoteGateway ?? "~" }
    var sortPhase2: Int { usage.tunnel.phase2Up }
    var sortIn: UInt64 { usage.tunnel.incomingBytes ?? 0 }
    var sortOut: UInt64 { usage.tunnel.outgoingBytes ?? 0 }
    var sortUp: Date { usage.state == .up ? (usage.tunnel.upSince ?? .distantFuture) : .distantFuture }
    var sortState: Int { usage.state.rawValue }
    var sortType: String { usage.tunnel.type ?? "" }
    var sortSite: String { usage.site }

    /// « 1/1 », « 0/2 », « — ».
    var phase2Text: String {
        usage.tunnel.phase2.isEmpty ? "—" : "\(usage.tunnel.phase2Up)/\(usage.tunnel.phase2.count)"
    }

    static func typeLabel(_ type: String?) -> String {
        switch type?.lowercased() {
        case "automatic"?: return "Site à site"
        case "manual"?: return "Manuel"
        case "dialup"?, "dynamic"?: return "Accès distant"
        case let other?: return other
        case nil: return "—"
        }
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "tunnel", title: "Tunnel", isRequired: true),
        StandardColumn(id: "vers", title: "Vers"),
        StandardColumn(id: "passerelle", title: "Passerelle distante"),
        StandardColumn(id: "phase2", title: "Phases 2"),
        StandardColumn(id: "entrant", title: "Entrant"),
        StandardColumn(id: "sortant", title: "Sortant"),
        StandardColumn(id: "depuis", title: "Monté depuis"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "type", title: "Type", isDefaultVisible: false),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<WANTunnelRow>] = [
        "tunnel": KeyPathComparator(\WANTunnelRow.sortName),
        "vers": KeyPathComparator(\WANTunnelRow.sortPeer),
        "passerelle": KeyPathComparator(\WANTunnelRow.sortGateway),
        "phase2": KeyPathComparator(\WANTunnelRow.sortPhase2),
        "entrant": KeyPathComparator(\WANTunnelRow.sortIn),
        "sortant": KeyPathComparator(\WANTunnelRow.sortOut),
        "depuis": KeyPathComparator(\WANTunnelRow.sortUp),
        "etat": KeyPathComparator(\WANTunnelRow.sortState),
        "type": KeyPathComparator(\WANTunnelRow.sortType),
        "site": KeyPathComparator(\WANTunnelRow.sortSite),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<WANTunnelRow> {
        StandardTableModel(id: "wan.tunnels", columns: columns, sortKeys: sortKeys, defaultSort: "tunnel")
    }
}
