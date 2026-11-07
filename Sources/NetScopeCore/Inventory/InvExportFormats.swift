import Foundation

// Note 78 (0.26.0) : export de l'inventaire vers d'autres outils, en CSV aux noms de colonnes de
// leurs imports : NetBox (import en masse des appareils), GLPI (extension « Data injection »,
// colonnes aux libellés français de GLPI) et Snipe-IT (importateur d'actifs). Le format NetScope
// reste celui de l'aller-retour (réimportable tel quel). Aucun réseau ici.

/// Format d'export de l'inventaire (menu « Exporter »).
public enum InvExportFormat: String, CaseIterable, Sendable, Identifiable {
    case netscope, netbox, glpi, snipeIT

    public var id: String { rawValue }

    /// Formats en ordre alphabétique, sans exception (règle de la 0.34.0).
    public static var ordered: [InvExportFormat] { allCases.sortedFrench(by: \.label) }

    public var label: String {
        switch self {
        case .netscope: return "CSV NetScope (réimportable)"
        case .netbox: return "CSV pour NetBox (appareils)"
        case .glpi: return "CSV pour GLPI (Data injection)"
        case .snipeIT: return "CSV pour Snipe-IT (actifs)"
        }
    }

    /// Précision du menu (ce que l'outil attend avant l'import).
    public var help: String {
        switch self {
        case .netscope: return "Toutes les colonnes de NetScope, séparateur «\u{00A0};\u{00A0}» comme Excel en français."
        case .netbox: return "Devices › Import. Les sites, rôles, fabricants et types d’appareils doivent déjà exister dans NetBox."
        case .glpi: return "Extension Data injection\u{00A0}: modèle «\u{00A0}Ordinateur\u{00A0}» ou «\u{00A0}Matériel réseau\u{00A0}», séparateur «\u{00A0};\u{00A0}», en-têtes sur la 1re ligne."
        case .snipeIT: return "Assets › Import. Les colonnes portent les noms reconnus d’office par l’importateur de Snipe-IT."
        }
    }

    /// Suffixe du nom de fichier (« inventaire-netbox-2026-11-05.csv »).
    public var fileSuffix: String {
        switch self {
        case .netscope: return ""
        case .netbox: return "-netbox"
        case .glpi: return "-glpi"
        case .snipeIT: return "-snipeit"
        }
    }

    public var separator: Character {
        switch self {
        case .netscope, .glpi: return ";"
        case .netbox, .snipeIT: return ","
        }
    }

    /// En-têtes, dans l'ordre (hors format NetScope, qui garde `InvCSV.columns`).
    public var columns: [String] {
        switch self {
        case .netscope:
            return InvCSV.columns
        case .netbox:
            return ["name", "status", "role", "manufacturer", "device_type", "site", "location", "serial", "asset_tag",
                    "description", "comments"]
        case .glpi:
            return ["Nom", "Statut", "Lieu", "Type", "Fabricant", "Modèle", "Numéro de série", "Numéro d'inventaire",
                    "Usager", "Adresse IP", "Adresse MAC", "Fournisseur", "Date d'achat", "Durée de garantie", "Commentaires"]
        case .snipeIT:
            return ["Item Name", "Asset Tag", "Category", "Manufacturer", "Model Name", "Serial Number", "Status", "Location",
                    "Purchase Date", "Purchase Cost", "Supplier", "Warranty", "MAC Address", "Notes"]
        }
    }
}

public enum InvExternalCSV {
    /// Export d'un ensemble de fiches. `sites` : nom du site de chaque fiche (même ordre) ; un seul
    /// nom (`defaultSite`) s'applique aux fiches sans site.
    public static func export(_ records: [InvRecord], format: InvExportFormat, sites: [String]? = nil, defaultSite: String = "",
                              now: Date = Date()) -> String {
        if format == .netscope { return InvCSV.export(records, sites: sites, now: now) }
        let separator = format.separator
        var lines = [format.columns.map { InvCSV.quote($0, separator) }.joined(separator: String(separator))]
        for (index, record) in records.enumerated() {
            let site = sites.flatMap { index < $0.count ? $0[index] : nil } ?? defaultSite
            let fields: [String]
            switch format {
            case .netscope: fields = []
            case .netbox: fields = netbox(record, site: site, now: now)
            case .glpi: fields = glpi(record, site: site, now: now)
            case .snipeIT: fields = snipeIT(record, site: site, now: now)
            }
            lines.append(fields.map { InvCSV.quote($0, separator) }.joined(separator: String(separator)))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Valeurs communes

    /// Fabricant connu (vide pour « Inconnu » ou une MAC aléatoire : l'outil cible le refuserait).
    static func manufacturer(_ record: InvRecord) -> String {
        let label = record.vendorLabel
        return label == OUIDatabase.unknownLabel || label == OUIDatabase.randomizedLabel ? "" : label
    }

    /// Numéro de série : saisi, sinon détecté.
    static func serial(_ record: InvRecord) -> String {
        record.enteredSerial.isEmpty ? (record.detectedHardware?.serialNumber ?? "") : record.enteredSerial
    }

    /// Emplacement : local saisi, sinon switch et port.
    static func location(_ record: InvRecord) -> String {
        let local = record.annotations.location.trimmingCharacters(in: .whitespaces)
        return local.isEmpty ? "" : local
    }

    /// « IP 10.0.0.5 · MAC AA:… · SW-CORE-01 · Gi1/0/22 · VLAN 10 · prise B-214 ».
    static func networkSummary(_ record: InvRecord) -> String {
        var parts: [String] = []
        if record.hasAddress { parts.append("IP \(record.ip)") }
        if let mac = record.mac { parts.append("MAC \(mac.formatted(.upperColon))") }
        if let place = record.switchLocation { parts.append(place) }
        if let vlan = record.vlan { parts.append("VLAN \(vlan)") }
        if !record.annotations.wallJack.isEmpty { parts.append("prise \(record.annotations.wallJack)") }
        if let host = record.hostname, !host.isEmpty, host != record.displayName { parts.append("hôte \(host)") }
        return parts.joined(separator: " · ")
    }

    static func comments(_ record: InvRecord) -> String {
        var parts = [networkSummary(record)]
        let notes = record.annotations.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append(notes) }
        if !record.annotations.tags.isEmpty { parts.append("Étiquettes\u{00A0}: " + record.annotations.tags.joined(separator: ", ")) }
        if !record.detectedFirmwareLabel.isEmpty { parts.append("Firmware \(record.detectedFirmwareLabel)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// Mois de garantie entre l'achat et la fin (vide si l'une manque).
    static func warrantyMonths(_ record: InvRecord) -> String {
        guard let hardware = record.annotations.hardware, let start = hardware.purchaseDate, let end = hardware.warrantyEnd,
              end > start else { return "" }
        // Calendrier UTC (pas de décalage d'heure d'été) ; un reste de 15 jours ou plus compte pour un mois.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.month, .day], from: start, to: end)
        let months = (parts.month ?? 0) + ((parts.day ?? 0) >= 15 ? 1 : 0)
        return months > 0 ? String(months) : ""
    }

    static func isoDay(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Prix avec un point décimal (format attendu par les imports, quelle que soit la langue).
    static func price(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "" }
        return String(format: "%.2f", value)
    }

    // MARK: Formats

    static func netbox(_ record: InvRecord, site: String, now: Date) -> [String] {
        let model = record.detectedModelLabel
        return [
            record.displayName,
            record.status(now: now) == .enLigne || record.status(now: now) == .conflit ? "active" : "offline",
            record.type.label,
            manufacturer(record),
            model.isEmpty ? record.type.label : model,
            site,
            location(record),
            serial(record),
            record.annotations.assetNumber,
            networkSummary(record),
            comments(record),
        ]
    }

    static func glpi(_ record: InvRecord, site: String, now: Date) -> [String] {
        let place = [site, location(record)].filter { !$0.isEmpty }.joined(separator: " > ")
        return [
            record.displayName,
            record.isGone(now: now) ? "Hors service" : "En service",
            place,
            record.type.label,
            manufacturer(record),
            record.detectedModelLabel,
            serial(record),
            record.annotations.assetNumber,
            record.annotations.owner,
            record.hasAddress ? record.ip.description : "",
            record.mac?.formatted(.upperColon) ?? "",
            record.annotations.hardware?.supplier ?? "",
            isoDay(record.annotations.hardware?.purchaseDate),
            warrantyMonths(record),
            comments(record),
        ]
    }

    static func snipeIT(_ record: InvRecord, site: String, now: Date) -> [String] {
        let model = record.detectedModelLabel
        return [
            record.displayName,
            assetTag(record),
            record.type.label,
            manufacturer(record),
            model.isEmpty ? record.type.label : model,
            serial(record),
            record.isGone(now: now) ? "Archived" : "Ready to Deploy",
            [site, location(record)].filter { !$0.isEmpty }.joined(separator: " · "),
            isoDay(record.annotations.hardware?.purchaseDate),
            price(record.annotations.hardware?.price),
            record.annotations.hardware?.supplier ?? "",
            warrantyMonths(record),
            record.mac?.formatted(.upperColon) ?? "",
            comments(record),
        ]
    }

    /// Étiquette d'actif obligatoire et unique dans Snipe-IT : n° d'actif, sinon n° de série,
    /// sinon « NS- » et la MAC (ou l'adresse IP) sans séparateurs.
    static func assetTag(_ record: InvRecord) -> String {
        let asset = record.annotations.assetNumber.trimmingCharacters(in: .whitespaces)
        if !asset.isEmpty { return asset }
        let serial = serial(record)
        if !serial.isEmpty { return serial }
        if let mac = record.mac { return "NS-" + mac.formatted(.upperColon).replacingOccurrences(of: ":", with: "") }
        return "NS-" + record.ip.description.replacingOccurrences(of: ".", with: "-")
    }
}
