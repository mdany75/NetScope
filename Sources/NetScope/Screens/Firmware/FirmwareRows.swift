import NetScopeCore
import SwiftUI

// Lignes des tableaux standard de l'outil « Firmware et licences » (note 41) : sites, équipements,
// licences.

enum FirmwareTone {
    static func tone(_ status: FirmwareStatus) -> Tone {
        switch status {
        case .upToDate: return .success
        case .updateAvailable: return .warning
        case .unknown: return .neutral
        }
    }

    static func tone(_ level: LicenseLevel) -> Tone {
        switch level {
        case .expired, .critical: return .critical
        case .warning: return .warning
        case .ok: return .success
        case .unknown, .notLicensed: return .neutral
        }
    }

    /// Couleur des jours restants : rouge à 30 jours, orange à 60 (seuils réglables).
    static func color(_ level: LicenseLevel) -> Color {
        switch level {
        case .expired, .critical: return Theme.critical
        case .warning: return Theme.warning
        case .notLicensed, .unknown: return Theme.textSecondary
        case .ok: return Theme.text
        }
    }

    /// Libellé court de l'état d'une licence (« Valide », « Expire bientôt », « Expirée »).
    static func chip(_ usage: FirmwareLicenseUsage) -> String {
        switch usage.level {
        case .critical, .warning: return "Expire bientôt"
        default: return usage.level.label
        }
    }
}

/// Ligne du tableau « Tous les sites » (tableau standard « firmware.sites »).
struct FirmwareSiteRow: Identifiable {
    let summary: FirmwareSiteSummary
    var id: UUID { summary.controllerID }

    var sortSite: String { SearchText.fold(summary.site) }
    var sortVersion: String { summary.version }
    var sortUpdates: Int { summary.updates }
    var sortDays: Int { summary.nearestDays ?? Int.max }
    var sortRead: Date { summary.readAt }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "site", title: "Site", isRequired: true),
        StandardColumn(id: "fortigate", title: "FortiGate"),
        StandardColumn(id: "equipements", title: "Équipements"),
        StandardColumn(id: "majs", title: "Mises à jour"),
        StandardColumn(id: "licence", title: "Prochaine expiration"),
        StandardColumn(id: "lecture", title: "Lecture"),
    ]

    static let sortKeys: [String: KeyPathComparator<FirmwareSiteRow>] = [
        "site": KeyPathComparator(\FirmwareSiteRow.sortSite),
        "fortigate": KeyPathComparator(\FirmwareSiteRow.sortVersion),
        "equipements": KeyPathComparator(\FirmwareSiteRow.sortUpdates),
        "majs": KeyPathComparator(\FirmwareSiteRow.sortUpdates, order: .reverse),
        "licence": KeyPathComparator(\FirmwareSiteRow.sortDays),
        "lecture": KeyPathComparator(\FirmwareSiteRow.sortRead),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<FirmwareSiteRow> {
        StandardTableModel(id: "firmware.sites", columns: columns, sortKeys: sortKeys, defaultSort: "site")
    }
}

/// Ligne du tableau des équipements (tableau standard « firmware.equipements »).
struct FirmwareDeviceRow: Identifiable {
    let device: FirmwareDevice
    let order: Int
    var id: String { device.id }

    var sortOrder: Int { order }
    var sortName: String { SearchText.fold(device.name) }
    var sortSite: String { SearchText.fold(device.site) }
    var sortKind: String { device.kind.rawValue }
    var sortModel: String { device.model }
    var sortSerial: String { device.serial }
    var sortVersion: FortiVersion { device.version ?? FortiVersion(major: 0, minor: 0) }
    var sortAvailable: FortiVersion { device.available ?? FortiVersion(major: 0, minor: 0) }
    var sortState: Int { device.status.rawValue }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Équipement", isRequired: true),
        StandardColumn(id: "site", title: "Site"),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "serie", title: "Numéro de série"),
        StandardColumn(id: "version", title: "Version"),
        StandardColumn(id: "disponible", title: "Version disponible"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "source", title: "Source", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<FirmwareDeviceRow>] = [
        "ordre": KeyPathComparator(\FirmwareDeviceRow.sortOrder),
        "nom": KeyPathComparator(\FirmwareDeviceRow.sortName),
        "site": KeyPathComparator(\FirmwareDeviceRow.sortSite),
        "type": KeyPathComparator(\FirmwareDeviceRow.sortKind),
        "modele": KeyPathComparator(\FirmwareDeviceRow.sortModel),
        "serie": KeyPathComparator(\FirmwareDeviceRow.sortSerial),
        "version": KeyPathComparator(\FirmwareDeviceRow.sortVersion),
        "disponible": KeyPathComparator(\FirmwareDeviceRow.sortAvailable),
        "etat": KeyPathComparator(\FirmwareDeviceRow.sortState, order: .reverse),
        "source": KeyPathComparator(\FirmwareDeviceRow.sortKind),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<FirmwareDeviceRow> {
        StandardTableModel(id: "firmware.equipements", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }
}

/// Ligne du tableau des licences (tableau standard « firmware.licences »).
struct FirmwareLicenseRow: Identifiable {
    let usage: FirmwareLicenseUsage
    let order: Int
    var id: String { usage.id }

    var sortOrder: Int { order }
    var sortService: String { SearchText.fold(usage.license.label) }
    var sortSite: String { SearchText.fold(usage.site) }
    var sortExpires: Date { usage.license.expires ?? .distantFuture }
    var sortDays: Int { usage.daysLeft ?? Int.max }
    var sortLevel: Int { usage.level.rawValue }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "service", title: "Service", isRequired: true),
        StandardColumn(id: "site", title: "Site"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "expiration", title: "Date d’expiration"),
        StandardColumn(id: "jours", title: "Jours restants"),
        StandardColumn(id: "brut", title: "État lu", isDefaultVisible: false),
        StandardColumn(id: "base", title: "Version de la base", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<FirmwareLicenseRow>] = [
        "ordre": KeyPathComparator(\FirmwareLicenseRow.sortOrder),
        "service": KeyPathComparator(\FirmwareLicenseRow.sortService),
        "site": KeyPathComparator(\FirmwareLicenseRow.sortSite),
        "etat": KeyPathComparator(\FirmwareLicenseRow.sortLevel, order: .reverse),
        "expiration": KeyPathComparator(\FirmwareLicenseRow.sortExpires),
        "jours": KeyPathComparator(\FirmwareLicenseRow.sortDays),
        "brut": KeyPathComparator(\FirmwareLicenseRow.sortService),
        "base": KeyPathComparator(\FirmwareLicenseRow.sortService),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<FirmwareLicenseRow> {
        StandardTableModel(id: "firmware.licences", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }
}
