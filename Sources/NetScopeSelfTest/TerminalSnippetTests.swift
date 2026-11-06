import Foundation
@testable import NetScopeCore

// Note 67 (0.34.0) : extraits personnalisés et envoi à plusieurs sessions (textes fixes, rien
// n'est envoyé), et ordre alphabétique partagé de NetScope.
func registerTerminalSnippetTests(_ suite: TestSuite) {
    suite.add("Ordre alphabétique : français, sans casse ni accents, nombres") {
        try expectEqual(["Surveillance", "étendues DHCP", "Analyse", "Port 10", "Port 2", "Éditeur"].sortedFrench(),
                        ["Analyse", "Éditeur", "étendues DHCP", "Port 2", "Port 10", "Surveillance"], "ordre fr_CA")
        try expectEqual(["À propos", "Sites", "Général", "Alertes", "Autre"].sortedFrench(first: ["Général"], last: ["Autre", "À propos"]),
                        ["Général", "Alertes", "Sites", "Autre", "À propos"], "tête et fin gardées")
        try expectEqual(["cisco", "Cisco"].sortedFrench(), ["Cisco", "cisco"], "égalité tranchée, tri stable")
        try expect(FrenchOrder.precedes("Zébra", "zz"), "accent ignoré")
    }

    suite.add("Ordre alphabétique : listes des sélecteurs (types, guides, partages)") {
        try expectEqual(DeviceType.ordered.last, .inconnu, "« Inconnu » à la fin")
        try expectEqual(DeviceType.ordered.first?.label, "Caméra IP", "types triés")
        try expectEqual(DeviceType.ordered.count, DeviceType.allCases.count, "aucun type perdu")
        try expectEqual(LogDeviceGuide.Brand.orderedFamilies, ["Cisco", "Fortinet", "HP/Aruba", "Ubiquiti", "Autres"], "familles syslog")
        try expectEqual(DiskShareKind.ordered.last, .dossier, "« Autre » à la fin")
        try expectEqual(RemoteProtocol.ordered.first?.label, "FTP", "protocoles triés")
        try expectEqual(MonProbeKind.ordered.map(\.label), MonProbeKind.allCases.map(\.label).sortedFrench(), "sondes à ajouter")
    }

    suite.add("Extraits : marque déduite et extraits par marque triés") {
        try expectEqual(TerminalSnippetBrand.detect(description: "Cisco Catalyst 9300 SW-CORE-01", isSSH: true), .cisco, "Cisco")
        try expectEqual(TerminalSnippetBrand.detect(description: "FortiGate-60F", isSSH: true), .fortinet, "FortiGate")
        try expectEqual(TerminalSnippetBrand.detect(description: "HPE Aruba 2930F", isSSH: false), .aruba, "Aruba en Telnet")
        try expectEqual(TerminalSnippetBrand.detect(description: "NAS-SYNO", isSSH: true), .linux, "SSH sans marque")
        try expect(TerminalSnippetBrand.detect(description: "Switch inconnu", isSSH: false) == nil, "Telnet sans marque")
        try expectEqual(TerminalSnippetBrand.fortinet.builtInCommands.first, "diagnose sys top", "triés")
        try expectEqual(TerminalSnippetBrand.ordered.map(\.label), ["Aruba et HPE", "Cisco", "FortiGate", "Linux (SSH)"], "marques triées")
    }

    suite.add("Extraits : personnels d'abord, filtrés par marque, JSON") {
        let save = TerminalSnippet(name: "Sauvegarder", command: "copy running-config startup-config", brand: .cisco, sendsReturn: true)
        let all = TerminalSnippet(name: "date", command: "date")
        let forti = TerminalSnippet(name: "Sessions", command: "diagnose sys session list", brand: .fortinet)
        let items = TerminalSnippetLibrary.items(brand: .cisco, custom: [save, forti, all])
        try expectEqual(items.prefix(2).map(\.title), ["date", "Sauvegarder"], "personnels triés, autre marque exclue")
        try expect(items[1].isCustom && items[1].sendsReturn, "Entrée gardée")
        try expectEqual(items.count, 2 + 6, "puis les six de Cisco")
        try expect(TerminalSnippetLibrary.items(brand: nil, custom: []).isEmpty, "rien sans marque")
        let decoded = TerminalSnippet.decodeList(TerminalSnippet.encodeList([save, all]))
        try expectEqual(decoded, [save, all], "aller-retour JSON")
        try expect(TerminalSnippet.decodeList(Data("pas du JSON".utf8)).isEmpty, "donnée illisible : liste vide")
        try expect(TerminalSnippet.validationError(name: " ", command: "x", existing: []) != nil, "nom vide")
        try expect(TerminalSnippet.validationError(name: "a", command: "\n", existing: []) != nil, "commande vide")
        try expect(TerminalSnippet.validationError(name: "sauvegarder", command: "x", existing: [save]) != nil, "nom en double")
        try expect(TerminalSnippet.validationError(name: "Sauvegarder", command: "x", existing: [save], editing: save.id) == nil,
                   "même nom en modification")
    }

    suite.add("Envoi à plusieurs sessions : texte, choix et confirmation") {
        try expectEqual(TerminalBroadcast.payload(command: "show run\n", sendsReturn: true), "show run\r", "Entrée finale")
        try expectEqual(TerminalBroadcast.payload(command: "conf t\r\nhostname X\n\n", sendsReturn: false), "conf t\rhostname X", "lignes")
        try expectEqual(TerminalBroadcast.payload(command: "  \n", sendsReturn: true), "", "vide")
        let a = TerminalBroadcast.Target(id: UUID(), name: "SW-ETG2-01", address: "10.182.122.3", isConnected: true)
        let b = TerminalBroadcast.Target(id: UUID(), name: "SW-CORE-01", address: "10.182.122.2", isConnected: true)
        let c = TerminalBroadcast.Target(id: UUID(), name: "FortiGate-60F", address: "10.182.122.1", isConnected: false)
        // Même adresse IP pour deux sessions de sites différents : chacune est choisie par son identifiant.
        let twin = TerminalBroadcast.Target(id: UUID(), name: "SW-CORE-01 (Laval)", address: "10.182.122.2", isConnected: true)
        let plan = TerminalBroadcast.plan(command: "show running-config", sendsReturn: true,
                                          targets: [a, b, c, twin], selected: [a.id, b.id, c.id])
        try expectEqual(plan.recipients.map(\.name), ["SW-CORE-01", "SW-ETG2-01"], "ouvertes, triées, sans la jumelle")
        try expectEqual(plan.skipped.map(\.name), ["FortiGate-60F"], "fermée ignorée")
        try expect(plan.canSend, "envoi possible")
        try expectEqual(TerminalBroadcast.confirmationTitle(plan), "Envoyer la commande à 2\u{00A0}sessions\u{00A0}?", "titre")
        let message = TerminalBroadcast.confirmationMessage(plan, command: "show running-config", sendsReturn: true)
        try expect(message.contains("SW-CORE-01, SW-ETG2-01") && message.contains("Entrée") && message.contains("FortiGate-60F"), message)
        let none = TerminalBroadcast.plan(command: "x", sendsReturn: false, targets: [c], selected: [c.id])
        try expect(!none.canSend, "aucune session ouverte")
        try expectEqual(TerminalBroadcast.lineCount("a\nb\n"), 2, "deux lignes")
    }
}
