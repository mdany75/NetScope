import Foundation
import NetScopeCore

// Note 26 : recherche multiple (analyseur, règles de correspondance, branchement des modules).
// Données fixes seulement, aucun trafic réseau.

func registerSearchTests(_ suite: TestSuite) {
    let printer = Device(ip: IPv4Address("10.182.122.111")!, mac: MACAddress("94:DD:F8:18:15:7D"),
                         hostname: "Brother DCP-L2640DW", openPorts: [80, 443, 9100, 631],
                         switchName: "SW-ETG2-01", switchPort: "1/14", vlan: 30, rangeLabel: "Bureau",
                         deviceType: .imprimante)
    let camera = Device(ip: IPv4Address("10.182.40.21")!, mac: MACAddress("44:19:B6:0A:11:22"),
                        hostname: "CAM-HALL-01", isOnline: false, openPorts: [80, 554],
                        switchName: "SW-ETG2-02", switchPort: "port4", vlan: 40, rangeLabel: "Caméras",
                        deviceType: .camera)
    let poste = Device(ip: IPv4Address("10.20.3.7")!, mac: MACAddress("3C:22:FB:00:00:01"),
                       hostname: "WKS346.bureau.local", customName: "Poste de l’accueil", openPorts: [445, 3389],
                       switchName: "SW-ETG1-01", switchPort: "Gi1/0/4", vlan: 4, rangeLabel: "Siège",
                       deviceType: .poste)
    let devices = [printer, camera, poste]
    func found(_ text: String, in items: [Device] = devices) -> [String] {
        items.filtered(by: text).map(\.ip.description)
    }

    suite.add("Recherche : analyse de la requête (préfixes, exclusions, phrases, alias)") {
        let q = SearchQuery("sw:SW-ETG2 Type:Imprimante -vlan:4 \"salle 204\" fabricant:«Brother Industries» -bureau inconnu:x 94:dd",
                            schema: .scanner)
        try expectEqual(q.terms.count, 8, "huit critères")
        try expectEqual(q.terms[0].field?.key, "switch", "alias sw → switch")
        try expectEqual(q.terms[0].value, "SW-ETG2", "valeur gardée telle quelle")
        try expectEqual(q.terms[1].field?.key, "type", "préfixe insensible à la casse")
        try expect(q.terms[2].isNegated && q.terms[2].field?.key == "vlan", "-vlan:4 exclut")
        try expect(q.terms[3].isPhrase && q.terms[3].field == nil && q.terms[3].value == "salle 204", "phrase exacte")
        try expect(q.terms[4].isPhrase && q.terms[4].field?.key == "fab" && q.terms[4].value == "Brother Industries",
                   "valeur entre « » après un préfixe")
        try expect(q.terms[5].isNegated && q.terms[5].field == nil && q.terms[5].value == "bureau", "-mot")
        try expect(q.terms[6].field == nil && q.terms[6].value == "inconnu:x", "préfixe inconnu : du texte")
        try expect(q.terms[7].field == nil && q.terms[7].value == "94:dd", "fragment de MAC : du texte")
        let mac = SearchQuery("94:dd:f8 12:30", schema: .scanner)
        try expect(mac.terms.allSatisfy { $0.field == nil }, "MAC et heure restent du texte")
        try expectEqual(SearchQuery("état:\"hors ligne\"", schema: .scanner).terms.first?.field?.key, "etat", "préfixe accentué")
        try expectEqual(SearchQuery("vendor:hp name:x host:y", schema: .scanner).terms.compactMap(\.field?.key),
                        ["fab", "nom", "nom"], "alias anglais")
        try expectEqual(SearchQuery("“salle 204”", schema: .scanner).terms.first?.value, "salle 204", "guillemets typographiques")
        try expect(SearchQuery("   ", schema: .scanner).isEmpty, "vide")
        try expect(SearchQuery("switch:", schema: .scanner).isEmpty, "préfixe sans valeur : ne filtre pas encore")
        try expectEqual(SearchQuery("-", schema: .scanner).terms.first?.value, "-", "tiret seul : du texte")
        try expectEqual(SearchQuery("type:camera", schema: .textOnly).terms.first?.field?.key, nil,
                        "module sans champ : tout est du texte")
        try expectEqual(q.terms[0].label, "Switch\u{00A0}: SW-ETG2", "étiquette")
        try expectEqual(q.terms[3].label, "«\u{00A0}salle 204\u{00A0}»", "étiquette d'une phrase")
    }

    suite.add("Recherche : édition (retirer une étiquette, choisir un préfixe)") {
        let q = SearchQuery("switch:SW-ETG2  type:imprimante -\"salle 204\"", schema: .scanner)
        try expectEqual(q.removing(q.terms[1]), "switch:SW-ETG2 -\"salle 204\"", "retire le critère, garde les guillemets")
        try expectEqual(q.removing(q.terms[0]), "type:imprimante -\"salle 204\"", "retire le premier")
        let typing = SearchQuery("type:camera sw", schema: .scanner)
        try expectEqual(typing.pendingWord, "sw", "mot en cours")
        try expectEqual(typing.inserting(.switchName), "type:camera switch:", "le mot commencé devient le préfixe")
        try expectEqual(SearchQuery("brother ", schema: .scanner).inserting(.vlan), "brother vlan:", "ajout après un espace")
        try expectEqual(SearchQuery("", schema: .scanner).inserting(.ip), "ip:", "requête vide")
        try expectEqual(SearchSchema.scanner.example, "switch:SW-ETG2 type:imprimante", "exemple du Scanner")
    }

    suite.add("Recherche : ET, exclusion, phrase, accents") {
        try expectEqual(found("switch:SW-ETG2 type:imprimante"), ["10.182.122.111"], "switch + type")
        try expectEqual(found("sw:etg2"), ["10.182.122.111", "10.182.40.21"], "contient, sans casse")
        try expectEqual(found("-type:imprimante"), ["10.182.40.21", "10.20.3.7"], "exclusion d'un champ")
        try expectEqual(found("etg2 -cam"), ["10.182.122.111"], "exclusion d'un mot")
        try expectEqual(found("type:camera"), ["10.182.40.21"], "type sans accent")
        try expectEqual(found("type:caméra"), ["10.182.40.21"], "type avec accent")
        try expectEqual(found("type:printer"), ["10.182.122.111"], "type en anglais")
        try expectEqual(found("\"poste de l'accueil\""), ["10.20.3.7"], "phrase exacte (apostrophe droite ou courbe)")
        try expectEqual(found("\"accueil poste\""), [], "phrase dans l'ordre seulement")
        try expectEqual(found("plage:cameras"), ["10.182.40.21"], "plage sans accent")
        try expectEqual(found("etat:\"hors ligne\""), ["10.182.40.21"], "état")
        try expectEqual(found("-etat:\"hors ligne\" fab:brother"), ["10.182.122.111"], "état exclu et fabricant")
        try expectEqual(found("switch:SW-ETG2 switch:SW-ETG1"), [], "deux critères du même champ : les deux à la fois")
        try expectEqual(found("bidon:xyz"), [], "préfixe inconnu cherché comme texte")
        try expectEqual(found("site:Montréal"), [], "champ vide : aucun")
        try expectEqual(found("-site:Montréal").count, 3, "champ vide exclu : tous")
    }

    suite.add("Recherche : IP par préfixe ou CIDR, MAC sans séparateurs") {
        try expectEqual(found("ip:10.182."), ["10.182.122.111", "10.182.40.21"], "préfixe terminé par un point")
        try expectEqual(found("ip:10.20"), ["10.20.3.7"], "préfixe aligné sur l'octet (10.20 ≠ 10.200)")
        let far = Device(ip: IPv4Address("10.200.1.1")!)
        try expectEqual(found("ip:10.20", in: devices + [far]), ["10.20.3.7"], "10.200.1.1 exclu")
        try expectEqual(found("ip:10.20.0.0/16", in: devices + [far]), ["10.20.3.7"], "CIDR")
        try expectEqual(found("ip:10.0.0.0/8").count, 3, "CIDR large")
        try expectEqual(found("ip:10.182.122.11"), [], "adresse complète : égalité (pas 10.182.122.111)")
        try expectEqual(found("ip:10.182.122.111"), ["10.182.122.111"], "adresse exacte")
        try expectEqual(found("-ip:10.182.0.0/16"), ["10.20.3.7"], "CIDR exclu")
        try expectEqual(found("mac:94ddf8"), ["10.182.122.111"], "MAC sans séparateur")
        try expectEqual(found("mac:94DD.F818"), ["10.182.122.111"], "MAC au format Cisco")
        try expectEqual(found("mac:94-dd-f8-18"), ["10.182.122.111"], "MAC avec tirets")
        try expectEqual(found("mac:b6:0a"), ["10.182.40.21"], "fragment de MAC")
    }

    suite.add("Recherche : VLAN et port numériques (égalité), ports ouverts") {
        try expectEqual(found("vlan:4"), ["10.20.3.7"], "vlan:4 ne trouve pas 40")
        try expectEqual(found("vlan:40"), ["10.182.40.21"], "vlan:40")
        try expectEqual(found("port:4"), ["10.182.40.21", "10.20.3.7"], "port4 et Gi1/0/4, pas 1/14")
        try expectEqual(found("port:14"), ["10.182.122.111"], "1/14")
        try expectEqual(found("port:1/14"), ["10.182.122.111"], "nom de port non numérique : contient")
        try expectEqual(found("port:gi1"), ["10.20.3.7"], "contient")
        try expectEqual(found("tcp:9100"), ["10.182.122.111"], "port ouvert")
        try expectEqual(found("tcp:80"), ["10.182.122.111", "10.182.40.21"], "port ouvert 80 (pas 8080)")
        try expectEqual(found("ouvert:443 -tcp:9100"), [], "alias de port ouvert, exclusion")
        try expectEqual(found("vlan:3"), [], "vlan:3 ne trouve pas 30")
    }

    suite.add("Recherche : un mot seul donne le même résultat qu'avant (Scanner)") {
        // Ancienne recherche du Scanner (0.10.0), recopiée telle quelle.
        func legacy(_ device: Device, _ query: String) -> Bool {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            var fields = [device.ip.description, device.displayName, device.vendorLabel, device.deviceType.label]
            if let mac = device.mac { fields += [mac.formatted(.colon), mac.formatted(.hyphen), mac.formatted(.cisco)] }
            fields += [device.hostname, device.customName, device.switchName, device.switchPort, device.rangeLabel].compactMap { $0 }
            if let vlan = device.vlan { fields.append("vlan \(vlan)") }
            fields += device.openPorts.map(String.init)
            return fields.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let words = ["", "brother", "94dd.f818", "94-dd", "9100", "1/14", "vlan", "10.182", "camera", "Caméras", "accueil",
                     "ETG2", "port4", "gi1", "hikvision", "445", "imprimante", "BUREAU", "l’accueil", ".local", "poste",
                     "44:19", "inconnu", "40"]
        for word in words {
            for device in devices {
                try expectEqual(device.matches(word), legacy(device, word), "« \(word) » sur \(device.ip)")
            }
        }
    }

    suite.add("Recherche : modules (Inventaire, Accès distant, sondes, journal, serveurs)") {
        var record = InvRecord(key: "94:dd:f8:18:15:7d", mac: MACAddress("94:DD:F8:18:15:7D"),
                               ip: IPv4Address("10.182.122.111")!, hostname: "Brother", vendor: nil,
                               detectedType: .imprimante, isOnline: false, latencyMs: nil, openPorts: [9100],
                               switchName: "SW-ETG2-01", switchPort: "1/14", vlan: 30, rangeLabel: "Bureau",
                               firstSeen: Date(), lastSeen: Date())
        record.annotations.tags = ["Critique"]
        record.annotations.location = "Salle 204"
        record.annotations.wallJack = "P2-14"
        try expect(record.matches("tag:critique local:204 prise:p2-14"), "inventaire : étiquette, local, prise")
        try expect(record.matches("type:imprimante etat:\"hors ligne\" vlan:30"), "inventaire : type, état, VLAN")
        try expect(!record.matches("vlan:3"), "inventaire : vlan:3")
        try expect(record.matches("prise"), "inventaire : mot seul comme avant")

        let ssh = RemoteConnection(name: "Cisco core 9300", proto: .ssh, host: "10.182.122.2", port: 22,
                                   username: "admin", folder: "Réseau", note: "Salle serveurs")
        try expect(ssh.matches("proto:ssh dossier:reseau"), "accès : protocole et dossier sans accent")
        try expect(ssh.matches("ip:10.182.122. port:22"), "accès : hôte et port")
        try expect(!ssh.matches("port:2"), "accès : port:2 ne trouve pas 22")
        try expect(!ssh.matches("-proto:ssh"), "accès : exclusion")
        try expect(ssh.matches("cisco 9300"), "accès : deux mots")

        let alert = MonAlert(date: Date(), probeID: nil, probeName: "Passerelle", severity: .critical, message: "Hors ligne depuis 3 min")
        try expect(alert.matchesSearch("gravite:critique -etat:résolue"), "journal : gravité, non résolue")
        try expect(!alert.matchesSearch("gravite:info"), "journal : autre gravité")
        try expect(alert.matchesSearch("passerelle"), "journal : mot seul")

        let event = InvEvent(date: Date(), kind: .changementPort, severity: .alerte, key: "k", ip: IPv4Address("10.182.122.111")!,
                             title: "Port de switch changé", detail: "SW-ETG2-01 · 1/14 → 1/16")
        let item = InvEventSearchItem(event, deviceName: "Brother", mac: MACAddress("94:DD:F8:18:15:7D"))
        try expect(item.matchesSearch("gravite:alerte etat:\"à traiter\" mac:94ddf8"), "analyse : gravité, statut, MAC")
        try expect(item.matchesSearch("type:\"port de switch\" nom:brother"), "analyse : type de changement, appareil")
        try expect(!item.matchesSearch("gravite:critique"), "analyse : autre gravité")
    }

    suite.add("Recherche : document à la volée et schéma") {
        let schema = SearchSchema([.port, .vlan, .poe, .status])
        let doc = SearchDocument(["port": ["port14"], "vlan": ["30"], "poe": ["Actif 7,2 W"], "etat": ["Activé / Up"]])
        try expect(SearchQuery("port:14 vlan:30 poe:actif", schema: schema).matches(doc), "document : trois champs")
        try expect(!SearchQuery("port:1", schema: schema).matches(doc), "document : port:1")
        try expect(SearchQuery("7,2", schema: schema).matches(doc), "document : texte libre")
        try expectEqual(schema.field(forPrefix: "Statut")?.key, "etat", "alias")
        try expectEqual(schema.field(forPrefix: "ssid")?.key, nil, "champ absent du module")
        for module in [SearchSchema.scanner, .inventaire, .analyse, .sondes, .journal, .surveillance, .acces, .serveurs, .wifi,
                       .switchs, .outils, .outilsListe, .outilsHistorique, .reglages, .wifiBornes, .wifiClients, .wifiSSID,
                       .wifiVoisins, .wifiEcran] {
            var seen: [String: String] = [:]
            for field in module.fields {
                for alias in field.aliases {
                    try expect(seen[alias] == nil, "alias « \(alias) » en double dans \(module.example)")
                    seen[alias] = field.key
                }
            }
            try expect(!SearchQuery(module.example, schema: module).fieldTerms.isEmpty, "exemple lu : \(module.example)")
        }
    }

    suite.add("Recherche : Boîte à outils, critère de l'historique sans effet sur la liste des outils") {
        let query = SearchQuery("etat:échec cible:exemple.ca", schema: .outils)
        try expectEqual(query.fieldTerms.compactMap(\.field?.key), ["etat", "cible"], "champs de l'historique reconnus")
        let tools = query.restricted(to: .outilsListe)
        try expect(tools.isEmpty, "liste des outils : critères laissés de côté")
        try expect(tools.matches(SearchDocument(["nom": ["DNS"], "groupe": ["Diagnostic"]])), "outil gardé")
        let history = query.restricted(to: .outilsHistorique)
        try expect(!history.matches(SearchDocument(["nom": ["DNS"], "cible": ["exemple.ca"], "etat": ["Réussi"]])), "historique filtré")
        try expect(history.matches(SearchDocument(["nom": ["DNS"], "cible": ["exemple.ca"], "etat": ["Échec"]])), "historique : échec gardé")
        // Wi-Fi : « borne: » ne concerne pas les réseaux voisins du Mac.
        let wifi = SearchQuery("borne:AP-ACCUEIL", schema: .wifiEcran)
        try expect(wifi.restricted(to: .wifi).isEmpty, "réseaux voisins : critère des bornes laissé de côté")
        try expect(!wifi.restricted(to: .wifiBornes).isEmpty, "bornes : critère appliqué")
    }

    suite.add("Recherche : écran à deux listes (Surveillance : sondes et journal)") {
        let query = SearchQuery("type:ping gravite:critique passerelle", schema: .surveillance)
        try expectEqual(query.fieldTerms.compactMap(\.field?.key), ["type", "gravite"], "champs des deux listes reconnus")
        let probes = query.restricted(to: .sondes)
        try expectEqual(probes.terms.map(\.value), ["ping", "passerelle"], "sondes : gravité laissée de côté")
        let journal = query.restricted(to: .journal)
        try expectEqual(journal.terms.map(\.value), ["critique", "passerelle"], "journal : type laissé de côté")
        let alert = MonAlert(date: Date(), probeID: nil, probeName: "Passerelle", severity: .critical, message: "Hors ligne")
        try expect(journal.matches(alert), "journal : l'alerte critique de la passerelle")
        try expect(!query.restricted(to: .journal).matches(MonAlert(date: Date(), probeID: nil, probeName: "Passerelle",
                                                                      severity: .info, message: "Rétablie")), "journal : info exclue")
    }
}
