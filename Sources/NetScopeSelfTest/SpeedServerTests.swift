import Foundation
import NetScopeCore

// Tests du choix du serveur Speedtest (note 16) et du bouton « Installer » (note 17) : lecture de
// réponses fixes (M-Lab, LibreSpeed, Ookla), choix automatique, favoris, historique par serveur,
// scripts d'installation. Aucun accès réseau, aucun processus lancé.

func registerSpeedServerTests(_ suite: TestSuite) {
    suite.add("Serveurs : liste LibreSpeed") {
        let json = """
        [
          {"id":3,"name":"Montréal, Canada (Fibre Laurentides)","server":"//mtl.exemple.net/backend","dlURL":"garbage.php",
           "ulURL":"empty.php","pingURL":"empty.php","getIpURL":"getIP.php","sponsorName":"Fibre Laurentides"},
          {"id":"7","name":"Québec, Canada","server":"http://qc.exemple.net:8080/","dlURL":"backend/garbage.php",
           "ulURL":"backend/empty.php","pingURL":"backend/empty.php","getIpURL":"backend/getIP.php"},
          {"id":9,"name":"Sans adresse"},
          {"id":10,"name":"Protocole refusé","server":"ftp://x.exemple.net/"}
        ]
        """
        let servers = try LibreSpeedParser.servers(Data(json.utf8))
        try expectEqual(servers.count, 2, "entrées invalides ignorées")
        let mtl = servers[0]
        try expectEqual(mtl.id, "librespeed:3", "identifiant")
        try expectEqual(mtl.baseURL, "https://mtl.exemple.net/backend/", "« // » devient https, « / » final ajouté")
        try expectEqual(mtl.city, "Montréal", "ville")
        try expectEqual(mtl.country, "Canada", "pays")
        try expectEqual(mtl.sponsor, "Fibre Laurentides", "opérateur")
        try expectEqual(mtl.host, "mtl.exemple.net", "hôte")
        try expectEqual(mtl.port, 443, "port https")
        try expectEqual(mtl.historyLabel, "LibreSpeed · Montréal · Fibre Laurentides", "libellé d'historique")
        let qc = servers[1]
        try expectEqual(qc.port, 8080, "port explicite")
        try expectEqual(qc.sponsor, nil, "pas d'opérateur")
        try expectEqual(qc.downloadPath, "backend/garbage.php", "chemin de téléchargement")
        try expectThrows(SpeedParseError.invalidFormat("liste LibreSpeed"), "liste illisible") {
            _ = try LibreSpeedParser.servers(Data("{\"a\":1}".utf8))
        }
        let split = LibreSpeedParser.splitName("Amsterdam, Netherlands (Clouvider)")
        try expectEqual(split.city, "Amsterdam", "nom : ville")
        try expectEqual(split.sponsor, "Clouvider", "nom : hébergeur")
    }

    suite.add("Serveurs : points d'accès et IP LibreSpeed") {
        let endpoints = LibreSpeedEndpoints(base: URL(string: "https://mtl.exemple.net/backend")!)
        try expectEqual(endpoints.downloadURL(bytes: 25_000_000, nonce: "1").absoluteString,
                        "https://mtl.exemple.net/backend/garbage.php?r=1&ckSize=24", "garbage.php, blocs de 1 Mio arrondis")
        try expectEqual(endpoints.downloadURL(bytes: 10, nonce: "1").absoluteString,
                        "https://mtl.exemple.net/backend/garbage.php?r=1&ckSize=1", "au moins un bloc")
        try expectEqual(endpoints.uploadURL(nonce: "2").absoluteString, "https://mtl.exemple.net/backend/empty.php?r=2", "téléversement")
        try expectEqual(endpoints.ipURL.absoluteString, "https://mtl.exemple.net/backend/getIP.php?isp=true", "IP et fournisseur")
        let config = SpeedTestConfig(streams: 4, libreSpeed: endpoints)
        try expect(config.downloadURL(bytes: 0).path.hasSuffix("/empty.php"), "latence : empty.php")
        try expect(config.metaURL.absoluteString.hasSuffix("getIP.php?isp=true"), "méta : getIP.php")

        let info = try unwrapValue(LibreSpeedParser.clientInfo(Data("""
        {"processedString":"203.0.113.24 - Bell Canada, CA (12 km)","rawIspInfo":{"ip":"203.0.113.24","org":"AS577 Bell Canada","country":"CA"}}
        """.utf8)), "getIP JSON")
        try expectEqual(info.clientIP, "203.0.113.24", "IP publique")
        try expectEqual(info.asOrganization, "Bell Canada", "fournisseur sans pays ni distance")
        try expectEqual(info.asn, 577, "numéro d'AS")
        try expectEqual(LibreSpeedParser.clientInfo(Data("203.0.113.9\n".utf8))?.clientIP, "203.0.113.9", "getIP texte")
        try expectEqual(LibreSpeedParser.clientInfo(Data("<html>erreur</html>".utf8)), nil, "réponse HTML refusée")
        let (asn, name) = LibreSpeedParser.splitASN("AS812 Rogers Communications Canada Inc.")
        try expectEqual(asn, 812, "AS")
        try expectEqual(name, "Rogers Communications Canada Inc.", "organisation")
    }

    suite.add("Serveurs : localisation M-Lab et mesures NDT7") {
        let json = """
        {"results":[
          {"machine":"mlab1-yul04.mlab-oti.measurement-lab.org","location":{"city":"Montreal","country":"CA"},
           "urls":{"ws:///ndt/v7/download":"ws://ndt-mlab1-yul04.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=a",
                   "wss:///ndt/v7/download":"wss://ndt-mlab1-yul04.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=b",
                   "wss:///ndt/v7/upload":"wss://ndt-mlab1-yul04.mlab-oti.measurement-lab.org/ndt/v7/upload?access_token=c"}},
          {"machine":"mlab2-yyz04.mlab-oti.measurement-lab.org","location":{"city":"Toronto","country":"CA"},
           "urls":{"ws:///ndt/v7/download":"ws://exemple/ndt/v7/download"}}
        ]}
        """
        let targets = try MLabLocate.parse(Data(json.utf8))
        try expectEqual(targets.count, 1, "serveur sans wss:// écarté")
        let target = targets[0]
        try expectEqual(target.site, "yul04", "site")
        try expectEqual(target.city, "Montreal", "ville")
        try expectEqual(target.downloadURL.query, "access_token=b", "URL signée wss")
        try expectEqual(target.server.id, "mlab:yul04", "identifiant stable (sans jeton)")
        try expectEqual(target.server.historyLabel, "M-Lab · Montreal (yul04)", "libellé")
        try expectEqual(target.server.host, "ndt-mlab1-yul04.mlab-oti.measurement-lab.org", "hôte pour la latence")
        try expectEqual(MLabLocate.site(fromMachine: "ndt-mlab3-lga1t.mlab-oti.measurement-lab.org"), nil, "site non standard")
        try expectEqual(MLabLocate.url(site: "yul04").absoluteString,
                        "https://locate.measurementlab.net/v2/nearest/ndt/ndt7?site=yul04", "favori : site imposé")
        try expectEqual(MLabLocate.url(site: "yul04&x=1"), MLabLocate.nearestURL, "site invalide ignoré")
        try expectThrows(SpeedParseError.invalidFormat("M-Lab\u{a0}: No capacity"), "erreur du service") {
            _ = try MLabLocate.parse(Data("{\"error\":{\"title\":\"No capacity\"}}".utf8))
        }
        try expectThrows(SpeedParseError.empty("M-Lab"), "liste vide") {
            _ = try MLabLocate.parse(Data("{\"results\":[]}".utf8))
        }

        let measurement = try unwrapValue(NDT7Measurement.parse("""
        {"AppInfo":{"ElapsedTime":2000000,"NumBytes":125000000},"ConnectionInfo":{"Client":"203.0.113.24:52144","Server":"x"},
         "Origin":"server","Test":"upload","TCPInfo":{"MinRTT":5800,"RTT":7200,"RTTVar":900,"BytesReceived":124000000,"ElapsedTime":2000100}}
        """), "mesure NDT7")
        try expectEqual(measurement.appMegabitsPerSecond, 500, "125 Mo en 2 s = 500 Mb/s")
        try expectEqual(measurement.minRTTMs, 5.8, "MinRTT en ms")
        try expectEqual(measurement.rttMs, 7.2, "RTT en ms")
        try expectEqual(measurement.clientIP, "203.0.113.24", "IP du client")
        try expectEqual(measurement.test, "upload", "test")
        try expectEqual(NDT7Measurement.parse("{\"ConnectionInfo\":{\"Client\":\"[2001:db8::5]:443\"}}")?.clientIP,
                        "2001:db8::5", "IPv6 entre crochets")
        try expectEqual(NDT7Measurement.parse("{\"Autre\":1}"), nil, "message inconnu")
        try expectEqual(NDT7Upload.nextMessageSize(current: 8192, totalSent: 100_000), 8192, "taille gardée sous 16 ×")
        try expectEqual(NDT7Upload.nextMessageSize(current: 8192, totalSent: 131_072), 16_384, "taille doublée à 16 ×")
        try expectEqual(NDT7Upload.nextMessageSize(current: 1 << 20, totalSent: 1 << 30), 1 << 20, "plafond de 1 Mio")
    }

    suite.add("Serveurs : sortie JSON du CLI d'Ookla") {
        let result = """
        {"type":"result","timestamp":"2026-11-03T14:05:00Z","ping":{"jitter":0.62,"latency":5.1,"low":4.8,"high":6.0},
         "download":{"bandwidth":115125000,"bytes":1100000000,"elapsed":9800,"latency":{"iqm":16.2}},
         "upload":{"bandwidth":61500000,"bytes":560000000,"elapsed":9000,"latency":{"iqm":14.0}},
         "packetLoss":0.3,"isp":"Bell Canada","interface":{"internalIp":"10.182.122.135","externalIp":"203.0.113.24"},
         "server":{"id":30514,"host":"speedtest.mtl.exemple.net","port":8080,"name":"Bell Canada","location":"Montréal, QC","country":"Canada"},
         "result":{"id":"abc","url":"https://www.speedtest.net/result/c/abc"}}
        """
        let summary = try OoklaParser.result(Data(result.utf8))
        try expectEqual(summary.downMbps, 921, "bande passante en octets/s → Mb/s")
        try expectEqual(summary.upMbps, 492, "montée")
        try expectEqual(summary.idleLatencyMs, 5.1, "latence")
        try expectEqual(summary.jitterMs, 0.62, "gigue")
        try expectEqual(summary.loadedLatencyMs, 16.2, "latence en charge : la plus haute des IQM")
        try expectEqual(summary.lossPercent, 0.3, "perte de paquets")
        try expectEqual(summary.server?.serverID, "ookla:30514", "identifiant du serveur")
        try expectEqual(summary.server?.label, "Ookla · Bell Canada · Montréal, QC", "libellé")
        try expectEqual(summary.server?.clientIP, "203.0.113.24", "IP publique")
        try expectEqual(summary.server?.resultURL, "https://www.speedtest.net/result/c/abc", "lien du résultat")
        try expectEqual(OoklaParser.event(result), .result(summary), "ligne JSONL « result »")

        try expectEqual(OoklaParser.event("{\"type\":\"download\",\"download\":{\"bandwidth\":12500000,\"progress\":0.5}}"),
                        .download(mbps: 100, progress: 0.5), "progression du téléchargement")
        try expectEqual(OoklaParser.event("{\"type\":\"ping\",\"ping\":{\"jitter\":0.4,\"latency\":6.2,\"progress\":1}}"),
                        .ping(latencyMs: 6.2, jitterMs: 0.4, progress: 1), "latence")
        try expectEqual(OoklaParser.event("{\"type\":\"log\",\"level\":\"error\",\"message\":\"Configuration - Couldn't resolve host\"}"),
                        .error("Configuration - Couldn't resolve host"), "erreur")
        try expectEqual(OoklaParser.event("{\"type\":\"log\",\"level\":\"info\",\"message\":\"x\"}"), nil, "journal ignoré")
        try expectEqual(OoklaParser.event("pas du json"), nil, "ligne illisible")

        let list = """
        {"type":"serverList","servers":[{"id":30514,"host":"speedtest.mtl.exemple.net","port":8080,"name":"Bell Canada","location":"Montréal, QC","country":"Canada"},
         {"name":"sans identifiant"}]}
        """
        let servers = try OoklaParser.servers(Data(list.utf8))
        try expectEqual(servers.map(\.id), ["ookla:30514"], "liste Ookla")
        try expectEqual(servers[0].ooklaID, 30514, "identifiant numérique")
        try expectEqual(servers[0].historyLabel, "Ookla · Bell Canada · Montréal, QC", "libellé")
        try expect(OoklaLocator.isOokla(versionOutput: "Speedtest by Ookla 1.2.0.84 (ea6b6773cf) Darwin 25.0.0"), "CLI d'Ookla reconnu")
        try expect(!OoklaLocator.isOokla(versionOutput: "speedtest-cli 2.1.3\nPython 3.12.4"), "speedtest-cli (Python) écarté")
        try expectEqual(OoklaLocator.testArguments(serverID: 30514),
                        ["--format=jsonl", "--progress=yes", "--accept-license", "--accept-gdpr", "--server-id=30514"], "arguments")
        try expectEqual(OoklaLocator.testArguments(serverID: nil).contains { $0.hasPrefix("--server-id") }, false, "serveur choisi par Ookla")
    }

    suite.add("Serveurs : choix automatique, tri, recherche") {
        var cloudflare = SpeedServer.cloudflare
        cloudflare.latencyMs = 9
        let mlab = SpeedServer(id: "mlab:yul04", source: .mlab, name: "Montréal", city: "Montréal", site: "yul04", latencyMs: 7.5)
        let libre = SpeedServer(id: "librespeed:3", source: .librespeed, name: "Québec, Canada (Réseau Capitale)", city: "Québec",
                                sponsor: "Réseau Capitale", latencyMs: 12)
        let ookla = SpeedServer(id: "ookla:1", source: .ookla, name: "Bell", latencyMs: 3)
        let custom = try SpeedServer.custom(address: "vitesse.exemple.ca")
        let silent = SpeedServer(id: "librespeed:9", source: .librespeed, name: "Ottawa")
        let all = [cloudflare, mlab, libre, ookla, custom, silent]
        try expectEqual(SpeedServerPicker.automatic(all).id, "mlab:yul04", "plus faible latence, Ookla exclu")
        try expectEqual(SpeedServerPicker.automatic([silent]).id, "cloudflare", "sans mesure : Cloudflare")
        try expectEqual(SpeedServerPicker.sorted(all, favorites: ["librespeed:3"]).map(\.id),
                        ["librespeed:3", "ookla:1", "mlab:yul04", "cloudflare", "librespeed:9", "custom:https://vitesse.exemple.ca/"],
                        "favoris, puis latence, puis sans mesure")
        try expect(SpeedServerPicker.matches(libre, query: "quebec capitale"), "recherche sans accents")
        try expect(!SpeedServerPicker.matches(libre, query: "toronto"), "recherche sans résultat")
    }

    suite.add("Serveurs : serveur personnalisé") {
        let server = try SpeedServer.custom(address: " https://vitesse.exemple.ca/backend ", label: "Fournisseur")
        try expectEqual(server.id, "custom:https://vitesse.exemple.ca/backend/", "identifiant")
        try expectEqual(server.name, "Fournisseur", "nom")
        try expectEqual(server.port, 443, "port")
        try expectEqual(LibreSpeedEndpoints(server: server)?.pingURL(nonce: "1").absoluteString,
                        "https://vitesse.exemple.ca/backend/empty.php?r=1", "points d'accès LibreSpeed")
        try expectEqual(try SpeedServer.custom(address: "10.10.0.30:8080").baseURL, "https://10.10.0.30:8080/", "https par défaut")
        try expectThrows(SpeedServerError.emptyAddress, "adresse vide") { _ = try SpeedServer.custom(address: "  ") }
        try expectThrows(SpeedServerError.unsupportedScheme("ftp"), "ftp refusé") { _ = try SpeedServer.custom(address: "ftp://x.exemple") }
        try expectThrows(SpeedServerError.invalidAddress("https://a b.exemple"), "espace refusé") {
            _ = try SpeedServer.custom(address: "https://a b.exemple")
        }
        try expectThrows(SpeedServerError.invalidAddress("https://moi:secret@x.exemple"), "identifiants refusés") {
            _ = try SpeedServer.custom(address: "https://moi:secret@x.exemple")
        }
    }

    suite.add("Serveurs : favoris et choix enregistrés") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-serveurs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeedServerPrefsStore(url: directory.appendingPathComponent("speedtest-serveurs.json"))
        try expectEqual(store.load(), SpeedServerPrefs(), "préférences par défaut")
        var prefs = SpeedServerPrefs()
        var mlab = SpeedServer(id: "mlab:yul04", source: .mlab, name: "Montréal", site: "yul04")
        mlab.latencyMs = 7
        prefs.toggleFavorite(mlab)
        try expectEqual(prefs.favorites.first?.latencyMs, nil, "latence non enregistrée")
        let custom = try SpeedServer.custom(address: "vitesse.exemple.ca")
        prefs.addCustom(custom)
        prefs.selectedID = custom.id
        prefs.selected = custom
        try expectEqual(prefs.favoriteIDs, ["mlab:yul04", custom.id], "personnalisé mis en favori")
        try store.save(prefs)
        try expectEqual(store.load(), prefs, "relu à l'identique")
        prefs.removeCustom(id: custom.id)
        try expectEqual(prefs.selectedID, SpeedServerPrefs.automaticID, "retrait : retour en automatique")
        try expectEqual(prefs.favoriteIDs, ["mlab:yul04"], "retiré des favoris")
        prefs.toggleFavorite(mlab)
        try expectEqual(prefs.favorites, [], "favori retiré")
    }

    suite.add("Serveurs : historique par serveur") {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func record(_ hours: Double, _ server: String, _ id: String?, _ source: SpeedServerSource?, _ down: Double,
                    _ up: Double? = nil, kind: SpeedTestKind = .internet) -> SpeedTestRecord {
            SpeedTestRecord(date: now.addingTimeInterval(-hours * 3_600), kind: kind, server: server, interfaceName: "en7",
                            interfaceKind: "Ethernet", downMbps: down, upMbps: up, latencyMs: 6,
                            serverSource: source, serverID: id)
        }
        let records = [
            record(1, "Cloudflare · YUL · Montréal", "cloudflare:YUL", .cloudflare, 900, 480),
            record(2, "Cloudflare · YUL · Montréal", "cloudflare:YUL", .cloudflare, 920, 490),
            record(3, "M-Lab · Montréal (yul04)", "mlab:yul04", .mlab, 860, 470),
            record(4, "Cloudflare", nil, nil, 700),
            record(5, "NAS 10.10.0.20:5201", nil, nil, 941, kind: .lan),
        ]
        let stats = SpeedServerStats.compute(records)
        try expectEqual(stats.map(\.id), ["cloudflare:YUL", "mlab:yul04", "internet:Cloudflare"], "regroupement, le plus testé d'abord")
        try expectEqual(stats[0].count, 2, "nombre de tests")
        try expectEqual(stats[0].averageDown, 910, "descente moyenne")
        try expectEqual(stats[0].averageUp, 485, "montée moyenne")
        try expectEqual(stats[0].bestDown, 920, "meilleure descente")
        try expectEqual(stats[2].source, "Cloudflare", "ancien test sans source : Cloudflare")
        try expectEqual(SpeedServerStats.compute(records, kind: nil).count, 4, "tous types")
        try expectEqual(records[4].sourceLabel, "iperf3", "source iperf3")

        // Ancien fichier d'historique (sans source) : toujours lisible.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("speedtest.json")
        try Data("""
        {"version":1,"records":[{"id":"8C1A4B5E-0000-4000-8000-000000000001","date":"2026-11-02T12:00:00Z","kind":"internet",
        "origin":"manuel","server":"Cloudflare · YUL","interfaceName":"en7","interfaceKind":"Ethernet","downMbps":900,"streams":8}]}
        """.utf8).write(to: url)
        let loaded = SpeedHistoryStore(url: url).load(now: Date(timeIntervalSince1970: 1_793_000_000))
        try expectEqual(loaded.records.count, 1, "ancien historique relu")
        try expectEqual(loaded.records.first?.serverSource, nil, "sans source")
        try expect(SpeedHistoryStore.csv(loaded.records).components(separatedBy: "\r\n")[1].hasSuffix(";8;Cloudflare"), "CSV : colonne Source")
    }

    suite.add("Serveurs : description du serveur testé") {
        let base = SpeedServerInfo(city: "Québec", source: "LibreSpeed", serverName: "Québec · Réseau Capitale", serverID: "librespeed:7")
        let merged = base.merged(with: SpeedServerInfo(clientIP: "203.0.113.24", asn: 577, asOrganization: "Bell Canada"))
        try expectEqual(merged.label, "LibreSpeed · Québec · Réseau Capitale", "libellé gardé")
        try expectEqual(merged.clientIP, "203.0.113.24", "IP ajoutée")
        try expectEqual(merged.providerLabel, "AS577 · Bell Canada", "fournisseur ajouté")
        try expectEqual(SpeedServerInfo(colo: "YUL", city: "Montreal").label, "Cloudflare · YUL · Montreal", "Cloudflare inchangé")
    }

    suite.add("Installer : liste blanche, détection, scripts") {
        try expectEqual(InstallableTool.allCases.map(\.formula), ["iperf3", "telnet", "teamookla/speedtest/speedtest"], "formules fixes")
        try expectEqual(InstallableTool.iperf3.displayCommand, "brew install iperf3", "commande affichée")
        try expectEqual(ToolInstaller.installCommand(.telnet, brewPath: "/opt/homebrew/bin/brew"),
                        "/opt/homebrew/bin/brew install telnet", "commande lancée")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-installer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appendingPathComponent("iperf3").path
        let brew = directory.appendingPathComponent("brew").path
        try expectEqual(ToolInstaller.presence(.iperf3, toolPaths: [tool], brewPaths: [brew]), .missingWithoutHomebrew, "rien d'installé")
        FileManager.default.createFile(atPath: brew, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try expectEqual(ToolInstaller.presence(.iperf3, toolPaths: [tool], brewPaths: [brew]), .missingWithHomebrew(brew: brew), "Homebrew présent")
        FileManager.default.createFile(atPath: tool, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
        try expect(!ToolInstaller.presence(.iperf3, toolPaths: [tool], brewPaths: [brew]).isInstalled, "fichier non exécutable ignoré")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        try expectEqual(ToolInstaller.presence(.iperf3, toolPaths: [tool], brewPaths: [brew]), .installed(path: tool), "outil détecté")

        let script = ToolInstaller.installScript(.iperf3, brewPath: "/opt/homebrew/bin/brew")
        let lines = script.components(separatedBy: "\n")
        try expectEqual(lines.first, "#!/bin/zsh", "script zsh")
        try expect(lines.contains("rm -f -- \"$0\""), "le script s'efface")
        guard let readIndex = lines.firstIndex(of: "read -r reponse || exit 1"),
              let runIndex = lines.firstIndex(of: "/opt/homebrew/bin/brew install iperf3") else {
            throw TestFailure(message: "attente d'Entrée ou commande absente", file: #fileID, line: #line)
        }
        try expect(readIndex < runIndex, "rien ne se lance avant Entrée")
        try expect(!script.contains("sudo"), "aucune élévation de droits")
        try expect(ToolInstaller.homebrewScript().contains(Homebrew.officialInstallCommand), "commande officielle de Homebrew")
        try expectEqual(IperfServerHelp.serverCommand, "iperf3 -s", "commande côté cible")
    }
}

private func unwrapValue<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
    return value
}
