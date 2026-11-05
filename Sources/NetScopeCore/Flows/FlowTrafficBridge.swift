import Foundation

// Note 75 : les synthèses du collecteur de flux présentées comme le trafic de FortiView, pour que
// l'écran Trafic, « Qui sature le lien ? » et l'analyse s'en servent tels quels. Chaque
// exportateur tient lieu de « site » : ses lignes ne sont jamais fondues avec celles d'un autre
// (deux équipements qui voient le même trafic le compteraient deux fois).

/// Réglages d'un exportateur, choisis dans NetScope (rien n'est secret : pas de Trousseau).
public struct FlowExporterSettings: Codable, Hashable, Sendable {
    /// Nom affiché (« FortiGate du siège ») ; l'adresse sinon.
    public var name: String?
    /// Interface vers Internet choisie à la main (sinon devinée d'après les flux).
    public var wanInterface: UInt32?
    /// Débits du lien Internet (Mb/s), pour la charge et « Qui sature le lien ? ».
    public var downMbps: Double?
    public var upMbps: Double?

    public init(name: String? = nil, wanInterface: UInt32? = nil, downMbps: Double? = nil, upMbps: Double? = nil) {
        self.name = name
        self.wanInterface = wanInterface
        self.downMbps = downMbps
        self.upMbps = upMbps
    }

    /// « FortiGate du siège » ou « 10.0.0.1 ».
    public func label(for exporter: IPv4Address) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? exporter.description : trimmed
    }
}

public enum FlowTrafficBridge {
    /// Périodes proposées pour les flux (pas de 7 jours : rien n'est gardé au-delà de 24 h).
    public static let periods: [TrafficPeriod] = [.realtime, .fiveMinutes, .hour, .day]

    /// Fenêtre (secondes) d'une période : « temps réel » est la dernière minute.
    public static func window(_ period: TrafficPeriod) -> TimeInterval {
        period.seconds.map { min($0, 86_400) } ?? 60
    }

    /// Libellé du contrôle segmenté (« 1 min » pour le temps réel).
    public static func label(_ period: TrafficPeriod) -> String {
        period == .realtime ? "1\u{00A0}min" : period.label
    }

    /// « sur la dernière minute ».
    public static func span(_ period: TrafficPeriod) -> String {
        period == .realtime ? "sur la dernière minute" : period.span
    }

    /// Nom d'une interface d'exportateur.
    public static func interfaceName(_ index: UInt32) -> String { "Interface \(index)" }

    /// Trafic des exportateurs donnés, dans l'ordre donné.
    public static func overview(_ summaries: [FlowSummary], settings: [IPv4Address: FlowExporterSettings],
                                period: TrafficPeriod, now: Date) -> TrafficOverview {
        var overview = TrafficOverview(period: period)
        for summary in summaries where !summary.isEmpty {
            let config = settings[summary.exporter] ?? FlowExporterSettings()
            let site = config.label(for: summary.exporter)
            overview.sites.append(site)
            overview.readAt = max(overview.readAt ?? .distantPast, summary.lastSeen ?? now)
            let realtime = period.isRealtime
            func entry(_ view: TrafficView, _ host: FlowHostTotal) -> TrafficEntry {
                TrafficEntry(site: site, view: view, key: host.ip.description, name: host.ip.description, ip: host.ip,
                             sentBytes: host.volume.sent, receivedBytes: host.volume.received,
                             bandwidth: summary.rate(host.volume.bytes), sessions: host.volume.flows)
            }
            overview.entries += summary.hosts.map { entry(.sources, $0) }
            overview.entries += summary.remotes.map { entry(.destinations, $0) }
            overview.entries += summary.applications.map { app in
                TrafficEntry(site: site, view: .applications, key: app.application.name, name: app.application.name,
                             category: app.application.category, sentBytes: app.volume.sent, receivedBytes: app.volume.received,
                             bandwidth: summary.rate(app.volume.bytes), sessions: app.volume.flows, risk: app.application.risk)
            }
            for interface in summary.interfaces {
                let name = interfaceName(interface.index)
                let measured = interface.counterInBps != nil && realtime
                let rx = measured ? interface.counterInBps ?? 0 : summary.rate(interface.inBytes)
                let tx = measured ? interface.counterOutBps ?? 0 : summary.rate(interface.outBytes)
                let inBytes = interface.inBytes > 0 || interface.counterInBps == nil ? interface.inBytes : bytes(fromRate: interface.counterInBps ?? 0, span: summary.span)
                let outBytes = interface.outBytes > 0 || interface.counterOutBps == nil ? interface.outBytes : bytes(fromRate: interface.counterOutBps ?? 0, span: summary.span)
                // Sur une interface WAN, « reçu » est le téléchargement et « envoyé » l'envoi.
                overview.entries.append(TrafficEntry(site: site, view: .interfaces, key: name, name: name,
                                                     sentBytes: outBytes, receivedBytes: inBytes, bandwidth: rx + tx,
                                                     sessions: interface.flows))
                let isWAN = interface.index == (config.wanInterface ?? summary.wanInterface)
                let speedMbps = interface.speed.map { $0 / 1_000_000 }
                overview.links.append(TrafficLink(site: site, name: name, alias: isWAN ? "Internet" : nil, role: isWAN ? "wan" : "lan",
                                                  linkUp: interface.isUp, speedMbps: speedMbps.flatMap { $0 > 0 ? $0 : nil },
                                                  upstreamKbps: isWAN ? config.upMbps.map { saturated($0 * 1000) } : nil,
                                                  downstreamKbps: isWAN ? config.downMbps.map { saturated($0 * 1000) } : nil,
                                                  txBps: tx, rxBps: rx))
            }
            overview.sessions += summary.conversations.enumerated().map { index, conversation in
                TrafficSession(site: site, source: conversation.local, sourcePort: nil, destination: conversation.remote,
                               destinationPort: conversation.port == 0 ? nil : Int(conversation.port),
                               proto: FlowApplications.protocolName(conversation.proto), application: conversation.application.name,
                               sentBytes: conversation.volume.sent, receivedBytes: conversation.volume.received,
                               duration: conversation.durationMs.map { Int($0 / 1000) }, serial: "\(summary.exporter)-\(index)")
            }
            overview.notes += notes(summary, site: site, multi: summaries.count > 1, config: config)
        }
        return overview
    }

    /// Octets transportés à un débit (b/s) pendant une durée (s), sans jamais planter :
    /// une valeur infinie, négative ou plus grande que UInt64.max est ramenée dans les bornes.
    public static func bytes(fromRate bps: Double, span: TimeInterval) -> UInt64 {
        saturated(bps * span / 8)
    }

    /// Conversion saturée d'un Double en UInt64 (0 pour NaN, l'infini ou une valeur négative).
    public static func saturated(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    /// Remarques de lecture d'un exportateur (échantillonnage, IPv6, lignes hors tableaux, WAN).
    static func notes(_ summary: FlowSummary, site: String, multi: Bool, config: FlowExporterSettings) -> [String] {
        let prefix = multi ? site + "\u{00A0}: " : ""
        var notes: [String] = []
        if summary.maxSampling > 1 {
            notes.append(prefix + "flux échantillonnés (1 paquet sur \(summary.maxSampling))\u{00A0}: volumes et débits estimés.")
        }
        if summary.ipv6Flows > 0 {
            notes.append(prefix + "\(summary.ipv6Flows) flux IPv6 comptés dans le total, mais pas dans les tableaux (adresses IPv4 seulement).")
        }
        if summary.overflowBytes > 0, summary.total.bytes > 0 {
            let share = min(100, Double(summary.overflowBytes) / Double(max(1, summary.total.bytes)) * 100)
            if share >= 1 {
                notes.append(prefix + String(format: "%.0f", share) + "\u{00A0}% du volume réparti sur trop d’appareils ou de conversations pour être détaillé (mémoire bornée).")
            }
        }
        if config.wanInterface == nil, let wan = summary.wanInterface {
            notes.append(prefix + "lien Internet deviné\u{00A0}: \(interfaceName(wan)) (le plus emprunté par le trafic vers des adresses publiques).")
        }
        let wanKnown = config.downMbps != nil || config.upMbps != nil
            || summary.interfaces.contains { $0.isWAN && $0.speed != nil }
        if (config.wanInterface ?? summary.wanInterface) != nil, !wanKnown {
            notes.append(prefix + "débit du lien Internet inconnu\u{00A0}: saisissez-le dans le collecteur pour voir sa charge.")
        }
        return notes
    }
}
