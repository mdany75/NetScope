import Foundation
import NetScopeCore

// Note 41 : firmware et licences du parc Fortinet. Réponses JSON fixes de FortiOS en variantes
// de versions (7.4 : system/firmware avec « current » et « available », chemin de mise à jour,
// listes recommandées des FortiSwitch et des FortiAP ; 6.4 : system/firmware absent, ancienne
// adresse des switchs ; réponses nues), comparaison des versions « v7.2.8 build1639 », jours
// restants et couleurs à 60 et 30 jours, lecture par un faux transport (404, 403, jeton retiré),
// vue multisite, sondes de la Surveillance et rapport. Aucun réseau.

enum FirmwareFixtures {
    static let status72 = """
    {"http_method":"GET","results":{"model_name":"FortiGate","model_number":"60F","model":"FGT60F","hostname":"FGT-SIEGE"},
     "vdom":"root","path":"system","name":"status","status":"success","serial":"FGT60FTK22004711","version":"v7.2.8","build":1639}
    """

    static let firmware72 = """
    {"http_method":"GET","results":{
      "current":{"id":"","version":"v7.2.8","major":7,"minor":2,"patch":8,"build":1639,"platform-id":"FGT60F","maturity":"M"},
      "available":[
        {"id":"07002000FIMG0012002010","version":"v7.2.10","major":7,"minor":2,"patch":10,"build":1706,"platform-id":"FGT60F","source":"fortiguard","maturity":"M"},
        {"id":"07002000FIMG0012002009","version":"v7.2.9","major":7,"minor":2,"patch":9,"build":1688,"platform-id":"FGT60F","source":"fortiguard","maturity":"M"},
        {"id":"07004000FIMG0012004005","version":"v7.4.5","major":7,"minor":4,"patch":5,"build":2702,"platform-id":"FGT60F","source":"fortiguard","maturity":"F"}
      ]},"vdom":"root","path":"system","name":"firmware","status":"success","serial":"FGT60FTK22004711","version":"v7.2.8","build":1639}
    """

    static let upgradePaths = """
    {"results":[{"from":{"major":7,"minor":2,"patch":8,"build":1639},"to":{"major":7,"minor":2,"patch":9,"build":1688}},
                {"from":{"major":7,"minor":2,"patch":9,"build":1688},"to":{"major":7,"minor":2,"patch":10,"build":1706}},
                {"from":"v7.2.10","to":"v7.4.5"}],"status":"success"}
    """

    static let switches = """
    {"results":[
      {"name":"FSW-ENTREPOT","serial":"S248EPTF21000123","switch-id":"FSW-ENTREPOT","status":"Connected","state":"Authorized",
       "os_version":"S248EP-v7.2.5-build0453,230920 (GA)","ports":[]},
      {"name":"FSW-QUAI","serial":"S124FPTF22000456","switch-id":"FSW-QUAI","status":"Connected","state":"Authorized",
       "os_version":"S124FP-v7.2.3-build0429,230712 (GA)","ports":[]}
    ],"status":"success"}
    """

    /// Liste recommandée des FortiSwitch : un objet par plateforme (forme défensive).
    static let switchFirmware = """
    {"results":[{"platform":"S248EP","versions":[{"version":"v7.2.5","build":453,"recommended":true},{"version":"v7.2.4","build":440}]},
                {"platform":"S124FP","recommended":{"version":"S124FP-v7.2.5-build0453"}}],"status":"success"}
    """

    static let accessPoints = """
    {"results":[
      {"name":"AP-ACCUEIL","wtp_id":"FP231FTF22004101","serial":"FP231FTF22004101","os_version":"FP231F-v7.2.8-build0436","status":"connected"},
      {"name":"AP-ENTREPOT","wtp_id":"FP231FTF22004233","serial":"FP231FTF22004233","os_version":"FP231F-v7.2.4-build0412","status":"connected"},
      {"name":"AP-DIRECTION","wtp_id":"FP23JFTF23001044","serial":"FP23JFTF23001044","os_version":"FP23JF-v7.2.8-build0436","status":"connected"}
    ],"status":"success"}
    """

    /// Liste recommandée des FortiAP : dictionnaire indexé par plateforme, versions en texte.
    static let apFirmware = """
    {"results":{"FP231F":{"available":["FP231F-v7.2.8-build0436","FP231F-v7.2.4-build0412"]}},"status":"success"}
    """

    /// license/status : un objet par service ; FortiCare avec ses contrats d'assistance. Dates
    /// relatives au 2026-11-04 12:00 UTC (1_793_793_600).
    static func licenses(now: Date) -> String {
        func at(_ days: Double) -> Int { Int(now.timeIntervalSince1970 + days * 86_400 + 3600) }
        return """
        {"http_method":"GET","results":{
          "forticare":{"status":"registered","account":"dany@example.com","company":"Groupe","industry":"",
             "support":{"hardware":{"status":"licensed","support_level":"premium","expires":\(at(280))},
                        "enhanced":{"status":"licensed","support_level":"24x7","expires":\(at(48))}}},
          "antivirus":{"type":"contract","status":"licensed","version":"92.08137","expires":\(at(280)),"last_update":1793750000},
          "ips":{"type":"contract","status":"expires_soon","version":"28.00920","expires":\(at(21))},
          "web_filtering":{"type":"contract","status":"licensed","expires":\(at(280))},
          "antispam":{"type":"contract","status":"no_license"},
          "industrial_db":{"type":"contract","status":"expired","expires":\(at(-4))},
          "vdom":{"type":"default","can_upgrade":false,"used":1,"max":10}
        },"status":"success"}
        """
    }

    static let now = Date(timeIntervalSince1970: 1_793_793_600)

    static func transport() -> FortiFakeTransport {
        FortiFakeTransport([
            FirmwarePaths.system: (200, status72), FirmwarePaths.firmware: (200, firmware72), FirmwarePaths.upgradePaths: (200, upgradePaths),
            FirmwarePaths.switches: (200, switches), FirmwarePaths.switchFirmware: (200, switchFirmware),
            FirmwarePaths.accessPoints: (200, accessPoints), FirmwarePaths.apFirmware: (200, apFirmware),
            FirmwarePaths.licenses: (200, licenses(now: now)),
        ])
    }
}

func registerFirmwareTests(_ suite: TestSuite) {
    let now = FirmwareFixtures.now

    suite.add("Firmware : versions FortiOS « v7.2.8 build1639 » lues et comparées") {
        try expectEqual(FortiVersion("v7.2.8 build1639"), FortiVersion(major: 7, minor: 2, patch: 8, build: 1639), "FortiOS")
        try expectEqual(FortiVersion("S248EP-v7.2.5-build0453,230920 (GA)"), FortiVersion(major: 7, minor: 2, patch: 5, build: 453), "FortiSwitch")
        try expectEqual(FortiVersion("FP231F-v7.2.8-build0436")?.short, "v7.2.8", "FortiAP")
        try expectEqual(FortiVersion("FortiOS v7.4.4 (build 2662)")?.build, 2662, "build avec espace")
        try expectEqual(FortiVersion("FortiGate-60F 7.0"), FortiVersion(major: 7, minor: 0, patch: 0), "majeure et mineure seules")
        try expect(FortiVersion("version inconnue") == nil && FortiVersion("") == nil, "illisible")
        let a = FortiVersion("v7.2.8")!, b = FortiVersion("v7.2.10")!, c = FortiVersion("v7.4.0")!
        try expect(a < b && b < c, "7.2.8 < 7.2.10 < 7.4.0 (pas un tri de texte)")
        try expect(a.sameBranch(b) && !b.sameBranch(c), "branches")
        try expect(FortiVersion("v7.2.8 build1639")!.sameRelease(FortiVersion("v7.2.8")!), "même version, build ignoré")
        try expectEqual(FortiVersion("v7.2.8 build0639")?.description, "v7.2.8 build0639", "libellé avec build")
    }

    suite.add("Firmware : analyseurs tolérants (7.4, liste recommandée, réponses nues, licences)") {
        let parsed = try FirmwareParsers.fortiOS(Data(FirmwareFixtures.firmware72.utf8)).unwrap("system/firmware")
        try expectEqual(parsed.current?.short, "v7.2.8", "version installée")
        try expectEqual(parsed.available.map(\.version.short), ["v7.4.5", "v7.2.10", "v7.2.9"], "images triées")
        try expectEqual(parsed.available.first?.maturity, "Feature", "maturité F")
        try expectEqual(parsed.available[1].maturity, "Mature", "maturité M")
        let bare = try FirmwareParsers.fortiOS(Data(#"[{"version":"v7.0.15","build":601}]"#.utf8)).unwrap("liste nue")
        try expect(bare.current == nil && bare.available.first?.version.build == 601, "liste nue")
        try expect(FirmwareParsers.fortiOS(Data("pas du json".utf8)) == nil, "pas du JSON")

        let edges = try FirmwareParsers.upgradePaths(Data(FirmwareFixtures.upgradePaths.utf8)).unwrap("chemins")
        try expectEqual(edges.count, 3, "trois étapes (objets ou textes)")
        try expectEqual(FirmwareAnalysis.path(from: FortiVersion("v7.2.8")!, to: FortiVersion("v7.2.10")!, edges: edges).map(\.short),
                        ["v7.2.9", "v7.2.10"], "chemin par 7.2.9")
        try expect(FirmwareAnalysis.path(from: FortiVersion("v7.2.8")!, to: FortiVersion("v7.6.0")!, edges: edges).isEmpty, "chemin inconnu")

        let sw = try FirmwareParsers.catalog(Data(FirmwareFixtures.switchFirmware.utf8)).unwrap("fsw-firmware")
        try expectEqual(sw["S248EP"]?.first?.version.short, "v7.2.5", "S248EP")
        try expect(sw["S248EP"]?.first?.recommended == true, "recommandée")
        try expectEqual(sw["S124FP"]?.first?.version.short, "v7.2.5", "S124FP (objet recommandé)")
        let ap = try FirmwareParsers.catalog(Data(FirmwareFixtures.apFirmware.utf8)).unwrap("wifi/firmware")
        try expectEqual(ap["FP231F"]?.map(\.version.short), ["v7.2.8", "v7.2.4"], "FortiAP indexé par plateforme")

        let licenses = try FirmwareParsers.licenses(Data(FirmwareFixtures.licenses(now: now).utf8)).unwrap("license/status")
        let keys = licenses.map(\.key)
        try expect(keys.contains("ips") && keys.contains("antivirus") && keys.contains("web_filtering"), "services lus")
        try expect(keys.contains("forticare") && keys.contains("forticare.hardware") && keys.contains("forticare.enhanced"), "FortiCare détaillé")
        try expect(!keys.contains("vdom"), "VDOM n'est pas un contrat")
        try expectEqual(licenses.first { $0.key == "ips" }?.version, "28.00920", "version de la base")
        try expectEqual(FirmwareLicense.label("web_filtering"), "Filtrage web", "libellé en français")
        try expectEqual(FirmwareLicense.label("forticare.hardware"), "FortiCare · matériel", "libellé FortiCare")
        try expectEqual(FirmwareLicense.label("sdwan_overlay"), "Sdwan overlay", "clé inconnue lisible")
        // Dates en millisecondes, en texte ISO ou « AAAA-MM-JJ » ; réponse nue.
        let variants = try FirmwareParsers.licenses(Data(#"{"ips":{"status":"licensed","expires":1801569600000},"antivirus":{"status":"licensed","expires":"2027-02-01"}}"#.utf8))
            .unwrap("variantes")
        try expect(variants.allSatisfy { $0.expires != nil }, "dates lues")
    }

    suite.add("Firmware : jours restants et couleurs à 60 et 30 jours") {
        func lic(_ status: String?, _ days: Double?) -> FirmwareLicense {
            FirmwareLicense(key: "ips", status: status, expires: days.map { now.addingTimeInterval($0 * 86_400 + 60) })
        }
        try expectEqual(FirmwareAnalysis.daysLeft(now.addingTimeInterval(21 * 86_400 + 3600), now: now), 21, "21 jours")
        try expectEqual(FirmwareAnalysis.daysLeft(now.addingTimeInterval(-3600), now: now), -1, "expirée depuis moins d'un jour")
        try expectEqual(FirmwareAnalysis.level(lic("licensed", 200), now: now).level, .ok, "valide")
        try expectEqual(FirmwareAnalysis.level(lic("licensed", 60), now: now).level, .warning, "60 jours : orange")
        try expectEqual(FirmwareAnalysis.level(lic("licensed", 61), now: now).level, .ok, "61 jours : valide")
        try expectEqual(FirmwareAnalysis.level(lic("expires_soon", 30), now: now).level, .critical, "30 jours : rouge")
        try expectEqual(FirmwareAnalysis.level(lic("licensed", -2), now: now).level, .expired, "date passée : expirée")
        try expectEqual(FirmwareAnalysis.level(lic("expired", nil), now: now).level, .expired, "état expiré")
        try expectEqual(FirmwareAnalysis.level(lic("no_license", nil), now: now).level, .notLicensed, "sans licence")
        try expectEqual(FirmwareAnalysis.level(lic("expires_soon", nil), now: now).level, .warning, "bientôt, sans date")
        try expectEqual(FirmwareAnalysis.level(lic("registered", nil), now: now).level, .ok, "enregistré")
        try expectEqual(FirmwareAnalysis.level(lic("bizarre", nil), now: now).level, .unknown, "état inconnu")
        let custom = FirmwareThresholds(warningDays: 90, criticalDays: 45)
        try expectEqual(FirmwareAnalysis.level(lic("licensed", 80), now: now, thresholds: custom).level, .warning, "seuils propres")
        let usage = FirmwareLicenseUsage(controllerID: UUID(), site: "Siège", license: lic("expired", -4), daysLeft: -4, level: .expired)
        try expectEqual(usage.daysLabel, "expirée depuis 4\u{00A0}j", "libellé des jours")
    }

    suite.add("Firmware : lecture par l'API (faux transport, 6.4, 404, 403, jeton retiré)") {
        let transport = FirmwareFixtures.transport()
        let report = try await FortiGateReader(transport: transport, tokenForRedaction: FortiFixtures.token).readFirmware(now: now)
        try expectEqual(report.system?.hostname, "FGT-SIEGE", "système")
        try expectEqual(report.currentFortiOS?.description, "v7.2.8 build1639", "version installée")
        try expectEqual(report.availableFortiOS?.count, 3, "images FortiOS")
        try expectEqual(report.upgradeEdges.count, 3, "chemin de mise à jour")
        try expectEqual(report.switches.count, 2, "FortiSwitch")
        try expectEqual(report.accessPoints.count, 3, "FortiAP")
        try expect(report.switchCatalog?["S248EP"] != nil && report.apCatalog?["FP231F"] != nil, "listes recommandées")
        try expect((report.licenses?.count ?? 0) >= 7, "licences")
        try expect(report.notes.isEmpty, "rien à signaler : \(report.notes)")
        try expect(transport.requested.allSatisfy { FirmwarePaths.all.contains($0) }, "seulement des adresses de lecture connues")
        try expect(!transport.requested.contains { $0.contains("upgrade") && !$0.hasSuffix("upgrade-paths") }, "jamais d'adresse de mise à jour")

        // FortiOS 6.4 : system/firmware, listes recommandées et chemin absents ; ancienne adresse des switchs.
        let old = FortiFakeTransport([
            FirmwarePaths.system: (200, FirmwareFixtures.status72),
            FirmwarePaths.switchesLegacy: (200, FirmwareFixtures.switches),
            FirmwarePaths.accessPoints: (200, FirmwareFixtures.accessPoints),
            FirmwarePaths.licenses: (200, FirmwareFixtures.licenses(now: now)),
        ])
        let r64 = try await FortiGateReader(transport: old).readFirmware(now: now)
        try expect(old.requested.contains(FirmwarePaths.switchesLegacy), "repli sur l'ancienne adresse des switchs")
        try expect(!old.requested.contains(FirmwarePaths.upgradePaths), "pas de chemin sans image disponible")
        try expect(r64.availableFortiOS == nil && r64.switchCatalog == nil, "listes non lues")
        try expect(r64.notes.contains { $0.hasPrefix("Versions FortiOS disponibles") && $0.contains("absente") }, "404 expliqué")
        let ov64 = FirmwareAnalysis.overview([FirmwareSiteReport(controllerID: UUID(), site: "Labo", report: r64)], now: now)
        try expectEqual(ov64.devices.first { $0.kind == .fortigate }?.status, .unknown, "FortiGate : inconnu sans liste")
        let late = ov64.devices.first { $0.name == "AP-ENTREPOT" }
        try expectEqual(late?.status, .updateAvailable, "FortiAP en retard sur le parc")
        try expectEqual(late?.source, .parc, "source : le parc")
        try expectEqual(ov64.devices.first { $0.name == "AP-ACCUEIL" }?.status, .unknown, "le plus récent du parc reste inconnu")

        // Licences refusées (403) : expliqué ; tout refusé et rien d'autre : erreur.
        let refusedLicenses = FortiFakeTransport([
            FirmwarePaths.system: (200, FirmwareFixtures.status72),
            FirmwarePaths.firmware: (200, FirmwareFixtures.firmware72),
            FirmwarePaths.licenses: (403, #"{"status":"error","http_status":403}"#),
        ])
        let partial = try await FortiGateReader(transport: refusedLicenses).readFirmware(now: now)
        try expect(partial.licenses == nil && partial.notes.contains { $0.contains("Licences") && $0.contains("403") && $0.contains("System") },
                   "403 des licences expliqué")
        let refused = FortiFakeTransport([
            FirmwarePaths.system: (200, FirmwareFixtures.status72),
            FirmwarePaths.firmware: (403, #"{"status":"error","http_status":403}"#),
            FirmwarePaths.licenses: (403, #"{"status":"error","http_status":403}"#),
        ])
        do {
            _ = try await FortiGateReader(transport: refused).readFirmware(now: now)
            throw TestFailure(message: "403 attendu", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expect(error.firmwareDescription.contains("System") && error.firmwareDescription.contains("Switch Controller"), "403 expliqué")
        }
        do {
            _ = try await FortiGateReader(transport: FortiFakeTransport([FirmwarePaths.system: (401, "{}")])).readFirmware(now: now)
            throw TestFailure(message: "401 attendu", file: #fileID, line: #line)
        } catch let error as FortiGateError {
            try expectEqual(error, .tokenRejected, "jeton refusé")
        }

        // Le jeton ne sort jamais dans les réponses brutes.
        let leaky = FortiFakeTransport([
            FirmwarePaths.system: (200, FirmwareFixtures.status72),
            FirmwarePaths.licenses: (200, #"{"results":{"forticare":{"status":"registered","password":"secret123","echo":"\#(FortiFixtures.token)"}}}"#),
        ])
        let redacted = try await FortiGateReader(transport: leaky, tokenForRedaction: FortiFixtures.token).readFirmware(now: now)
        let raw = redacted.calls.map(\.body).joined()
        try expect(!raw.contains(FortiFixtures.token) && !raw.contains("secret123"), "jeton et secret retirés")
    }

    suite.add("Firmware : état des équipements et vue de tous les sites") {
        let report = try await FortiGateReader(transport: FirmwareFixtures.transport()).readFirmware(now: now)
        let siegeID = UUID()
        let lavalID = UUID()
        var laval = FirmwareReadReport(system: FortiGateSystem(hostname: "FGT-LAVAL", model: "FortiGate-40F", serial: "FGT40FTK23001802",
                                                               version: "v7.2.10", build: 1706),
                                       currentFortiOS: FortiVersion("v7.2.10 build1706"),
                                       availableFortiOS: [FirmwareImage(version: FortiVersion("v7.4.5")!, maturity: "Feature")],
                                       accessPoints: [FortiManagedAP(name: "AP-LAV-QUAI", serial: "FP231FTF23002210", model: "FAP-231F",
                                                                     firmware: "FP231F-v7.2.8-build0436")],
                                       licenses: [FirmwareLicense(key: "forticare.hardware", status: "licensed",
                                                                  expires: now.addingTimeInterval(48 * 86_400 + 60))],
                                       readAt: now)
        laval.notes = ["Licences FortiGuard\u{00A0}: test."]
        let overview = FirmwareAnalysis.overview([FirmwareSiteReport(controllerID: siegeID, site: "Siège", report: report),
                                                  FirmwareSiteReport(controllerID: lavalID, site: "Entrepôt Laval", report: laval)], now: now)
        try expect(overview.isMultiSite, "deux sites")
        let fgt = try overview.devices.first { $0.name == "FGT-SIEGE" }.unwrap("FortiGate du Siège")
        try expectEqual(fgt.status, .updateAvailable, "Siège : mise à jour disponible")
        try expectEqual(fgt.available?.short, "v7.2.10", "même branche")
        try expectEqual(fgt.availableMaturity, "Mature", "maturité")
        try expectEqual(fgt.newerBranch?.short, "v7.4.5", "branche plus récente signalée")
        try expectEqual(fgt.upgradePath.map(\.short), ["v7.2.9", "v7.2.10"], "chemin publié")
        let lavalGate = try overview.devices.first { $0.name == "FGT-LAVAL" }.unwrap("FortiGate de Laval")
        try expectEqual(lavalGate.status, .upToDate, "Laval : à jour dans sa branche")
        try expectEqual(lavalGate.newerBranch?.short, "v7.4.5", "7.4 signalée seulement")
        try expectEqual(overview.devices.first { $0.name == "FSW-QUAI" }?.status, .updateAvailable, "FSW-QUAI en 7.2.3 → 7.2.5")
        try expectEqual(overview.devices.first { $0.name == "FSW-ENTREPOT" }?.status, .upToDate, "FSW-ENTREPOT à jour")
        try expectEqual(overview.devices.first { $0.name == "AP-ENTREPOT" }?.source, .recommended, "liste recommandée de la FortiGate")
        try expectEqual(overview.devices.first { $0.name == "AP-DIRECTION" }?.status, .unknown, "FAP-23JF sans liste ni parc plus récent")
        try expectEqual(overview.devices.first { $0.name == "AP-LAV-QUAI" }?.status, .unknown, "Laval sans liste : déjà au plus récent du parc")
        try expectEqual(overview.devices.first?.kind, .fortigate, "FortiGate d'abord")
        try expectEqual(overview.outdated.count, 3, "trois équipements à mettre à jour")

        let siege = try overview.sites.first { $0.site == "Siège" }.unwrap("résumé du Siège")
        try expectEqual(siege.updates, 3, "mises à jour du Siège")
        try expectEqual(siege.nearestDays, -4, "licence la plus proche : expirée depuis 4 jours")
        try expectEqual(siege.licenseLevel, .expired, "pire niveau")
        let lavalSummary = try overview.sites.first { $0.site == "Entrepôt Laval" }.unwrap("résumé de Laval")
        try expectEqual(lavalSummary.nearestDays, 48, "48 jours")
        try expectEqual(lavalSummary.licenseLevel, .warning, "orange")
        try expectEqual(overview.alertingLicenses.map(\.license.key).prefix(3), ["industrial_db", "ips", "forticare.hardware"], "les plus urgentes d’abord (à égalité, par site)")
        try expectEqual(overview.licenses.last?.level, .notLicensed, "sans licence à la fin")
        try expect(overview.notes.contains("Entrepôt Laval\u{00A0}: Licences FortiGuard\u{00A0}: test."), "notes préfixées du site")
        try expectEqual(FirmwareAnalysis.alertText(fgt), "FGT-SIEGE (FortiGate)\u{00A0}: v7.2.8 → v7.2.10", "texte d'alerte")
        try expect(FirmwareAnalysis.advice(fgt).contains("v7.2.8 → v7.2.9 → v7.2.10"), "conseil avec le chemin")
    }

    suite.add("Firmware : sondes « Licence bientôt expirée » et « Firmware pas à jour »") {
        let report = try await FortiGateReader(transport: FirmwareFixtures.transport()).readFirmware(now: now)
        let overview = FirmwareAnalysis.overview([FirmwareSiteReport(controllerID: UUID(), site: "Siège", report: report)], now: now)
        var probe = MonProbe(name: "Licences", kind: .licenseExpiring, target: "*")
        try expectEqual(MonProbe.defaultResourceLimit(.licenseExpiring), 30, "30 jours par défaut")
        try expect(probe.conditionSummary.contains("30"), "condition : \(probe.conditionSummary)")
        var context = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], inventoryReady: true, now: now)
        context.firmware = overview
        let all = await MonRunner.run(probe, context: context)
        try expect(!all.result.reachable && all.result.error?.contains("Base industrielle") == true, "expirée : panne")
        probe.target = "ips"
        let ips = await MonRunner.run(probe, context: context)
        try expect(ips.result.reachable && ips.result.problem?.contains("21") == true, "IPS dans 21 j : alerte (\(ips.result.problem ?? ""))")
        try expectEqual(ips.result.value, "IPS (prévention d’intrusion) · 21\u{00A0}j", "valeur")
        probe.resourceLimit = 14
        let quiet = await MonRunner.run(probe, context: context)
        try expect(quiet.result.reachable && quiet.result.problem == nil, "seuil 14 j : rien")
        probe.target = "Siège / antivirus"
        let run1 = await MonRunner.run(probe, context: context)
        try expect(run1.result.problem == nil, "antivirus valide")
        probe.target = "Labo / *"
        let run2 = await MonRunner.run(probe, context: context)
        try expect(run2.noData, "autre site : rien à évaluer")
        probe.target = "foo"
        let run3 = await MonRunner.run(probe, context: context)
        try expectEqual(run3.result.value, "Licence introuvable", "introuvable")

        var fw = MonProbe(name: "Firmware", kind: .firmwareOutdated, target: "*")
        let outdated = await MonRunner.run(fw, context: context)
        try expect(outdated.result.reachable && outdated.result.problem?.contains("FGT-SIEGE") == true, "alerte FortiGate")
        try expectEqual(outdated.result.value, "3 à mettre à jour sur 6", "valeur")
        fw.target = "FSW-ENTREPOT"
        let fine = await MonRunner.run(fw, context: context)
        try expect(fine.result.problem == nil && fine.result.value == "v7.2.5 · à jour", "switch à jour : \(fine.result.value)")
        fw.target = "FortiAP"
        let run4 = await MonRunner.run(fw, context: context)
        try expect(run4.result.problem?.contains("AP-ENTREPOT") == true, "famille FortiAP")

        var pending = MonRunContext(pinger: nil, snmpCommunity: nil, devices: [], inventoryReady: true, now: now)
        let run5 = await MonRunner.run(fw, context: pending)
        try expect(run5.noData, "en attente d'une lecture")
        pending.firmwareError = "Jeton absent."
        let run6 = await MonRunner.run(fw, context: pending)
        try expectEqual(run6.result.value, "Lecture impossible", "erreur dite")
        context.firmwareSiteErrors = ["Laval": "HTTP 403"]
        fw.target = "Laval / *"
        let run7 = await MonRunner.run(fw, context: context)
        try expect(run7.result.error?.contains("403") == true, "site en erreur dit")

        let nav = NavResolver.primary(.probe(NavProbeRef(probe)), in: NavContext(activeSiteKey: "x"))
        try expectEqual(nav.destination, NavDestination(.outils, focus: .tool("firmware")), "double-clic : l'outil Firmware et licences")
    }

    suite.add("Firmware : drapeau du rapport, problèmes et section facultative") {
        let report = try await FortiGateReader(transport: FirmwareFixtures.transport()).readFirmware(now: now)
        let overview = FirmwareAnalysis.overview([FirmwareSiteReport(controllerID: UUID(), site: "Siège", report: report)], now: now)
        let switches = ReportFirmware.flag([ReportSwitch(name: "FSW-QUAI", model: "FS-124F-POE", ip: "10.255.1.3", activePorts: 20, totalPorts: 24),
                                            ReportSwitch(name: "fsw-entrepot", model: "FS-248E-POE", ip: "10.255.1.2", activePorts: 40, totalPorts: 48,
                                                         firmware: "7.2.5"),
                                            ReportSwitch(name: "SW-CORE-01", model: "Catalyst", ip: "10.182.122.2", activePorts: 30, totalPorts: 48)],
                                           with: overview)
        try expect(switches[0].firmwareOutdated && switches[0].firmware == "v7.2.3", "FSW-QUAI : drapeau et version remplis")
        try expect(!switches[1].firmwareOutdated && switches[1].firmware == "7.2.5", "FSW-ENTREPOT : à jour, version gardée")
        try expect(!switches[2].firmwareOutdated, "switch hors parc Fortinet intact")

        let problems = ReportFirmware.problems(overview)
        try expect(problems.contains { $0.key == "licence|Siège|industrial_db" && $0.severity == .eleve }, "licence expirée : élevé")
        try expect(problems.contains { $0.key == "licence|Siège|ips" && $0.severity == .moyen }, "IPS sous 30 j : moyen")
        try expect(problems.contains { $0.title == "Firmware FGT-SIEGE v7.2.8" && $0.recommendation.contains("v7.2.10") }, "firmware signalé")

        var input = ReportInput(devices: [], switches: switches, now: now)
        input.firmware = overview
        input.extraProblems = problems
        let config = ReportConfig(template: .audit, sections: [.resume, .firmware, .switchs, .problemes])
        let doc = ReportBuilder.build(config: config, input: input)
        let section = try doc.sections.first { $0.kind == .firmware }.unwrap("section présente")
        try expect(section.heading.hasSuffix("Firmware et licences"), "titre")
        try expect(section.blocks.count >= 5, "texte, chiffres, équipements, licences, conseils")
        let fsw = doc.problems.filter { $0.title.contains("FSW-QUAI") }
        try expectEqual(fsw.count, 1, "un seul problème pour FSW-QUAI (drapeau et lecture)")
        try expect(!ReportTemplate.allCases.contains { $0.defaultSections.contains(.firmware) }, "facultative : aucun modèle ne la coche")
        let none = ReportBuilder.build(config: config, input: ReportInput(devices: [], now: now)).sections.first { $0.kind == .firmware }
        if case .note(let text)? = none?.blocks.first {
            try expect(text.contains("Firmware et licences"), "sans lecture : la marche à suivre")
        } else {
            throw TestFailure(message: "note attendue", file: #fileID, line: #line)
        }
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
