import Darwin
import Foundation

/// Machine d'état de transfert (émetteur, récepteur, client), menée par `TFTPDriver`.
protocol TFTPMachine {
    mutating func start() -> TFTPAction
    mutating func receive(_ packet: TFTPPacket) -> TFTPAction
    mutating func timeout() -> TFTPAction
    var timeoutInterval: TimeInterval { get }
    var progressBytes: Int64 { get }
}

extension TFTPSender: TFTPMachine {
    var timeoutInterval: TimeInterval { settings.timeout }
    var progressBytes: Int64 { bytesAcknowledged }
}

extension TFTPReceiver: TFTPMachine {
    var timeoutInterval: TimeInterval { settings.timeout }
    var progressBytes: Int64 { bytesReceived }
}

extension TFTPClientMachine: TFTPMachine {
    var timeoutInterval: TimeInterval { settings.timeout }
    var progressBytes: Int64 { bytesTransferred }
}

/// Mène une machine d'état sur un socket : envoie, attend (par tranches de 200 ms pour voir
/// l'annulation), retransmet au délai.
enum TFTPDriver {
    struct Link {
        var send: ([UInt8], TFTPPacket) -> Void
        /// Paquet suivant de l'autre côté (déjà filtré), délai écoulé ou erreur.
        var receive: (TimeInterval) -> TFTPSocket.Wait
        var cancelled: () -> Bool
        var progress: (Int64) -> Void
    }

    /// Renvoie nil en cas de succès, sinon l'échec.
    static func run<M: TFTPMachine>(_ machine: inout M, link: Link) -> TFTPFailure? {
        var lastProgress = Date.distantPast
        func perform(_ action: TFTPAction) -> TFTPFailure?? {
            for packet in action.packets { link.send(packet.encoded(), packet) }
            switch action {
            case .send: return nil
            case .complete: return .some(nil)
            case .fail(let failure): return .some(failure)
            }
        }
        if let outcome = perform(machine.start()) { return outcome }
        var deadline = Date().addingTimeInterval(machine.timeoutInterval)
        while true {
            if link.cancelled() {
                let failure = TFTPFailure.cancelled
                if let packet = failure.packetToPeer { link.send(packet.encoded(), packet) }
                return failure
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                if let outcome = perform(machine.timeout()) { return outcome }
                deadline = Date().addingTimeInterval(machine.timeoutInterval)
                continue
            }
            switch link.receive(min(remaining, 0.2)) {
            case .timeout:
                continue
            case .failure(let message):
                return .protocolError(message)
            case .datagram(let datagram):
                guard let packet = try? TFTPPacket.decode(datagram.bytes) else { continue }
                let action = machine.receive(packet)
                if !action.packets.isEmpty { deadline = Date().addingTimeInterval(machine.timeoutInterval) }
                if Date().timeIntervalSince(lastProgress) > 0.2 {
                    lastProgress = Date()
                    link.progress(machine.progressBytes)
                }
                if let outcome = perform(action) {
                    link.progress(machine.progressBytes)
                    return outcome
                }
            }
        }
    }

    /// Après l'ACK final : si le dernier bloc revient (ACK perdu), on le réacquitte, pendant au
    /// plus le délai du transfert (3 s au plus).
    static func dally<M: TFTPMachine>(_ machine: inout M, link: Link) {
        let end = Date().addingTimeInterval(min(machine.timeoutInterval, 3))
        while Date() < end, !link.cancelled() {
            guard case .datagram(let datagram) = link.receive(min(end.timeIntervalSinceNow, 0.2)) else { continue }
            guard let packet = try? TFTPPacket.decode(datagram.bytes) else { continue }
            for reply in machine.receive(packet).packets { link.send(reply.encoded(), reply) }
        }
    }
}

// MARK: - Serveur

/// Serveur TFTP temporaire (note 51) : écoute en UDP, sert les fichiers d'un dossier choisi en
/// lecture (RRQ) et, si permis, en écriture (WRQ). Chaque transfert a son propre socket (nouveau
/// port, le « TID » de la RFC 1350) et son propre fil d'exécution.
///
/// Port 69 sans droits administrateur : macOS (depuis 10.14) permet à une application ordinaire
/// d'écouter sous 1024 à condition d'écouter sur toutes les interfaces. Le serveur écoute donc
/// sur 0.0.0.0 et filtre lui-même l'interface choisie grâce à l'adresse de destination de chaque
/// requête (IP_RECVDSTADDR) ; les réponses partent de l'adresse qui a reçu la requête.
public final class TFTPServer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var root: URL
        public var port: UInt16
        /// Adresse locale qui accepte les requêtes ; nil : toutes les interfaces.
        public var listenAddress: IPv4Address?
        public var allowWrite: Bool
        public var allowOverwrite: Bool
        public var policy: TFTPServerPolicy
        /// Transferts simultanés au plus.
        public var maxTransfers: Int

        public init(root: URL, port: UInt16 = 69, listenAddress: IPv4Address? = nil, allowWrite: Bool = false,
                    allowOverwrite: Bool = false, policy: TFTPServerPolicy = TFTPServerPolicy(), maxTransfers: Int = 16) {
            self.root = root
            self.port = port
            self.listenAddress = listenAddress
            self.allowWrite = allowWrite
            self.allowOverwrite = allowOverwrite
            self.policy = policy
            self.maxTransfers = maxTransfers
        }
    }

    /// Un transfert demandé par un appareil.
    public struct Transfer: Sendable, Identifiable, Equatable {
        public var id = UUID()
        public var date = Date()
        public var peer: IPv4Address
        public var peerPort: UInt16
        /// Adresse du Mac qui a reçu la requête.
        public var local: IPv4Address?
        public var kind: TFTPRequest.Kind
        public var filename: String
        public var mode: TFTPMode
        public var options: [TFTPOption]
        public var settings: TFTPTransferSettings?
        /// Taille du fichier (lecture) ou taille annoncée (écriture, option tsize).
        public var size: Int64?
    }

    public enum Event: Sendable {
        case listening(port: UInt16)
        case started(Transfer)
        case progress(id: UUID, bytes: Int64)
        case finished(id: UUID, bytes: Int64, seconds: TimeInterval, retransmissions: Int)
        case failed(id: UUID, failure: TFTPFailure, bytes: Int64, seconds: TimeInterval)
        /// Requête refusée avant tout transfert (fichier introuvable, lecture seule…).
        case refused(Transfer, TFTPFailure)
        /// Paquet ignoré (requête reçue sur une autre interface, paquet illisible…).
        case ignored(peer: IPv4Address, reason: String)
        /// Écoute arrêtée (nil : arrêt demandé).
        case stopped(String?)
    }

    public let configuration: Configuration
    public private(set) var boundPort: UInt16 = 0
    private let events: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var running = false
    private var active: [String: UUID] = [:]

    public init(configuration: Configuration, events: @escaping @Sendable (Event) -> Void) {
        self.configuration = configuration
        self.events = events
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var activeTransfers: Int { lock.lock(); defer { lock.unlock() }; return active.count }

    /// Ouvre le port et commence à écouter. Sous 1024, l'écoute se fait sur toutes les interfaces
    /// (voir la description du type) ; au-dessus, directement sur l'adresse choisie.
    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        lock.unlock()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configuration.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TFTPFileError(.accessViolation, "Dossier partagé introuvable\u{00A0}: \(configuration.root.path).")
        }
        let bindAddress = Self.bindAddress(port: configuration.port, listen: configuration.listenAddress)
        let (fd, port) = try TFTPSocket.bind(address: bindAddress, port: configuration.port, receiveDestination: true)
        lock.lock()
        listener = fd
        boundPort = port
        running = true
        lock.unlock()
        events(.listening(port: port))
        let thread = Thread { [self] in listen(fd) }
        thread.name = "TFTP écoute \(port)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Adresse de liaison : toutes les interfaces sous 1024 (pas besoin d'être root), sinon l'adresse choisie.
    public static func bindAddress(port: UInt16, listen: IPv4Address?) -> IPv4Address? {
        port != 0 && port < 1024 ? nil : listen
    }

    /// Arrête l'écoute et annule les transferts en cours (un ERROR est envoyé aux appareils).
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { events(.stopped(nil)) }
    }

    private var shouldRun: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func listen(_ fd: Int32) {
        defer { close(fd) }
        while shouldRun {
            switch TFTPSocket.receive(fd, timeout: 0.2) {
            case .timeout:
                continue
            case .failure(let message):
                lock.lock()
                let wasRunning = running
                running = false
                lock.unlock()
                if wasRunning { events(.stopped("Écoute interrompue\u{00A0}: \(message)")) }
                return
            case .datagram(let datagram):
                handle(datagram, listener: fd)
            }
        }
    }

    /// Requête reçue sur le port d'écoute.
    private func handle(_ datagram: TFTPSocket.Datagram, listener fd: Int32) {
        if let wanted = configuration.listenAddress, let destination = datagram.destination,
           destination != wanted {
            events(.ignored(peer: datagram.from, reason: "requête reçue sur \(destination), hors de l’interface choisie (\(wanted))"))
            return
        }
        let packet: TFTPPacket
        do {
            packet = try TFTPPacket.decode(datagram.bytes)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "paquet illisible"
            if case TFTPDecodeError.unsupportedMode = error {
                TFTPSocket.send(fd, TFTPPacket.error(code: .illegalOperation, message: "Mode non pris en charge").encoded(),
                                to: datagram.from, port: datagram.fromPort)
            }
            events(.ignored(peer: datagram.from, reason: message))
            return
        }
        guard case .request(let request) = packet else {
            // Un DATA ou ACK sur le port d'écoute : transfert inconnu.
            TFTPSocket.send(fd, TFTPPacket.error(code: .unknownTransferID, message: TFTPWire.message(.unknownTransferID)).encoded(),
                            to: datagram.from, port: datagram.fromPort)
            events(.ignored(peer: datagram.from, reason: "paquet \(packet.summary) hors transfert"))
            return
        }
        let key = "\(datagram.from):\(datagram.fromPort)"
        lock.lock()
        // Requête répétée par l'appareil (notre première réponse est en route) : ignorée.
        if active[key] != nil { lock.unlock(); return }
        let full = active.count >= configuration.maxTransfers
        var transfer = Transfer(peer: datagram.from, peerPort: datagram.fromPort, local: datagram.destination,
                                kind: request.kind, filename: request.filename, mode: request.mode, options: request.options)
        if !full { active[key] = transfer.id }
        lock.unlock()
        guard !full else {
            TFTPSocket.send(fd, TFTPPacket.error(code: .notDefined, message: "Serveur occupe").encoded(), to: datagram.from, port: datagram.fromPort)
            events(.refused(transfer, .local(.notDefined, "Trop de transferts simultanés (\(configuration.maxTransfers) au plus).")))
            return
        }
        let thread = Thread { [self] in
            serve(request, transfer: &transfer, listener: fd)
            lock.lock()
            active[key] = nil
            lock.unlock()
        }
        thread.name = "TFTP \(key)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Mène un transfert, du choix du fichier à la fin.
    private func serve(_ request: TFTPRequest, transfer: inout Transfer, listener fd: Int32) {
        let access = TFTPFileAccess(root: configuration.root, allowWrite: configuration.allowWrite,
                                    allowOverwrite: configuration.allowOverwrite, maxWriteSize: configuration.policy.maxWriteSize)
        // Socket du transfert : nouvelle source (TID), depuis l'adresse qui a reçu la requête.
        let socketPair: (fd: Int32, port: UInt16)
        do {
            socketPair = try TFTPSocket.bind(address: transfer.local ?? configuration.listenAddress, port: 0)
        } catch {
            let failure = TFTPFailure.local(.notDefined, (error as? LocalizedError)?.errorDescription ?? "socket indisponible")
            events(.refused(transfer, failure))
            return
        }
        let socket = socketPair.fd
        defer { close(socket) }
        let peer = transfer.peer
        let peerPort = transfer.peerPort
        _ = ToolSocket.connect(socket, to: ToolSocket.address(peer, port: peerPort))
        let send: ([UInt8], TFTPPacket) -> Void = { bytes, _ in _ = Darwin.send(socket, bytes, bytes.count, 0) }
        func refuse(_ error: Error) {
            let failure: TFTPFailure
            if let fileError = error as? TFTPFileError { failure = fileError.failure } else {
                failure = .local(.notDefined, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            if let packet = failure.packetToPeer { send(packet.encoded(), packet) }
            events(.refused(transfer, failure))
        }
        let started = Date()
        let id = transfer.id
        let link = TFTPDriver.Link(
            send: send,
            receive: { timeout in TFTPSocket.receive(socket, timeout: timeout) },
            cancelled: { [weak self] in !(self?.shouldRun ?? false) },
            progress: { [events] bytes in events(.progress(id: id, bytes: bytes)) })
        switch request.kind {
        case .read:
            let source: TFTPFileSource
            do {
                source = try access.openForReading(request.filename, mode: request.mode)
            } catch {
                refuse(error)
                return
            }
            defer { source.close() }
            let (settings, oack) = TFTPNegotiation.server(request, policy: configuration.policy, fileSize: source.size)
            transfer.settings = settings
            transfer.size = source.size
            events(.started(transfer))
            var sender = TFTPSender(settings: settings, oack: oack, read: { try source.read($0) })
            let failure = TFTPDriver.run(&sender, link: link)
            report(id: id, failure: failure, bytes: sender.bytesAcknowledged, started: started, retransmissions: sender.retransmissions)
        case .write:
            let announced = request.option("tsize").flatMap { Int64($0) }
            let sink: TFTPFileSink
            do {
                sink = try access.openForWriting(request.filename, mode: request.mode, announcedSize: announced)
            } catch {
                refuse(error)
                return
            }
            let (settings, oack) = TFTPNegotiation.server(request, policy: configuration.policy, fileSize: nil)
            transfer.settings = settings
            transfer.size = settings.transferSize
            events(.started(transfer))
            var receiver = TFTPReceiver(settings: settings, initial: oack.isEmpty ? .ack(block: 0) : .oack(oack),
                                        write: { try sink.write($0) })
            var failure = TFTPDriver.run(&receiver, link: link)
            if failure == nil {
                do { try sink.commit() } catch {
                    failure = (error as? TFTPFileError)?.failure ?? .local(.accessViolation, error.localizedDescription)
                }
            } else {
                sink.discard()
            }
            report(id: id, failure: failure, bytes: receiver.bytesReceived, started: started, retransmissions: 0)
            // ACK final perdu : l'appareil renverra son dernier bloc, on le réacquitte un moment.
            if failure == nil { TFTPDriver.dally(&receiver, link: link) }
        }
    }

    private func report(id: UUID, failure: TFTPFailure?, bytes: Int64, started: Date, retransmissions: Int) {
        let seconds = Date().timeIntervalSince(started)
        if let failure {
            events(.failed(id: id, failure: failure, bytes: bytes, seconds: seconds))
        } else {
            events(.finished(id: id, bytes: bytes, seconds: seconds, retransmissions: retransmissions))
        }
    }
}
