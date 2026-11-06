import Foundation
import NetScopeCore

// Écran Appareil : « Ouvrir une fiche » (lecture de la saisie, suggestions) et appareils saisis à la
// main (rattachement à l'appareil scanné). Aucun réseau.

func registerDeviceLookupTests(_ suite: TestSuite) {
    let printerMAC = MACAddress("94:DD:F8:18:15:7D")!

    suite.add("Ouvrir une fiche : IPv4 stricte et messages des adresses mal écrites") {
        try expectEqual(DeviceEntry.parse("  10.182.122.111 "), .ip(IPv4Address("10.182.122.111")!), "IP avec espaces")
        try expectEqual(DeviceEntry.parse(""), .empty, "vide")
        try expectEqual(DeviceEntry.parse("10.182"), .invalid("Adresse IP incomplète\u{00A0}: 2 octets sur 4"), "incomplète")
        try expectEqual(DeviceEntry.parse("10.182.122."), .invalid("Adresse IP incomplète\u{00A0}: 3 octets sur 4"), "point final")
        try expectEqual(DeviceEntry.parse("10.0.0.256"), .invalid("«\u{00A0}256\u{00A0}» dépasse 255"), "octet trop grand")
        try expectEqual(DeviceEntry.parse("10.0.0.1.5"), .invalid("Adresse IP trop longue\u{00A0}: 5 octets au lieu de 4"), "trop long")
        try expectEqual(DeviceEntry.parse("10..0.1"), .invalid("Point en trop dans l’adresse IP"), "point double")
        try expectEqual(DeviceEntry.parse("010.0.0.1"),
                        .invalid("«\u{00A0}010\u{00A0}»\u{00A0}: zéro en tête refusé (octal ou décimal\u{00A0}?)"), "zéro en tête")
        try expectEqual(DeviceEntry.parse("10.0.0.0/24"),
                        .invalid("Une seule adresse est attendue, sans masque\u{00A0}: 10.0.0.0"), "masque")
        try expect(!DeviceEntry.parse("10.182").isUsable, "une IP incomplète n'ouvre rien")
    }

    suite.add("Ouvrir une fiche : MAC sous toutes ses formes") {
        for text in ["94:dd:f8:18:15:7d", "94-DD-F8-18-15-7D", "94dd.f818.157d", "94DDF818157D",
                     "94dd-f818-157d", "94dd:f818:157d"] {
            try expectEqual(DeviceEntry.parse(text), .mac(printerMAC), "MAC « \(text) »")
        }
        try expectEqual(DeviceEntry.parse("0:1a:2b:3:4:5"), .mac(MACAddress("00:1A:2B:03:04:05")!), "octets sans zéro (arp -a)")
        try expectEqual(DeviceEntry.parse("94:dd:f8:18:15"),
                        .invalid("Adresse MAC incomplète\u{00A0}: 10 chiffres hexadécimaux sur 12"), "MAC courte")
        try expectEqual(DeviceEntry.parse("94:dd:f8:18:15:7g"),
                        .invalid("Adresse MAC illisible\u{00A0}: «\u{00A0}g\u{00A0}» n’est pas un chiffre hexadécimal"), "caractère")
        try expectEqual(DeviceEntry.parse("fe80::1"), .invalid("Adresse IPv6\u{00A0}: NetScope travaille en IPv4 seulement"), "IPv6")
        if case .ambiguous(let mac, let name) = DeviceEntry.parse("facefeedbead") {
            try expectEqual(mac, MACAddress("fa:ce:fe:ed:be:ad")!, "lecture MAC")
            try expectEqual(name, "facefeedbead", "lecture nom")
        } else {
            throw TestFailure(message: "douze lettres hexadécimales : saisie ambiguë", file: #fileID, line: #line)
        }
    }

    suite.add("Ouvrir une fiche : noms d'hôte valides et refusés") {
        try expectEqual(DeviceEntry.parse("SW-ETG2-01"), .hostname("SW-ETG2-01"), "nom court")
        try expectEqual(DeviceEntry.parse("imprimante.exemple.ca."), .hostname("imprimante.exemple.ca"), "point final retiré")
        try expectEqual(DeviceEntry.parse("cafe.beef"), .hostname("cafe.beef"), "lettres hexadécimales sans chiffre : un nom")
        try expectEqual(DeviceEntry.parse("-routeur"), .invalid("Un nom d’hôte ne commence ni ne finit par un tiret"), "tiret")
        try expectEqual(DeviceEntry.parse("poste_12"), .invalid("Caractère «\u{00A0}_\u{00A0}» interdit dans un nom d’hôte"), "souligné")
        try expectEqual(DeviceEntry.parse("Imprimante accueil"),
                        .invalid("Ni une adresse, ni un nom d’hôte (pas d’espace dans un nom d’hôte)\u{00A0}: choisissez une suggestion"),
                        "espace")
        try expectEqual(DeviceEntry.parse("a." + String(repeating: "b", count: 64)),
                        .invalid("Partie du nom trop longue (63 caractères au plus)"), "étiquette trop longue")
        try expectEqual(DeviceEntry.validHostname("srv.10"), nil, "dernier niveau numérique")
    }

    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let scanner: [DeviceLookupCandidate] = [
        DeviceLookupCandidate(id: "s1", origin: .scanner, ip: IPv4Address("10.182.122.1"), name: "Passerelle",
                              hostname: "FortiGate-60F", vendor: "Fortinet", type: .routeur, isOnline: true),
        DeviceLookupCandidate(id: "s111", origin: .scanner, ip: IPv4Address("10.182.122.111"), mac: printerMAC,
                              name: "Imprimante accueil", hostname: "Brother DCP-L2640DW", vendor: "Brother",
                              type: .imprimante, isOnline: true),
        DeviceLookupCandidate(id: "s146", origin: .scanner, ip: IPv4Address("10.182.122.146"), name: "Poste réception",
                              hostname: "WKS341", vendor: "Dell", type: .poste, isOnline: false),
        DeviceLookupCandidate(id: "s10", origin: .scanner, ip: IPv4Address("10.10.0.10"), hostname: "SRV-AD-01",
                              vendor: "Dell", type: .serveur, isOnline: true),
    ]

    suite.add("Suggestions : début d'IP, nom sans accents, MAC partielle, fabricant") {
        let ip = DeviceLookup.suggestions(for: "10.182", in: scanner)
        try expectEqual(ip.map(\.candidate.id), ["s1", "s111", "s146"], "début d'IP, en ligne d'abord puis par adresse")
        try expect(ip.allSatisfy { $0.field == .ip && !$0.isExact }, "champ IP, non exact")
        let exact = DeviceLookup.suggestions(for: "10.182.122.111", in: scanner)
        try expectEqual(exact.first?.candidate.id, "s111", "IP exacte d'abord")
        try expect(exact.first?.isExact == true, "IP exacte")
        try expectEqual(DeviceLookup.suggestions(for: "reception", in: scanner).first?.candidate.id, "s146", "sans accent")
        try expectEqual(DeviceLookup.suggestions(for: "accueil", in: scanner).first?.field, .name, "mot du nom")
        let mac = DeviceLookup.suggestions(for: "94-dd-f8", in: scanner)
        try expectEqual(mac.map(\.candidate.id), ["s111"], "début de MAC, autre écriture")
        try expectEqual(mac.first?.field, .mac, "champ MAC")
        try expectEqual(DeviceLookup.suggestions(for: "94DDF818157D", in: scanner).first?.isExact, true, "MAC exacte")
        let dell = DeviceLookup.suggestions(for: "dell", in: scanner)
        try expectEqual(dell.map(\.candidate.id), ["s10", "s146"], "fabricant, en ligne d'abord")
        try expectEqual(DeviceLookup.suggestions(for: "srv-ad", in: scanner).first?.field, .hostname, "nom d'hôte")
        try expectEqual(DeviceLookup.suggestions(for: "", in: scanner).count, 0, "vide : rien")
        try expectEqual(DeviceLookup.suggestions(for: "10", in: scanner, limit: 2).count, 2, "limite")
        try expectEqual(DeviceLookup.exactMatch(for: "passerelle", in: scanner)?.candidate.id, "s1", "Entrée : nom exact")
        try expect(DeviceLookup.exactMatch(for: "10.182", in: scanner) == nil, "Entrée : pas de fiche sans saisie exacte")
    }

    suite.add("Suggestions : doublons retirés par site, Scanner d'abord") {
        let inventory = DeviceLookupCandidate(id: "inv", origin: .inventory, ip: IPv4Address("10.182.122.150"), mac: printerMAC,
                                              name: "Ancienne fiche", type: .imprimante)
        let inventoryOnly = DeviceLookupCandidate(id: "inv2", origin: .inventory, ip: IPv4Address("10.182.122.160"),
                                                  name: "Mini PC salle de conférence", type: .poste)
        let laval = DeviceLookupCandidate(id: "laval", origin: .otherSite, siteKey: "laval", siteName: "Laval",
                                          ip: IPv4Address("10.182.122.111"), name: "Imprimante Laval", type: .imprimante)
        let manualSameIP = DeviceLookupCandidate(id: "man", origin: .manual, ip: IPv4Address("10.182.122.146"), name: "Saisie")
        let merged = DeviceLookup.deduplicated([inventory, inventoryOnly, laval, manualSameIP] + scanner)
        try expectEqual(merged.map(\.id), ["s1", "s111", "s146", "s10", "inv2", "laval"],
                        "même MAC (inventaire) et même IP sans MAC (saisie) retirés ; l'autre site est un autre appareil")
        let found = DeviceLookup.suggestions(for: "10.182.122.111", in: merged)
        try expectEqual(found.map(\.candidate.id), ["s111", "laval"], "à égalité, le Scanner avant l'autre site")
    }

    suite.add("Saisie à la main : fiche affichée, jamais vérifiée puis vérifiée") {
        var entry = ManualDeviceEntry(ip: IPv4Address("10.182.122.160")!, mac: MACAddress("1c-69-7a-0b-44-e2"),
                                      name: "  Mini PC salle de conférence ", type: .poste, created: now)
        try expectEqual(entry.name, "Mini PC salle de conférence", "nom nettoyé")
        var device = entry.device
        try expectEqual(device.id, "10.182.122.160", "même identifiant qu'un appareil scanné (l'IP)")
        try expectEqual(device.displayName, "Mini PC salle de conférence", "nom affiché")
        try expect(!device.isOnline && device.latencyMs == nil, "jamais vérifiée : hors ligne")
        try expectEqual(device.lastSeen, now, "vue à la date de la saisie")
        try expectEqual(entry.originLabel, "Saisi à la main · pas encore vu par un scan", "libellé")
        entry.lastCheck = ManualDeviceEntry.Check(date: now.addingTimeInterval(60), latencyMs: 3.4)
        device = entry.device
        try expect(device.isOnline, "répond : en ligne")
        try expectEqual(device.latencyMs, 3.4, "latence")
        try expectEqual(device.lastSeen, now.addingTimeInterval(60), "vue à la vérification")
        entry.lastCheck = ManualDeviceEntry.Check(date: now.addingTimeInterval(120), latencyMs: nil)
        try expect(!entry.device.isOnline, "pas de réponse : hors ligne")
        let data = try JSONEncoder().encode(entry)
        try expectEqual(try JSONDecoder().decode(ManualDeviceEntry.self, from: data), entry, "aller-retour JSON")
    }

    suite.add("Saisie à la main : rattachement par MAC, sinon par IP, noms conservés") {
        let scanned = [
            Device(ip: IPv4Address("10.182.122.170")!, mac: MACAddress("1C:69:7A:0B:44:E2"), hostname: "MINIPC-SALLE"),
            Device(ip: IPv4Address("10.182.122.111")!, mac: printerMAC, customName: "Imprimante accueil"),
            Device(ip: IPv4Address("10.182.122.50")!, mac: MACAddress("00:11:22:33:44:55")),
        ]
        let byMAC = ManualDeviceEntry(ip: IPv4Address("10.182.122.160")!, mac: MACAddress("1C:69:7A:0B:44:E2"),
                                      name: "Mini PC salle", created: now)
        let byIP = ManualDeviceEntry(ip: IPv4Address("10.182.122.111")!, name: "Brother accueil", created: now)
        let otherMAC = ManualDeviceEntry(ip: IPv4Address("10.182.122.50")!, mac: MACAddress("AA:BB:CC:00:00:01"), created: now)
        let unseen = ManualDeviceEntry(ip: IPv4Address("10.182.122.200")!, created: now)
        let laval = ManualDeviceEntry(reference: Device(ip: IPv4Address("10.182.122.50")!), source: .otherSite("Laval"), created: now)
        let result = ManualDevices.attach([byMAC, byIP, otherMAC, unseen, laval], to: scanned)
        try expectEqual(result.attached.map(\.deviceID), ["10.182.122.170", "10.182.122.111"], "MAC (IP changée) puis IP")
        try expectEqual(result.attached[0].customName, "Mini PC salle", "le nom saisi devient le nom de l'appareil")
        try expectEqual(result.attached[1].customName, nil, "nom déjà donné : gardé")
        try expectEqual(result.attached[1].nameForNotes, "Brother accueil", "le nom saisi va dans les notes")
        try expectEqual(result.remaining.map(\.ip.description), ["10.182.122.50", "10.182.122.200", "10.182.122.50"],
                        "MAC différente, jamais vu, autre site par IP seule : non rattachés")
        try expectEqual(ManualDevices.mergedNotes(scanned: "Toner changé", typed: "Prêt à la salle 2.08", nameForNotes: "Brother accueil"),
                        "Toner changé\nPrêt à la salle 2.08\nNom saisi à la main\u{00A0}: Brother accueil", "notes réunies")
        try expectEqual(ManualDevices.mergedNotes(scanned: "Prêt à la salle 2.08", typed: "Prêt à la salle 2.08", nameForNotes: nil),
                        "Prêt à la salle 2.08", "sans doublon")
    }

    suite.add("Saisie à la main : une saisie par IP, récents sans doublon") {
        let first = ManualDeviceEntry(ip: IPv4Address("10.0.0.5")!, name: "A", created: now)
        let second = ManualDeviceEntry(ip: IPv4Address("10.0.0.6")!, name: "B", created: now)
        let again = ManualDeviceEntry(ip: IPv4Address("10.0.0.5")!, name: "A2", created: now)
        let list = ManualDevices.upsert(again, into: ManualDevices.upsert(second, into: ManualDevices.upsert(first, into: [])))
        try expectEqual(list.map(\.name), ["A2", "B"], "même IP remplacée, la plus récente d'abord")
        var many: [ManualDeviceEntry] = []
        for index in 0..<30 { many = ManualDevices.upsert(ManualDeviceEntry(ip: IPv4Address(UInt32(index + 1)), created: now), into: many) }
        try expectEqual(many.count, ManualDevices.keptCount, "au plus \(ManualDevices.keptCount)")

        let printer = DeviceRecentView(ip: IPv4Address("10.182.122.111")!, mac: printerMAC, name: "Imprimante", type: .imprimante, viewed: now)
        let moved = DeviceRecentView(ip: IPv4Address("10.182.122.150")!, mac: printerMAC, name: "Imprimante", type: .imprimante,
                                     viewed: now.addingTimeInterval(10))
        let manual = DeviceRecentView(ip: IPv4Address("10.182.122.160")!, name: "Mini PC", type: .poste,
                                      viewed: now.addingTimeInterval(20), isManual: true)
        var recents = DeviceRecents.record(printer, in: [])
        recents = DeviceRecents.record(moved, in: recents)
        recents = DeviceRecents.record(manual, in: recents)
        try expectEqual(recents.map(\.ip.description), ["10.182.122.160", "10.182.122.150"], "même MAC : une seule ligne")
        try expectEqual(DeviceRecents.record(manual, in: recents, limit: 1).count, 1, "limite")
    }

    suite.add("Saisie à la main : chaque site garde ses saisies et ses récents") {
        let siteA = ManualDeviceEntry(ip: IPv4Address("10.0.0.5")!, name: "Saisie du site A", created: now, siteKey: "a")
        let siteB = ManualDeviceEntry(ip: IPv4Address("10.0.0.5")!, name: "Saisie du site B", created: now, siteKey: "b")
        let old = ManualDeviceEntry(ip: IPv4Address("10.0.0.9")!, name: "Sans site", created: now)
        let list = ManualDevices.upsert(siteB, into: ManualDevices.upsert(siteA, into: [old]))
        try expectEqual(list.map(\.name), ["Saisie du site B", "Saisie du site A", "Sans site"],
                        "même IP dans deux sites : deux saisies")
        try expectEqual(ManualDevices.visible(list, site: "a").map(\.name), ["Saisie du site A", "Sans site"], "site A")
        // Un scan du site B ne rattache que les saisies du site B (AppState filtre par `visible`).
        let scannedB = [Device(ip: IPv4Address("10.0.0.5")!, mac: MACAddress("00:11:22:33:44:66"))]
        let result = ManualDevices.attach(ManualDevices.visible(list, site: "b"), to: scannedB)
        try expectEqual(result.attached.map(\.entry.name), ["Saisie du site B"], "la saisie du site A n'est pas rattachée")

        let viewA = DeviceRecentView(ip: IPv4Address("10.0.0.5")!, name: "A", type: .poste, viewed: now, siteKey: "a")
        let viewB = DeviceRecentView(ip: IPv4Address("10.0.0.5")!, name: "B", type: .poste, viewed: now, siteKey: "b")
        try expectEqual(DeviceRecents.record(viewB, in: [viewA]).count, 2, "même IP dans deux sites : deux visites")
        // Fiche fermée puis revue : une ancienne visite sans site (visible partout) est remplacée, pas doublée.
        let legacyView = DeviceRecentView(ip: IPv4Address("10.0.0.5")!, name: "A", type: .poste, viewed: now.addingTimeInterval(-240))
        try expectEqual(DeviceRecents.record(viewA, in: [legacyView]), [viewA], "visite sans site remplacée par celle du site")

        // Fichier d'avant les sites : la saisie se lit (sans site, visible partout).
        let legacy = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        try expect(!legacy.contains("siteKey") && !legacy.contains("openPorts"), "champs absents de l'ancien format")
        let decoded = try JSONDecoder().decode(ManualDeviceEntry.self, from: Data(legacy.utf8))
        try expectEqual(decoded.siteKey, nil, "sans site")
        try expect(decoded.belongs(to: "a") && decoded.belongs(to: "b"), "visible dans tous les sites")
    }

    suite.add("Fiche reprise : jamais présentée en ligne sans vérification, ports de la fiche") {
        var base = Device(ip: IPv4Address("192.168.1.1")!, mac: MACAddress("00:09:0F:AA:BB:CC"), isOnline: true,
                          latencyMs: 3, openPorts: [443], firstSeen: now, lastSeen: now)
        base.snmpKind = nil
        var entry = ManualDeviceEntry(reference: base, source: .otherSite("Laval"), created: now)
        try expect(!entry.device.isOnline && entry.device.latencyMs == nil, "état d'un autre site : pas en ligne ici")
        try expectEqual(entry.device.lastSeen, now, "dernière détection ailleurs gardée")
        try expectEqual(entry.createdVerb, "Ouvert", "fiche reprise : « Ouvert »")
        try expectEqual(ManualDeviceEntry(ip: base.ip, created: now).createdVerb, "Saisi", "saisie : « Saisi »")
        try expectEqual(entry.device.openPorts, [443], "ports de la fiche reprise")
        entry.openPorts = [22, 443]
        try expectEqual(entry.device.openPorts, [22, 443], "ports trouvés par un outil de la fiche")
        entry.lastCheck = ManualDeviceEntry.Check(date: now, latencyMs: 2)
        try expect(entry.device.isOnline, "vérifiée : en ligne")
    }

    suite.add("Ressources d'un poste : ce que la saisie désigne (appareil connu, adresse, nom, MAC)") {
        let server = DeviceLookupCandidate(id: "s", origin: .scanner, ip: IPv4Address("10.10.0.10"),
                                           mac: MACAddress("00:15:5D:0A:10:01"), name: "SRV-AD-01", type: .serveur)
        let noAddress = DeviceLookupCandidate(id: "i", origin: .inventory, ip: nil, mac: printerMAC, name: "Imprimante entrepôt")
        let list = [server, noAddress]
        try expectEqual(DeviceLookup.target(for: "  ", in: list), .empty, "vide")
        try expectEqual(DeviceLookup.target(for: "10.10.0.10", in: list), .known(server), "IP connue")
        try expectEqual(DeviceLookup.target(for: "srv-ad-01", in: list), .known(server), "nom connu, casse ignorée")
        try expectEqual(DeviceLookup.target(for: "00-15-5d-0a-10-01", in: list), .known(server), "MAC connue")
        try expectEqual(DeviceLookup.target(for: "10.10.0.10", in: list).address, IPv4Address("10.10.0.10"), "adresse à interroger")
        try expectEqual(DeviceLookup.target(for: "10.10.0.99", in: list), .address(IPv4Address("10.10.0.99")!), "IP inconnue")
        try expectEqual(DeviceLookup.target(for: "10.10.0.99", in: list).address, IPv4Address("10.10.0.99"), "interrogée telle quelle")
        try expectEqual(DeviceLookup.target(for: "poste-compta-3", in: list), .hostname("poste-compta-3"), "nom inconnu : à résoudre")
        try expect(DeviceLookup.target(for: "poste-compta-3", in: list).address == nil, "un nom n'est jamais résolu sans demande")
        try expectEqual(DeviceLookup.target(for: "94:dd:f8:18:15:7d", in: list), .unknownMAC(printerMAC),
                        "MAC connue sans adresse : rien à interroger")
        try expectEqual(DeviceLookup.target(for: "10.10", in: list), .invalid("Adresse IP incomplète\u{00A0}: 2 octets sur 4"), "incomplète")
    }

    suite.add("Fermer la fiche : ⇧⌘W par défaut, sans conflit") {
        let action = ShortcutCatalog.fixedActions.first { $0.id == ShortcutID.closeDevice }
        try expectEqual(action?.defaultCombo, KeyCombo("w", [.shift, .command]), "⇧⌘W")
        let actions = ShortcutCatalog.fixedActions + ShortcutCatalog.screenActions(NavModule.allCases.map { ($0.rawValue, $0.title) })
        try expect(ShortcutSettings().conflicts(in: actions)[ShortcutID.closeDevice] == nil, "aucun conflit, ni avec macOS")
    }
}
