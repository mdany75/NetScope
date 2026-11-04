import Foundation
import NetScopeCore

// Rapports : sections construites à partir de données fixes, pagination et exports CSV, JSON,
// HTML. Aucun accès réseau ; un seul dossier temporaire pour l'index des rapports.

private let r0 = Date(timeIntervalSince1970: 1_793_700_000)

private func rdev(_ ip: String, _ mac: String?, host: String, type: DeviceType, online: Bool = true, ports: [UInt16] = [],
                  sw: String? = nil, port: String? = nil, vlan: Int? = nil, vendor: String? = nil) -> Device {
    Device(ip: IPv4Address(ip)!, mac: mac.flatMap(MACAddress.init), vendor: vendor, hostname: host, isOnline: online,
           openPorts: ports, switchName: sw, switchPort: port, vlan: vlan, firstSeen: r0, lastSeen: r0,
           rangeLabel: "Bureau", deviceType: type)
}

private func sampleDevices() -> [Device] {
    [
        rdev("10.182.122.1", "04:D5:90:3A:7B:11", host: "FortiGate-60F", type: .routeur, ports: [22, 443], sw: "SW-CORE-01", port: "Gi1/0/1", vlan: 1, vendor: "Fortinet"),
        rdev("10.182.122.2", "70:0F:6A:91:4C:02", host: "SW-CORE-01", type: .switch, ports: [22, 23, 443], vlan: 1, vendor: "Cisco"),
        rdev("10.182.122.3", "88:3A:30:5D:E1:40", host: "SW-ETG2-01", type: .switch, ports: [22, 80, 443], sw: "SW-CORE-01", port: "Gi1/0/47", vlan: 1),
        rdev("10.182.122.102", "70:4C:A5:1E:22:9A", host: "FortiAP-231F", type: .pointAcces, sw: "SW-CORE-01", port: "Gi1/0/12", vlan: 20),
        rdev("10.182.122.133", "D6:4E:81:7A:33:C0", host: "Android_89UM1WTN", type: .telephone, sw: "FortiAP-231F", port: "Wi-Fi", vlan: 20),
        rdev("10.182.122.117", "B0:7B:25:44:A1:6C", host: "WKS346", type: .poste, ports: [135, 445, 3389], sw: "SW-CORE-01", port: "Gi1/0/22", vlan: 1, vendor: "Dell"),
        rdev("10.182.122.140", "00:1A:2B:44:10:EE", host: "NPI7A4410", type: .imprimante, ports: [80, 9100], sw: "SW-ETG2-01", port: "1/18", vlan: 30),
        rdev("10.182.122.146", "B0:7B:25:44:9F:20", host: "WKS341", type: .poste, online: false, sw: "SW-CORE-01", port: "Gi1/0/23", vlan: 1),
        rdev("10.182.122.150", "3A:1F:C7:02:9B:E4", host: "=HYPERLINK(\"http://x\")", type: .inconnu, ports: [8080], vlan: 1),
        rdev("192.168.50.21", "BC:AD:28:6F:01:5A", host: "Caméra-Quai", type: .camera, ports: [80, 554], sw: "SW-CORE-01", port: "Gi1/0/33", vlan: 40),
    ]
}

private func sampleInput() -> ReportInput {
    let devices = sampleDevices()
    var store = InventoryStore()
    store.merge(devices, at: r0)
    // Deux MAC sur 10.182.122.140 dans le même scan : conflit IP.
    var twin = devices.first { $0.id == "10.182.122.140" }!
    twin.mac = MACAddress("5C:F9:38:02:7A:41")
    store.merge(devices + [twin], at: r0.addingTimeInterval(60))
    return ReportInput(
        devices: devices, records: store.sortedRecords,
        ranges: [ReportRange(label: "Bureau", text: "10.182.122.0/24", vlan: 1), ReportRange(label: "Caméras", text: "192.168.50.0/24", vlan: 40)],
        switches: [ReportSwitch(name: "SW-CORE-01", model: "Cisco Catalyst 9300-48P", ip: "10.182.122.2", activePorts: 41, totalPorts: 48,
                                firmware: "17.6.4", firmwareOutdated: true, uplink: "Te1/1/1")],
        links: ["SW-CORE-01 Te1/1/1 ↔ SW-ETG2-01 1/25 (LLDP)"],
        radios: ["10.182.122.102": ReportRadio(channel24: 6, channel5: 36, congested24: true)],
        extraProblems: [ReportProblem(title: "DHCP non autorisé sur 10.182.122.250", severity: .critique, recommendation: "Débrancher l’appareil.")],
        annex: [ReportRawLine("SW-ETG2-01# show mac-address"), ReportRawLine(" 1/18   30    ", mac: MACAddress("00:1A:2B:44:10:EE"), suffix: "   dynamic")],
        sourceName: "Macmini-de-Dany", sourceIP: "10.182.122.135", gateway: "10.182.122.1 (FortiGate-60F)", now: r0.addingTimeInterval(120))
}

private func sampleConfig(_ template: ReportTemplate = .audit) -> ReportConfig {
    ReportConfig(template: template, client: "Groupe Exemple", site: "Siège social", technician: "Dany Ménard", date: "2026-11-03")
}

private func texts(_ document: ReportDocument, _ kind: ReportSectionKind) -> [String] {
    guard let section = document.section(kind) else { return [] }
    var result: [String] = []
    for block in section.blocks {
        switch block {
        case .paragraph(let t), .note(let t): result.append(t)
        case .kpis(let k): result += k.map { $0.value + " " + $0.label }
        case .bars(let title, let bars): result.append(title); result += bars.map(\.label)
        case .table(let table): result += table.rows.flatMap { $0.cells.map(\.text) }
        case .code(let lines): result += lines
        }
    }
    return result
}

func registerReportTests(_ suite: TestSuite) {
    suite.add("Rapport\u{00A0}: modèles, sections par défaut, titre, référence et nom de fichier") {
        var config = sampleConfig()
        try expectEqual(config.sections.count, 7, "audit\u{00A0}: 7 sections")
        try expect(!config.includes(.annexe), "audit sans annexe")
        config.apply(.securite)
        try expectEqual(config.sections, [.resume, .switchs, .securite, .problemes], "sécurité")
        config.apply(.inventaire)
        try expect(config.includes(.annexe) && config.includes(.plan), "inventaire\u{00A0}: plan et annexe")
        try expectEqual(config.documentTitle, "Inventaire réseau — Siège social", "titre")
        try expectEqual(config.dateLabel, "3 novembre 2026", "date longue")
        try expectEqual(config.reference, "RPT-20261103-01", "référence")
        try expectEqual(config.fileName(for: .pdf), "rapport-inventaire-siege-social-2026-11-03.pdf", "nom de fichier sans accents")
        try expectEqual(ReportText.slug("../Él/ève\u{00A0}: «test»"), "el-eve-test", "slug sans séparateur de chemin")
        try expectEqual(ReportConfig(site: "").documentTitle, "Rapport d’audit réseau — [À COMPLÉTER]", "site manquant")
        try expectEqual(ReportText.longDate("2026-13-01"), nil, "mois invalide")
        try expectEqual(ReportText.percent(0.444), "44\u{00A0}%", "pourcentage avec espace insécable")
        try expectEqual(ReportText.mac(MACAddress("8C:16:45:2B:9E:03"), masked: true), "8C:16:45:xx:xx:xx", "MAC masquée")
    }

    suite.add("Rapport\u{00A0}: ports à risque (Telnet, SMB, RDP, VNC, HTTP d’administration)") {
        try expectEqual(ReportBuilder.risk(port: 23, type: .switch)?.severity, .eleve, "Telnet élevé")
        try expectEqual(ReportBuilder.risk(port: 445, type: .poste)?.severity, .moyen, "SMB moyen")
        try expectEqual(ReportBuilder.risk(port: 3389, type: .poste)?.severity, .moyen, "RDP moyen")
        try expectEqual(ReportBuilder.risk(port: 5900, type: .poste)?.severity, .moyen, "VNC moyen")
        try expect(ReportBuilder.risk(port: 80, type: .imprimante) == nil, "HTTP d'une imprimante\u{00A0}: pas listé")
        try expect(ReportBuilder.risk(port: 80, type: .switch) != nil, "HTTP d'un switch\u{00A0}: listé")
        try expect(ReportBuilder.risk(port: 443, type: .switch) == nil, "HTTPS\u{00A0}: pas listé")
        let ports = ReportBuilder.riskyPorts(sampleDevices())
        try expectEqual(ports.first?.port, 23, "Telnet en tête (le plus grave)")
        try expectEqual(ports.map(\.port).sorted(), [23, 80, 445, 3389, 8080], "ports retenus")
    }

    suite.add("Rapport\u{00A0}: problèmes (conflit IP, DHCP, Telnet, hors ligne, firmware) triés par gravité") {
        let problems = ReportBuilder.problems(sampleInput())
        let titles = problems.map(\.title)
        try expectEqual(problems.first?.title, "Conflit IP sur 10.182.122.140", "conflit en premier")
        try expect(problems.first?.recommendation.contains("5C:F9:38:02:7A:41") == true, "les deux MAC citées")
        try expect(titles.contains("DHCP non autorisé sur 10.182.122.250"), "problème fourni")
        try expect(titles.contains("Telnet ouvert sur SW-CORE-01"), "Telnet")
        try expect(titles.contains { $0.hasPrefix("WKS341") && $0.hasSuffix("hors ligne") }, "poste hors ligne")
        try expect(titles.contains("Firmware SW-CORE-01 17.6.4"), "firmware signalé")
        try expect(titles.contains("1 appareil non identifié"), "appareil inconnu")
        let ranks = problems.map(\.severity)
        try expectEqual(ranks, ranks.sorted(), "tri par gravité")
    }

    suite.add("Rapport\u{00A0}: sections construites à partir des appareils, de l’inventaire et des switchs") {
        let input = sampleInput()
        let document = ReportBuilder.build(config: sampleConfig(), input: input, generator: "NetScope 9.9")
        try expectEqual(document.sections.map(\.kind), [.resume, .plan, .switchs, .wifi, .securite, .problemes, .inventaire],
                        "ordre du document")
        try expectEqual(document.sections.map(\.heading).first, "1. Résumé", "numérotation")
        try expectEqual(document.sections.last?.heading, "7. Inventaire", "inventaire en dernier")

        let resume = texts(document, .resume)
        try expect(resume.contains("10 appareils"), "indicateur appareils")
        try expect(resume.contains { $0.hasPrefix("1 switch") }, "un switch relevé")
        try expect(resume.contains { $0.contains("dont 2 critiques") }, "deux critiques\u{00A0}: \(resume)")
        try expect(resume.first?.contains("Macmini-de-Dany (10.182.122.135)") == true, "poste source")
        try expect(resume.first?.contains("10.182.122.0/24 et 192.168.50.0/24") == true, "plages")

        let plan = texts(document, .plan)
        try expect(plan.contains("Sous-total"), "sous-total du /24 à plusieurs VLAN")
        try expect(plan.contains("192.168.50.0/24"), "deuxième réseau")
        try expect(plan.contains { $0.contains("Passerelle 10.182.122.1") }, "passerelle")

        let wifi = texts(document, .wifi)
        try expect(wifi.contains("Canal 6 · encombré") && wifi.contains("Canal 36"), "radios")
        try expect(wifi.contains("1"), "un client Wi-Fi sur la borne")

        let security = texts(document, .securite)
        try expect(security.contains("Telnet (administration)") && security.contains("RDP (bureau à distance)"), "services")

        let inventory = texts(document, .inventaire)
        try expect(inventory.contains("Conflit IP"), "état conflit")
        try expect(inventory.contains("Hors ligne"), "état hors ligne")
        try expect(inventory.contains("SW-ETG2-01 1/18"), "emplacement physique")
        try expect(inventory.contains("B0:7B:25:44:A1:6C"), "MAC visible")

        var masked = sampleConfig(.inventaire)
        masked.maskMAC = true
        let maskedDocument = ReportBuilder.build(config: masked, input: input)
        let maskedTexts = texts(maskedDocument, .inventaire) + texts(maskedDocument, .annexe)
        try expect(!maskedTexts.contains { $0.contains("44:A1:6C") || $0.contains("10:ee") || $0.contains("10:EE") }, "MAC masquées")
        try expect(maskedTexts.contains("B0:7B:25:xx:xx:xx"), "préfixe gardé")
        try expect(texts(maskedDocument, .annexe).contains { $0.contains("is-at 5c:f9:38:xx:xx:xx   (doublon)") }, "annexe\u{00A0}: doublon ARP")
    }

    suite.add("Rapport\u{00A0}: données absentes, sections vides lisibles") {
        let document = ReportBuilder.build(config: sampleConfig(), input: ReportInput(devices: []))
        try expect(texts(document, .plan).first?.contains("lancez un scan") == true, "plan vide")
        try expect(texts(document, .switchs).first?.contains("Aucun switch") == true, "pas de switch")
        try expect(texts(document, .problemes).first?.contains("Aucun problème") == true, "aucun problème")
        let none = ReportBuilder.build(config: ReportConfig(sections: []), input: ReportInput(devices: []))
        let pages = ReportPaginator.paginate(none)
        try expectEqual(pages.count, 1, "une page même sans section")
        try expect(pages[0].hasSignature, "signature sur la seule page")
    }

    suite.add("Rapport\u{00A0}: firmware lu dans sysDescr et résumé d’un relevé SNMP") {
        try expectEqual(ReportSwitch.firmware(in: "Cisco Catalyst 9300-48P, IOS XE Software, Version 17.9.4a"), "17.9.4a", "Cisco")
        try expectEqual(ReportSwitch.firmware(in: "Aruba JL261A 2930F-24G-PoE+-4SFP+ Switch, revision WC.16.11.0012"), "WC.16.11.0012", "Aruba")
        try expectEqual(ReportSwitch.firmware(in: "FortiGate-60F v7.2.8"), "7.2.8", "v7.2.8")
        try expectEqual(ReportSwitch.firmware(in: "Switch générique"), nil, "inconnu")
        let interfaces = (1...4).map { SNMPInterface(index: $0, name: "Gi1/0/\($0)", descr: "GigabitEthernet1/0/\($0)", alias: "",
                                                     operStatus: $0 == 4 ? .down : .up, speedMbps: 1000) }
        let snapshot = SNMPSwitchSnapshot(host: IPv4Address("10.0.0.2")!,
                                          system: SNMPSystemInfo(name: "SW-TEST", descr: "Cisco Catalyst 2960X-24, Version 15.2(7)E8"),
                                          interfaces: interfaces,
                                          neighbors: [SNMPLLDPNeighbor(localPortNum: 1, ifIndex: 1, sysName: "SW-CORE", portID: "Gi1/0/47",
                                                                       capabilities: [.bridge])])
        let sw = ReportSwitch(snapshot: snapshot)
        try expectEqual(sw.model, "Cisco Catalyst 2960X-24", "modèle")
        try expectEqual(sw.firmware, "15.2(7)E8", "version")
        try expectEqual(sw.activePorts, 3, "ports actifs")
        try expectEqual(sw.totalPorts, 4, "ports physiques")
        try expectEqual(sw.uplink, "Gi1/0/1", "uplink LLDP")
    }

    suite.add("Rapport\u{00A0}: pagination lettre, tableaux coupés avec «\u{00A0}(suite)\u{00A0}», signature en dernière page") {
        var devices: [Device] = []
        for n in 1...120 {
            devices.append(rdev("10.0.\(n / 250).\(n % 250 + 1)", nil, host: "POSTE-\(n)", type: .poste, ports: n % 10 == 0 ? [3389] : [],
                                sw: "SW-1", port: "Gi1/0/\(n % 48 + 1)", vlan: 1))
        }
        let document = ReportBuilder.build(config: sampleConfig(), input: ReportInput(devices: devices))
        let metrics = ReportPageMetrics()
        let pages = ReportPaginator.paginate(document, metrics: metrics)
        try expect(pages.count >= 4, "plusieurs pages (\(pages.count))")
        try expectEqual(pages.map(\.number), Array(1...pages.count), "pages numérotées")
        for page in pages {
            try expect(page.used <= metrics.contentHeight + 0.5, "page \(page.number) remplie sans débordement (\(page.used))")
        }
        // Chaque ligne de l'inventaire apparaît une seule fois, dans l'ordre.
        var inventoryRows: [String] = []
        var continued = 0
        for page in pages {
            var current: String?
            for item in page.items {
                switch item {
                case .heading(let title, let isContinued):
                    current = title
                    if isContinued { continued += 1 }
                case .block(.table(let table)) where current?.hasSuffix("Inventaire") == true:
                    inventoryRows += table.rows.map { $0.cells[1].text }
                default: break
                }
            }
        }
        try expectEqual(inventoryRows, (1...120).map { "POSTE-\($0)" }, "toutes les lignes, une seule fois")
        try expect(continued >= 2, "titre répété sur les pages de suite")
        try expectEqual(pages.filter(\.hasSignature).map(\.number), [pages.count], "signature en dernière page seulement")
        try expect(!pages[pages.count - 1].items.isEmpty, "la signature n'est jamais seule sur sa page")

        // Page pleine qui finit par un tableau : ses deux dernières lignes accompagnent la signature.
        let rows = (1...40).map { ReportRow([ReportCell("ligne \($0)")]) }
        let full = ReportDocument(title: "T", template: .audit, client: "", site: "", technician: "", date: "", dateLabel: "",
                                  reference: "", generator: "", signature: true,
                                  sections: [ReportSection(kind: .inventaire, heading: "1. Inventaire",
                                                           blocks: [.table(ReportTable(columns: [ReportColumn("A")], rows: rows))])],
                                  problems: [])
        let fullPages = ReportPaginator.paginate(full, metrics: metrics)
        let lastPage = fullPages[fullPages.count - 1]
        try expect(lastPage.hasSignature, "signature sur la dernière page")
        var tail: [String] = []
        for case .block(.table(let part)) in lastPage.items { tail += part.rows.map { $0.cells[0].text } }
        try expect(!tail.isEmpty && tail.last == "ligne 40", "dernières lignes avec la signature (\(tail))")
        var all: [String] = []
        for page in fullPages { for case .block(.table(let part)) in page.items { all += part.rows.map { $0.cells[0].text } } }
        try expectEqual(all, rows.map { $0.cells[0].text }, "aucune ligne perdue ni doublée")

        // Annexe brute plus longue qu'une page : coupée entre deux lignes, sans rien perdre.
        let raw = (1...120).map { "ligne brute \($0)" }
        var annexDocument = full
        annexDocument.sections = [ReportSection(kind: .annexe, heading: "1. Annexe brute", blocks: [.note("Extrait."), .code(raw)])]
        let annexPages = ReportPaginator.paginate(annexDocument, metrics: metrics)
        var rawSeen: [String] = []
        for page in annexPages {
            try expect(page.used <= metrics.contentHeight + 0.5, "annexe\u{00A0}: page \(page.number) sans débordement")
            for case .block(.code(let lines)) in page.items { rawSeen += lines }
        }
        try expect(annexPages.count >= 3, "annexe sur plusieurs pages")
        try expectEqual(rawSeen, raw, "toutes les lignes brutes, dans l'ordre")
        let starts = ReportPaginator.startPages(pages)
        try expectEqual(starts[.resume], 1, "résumé en page 1")
        try expect((starts[.inventaire] ?? 0) >= (starts[.problemes] ?? 99), "inventaire après les problèmes")

        // Le démo du croquis : sans annexe, l'audit tient en peu de pages.
        let small = ReportPaginator.paginate(ReportBuilder.build(config: sampleConfig(), input: sampleInput()), metrics: metrics)
        try expect((2...4).contains(small.count), "audit de 10 appareils\u{00A0}: 2 à 4 pages (\(small.count))")
    }

    suite.add("Rapport\u{00A0}: export CSV protégé contre les formules") {
        let document = ReportBuilder.build(config: sampleConfig(), input: sampleInput())
        let csv = ReportExport.csv(document)
        try expect(csv.hasPrefix("Rapport d’audit réseau — Siège social\r\n"), "titre en première ligne")
        try expect(csv.contains("\r\n7. Inventaire\r\nIP;Nom;Type;MAC;Port;VLAN;État\r\n"), "section et en-têtes")
        try expect(csv.contains("\"'=HYPERLINK(\"\"http://x\"\")\""), "formule neutralisée et guillemets doublés")
        try expect(!csv.contains(";=HYPERLINK"), "aucune cellule ne commence par =")
        try expect(ReportExport.csvData(document).starts(with: [0xEF, 0xBB, 0xBF]), "BOM UTF-8")
        try expect(ReportExport.csvRowCount(document) > 20, "lignes de données")
    }

    suite.add("Rapport\u{00A0}: export JSON structuré") {
        let document = ReportBuilder.build(config: sampleConfig(), input: sampleInput())
        let data = try ReportExport.json(document)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = root["rapport"] as? [String: Any],
              let sections = root["sections"] as? [[String: Any]],
              let problems = root["problemes"] as? [[String: Any]] else {
            throw TestFailure(message: "structure JSON inattendue", file: #fileID, line: #line)
        }
        try expectEqual(meta["client"] as? String, "Groupe Exemple", "client")
        try expectEqual(meta["reference"] as? String, "RPT-20261103-01", "référence")
        try expectEqual(sections.count, 7, "sections")
        let inventory = sections.first { ($0["id"] as? String) == "inventaire" }
        let rows = ((inventory?["tableaux"] as? [[String: Any]])?.first?["lignes"] as? [[String: String]]) ?? []
        try expect(rows.contains { $0["IP"] == "10.182.122.140" && $0["État"] == "Conflit IP" }, "ligne d'inventaire par en-têtes")
        try expectEqual(problems.first?["gravite"] as? String, "Critique", "problèmes triés")
    }

    suite.add("Rapport\u{00A0}: export HTML autonome et échappé") {
        var input = sampleInput()
        input.devices[1].hostname = "<script>alert('x')</script>"
        var config = sampleConfig()
        config.client = "A&B \"Inc\""
        let document = ReportBuilder.build(config: config, input: input)
        let html = ReportExport.html(document, logoDataURL: "javascript:alert(1)")
        try expect(html.hasPrefix("<!doctype html>"), "page complète")
        try expect(!html.contains("<script>"), "aucune balise script injectée")
        try expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"), "nom d'hôte échappé")
        try expect(html.contains("Client\u{00A0}: A&amp;B &quot;Inc&quot;"), "client échappé")
        try expect(!html.contains("javascript:"), "logo refusé s'il n'est pas une image data:")
        try expect(!html.contains("<link") && !html.contains("src=\"http"), "aucune ressource externe")
        try expect(html.contains("Signature du client"), "bloc de signature")
        try expectEqual(ReportExport.escapeHTML("<a href=\"x\">'&'</a>"), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;", "échappement")
        let withLogo = ReportExport.html(document, logoDataURL: "data:image/png;base64,AAAA")
        try expect(withLogo.contains("<img src=\"data:image/png;base64,AAAA\""), "logo intégré")
    }

    suite.add("Rapport\u{00A0}: rapports récents et modèles enregistrés (index JSON)") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-rapports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var library = ReportLibrary()
        library.add(ReportRecent(title: "Audit réseau — Siège", fileName: "a.pdf", format: .pdf, date: "2026-11-03", pages: 3, technician: "Dany"))
        library.add(ReportRecent(title: "Inventaire", fileName: "b.csv", format: .csv, date: "2026-11-03", rows: 188, technician: ""))
        library.add(ReportRecent(title: "Audit réseau — Siège", fileName: "a.pdf", format: .pdf, date: "2026-11-04", pages: 4, technician: "Dany"))
        try expectEqual(library.recents.map(\.fileName), ["a.pdf", "b.csv"], "sans doublon, le plus récent d'abord")
        try expectEqual(library.recents[0].meta, "2026-11-04 · 4 pages · Dany", "méta PDF")
        try expectEqual(library.recents[1].meta, "2026-11-03 · 188 lignes", "méta CSV")
        library.save(ReportSavedTemplate(name: "Audit client", config: sampleConfig()))
        library.save(ReportSavedTemplate(name: "audit CLIENT", config: sampleConfig(.securite)))
        try expectEqual(library.templates.count, 1, "même nom\u{00A0}: remplacé")
        try library.save(to: directory)
        let loaded = ReportLibrary.load(from: directory)
        try expectEqual(loaded.recents.map(\.id), library.recents.map(\.id), "rapports relus")
        try expectEqual(loaded.recents.map(\.meta), library.recents.map(\.meta), "méta relues")
        try expectEqual(loaded.templates.map(\.config), library.templates.map(\.config), "modèles relus")
        try expectEqual(loaded.existingRecents(in: directory).count, 0, "fichiers absents\u{00A0}: masqués")
        try Data("x".utf8).write(to: directory.appendingPathComponent("a.pdf"))
        try expectEqual(loaded.existingRecents(in: directory).map(\.fileName), ["a.pdf"], "fichier présent")
        try expectEqual(ReportLibrary.availableName("a.pdf", in: directory), "a-2.pdf", "nom libre")
        try expectEqual(ReportLibrary.availableName("c.pdf", in: directory), "c.pdf", "nom déjà libre")
    }
}
