import Foundation

// Note 91 : niveau du toner et des consommables des imprimantes par SNMP (Printer-MIB, RFC 3805,
// et HOST-RESOURCES-MIB). La lecture se fait seulement sur demande (bouton de la fiche, sonde de
// Surveillance) : jamais de balayage. L'analyse des réponses (`PrinterMIB.reading`) est pure et
// testée sur des réponses fixes ; la lecture passe par une requête fournie (client UDP, ou agent en
// mémoire des tests et de la démonstration).

public enum PrinterMIBOIDs {
    /// prtMarkerSuppliesEntry ; colonne, puis hrDeviceIndex et prtMarkerSuppliesIndex.
    public static let supplies: SNMPOID = "1.3.6.1.2.1.43.11.1.1"
    public static let supplyClass: UInt32 = 4
    public static let supplyType: UInt32 = 5
    public static let supplyDescription: UInt32 = 6
    public static let supplyMaxCapacity: UInt32 = 8
    public static let supplyLevel: UInt32 = 9
    /// prtMarkerLifeCount (compteur de pages, par moteur d'impression).
    public static let lifeCount: SNMPOID = "1.3.6.1.2.1.43.10.2.1.4"
    /// hrPrinterEntry : hrPrinterStatus (.1) et hrPrinterDetectedErrorState (.2).
    public static let hrPrinter: SNMPOID = "1.3.6.1.2.1.25.3.5.1"
    /// prtAlertDescription (alertes en cours, texte de l'imprimante).
    public static let alertDescription: SNMPOID = "1.3.6.1.2.1.43.18.1.1.8"

    /// Sous-arbres parcourus, dans l'ordre.
    public static let roots: [SNMPOID] = [supplies, lifeCount, hrPrinter, alertDescription]
}

/// Famille d'un consommable (prtMarkerSuppliesType, précisée par la description).
public enum PrinterSupplyKind: String, Codable, CaseIterable, Sendable {
    case toner, ink, drum, maintenance, waste, fuser, transfer, other

    public var label: String {
        switch self {
        case .toner: return "Toner"
        case .ink: return "Encre"
        case .drum: return "Tambour"
        case .maintenance: return "Kit de maintenance"
        case .waste: return "Bac de récupération"
        case .fuser: return "Unité de fusion"
        case .transfer: return "Courroie de transfert"
        case .other: return "Consommable"
        }
    }

    /// Type normalisé de prtMarkerSuppliesTypeTC, précisé par la description (kit de maintenance).
    public static func from(type: Int?, description: String) -> PrinterSupplyKind {
        let text = description.lowercased()
        if text.contains("maintenance") { return .maintenance }
        switch type ?? 0 {
        case 3, 21: return .toner
        case 5, 6, 7: return .ink
        case 9, 10: return .drum
        case 4, 8, 14, 24: return .waste
        case 11, 15, 17, 19, 22: return .fuser
        case 20: return .transfer
        case 18: return .maintenance
        default:
            if text.contains("toner") { return .toner }
            if text.contains("ink") || text.contains("encre") { return .ink }
            if text.contains("drum") || text.contains("tambour") || text.contains("opc") || text.contains("imaging") { return .drum }
            if text.contains("waste") || text.contains("récup") { return .waste }
            if text.contains("fuser") || text.contains("fusion") { return .fuser }
            return .other
        }
    }
}

/// Couleur d'un toner ou d'une encre, lue dans la description.
public enum PrinterColor: String, Codable, CaseIterable, Sendable {
    case black, cyan, magenta, yellow

    public var label: String {
        switch self {
        case .black: return "Noir"
        case .cyan: return "Cyan"
        case .magenta: return "Magenta"
        case .yellow: return "Jaune"
        }
    }

    public static func from(description: String) -> PrinterColor? {
        let text = description.lowercased()
        if text.contains("black") || text.contains("noir") || text.contains("schwarz") { return .black }
        if text.contains("cyan") { return .cyan }
        if text.contains("magenta") { return .magenta }
        if text.contains("yellow") || text.contains("jaune") { return .yellow }
        return nil
    }
}

/// Un consommable (ligne de prtMarkerSuppliesTable).
public struct PrinterSupply: Codable, Hashable, Sendable, Identifiable {
    /// « 1.3 » : hrDeviceIndex et prtMarkerSuppliesIndex.
    public var id: String
    public var description: String
    public var kind: PrinterSupplyKind
    public var color: PrinterColor?
    /// Niveau restant (ou place restante d'un bac de récupération) ; nil : inconnu.
    public var level: Int?
    public var maxCapacity: Int?
    /// L'imprimante dit seulement « il en reste » (niveau -3).
    public var someRemaining: Bool

    public init(id: String, description: String, kind: PrinterSupplyKind, color: PrinterColor? = nil,
                level: Int? = nil, maxCapacity: Int? = nil, someRemaining: Bool = false) {
        self.id = id
        self.description = description
        self.kind = kind
        self.color = color
        self.level = level
        self.maxCapacity = maxCapacity
        self.someRemaining = someRemaining
    }

    /// Pourcentage restant (0 à 100) ; nil si le niveau ou la capacité est inconnu.
    public var percent: Double? {
        guard let level, let maxCapacity, maxCapacity > 0, level >= 0 else { return nil }
        return min(100, max(0, Double(level) / Double(maxCapacity) * 100))
    }

    /// « Toner noir », « Tambour », « Bac de récupération ».
    public var displayName: String {
        guard let color, kind == .toner || kind == .ink else { return kind == .other ? description : kind.label }
        return "\(kind.label) \(color.label.lowercased())"
    }

    /// « 12 % », « il en reste », « inconnu ».
    public var levelLabel: String {
        if let percent { return "\(Int(percent.rounded()))\u{00A0}%" }
        return someRemaining ? "il en reste" : "inconnu"
    }

    /// Vrai si le niveau connu est au seuil ou en dessous.
    public func isLow(threshold: Double) -> Bool {
        guard let percent else { return false }
        return percent <= threshold
    }
}

/// État d'erreur détecté (hrPrinterDetectedErrorState, bits de la RFC 2790).
public enum PrinterErrorFlag: Int, Codable, CaseIterable, Sendable {
    case lowPaper = 0, noPaper, lowToner, noToner, doorOpen, jammed, offline, serviceRequested
    case inputTrayMissing, outputTrayMissing, markerSupplyMissing, outputNearFull, outputFull, inputTrayEmpty, overduePreventMaint

    public var label: String {
        switch self {
        case .lowPaper: return "Papier bas"
        case .noPaper: return "Plus de papier"
        case .lowToner: return "Toner bas"
        case .noToner: return "Plus de toner"
        case .doorOpen: return "Porte ouverte"
        case .jammed: return "Bourrage papier"
        case .offline: return "Hors ligne"
        case .serviceRequested: return "Intervention demandée"
        case .inputTrayMissing: return "Bac d’alimentation absent"
        case .outputTrayMissing: return "Bac de sortie absent"
        case .markerSupplyMissing: return "Consommable absent"
        case .outputNearFull: return "Bac de sortie presque plein"
        case .outputFull: return "Bac de sortie plein"
        case .inputTrayEmpty: return "Bac vide"
        case .overduePreventMaint: return "Entretien en retard"
        }
    }

    /// Bloque l'impression (panne de la sonde, rouge dans la fiche).
    public var isBlocking: Bool {
        switch self {
        case .noPaper, .noToner, .doorOpen, .jammed, .offline, .markerSupplyMissing, .outputFull, .inputTrayEmpty: return true
        default: return false
        }
    }

    /// Drapeaux d'une valeur hrPrinterDetectedErrorState (le bit de poids fort du premier octet = 0).
    public static func flags(_ bytes: [UInt8]) -> [PrinterErrorFlag] {
        var result: [PrinterErrorFlag] = []
        for (byteIndex, byte) in bytes.prefix(2).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                if let flag = PrinterErrorFlag(rawValue: byteIndex * 8 + bit) { result.append(flag) }
            }
        }
        return result
    }
}

/// État général (hrPrinterStatus).
public enum PrinterState: Int, Codable, Sendable {
    case other = 1, unknown, idle, printing, warmup

    public var label: String {
        switch self {
        case .other: return "Autre"
        case .unknown: return "Inconnu"
        case .idle: return "Prête"
        case .printing: return "Impression en cours"
        case .warmup: return "Préchauffage"
        }
    }
}

/// Relevé d'une imprimante.
public struct PrinterReading: Codable, Hashable, Sendable {
    public var supplies: [PrinterSupply]
    /// Compteur de pages (somme des moteurs) ; nil : non publié.
    public var pageCount: Int?
    public var state: PrinterState?
    public var errors: [PrinterErrorFlag]
    /// Alertes en cours (texte de l'imprimante, doublons retirés).
    public var alerts: [String]
    public var readAt: Date

    public init(supplies: [PrinterSupply] = [], pageCount: Int? = nil, state: PrinterState? = nil,
                errors: [PrinterErrorFlag] = [], alerts: [String] = [], readAt: Date = Date()) {
        self.supplies = supplies
        self.pageCount = pageCount
        self.state = state
        self.errors = errors
        self.alerts = alerts
        self.readAt = readAt
    }

    /// Consommable au niveau connu le plus bas.
    public var lowest: PrinterSupply? {
        supplies.filter { $0.percent != nil }.min { ($0.percent ?? 100) < ($1.percent ?? 100) }
    }

    /// Consommables au seuil ou en dessous, du plus bas au plus haut.
    public func lowSupplies(threshold: Double) -> [PrinterSupply] {
        supplies.filter { $0.isLow(threshold: threshold) }.sorted { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }

    public var blockingErrors: [PrinterErrorFlag] { errors.filter(\.isBlocking) }

    /// Résumé d'une ligne (« Toner noir 8 % · 48 213 pages · Bourrage papier »).
    public var summary: String {
        var parts: [String] = []
        if let lowest { parts.append("\(lowest.displayName) \(lowest.levelLabel)") }
        if let pageCount { parts.append("\(PrinterMIB.grouped(pageCount)) pages") }
        parts += errors.map(\.label)
        return parts.isEmpty ? "Aucun consommable publié" : parts.joined(separator: " · ")
    }
}

public enum PrinterMIB {
    /// Seuil d'alerte proposé (note 91).
    public static let defaultThreshold: Double = 15

    /// Relevé lu dans les varbinds des sous-arbres `PrinterMIBOIDs.roots`.
    public static func reading(_ binds: [SNMPVarBind], now: Date = Date()) -> PrinterReading {
        var rows: [String: (cls: Int?, type: Int?, descr: String?, max: Int?, level: Int?)] = [:]
        var order: [String] = []
        var pages: [Int] = []
        var state: PrinterState?
        var errors: [PrinterErrorFlag] = []
        var alerts: [String] = []
        for bind in binds where !bind.value.isException {
            if let suffix = bind.oid.suffix(after: PrinterMIBOIDs.supplies), suffix.count == 3 {
                let key = "\(suffix[1]).\(suffix[2])"
                if rows[key] == nil { order.append(key); rows[key] = (nil, nil, nil, nil, nil) }
                let number = bind.value.intValue.map { Int($0) }
                switch suffix[0] {
                case PrinterMIBOIDs.supplyClass: rows[key]?.cls = number
                case PrinterMIBOIDs.supplyType: rows[key]?.type = number
                case PrinterMIBOIDs.supplyDescription: rows[key]?.descr = bind.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                case PrinterMIBOIDs.supplyMaxCapacity: rows[key]?.max = number
                case PrinterMIBOIDs.supplyLevel: rows[key]?.level = number
                default: break
                }
            } else if bind.oid.hasPrefix(PrinterMIBOIDs.lifeCount), let count = bind.value.intValue, count >= 0 {
                pages.append(Int(count))
            } else if let suffix = bind.oid.suffix(after: PrinterMIBOIDs.hrPrinter), suffix.count >= 1 {
                if suffix[0] == 1, state == nil, let value = bind.value.intValue { state = PrinterState(rawValue: Int(value)) }
                if suffix[0] == 2, let bytes = bind.value.bytesValue {
                    for flag in PrinterErrorFlag.flags(bytes) where !errors.contains(flag) { errors.append(flag) }
                }
            } else if bind.oid.hasPrefix(PrinterMIBOIDs.alertDescription), let text = bind.value.stringValue {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !alerts.contains(trimmed) { alerts.append(trimmed) }
            }
        }
        let supplies = order.compactMap { key -> PrinterSupply? in
            guard let row = rows[key] else { return nil }
            let description = row.descr.flatMap { $0.isEmpty ? nil : $0 } ?? "Consommable \(key)"
            var kind = PrinterSupplyKind.from(type: row.type, description: description)
            // Classe 4 (receptacleThatIsFilled) : toujours un bac de récupération.
            if row.cls == 4 { kind = .waste }
            let maxCapacity = row.max.flatMap { $0 > 0 ? $0 : nil }
            let level = row.level.flatMap { $0 >= 0 ? $0 : nil }
            return PrinterSupply(id: key, description: description, kind: kind,
                                 color: (kind == .toner || kind == .ink || kind == .drum) ? PrinterColor.from(description: description) : nil,
                                 level: level, maxCapacity: maxCapacity, someRemaining: row.level == -3)
        }
        return PrinterReading(supplies: supplies, pageCount: pages.isEmpty ? nil : pages.reduce(0, +), state: state,
                              errors: errors, alerts: alerts, readAt: now)
    }

    /// Lit le relevé avec une requête fournie (client UDP, agent en mémoire). Lève une erreur si
    /// l'agent ne publie aucun consommable (pas une imprimante, ou Printer-MIB absente).
    public static func read(now: Date = Date(), fetch: (SNMPPDU) async throws -> SNMPPDU) async throws -> PrinterReading {
        var binds: [SNMPVarBind] = []
        for root in PrinterMIBOIDs.roots {
            let result = try await SNMPWalker.walk(root, mode: .bulk(maxRepetitions: 20), limit: 400, fetch: fetch)
            binds += result.binds
        }
        let reading = reading(binds, now: now)
        guard !reading.supplies.isEmpty else { throw PrinterMIBError.noSupplies }
        return reading
    }

    /// Lecture par un client SNMP (v2c, ou v3 avec le client v3 sous-jacent).
    public static func read(client: SNMPClient, now: Date = Date()) async throws -> PrinterReading {
        try await read(now: now) { pdu in try await client.request(pdu, checkStatus: false) }
    }

    /// « 48 213 » (espace insécable fine comme séparateur de milliers).
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, char) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append("\u{202F}") }
            out.append(char)
        }
        return value < 0 ? "-" + out : out
    }
}

public enum PrinterMIBError: Error, LocalizedError, Equatable {
    case noSupplies

    public var errorDescription: String? {
        switch self {
        case .noSupplies: return "Aucun consommable publié par SNMP (Printer-MIB absente\u{00A0}: SNMP désactivé sur l’imprimante, ou pas une imprimante)."
        }
    }
}
