import Foundation

// Adaptateurs : chaque émetteur (Surveillance, État des services, Test DHCP, Scanner) fabrique son
// AlertEvent d'une ligne. Quand le type d'événement commun de NetScope (NetScopeEvent) existera,
// un seul adaptateur NetScopeEvent → AlertEvent suffira à brancher les alertes sur lui.

extension AlertEvent {
    /// Alerte d'une sonde de la Surveillance (panne ou alerte).
    public static func probe(_ alert: MonAlert, probe: MonProbe) -> AlertEvent? {
        let kind: AlertEventKind
        let title: String
        switch alert.severity {
        case .critical:
            kind = .probeDown
            title = "\(probe.name) hors ligne"
        case .warning:
            kind = .probeWarning
            title = "\(probe.name) en alerte"
        case .info:
            // Information de la sonde « Nouveaux appareils » : nouvel appareil sur la plage.
            guard probe.kind == .newDevices else { return nil }
            kind = .newDevice
            title = "Nouvel appareil sur \(probe.target)"
        case .success:
            return nil
        }
        return AlertEvent(kind: kind, severity: kind == .newDevice ? .info : (alert.severity == .critical ? .critical : .warning),
                          title: title, message: alert.message, subject: probe.id.uuidString, occurredAt: alert.date,
                          details: probeDetails(probe), probeID: probe.id)
    }

    /// Retour à la normale d'une sonde.
    public static func probeRecovery(probe: MonProbe, value: String, at date: Date = Date()) -> AlertEvent {
        AlertEvent(kind: .probeRecovered, severity: .info, title: "\(probe.name) rétablie",
                   message: "Retour à la normale\u{00A0}: \(value).", subject: probe.id.uuidString, occurredAt: date,
                   details: probeDetails(probe), probeID: probe.id)
    }

    static func probeDetails(_ probe: MonProbe) -> [AlertDetail] {
        var details = [AlertDetail("Sonde", probe.kind.label), AlertDetail("Cible", probe.target)]
        if !probe.subtitle.isEmpty { details.append(AlertDetail("Appareil", probe.subtitle)) }
        return details
    }

    /// Nouvel incident d'un service en ligne.
    public static func serviceIncident(serviceID: String, serviceName: String, incident: SvcIncident, at date: Date = Date()) -> AlertEvent {
        let word = incident.impact == .outage ? "panne" : incident.impact == .maintenance ? "maintenance" : "incident"
        var details = [AlertDetail("Service", serviceName), AlertDetail("Statut", incident.status)]
        if !incident.affected.isEmpty { details.append(AlertDetail("Touché", incident.affected.joined(separator: ", "))) }
        if let url = incident.url, !url.isEmpty { details.append(AlertDetail("Page officielle", url)) }
        return AlertEvent(kind: .serviceIncident, severity: incident.impact == .outage ? .critical : (incident.impact == .maintenance ? .info : .warning),
                          title: "\(serviceName)\u{00A0}: \(word)", message: incident.title,
                          subject: "\(serviceID)|\(incident.id)", occurredAt: date, details: details)
    }

    /// Service en ligne injoignable depuis ce réseau (page d'état OK, mais rien ne répond d'ici).
    public static func serviceUnreachable(serviceID: String, serviceName: String, headline: String, at date: Date = Date()) -> AlertEvent {
        AlertEvent(kind: .serviceIncident, severity: .warning, title: "\(serviceName) injoignable d’ici", message: headline,
                   subject: "\(serviceID)|injoignable", occurredAt: date, details: [AlertDetail("Service", serviceName)])
    }

    /// Serveur DHCP non autorisé (une alerte par serveur).
    public static func rogueDHCP(_ offer: DHCPOffer, interface: String, at date: Date = Date()) -> AlertEvent {
        let server = offer.server?.description ?? "?"
        var details = [AlertDetail("Serveur", server), AlertDetail("Interface", interface),
                       AlertDetail("Adresse proposée", offer.offeredAddress.description)]
        if let mac = offer.sourceMAC { details.append(AlertDetail("MAC", mac.description)) }
        if let router = offer.routers.first { details.append(AlertDetail("Passerelle annoncée", router.description)) }
        return AlertEvent(kind: .rogueDHCP, severity: .critical, title: "Serveur DHCP non autorisé\u{00A0}: \(server)",
                          message: "Une offre DHCP vient d’un serveur hors de la liste autorisée\u{00A0}: des postes pourraient recevoir une mauvaise adresse ou passerelle.",
                          subject: server, occurredAt: date, details: details)
    }

    /// Fin d'un scan (résumé).
    public static func scanFinished(online: Int, new: Int, duration: String, ranges: String, at date: Date = Date()) -> AlertEvent {
        AlertEvent(kind: .scanFinished, severity: .info, title: "Scan terminé\u{00A0}: \(online) appareil\(online > 1 ? "s" : "") en ligne",
                   message: "Scan terminé en \(duration)\u{00A0}: \(online) en ligne, \(new) nouveau\(new > 1 ? "x" : "").",
                   subject: "scan|\(ranges)", occurredAt: date,
                   details: [AlertDetail("Plages", ranges), AlertDetail("Durée", duration)])
    }

    /// Nouveaux appareils trouvés par un scan (un seul événement pour le lot).
    public static func newDevices(_ devices: [Device], at date: Date = Date()) -> AlertEvent? {
        guard !devices.isEmpty else { return nil }
        let names = devices.prefix(8).map { device in
            "\(device.ip) · \(device.displayName)" + (device.mac.map { " · \($0)" } ?? "")
        }
        var details = names.enumerated().map { AlertDetail("Appareil \($0.offset + 1)", $0.element) }
        if devices.count > 8 { details.append(AlertDetail("Autres", "\(devices.count - 8)")) }
        let subject = devices.map { $0.mac?.description ?? $0.ip.description }.sorted().joined(separator: ",")
        return AlertEvent(kind: .newDevice, severity: .info,
                          title: devices.count == 1 ? "Nouvel appareil\u{00A0}: \(devices[0].displayName)" : "\(devices.count) nouveaux appareils",
                          message: devices.count == 1 ? "Un appareil jamais vu est apparu sur le réseau." : "Des appareils jamais vus sont apparus sur le réseau.",
                          subject: subject, occurredAt: date, details: details)
    }
}
