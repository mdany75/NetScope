import Foundation
import NetScopeCore

// 0.15.0, notes 49, 48 et 45 : sélecteur de site sous le logo (recherche, pastille de la
// FortiGate, titre de la fenêtre), Switchs et Wi-Fi d'un autre site sans changer le site actif
// (jamais de mélange entre deux sites aux mêmes adresses), suite des sauts entre modules, nom de
// l'écran d'origine du bouton Retour, raccourci ⌘⇧S. Données fixes, aucun réseau.

func registerSiteBrowseTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    let fgSiege = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000001")!
    let fgLaval = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000002")!
    let fgLaval2 = UUID(uuidString: "0B9C1D3E-1A11-4F0A-9C10-5EE3A0000009")!

    let siege = Site(name: "Siège", notes: "Bureaux et salle des serveurs",
                     ranges: [ScanRangeConfig(text: "10.182.122.0/24", label: "Bureau", vlan: 1)],
                     fortiGateIDs: [fgSiege], switchHosts: ["10.182.122.2"])
    let laval = Site(name: "Entrepôt Laval",
                     ranges: [ScanRangeConfig(text: "10.20.0.0/24", label: "Bureaux", vlan: 1),
                              ScanRangeConfig(text: "10.20.40.0/24", label: "Caméras", vlan: 40)],
                     fortiGateIDs: [fgLaval], switchHosts: ["10.20.0.2"])
    let quebec = Site(name: "Bureau Québec", ranges: [ScanRangeConfig(text: "192.168.1.0/24", label: "Invités", vlan: 99)])
    // Même plage que Québec : un autre client.
    let clinique = Site(name: "Clinique Exemple", ranges: [ScanRangeConfig(text: "192.168.1.0/24", label: "Postes", vlan: 1)])
    let siegeKey = SiteFiles.key(for: siege.id)
    let lavalKey = SiteFiles.key(for: laval.id)

    func snmp(_ host: String, _ name: String) -> SNMPSwitchSnapshot {
        let ports = (1...8).map { SNMPInterface(index: $0, name: "\($0)", descr: "\($0)", alias: "", operStatus: $0 <= 3 ? .up : .down, speedMbps: 1000) }
        return SNMPSwitchSnapshot(host: IPv4Address(host)!, system: SNMPSystemInfo(name: name, descr: "Cisco IOS Software, C2960X", objectID: "1.3.6.1.4.1.9", location: "Baie"),
                                  interfaces: ports, polledAt: now)
    }
    func fortiReport(_ hostname: String, switches: [(String, String)]) -> FortiGateReport {
        let system = FortiGateSystem(hostname: hostname, model: "FortiGate-60F", serial: "FGT60F\(hostname)", version: "v7.2.8")
        let list = switches.map { name, ip in
            FortiManagedSwitch(switchID: name, serial: "S\(name)", name: name, model: "FS-124F", connected: true, state: "Authorized",
                               fortilinkIP: IPv4Address(ip),
                               ports: (1...4).map { FortiSwitchPort(name: "port\($0)", number: $0, linkUp: $0 == 1, adminUp: true) })
        }
        return FortiGateReport(system: system, switches: list, readAt: now)
    }

    // MARK: Sélecteur (note 49)

    suite.add("Sélecteur de site : recherche par nom sans accents, plage, libellé et VLAN") {
        let all = [laval, quebec, clinique, siege]
        try expectEqual(SitePicker.filter(all, query: "").count, 4, "recherche vide : tous")
        try expectEqual(SitePicker.filter(all, query: "quebec").map(\.name), ["Bureau Québec"], "sans accent")
        try expectEqual(SitePicker.filter(all, query: "SIÈGE").map(\.name), ["Siège"], "majuscules et accents")
        try expectEqual(SitePicker.filter(all, query: "10.20").map(\.name), ["Entrepôt Laval"], "par plage")
        try expectEqual(SitePicker.filter(all, query: "vlan 40").map(\.name), ["Entrepôt Laval"], "par VLAN")
        try expectEqual(SitePicker.filter(all, query: "caméras").map(\.name), ["Entrepôt Laval"], "par libellé")
        try expectEqual(SitePicker.filter(all, query: "serveurs").map(\.name), ["Siège"], "par les notes")
        // Deux sites aux mêmes plages : les deux sont proposés, jamais un seul « par l'IP ».
        try expectEqual(Set(SitePicker.filter(all, query: "192.168.1").map(\.name)), ["Bureau Québec", "Clinique Exemple"], "mêmes plages")
        try expectEqual(SitePicker.filter(all, query: "192.168.1 postes").map(\.name), ["Clinique Exemple"], "tous les mots")
        try expect(SitePicker.filter(all, query: "inconnu").isEmpty, "aucun site")
    }

    suite.add("Sélecteur de site : flèches et sous-titre de la fenêtre") {
        let ids = [siege.id, laval.id, quebec.id]
        try expectEqual(SitePicker.step(from: nil, in: ids, by: 1), siege.id, "↓ sans ligne : la première")
        try expectEqual(SitePicker.step(from: nil, in: ids, by: -1), quebec.id, "↑ sans ligne : la dernière")
        try expectEqual(SitePicker.step(from: siege.id, in: ids, by: 1), laval.id, "↓")
        try expectEqual(SitePicker.step(from: quebec.id, in: ids, by: 1), quebec.id, "bord bas")
        try expectEqual(SitePicker.step(from: siege.id, in: ids, by: -1), siege.id, "bord haut")
        try expectEqual(SitePicker.step(from: UUID(), in: ids, by: 1), siege.id, "ligne disparue (recherche)")
        try expect(SitePicker.step(from: nil, in: [], by: 1) == nil, "liste vide")
        try expectEqual(SitePicker.windowSubtitle(activeName: "Siège"), "Site\u{00A0}: Siège", "site actif")
        try expectEqual(SitePicker.windowSubtitle(activeName: nil), "Aucun site (plages libres)", "plages libres")
        try expectEqual(SitePicker.windowSubtitle(activeName: "  "), "Aucun site (plages libres)", "nom vide")
    }

    suite.add("Sélecteur de site : pastille de la FortiGate (jointe, injoignable, jamais lue, aucune)") {
        try expectEqual(SiteLinkState.evaluate([]), .noFortiGate, "aucune FortiGate")
        let read = now.addingTimeInterval(-120)
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "Siège", readAt: read)]), .joined(read), "lue cette session")
        let saved = FortiControllerStatus(kind: .ok, date: now.addingTimeInterval(-3_600))
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "Siège", status: saved)]), .joined(saved.date), "dernier état enregistré")
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "Québec", error: "Jeton absent.")]), .problem("Jeton absent."), "erreur")
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "Q", status: FortiControllerStatus(kind: .missingToken))]),
                        .problem("jeton absent"), "jeton absent enregistré, sans message")
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "Q", status: FortiControllerStatus(kind: .untested))]), .notRead, "jamais testée")
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "Q", isEnabled: false, readAt: read)]),
                        .problem("lecture désactivée"), "désactivée")
        // Une lecture réussie cette session l'emporte sur une erreur d'une autre FortiGate du site.
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "A", error: "Accès refusé"),
                                                SiteFortiGateProbe(name: "B", readAt: read)]), .joined(read), "une sur deux")
        // Erreur récente après une lecture réussie : la FortiGate ne répond plus.
        try expectEqual(SiteLinkState.evaluate([SiteFortiGateProbe(name: "A", readAt: read, error: "Délai dépassé")]),
                        .problem("Délai dépassé"), "erreur après lecture")
        try expectEqual(SiteLinkState.joined(nil).label, "FortiGate jointe", "libellé")
        try expect(SiteLinkState.joined(read).help(time: { _ in "14:02" }).contains("lue à 14:02"), "heure dans l'aide")
    }

    // MARK: Switchs d'un autre site (note 48)

    suite.add("Switchs par site : FortiSwitch de SES FortiGate, SNMP relevés pour CE site seulement") {
        let reports = [
            FortiSiteReport(controllerID: fgSiege, site: "Siège", report: fortiReport("FGT-SIEGE", switches: [("FSW-ENTREPOT", "10.255.1.2")])),
            FortiSiteReport(controllerID: fgLaval, site: "Entrepôt Laval", report: fortiReport("FGT-LAVAL", switches: [("FSW-LAVAL-01", "10.255.1.2"), ("FSW-LAVAL-02", "10.255.1.3")])),
        ]
        let readings = [
            SiteSNMPReading(snapshot: snmp("10.20.0.2", "SW-LAVAL-CORE"), siteKey: lavalKey),
            SiteSNMPReading(snapshot: snmp("10.182.122.2", "SW-CORE-01"), siteKey: siegeKey),
            // Même adresse que le switch de Laval, relevée au Siège : un autre switch, jamais montré à Laval.
            SiteSNMPReading(snapshot: snmp("10.20.0.2", "SW-AUTRE-CLIENT"), siteKey: siegeKey),
            // Dans les plages de Laval, mais relevé on ne sait pour quel site.
            SiteSNMPReading(snapshot: snmp("10.20.0.3", "SW-INCONNU"), siteKey: nil),
        ]
        let view = SiteSwitchBrowse.view(site: laval, siteKey: lavalKey, fortiReports: reports, snmp: readings)
        try expectEqual(view.entries.map(\.name), ["FSW-LAVAL-01", "FSW-LAVAL-02", "SW-LAVAL-CORE"], "switchs de Laval seulement")
        try expect(view.entries.allSatisfy { $0.siteKey == lavalKey && $0.siteName == "Entrepôt Laval" }, "marqués de leur site")
        try expectEqual(view.entries.first?.source, .fortiGate("Entrepôt Laval"), "source FortiGate")
        try expectEqual(view.entries.last?.source, .snmp, "source SNMP")
        try expect(view.emptyMessage == nil, "rien à expliquer")
        try expect(view.notes.isEmpty, "rien à signaler")
        try expectEqual(view.fortiGatesToRead, [fgLaval], "FortiGate à relire")
        // Même adresse FortiLink sur deux sites : deux lignes distinctes.
        let siegeView = SiteSwitchBrowse.view(site: siege, siteKey: siegeKey, fortiReports: reports, snmp: readings)
        try expectEqual(siegeView.entries.map(\.name), ["FSW-ENTREPOT", "SW-CORE-01"], "switchs du Siège")
        let ids = Set((view.entries + siegeView.entries).map(\.id))
        try expectEqual(ids.count, 5, "identifiants « site|adresse » uniques")
    }

    suite.add("Switchs par site : messages clairs (ni FortiGate ni switch, non lue, aucun FortiSwitch, SNMP sur place)") {
        let nothing = SiteSwitchBrowse.view(site: clinique, siteKey: "c", fortiReports: [], snmp: [])
        try expect(nothing.entries.isEmpty, "vide")
        try expect(nothing.emptyMessage?.contains("ni FortiGate ni switch SNMP") == true, "ni FortiGate ni switch")
        let unread = SiteSwitchBrowse.view(site: laval, siteKey: lavalKey, fortiReports: [], fortiGateNames: [fgLaval: "FGT Laval"], snmp: [])
        try expect(unread.emptyMessage?.contains("lisez sa FortiGate") == true, "FortiGate pas encore lue")
        try expect(unread.notes.contains { $0.contains("10.20.0.2") && $0.contains("sur place") }, "switch SNMP associé jamais relevé pour ce site")
        try expect(!unread.notes.contains { $0.contains("pas encore lue") }, "pas de doublon avec le message")
        let none = SiteSwitchBrowse.view(site: laval, siteKey: lavalKey,
                                         fortiReports: [FortiSiteReport(controllerID: fgLaval, site: "Laval", report: fortiReport("FGT-LAVAL", switches: []))],
                                         snmp: [])
        try expect(none.emptyMessage?.contains("ne gère aucun FortiSwitch") == true, "aucun FortiSwitch")
        // Deux FortiGate, une seule lue : remarque nommée.
        var twoGates = laval
        twoGates.fortiGateIDs = [fgLaval, fgLaval2]
        let partial = SiteSwitchBrowse.view(site: twoGates, siteKey: lavalKey,
                                            fortiReports: [FortiSiteReport(controllerID: fgLaval, site: "Laval", report: fortiReport("FGT-LAVAL", switches: [("FSW-A", "10.255.1.2")]))],
                                            fortiGateNames: [fgLaval2: "FGT Laval 2"], snmp: [])
        try expect(partial.notes.contains("FortiGate pas encore lue\u{00A0}: FGT Laval 2."), "FortiGate non lue nommée")
        // Une lecture d'une FortiGate d'un autre site n'est jamais prise.
        let foreign = SiteSwitchBrowse.view(site: laval, siteKey: lavalKey,
                                            fortiReports: [FortiSiteReport(controllerID: fgSiege, site: "Siège", report: fortiReport("FGT-SIEGE", switches: [("FSW-X", "10.255.1.9")]))],
                                            snmp: [])
        try expect(foreign.entries.isEmpty, "FortiGate d'un autre site ignorée")
    }

    suite.add("Switchs par site : recherche commune (préfixes, exclusion) et saut vers un switch par son nom") {
        let entry = SiteSwitchEntry(siteKey: lavalKey, siteName: "Entrepôt Laval", snapshot: snmp("10.20.0.2", "SW-LAVAL-CORE"), source: .snmp)
        try expect(entry.matches(""), "recherche vide")
        try expect(entry.matches("laval core"), "mots libres")
        try expect(entry.matches("site:entrepot switch:sw-laval"), "préfixes")
        try expect(entry.matches("10.20.0"), "adresse")
        try expect(!entry.matches("-cisco"), "exclusion")
        try expect(!entry.matches("siège"), "autre site")
        try expect(entry.answers(to: "10.20.0.2"), "par adresse")
        try expect(entry.answers(to: "sw-laval-core"), "par nom, sans casse")
        try expect(!entry.answers(to: ""), "vide")
    }

    // MARK: Wi-Fi d'un autre site (note 48)

    suite.add("Wi-Fi par site : lectures de SES FortiGate, renommées d'après le site, sans fusion entre sites") {
        let mac = MACAddress("3C:22:FB:7E:05:B1")!
        let siegeReport = FortiWifiSiteReport(controllerID: fgSiege, site: "FGT-SIEGE",
                                              report: FortiWifiReport(aps: [FortiManagedAP(name: "AP-ACCUEIL", serial: "FP231F1")],
                                                                      clients: [FortiWifiClient(mac: mac, ssid: "Bureau", apName: "AP-ACCUEIL")], readAt: now))
        let lavalReport = FortiWifiSiteReport(controllerID: fgLaval, site: "FGT-LAVAL",
                                              report: FortiWifiReport(aps: [FortiManagedAP(name: "AP-QUAI", serial: "FP231F2")],
                                                                      clients: [FortiWifiClient(mac: mac, ssid: "Quai", apName: "AP-QUAI")], readAt: now))
        let cache = [fgSiege: siegeReport, fgLaval: lavalReport]
        let lavalReports = SiteWifiBrowse.reports(site: laval, cache: cache)
        try expectEqual(lavalReports.map(\.site), ["Entrepôt Laval"], "nom du site, pas de la FortiGate")
        try expectEqual(lavalReports.map(\.controllerID), [fgLaval], "seulement sa FortiGate")
        var twoGates = laval
        twoGates.fortiGateIDs = [fgLaval, fgSiege]
        try expectEqual(SiteWifiBrowse.reports(site: twoGates, fortiGateNames: [fgLaval: "FGT-1", fgSiege: "FGT-2"], cache: cache).map(\.site),
                        ["Entrepôt Laval · FGT-1", "Entrepôt Laval · FGT-2"], "plusieurs FortiGate : site · FortiGate")
        let overview = SiteWifiBrowse.overview(perSite: [SiteWifiBrowse.reports(site: siege, cache: cache), lavalReports])
        try expectEqual(overview.sites, ["Siège", "Entrepôt Laval"], "deux sites")
        try expect(overview.isMultiSite, "colonne Site")
        try expectEqual(overview.clients.count, 2, "même MAC sur deux sites : deux clients (aucune fusion)")
        try expectEqual(Set(overview.clients.map(\.id)).count, 2, "identifiants distincts")
        try expectEqual(overview.aps.map(\.site), ["Siège", "Entrepôt Laval"], "bornes marquées de leur site")
        try expect(SiteWifiBrowse.emptyMessage(site: laval, reports: lavalReports) == nil, "rien à expliquer")
        try expect(SiteWifiBrowse.emptyMessage(site: clinique, reports: [])?.contains("pas de FortiGate") == true, "sans FortiGate")
        try expect(SiteWifiBrowse.emptyMessage(site: laval, reports: [])?.contains("pas encore été lues") == true, "non lue")
        let empty = FortiWifiSiteReport(controllerID: fgLaval, site: "x", report: FortiWifiReport(readAt: now))
        try expect(SiteWifiBrowse.emptyMessage(site: laval, reports: [empty])?.contains("aucune borne") == true, "aucune borne")
    }

    // MARK: Sauts entre modules et Retour (notes 48 et 45)

    suite.add("Navigation : l'appareil d'un autre site ouvre Switchs et ports sur SON site, jamais le switch homonyme du site actif") {
        let active = "site-actif"
        let other = "site-laval"
        // Le site actif a aussi un « SW-CORE-01 » : il ne doit pas être proposé pour l'appareil de Laval.
        let context = NavContext(activeSiteKey: active, switches: [snmp("10.182.122.2", "SW-CORE-01")])
        let ref = NavDeviceRef(ip: "10.20.0.47", mac: "B0:7B:25:20:00:07", name: "Poste expédition", siteKey: other,
                               switchName: "SW-CORE-01", switchPort: "Gi1/0/7")
        let items = NavResolver.openIn(.device(ref), in: context)
        let switchItem = try items.first { $0.destination.module == .switchs }.siteBrowseRequired("Switchs et ports proposé")
        try expectEqual(switchItem.destination.sites, .only([other]), "sur le site de l'appareil")
        try expectEqual(switchItem.destination.focus, .switchPort(host: "SW-CORE-01", port: "Gi1/0/7"), "switch par son nom, et son port")
        try expectEqual(NavSites.only([other]).siteKey, other, "site d'un seul site")
        try expectEqual(NavSites.include(other).siteKey, other, "site ajouté")
        try expect(NavSites.only([active, other]).siteKey == nil, "plusieurs sites : aucun")
        // Le même appareil sur le site actif : le switch relevé du site actif.
        let local = NavDeviceRef(ip: "10.182.122.47", name: "Poste", siteKey: active, switchName: "SW-CORE-01", switchPort: "Gi1/0/7")
        let localItem = try NavResolver.openIn(.device(local), in: context).first { $0.destination.module == .switchs }.siteBrowseRequired("site actif")
        try expect(localItem.destination.sites == nil, "site actif : rien à changer")
        try expectEqual(localItem.destination.focus, .switchPort(host: "10.182.122.2", port: "Gi1/0/7"), "switch relevé")
    }

    suite.add("Retour : nom court de l'écran d'origine, historique vidé au changement de site") {
        try expectEqual(NavModule.inventaire.shortTitle, "Inventaire", "Inventaire")
        try expectEqual(NavModule.carte.shortTitle, "Carte", "Carte")
        try expectEqual(NavModule.appareil.shortTitle, "Fiche", "fiche Appareil")
        try expectEqual(NavModule.switchs.shortTitle, "Switchs", "Switchs")
        for module in NavModule.allCases { try expect(module.shortTitle.count <= 14, "court\u{00A0}: \(module.shortTitle)") }
        var history = NavHistory(limit: 10)
        history.leave(NavLocation(.inventaire, deviceID: "10.0.0.1"))
        history.leave(NavLocation(.appareil, deviceID: "10.0.0.1"))
        try expectEqual(history.previous?.module.shortTitle, "Fiche", "le bouton nomme l'écran d'origine")
        _ = history.goBack(from: NavLocation(.switchs))
        try expect(history.canGoForward, "Avancer possible")
        history.clear()
        try expect(!history.canGoBack && !history.canGoForward, "changement de site : plus de Retour ni d'Avancer")
    }

    suite.add("Raccourci ⌘⇧S « Choisir le site » : au catalogue, sans conflit") {
        let action = try ShortcutCatalog.fixedActions.first { $0.id == ShortcutID.chooseSite }.siteBrowseRequired("au catalogue")
        try expectEqual(action.defaultCombo, KeyCombo("s", [.shift, .command]), "⌘⇧S")
        try expectEqual(action.group, .navigation, "groupe Navigation")
        let actions = ShortcutCatalog.fixedActions + ShortcutCatalog.screenActions(NavModule.allCases.map { ($0.rawValue, $0.title) })
        try expect(ShortcutSettings().conflicts(in: actions)[ShortcutID.chooseSite] == nil, "aucun conflit")
    }
}

private extension Optional {
    /// Valeur présente, sinon échec du test.
    func siteBrowseRequired(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: message, file: file, line: line) }
        return value
    }
}
