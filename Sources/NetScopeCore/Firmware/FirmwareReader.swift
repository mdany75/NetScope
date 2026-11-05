import Foundation

// Note 41 : lecture du firmware et des licences d'une FortiGate (GET seulement), avec le même
// transport et le même jeton que les FortiSwitch. Système, version installée et images
// disponibles de FortiOS (et chemin de mise à jour s'il est publié), FortiSwitch et FortiAP gérés
// avec leur version, versions recommandées pour eux, contrats FortiGuard et FortiCare. Chaque
// partie absente de cette version de FortiOS (404) ou refusée au profil (403) est notée et
// ignorée ; seuls le système (jeton, hôte de confiance) et un refus de toutes les parties lèvent
// l'erreur. NetScope ne lance jamais de mise à jour : aucune adresse d'écriture n'est connue ici.

/// Adresses de l'API utilisées pour le firmware et les licences (toutes en lecture).
public enum FirmwarePaths {
    public static let system = FortiPaths.systemStatus
    public static let firmware = "/api/v2/monitor/system/firmware"
    /// FortiOS 7.0 et plus ; absente ailleurs (404, ignoré sans note).
    public static let upgradePaths = "/api/v2/monitor/system/firmware/upgrade-paths"
    public static let switches = FortiPaths.switchStatus
    public static let switchesLegacy = FortiPaths.switchLegacy
    public static let switchFirmware = "/api/v2/monitor/switch-controller/fsw-firmware"
    public static let accessPoints = FortiWifiPaths.managedAP
    public static let apFirmware = "/api/v2/monitor/wifi/firmware"
    public static let licenses = "/api/v2/monitor/license/status"

    public static let all = [system, firmware, upgradePaths, switches, switchesLegacy, switchFirmware, accessPoints, apFirmware, licenses]
}

extension FortiGateReader {
    /// Lit le firmware et les licences. Voir `readFirmwareKeepingCalls`.
    public func readFirmware(now: Date = Date()) async throws -> FirmwareReadReport {
        do {
            return try await readFirmwareKeepingCalls(now: now)
        } catch let failure as FortiReadFailure {
            throw failure.error
        }
    }

    /// Comme `readFirmware`, mais une erreur emporte les appels déjà faits (`FortiReadFailure`).
    public func readFirmwareKeepingCalls(now: Date = Date()) async throws -> FirmwareReadReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readFirmwareAll(now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    private func readFirmwareAll(now: Date, calls: inout [FortiCallRecord]) async throws -> FirmwareReadReport {
        var report = FirmwareReadReport(readAt: now)

        let system = try await fetch(FirmwarePaths.system)
        calls.append(system.record)
        if let error = system.error { throw error }
        if let body = system.response?.body { report.system = FortiParsers.system(body) }
        report.currentFortiOS = report.system.flatMap { s in
            FortiVersion(s.version).map { v in var copy = v; if copy.build == nil { copy.build = s.build }; return copy }
        }

        // Images FortiOS disponibles (FortiGuard, par la FortiGate).
        let firmware = try await fetch(FirmwarePaths.firmware)
        calls.append(firmware.record)
        if let body = firmware.response?.body, firmware.error == nil, let parsed = FirmwareParsers.fortiOS(body) {
            if let current = parsed.current { report.currentFortiOS = current }
            report.availableFortiOS = parsed.available
            if parsed.available.isEmpty {
                report.notes.append("Aucune image FortiOS proposée par FortiGuard\u{00A0}: la FortiGate est peut-être à jour, sans contrat FortiCare ou sans accès à FortiGuard.")
            }
        } else if let note = Self.firmwareNote("Versions FortiOS disponibles", firmware.error, right: "System") {
            report.notes.append(note)
        }

        // Chemin de mise à jour (facultatif ; absent avant 7.0 : rien à dire).
        if report.availableFortiOS?.isEmpty == false {
            let paths = try await fetch(FirmwarePaths.upgradePaths)
            calls.append(paths.record)
            if let body = paths.response?.body, paths.error == nil, let edges = FirmwareParsers.upgradePaths(body) {
                report.upgradeEdges = edges
            }
        }

        // FortiSwitch gérés : adresse 7.x, sinon celle de 6.4.
        var switches = try await fetch(FirmwarePaths.switches)
        calls.append(switches.record)
        if case .notFound? = switches.error {
            switches = try await fetch(FirmwarePaths.switchesLegacy)
            calls.append(switches.record)
        }
        if let body = switches.response?.body, switches.error == nil, let list = FortiParsers.managedSwitches(body) {
            report.switches = list
            if !list.isEmpty {
                let catalog = try await fetch(FirmwarePaths.switchFirmware)
                calls.append(catalog.record)
                if let body = catalog.response?.body, catalog.error == nil, let map = FirmwareParsers.catalog(body) {
                    report.switchCatalog = map
                } else if case .forbidden? = catalog.error, let note = Self.firmwareNote("Versions recommandées des FortiSwitch", catalog.error,
                                                                                          right: "WiFi & Switch Controller") {
                    report.notes.append(note)
                }
            }
        } else if case .forbidden? = switches.error, let note = Self.firmwareNote("FortiSwitch", switches.error, right: "WiFi & Switch Controller") {
            report.notes.append(note)
        }

        // FortiAP gérées.
        let aps = try await fetch(FirmwarePaths.accessPoints)
        calls.append(aps.record)
        if let body = aps.response?.body, aps.error == nil, let list = FortiWifiParsers.managedAPs(body, now: now) {
            report.accessPoints = list
            if !list.isEmpty {
                let catalog = try await fetch(FirmwarePaths.apFirmware)
                calls.append(catalog.record)
                if let body = catalog.response?.body, catalog.error == nil, let map = FirmwareParsers.catalog(body) {
                    report.apCatalog = map
                } else if case .forbidden? = catalog.error, let note = Self.firmwareNote("Versions recommandées des FortiAP", catalog.error,
                                                                                          right: "WiFi & Switch Controller") {
                    report.notes.append(note)
                }
            }
        } else if case .forbidden? = aps.error, let note = Self.firmwareNote("FortiAP", aps.error, right: "WiFi & Switch Controller") {
            report.notes.append(note)
        }

        // Contrats FortiGuard et FortiCare.
        let licenses = try await fetch(FirmwarePaths.licenses)
        calls.append(licenses.record)
        if let body = licenses.response?.body, licenses.error == nil, let list = FirmwareParsers.licenses(body) {
            report.licenses = list
        } else if let note = Self.firmwareNote("Licences FortiGuard", licenses.error, right: "System") {
            report.notes.append(note)
        }

        // Tout refusé : rien à montrer, l'erreur explique le droit à ajouter.
        let refused = [firmware.error, licenses.error].allSatisfy { if case .forbidden? = $0 { return true } else { return false } }
        if refused, report.switches.isEmpty, report.accessPoints.isEmpty { throw FortiGateError.forbidden(path: FirmwarePaths.licenses) }

        report.calls = calls
        return report
    }

    /// Explication d'une partie absente (404) ou refusée (403).
    static func firmwareNote(_ part: String, _ error: FortiGateError?, right: String) -> String? {
        switch error {
        case .notFound?: return "\(part)\u{00A0}: adresse absente de cette version de FortiOS."
        case .forbidden?: return "\(part)\u{00A0}: accès refusé (HTTP 403), ajoutez le droit «\u{00A0}\(right)\u{00A0}» en lecture au profil de l’administrateur API."
        case .some(let other): return "\(part)\u{00A0}: \(other.errorDescription ?? "lecture impossible.")"
        case nil: return nil
        }
    }
}

extension FortiGateError {
    /// Message propre au firmware et aux licences pour un 403.
    public var firmwareDescription: String {
        if case .forbidden = self {
            return "Accès refusé (HTTP 403) au firmware et aux licences de la FortiGate\u{00A0}: ajoutez les droits «\u{00A0}System\u{00A0}» et «\u{00A0}WiFi & Switch Controller\u{00A0}» en lecture au profil de l’administrateur API (System › Admin Profiles), ou vérifiez que ce Mac est dans ses hôtes de confiance."
        }
        return errorDescription ?? "Lecture impossible."
    }
}
