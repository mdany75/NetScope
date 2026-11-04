import Foundation
@testable import NetScopeCore

// Tests de la note 13 : sauvegardes (manifeste, rotation, restauration, absence de secrets) dans un
// dossier temporaire, méthodes de découverte des profils de scan et leur effet sur le moteur.
// Aucun accès réseau.

func registerBackupMethodsTests(_ suite: TestSuite) {
    suite.add("ZIP : archive « stored » relue à l'identique, CRC-32") {
        try expectEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926, "CRC-32 de référence")
        let entries = [BackupZip.Entry(path: "manifeste.json", data: Data("{}".utf8)),
                       BackupZip.Entry(path: "fichiers/état.json", data: Data(repeating: 0x41, count: 5000))]
        let zip = BackupZip.archive(entries)
        try expectEqual(try BackupZip.entries(of: zip), entries, "aller-retour")
        var damaged = [UInt8](zip)
        damaged[200] ^= 0xFF
        do {
            _ = try BackupZip.entries(of: Data(damaged))
            throw TestFailure(message: "archive modifiée acceptée", file: #fileID, line: #line)
        } catch is BackupZip.ZipError {}
    }

    suite.add("Sauvegarde : manifeste, fichiers JSON, préférences, aucun secret") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let source = try sandbox.source()
        let info = try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: .manuelle,
                                           date: Date(timeIntervalSince1970: 1_793_000_000))
        try expect(info.url.lastPathComponent.hasPrefix("NetScope-sauvegarde-") && info.url.pathExtension == "zip", "nom de l'archive")
        let manifest = info.manifest
        try expectEqual(manifest.version, BackupManifest.currentVersion, "version du manifeste")
        try expectEqual(manifest.files.map(\.path), ["etat.json", "inventaire.json", "outils/historique.json", "surveillance.json"], "fichiers JSON recensés")
        try expectEqual(manifest.skippedFiles, ["oui.tsv"], "base des fabricants laissée")
        try expectEqual(manifest.preferenceCount, 2, "préférences gardées")
        try expectEqual(manifest.excludedPreferenceKeys, ["NetScope.speedtest.jeton", "reglages.smtp.motDePasse"], "préférences secrètes écartées")
        try expectEqual(manifest.keychain.map(\.account), ["jeton", "identifiants"], "comptes du Trousseau nommés (triés par service)")
        let raw = try Data(contentsOf: info.url)
        try expect(raw.range(of: Data(BackupSandbox.secret.utf8)) == nil, "le secret n'est pas dans l'archive")
        // Le manifeste se relit, la liste le trouve.
        let listed = BackupEngine.list(in: sandbox.backups)
        try expectEqual(listed.count, 1, "une sauvegarde")
        try expectEqual(listed.first?.manifest.summary, "4 fichiers · 2 préférences", "résumé")
        // Forme « dossier daté ».
        let folder = try BackupEngine.create(source, in: sandbox.backups, format: .dossier, kind: .automatique,
                                             date: Date(timeIntervalSince1970: 1_793_000_100))
        try expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("manifeste.json").path), "manifeste du dossier")
        try expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("fichiers/outils/historique.json").path), "sous-dossier copié")
        let contents = try BackupEngine.read(folder.url)
        try expectEqual(contents.files.count, 4, "dossier relu")
        try expectEqual(BackupEngine.list(in: sandbox.backups).first?.format, .dossier, "plus récente en premier")
    }

    suite.add("Sauvegarde : rotation (nombre gardé, sécurité à part)") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let source = try sandbox.source()
        for day in 0..<5 {
            try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: day == 4 ? .manuelle : .automatique,
                                    date: Date(timeIntervalSince1970: 1_793_000_000 + Double(day) * 86_400))
        }
        for hour in 0..<4 {
            try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: .securite,
                                    date: Date(timeIntervalSince1970: 1_793_500_000 + Double(hour) * 3600))
        }
        let removed = try BackupEngine.rotate(in: sandbox.backups, keep: 2, keepSafety: 3)
        try expectEqual(removed.count, 4, "3 ordinaires + 1 de sécurité supprimées")
        let left = BackupEngine.list(in: sandbox.backups)
        try expectEqual(left.filter { $0.manifest.kind != .securite }.count, 2, "deux gardées")
        try expectEqual(left.filter { $0.manifest.kind == .securite }.count, 3, "trois de sécurité")
        try expectEqual(left.first { $0.manifest.kind == .manuelle }?.date, Date(timeIntervalSince1970: 1_793_000_000 + 4 * 86_400), "la plus récente reste")
        try expectEqual(try BackupEngine.rotate(in: sandbox.backups, keep: 0).count, 0, "0 : tout garder")
        try expect(BackupEngine.isAutomaticBackupDue(last: nil), "première sauvegarde due")
        try expect(!BackupEngine.isAutomaticBackupDue(last: Date().addingTimeInterval(-3600)), "pas deux par jour")
        try expect(BackupEngine.isAutomaticBackupDue(last: Date().addingTimeInterval(-90_000)), "due après 24 h")
    }

    suite.add("Sauvegarde : restauration des fichiers et des préférences") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let info = try BackupEngine.create(try sandbox.source(), in: sandbox.backups, format: .zip, kind: .manuelle)
        // État modifié après la sauvegarde.
        try Data(#"{"version":1,"ranges":[]}"#.utf8).write(to: sandbox.data.appendingPathComponent("etat.json"))
        try Data("{}".utf8).write(to: sandbox.data.appendingPathComponent("nouveau.json"))
        let contents = try BackupEngine.read(info.url)
        let result = try BackupEngine.restoreFiles(contents, to: sandbox.data)
        try expectEqual(result.removed, ["nouveau.json"], "fichier absent de la sauvegarde retiré")
        try expectEqual(try String(contentsOf: sandbox.data.appendingPathComponent("etat.json"), encoding: .utf8), BackupSandbox.etat, "état d'origine remis")
        try expect(FileManager.default.fileExists(atPath: sandbox.data.appendingPathComponent("oui.tsv").path), "autres fichiers laissés")
        let current: [String: Any] = ["reglages.scan.threads": 512, "sauvegarde.dossier": "/Volumes/NAS", "reglages.smtp.motDePasse": "x"]
        let merged = BackupEngine.mergedPreferences(backup: contents.preferences, current: current, preserving: ["sauvegarde."])
        try expectEqual(merged["reglages.scan.threads"] as? Int, 64, "préférence de la sauvegarde")
        try expectEqual(merged["sauvegarde.dossier"] as? String, "/Volumes/NAS", "réglages de sauvegarde gardés")
        try expectEqual(merged["reglages.smtp.motDePasse"] as? String, "x", "préférence secrète jamais effacée")
        // Archive altérée ou d'une version future : refusée.
        var newer = contents.manifest
        newer.version = 99
        let future = BackupZip.archive([BackupZip.Entry(path: "manifeste.json", data: try BackupEngine.encoder().encode(newer))])
        let futureURL = sandbox.backups.appendingPathComponent("NetScope-sauvegarde-futur.zip")
        try future.write(to: futureURL)
        try expectThrows(BackupError.newerVersion(99), "version future") { _ = try BackupEngine.read(futureURL) }
        try expect(!BackupEngine.isSafeRelativePath("../etc/passwd") && BackupEngine.isSafeRelativePath("outils/a.json"), "chemins refusés")
    }

    suite.add("Méthodes de découverte : anciens profils sans méthodes, valeurs partielles") {
        let empty = try JSONDecoder().decode(ScanMethods.self, from: Data("{}".utf8))
        try expectEqual(empty, ScanMethods(), "profil sans méthodes : comportement d'avant")
        try expect(empty.icmp && empty.arp && empty.mdns && empty.netbios && empty.snmp && !empty.tcp && !empty.udp && !empty.lldp,
                   "valeurs par défaut = comportement actuel")
        let partial = try JSONDecoder().decode(ScanMethods.self, from: Data(#"{"icmp":false,"tcp":true,"tcpPorts":[443,22,0,22]}"#.utf8))
        try expect(!partial.icmp && partial.tcp && partial.arp, "valeurs partielles")
        try expectEqual(partial.tcpPorts, [22, 443], "ports nettoyés")
        try expectEqual(ScanProfileMethods.decode(nil), ScanProfileMethods(), "aucune préférence")
        try expectEqual(ScanProfileMethods.decode(Data("pas du json".utf8)), ScanProfileMethods(), "préférence illisible")
        let saved = ScanProfileMethods.decode(Data(#"{"byProfile":{"complet":{"udp":true}}}"#.utf8))
        try expect(saved.methods(for: .complet).udp, "méthode enregistrée")
        try expectEqual(saved.methods(for: .rapide), ScanMethods(), "autre profil inchangé")
        var edited = saved
        edited.set(ScanMethods(), for: .complet)
        try expect(edited.byProfile.isEmpty, "retour aux valeurs par défaut : rien d'enregistré")
        try expectEqual(ScanProfileMethods.decode(saved.encoded()), saved, "aller-retour")
    }

    suite.add("Méthodes de découverte : plan du scan") {
        var options = ScanOptions(profile: .rapide)
        let standard = ScanPlan(options: options, autoDiscoverSwitches: true)
        try expectEqual(standard.phases, ScanPhase.allCases, "plan par défaut : toutes les étapes")
        try expect(standard.ping && standard.arp && standard.resolvesNames && !standard.probesPresence && !standard.lldp, "comportement actuel")
        try expectEqual(ScanPlan(options: options, autoDiscoverSwitches: false).phases, [.ping, .arp, .details], "sans découverte SNMP")
        try expect(ScanPlan(options: ScanOptions(profile: .complet), autoDiscoverSwitches: false).snmp, "Complet : SNMP toujours")
        options.methods.snmp = false
        try expect(!ScanPlan(options: options, autoDiscoverSwitches: true).snmp, "SNMP décoché")
        options.methods.icmp = false
        options.methods.tcp = true
        options.methods.reverseDNS = false
        options.methods.mdns = false
        options.methods.netbios = false
        options.portOverride = []
        let tcpOnly = ScanPlan(options: options, autoDiscoverSwitches: true)
        try expect(!tcpOnly.ping && tcpOnly.probesPresence, "présence par TCP")
        try expectEqual(tcpOnly.presenceTCPPorts, ScanMethods.defaultTCPPorts, "ports de présence")
        try expectEqual(tcpOnly.phases, [.ping, .arp], "ni noms ni ports")
        options.methods.arp = false
        options.methods.tcp = false
        try expect(ScanPlan(options: options, autoDiscoverSwitches: false).findsNothing, "aucune méthode de présence")
        var lldp = ScanMethods()
        lldp.lldp = true
        lldp.udp = true
        try expectEqual(lldp.tags, ["ICMP", "ARP", "UDP", "DNS · mDNS · NetBIOS", "SNMP", "LLDP/CDP"], "étiquettes du profil")
        var noNames = ScanMethods()
        noNames.reverseDNS = false
        noNames.mdns = false
        noNames.netbios = false
        try expect(noNames.nameResolver() == nil, "aucune méthode de noms : aucun résolveur")
        noNames.mdns = true
        let chain = noNames.nameResolver()
        try expect(chain?.reverseDNS == nil && chain?.mdns != nil && chain?.netbios == nil, "chaîne réduite à mDNS")
    }

    suite.add("Méthodes de découverte : effet réel sur le moteur (sans ICMP, présence TCP, sans ARP)") {
        let target = ScanTarget(label: "Bureau", range: try IPRange(parsing: "10.0.0.1-6"))
        let pinger = CountingPinger(replies: [IPv4Address("10.0.0.1")!: 0.9])
        let presence = FakePresence(hits: [IPv4Address("10.0.0.3")!: ScanPresenceHit(method: .tcp, port: 443, milliseconds: 3)])
        let arp = ScanFakeARP(table: [IPv4Address("10.0.0.5")!: MACAddress("04:d5:90:3a:7b:11")!])
        let names = CountingNames()
        var options = ScanOptions(profile: .rapide, concurrency: 4)
        options.methods.icmp = false
        options.methods.arp = false
        options.methods.tcp = true
        options.methods.reverseDNS = false
        options.methods.mdns = false
        options.methods.netbios = false
        options.portOverride = []
        let engine = ScanEngine(pinger: pinger, arp: arp, ports: ScanNoPorts(), names: names, presence: presence)
        var found: [IPv4Address: Device] = [:]
        var phases: [ScanPhase] = []
        var lastProgress: ScanRangeProgress?
        for await event in engine.scan([target], options: options) {
            switch event {
            case .phase(let phase): phases.append(phase)
            case .deviceFound(let device, _), .deviceUpdated(let device, _): found[device.ip] = device
            case .rangeProgress(let progress): lastProgress = progress
            default: break
            }
        }
        try expectEqual(await pinger.count, 0, "ICMP décoché : aucun ping")
        try expectEqual(await presence.asked, 6, "chaque adresse sondée en TCP")
        try expectEqual(Array(found.keys), [IPv4Address("10.0.0.3")!], "seul l'hôte qui répond en TCP")
        try expect(found[IPv4Address("10.0.0.3")!]?.latencyMs == nil, "pas de latence ICMP inventée")
        try expectEqual(phases, [.ping], "ni ARP, ni noms, ni ports")
        try expectEqual(await names.count, 0, "noms décochés : aucune résolution")
        try expectEqual(lastProgress?.done, 6, "toutes les adresses comptées")

        // Ni ICMP, ni TCP, ni UDP : seule la table ARP, l'avancement va quand même au bout.
        var arpOnly = ScanOptions(profile: .rapide, concurrency: 4)
        arpOnly.methods.icmp = false
        arpOnly.portOverride = []
        let second = ScanEngine(pinger: pinger, arp: arp, ports: ScanNoPorts(), names: ScanNoNames(), presence: presence)
        var arpFound: [IPv4Address] = []
        var arpProgress: ScanRangeProgress?
        for await event in second.scan([target], options: arpOnly) {
            if case .deviceFound(let device, _) = event { arpFound.append(device.ip) }
            if case .rangeProgress(let progress) = event { arpProgress = progress }
        }
        try expectEqual(arpFound, [IPv4Address("10.0.0.5")!], "hôte de la table ARP")
        try expectEqual(arpProgress?.done, 6, "avancement complet sans sonde")
    }

    suite.add("Export JSON des résultats") {
        let device = Device(ip: IPv4Address("10.0.0.5")!, mac: MACAddress("04:d5:90:3a:7b:11"), vendor: "Brother", latencyMs: 4.12,
                            openPorts: [80, 9100], vlan: 20, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 60),
                            rangeLabel: "Bureau", deviceType: .imprimante)
        let data = ScanJSON.data([device], date: Date(timeIntervalSince1970: 120))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScanJSON.Document.self, from: data)
        try expectEqual(document.appareils.first?.ip, "10.0.0.5", "IP")
        try expectEqual(document.appareils.first?.latenceMs, 4.1, "latence arrondie")
        try expectEqual(document.appareils.first?.type, "Imprimante", "type lisible")
        try expectEqual(ExportFormat(rawValue: "json"), .json, "format enregistré")
    }
}

// MARK: - Outils des tests

/// Dossier temporaire : données de l'app, préférences et dossier des sauvegardes.
struct BackupSandbox {
    static let secret = "SuperSecret-123!"
    static let etat = #"{"version":1,"ranges":[{"text":"10.0.0.0/24"}]}"#

    let root: URL
    var data: URL { root.appendingPathComponent("NetScope", isDirectory: true) }
    var backups: URL { root.appendingPathComponent("Sauvegardes", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-sauvegarde-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: data.appendingPathComponent("outils"), withIntermediateDirectories: true)
        try Data(Self.etat.utf8).write(to: data.appendingPathComponent("etat.json"))
        try Data(#"{"version":2,"devices":[]}"#.utf8).write(to: data.appendingPathComponent("inventaire.json"))
        try Data(#"{"probes":[]}"#.utf8).write(to: data.appendingPathComponent("surveillance.json"))
        try Data("[]".utf8).write(to: data.appendingPathComponent("outils/historique.json"))
        try Data("#oui\n".utf8).write(to: data.appendingPathComponent("oui.tsv"))
        try Data("x".utf8).write(to: data.appendingPathComponent(".cache.json"))
    }

    func source() throws -> BackupSource {
        let preferences: [String: Any] = ["reglages.scan.threads": 64, "reglages.scan.ports": "22,80",
                                          "reglages.smtp.motDePasse": Self.secret, "NetScope.speedtest.jeton": Self.secret]
        let plist = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        return BackupSource(dataDirectory: data, preferences: plist,
                            keychain: [BackupKeychainItem(service: "com.danymenard.netscope.snmp", account: "identifiants", usage: "SNMP"),
                                       BackupKeychainItem(service: "com.danymenard.netscope.github", account: "jeton", usage: "GitHub")],
                            appVersion: "0.8.0", appBuild: "80")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

actor PingCounter {
    var value = 0
    func increment() { value += 1 }
}

struct CountingPinger: ScanPinging {
    let replies: [IPv4Address: Double]
    let counter = PingCounter()
    var count: Int { get async { await counter.value } }

    func ping(_ ip: IPv4Address, timeout: Duration) async -> Double? {
        await counter.increment()
        return replies[ip]
    }
}

struct CountingNames: ScanNameResolving {
    let counter = PingCounter()
    var count: Int { get async { await counter.value } }

    func name(for ip: IPv4Address, timeout: Duration) async -> String? {
        await counter.increment()
        return nil
    }
}

struct FakePresence: ScanPresenceProbing {
    let hits: [IPv4Address: ScanPresenceHit]
    let counter = PingCounter()
    var asked: Int { get async { await counter.value } }

    func probe(_ ip: IPv4Address, tcpPorts: [UInt16], udpPorts: [UInt16], timeout: Duration) async -> ScanPresenceHit? {
        await counter.increment()
        return hits[ip]
    }
}
