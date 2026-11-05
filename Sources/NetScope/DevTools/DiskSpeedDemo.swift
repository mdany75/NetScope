import Foundation
import NetScopeCore

/// Démonstration de l'outil « Vitesse des disques » (`--demo`) : emplacements fictifs (SSD interne,
/// disque USB, partage SMB du NAS, OneDrive), un test terminé et un historique. Rien n'est écrit sur
/// le disque ni envoyé sur le réseau ; « Lancer » rejoue une mesure fictive.
/// NETSCOPE_DISQUE_DEMO=interne|usb|nas|nuage choisit le test terminé affiché (nas par défaut) ;
/// NETSCOPE_OUTIL_DEMO=disques ouvre l'outil pour la capture.
@MainActor
enum DiskSpeedDemo {
    static let home = "/Users/technicien"
    /// Latence fictive vers le NAS.
    static let serverLatency = 3.4

    static let internalSSD = DiskLocation(name: "Macintosh HD", path: "/", testParent: home + "/Library/Caches", kind: .interne,
                                          fileSystem: "APFS", totalBytes: 994_662_584_320, freeBytes: 412_318_000_000)
    static let usb = DiskLocation(name: "Samsung T7", path: "/Volumes/Samsung T7", kind: .externe, fileSystem: "exFAT",
                                  totalBytes: 1_000_202_043_392, freeBytes: 640_410_000_000)
    /// Le partage Projets tel que monté sur le Mac (volume trouvé).
    static let nasMount = DiskLocation(name: "Projets", path: "/Volumes/Projets", kind: .reseau, fileSystem: "SMB",
                                       totalBytes: 7_984_000_000_000, freeBytes: 3_120_000_000_000, server: "nas-bureau.local",
                                       share: "Projets", networkProtocol: .smb)

    // Emplacements ajoutés au Siège (note 55) : le NAS du bureau (déjà monté, avec un test) et le
    // partage Sauvegardes du serveur de sauvegarde (choisi dans le Scanner, pas encore monté).
    static var siegeKey: String { SiteFiles.key(for: SitesDemo.siegeID) }
    static let nasShareID = UUID(uuidString: "D15C0055-0001-4E55-9A11-00000000B001")!
    static let backupShareID = UUID(uuidString: "D15C0055-0002-4E55-9A11-00000000B002")!

    static var nasShare: DiskShareLocation {
        DiskShareLocation(id: nasShareID, siteKey: siegeKey, name: "NAS Bureau – Projets", kind: .smb, server: "nas-bureau.local",
                          share: "Projets", user: "technicien", hasPassword: true, created: Date(timeIntervalSince1970: 1_790_000_000))
    }

    static var backupShare: DiskShareLocation {
        DiskShareLocation(id: backupShareID, siteKey: siegeKey, name: "Sauvegardes", kind: .smb, server: "10.10.0.31",
                          share: "Sauvegardes", user: "BUREAU;technicien", deviceName: "Serveur de sauvegarde",
                          deviceIP: "10.10.0.31", deviceHost: "SRV-BACKUP", hasPassword: true,
                          created: Date(timeIntervalSince1970: 1_790_100_000))
    }

    /// Le NAS tel que la liste l'affiche : volume monté reconnu comme l'emplacement ajouté.
    static var nas: DiskLocation {
        var location = nasMount
        location.name = nasShare.displayName
        location.savedID = nasShare.locationID
        return location
    }

    static var backup: DiskLocation {
        DiskLocation(name: backupShare.displayName, path: backupShare.address, testParent: "", kind: .reseau, fileSystem: "SMB",
                     server: backupShare.server, share: backupShare.share, networkProtocol: .smb,
                     savedID: backupShare.locationID, isMounted: false)
    }

    /// « Tester le serveur » fictif : NAS (SMB, NFS, WebDAV), serveur de sauvegarde (SMB et HTTPS),
    /// tout autre nom (rien ne répond).
    static func serverReport(host: String, now: Date = Date()) -> DiskServerReport {
        func ports(_ open: [UInt16: Double], closed: [UInt16] = []) -> [PortScanResult] {
            DiskServerCheck.ports.map { item in
                if let rtt = open[item.port] { return PortScanResult(port: item.port, state: .open, rttMs: rtt) }
                return PortScanResult(port: item.port, state: closed.contains(item.port) ? .closed : .filtered)
            }
        }
        let key = DiskShareCatalog.normalizedHost(host)
        if key == "nas-bureau" || key == "10.10.0.20" {
            return DiskServerReport(host: host, address: "10.10.0.20", pingMs: serverLatency,
                                    ports: ports([445: 2.1, 139: 2.3, 2049: 2.0, 80: 2.6, 443: 2.8], closed: [548]), date: now)
        }
        if key == "10.10.0.31" || key == "srv-backup" {
            return DiskServerReport(host: host, address: "10.10.0.31", pingMs: 1.2,
                                    ports: ports([445: 1.4, 443: 1.9], closed: [139, 2049, 548, 80]), date: now)
        }
        return DiskServerReport(host: host, address: IPv4Address(host).map { _ in host } ?? "10.182.122.250", pingMs: nil,
                                ports: ports([:]), date: now)
    }

    /// Captures : NETSCOPE_DISQUE_FEUILLE=nouveau (ajout, appareil choisi et serveur testé) ou nas
    /// (modification du NAS) dessine la feuille par-dessus l'outil.
    static var snapshotDraft: DiskShareDraft? {
        guard RegEnvironment.isSnapshot, let raw = ProcessInfo.processInfo.environment["NETSCOPE_DISQUE_FEUILLE"] else { return nil }
        if raw == "nas" {
            return DiskShareDraft(share: nasShare, isNew: false, report: serverReport(host: nasShare.server))
        }
        var share = backupShare
        share.id = UUID(uuidString: "D15C0055-0003-4E55-9A11-00000000B003")!
        share.name = ""
        share.share = "Archives"
        share.hasPassword = false
        return DiskShareDraft(share: share, isNew: true, report: serverReport(host: share.server))
    }
    static let onedrive = DiskLocation(name: "OneDrive – Bureau", path: home + "/Library/CloudStorage/OneDrive-Bureau",
                                       kind: .nuage, fileSystem: "File Provider", totalBytes: 994_662_584_320,
                                       freeBytes: 412_318_000_000, provider: .onedrive, account: "Bureau")

    static var locations: [DiskLocation] { [internalSSD, usb, nas, onedrive] }

    /// Résultats fictifs réalistes de chaque emplacement.
    static func result(for location: DiskLocation, size: Int64 = 1 << 30, passes: Int = 2) -> DiskBenchmarkResult {
        func spread(_ value: Double, _ count: Int) -> [Double] {
            (0..<max(count, 1)).map { value * (1 + 0.012 * Double($0 % 2 == 0 ? $0 : -$0)) }
        }
        switch location.kind {
        case .interne:
            return DiskBenchmarkResult(sizeBytes: size, passes: passes, writePasses: spread(2_846, passes), readPasses: spread(3_118, passes),
                                       randomRead: DiskRandomResult(operations: 55_200, seconds: 3, iops: 18_400, meanMs: 0.054, p95Ms: 0.081),
                                       randomWrite: DiskRandomResult(operations: 29_400, seconds: 3, iops: 9_800, meanMs: 0.098, p95Ms: 0.21))
        case .externe:
            return DiskBenchmarkResult(sizeBytes: size, passes: passes, writePasses: spread(818, passes), readPasses: spread(904, passes),
                                       randomRead: DiskRandomResult(operations: 18_600, seconds: 3, iops: 6_200, meanMs: 0.16, p95Ms: 0.24),
                                       randomWrite: DiskRandomResult(operations: 14_700, seconds: 3, iops: 4_900, meanMs: 0.2, p95Ms: 0.41))
        case .reseau:
            return DiskBenchmarkResult(sizeBytes: size, passes: passes, writePasses: spread(71.2, passes), readPasses: spread(82.4, passes),
                                       randomRead: DiskRandomResult(operations: 4_350, seconds: 3, iops: 1_450, meanMs: 0.68, p95Ms: 1.9),
                                       randomWrite: DiskRandomResult(operations: 1_860, seconds: 3, iops: 620, meanMs: 1.6, p95Ms: 4.2))
        case .nuage:
            return DiskBenchmarkResult(sizeBytes: 256 << 20, passes: 1, writePasses: [1_384], cloudStatus: .envoye, uploadSeconds: 41)
        }
    }

    static func context(for location: DiskLocation) -> DiskNetworkContext? {
        switch location.kind {
        case .reseau: return DiskNetworkContext(linkMbps: 866, linkKind: "Wi-Fi", interfaceName: "en0", serverLatencyMs: serverLatency)
        case .nuage: return DiskNetworkContext(internetUpMbps: 487)
        default: return nil
        }
    }

    static func apply(to model: DiskSpeedModel, now: Date = Date()) {
        let choice: DiskLocation = {
            switch ProcessInfo.processInfo.environment["NETSCOPE_DISQUE_DEMO"] {
            case "interne": return internalSSD
            case "usb": return usb
            case "nuage": return onedrive
            case "sauvegardes": return backup
            default: return nas
            }
        }()
        model.loadDemoLocations([internalSSD, usb, nasMount, onedrive], shares: [nasShare, backupShare], selected: choice.id)
        // NETSCOPE_DISQUE_SERVEUR=1 : résultat de « Tester le serveur » sur le partage choisi.
        if ProcessInfo.processInfo.environment["NETSCOPE_DISQUE_SERVEUR"] != nil {
            for share in [nasShare, backupShare] where share.locationID == choice.id {
                model.setDemoServerReport(serverReport(host: share.server, now: now), for: share.id)
            }
        }
        model.setDemo(history: history(now: now))
        // Sauvegardes : ajouté, jamais mesuré, pas encore monté.
        if choice.id == backup.id { return }
        let config = DiskBenchmarkConfig(sizeBytes: choice.kind == .nuage ? 256 << 20 : 1 << 30, passes: choice.kind == .nuage ? 1 : 2)
        let result = result(for: choice, size: config.sizeBytes, passes: config.passes)
        let context = context(for: choice)
        let verdict = DiskAdvisor.verdict(kind: choice.kind, result: result, context: context ?? DiskNetworkContext())
        model.loadDemoResult(location: choice, config: config, result: result, points: curve(result), network: context, verdict: verdict)
    }

    /// Courbe fictive : écriture puis lecture de chaque passe, avec de petites variations.
    static func curve(_ result: DiskBenchmarkResult) -> [DiskPoint] {
        var points: [DiskPoint] = []
        var time = 0.4
        var id = 0
        var segment = 0
        for index in 0..<result.passes {
            for (phase, list) in [(DiskPhase.ecriture, result.writePasses), (.lecture, result.readPasses)] where index < list.count {
                segment += 1
                let mean = list[index]
                let seconds = min(8, max(2.4, Double(result.sizeBytes) / 1_000_000 / mean))
                let steps = Int(seconds / 0.1)
                for step in 0..<steps {
                    let x = Double(step)
                    // Montée rapide au début, ondulation douce, creux ponctuels (vidage du cache du disque).
                    let ramp = min(1, 0.55 + x / 6)
                    let wave = 1 + 0.035 * sin(x * 0.9 + Double(index) * 1.3) + 0.02 * sin(x * 2.7)
                    let dip = phase == .ecriture && step % 23 == 17 ? 0.86 : 1
                    id += 1
                    points.append(DiskPoint(id: id, time: time, value: mean * ramp * wave * dip, phase: phase, segment: segment))
                    time += 0.1
                }
                time += 0.3
            }
        }
        return points
    }

    /// Historique fictif : quelques jours de tests sur les quatre emplacements.
    static func history(now: Date) -> [DiskTestRecord] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func record(_ location: DiskLocation, _ hours: Double, scale: Double = 1, size: Int64 = 1 << 30, passes: Int = 2,
                    context: DiskNetworkContext? = nil, upload: Double? = nil) -> DiskTestRecord {
            var result = result(for: location, size: location.kind == .nuage ? 256 << 20 : size, passes: passes)
            result.writePasses = result.writePasses.map { $0 * scale }
            result.readPasses = result.readPasses.map { $0 * scale }
            if let upload { result.uploadSeconds = upload }
            let context = context ?? self.context(for: location)
            let verdict = DiskAdvisor.verdict(kind: location.kind, result: result, context: context ?? DiskNetworkContext())
            return DiskTestRecord(date: ago(hours), location: location, result: result, network: context, verdict: verdict)
        }
        let ethernet = DiskNetworkContext(linkMbps: 1000, linkKind: "Ethernet", interfaceName: "en7", serverLatencyMs: 0.6)
        return [
            record(nas, 0.2),
            record(usb, 1.5, passes: 3),
            record(onedrive, 3.2),
            record(internalSSD, 5, size: 5 << 30),
            record(nas, 26, scale: 1.38, context: ethernet),
            record(usb, 30, scale: 0.42, size: 256 << 20, passes: 1),
            record(onedrive, 50, upload: 96),
            record(nas, 74, scale: 0.37, context: DiskNetworkContext(linkMbps: 1000, linkKind: "Ethernet", interfaceName: "en7",
                                                                   serverLatencyMs: 31)),
            record(internalSSD, 98),
        ]
    }

    /// Mesure fictive rejouée quand on clique « Lancer » en démonstration (environ 6 s).
    struct Engine: DiskBenchmarkEngine {
        let location: DiskLocation
        let config: DiskBenchmarkConfig

        func run() -> AsyncStream<DiskEvent> {
            let location = self.location, config = self.config
            return AsyncStream { continuation in
                let task = Task {
                    let result = await MainActor.run { DiskSpeedDemo.result(for: location, size: config.sizeBytes, passes: config.passes) }
                    let plan = DiskPlan(config: config, kind: location.kind)
                    var elapsed = 0.0
                    func sleep() async -> Bool {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        elapsed += 0.1
                        return !Task.isCancelled
                    }
                    continuation.yield(.phase(.preparation, pass: 1))
                    var final = DiskBenchmarkResult(sizeBytes: result.sizeBytes, passes: result.passes)
                    for pass in 1...result.passes {
                        for (phase, list) in [(DiskPhase.ecriture, result.writePasses), (.lecture, result.readPasses)] where pass <= list.count {
                            continuation.yield(.phase(phase, pass: pass))
                            let mean = list[pass - 1]
                            let steps = max(6, 18 / result.passes)
                            for step in 0..<steps {
                                guard await sleep() else { continuation.yield(.stopped); continuation.finish(); return }
                                let value = mean * (0.92 + 0.08 * sin(Double(step)))
                                continuation.yield(.progress(DiskProgress(phase: phase, pass: pass,
                                                                          fraction: plan.fraction(phase: phase, pass: pass,
                                                                                                  stepFraction: Double(step + 1) / Double(steps)),
                                                                          instant: value, elapsed: elapsed)))
                            }
                            continuation.yield(.passMeasured(phase, pass: pass, mbps: mean))
                            if phase == .ecriture { final.writePasses.append(mean) } else { final.readPasses.append(mean) }
                        }
                    }
                    if location.kind == .nuage {
                        continuation.yield(.phase(.envoi, pass: 1))
                        for step in 0..<12 {
                            guard await sleep() else { continuation.yield(.stopped); continuation.finish(); return }
                            continuation.yield(.cloud(step < 11 ? .envoi : .envoye, elapsed: Double(step + 1) * 3.4))
                        }
                        final.cloudStatus = .envoye
                        final.uploadSeconds = result.uploadSeconds
                    } else if config.random {
                        for (phase, value) in [(DiskPhase.aleatoireLecture, result.randomRead), (.aleatoireEcriture, result.randomWrite)] {
                            continuation.yield(.phase(phase, pass: 1))
                            for _ in 0..<6 { guard await sleep() else { continuation.yield(.stopped); continuation.finish(); return } }
                            if let value { continuation.yield(.random(phase, value)) }
                        }
                        final.randomRead = result.randomRead
                        final.randomWrite = result.randomWrite
                    }
                    continuation.yield(.phase(.nettoyage, pass: 1))
                    continuation.yield(.finished(final))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
