import Foundation
import NetScopeCore

// Notifications (NotificationPolicy, événements communs) et raccourcis clavier : données fixes,
// aucun réseau, aucune notification réelle.

func registerNotificationShortcutTests(_ suite: TestSuite) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!

    func at(_ hour: Int, _ minute: Int = 0, day: Int = 4) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func event(_ kind: NetScopeEventKind, title: String = "Événement", date: Date, severity: NetScopeEventSeverity? = nil,
               banner: Bool = true, sound: Bool = false) -> NetScopeEvent {
        NetScopeEvent(kind: kind, severity: severity, title: title, detail: "Détail", date: date,
                      sourceAllowsBanner: banner, sourceRequestsSound: sound)
    }

    suite.add("Notifications : heures de silence par-dessus minuit") {
        let quiet = QuietHours(isEnabled: true, start: DayMinute(hour: 22), end: DayMinute(hour: 7))
        try expect(quiet.contains(DayMinute(hour: 22)), "22:00 compris (début)")
        try expect(quiet.contains(DayMinute(hour: 23, minute: 59)), "23:59 compris")
        try expect(quiet.contains(DayMinute(hour: 0)), "minuit compris")
        try expect(quiet.contains(DayMinute(hour: 6, minute: 59)), "06:59 compris")
        try expect(!quiet.contains(DayMinute(hour: 7)), "07:00 exclu (fin)")
        try expect(!quiet.contains(DayMinute(hour: 12)), "midi exclu")
        try expectEqual(quiet.durationMinutes, 540, "durée de 22:00 à 07:00")
        let day = QuietHours(isEnabled: true, start: DayMinute(hour: 12), end: DayMinute(hour: 13, minute: 30))
        try expect(day.contains(DayMinute(hour: 13)) && !day.contains(DayMinute(hour: 11, minute: 59)), "période dans la journée")
        try expect(!QuietHours(isEnabled: true, start: DayMinute(hour: 8), end: DayMinute(hour: 8)).contains(DayMinute(hour: 8)),
                   "début = fin : période vide")
        try expect(!QuietHours(isEnabled: false).contains(DayMinute(hour: 23)), "désactivée : jamais")
        try expect(quiet.contains(at(2, 15), calendar: calendar), "date à 02:15 dans la période")
        try expectEqual(DayMinute(text: "7:05")?.text, "07:05", "lecture de « 7:05 »")
        try expect(DayMinute(text: "24:00") == nil && DayMinute(text: "abc") == nil, "heures invalides refusées")
        try expectEqual(DayMinute(-30).text, "23:30", "minutes négatives ramenées dans la journée")
    }

    suite.add("Notifications : silence, sauf événements critiques si permis") {
        var settings = NotificationSettings()
        settings.quietHours = QuietHours(isEnabled: true, start: DayMinute(hour: 22), end: DayMinute(hour: 7))
        var policy = NotificationPolicy()
        let night = NotificationContext(now: at(23, 30), calendar: calendar)
        try expectEqual(policy.decide(event(.probeWarning, date: at(23, 30)), settings: settings, context: night),
                        .suppress(.quietHours), "alerte à 23:30 : silence")
        let critical = policy.decide(event(.probeDown, date: at(23, 31)), settings: settings, context: night)
        try expect(critical.delivery?.sound == true, "critique livrée avec le son (passe outre)")
        settings.criticalBypassQuietHours = false
        try expectEqual(policy.decide(event(.rogueDHCP, date: at(23, 32)), settings: settings, context: night),
                        .suppress(.quietHours), "critique en silence si l'exception est désactivée")
        let morning = NotificationContext(now: at(7, 0, day: 5), calendar: calendar)
        try expect(policy.decide(event(.probeWarning, date: at(7, 0, day: 5)), settings: settings, context: morning).delivery != nil,
                   "07:00 le lendemain : livrée")
        let test = policy.decide(event(.test, date: at(23, 40)), settings: settings, context: night)
        try expect(test.delivery != nil, "notification de test : toujours livrée")
    }

    suite.add("Notifications : types désactivés, son, réglages de la sonde, premier plan") {
        var settings = NotificationSettings()
        var policy = NotificationPolicy()
        let context = NotificationContext(now: at(10), calendar: calendar)
        try expect(!settings.isEnabled(.scanFinished) && !settings.isEnabled(.deviceMoved), "fin de scan et déplacement désactivés par défaut")
        try expect(settings.isEnabled(.probeDown) && settings.isEnabled(.rogueDHCP), "pannes et DHCP activés par défaut")
        try expectEqual(policy.decide(event(.scanFinished, date: at(10)), settings: settings, context: context),
                        .suppress(.kindDisabled), "type désactivé")
        settings.set(.scanFinished, enabled: true)
        try expect(policy.decide(event(.scanFinished, date: at(10)), settings: settings, context: context).delivery != nil,
                   "type activé : livré")
        try expectEqual(policy.decide(event(.scanFinished, date: at(10)), settings: settings,
                                      context: NotificationContext(now: at(10), appIsActive: true, calendar: calendar)),
                        .suppress(.appActive), "fin de scan au premier plan : rien")
        // Son « Critiques » : la sonde qui demande le son l'obtient ; « Aucun » coupe tout.
        try expect(policy.decide(event(.probeWarning, date: at(10)), settings: settings, context: context).delivery?.sound == false,
                   "alerte sans son")
        try expect(policy.decide(event(.probeWarning, date: at(10), sound: true), settings: settings, context: context).delivery?.sound == true,
                   "son demandé par la sonde")
        settings.sound = .off
        try expect(policy.decide(event(.probeDown, date: at(10), sound: true), settings: settings, context: context).delivery?.sound == false,
                   "son coupé")
        settings.sound = .all
        try expect(policy.decide(event(.newDevice, date: at(10)), settings: settings, context: context).delivery?.sound == true,
                   "son pour tout")
        // Sonde sans notification mais avec son : un bip seul.
        let beep = policy.decide(event(.probeDown, date: at(10), banner: false, sound: true), settings: settings, context: context)
        try expect(beep.delivery?.banner == false && beep.delivery?.sound == true, "bip seul")
        // Sonde sans notification ni son : muette, même avec « Tous ».
        try expectEqual(policy.decide(event(.probeDown, date: at(10), banner: false, sound: false), settings: settings, context: context),
                        .suppress(.sourceDeclined), "sonde silencieuse, son « Tous »")
        settings.sound = .critical
        try expectEqual(policy.decide(event(.probeDown, date: at(10), banner: false, sound: false), settings: settings, context: context),
                        .suppress(.sourceDeclined), "sonde silencieuse, panne critique")
        try expectEqual(policy.decide(event(.probeWarning, date: at(10), banner: false), settings: settings, context: context),
                        .suppress(.sourceDeclined), "notification désactivée sur la sonde")
        settings.bannersEnabled = false
        try expectEqual(policy.decide(event(.newDevice, date: at(10)), settings: settings, context: context),
                        .suppress(.bannersDisabled), "Centre de notifications désactivé")
    }

    suite.add("Notifications : regroupement des rafales d'un même type") {
        var settings = NotificationSettings()
        settings.sound = .all
        var policy = NotificationPolicy()
        var decisions: [NotificationDelivery] = []
        for index in 0..<6 {
            let date = at(10).addingTimeInterval(TimeInterval(index * 30))
            let decision = policy.decide(event(.probeDown, title: "Sonde \(index + 1)", date: date), settings: settings,
                                         context: NotificationContext(now: date, calendar: calendar))
            guard let delivery = decision.delivery else { throw TestFailure(message: "non livrée (\(index))", file: #fileID, line: #line) }
            decisions.append(delivery)
        }
        try expectEqual(decisions.prefix(3).map(\.groupedCount), [1, 1, 1], "trois premières telles quelles")
        try expectEqual(Set(decisions.prefix(3).map(\.identifier)).count, 3, "identifiants distincts")
        let summaries = Array(decisions.suffix(3))
        try expectEqual(Set(summaries.map(\.identifier)).count, 1, "un seul résumé, remplacé à chaque fois")
        try expectEqual(summaries.map(\.groupedCount), [1, 2, 3], "nombre regroupé")
        try expectEqual(summaries.map(\.sound), [true, false, false], "son une seule fois pour le résumé")
        try expect(summaries.last!.title.contains("6 événements"), "titre du résumé : \(summaries.last!.title)")
        try expect(summaries.last!.body.contains("Sonde 6"), "dernier événement dans le résumé")
        try expect(Set(decisions.map(\.thread)) == ["type-probeDown"], "même fil")
        // Autre type : compté à part.
        let other = policy.decide(event(.newDevice, date: at(10, 6)), settings: settings,
                                  context: NotificationContext(now: at(10, 6), calendar: calendar))
        try expectEqual(other.delivery?.groupedCount, 1, "autre type non regroupé")
        // Fenêtre écoulée : on repart de zéro.
        let later = policy.decide(event(.probeDown, date: at(10, 20)), settings: settings,
                                  context: NotificationContext(now: at(10, 20), calendar: calendar))
        try expectEqual(later.delivery?.groupedCount, 1, "après la fenêtre de 5 min : simple")
        // Sans regroupement : jamais de résumé.
        settings.grouping = false
        var plain = NotificationPolicy()
        for index in 0..<5 {
            let decision = plain.decide(event(.probeDown, date: at(11, index)), settings: settings,
                                        context: NotificationContext(now: at(11, index), calendar: calendar))
            try expectEqual(decision.delivery?.groupedCount, 1, "sans regroupement (\(index))")
        }
        // L'aperçu ne compte pas dans la rafale.
        var counted = NotificationPolicy()
        settings.grouping = true
        for _ in 0..<5 {
            _ = counted.preview(event(.probeDown, date: at(12)), settings: settings, context: NotificationContext(now: at(12), calendar: calendar))
        }
        try expectEqual(counted.decide(event(.probeDown, date: at(12)), settings: settings,
                                       context: NotificationContext(now: at(12), calendar: calendar)).delivery?.groupedCount, 1,
                        "aperçus non comptés")
    }

    suite.add("Notifications : réglages enregistrés et relus") {
        var settings = NotificationSettings()
        settings.sound = .all
        settings.set(.scanFinished, enabled: true)
        settings.set(.probeRecovered, enabled: false)
        settings.quietHours = QuietHours(isEnabled: true, start: DayMinute(hour: 21, minute: 30), end: DayMinute(hour: 6, minute: 45))
        settings.grouping = false
        let back = NotificationSettings.decoded(settings.encoded())
        try expectEqual(back, settings, "aller-retour JSON")
        // Version future (type inconnu) et clés manquantes : lecture tolérante.
        let json = #"{"enabledKinds":["probeDown","typeFutur"],"sound":"bizarre"}"#
        let tolerant = NotificationSettings.decoded(Data(json.utf8))
        // Fichier antérieur à la note 42 : « Rapport planifié produit » prend sa valeur par défaut (activé).
        // Note 78 (0.26.0) : WAN suit « sonde en panne » (activé ici), licence, firmware et Syslog
        // suivent « sonde en alerte » (coupé ici) ; les cibles du ping continu prennent leur défaut.
        // Note 78 et 81 (0.27.0) : débit Internet sous le seuil et base des fabricants, activés par défaut.
        try expectEqual(tolerant.enabledKinds, [.probeDown, .reportReady, .wanDown, .pingTargetDown, .pingTargetUp,
                                                .internetSpeedLow, .ouiUpdated], "type inconnu ignoré")
        try expectEqual(tolerant.sound, .critical, "son inconnu : valeur par défaut")
        try expect(tolerant.grouping && tolerant.bannersEnabled, "clés absentes : valeurs par défaut")
        try expectEqual(NotificationSettings.decoded(Data("pas du json".utf8)), NotificationSettings(), "illisible : défaut")
    }

    suite.add("Événements : forme commune, liens et abonnés") {
        let id = UUID(uuidString: "6F1C2B9E-0D7A-4A51-9B0F-3C2D1E4F5A6B")!
        for link in [NetScopeEventLink.none, .probe(id), .service("microsoft365"), .device("10.182.122.40"), .screen("analyse"), .updates] {
            try expectEqual(NetScopeEventLink(url: link.url), link, "lien \(link.url)")
        }
        try expect(NetScopeEventLink(url: "https://exemple.com") == nil && NetScopeEventLink(url: "netscope://sonde/pas-un-uuid") == nil,
                   "liens invalides refusés")
        let event = NetScopeEvent(id: "a", kind: .rogueDHCP, title: "Serveur DHCP non autorisé\u{00A0}: 10.182.122.250",
                                  detail: "Offre 10.182.122.77", date: Date(timeIntervalSince1970: 1_800_000_000), link: .screen("analyse"))
        try expectEqual(event.severity, .critical, "gravité par défaut du type")
        let data = try JSONEncoder().encode(event)
        try expectEqual(try JSONDecoder().decode(NetScopeEvent.self, from: data), event, "événement JSON aller-retour")
        try expect(NetScopeEventSeverity.critical > .warning && NetScopeEventSeverity.warning > .info, "ordre des gravités")
        try expect(!NetScopeEventKind.configurable.contains(.test), "test hors des réglages")
        try await MainActor.run {
            let center = NetScopeEventCenter()
            var received: [String] = []
            center.subscribe("a") { received.append("a:" + $0.id) }
            center.subscribe("b") { received.append("b:" + $0.id) }
            center.subscribe("a") { received.append("a2:" + $0.id) }
            center.publish(event)
            try expectEqual(received, ["b:a", "a2:a"], "abonnés (le second « a » remplace le premier)")
            center.unsubscribe("b")
            center.recentLimit = 2
            center.publish(NetScopeEvent(id: "b", kind: .test, title: "t", detail: ""))
            center.publish(NetScopeEvent(id: "c", kind: .test, title: "t", detail: ""))
            try expectEqual(center.recent.map(\.id), ["c", "b"], "derniers événements, limités")
            try expectEqual(center.subscriberNames, ["a"], "désabonnement")
        }
    }

    suite.add("Raccourcis : affichage, sérialisation, touches") {
        try expectEqual(KeyCombo("R", [.shift, .command]).display, "⇧⌘R", "⇧⌘R")
        try expectEqual(KeyCombo("p", [.command, .option, .control, .shift]).displayParts, ["⌃", "⌥", "⇧", "⌘", "P"], "ordre ⌃⌥⇧⌘")
        try expectEqual(KeyCombo("return", [.command]).display, "⌘↩", "touche spéciale")
        for combo in [KeyCombo("r"), KeyCombo(".", [.shift, .command]), KeyCombo("+"), KeyCombo("f5", [.control, .option]),
                      KeyCombo(","), KeyCombo("space", [.control])] {
            try expectEqual(KeyCombo(serialized: combo.serialized), combo, "aller-retour \(combo.serialized)")
        }
        try expectEqual(KeyCombo("r", [.shift, .command]).serialized, "shift+cmd+r", "forme enregistrée")
        try expect(KeyCombo(serialized: "cmd+") == nil && KeyCombo(serialized: "cmd+toto") == nil && KeyCombo(serialized: "") == nil,
                   "formes invalides")
        try expect(KeyCombo("r", []).problem != nil && KeyCombo("r", [.shift]).problem != nil, "touche seule refusée")
        try expect(KeyCombo("f6", []).problem == nil && KeyCombo("r", [.control]).problem == nil, "F6 seule et ⌃R permises")
        try expectEqual(KeyCombo.key(keyCode: 15, characters: "R"), "r", "lettre")
        try expectEqual(KeyCombo.key(keyCode: 36, characters: "\r"), "return", "Retour")
        try expectEqual(KeyCombo.key(keyCode: 96, characters: "\u{F708}"), "f5", "F5")
        try expect(KeyCombo.key(keyCode: 999, characters: "\u{F730}") == nil, "touche de fonction inconnue")
        try expect(KeyCombo.key(keyCode: 56, characters: "") == nil, "modification seule")
    }

    suite.add("Raccourcis : conflits entre commandes et avec macOS") {
        let actions = ShortcutCatalog.fixedActions + ShortcutCatalog.screenActions([
            ("scanner", "Scanner"), ("carte", "Carte du réseau"), ("inventaire", "Inventaire"), ("appareil", "Appareil"),
            ("ping", "Ping continu"), ("switchs", "Switchs et ports"), ("wifi", "Wi-Fi"), ("outils", "Outils"),
            ("surveillance", "Surveillance"), ("analyse", "Historique et adressage"), ("rapports", "Rapports"),
        ])
        var settings = ShortcutSettings()
        try expectEqual(settings.conflicts(in: actions), [:], "valeurs par défaut sans conflit")
        try expectEqual(settings.combo(for: actions.first { $0.id == "ecran.surveillance" }!), KeyCombo("9"), "⌘9 : 9e écran")
        try expect(settings.combo(for: actions.first { $0.id == "ecran.analyse" }!) == nil, "10e écran sans raccourci")
        let ping = actions.first { $0.id == ShortcutID.ping }!
        let browser = actions.first { $0.id == ShortcutID.openBrowser }!
        settings.set(KeyCombo("i"), for: ping)
        settings.set(KeyCombo("h"), for: browser)
        let conflicts = settings.conflicts(in: actions)
        try expectEqual(conflicts[ShortcutID.ping], [.duplicate(ShortcutID.openDevice)], "⌘I en double (ping)")
        try expectEqual(conflicts[ShortcutID.openDevice], [.duplicate(ShortcutID.ping)], "⌘I en double (fiche)")
        try expectEqual(conflicts[ShortcutID.openBrowser], [.system("Masquer NetScope")], "⌘H réservé")
        try expectEqual(settings.owner(of: KeyCombo("i"), among: actions, excluding: ping)?.id, ShortcutID.openDevice, "propriétaire")
        try expect(settings.isCustomized(ping) && settings.customizedCount == 2, "deux écarts")
        settings.set(nil, for: ping)
        try expect(settings.combo(for: ping) == nil && settings.conflicts(in: actions)[ShortcutID.openDevice] == nil,
                   "raccourci retiré : plus de conflit")
        settings.set(KeyCombo("p"), for: ping)
        try expect(!settings.isCustomized(ping), "remis à la valeur par défaut : écart effacé")
        settings.resetAll()
        try expectEqual(settings, ShortcutSettings(), "retour aux valeurs par défaut")
    }

    suite.add("Raccourcis : réglages enregistrés et relus") {
        let actions = ShortcutCatalog.fixedActions
        var settings = ShortcutSettings()
        settings.set(KeyCombo("m", [.option, .command]), for: actions.first { $0.id == ShortcutID.copyMAC }!)
        settings.set(nil, for: actions.first { $0.id == ShortcutID.openBrowser }!)
        let text = String(decoding: settings.encoded(), as: UTF8.self)
        try expectEqual(text, #"{"selection.copierMAC":"opt+cmd+m","selection.navigateur":""}"#, "JSON lisible")
        try expectEqual(ShortcutSettings.decoded(settings.encoded()), settings, "aller-retour")
        let messy = ShortcutSettings.decoded(Data(#"{"scan.lancer":"cmd+???","scan.arreter":"ctrl+opt+escape"}"#.utf8))
        try expect(messy.overrides["scan.lancer"] == nil, "entrée invalide ignorée")
        try expectEqual(messy.combo(for: actions.first { $0.id == ShortcutID.stopScan }!), KeyCombo("escape", [.control, .option]), "entrée valide gardée")
        try expectEqual(ShortcutSettings.decoded(nil), ShortcutSettings(), "rien d'enregistré")
    }
}
