import Foundation

/// Format d'export par défaut (Réglages › Export et sauvegarde).
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case csv, json, pdf

    public var label: String { rawValue.uppercased() }

    public var detail: String {
        switch self {
        case .csv: return "CSV séparé par des points-virgules, UTF-8 avec BOM (Excel)."
        case .json: return "JSON structuré : appareils, ports, emplacement (switch, port, VLAN)."
        case .pdf: return "Rapport PDF mis en page (écran Rapports)."
        }
    }
}

/// Export JSON des résultats d'un scan : un objet par appareil, clés lisibles, dates ISO 8601.
public enum ScanJSON {
    public struct Row: Codable, Equatable, Sendable {
        public var statut: String
        public var ip: String
        public var nomPersonnalise: String?
        public var hostname: String?
        public var fabricant: String?
        public var mac: String?
        public var latenceMs: Double?
        public var portsOuverts: [UInt16]
        public var switchNom: String?
        public var switchPort: String?
        public var vlan: Int?
        public var type: String
        public var plage: String?
        public var premiereVue: Date
        public var derniereVue: Date
    }

    public struct Document: Codable, Equatable, Sendable {
        public var format = "netscope-scan"
        public var version = 1
        public var exporteLe: Date
        public var appareils: [Row]
    }

    public static func rows(_ devices: [Device]) -> [Row] {
        devices.map { device in
            Row(statut: device.isOnline ? "en ligne" : "hors ligne", ip: device.ip.description, nomPersonnalise: device.customName,
                hostname: device.hostname, fabricant: device.vendor, mac: device.mac?.formatted(.upperColon),
                latenceMs: device.latencyMs.map { ($0 * 10).rounded() / 10 }, portsOuverts: device.openPorts,
                switchNom: device.switchName, switchPort: device.switchPort, vlan: device.vlan, type: device.deviceType.label,
                plage: device.rangeLabel, premiereVue: device.firstSeen, derniereVue: device.lastSeen)
        }
    }

    public static func data(_ devices: [Device], date: Date = Date()) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(Document(exporteLe: date, appareils: rows(devices)))) ?? Data()
    }
}
