import Foundation

/// Sondes de la note 41 : « Licence bientôt expirée » (seuil en jours) et « Firmware pas à jour ».
/// Elles lisent la dernière lecture du firmware et des licences des FortiGate (aucun trafic propre ;
/// l'application relit quand la lecture est plus vieille que l'intervalle). Lecture seule : aucune
/// mise à jour n'est jamais lancée.
public enum MonFirmwareChecks {
    /// Seuil proposé d'une nouvelle sonde « Licence bientôt expirée », en jours.
    public static let defaultDays = 30

    /// Licences visées : « * » (toutes), « Siège / * », un service (« ips », « IPS », « FortiCare »).
    public static func licenses(_ target: String, in overview: FirmwareOverview) -> [FirmwareLicenseUsage] {
        let (site, key) = MonWANChecks.parse(target)
        return overview.licenses.filter { usage in
            guard site == nil || SearchText.fold(usage.site) == site else { return false }
            guard usage.level != .notLicensed else { return false }
            guard let key else { return true }
            let base = usage.license.key.split(separator: ".").first.map(String.init) ?? usage.license.key
            let keys = [usage.license.key, base, usage.license.label, usage.license.label.components(separatedBy: " ").first ?? ""]
                .map(SearchText.fold)
            return keys.contains(key) || SearchText.fold(usage.license.label).hasPrefix(key)
        }
    }

    /// Équipements visés : « * », « Siège / * », un nom, un numéro de série, un modèle ou une
    /// famille (« FortiAP »).
    public static func devices(_ target: String, in overview: FirmwareOverview) -> [FirmwareDevice] {
        let (site, key) = MonWANChecks.parse(target)
        return overview.devices.filter { device in
            guard site == nil || SearchText.fold(device.site) == site else { return false }
            guard let key else { return true }
            return [device.name, device.serial, device.model, device.kind.label, device.kind.rawValue].map(SearchText.fold).contains(key)
        }
    }

    static func unread(_ overview: FirmwareOverview?, error: String?, now: Date) -> MonRunOutcome? {
        if let overview, overview.readAt != nil, !overview.sites.isEmpty { return nil }
        if let error {
            return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Lecture impossible", error: error))
        }
        return .noData(now, "En attente d’une lecture de la FortiGate")
    }

    /// Lecture impossible pour un site visé : dite plutôt que de rester verte sur les autres sites.
    static func withSiteErrors(_ outcome: MonRunOutcome, target: String, siteErrors: [String: String], now: Date) -> MonRunOutcome {
        let failed = MonWANChecks.failedSites(target, siteErrors: siteErrors)
        guard !failed.isEmpty, outcome.noData || outcome.result.problem == nil else { return outcome }
        if !outcome.noData && !outcome.result.reachable { return outcome }
        let site = MonWANChecks.parse(target).site
        let message = failed.map { failed.count > 1 || site == nil ? "\($0.site)\u{00A0}: \($0.message)" : $0.message }.joined(separator: " ")
        return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Lecture impossible", error: message))
    }

    static func suffix(_ site: String, _ overview: FirmwareOverview) -> String { overview.isMultiSite ? " (\(site))" : "" }

    /// « Licence bientôt expirée » : panne si une licence visée est expirée, alerte si elle expire
    /// dans `days` jours ou moins.
    public static func licenseExpiring(target: String, overview: FirmwareOverview?, error: String? = nil, siteErrors: [String: String] = [:],
                                       days: Int, now: Date) -> MonRunOutcome {
        withSiteErrors(licenseState(target: target, overview: overview, error: error, days: days, now: now),
                       target: target, siteErrors: siteErrors, now: now)
    }

    static func licenseState(target: String, overview: FirmwareOverview?, error: String?, days: Int, now: Date) -> MonRunOutcome {
        if let pending = unread(overview, error: error, now: now) { return pending }
        guard let overview else { return .noData(now, "En attente d’une lecture de la FortiGate") }
        let chosen = licenses(target, in: overview)
        guard !chosen.isEmpty else {
            if MonWANChecks.parse(target).key == nil { return .noData(now, "Aucune licence lue") }
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Licence introuvable",
                                                   problem: "Aucune licence «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let dated = chosen.filter { $0.daysLeft != nil }.sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        let nearest = dated.first
        var value = chosen.count == 1 ? chosen[0].license.label : "\(chosen.count) licences"
        if let nearest {
            value += " · " + (chosen.count > 1 ? "min " : "") + nearest.daysLabel
        }
        let expired = chosen.filter { $0.level == .expired }
        if let first = expired.first, let text = FirmwareAnalysis.alertText(first) {
            let more = expired.count > 1 ? " (et \(expired.count - 1) autre\(expired.count > 2 ? "s" : ""))" : ""
            return MonRunOutcome(result: MonResult(date: now, reachable: false, value: value, error: text + suffix(first.site, overview) + more))
        }
        let soon = dated.filter { ($0.daysLeft ?? .max) <= days }
        if let first = soon.first {
            let more = soon.count > 1 ? " (et \(soon.count - 1) autre\(soon.count > 2 ? "s" : ""))" : ""
            let text = first.daysLeft == 0 ? "Licence \(first.license.label)\u{00A0}: expire aujourd’hui"
                : "Licence \(first.license.label)\u{00A0}: expire dans \(first.daysLeft ?? 0)\u{00A0}j"
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: text + suffix(first.site, overview) + more))
        }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
    }

    /// « Firmware pas à jour » : alerte si un équipement visé a une mise à jour disponible.
    public static func firmwareOutdated(target: String, overview: FirmwareOverview?, error: String? = nil,
                                        siteErrors: [String: String] = [:], now: Date) -> MonRunOutcome {
        withSiteErrors(firmwareState(target: target, overview: overview, error: error, now: now),
                       target: target, siteErrors: siteErrors, now: now)
    }

    static func firmwareState(target: String, overview: FirmwareOverview?, error: String?, now: Date) -> MonRunOutcome {
        if let pending = unread(overview, error: error, now: now) { return pending }
        guard let overview else { return .noData(now, "En attente d’une lecture de la FortiGate") }
        let chosen = devices(target, in: overview)
        guard !chosen.isEmpty else {
            if MonWANChecks.parse(target).key == nil { return .noData(now, "Aucun équipement lu") }
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Équipement introuvable",
                                                   problem: "Aucun équipement «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let outdated = chosen.filter { $0.status == .updateAvailable }
        let value: String
        if chosen.count == 1 {
            let d = chosen[0]
            value = d.versionLabel + (d.status == .updateAvailable ? " → \(d.availableLabel)" : " · \(d.status.label.lowercased())")
        } else {
            value = outdated.isEmpty ? "\(chosen.count) à jour ou inconnus" : "\(outdated.count) à mettre à jour sur \(chosen.count)"
        }
        if let first = outdated.first, let text = FirmwareAnalysis.alertText(first) {
            let more = outdated.count > 1 ? " (et \(outdated.count - 1) autre\(outdated.count > 2 ? "s" : ""))" : ""
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: text + suffix(first.site, overview) + more))
        }
        if chosen.allSatisfy({ $0.status == .unknown }) { return .noData(now, "Versions disponibles inconnues") }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
    }
}
