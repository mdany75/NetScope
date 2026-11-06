import Foundation

// Ordre alphabétique des listes fixes que l'on parcourt pour choisir (demande de Dany,
// 5 novembre 2026 : « en ordre alphabétique… donc partout dans NetScope »). Les valeurs gardent
// leur ordre de déclaration (allCases), utile aux fichiers et aux captures ; seuls les menus et
// sélecteurs lisent `ordered`. « Inconnu », « Autre » et « Autres » restent à la fin.

public extension DeviceType {
    /// Types d'appareil des sélecteurs : alphabétique, « Inconnu » à la fin.
    static var ordered: [DeviceType] { allCases.sortedFrench(by: \.label, last: [DeviceType.inconnu.label]) }
}

public extension RemoteProtocol {
    static var ordered: [RemoteProtocol] { allCases.sortedFrench(by: \.label) }
}

public extension ControllerKind {
    static var ordered: [ControllerKind] { allCases.sortedFrench(by: \.label) }
}

public extension MonProbeKind {
    /// Sondes à ajouter.
    static var ordered: [MonProbeKind] { allCases.sortedFrench(by: \.label) }
}

public extension ConfigDeviceKind {
    static var ordered: [ConfigDeviceKind] { allCases.sortedFrench(by: \.label) }
}

public extension ReportTemplate {
    static var ordered: [ReportTemplate] { allCases.sortedFrench(by: \.label) }
}

public extension DiskShareKind {
    /// Types de partage : alphabétique, « Autre » (dossier) à la fin.
    static var ordered: [DiskShareKind] { allCases.sortedFrench(by: \.label, last: [DiskShareKind.dossier.label]) }
}

public extension LogDeviceGuide.Brand {
    /// Familles des guides syslog : alphabétique, « Autres » à la fin.
    static var orderedFamilies: [String] { Array(Set(allCases.map(\.family))).sortedFrench(last: ["Autres"]) }

    static func ordered(in family: String) -> [LogDeviceGuide.Brand] {
        allCases.filter { $0.family == family }.sortedFrench(by: \.label)
    }
}

public extension FlowDeviceGuide.Brand {
    static var orderedFamilies: [String] { families.sortedFrench(last: ["Autres"]) }

    static func ordered(in family: String) -> [FlowDeviceGuide.Brand] {
        allCases.filter { $0.family == family }.sortedFrench(by: \.label)
    }
}
