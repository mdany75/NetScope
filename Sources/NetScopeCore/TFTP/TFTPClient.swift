import Darwin
import Foundation

/// Client TFTP (note 51) : récupère (get) ou envoie (put) un fichier vers un appareil — switch,
/// borne, téléphone IP. Options blksize, tsize, timeout et windowsize demandées ; sans réponse
/// valide aux options, retour en RFC 1350 pure.
public enum TFTPClient {
    public struct Options: Equatable, Sendable {
        public var blockSize: Int
        public var windowSize: Int
        /// Délai avant retransmission (secondes, 1 à 255).
        public var timeout: Int
        public var retries: Int
        public var mode: TFTPMode
        /// Demande des options (RFC 2347) ; non : RFC 1350 pure (vieux appareils).
        public var useOptions: Bool

        public init(blockSize: Int = TFTPLimits.ethernetBlockSize, windowSize: Int = 1, timeout: Int = 3,
                    retries: Int = TFTPLimits.defaultRetries, mode: TFTPMode = .octet, useOptions: Bool = true) {
            self.blockSize = blockSize
            self.windowSize = windowSize
            self.timeout = timeout
            self.retries = retries
            self.mode = mode
            self.useOptions = useOptions
        }
    }

    public enum Direction: String, Sendable, Codable {
        /// Récupérer un fichier de l'appareil (RRQ).
        case get
        /// Envoyer un fichier à l'appareil (WRQ).
        case put
    }

    public struct Result: Equatable, Sendable {
        public var bytes: Int64
        public var seconds: TimeInterval
        public var settings: TFTPTransferSettings
        /// Vrai si l'appareil a refusé les options (transfert en RFC 1350 pure).
        public var withoutOptions: Bool
        public var retransmissions: Int

        public init(bytes: Int64, seconds: TimeInterval, settings: TFTPTransferSettings, withoutOptions: Bool = false, retransmissions: Int = 0) {
            self.bytes = bytes
            self.seconds = seconds
            self.settings = settings
            self.withoutOptions = withoutOptions
            self.retransmissions = retransmissions
        }
    }

    /// Transfert complet, sur un fil d'exécution à part. `local` est le fichier envoyé (put) ou le
    /// fichier enregistré (get, écrit à côté puis mis en place à la fin). `progress` reçoit les
    /// octets transférés et la taille annoncée (tsize). `cancelled` est consulté toutes les 200 ms.
    public static func transfer(_ direction: Direction, host: IPv4Address, port: UInt16 = 69, remote: String, local: URL,
                                options: Options = Options(),
                                progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in },
                                cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    let result = try run(direction, host: host, port: port, remote: remote, local: local, options: options,
                                         progress: progress, cancelled: cancelled)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "TFTP client"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    static func run(_ direction: Direction, host: IPv4Address, port: UInt16, remote: String, local: URL, options: Options,
                    progress: @escaping (Int64, Int64?) -> Void, cancelled: @escaping () -> Bool) throws -> Result {
        let remoteName = remote.trimmingCharacters(in: .whitespaces)
        guard !remoteName.isEmpty else { throw ToolError.invalidInput("Indiquez le nom du fichier sur l’appareil.") }
        guard port != 0 else { throw ToolError.invalidInput("Port invalide.") }
        let settings = TFTPTransferSettings(blockSize: options.blockSize, windowSize: options.windowSize,
                                            timeout: TimeInterval(options.timeout), retries: options.retries, mode: options.mode)
        var source: TFTPFileSource?
        var sink: TFTPFileSink?
        var machine: TFTPClientMachine
        switch direction {
        case .put:
            do {
                source = try TFTPFileSource(url: local, mode: options.mode)
            } catch {
                throw ToolError.invalidInput("Fichier à envoyer illisible\u{00A0}: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            let requested = options.useOptions
                ? TFTPNegotiation.clientOptions(blockSize: options.blockSize, windowSize: options.windowSize,
                                                timeout: options.timeout, transferSize: source?.size)
                : []
            let file = source!
            machine = TFTPClientMachine(put: remoteName, options: requested, settings: settings, read: { try file.read($0) })
        case .get:
            do {
                sink = try TFTPFileSink(destination: local, mode: options.mode, overwrite: true)
            } catch {
                throw ToolError.invalidInput("Enregistrement impossible\u{00A0}: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            let requested = options.useOptions
                ? TFTPNegotiation.clientOptions(blockSize: options.blockSize, windowSize: options.windowSize,
                                                timeout: options.timeout, transferSize: 0)
                : []
            let file = sink!
            machine = TFTPClientMachine(get: remoteName, options: requested, settings: settings, write: { try file.write($0) })
        }
        defer { source?.close() }
        let fd: Int32
        do {
            (fd, _) = try TFTPSocket.bind(address: nil, port: 0)
        } catch {
            // Le fichier partiel déjà créé ne doit pas rester dans le dossier de l'utilisateur.
            sink?.discard()
            throw error
        }
        defer { close(fd) }
        let started = Date()
        // TID de l'appareil : port source de sa première réponse, verrouillé dès le transfert lancé.
        var peerPort: UInt16?
        var locked = false
        let total: () -> Int64? = { [source] in source?.size }
        var announced: Int64?
        let link = TFTPDriver.Link(
            send: { bytes, packet in
                if case .request = packet {
                    TFTPSocket.send(fd, bytes, to: host, port: port)
                } else {
                    TFTPSocket.send(fd, bytes, to: host, port: peerPort ?? port)
                }
            },
            receive: { timeout in
                let end = Date().addingTimeInterval(timeout)
                while true {
                    let wait = TFTPSocket.receive(fd, timeout: max(0, end.timeIntervalSinceNow))
                    guard case .datagram(let datagram) = wait else { return wait }
                    // Paquet d'une autre machine : ignoré.
                    guard datagram.from == host else { continue }
                    if locked, let peerPort, datagram.fromPort != peerPort {
                        // Autre port de l'appareil pendant le transfert : ERROR 5, sans interrompre.
                        TFTPSocket.send(fd, TFTPPacket.error(code: .unknownTransferID, message: TFTPWire.message(.unknownTransferID)).encoded(),
                                        to: datagram.from, port: datagram.fromPort)
                        continue
                    }
                    peerPort = datagram.fromPort
                    if let packet = try? TFTPPacket.decode(datagram.bytes) {
                        switch packet {
                        case .oack(let options):
                            locked = true
                            // Taille annoncée par l'appareil (tsize) : progression d'un get.
                            if let value = options.first(where: { $0.name == "tsize" }).flatMap({ Int64($0.value) }), value > 0 {
                                announced = value
                            }
                        case .data, .ack: locked = true
                        default: break
                        }
                    }
                    return wait
                }
            },
            cancelled: cancelled,
            progress: { bytes in progress(bytes, total() ?? announced) })
        var failure = TFTPDriver.run(&machine, link: link)
        if direction == .get {
            if failure == nil {
                do { try sink?.commit() } catch {
                    failure = (error as? TFTPFileError)?.failure ?? .local(.accessViolation, error.localizedDescription)
                }
            } else {
                sink?.discard()
            }
        }
        if let failure { throw failure }
        return Result(bytes: machine.bytesTransferred, seconds: Date().timeIntervalSince(started), settings: machine.settings,
                      withoutOptions: machine.fellBackWithoutOptions || !options.useOptions, retransmissions: machine.retransmissions)
    }
}
