import Foundation
import NetScopeCore

/// Firmware et licences fictifs (note 41), lus « sur » les FortiGate de démonstration. Aucun accès
/// réseau.
///
/// - Siège (FortiGate-60F) : FortiOS v7.2.8 build1639, v7.2.10 disponible (Mature, chemin par
///   v7.2.9) et v7.4.5 (Feature, autre branche) ; trois FortiSwitch en v7.2.5, à jour ; six FortiAP
///   dont AP-ENTREPOT en retard (v7.2.4, v7.2.8 recommandée) ; licence IPS qui expire dans 21 jours,
///   FortiCare matériel dans 48 jours, antivirus et filtrage web valides, antispam sans licence ;
/// - Entrepôt Laval (FortiGate-40F) : FortiOS v7.2.8 aussi, mêmes images ; deux FortiSwitch et deux
///   FortiAP à jour ; licences valides ;
/// - Bureau Québec : jeton manquant ; Usine Drummondville : refusée (HTTP 403).
///
/// Captures : NETSCOPE_OUTIL_DEMO=firmware ouvre l'outil ; NETSCOPE_SITES_VUE_OUTILS=tous montre
/// tous les sites ; NETSCOPE_FIRMWARE_EQUIPEMENT=FSW-QUAI choisit l'équipement détaillé (le premier à
/// mettre à jour par défaut) ; NETSCOPE_RAPPORT_FIRMWARE=1 coche la section du rapport.
@MainActor
enum FirmwareDemo {
    struct Content {
        var reports: [UUID: FirmwareSiteReport]
        var errors: [UUID: String]
        var calls: [UUID: [FortiCallRecord]]
    }

    /// Équipement détaillé au lancement (nil : le premier à mettre à jour).
    static var initialDeviceID: String? {
        guard let name = ProcessInfo.processInfo.environment["NETSCOPE_FIRMWARE_EQUIPEMENT"] else { return nil }
        let content = make()
        let overview = FirmwareAnalysis.overview(Array(content.reports.values))
        return overview.devices.first { $0.name.lowercased() == name.lowercased() }?.id
    }

    static func make(now: Date = Date()) -> Content {
        let siegeReport = siege(now: now)
        let lavalReport = laval(now: now.addingTimeInterval(-3 * 60))
        let drummondError = FortiGateError.forbidden(path: FirmwarePaths.licenses).firmwareDescription
        return Content(
            reports: [FortiGateSitesDemo.siegeID: FirmwareSiteReport(controllerID: FortiGateSitesDemo.siegeID, site: "Siège", report: siegeReport),
                      FortiGateSitesDemo.lavalID: FirmwareSiteReport(controllerID: FortiGateSitesDemo.lavalID, site: "Entrepôt Laval", report: lavalReport)],
            errors: [FortiGateSitesDemo.quebecID: "Jeton absent\u{00A0}: enregistrez-le dans Réglages › Switchs › Contrôleurs FortiGate.",
                     FortiGateSitesDemo.drummondID: drummondError],
            calls: [FortiGateSitesDemo.siegeID: siegeReport.calls, FortiGateSitesDemo.lavalID: lavalReport.calls,
                    FortiGateSitesDemo.drummondID: [
                        FortiCallRecord(path: FirmwarePaths.system, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
                        FortiCallRecord(path: FirmwarePaths.firmware, status: 403, outcome: .refused, message: drummondError,
                                        body: #"{"status":"error","http_status":403}"#),
                        FortiCallRecord(path: FirmwarePaths.licenses, status: 403, outcome: .refused, message: drummondError,
                                        body: #"{"status":"error","http_status":403}"#),
                    ]])
    }

    /// Images FortiOS proposées par FortiGuard aux FortiGate en 7.2.8.
    private static let fortiOSImages = [FirmwareImage(version: FortiVersion(major: 7, minor: 4, patch: 5, build: 2702), maturity: "Feature"),
                                        FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 10, build: 1706), maturity: "Mature"),
                                        FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 9, build: 1688), maturity: "Mature")]
    private static let edges = [FirmwareUpgradeEdge(from: FortiVersion(major: 7, minor: 2, patch: 8), to: FortiVersion(major: 7, minor: 2, patch: 9)),
                                FirmwareUpgradeEdge(from: FortiVersion(major: 7, minor: 2, patch: 9), to: FortiVersion(major: 7, minor: 2, patch: 10)),
                                FirmwareUpgradeEdge(from: FortiVersion(major: 7, minor: 2, patch: 10), to: FortiVersion(major: 7, minor: 4, patch: 5))]
    private static let switchCatalog: [String: [FirmwareImage]] = [
        "S248EP": [FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 5, build: 453), recommended: true)],
        "S124FP": [FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 5, build: 453), recommended: true)],
        "S108FF": [FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 5, build: 453), recommended: true)],
    ]
    private static let apCatalog: [String: [FirmwareImage]] = [
        "FP231F": [FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 8, build: 436), recommended: true)],
        "FP431F": [FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 8, build: 436), recommended: true)],
        "FP23JF": [FirmwareImage(version: FortiVersion(major: 7, minor: 2, patch: 8, build: 436), recommended: true)],
    ]

    private static func days(_ n: Double, from now: Date) -> Date { now.addingTimeInterval(n * 86_400 + 3600) }

    private static func calls(_ report: FirmwareReadReport) -> [FortiCallRecord] {
        [FortiCallRecord(path: FirmwarePaths.system, status: 200, outcome: .ok, body: "(démonstration)", items: 1),
         FortiCallRecord(path: FirmwarePaths.firmware, status: 200, outcome: .ok, body: "(démonstration)", items: 2),
         FortiCallRecord(path: FirmwarePaths.upgradePaths, status: 200, outcome: .ok, body: "(démonstration)", items: edges.count),
         FortiCallRecord(path: FirmwarePaths.switches, status: 200, outcome: .ok, body: "(démonstration)", items: report.switches.count),
         FortiCallRecord(path: FirmwarePaths.switchFirmware, status: 200, outcome: .ok, body: "(démonstration)", items: switchCatalog.count),
         FortiCallRecord(path: FirmwarePaths.accessPoints, status: 200, outcome: .ok, body: "(démonstration)", items: report.accessPoints.count),
         FortiCallRecord(path: FirmwarePaths.apFirmware, status: 200, outcome: .ok, body: "(démonstration)", items: apCatalog.count),
         FortiCallRecord(path: FirmwarePaths.licenses, status: 200, outcome: .ok, body: "(démonstration)", items: report.licenses?.count ?? 0)]
    }

    private static func sw(_ name: String, _ serial: String, _ model: String, _ code: String) -> FortiManagedSwitch {
        FortiManagedSwitch(switchID: name, serial: serial, name: name, model: model, osVersion: "\(code)-v7.2.5-build0453,230920 (GA)",
                           connected: true, state: "Authorized")
    }

    private static func ap(_ name: String, _ serial: String, _ model: String, _ firmware: String, connected: Bool = true) -> FortiManagedAP {
        FortiManagedAP(name: name, wtpID: serial, serial: serial, model: model, firmware: firmware, connected: connected)
    }

    // MARK: Siège

    static func siege(now: Date = Date()) -> FirmwareReadReport {
        let system = FortiGateSystem(hostname: "FGT-SIEGE", model: "FortiGate-60F", serial: "FGT60FTK22004711",
                                     version: "v7.2.8", build: 1639, vdom: "root")
        let licenses = [
            FirmwareLicense(key: "forticare", status: "registered", type: "contract"),
            FirmwareLicense(key: "forticare.hardware", status: "licensed", type: "premium", expires: days(48, from: now)),
            FirmwareLicense(key: "antivirus", status: "licensed", type: "contract", version: "92.08137", expires: days(292, from: now)),
            FirmwareLicense(key: "ips", status: "expires_soon", type: "contract", version: "28.00920", expires: days(21, from: now)),
            FirmwareLicense(key: "web_filtering", status: "licensed", type: "contract", expires: days(292, from: now)),
            FirmwareLicense(key: "appctrl", status: "licensed", type: "contract", version: "28.00920", expires: days(292, from: now)),
            FirmwareLicense(key: "botnet_ip", status: "licensed", type: "contract", version: "7.03814", expires: days(292, from: now)),
            FirmwareLicense(key: "antispam", status: "no_license", type: "contract"),
        ]
        var report = FirmwareReadReport(
            system: system, currentFortiOS: FortiVersion(major: 7, minor: 2, patch: 8, build: 1639), availableFortiOS: fortiOSImages,
            upgradeEdges: edges,
            switches: [sw("FSW-ENTREPOT", "S248EPTF21000123", "FS-248E-POE", "S248EP"), sw("FSW-QUAI", "S124FPTF22000456", "FS-124F-POE", "S124FP"),
                       sw("FSW-SERVEURS", "S108FFTV21000789", "FS-108F", "S108FF")],
            accessPoints: [ap("AP-ACCUEIL", "FP231FTF22004101", "FAP-231F", "FP231F-v7.2.8-build0436"),
                           ap("AP-ETG2", "FP231FTF22004187", "FAP-231F", "FP231F-v7.2.8-build0436"),
                           ap("AP-SALLE-CONF", "FP431FTF21000912", "FAP-431F", "FP431F-v7.2.8-build0436"),
                           ap("AP-ENTREPOT", "FP231FTF22004233", "FAP-231F", "FP231F-v7.2.4-build0412"),
                           ap("AP-DIRECTION", "FP23JFTF23001044", "FAP-23JF", "FP23JF-v7.2.8-build0436"),
                           ap("AP-QUAI", "FP231FTF22004290", "FAP-231F", "FP231F-v7.2.8-build0436", connected: false)],
            switchCatalog: switchCatalog, apCatalog: apCatalog, licenses: licenses, readAt: now.addingTimeInterval(-40))
        report.calls = calls(report)
        return report
    }

    // MARK: Entrepôt Laval

    static func laval(now: Date = Date()) -> FirmwareReadReport {
        let system = FortiGateSystem(hostname: "FGT-LAVAL", model: "FortiGate-40F", serial: "FGT40FTK23001802", version: "v7.2.8", build: 1639, vdom: "root")
        let licenses = [
            FirmwareLicense(key: "forticare", status: "registered", type: "contract"),
            FirmwareLicense(key: "forticare.hardware", status: "licensed", type: "8x5", expires: days(204, from: now)),
            FirmwareLicense(key: "antivirus", status: "licensed", type: "contract", version: "92.08137", expires: days(204, from: now)),
            FirmwareLicense(key: "ips", status: "licensed", type: "contract", version: "28.00920", expires: days(204, from: now)),
            FirmwareLicense(key: "web_filtering", status: "licensed", type: "contract", expires: days(204, from: now)),
        ]
        var report = FirmwareReadReport(
            system: system, currentFortiOS: FortiVersion(major: 7, minor: 2, patch: 8, build: 1639), availableFortiOS: fortiOSImages,
            upgradeEdges: edges,
            switches: [sw("FSW-LAVAL-01", "S124FPTF23001190", "FS-124F-POE", "S124FP"), sw("FSW-LAVAL-02", "S108FFTV23000417", "FS-108F", "S108FF")],
            accessPoints: [ap("AP-LAV-QUAI", "FP231FTF23002210", "FAP-231F", "FP231F-v7.2.8-build0436"),
                           ap("AP-LAV-BUREAU", "FP23JFTF23003301", "FAP-23JF", "FP23JF-v7.2.8-build0436")],
            switchCatalog: switchCatalog, apCatalog: apCatalog, licenses: licenses, readAt: now)
        report.calls = calls(report)
        return report
    }
}
