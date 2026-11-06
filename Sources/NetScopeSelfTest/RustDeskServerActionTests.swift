import Foundation
import NetScopeCore

// Note 88 (0.33.1) : actions sur le serveur RustDesk — validation stricte, scripts fixes, lecture
// de la sortie, règles de la mise à jour planifiée, historique et secrets. Textes fixes et valeurs
// fictives seulement ; aucun ssh, aucune action lancée.

func registerRustDeskServerActionTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_794_000_000)

    suite.add("Serveur RustDesk, actions : adresse, port et ID validés strictement (aucune injection)") {
        for bad in ["", "203.0.113.58; rm -rf /", "203.0.113.58'", "$(id)", "203.0.113.58 ", "999.1.1.1", "exemple.ca", "1.2.3.4\nid", "`id`"] {
            var refused = false
            do { _ = try RustDeskActionValidation.address(bad) } catch { refused = true }
            try expect(refused, "adresse refusée : \(bad.debugDescription)")
        }
        try expectEqual(try RustDeskActionValidation.address("203.0.113.58"), "203.0.113.58", "IPv4")
        try expectEqual(try RustDeskActionValidation.address("2001:db8::5"), "2001:db8::5", "IPv6")
        for port in [0, 65_536, -1] {
            var refused = false
            do { _ = try RustDeskActionValidation.port(port) } catch { refused = true }
            try expect(refused, "port refusé : \(port)")
        }
        try expectEqual(try RustDeskActionValidation.port(nil), nil, "sans port")
        try expectEqual(try RustDeskActionValidation.rustDeskID("263 418 095"), "263418095", "ID groupé")
        var refusedID = false
        do { _ = try RustDeskActionValidation.rustDeskID("26341;id") } catch { refusedID = true }
        try expect(refusedID, "ID invalide refusé")
        try expectEqual(try RustDeskActionValidation.containerName("rustdesk-hbbr_1"), "rustdesk-hbbr_1", "nom de conteneur")
        var refusedName = false
        do { _ = try RustDeskActionValidation.containerName("hbbr;reboot") } catch { refusedName = true }
        try expect(refusedName, "nom de conteneur invalide refusé")
        // Une session dont l'adresse n'est pas valide ne devient jamais une action.
        let forged = RustDeskRelaySession(address: "1.2.3.4';reboot;'", seconds: 1, megabytes: 0, maxKbps: 0, averageKbps: 0, currentKbps: 0)
        var refusedSession = false
        do { _ = try RustDeskServerAction.disconnect(forged) } catch { refusedSession = true }
        try expect(refusedSession, "session forgée refusée")
    }

    suite.add("Serveur RustDesk, actions : script de déconnexion (ss -K sur la session seulement, vérifiée ensuite)") {
        let session = RustDeskRelaySession(address: "203.0.113.58:52114", seconds: 60, megabytes: 1, maxKbps: 1, averageKbps: 1, currentKbps: 1)
        let action = try RustDeskServerAction.disconnect(session, targetID: "263418095", station: "Réception")
        try expectEqual(action.peerLabel, "203.0.113.58:52114", "adresse et port")
        try expectEqual(action.target, "203.0.113.58:52114 (Réception)", "cible notée")
        let script = action.script
        try expect(script.contains("FILTRE='( sport = :21117 ) and ( dst 203.0.113.58:52114 or dst [::ffff:203.0.113.58]:52114 )'"), "filtre ss exact")
        try expect(script.contains("asroot ss -K -tn state established \"$FILTRE\""), "ss -K avec sudo")
        try expect(script.contains("val apres"), "vérifiée ensuite")
        try expect(script.contains("NETSCOPE_MDP=; section FIN"), "mot de passe oublié avant la fin")
        for word in ["dc pull", "dc up -d", "apt-get", "dnf -y", "shutdown -r", "dk restart", "systemctl restart", "dk tag"] {
            try expect(!script.contains(word), "déconnexion sans « \(word) »")
        }
        let v6 = try RustDeskServerAction.disconnect(RustDeskRelaySession(address: "[2001:db8::5]:40000", seconds: 1, megabytes: 0, maxKbps: 0,
                                                                          averageKbps: 0, currentKbps: 0))
        try expect(v6.script.contains("( dst [2001:db8::5]:40000 )"), "IPv6 entre crochets, sans forme ::ffff:")
        try expect(action.consequences.joined().contains("reconnecter aussitôt"), "le poste peut se reconnecter, dit avant")
    }

    suite.add("Serveur RustDesk, actions : chaque script ne contient que ses propres commandes de modification") {
        let actions: [RustDeskServerAction] = [
            try .disconnect(RustDeskRelaySession(address: "198.51.100.37:61002", seconds: 1, megabytes: 0, maxKbps: 0, averageKbps: 0, currentKbps: 0)),
            .restartRelay(activeSessions: 2),
            .updateRustDesk(activeSessions: 0),
            .updateSystem(scope: .security, allowReboot: true, activeSessions: 1),
        ]
        for action in actions {
            let script = action.script
            try expect(script.contains("section JOURNAL") && script.contains("fin echec"), "\(action.kind) : journal et échec prévu")
            try expect(script.contains("sudo refusé"), "\(action.kind) : sudo vérifié d'abord")
            for (kind, words) in RustDeskServerActionScript.modifyingWords where kind != action.kind {
                for word in words where !(RustDeskServerActionScript.modifyingWords[action.kind] ?? []).contains(word) {
                    try expect(!script.contains(word), "\(action.kind) sans « \(word) »")
                }
            }
            for word in RustDeskServerActionScript.modifyingWords[action.kind] ?? [] {
                try expect(script.contains(word), "\(action.kind) contient « \(word) »")
            }
            try expect(!script.contains("rm "), "\(action.kind) : aucun rm")
        }
        let rustdesk = RustDeskServerAction.updateRustDesk(activeSessions: 0).script
        try expect(rustdesk.contains("dc config -q"), "compose relu avant")
        try expect(rustdesk.range(of: "dc config -q")!.lowerBound < rustdesk.range(of: "dc pull")!.lowerBound, "relu avant pull")
        try expect(rustdesk.range(of: "tar -C")!.lowerBound < rustdesk.range(of: "dc pull")!.lowerBound, "sauvegarde avant pull")
        try expect(rustdesk.range(of: "dk tag \"$IID\" \"$RETOUR\"")!.lowerBound < rustdesk.range(of: "dc pull")!.lowerBound, "étiquette avant pull")
        try expect(rustdesk.contains("dk tag \"$RETOUR\" \"$IMG\""), "retour à l'image précédente")
        try expect(rustdesk.contains("Clé publique inchangée"), "clé vérifiée après")
        try expect(rustdesk.contains("com.docker.compose.project.working_dir"), "dossier du compose lu sur le conteneur")
        try expect(rustdesk.contains("docker-compose"), "ancien docker-compose toléré")
        let system = RustDeskServerAction.updateSystem(scope: .security, allowReboot: false, activeSessions: 0).script
        try expect(system.contains("SECU=1\nREDEM=0"), "options de la mise à jour du système")
        try expect(system.contains("dnf -y -q upgrade $O") && system.contains("unattended-upgrade"), "apt et dnf")
        try expect(!RustDeskServerAction.updateSystem(scope: .all, allowReboot: false, activeSessions: 0).script.contains("relais)\nif"), "pas de report à la main")
        let planned = RustDeskServerAction.updateRustDesk(activeSessions: 0, postponeIfSession: true).script
        try expect(planned.contains("fin reporte"), "report si session (planifiée)")
        try expect(!RustDeskServerAction.updateRustDesk(activeSessions: 0).script.contains("fin reporte"), "aucun report à la main")
        // Syntaxe vérifiée par « sh -n » (lecture seule du script, rien n'est exécuté).
        for action in actions + [.updateRustDesk(activeSessions: 0, postponeIfSession: true)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n"]
            let input = Pipe()
            process.standardInput = input
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(Data(action.script.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            try expectEqual(process.terminationStatus, 0, "\(action.kind) : syntaxe sh valide")
        }
        // Les scripts de lecture restent sans aucune modification.
        for word in RustDeskServerDetailScript.forbiddenWords {
            try expect(!RustDeskServerDetailScript.details.contains(word), "lecture détaillée sans « \(word) »")
        }
    }

    suite.add("Serveur RustDesk, actions : confirmation et commande copiée sans secret") {
        let restart = RustDeskServerAction.restartRelay(activeSessions: 2)
        try expect(restart.consequences[0].contains("2 sessions relayées en cours"), "sessions en cours signalées")
        try expectEqual(restart.confirmLabel, "Redémarrer hbbr", "bouton de confirmation")
        let system = RustDeskServerAction.updateSystem(scope: .all, allowReboot: true, activeSessions: 0)
        try expect(system.consequences.joined().contains("Redémarrage du serveur permis"), "redémarrage annoncé")
        let account = RustDeskServerAccount(user: "admin", host: "assistance.exemple.ca", port: 2222)
        let command = RustDeskServerSSH.copyableActionCommand(account, action: restart)
        try expect(command.hasPrefix("ssh -T -p 2222 -- admin@assistance.exemple.ca "), "même connexion ssh")
        try expect(command.contains("<<'NETSCOPE'\n\n# NetScope : action"), "première ligne vide (aucun mot de passe)")
        try expect(command.contains(restart.script), "script exact")
        try expectEqual(RustDeskServerSSH.actionTimeout(.updateSystem), 5_400, "délai de la mise à jour du système")
    }

    suite.add("Serveur RustDesk, actions : sortie lue (réussite, échec, report, interruption)") {
        let ok = """
        @@NETSCOPE ACCES@@
        SUDO ok
        @@NETSCOPE JOURNAL@@
        VAL sessions=0
        ETAPE ok Compose relu sans erreur (/srv/exemple/rustdesk).
        VAL version_avant=hbbs 1.1.12
        ETAPE ok docker compose pull terminé.
        ETAPE ok Clé publique inchangée.
        VAL version_apres=hbbs 1.1.14
        ETAPE bizarre ignorée
        @@NETSCOPE RESULTAT@@
        ok
        @@NETSCOPE FIN@@
        """
        let parsed = RustDeskActionOutput.parse(ok)
        try expectEqual(parsed.outcome, .ok, "réussie")
        try expectEqual(parsed.steps.count, 3, "étapes connues seulement")
        try expectEqual(parsed.values["version_apres"], "hbbs 1.1.14", "valeur lue")
        try expectEqual(parsed.summary(for: .updateRustDesk), "RustDesk Server 1.1.12 → 1.1.14.", "résumé des versions")
        let failed = RustDeskActionOutput.parse("@@NETSCOPE JOURNAL@@\nETAPE echec RustDesk ne repart pas.\nETAPE ok Image précédente remise.\n@@NETSCOPE RESULTAT@@\nechec\n@@NETSCOPE FIN@@\n")
        try expectEqual(failed.outcome, .failed, "échec")
        try expectEqual(failed.summary(for: .updateRustDesk), "RustDesk ne repart pas.", "résumé de l'échec")
        let mixed = RustDeskActionOutput.parse("@@NETSCOPE JOURNAL@@\nETAPE echec x\n@@NETSCOPE RESULTAT@@\nok\n@@NETSCOPE FIN@@\n")
        try expectEqual(mixed.outcome, .failed, "une étape en échec l'emporte")
        let postponed = RustDeskActionOutput.parse("@@NETSCOPE JOURNAL@@\nVAL sessions=2\n@@NETSCOPE RESULTAT@@\nreporte\n@@NETSCOPE FIN@@\n")
        try expectEqual(postponed.outcome, .postponed, "reportée")
        let cut = RustDeskActionOutput.parse("@@NETSCOPE JOURNAL@@\nETAPE ok docker compose pull terminé.\n")
        try expectEqual(cut.outcome, .failed, "interrompue = échec")
        try expect(!cut.complete && cut.steps.last?.level == "echec", "interruption dite")
        let control = RustDeskActionOutput.parse("@@NETSCOPE JOURNAL@@\nETAPE ok a\u{1B}[31mb\n@@NETSCOPE RESULTAT@@\nok\n@@NETSCOPE FIN@@\n")
        try expect(!(control.steps.first?.text.contains("\u{1B}") ?? true), "caractères de contrôle retirés")
    }

    suite.add("Serveur RustDesk, mise à jour planifiée : un seul Mac, fenêtre, report, abandon, oubli") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        var schedule = RustDeskUpdateSchedule()
        schedule.enabled = true
        schedule.weekday = 1
        schedule.hour = 3
        schedule.runnerID = "MAC-A"
        // Dimanche 8 novembre 2026, 3 h 02 (Toronto).
        let slot = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 3, minute: 0))!
        let at = slot.addingTimeInterval(120)
        try expectEqual(schedule.lastSlot(atOrBefore: at, calendar: calendar), slot, "échéance de la semaine")
        try expectEqual(schedule.nextSlot(after: at, calendar: calendar), slot.addingTimeInterval(7 * 86_400), "prochaine échéance")
        try expectEqual(schedule.label(calendar: calendar), "dimanche à 3\u{00A0}h", "libellé")
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: at, calendar: calendar, records: [], machineID: "MAC-B"), .idle, "autre Mac : rien")
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: at, calendar: calendar, records: [], machineID: "MAC-A"),
                        .run(slot: slot, last: false), "ce Mac : à faire")
        var off = schedule
        off.enabled = false
        try expectEqual(RustDeskUpdateSchedule.decide(off, now: at, calendar: calendar, records: [], machineID: "MAC-A"), .idle, "coupée")
        let postponed = RustDeskActionRecord(date: at, kind: .updateRustDesk, target: "x", outcome: .postponed, summary: "", origin: "A", slot: slot)
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: at.addingTimeInterval(600), calendar: calendar, records: [postponed], machineID: "MAC-A"),
                        .idle, "report : attendre 15 min")
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: at.addingTimeInterval(900), calendar: calendar, records: [postponed], machineID: "MAC-A"),
                        .run(slot: slot, last: false), "nouvel essai après 15 min")
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: slot.addingTimeInterval(3 * 3_600 - 600), calendar: calendar, records: [postponed], machineID: "MAC-A"),
                        .run(slot: slot, last: true), "dernier essai de la fenêtre")
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: slot.addingTimeInterval(3 * 3_600 + 60), calendar: calendar, records: [postponed], machineID: "MAC-A"),
                        .expired(slot: slot), "fenêtre passée : abandon")
        let done = RustDeskActionRecord(date: at, kind: .updateRustDesk, target: "x", outcome: .ok, summary: "", origin: "A", slot: slot)
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: at.addingTimeInterval(3_600), calendar: calendar, records: [done], machineID: "MAC-A"),
                        .idle, "faite : rien de plus")
        try expectEqual(RustDeskUpdateSchedule.decide(schedule, now: slot.addingTimeInterval(5 * 3_600), calendar: calendar, records: [], machineID: "MAC-A"),
                        .missed(slot: slot), "aucun essai dans la fenêtre : manquée")
        var changed = schedule
        changed.changedAt = slot.addingTimeInterval(4 * 3_600)
        try expectEqual(RustDeskUpdateSchedule.decide(changed, now: slot.addingTimeInterval(5 * 3_600), calendar: calendar, records: [], machineID: "MAC-A"),
                        .idle, "réglée après l'échéance : ni faite ni manquée")
        let missedOld = RustDeskUpdateSchedule.decide(schedule, now: slot.addingTimeInterval(6 * 86_400), calendar: calendar,
                                                      records: [RustDeskActionRecord(date: slot, kind: .updateRustDesk, target: "", outcome: .missed,
                                                                                     summary: "", origin: "A", slot: slot)], machineID: "MAC-A")
        try expectEqual(missedOld, .idle, "manquée notée une seule fois")
        try expectEqual(schedule.actions().map(\.kind), [.updateRustDesk, .updateSystem], "RustDesk puis système")
        try expect(schedule.actions().allSatisfy(\.postponeIfSession), "report si session")
        try expect(!RustDeskUpdateSchedule.thisMachineID().isEmpty, "identifiant de ce Mac lu (gethostuuid, état local)")
    }

    suite.add("Serveur RustDesk, actions : historique synchronisé, réglage fusionné, secrets, alerte") {
        let a = RustDeskActionRecord(date: now, kind: .disconnect, target: "x", outcome: .ok, summary: "a", origin: "Mac A")
        let b = RustDeskActionRecord(date: now.addingTimeInterval(60), kind: .updateRustDesk, target: "y", outcome: .failed, summary: "b",
                                     origin: "Mac B (agent, planifiée)", slot: now)
        var base = RustDeskWatchStore.Contents()
        var local = base
        local.actions = [a]
        var schedule = RustDeskUpdateSchedule()
        schedule.enabled = true
        schedule.runnerID = "MAC-A"
        local.schedule = schedule
        var disk = base
        disk.actions = [b]
        let merged = RustDeskWatchStore.merge(local: local, base: base, disk: disk, now: now)
        try expectEqual(merged.actions.map(\.summary), ["b", "a"], "union, récentes d'abord")
        try expectEqual(merged.schedule, schedule, "réglage changé ici : gardé")
        base = merged
        let untouched = RustDeskWatchStore.merge(local: merged, base: base, disk: disk, now: now)
        try expectEqual(untouched.schedule.enabled, false, "réglage changé ailleurs seulement : celui du disque")
        // Aller-retour JSON avec bornes.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RustDeskWatchStore.Contents.self, from: encoder.encode(merged))
        try expectEqual(decoded.actions, merged.actions, "historique relu")
        let clamped = try decoder.decode(RustDeskUpdateSchedule.self, from: Data(#"{"weekday":9,"hour":30,"minute":-4,"target":"inconnu"}"#.utf8))
        try expect(clamped.weekday == 7 && clamped.hour == 23 && clamped.minute == 0 && clamped.target == .both, "réglage borné")
        // Secrets : jamais une phrase de passe de clé envoyée à sudo.
        let password = RustDeskServerAccount(user: "admin", host: "assistance.exemple.ca")
        let withKey = RustDeskServerAccount(user: "admin", host: "assistance.exemple.ca", keyPath: "~/.ssh/id_ed25519")
        try expectEqual(RustDeskServerCredentials.sudoPassword(stored: nil, sshSecret: "s", account: password), "s", "mot de passe SSH réutilisé")
        try expectEqual(RustDeskServerCredentials.sudoPassword(stored: nil, sshSecret: "s", account: withKey), nil, "phrase de passe jamais envoyée")
        try expectEqual(RustDeskServerCredentials.sudoPassword(stored: "t", sshSecret: "s", account: withKey), "t", "sudo enregistré d'abord")
        let settings = RustDeskDashboardSettings(manualAccount: "Admin@Assistance.exemple.ca")
        try expectEqual(RustDeskServerCredentials.secretKey(settings)?.account, "tableau-serveur-ssh:admin@assistance.exemple.ca", "nom au Trousseau")
        try expectEqual(RustDeskServerCredentials.sudoKey(settings), "tableau-serveur-sudo:saisi:admin@assistance.exemple.ca", "sudo au Trousseau")
        try expectEqual(RustDeskServerCredentials.account(settings, connections: [])?.host, "Assistance.exemple.ca", "compte saisi")
        let carnet = RustDeskDashboardSettings(connectionID: UUID())
        try expect(RustDeskServerCredentials.account(carnet, connections: []) == nil, "connexion supprimée : aucun compte")
        try expect(AlertEvent.rustDeskScheduledUpdate(a) == nil, "réussite : aucune alerte")
        try expectEqual(AlertEvent.rustDeskScheduledUpdate(b)?.severity, .critical, "échec : alerte critique")
    }
}
