import Foundation

// Note 41 : lecture tolérante des réponses de FortiOS (6.4 à 7.6) sur le firmware et les licences.
// Mêmes principes que FortiParsers : enveloppe « results » ou réponse nue, noms en « - » ou « _ »,
// champs absents, liste ou dictionnaire indexé.
//
// Noms relevés dans la documentation publique (FNDN, guide d'administration de FortiOS : niveaux
// de maturité « Mature » / « Feature »), le modèle Zabbix « FortiGate by HTTP » (system/firmware :
// results.current { version, build }, results.available [ … ] ; license/status : un objet par
// service { status, type, version, expires (horodatage Unix) }, états « licensed », « expired »,
// « expires_soon », « no_license », « no_support », « not_registered », « vm_valid »…) et le module
// PowerFGT (license/status : FortiGuard et FortiCare). Les listes des FortiSwitch
// (switch-controller/fsw-firmware) et des FortiAP (wifi/firmware) ne sont pas décrites
// publiquement en détail : elles sont lues de façon défensive et gardées dans la réponse brute.

public enum FirmwareParsers {
    // MARK: FortiOS

    /// monitor/system/firmware : version installée et images disponibles ; nil si ce n'est pas du JSON.
    public static func fortiOS(_ data: Data) -> (current: FortiVersion?, available: [FirmwareImage])? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let content = FortiJSON.results(json)
        guard let dict = content as? [String: Any] else {
            // Liste nue : uniquement des images disponibles.
            return (nil, images(content))
        }
        let root = FortiObject(dict)
        let current = root.object("current", "current_version", "installed").flatMap(FortiVersion.from)
            ?? root.string("current", "current_version").flatMap { FortiVersion($0) }
        return (current, images(root.any("available", "available_versions", "images", "versions")))
    }

    /// Liste d'images (objets ou textes), triée de la plus récente à la plus ancienne, sans doublon.
    static func images(_ value: Any?, recommended: Bool = false) -> [FirmwareImage] {
        var result: [FirmwareImage] = []
        let items: [Any]
        if let list = value as? [Any] { items = list } else if let value { items = [value] } else { items = [] }
        for item in items {
            if let dict = item as? [String: Any] {
                let o = FortiObject(dict)
                guard let v = FortiVersion.from(o) else { continue }
                let flag = recommended || o.bool("recommended", "is_recommended") == true
                result.append(FirmwareImage(version: v, maturity: FirmwareImage.maturityLabel(o.string("maturity", "release_type", "release-type", "tag")),
                                            recommended: flag))
            } else if let text = FortiJSON.string(item), let v = FortiVersion(text) {
                result.append(FirmwareImage(version: v, recommended: recommended))
            }
        }
        var seen: Set<FortiVersion> = []
        return result.sorted { $0.version > $1.version }.filter { seen.insert(FortiVersion(major: $0.version.major, minor: $0.version.minor,
                                                                                               patch: $0.version.patch)).inserted }
    }

    /// monitor/system/firmware/upgrade-paths : étapes « from » → « to » ; nil si ce n'est pas du JSON.
    public static func upgradePaths(_ data: Data) -> [FirmwareUpgradeEdge]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item -> FirmwareUpgradeEdge? in
            func version(_ names: String...) -> FortiVersion? {
                if let o = item.value(names) as? [String: Any] { return FortiVersion.from(FortiObject(o)) }
                return FortiJSON.string(item.value(names)).flatMap { FortiVersion($0) }
            }
            guard let from = version("from", "from_version", "source"), let to = version("to", "to_version", "target") else { return nil }
            return FirmwareUpgradeEdge(from: from, to: to)
        }
    }

    // MARK: FortiSwitch et FortiAP

    /// switch-controller/fsw-firmware ou wifi/firmware : images par code de plateforme (« S248EP »,
    /// « FP231F », numéro de série) ; nil si ce n'est pas du JSON. Accepte une liste d'objets
    /// { platform | model | serial, versions | available | recommended, … } ou un dictionnaire
    /// indexé par plateforme.
    public static func catalog(_ data: Data) -> [String: [FirmwareImage]]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: [FirmwareImage]] = [:]
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            let names = [item.string("platform", "platform_id", "platform-id", "model", "platform_type"),
                         item.string("serial", "sn", "wtp_id", "switch_id", "switch-id"), item.string("_key")]
                .compactMap { $0 }.map(FirmwareDevice.platformKey).filter { $0.count >= 3 }
            guard !names.isEmpty else { continue }
            var list = images(item.any("recommended", "recommended_version", "recommended_firmware"), recommended: true)
            list += images(item.any("available", "versions", "images", "firmware", "firmwares", "latest"))
            if list.isEmpty, let v = item.string("version", "latest_version") .flatMap({ FortiVersion($0) }) {
                list = [FirmwareImage(version: v)]
            }
            guard !list.isEmpty else { continue }
            for name in names { result[name, default: []] += list }
        }
        return result.mapValues { list in
            var seen: Set<FortiVersion> = []
            // À version égale, l'image marquée recommandée l'emporte.
            return list.sorted { ($0.version, $0.recommended ? 1 : 0) > ($1.version, $1.recommended ? 1 : 0) }
                .filter { seen.insert(FortiVersion(major: $0.version.major, minor: $0.version.minor, patch: $0.version.patch)).inserted }
        }
    }

    // MARK: Licences

    /// monitor/license/status : un contrat par service ; FortiCare détaillé (« support » : matériel,
    /// firmware, assistance) ; nil si ce n'est pas du JSON.
    public static func licenses(_ data: Data) -> [FirmwareLicense]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        guard let dict = FortiJSON.results(json) as? [String: Any] else { return [] }
        var result: [FirmwareLicense] = []
        for key in dict.keys.sorted() {
            guard let value = dict[key] as? [String: Any], key.lowercased() != "vdom" else { continue }
            let o = FortiObject(value)
            let status = o.string("status", "state")?.lowercased()
            let expires = timestamp(o.any("expires", "expiry", "expiration", "expiry_date", "expire"))
            if status != nil || expires != nil {
                result.append(FirmwareLicense(key: key, status: status, type: o.string("type")?.lowercased(),
                                              version: o.string("version", "db_version"), expires: expires))
            }
            // FortiCare : contrats d'assistance (matériel, firmware, assistance) avec leur date.
            if let support = o.object("support") {
                for sub in support.raw.keys.sorted() {
                    guard let child = support.raw[sub] as? [String: Any] else { continue }
                    let c = FortiObject(child)
                    let date = timestamp(c.any("expires", "expiry", "expiration"))
                    let state = c.string("status", "support_level_status")?.lowercased()
                    guard date != nil || state != nil else { continue }
                    result.append(FirmwareLicense(key: "\(key).\(sub)", status: state, type: c.string("support_level", "type")?.lowercased(),
                                                  expires: date))
                }
            }
        }
        return result
    }

    /// Horodatage Unix (secondes ou millisecondes), texte ISO 8601 ou « AAAA-MM-JJ » ; 0 : inconnu.
    static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String, Double(text) == nil {
            let t = text.trimmingCharacters(in: .whitespaces)
            if let date = ISO8601DateFormatter().date(from: t) { return date }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd", "EEE MMM d HH:mm:ss yyyy"] {
                f.dateFormat = format
                if let date = f.date(from: t) { return date }
            }
            return nil
        }
        return WANParsers.timestamp(value)
    }

    // MARK: États

    /// États d'un contrat actif.
    static let activeStates: Set<String> = ["licensed", "registered", "valid", "vm_valid", "free_license", "cloud_logged_in",
                                            "licensed_exhausted", "free_license_exhausted", "vm_eval", "update_manual",
                                            "update_push", "update_sched", "vm_grace_period", "active", "enable", "enabled"]
    static let soonStates: Set<String> = ["expires_soon", "vm_expires_soon"]
    static let expiredStates: Set<String> = ["expired", "vm_expired", "vm_eval_expired"]
    static let absentStates: Set<String> = ["no_license", "no_support", "not_registered", "unavailable", "disable", "disabled",
                                            "cloud_logged_out", "none"]
}
