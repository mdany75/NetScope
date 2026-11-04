import Foundation
import NetScopeCore

// Note 29 : relecture automatique. Planificateur (prochain moment, pauses, délai croissant,
// dédoublonnage), réglage par site, switchs SNMP relus et textes. Données fixes, aucun réseau.

func registerAutoRefreshTests(_ suite: TestSuite) {
    let t0 = Date(timeIntervalSince1970: 1_793_800_000)
    let five = AutoRefreshInterval.five
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    func tracks(_ fortiGate: AutoRefreshTrack? = AutoRefreshTrack(), wifi: AutoRefreshTrack? = AutoRefreshTrack(),
                snmp: AutoRefreshTrack? = AutoRefreshTrack()) -> [AutoRefreshPart: AutoRefreshTrack] {
        var result: [AutoRefreshPart: AutoRefreshTrack] = [:]
        result[.fortiGate] = fortiGate
        result[.wifi] = wifi
        result[.snmp] = snmp
        return result
    }

    // MARK: Prochain moment

    suite.add("Relecture auto : rien au lancement, première relecture un intervalle après le début du suivi") {
        let all = tracks()
        try expectEqual(AutoRefreshPlanner.decide(now: at(0), interval: five, anchor: t0, conditions: .init(), tracks: all),
                        .wait(until: at(5), retrying: false, failures: 0), "attente de 5 min au départ")
        try expectEqual(AutoRefreshPlanner.decide(now: at(5), interval: five, anchor: t0, conditions: .init(), tracks: all),
                        .read([.fortiGate, .wifi, .snmp]), "les trois parties relues ensemble à 5 min")
    }

    suite.add("Relecture auto : la prochaine part de la dernière lecture réussie") {
        var fg = AutoRefreshTrack()
        fg.begin(at: at(5))
        fg.succeed(at: at(5.2))
        try expectEqual(AutoRefreshPlanner.nextDue(fg, interval: five.seconds, anchor: t0), at(10.2), "5 min après la lecture")
        let decision = AutoRefreshPlanner.decide(now: at(7), interval: five, anchor: t0, conditions: .init(),
                                                 tracks: tracks(fg, wifi: nil, snmp: nil))
        try expectEqual(decision, .wait(until: at(10.2), retrying: false, failures: 0), "prochaine à 10 min 12 s")
        try expectEqual(AutoRefreshText.status(lastRead: fg.lastRead, decision: decision, reading: false, now: at(7)),
                        "Relu il y a 2\u{00A0}min · prochaine dans 4\u{00A0}min", "texte de l’indication")
    }

    suite.add("Relecture auto : une partie due dans les 30 s est relue dans la même tournée") {
        var snmp = AutoRefreshTrack()
        snmp.observeRead(at: at(0.4))   // relu 24 s après le début du suivi
        let decision = AutoRefreshPlanner.decide(now: at(5), interval: five, anchor: t0, conditions: .init(),
                                                 tracks: tracks(wifi: nil, snmp: snmp))
        try expectEqual(decision, .read([.fortiGate, .snmp]), "SNMP (dû dans 24 s) joint à la FortiGate")
        var late = AutoRefreshTrack()
        late.observeRead(at: at(2))
        try expectEqual(AutoRefreshPlanner.decide(now: at(5), interval: five, anchor: t0, conditions: .init(),
                                                  tracks: tracks(wifi: nil, snmp: late)),
                        .read([.fortiGate]), "SNMP relu il y a 3 min attend son tour")
    }

    suite.add("Relecture auto : un essai abandonné ne relance pas de boucle") {
        var fg = AutoRefreshTrack()
        fg.begin(at: at(5))
        fg.cancel()
        try expectEqual(AutoRefreshPlanner.nextDue(fg, interval: five.seconds, anchor: t0), at(10), "un intervalle après l’essai")
    }

    // MARK: Pauses

    suite.add("Relecture auto : pauses (désactivée, site non actif, veille, hors réseau, scan, réveil)") {
        let all = tracks()
        func decide(_ c: AutoRefreshConditions, _ interval: AutoRefreshInterval = .five) -> AutoRefreshDecision {
            AutoRefreshPlanner.decide(now: at(20), interval: interval, anchor: t0, conditions: c, tracks: all)
        }
        try expectEqual(decide(.init(), .off), .paused(.disabled), "désactivée")
        try expectEqual(decide(.init(siteIsActive: false)), .paused(.notActiveSite), "site non actif")
        try expectEqual(decide(.init(asleep: true)), .paused(.asleep), "Mac en veille")
        try expectEqual(decide(.init(online: false)), .paused(.offline), "hors réseau")
        try expectEqual(decide(.init(scanning: true)), .paused(.scanning), "scan en cours")
        try expectEqual(decide(.init(resumeAfter: at(20.25))), .paused(.resuming(until: at(20.25))), "délai après le réveil")
        try expectEqual(decide(.init(resumeAfter: at(19))), .read([.fortiGate, .wifi, .snmp]), "délai écoulé : relecture")
        // La veille passe avant le scan (un scan ne tourne pas Mac endormi, mais l'ordre reste stable).
        try expectEqual(decide(.init(scanning: true, asleep: true)), .paused(.asleep), "veille prioritaire")
        try expectEqual(AutoRefreshPlanner.wakeUp(after: .paused(.scanning), now: at(20)), at(20.5), "réévaluée 30 s plus tard")
    }

    suite.add("Relecture auto : rien à relire, ou action requise (jeton, certificat)") {
        let none = tracks(AutoRefreshTrack(available: false), wifi: AutoRefreshTrack(available: false), snmp: AutoRefreshTrack(available: false))
        try expectEqual(AutoRefreshPlanner.decide(now: at(9), interval: five, anchor: t0, conditions: .init(), tracks: none),
                        .paused(.nothingToRead), "aucune FortiGate prête ni switch SNMP")
        let blocked = tracks(AutoRefreshTrack(blockedReason: "jeton absent"), wifi: AutoRefreshTrack(blockedReason: "jeton absent"), snmp: nil)
        try expectEqual(AutoRefreshPlanner.decide(now: at(9), interval: five, anchor: t0, conditions: .init(), tracks: blocked),
                        .paused(.needsAttention("jeton absent")), "aucun essai tant que le jeton manque")
        let mixed = tracks(AutoRefreshTrack(blockedReason: "jeton absent"), wifi: nil, snmp: AutoRefreshTrack())
        try expectEqual(AutoRefreshPlanner.decide(now: at(9), interval: five, anchor: t0, conditions: .init(), tracks: mixed),
                        .read([.snmp]), "les switchs SNMP restent relus")
    }

    // MARK: Délai croissant

    suite.add("Relecture auto : délai croissant après une erreur, plafonné à 1 h, oublié après une réussite") {
        try expectEqual(AutoRefreshPlanner.backoff(failures: 0, interval: 300), 300, "sans erreur : l’intervalle")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 1, interval: 300), 600, "1 erreur : 10 min")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 2, interval: 300), 1200, "2 erreurs : 20 min")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 3, interval: 300), 2400, "3 erreurs : 40 min")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 4, interval: 300), 3600, "plafond : 1 h")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 400, interval: 300), 3600, "pas de débordement")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 1, interval: 60), 120, "1 min : 2 min")
        try expectEqual(AutoRefreshPlanner.backoff(failures: 3, interval: 1800), 3600, "30 min : jamais moins que l’intervalle")

        var fg = AutoRefreshTrack()
        fg.begin(at: at(5))
        fg.fail(at: at(5.1))
        fg.begin(at: at(15))
        fg.fail(at: at(15.1))
        try expectEqual(fg.failures, 2, "deux échecs de suite")
        let decision = AutoRefreshPlanner.decide(now: at(16), interval: five, anchor: t0, conditions: .init(),
                                                 tracks: tracks(fg, wifi: nil, snmp: nil))
        try expectEqual(decision, .wait(until: at(35), retrying: true, failures: 2), "nouvel essai 20 min après le dernier")
        try expectEqual(AutoRefreshText.status(lastRead: nil, decision: decision, reading: false, now: at(16)),
                        "Pas encore relu · erreur, nouvel essai dans 19\u{00A0}min", "texte en erreur")
        // Une lecture réussie au bouton « Relire » efface le délai.
        fg.observeRead(at: at(17))
        try expectEqual(fg.failures, 0, "réussite : délai oublié")
        try expectEqual(AutoRefreshPlanner.nextDue(fg, interval: five.seconds, anchor: t0), at(22), "5 min après la lecture au bouton")
    }

    suite.add("Relecture auto : une FortiGate en erreur n’empêche pas les switchs SNMP") {
        var fg = AutoRefreshTrack()
        fg.begin(at: at(5))
        fg.fail(at: at(5))
        var snmp = AutoRefreshTrack()
        snmp.observeRead(at: at(5))
        let decision = AutoRefreshPlanner.decide(now: at(10), interval: five, anchor: t0, conditions: .init(),
                                                 tracks: tracks(fg, wifi: nil, snmp: snmp))
        try expectEqual(decision, .read([.snmp]), "SNMP relu à son heure, la FortiGate attend 10 min")
    }

    // MARK: Dédoublonnage

    suite.add("Relecture auto : une lecture faite ailleurs (bouton, scan, Surveillance) repousse la suivante") {
        var wifi = AutoRefreshTrack()
        wifi.observeRead(at: at(4))       // sonde FortiAP de la Surveillance
        var fg = AutoRefreshTrack()
        fg.observeRead(at: at(4.5))       // « Relire la FortiGate »
        let decision = AutoRefreshPlanner.decide(now: at(5), interval: five, anchor: t0, conditions: .init(),
                                                 tracks: tracks(fg, wifi: wifi, snmp: nil))
        try expectEqual(decision, .wait(until: at(9), retrying: false, failures: 0), "pas de relecture en double à 5 min")
        // Une lecture plus ancienne ne recule pas la dernière.
        wifi.observeRead(at: at(1))
        try expectEqual(wifi.lastRead, at(4), "la plus récente reste")
    }

    suite.add("Relecture auto : une seule lecture à la fois par FortiGate") {
        var wifi = AutoRefreshTrack()
        wifi.inFlight = true             // la Surveillance lit les bornes
        let busy = tracks(AutoRefreshTrack(), wifi: wifi, snmp: AutoRefreshTrack())
        try expectEqual(AutoRefreshPlanner.decide(now: at(6), interval: five, anchor: t0, conditions: .init(), tracks: busy),
                        .read([.snmp]), "la FortiGate attend la fin de la lecture des bornes ; SNMP n’attend pas")
        var fg = AutoRefreshTrack()
        fg.inFlight = true
        let onlyForti = tracks(fg, wifi: AutoRefreshTrack(), snmp: nil)
        try expectEqual(AutoRefreshPlanner.decide(now: at(6), interval: five, anchor: t0, conditions: .init(), tracks: onlyForti),
                        .wait(until: at(6.25), retrying: false, failures: 0), "nouveau coup d’œil 15 s plus tard")
        try expectEqual(AutoRefreshText.status(lastRead: at(1), decision: .wait(until: at(6.25), retrying: false, failures: 0),
                                               reading: true, now: at(6)),
                        "Relu il y a 5\u{00A0}min · relecture en cours…", "lecture en cours affichée")
    }

    // MARK: Réglage par site

    suite.add("Relecture auto : intervalle par site, 5 min par défaut, valeurs inconnues ramenées") {
        var settings = AutoRefreshSettings()
        try expectEqual(settings.interval(forSiteKey: "A"), .five, "défaut : 5 min")
        settings.set(.off, forSiteKey: "A")
        settings.set(.fifteen, forSiteKey: "B")
        try expectEqual(settings.interval(forSiteKey: "A"), .off, "site A désactivé")
        try expectEqual(settings.interval(forSiteKey: "B"), .fifteen, "site B : 15 min")
        try expect(settings.isCustom("B") && !settings.isCustom("C"), "réglage propre ou par défaut")
        let decoded = AutoRefreshSettings.decode(settings.encoded())
        try expectEqual(decoded, settings, "aller-retour JSON")
        let odd = AutoRefreshSettings.decode(Data(#"{"intervals":{"X":3,"Y":90,"Z":-4}}"#.utf8))
        try expectEqual(odd.interval(forSiteKey: "X"), .five, "3 min → 5 min (jamais plus souvent que demandé)")
        try expectEqual(odd.interval(forSiteKey: "Y"), .thirty, "90 min → 30 min")
        try expectEqual(odd.interval(forSiteKey: "Z"), .off, "négatif → désactivée")
        try expectEqual(AutoRefreshSettings.decode(Data("pas du JSON".utf8)), AutoRefreshSettings(), "illisible : défaut")
        settings.set(.two, forSiteKey: SiteFiles.noSiteKey)
        settings.prune(keeping: ["B"])
        try expect(!settings.isCustom("A") && settings.isCustom("B") && settings.isCustom(SiteFiles.noSiteKey),
                   "site supprimé oublié, « sans site » gardé")
        try expectEqual(AutoRefreshInterval.allCases.map(\.rawValue), [0, 1, 2, 5, 10, 15, 30], "choix proposés")
        try expectEqual(AutoRefreshInterval.one.menuLabel, "Toutes les minutes", "libellé de menu")
        try expectEqual(AutoRefreshInterval.ten.label, "10\u{00A0}min", "libellé court")
    }

    // MARK: Switchs SNMP relus

    suite.add("Relecture auto : jamais de relecture SNMP d’un switch d’un autre site") {
        let siege = Site(name: "Siège", ranges: [ScanRangeConfig(text: "10.0.0.0/24", label: "")], switchHosts: ["10.0.0.2"])
        let client = Site(name: "Client B", ranges: [ScanRangeConfig(text: "10.0.0.0/24", label: "")], switchHosts: ["10.0.0.3"])
        let sites = [siege, client]
        let siegeKey = SiteFiles.key(for: siege.id)
        let hosts = ["10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.255.1.2", "10.0.0.2", "pas-une-ip"]
        let readings = ["10.0.0.4": siegeKey, "10.0.0.5": SiteFiles.key(for: client.id), "10.0.0.3": siegeKey]
        let chosen = AutoRefreshTargets.snmpHosts(hosts, controllerHosts: ["10.255.1.2"], activeSite: siege, sites: sites,
                                                  readingSites: readings, scanRanges: [])
        try expectEqual(chosen, ["10.0.0.2", "10.0.0.4"],
                        "switch associé et switch sans site relevé ici ; ni celui de Client B, ni celui relevé chez lui, ni FortiSwitch")
        let other = AutoRefreshTargets.snmpHosts(hosts, controllerHosts: [], activeSite: client, sites: sites,
                                                 readingSites: readings, scanRanges: [])
        try expectEqual(other, ["10.0.0.3", "10.0.0.5"], "côté Client B : les siens seulement")
        // Sans site actif : switch sans site, relevé sans site, dans les plages du dernier scan.
        let free = ["10.0.0.4": SiteFiles.noSiteKey, "192.168.1.2": SiteFiles.noSiteKey, "10.0.0.2": SiteFiles.noSiteKey]
        let none = AutoRefreshTargets.snmpHosts(["10.0.0.4", "192.168.1.2", "10.0.0.2"], controllerHosts: [], activeSite: nil,
                                                sites: sites, readingSites: free, scanRanges: [try IPRange(parsing: "10.0.0.0/24")])
        try expectEqual(none, ["10.0.0.4"], "hors des plages scannées ou associé à un site : écarté")
        let noScan = AutoRefreshTargets.snmpHosts(["10.0.0.4"], controllerHosts: [], activeSite: nil, sites: sites,
                                                  readingSites: free, scanRanges: [])
        try expect(noScan.isEmpty, "sans site ni scan : rien")
    }

    // MARK: Textes

    suite.add("Relecture auto : textes « il y a » et « dans »") {
        try expectEqual(AutoRefreshText.ago(at(0), now: at(0.5)), "à l’instant", "30 s")
        try expectEqual(AutoRefreshText.ago(at(0), now: at(2)), "il y a 2\u{00A0}min", "2 min")
        try expectEqual(AutoRefreshText.ago(at(0), now: at(65)), "il y a 1\u{00A0}h\u{00A0}05", "1 h 05")
        try expectEqual(AutoRefreshText.ago(at(0), now: at(120)), "il y a 2\u{00A0}h", "2 h")
        try expectEqual(AutoRefreshText.ago(at(0), now: at(3 * 1440 + 5)), "il y a 3\u{00A0}j", "3 j")
        try expectEqual(AutoRefreshText.until(at(3), now: at(2.5)), "dans moins d’une minute", "30 s")
        try expectEqual(AutoRefreshText.until(at(3), now: at(0)), "dans 3\u{00A0}min", "3 min")
        try expectEqual(AutoRefreshText.until(at(2.1), now: at(0)), "dans 3\u{00A0}min", "arrondi vers le haut")
        try expectEqual(AutoRefreshText.until(at(90), now: at(0)), "dans 1\u{00A0}h\u{00A0}30", "1 h 30")
        try expectEqual(AutoRefreshText.status(lastRead: at(0), decision: .paused(.scanning), reading: false, now: at(2)),
                        "Relu il y a 2\u{00A0}min · en pause pendant le scan", "pause")
        try expectEqual(AutoRefreshText.status(lastRead: nil, decision: .paused(.disabled), reading: false, now: at(2)),
                        "Pas encore relu · relecture automatique désactivée", "désactivée")
    }
}
