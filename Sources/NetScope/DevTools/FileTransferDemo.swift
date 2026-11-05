import Foundation
import NetScopeCore

// Note 50 : démonstration du navigateur de fichiers (--demo) et captures (NETSCOPE_REMOTE_VIEW=
// fichiers, fichiers-ftp). Arborescences fictives d'un NAS Synology (SFTP) et d'un switch Aruba
// (FTP) ; le volet « Ce Mac » est fictif lui aussi. Aucun réseau, aucun fichier écrit.

enum FileTransferDemo {
    /// Dossier « Téléchargements » fictif du volet Mac.
    static let localHome = URL(fileURLWithPath: "/Users/dany/Downloads", isDirectory: true)

    /// Dates fixes (4 novembre 2026), pour des captures identiques d'une fois à l'autre.
    static func day(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static func file(_ name: String, in directory: String, _ size: Int64, _ date: Date, _ perms: String = "rw-r--r--",
                             owner: String = "admin-nas") -> RemoteFileEntry {
        RemoteFileEntry(name: name, path: RemotePath.join(directory, name), kind: .file, size: size, modified: date,
                        permissions: perms, owner: owner, group: "users")
    }

    private static func folder(_ name: String, in directory: String, _ date: Date, owner: String = "admin-nas") -> RemoteFileEntry {
        RemoteFileEntry(name: name, path: RemotePath.join(directory, name), kind: .directory, modified: date,
                        permissions: "rwxr-xr-x", owner: owner, group: "users")
    }

    // MARK: Serveurs fictifs

    /// NAS Synology par SFTP : sauvegardes des configurations et firmwares.
    static func nasTree() -> [String: [RemoteFileEntry]] {
        let base = "/volume1/sauvegardes"
        return [
            "/": [folder("volume1", in: "/", day(1, 9, month: 10), owner: "root")],
            "/volume1": [folder("homes", in: "/volume1", day(1, 9, month: 10), owner: "root"),
                         folder("sauvegardes", in: "/volume1", day(4, 10, 15))],
            "/volume1/homes": [folder("admin-nas", in: "/volume1/homes", day(28, 8, month: 10))],
            "/volume1/homes/admin-nas": [file("notes.txt", in: "/volume1/homes/admin-nas", 1_840, day(28, 8, month: 10))],
            base: [
                folder("configs-switchs", in: base, day(3, 22, 0)),
                folder("firmware", in: base, day(4, 10, 15)),
                folder("fortigate", in: base, day(3, 22, 5)),
                folder("journaux", in: base, day(4, 6, 0)),
                file("FGT60F_7-4-4_sauvegarde.conf", in: base, 1_843_200, day(3, 22, 5)),
                file("SW-CORE-01_2026-11-03.cfg", in: base, 48_212, day(3, 22, 0)),
                file("SW-ETG2-01_2026-11-03.cfg", in: base, 31_406, day(3, 22, 1)),
                file("inventaire-siege.csv", in: base, 214_530, day(4, 8, 30), "rw-rw-r--"),
                file("lisez-moi.txt", in: base, 2_048, day(12, 14, 2, month: 9), "r--r--r--"),
                file("restaurer-switch.sh", in: base, 3_912, day(12, 14, 0, month: 9), "rwxr-x---"),
            ],
            base + "/configs-switchs": [
                file("SW-CORE-01_2026-11-01.cfg", in: base + "/configs-switchs", 48_190, day(1, 22, 0)),
                file("SW-CORE-01_2026-11-02.cfg", in: base + "/configs-switchs", 48_205, day(2, 22, 0)),
                file("SW-ETG1-01_2026-11-03.cfg", in: base + "/configs-switchs", 29_877, day(3, 22, 0)),
            ],
            base + "/firmware": [
                file("FAP-231F_v7.4.3.out", in: base + "/firmware", 42_336_256, day(18, 11, 0, month: 10)),
                file("WC_16_11_0012.swi", in: base + "/firmware", 25_165_824, day(2, 9, 30, month: 10)),
            ],
            base + "/fortigate": [file("FGT60F_7-4-3_sauvegarde.conf", in: base + "/fortigate", 1_820_160, day(20, 22, 5, month: 10))],
            base + "/journaux": [
                file("syslog-2026-11-03.log.gz", in: base + "/journaux", 3_481_600, day(4, 6, 0)),
                file("syslog-2026-11-02.log.gz", in: base + "/journaux", 3_215_872, day(3, 6, 0)),
            ],
        ]
    }

    /// Switch Aruba par FTP : configuration et image système.
    static func switchTree() -> [String: [RemoteFileEntry]] {
        [
            "/": [
                folder("cfg", in: "/", day(4, 7, 12), owner: "manager"),
                folder("logs", in: "/", day(4, 10, 2), owner: "manager"),
                file("primary.swi", in: "/", 25_165_824, day(2, 9, 41, month: 10), owner: "manager"),
                file("secondary.swi", in: "/", 24_903_680, day(11, 15, 3, month: 6), owner: "manager"),
            ],
            "/cfg": [
                file("startup-config", in: "/cfg", 31_406, day(4, 7, 12), owner: "manager"),
                file("running-config", in: "/cfg", 31_520, day(4, 10, 2), owner: "manager"),
            ],
            "/logs": [file("event.log", in: "/logs", 412_160, day(4, 10, 2), owner: "manager")],
        ]
    }

    // MARK: Volet Mac fictif

    static func localEntries(in url: URL) -> [RemoteFileEntry] {
        let path = url.path
        func local(_ name: String, _ size: Int64?, _ date: Date, directory: Bool = false) -> RemoteFileEntry {
            RemoteFileEntry(name: name, path: (path as NSString).appendingPathComponent(name), kind: directory ? .directory : .file,
                            size: size, modified: date, permissions: directory ? "rwxr-xr-x" : "rw-r--r--")
        }
        if path == localHome.path {
            return [
                local("Captures réseau", nil, day(2, 16, 40), directory: true),
                local("Firmware", nil, day(4, 9, 55), directory: true),
                local("FAP-231F_v7.4.4.out", 43_110_400, day(4, 9, 52)),
                local("FGT60F_7-4-4_sauvegarde.conf", 1_843_200, day(4, 8, 12)),
                local("SW-CORE-01_2026-11-04.cfg", 48_390, day(4, 10, 6)),
                local("WC_16_11_0013.swi", 26_214_400, day(4, 9, 58)),
                local("rapport-siege-novembre.pdf", 1_254_400, day(4, 10, 20)),
            ].sorted(by: RemoteFileEntry.browserOrder)
        }
        if path.hasSuffix("/Firmware") {
            return [local("FortiAP-231F_v7.4.4.out", 43_110_400, day(4, 9, 52)), local("ArubaOS-Switch_16.11.0013.swi", 26_214_400, day(4, 9, 58))]
        }
        if path.hasSuffix("/Captures réseau") {
            return [local("vlan20-dhcp.pcapng", 3_402_112, day(2, 16, 40))]
        }
        return []
    }

    static func localSize(_ url: URL) -> Int64? {
        localEntries(in: url.deletingLastPathComponent()).first { $0.name == url.lastPathComponent }?.size
    }

    // MARK: Clients fictifs

    private static let lock = NSLock()
    nonisolated(unsafe) private static var clients: [UUID: DemoFileTransfer] = [:]

    /// Client fictif de la connexion (le même pour le navigateur et la file : même arborescence).
    static func client(for connection: RemoteConnection) -> DemoFileTransfer {
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[connection.id] { return existing }
        let created = connection.proto == .sftp
            ? DemoFileTransfer(tree: nasTree(), home: "/volume1/homes/admin-nas")
            : DemoFileTransfer(tree: switchTree(), home: "/")
        clients[connection.id] = created
        return created
    }

    // MARK: Captures

    /// Session figée des captures : connectée, dossier ouvert, sélection et file des transferts.
    @MainActor
    static func snapshotSession(for connection: RemoteConnection) -> FileTransferSession {
        let session = FileTransferSession(connection: connection, store: nil, demo: true)
        let sftp = connection.proto == .sftp
        let tree = sftp ? nasTree() : switchTree()
        let remote = sftp ? "/volume1/sauvegardes" : "/cfg"
        session.phase = .connected
        session.remotePath = remote
        session.remoteEntries = (tree[remote] ?? []).sorted(by: RemoteFileEntry.browserOrder)
        session.remoteSelection = [RemotePath.join(remote, sftp ? "SW-CORE-01_2026-11-03.cfg" : "startup-config")]
        session.localEntries = localEntries(in: localHome)
        session.localSelection = [localHome.appendingPathComponent(sftp ? "FAP-231F_v7.4.4.out" : "WC_16_11_0013.swi").path]
        let started = day(4, 10, 21)
        if sftp {
            session.jobs = [
                TransferJob(direction: .download, localURL: localHome.appendingPathComponent("SW-ETG2-01_2026-11-03.cfg"),
                            remotePath: remote + "/SW-ETG2-01_2026-11-03.cfg", totalBytes: 31_406, transferredBytes: 31_406,
                            state: .done, startedAt: started, finishedAt: started.addingTimeInterval(1)),
                TransferJob(direction: .upload, localURL: localHome.appendingPathComponent("FAP-231F_v7.4.4.out"),
                            remotePath: remote + "/firmware/FAP-231F_v7.4.4.out", totalBytes: 43_110_400, transferredBytes: 26_738_688,
                            state: .running, bytesPerSecond: 2_600_000, startedAt: started.addingTimeInterval(20)),
                TransferJob(direction: .upload, localURL: localHome.appendingPathComponent("WC_16_11_0013.swi"),
                            remotePath: remote + "/firmware/WC_16_11_0013.swi", totalBytes: 26_214_400, transferredBytes: 9_437_184,
                            state: .retrying(attempt: 1), startedAt: started.addingTimeInterval(4), attempts: 1),
                TransferJob(direction: .download, localURL: localHome.appendingPathComponent("inventaire-siege.csv"),
                            remotePath: remote + "/inventaire-siege.csv", totalBytes: 214_530),
            ]
            session.log = ["10:21  Connecté à 10.10.0.20 (SFTP).", "10:21  Réception terminée\u{00A0}: SW-ETG2-01_2026-11-03.cfg",
                           "10:22  Coupure pendant WC_16_11_0013.swi\u{00A0}: reprise dans 2\u{00A0}s."]
        } else {
            session.jobs = [
                TransferJob(direction: .download, localURL: localHome.appendingPathComponent("startup-config"),
                            remotePath: "/cfg/startup-config", totalBytes: 31_406, transferredBytes: 31_406,
                            state: .done, startedAt: started, finishedAt: started.addingTimeInterval(1)),
                TransferJob(direction: .upload, localURL: localHome.appendingPathComponent("WC_16_11_0013.swi"),
                            remotePath: "/secondary.swi", totalBytes: 26_214_400, transferredBytes: 7_340_032,
                            state: .running, bytesPerSecond: 4_200_000, startedAt: started.addingTimeInterval(8)),
            ]
            session.log = ["10:21  Connecté à 10.182.122.3 (FTP)."]
        }
        return session
    }
}

/// Serveur fictif en mémoire (démonstration) : les transferts avancent sans rien écrire.
final class DemoFileTransfer: RemoteFileTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var tree: [String: [RemoteFileEntry]]
    private let home: String

    init(tree: [String: [RemoteFileEntry]], home: String) {
        self.tree = tree
        self.home = home
    }

    func connect() async throws -> String {
        try await Task.sleep(nanoseconds: 300_000_000)
        return home
    }

    func list(_ path: String) async throws -> [RemoteFileEntry] {
        try await Task.sleep(nanoseconds: 120_000_000)
        return try withLock {
            guard let entries = tree[RemotePath.normalize(path)] else { throw FileTransferError.notFound(path) }
            return entries.sorted(by: RemoteFileEntry.browserOrder)
        }
    }

    func size(of path: String) async throws -> Int64? {
        withLock { entry(path)?.size }
    }

    func download(_ remotePath: String, to localURL: URL, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        let total = withLock { entry(remotePath)?.size } ?? 1_000_000
        try await simulate(total: total, progress: progress)
    }

    func upload(_ localURL: URL, to remotePath: String, resume: Bool, progress: @escaping FileTransferProgress) async throws {
        let total = FileTransferDemo.localSize(localURL) ?? 1_000_000
        try await simulate(total: total, progress: progress)
        withLock {
            let parent = RemotePath.parent(remotePath)
            var entries = tree[parent] ?? []
            entries.removeAll { $0.path == remotePath }
            entries.append(RemoteFileEntry(name: RemotePath.name(remotePath), path: remotePath, kind: .file, size: total,
                                           modified: Date(), permissions: "rw-r--r--", owner: "admin-nas", group: "users"))
            tree[parent] = entries
        }
    }

    func makeDirectory(_ path: String) async throws {
        withLock {
            let parent = RemotePath.parent(path)
            tree[parent, default: []].append(RemoteFileEntry(name: RemotePath.name(path), path: path, kind: .directory, modified: Date(),
                                                             permissions: "rwxr-xr-x", owner: "admin-nas", group: "users"))
            tree[path] = []
        }
    }

    func rename(_ from: String, to: String) async throws {
        try withLock {
            let parent = RemotePath.parent(from)
            guard var entries = tree[parent], let index = entries.firstIndex(where: { $0.path == from }) else { throw FileTransferError.notFound(from) }
            entries[index].name = RemotePath.name(to)
            entries[index].path = to
            tree[parent] = entries
            if let children = tree.removeValue(forKey: from) { tree[to] = children }
        }
    }

    func deleteFile(_ path: String) async throws {
        withLock { tree[RemotePath.parent(path)]?.removeAll { $0.path == path } }
    }

    func removeDirectory(_ path: String) async throws {
        withLock {
            tree[RemotePath.parent(path)]?.removeAll { $0.path == path }
            tree[path] = nil
        }
    }

    func close() async {}

    private func entry(_ path: String) -> RemoteFileEntry? {
        tree[RemotePath.parent(path)]?.first { $0.path == RemotePath.normalize(path) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Avancement fictif : environ 8 Mo/s, au moins deux secondes.
    private func simulate(total: Int64, progress: FileTransferProgress) async throws {
        let steps = 20
        let duration = max(2, min(8, Double(total) / 8_000_000))
        for step in 1...steps {
            try await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            try Task.checkCancellation()
            progress(total * Int64(step) / Int64(steps))
        }
    }
}
