import Foundation

// Note 68 : versions visibles et services en clair dans le rapport Sécurité, d'après l'empreinte
// légère (services lus par un scan de ports demandé). Aucune base de CVE : une version annoncée
// aide l'attaquant à cibler, c'est tout ce que le rapport en dit.

/// Constat d'empreinte d'un service.
public struct ReportFingerprintFinding: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case clearText, obsolete, version

        public var label: String {
            switch self {
            case .clearText: return "Service en clair"
            case .obsolete: return "Protocole obsolète"
            case .version: return "Version annoncée"
            }
        }
    }

    public var host: String
    public var ip: IPv4Address
    /// Premier port ; `ports` les donne tous quand le même constat vaut pour plusieurs (80 et 443).
    public var port: UInt16
    public var ports: [UInt16]
    public var kind: Kind
    /// « OpenSSH 8.9p1 », « Telnet », « SMB1 ».
    public var detail: String
    public var system: String?
    public var severity: ReportSeverity
}

extension ReportBuilder {
    /// Services en clair, protocoles obsolètes et versions annoncées, du plus grave au moins grave.
    public static func fingerprintFindings(_ devices: [Device]) -> [ReportFingerprintFinding] {
        var result: [ReportFingerprintFinding] = []
        let infrastructure: Set<DeviceType> = [.switch, .routeur, .pointAcces]
        for device in devices where device.fingerprint?.services.isEmpty == false {
            let report = device.fingerprintReport
            let host = device.hostnameLabel ?? device.displayName
            let system = report.system.map(\.label)
            for service in report.services {
                if let clear = service.clearText {
                    let kind: ReportFingerprintFinding.Kind = clear == "SMB1" ? .obsolete : .clearText
                    let severity: ReportSeverity
                    switch clear {
                    case "Telnet", "SMB1": severity = .eleve
                    case "HTTP": severity = infrastructure.contains(device.deviceType) ? .moyen : .faible
                    default: severity = .moyen
                    }
                    // « VNC (RFB) 3.889 » commence déjà par « VNC » : pas de « VNC (VNC (RFB) 3.889) ».
                    let detail: String
                    if let label = service.productLabel, label != clear {
                        detail = label.hasPrefix(clear + " ") ? label : "\(clear) (\(label))"
                    } else {
                        detail = clear
                    }
                    append(ReportFingerprintFinding(host: host, ip: device.ip, port: service.port, ports: [service.port],
                                                    kind: kind, detail: detail, system: system, severity: severity), to: &result)
                } else if service.exposesVersion, let label = service.productLabel {
                    append(ReportFingerprintFinding(host: host, ip: device.ip, port: service.port, ports: [service.port],
                                                    kind: .version, detail: label, system: system, severity: .faible), to: &result)
                }
            }
        }
        return result.sorted { ($0.severity, $0.ip, $0.port) < ($1.severity, $1.ip, $1.port) }
    }

    /// Même constat sur un autre port du même appareil (serveur web sur 80 et 443) : une seule ligne.
    private static func append(_ finding: ReportFingerprintFinding, to result: inout [ReportFingerprintFinding]) {
        if let index = result.firstIndex(where: { $0.ip == finding.ip && $0.kind == finding.kind && $0.detail == finding.detail }) {
            result[index].ports.append(finding.port)
        } else {
            result.append(finding)
        }
    }

    /// Blocs du rapport : tableau des constats, ou rien si aucun service n'a été lu.
    static func fingerprintBlocks(_ devices: [Device]) -> [ReportBlock] {
        let findings = fingerprintFindings(devices)
        guard !findings.isEmpty else { return [] }
        let rows = findings.map { item in
            ReportRow([ReportCell(item.host, bold: true), ReportCell(item.ip.description),
                       ReportCell(item.ports.map(String.init).joined(separator: ", ")),
                       ReportCell(item.kind.label), ReportCell(item.detail), ReportCell(item.system ?? "—", tone: .muted),
                       ReportCell(item.severity.label, badge: item.severity.tone)])
        }
        let table = ReportTable(columns: [ReportColumn("Hôte", weight: 1.4), ReportColumn("IP", weight: 1.05, mono: true),
                                          ReportColumn("Port", weight: 0.5, trailing: true, mono: true),
                                          ReportColumn("Constat", weight: 1.2), ReportColumn("Détail", weight: 1.6),
                                          ReportColumn("Système", weight: 1.4), ReportColumn("Risque", weight: 0.7)],
                                rows: rows, wraps: true)
        let clear = findings.filter { $0.kind != .version }.count
        let versions = findings.count - clear
        var summary: [String] = []
        if clear > 0 { summary.append(plural(clear, "service en clair ou obsolète", "services en clair ou obsolètes")) }
        if versions > 0 { summary.append(plural(versions, "version annoncée", "versions annoncées")) }
        return [.paragraph("Versions visibles et services en clair (scans de ports avec détection de services)\u{00A0}: "
                           + summary.joined(separator: ", ") + "."),
                .table(table),
                .note("Empreinte légère, sans base de vulnérabilités\u{00A0}: une version annoncée n’est pas une faille en soi, mais facilite le ciblage. Masquer la bannière ou mettre à jour le service.")]
    }
}
