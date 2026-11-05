import Foundation
import NetScopeCore

// Note 79 : allègements décidés par Dany. Règles pures, données fixes, aucun trafic réseau :
// redirection des anciens identifiants d'outils, outil « Courriel » unique, TFTP en une seule
// entrée, Ookla et services grand public masqués par défaut, nouveaux noms des écrans.

func registerLighteningTests(_ suite: TestSuite) {
    suite.add("Allègements : anciens identifiants des outils de courriel → bon onglet de « Courriel »") {
        // Identifiants historiques : inchangés et reconnus comme onglets.
        for (raw, tab) in [("mailSuper", MailToolTab.superTool), ("mailHealth", .health), ("mx", .mx),
                           ("blacklist", .blacklist), ("mailRecords", .records), ("smtp", .smtp), ("entetes", .headers)] {
            try expectEqual(ToolRouting.canonical(raw), raw, "\(raw) garde son identifiant")
            try expectEqual(ToolRouting.mailTab(for: raw), tab, "\(raw) → onglet")
            try expectEqual(ToolRouting.listEntry(for: raw), ToolRouting.mailEntryID, "\(raw) → entrée « Courriel »")
        }
        // Alias : nouvelle entrée et anciens noms anglais.
        try expectEqual(ToolRouting.canonical("courriel"), "mailSuper", "courriel → Super outil")
        try expectEqual(ToolRouting.canonical(" Courriel "), "mailSuper", "casse et espaces ignorés")
        try expectEqual(ToolRouting.canonical("headers"), "entetes", "headers → En-têtes")
        try expectEqual(ToolRouting.mailTab(for: "dmarc"), .records, "dmarc → SPF, DKIM, DMARC")
        // Les autres outils ne bougent pas.
        for raw in ["dns", "subnet", "dhcpscopes", "cloud", "speedtest", "inconnu"] {
            try expectEqual(ToolRouting.canonical(raw), raw, "\(raw) inchangé")
            try expect(ToolRouting.mailTab(for: raw) == nil, "\(raw) n’est pas un onglet de courriel")
            try expectEqual(ToolRouting.listEntry(for: raw), raw, "\(raw) est sa propre entrée")
        }
        try expectEqual(MailToolTab.allCases.first, .superTool, "Super outil en premier onglet")
        try expectEqual(MailToolTab.headers.formerName, "Analyse d’en-têtes", "ancien nom gardé pour la recherche")
    }

    suite.add("Allègements : une seule entrée « Courriel » et une seule entrée TFTP dans la liste") {
        // Ordre de la Boîte à outils (identifiants de ToolKind), avec des doublons volontaires.
        let ids = ["subnet", "mac", "ports", "dns", "whois", "mtu", "iperf", "speedtest", "wol", "dhcp", "dhcpscopes",
                   "lldp", "tftp", "cloud", "wan", "firmware", "mailSuper", "mailHealth", "mx", "blacklist",
                   "mailRecords", "smtp", "entetes", "capture", "disques", "tftpd", "tftp-serveur"]
        let listed = ToolRouting.listedEntries(ids)
        try expectEqual(listed.filter { $0 == "tftp" }.count, 1, "TFTP une seule fois")
        try expectEqual(listed.filter { $0 == ToolRouting.mailEntryID }.count, 1, "Courriel une seule fois")
        try expect(!listed.contains { $0 != ToolRouting.mailEntryID && ToolRouting.mailTab(for: $0) != nil }, "aucun onglet de courriel séparé")
        try expectEqual(listed.firstIndex(of: "courriel"), listed.firstIndex(of: "firmware").map { $0 + 1 },
                        "Courriel à la place du premier outil de courriel")
        try expectEqual(listed.count, 19, "18 outils + 1 entrée « Courriel » pour 7 outils, doublons TFTP retirés")
        try expectEqual(Set(listed).count, listed.count, "aucun doublon")
    }

    suite.add("Allègements : Ookla masqué par défaut dans Speedtest, réactivable") {
        let prefs = SpeedServerPrefs()
        try expect(!prefs.ooklaEnabled, "Ookla masqué par défaut")
        let servers = [SpeedServer.cloudflare, SpeedServer.ooklaAuto]
        try expectEqual(prefs.allowed(servers).map(\.id), [SpeedServer.cloudflare.id], "serveurs Ookla retirés")
        try expect(!prefs.allows(.ooklaAuto) && prefs.allows(.cloudflare), "Ookla refusé, Cloudflare permis")

        var enabled = prefs
        enabled.setOoklaEnabled(true)
        try expectEqual(enabled.allowed(servers).count, 2, "réactivé : Ookla proposé")
        enabled.selectedID = SpeedServer.ooklaAuto.id
        enabled.selected = SpeedServer.ooklaAuto
        enabled.setOoklaEnabled(false)
        try expectEqual(enabled.selectedID, SpeedServerPrefs.automaticID, "masqué : le choix Ookla repasse en automatique")
        try expect(enabled.selected == nil, "serveur choisi oublié")

        // Fichier d'avant la 0.25.0 : sans la clé, masqué… sauf si Ookla était déjà choisi.
        let old = Data(#"{"version":1,"selectedID":"auto","favorites":[],"custom":[]}"#.utf8)
        let oldPrefs = try JSONDecoder().decode(SpeedServerPrefs.self, from: old)
        try expect(!oldPrefs.ooklaEnabled, "ancien fichier : masqué")
        var chosen = SpeedServerPrefs(selectedID: SpeedServer.ooklaAuto.id, selected: SpeedServer.ooklaAuto)
        chosen.ooklaEnabled = true
        var data = try JSONEncoder().encode(chosen)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "ooklaEnabled")
        data = try JSONSerialization.data(withJSONObject: object)
        let legacyChoice = try JSONDecoder().decode(SpeedServerPrefs.self, from: data)
        try expect(legacyChoice.ooklaEnabled, "ancien choix Ookla : gardé")
        // Aller-retour : le choix est enregistré.
        let saved = try JSONDecoder().decode(SpeedServerPrefs.self, from: JSONEncoder().encode(chosen))
        try expect(saved.ooklaEnabled, "réactivation enregistrée")
    }

    suite.add("Allègements : services grand public non suivis par défaut dans État des services") {
        let consumer = SvcCatalog.builtIn.filter { SvcCatalog.consumerServiceIDs.contains($0.id) }
        try expectEqual(Set(consumer.map(\.id)), ["facebook", "instagram", "tiktok", "snapchat", "grok"], "TikTok, Snapchat, Meta, Grok")
        try expect(consumer.allSatisfy { !$0.isEnabled }, "grand public : non suivis")
        let others = SvcCatalog.builtIn.filter { !SvcCatalog.consumerServiceIDs.contains($0.id) }
        try expect(others.allSatisfy(\.isEnabled), "Microsoft 365, Claude, ChatGPT… restent suivis")
        try expect(others.contains { $0.id == "claude" } && others.contains { $0.id == "copilot" }, "assistants IA d’entreprise gardés")

        // Ancien catalogue enregistré (tout actif) : migration unique, services personnalisés intacts.
        var saved = SvcCatalog.builtIn.map { service -> SvcService in var copy = service; copy.isEnabled = true; return copy }
        saved.append(SvcService(id: "perso-tiktok", name: "TikTok interne", category: "Perso", format: .none, feedURL: nil,
                                pageURL: "https://intranet.exemple.ca", endpoints: ["https://intranet.exemple.ca/"], isCustom: true))
        let migrated = SvcCatalog.hidingConsumerServices(SvcCatalog.merged(saved: saved))
        try expect(migrated.filter { SvcCatalog.consumerServiceIDs.contains($0.id) }.allSatisfy { !$0.isEnabled }, "masqués après migration")
        try expect(migrated.first { $0.id == "microsoft365" }?.isEnabled == true, "Microsoft 365 toujours suivi")
        try expect(migrated.first { $0.id == "perso-tiktok" }?.isEnabled == true, "service personnalisé intact")
        // Réactivé par l'utilisateur : la fusion garde son choix.
        var reactivated = migrated
        if let index = reactivated.firstIndex(where: { $0.id == "tiktok" }) { reactivated[index].isEnabled = true }
        try expect(SvcCatalog.merged(saved: reactivated).first { $0.id == "tiktok" }?.isEnabled == true, "réactivation gardée")
        // Service grand public absent d'un ancien fichier : ajouté, mais non suivi.
        let withoutGrok = SvcCatalog.merged(saved: saved.filter { $0.id != "grok" })
        try expect(withoutGrok.first { $0.id == "grok" }?.isEnabled == false, "Grok ajouté non suivi")
    }

    suite.add("Allègements : « Historique et adressage » et « Bilan de santé », anciens noms gardés") {
        try expectEqual(NavModule.analyse.title, "Historique et adressage", "nouveau nom de l’écran")
        try expectEqual(NavModule.analyse.rawValue, "analyse", "identifiant inchangé (liens, réglages)")
        try expect(NavModule.analyse.formerTitles.contains("Analyse"), "ancien nom retrouvable")
        try expect(NavModule.trafic.formerTitles.contains("Analyse complète du réseau"), "ancien nom du bilan retrouvable")
        try expectEqual(NavModule.analyse.shortcutDigit, "0", "⌥⌘0 inchangé")
        try expectEqual(ReportSectionKind.trafic.label, "Trafic et bilan de santé", "section du rapport renommée")
    }
}
