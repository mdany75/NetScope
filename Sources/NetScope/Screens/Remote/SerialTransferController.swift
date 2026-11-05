import AppKit
import Foundation
import NetScopeCore

/// Note 78 : un envoi ou une réception de fichiers XMODEM/YMODEM dans un onglet de console série.
/// L'automate (NetScopeCore) reçoit les octets du port à la place de l'émulateur tant que le
/// transfert dure ; un minuteur de 100 ms fait jouer les délais. En démonstration, un appareil
/// simulé (l'automate inverse, en mémoire, au débit d'une console à 115 200 bauds) répond : aucun
/// port série n'est ouvert.
@MainActor
final class SerialTransferController: ObservableObject, Identifiable {
    enum Direction: String, CaseIterable, Identifiable {
        case send, receive
        var id: String { rawValue }
        var label: String { self == .send ? "Envoyer vers l’appareil" : "Recevoir de l’appareil" }
    }

    let id = UUID()
    let direction: Direction
    let proto: SerialFileProtocol
    /// Fichiers envoyés (envoi) ; dossier où ranger les fichiers reçus (réception).
    let files: [SerialFile]
    let destination: URL?
    @Published private(set) var state: SerialTransferState = .waiting
    @Published private(set) var progress = SerialTransferProgress()
    @Published private(set) var startedAt = Date()
    @Published private(set) var finishedAt: Date?
    /// Fichiers reçus et enregistrés.
    @Published private(set) var saved: [URL] = []
    @Published private(set) var saveError: String?

    private let machine: SerialTransferMachine
    private let clockStart = DispatchTime.now().uptimeNanoseconds
    private var timer: Task<Void, Never>?
    /// Octets à écrire sur le port (posé par l'onglet).
    var send: (([UInt8]) -> Void)?
    /// Fin du transfert (message à écrire dans le terminal).
    var onFinish: ((String) -> Void)?
    // Démonstration : appareil simulé.
    private var peer: SerialTransferMachine?
    private var toPeer: [UInt8] = []
    private var fromPeer: [UInt8] = []
    private let demo: Bool
    /// Captures : transfert figé, qui ne reçoit rien et ne bouge pas.
    private(set) var isFrozen = false

    init(direction: Direction, proto: SerialFileProtocol, files: [SerialFile] = [], destination: URL? = nil, demo: Bool = false) {
        self.direction = direction
        self.proto = proto
        self.files = files
        self.destination = destination
        self.demo = demo
        switch direction {
        case .send:
            machine = XModemSender(proto: proto, files: files)
            if demo { peer = XModemReceiver(proto: proto) }
        case .receive:
            machine = XModemReceiver(proto: proto, defaultName: Self.defaultName(for: proto))
            if demo {
                let sample = SerialFile(name: "startup-config.txt", data: Array(TerminalDemo.sampleConfig.utf8))
                peer = XModemSender(proto: proto, files: [sample])
            }
        }
        progress = machine.progress
    }

    static func defaultName(for proto: SerialFileProtocol) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "console-\(formatter.string(from: Date())).bin"
    }

    var isActive: Bool { !state.isOver }

    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1e9 }

    // MARK: Déroulement

    func start() {
        startedAt = Date()
        output(machine.start(now: now))
        if let peer { fromPeer += peer.start(now: now) }
        refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.isActive else { return }
                self.tick()
            }
        }
    }

    /// Octets reçus du port pendant le transfert.
    func feed(_ bytes: [UInt8]) {
        guard isActive, !isFrozen else { return }
        output(machine.receive(bytes, now: now))
        refresh()
    }

    func cancel() {
        output(machine.cancel())
        refresh()
    }

    private func tick() {
        if peer != nil { runDemoPeer() }
        output(machine.tick(now: now))
        refresh()
    }

    private func output(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if peer != nil { toPeer += bytes } else { send?(bytes) }
    }

    /// Démonstration : environ 1 150 octets par 100 ms dans chaque sens (115 200 bauds).
    private func runDemoPeer() {
        guard let peer else { return }
        let budget = 1_150
        if !toPeer.isEmpty {
            let chunk = Array(toPeer.prefix(budget))
            toPeer.removeFirst(chunk.count)
            fromPeer += peer.receive(chunk, now: now)
        }
        fromPeer += peer.tick(now: now)
        if !fromPeer.isEmpty {
            let chunk = Array(fromPeer.prefix(budget))
            fromPeer.removeFirst(chunk.count)
            output(machine.receive(chunk, now: now))
        }
    }

    private func refresh() {
        progress = machine.progress
        guard machine.state != state else { return }
        state = machine.state
        guard state.isOver else { return }
        finishedAt = Date()
        timer?.cancel()
        if state == .finished, direction == .receive, let receiver = machine as? XModemReceiver {
            store(receiver.receivedFiles)
        }
        onFinish?(summary)
    }

    // MARK: Fichiers reçus

    private func store(_ files: [SerialFile]) {
        guard let destination else { return }
        if demo {
            // Démonstration : rien n'est écrit sur le disque.
            saved = files.map { destination.appendingPathComponent($0.name) }
            return
        }
        for file in files {
            let url = Self.uniqueURL(in: destination, name: XModem.safeName(file.name))
            do {
                try Data(file.data).write(to: url, options: .withoutOverwriting)
                if let date = file.modified { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
                saved.append(url)
            } catch {
                saveError = "Enregistrement de «\u{00A0}\(file.name)\u{00A0}» impossible\u{00A0}: \(error.localizedDescription)"
            }
        }
    }

    /// « firmware.bin », sinon « firmware 2.bin », « firmware 3.bin »… (jamais d'écrasement).
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    // MARK: Textes

    var title: String {
        let what = direction == .send ? "Envoi" : "Réception"
        return "\(what) \(proto.shortLabel)" + (progress.fileName.map { " · \($0)" } ?? "")
    }

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    var bytesPerSecond: Double? {
        let seconds = elapsed
        guard seconds > 0.5, progress.bytes > 0 else { return nil }
        return Double(progress.bytes) / seconds
    }

    /// « 62 % · 812 Kio sur 1,3 Mio · 11,2 Kio/s · reste 0:48 · 2 reprises ».
    var detail: String {
        var parts: [String] = []
        if let fraction = progress.fraction { parts.append("\(Int((fraction * 100).rounded()))\u{00A0}%") }
        let done = FileTransferFormat.size(progress.bytes)
        parts.append(progress.total.map { "\(done) sur \(FileTransferFormat.size($0))" } ?? done)
        if let rate = bytesPerSecond {
            parts.append(FileTransferFormat.rate(rate))
            if let total = progress.total, isActive, rate > 0 {
                parts.append("reste " + FileTransferFormat.remaining(Double(total - progress.bytes) / rate))
            }
        }
        if let count = progress.fileCount, count > 1 { parts.append("fichier \(progress.fileIndex) sur \(count)") }
        parts.append(progress.retries == 0 ? "aucune reprise" : "\(progress.retries) reprise\(progress.retries > 1 ? "s" : "")")
        return parts.joined(separator: " · ")
    }

    /// Ligne écrite dans le terminal à la fin.
    var summary: String {
        switch state {
        case .finished:
            if direction == .receive {
                let names = saved.map(\.lastPathComponent).joined(separator: ", ")
                return "\(proto.shortLabel)\u{00A0}: \(saved.count) fichier\(saved.count > 1 ? "s" : "") reçu\(saved.count > 1 ? "s" : "") (\(names)) dans \(destination?.lastPathComponent ?? "—")."
            }
            return "\(proto.shortLabel)\u{00A0}: \(files.map(\.name).joined(separator: ", ")) envoyé en \(FileTransferFormat.remaining(elapsed)), \(progress.retries) reprise\(progress.retries > 1 ? "s" : "")."
        default:
            return "\(proto.shortLabel)\u{00A0}: \(state.label)."
        }
    }

    // MARK: Démonstration et captures

    /// Transfert figé (captures) : envoi en cours, avancement et reprises fixes.
    static func snapshot(file: SerialFile, proto: SerialFileProtocol, bytes: Int64, retries: Int, seconds: Double) -> SerialTransferController {
        let controller = SerialTransferController(direction: .send, proto: proto, files: [file], demo: true)
        controller.state = .transferring
        controller.progress = SerialTransferProgress(fileName: file.name, fileIndex: 1, fileCount: 1, bytes: bytes,
                                                     total: Int64(file.data.count), blocks: Int(bytes / 1_024), retries: retries,
                                                     useCRC: true, blockSize: 1_024)
        controller.startedAt = Date().addingTimeInterval(-seconds)
        controller.isFrozen = true
        return controller
    }
}
