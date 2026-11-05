import Foundation

// Note 78 : envoi et réception de fichiers par la console série, en XMODEM (somme de contrôle ou
// CRC-16, blocs de 128 octets ou de 1 Kio) et YMODEM (lot : nom et taille dans le bloc 0), pour
// les mises à jour de firmware par la console (ROMMON Cisco, chargeurs d'amorçage). Les deux
// automates (`XModemSender`, `XModemReceiver`) sont purs : ils reçoivent des octets et l'heure,
// et rendent les octets à envoyer ; l'onglet de terminal les relie au port série. Les tests les
// relient l'un à l'autre par un tuyau simulé, avec erreurs et pertes.

/// Protocole choisi.
public enum SerialFileProtocol: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Blocs de 128 octets ; à l'envoi, somme ou CRC selon ce que demande le récepteur ; à la
    /// réception, somme de contrôle (NAK).
    case xmodem
    /// Blocs de 128 octets, CRC-16 (le récepteur envoie « C »).
    case xmodemCRC
    /// Blocs de 1 Kio, CRC-16.
    case xmodem1K
    /// Lot de fichiers : nom et taille dans le bloc 0, blocs de 1 Kio, CRC-16.
    case ymodem

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .xmodem: return "XMODEM (somme de contrôle)"
        case .xmodemCRC: return "XMODEM-CRC"
        case .xmodem1K: return "XMODEM-1K"
        case .ymodem: return "YMODEM (lot)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .xmodem: return "XMODEM"
        case .xmodemCRC: return "XMODEM-CRC"
        case .xmodem1K: return "XMODEM-1K"
        case .ymodem: return "YMODEM"
        }
    }

    /// Le récepteur demande le CRC (« C ») plutôt que la somme (NAK).
    public var requestsCRC: Bool { self != .xmodem }
    /// Blocs de 1 Kio à l'envoi (si le récepteur accepte le CRC).
    public var usesLargeBlocks: Bool { self == .xmodem1K || self == .ymodem }
    public var isBatch: Bool { self == .ymodem }
}

/// Octets de contrôle.
public enum XModemByte {
    public static let soh: UInt8 = 0x01
    public static let stx: UInt8 = 0x02
    public static let eot: UInt8 = 0x04
    public static let ack: UInt8 = 0x06
    public static let nak: UInt8 = 0x15
    public static let can: UInt8 = 0x18
    public static let crcRequest: UInt8 = 0x43 // « C »
    /// Bourrage CP/M de fin de fichier.
    public static let sub: UInt8 = 0x1A
    public static let backspace: UInt8 = 0x08
}

/// État d'un transfert.
public enum SerialTransferState: Equatable, Sendable {
    /// En attente de l'autre bout (récepteur prêt, émetteur qui commence).
    case waiting
    case transferring
    case finished
    case failed(String)
    /// Annulé ; `byPeer` : par l'appareil (CAN CAN), sinon par l'utilisateur.
    case cancelled(byPeer: Bool)

    public var isOver: Bool {
        switch self {
        case .waiting, .transferring: return false
        default: return true
        }
    }

    public var label: String {
        switch self {
        case .waiting: return "En attente de l’appareil"
        case .transferring: return "Transfert en cours"
        case .finished: return "Transfert terminé"
        case .failed(let reason): return "Échec\u{00A0}: \(reason)"
        case .cancelled(let byPeer): return byPeer ? "Annulé par l’appareil" : "Annulé"
        }
    }
}

/// Avancement affiché.
public struct SerialTransferProgress: Equatable, Sendable {
    public var fileName: String?
    /// Numéro du fichier en cours (YMODEM), à partir de 1.
    public var fileIndex: Int
    public var fileCount: Int?
    /// Octets du fichier en cours déjà acquittés (envoi) ou reçus (réception).
    public var bytes: Int64
    /// Taille du fichier en cours, si elle est connue.
    public var total: Int64?
    /// Blocs acquittés ou reçus, tous fichiers confondus.
    public var blocks: Int
    /// Blocs renvoyés ou redemandés (NAK, délai dépassé), tous fichiers confondus.
    public var retries: Int
    public var useCRC: Bool?
    public var blockSize: Int

    public init(fileName: String? = nil, fileIndex: Int = 1, fileCount: Int? = nil, bytes: Int64 = 0, total: Int64? = nil,
                blocks: Int = 0, retries: Int = 0, useCRC: Bool? = nil, blockSize: Int = 128) {
        self.fileName = fileName
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.bytes = bytes
        self.total = total
        self.blocks = blocks
        self.retries = retries
        self.useCRC = useCRC
        self.blockSize = blockSize
    }

    /// 0…1, si la taille est connue.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }

    /// « CRC-16 · blocs de 1 Kio ».
    public var checkLabel: String {
        let check = useCRC.map { $0 ? "CRC-16" : "somme de contrôle" } ?? "contrôle à négocier"
        return "\(check) · blocs de \(blockSize == 1_024 ? "1\u{00A0}Kio" : "128\u{00A0}octets")"
    }
}

/// Un fichier à envoyer ou reçu.
public struct SerialFile: Equatable, Sendable {
    public var name: String
    public var data: [UInt8]
    public var modified: Date?

    public init(name: String, data: [UInt8], modified: Date? = nil) {
        self.name = name
        self.data = data
        self.modified = modified
    }
}

/// Réglages des délais (secondes) et des reprises.
public struct SerialTransferTimings: Equatable, Sendable {
    /// Attente du premier « C »/NAK (envoi) ou du premier bloc (réception).
    public var startTimeout: Double
    /// Attente d'un ACK après un bloc, ou d'un bloc après un ACK.
    public var blockTimeout: Double
    /// Intervalle entre deux « C »/NAK de démarrage (réception).
    public var startInterval: Double
    /// Silence au milieu d'un bloc avant de le déclarer perdu.
    public var interByteTimeout: Double
    /// Reprises consécutives d'un même bloc avant l'abandon.
    public var maxRetries: Int
    /// « C » sans réponse avant de se replier sur la somme de contrôle (XMODEM-CRC à la réception).
    public var crcAttempts: Int

    public init(startTimeout: Double = 60, blockTimeout: Double = 10, startInterval: Double = 3, interByteTimeout: Double = 1,
                maxRetries: Int = 10, crcAttempts: Int = 4) {
        self.startTimeout = startTimeout
        self.blockTimeout = blockTimeout
        self.startInterval = startInterval
        self.interByteTimeout = interByteTimeout
        self.maxRetries = maxRetries
        self.crcAttempts = crcAttempts
    }
}

/// Calculs et blocs du protocole.
public enum XModem {
    /// Taille maximale d'un fichier reçu (64 Mio) : au-delà, la réception s'arrête.
    public static let maxReceiveSize = 64 << 20

    /// CRC-16 de XMODEM (polynôme 0x1021, départ à 0).
    public static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 { crc16(bytes[...]) }

    /// Somme des octets, sur 8 bits.
    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    /// Bloc complet : en-tête, numéro, complément, données bourrées, contrôle.
    public static func block(number: UInt8, payload: ArraySlice<UInt8>, size: Int, crc: Bool, padding: UInt8 = XModemByte.sub) -> [UInt8] {
        var data = Array(payload.prefix(size))
        if data.count < size { data += [UInt8](repeating: padding, count: size - data.count) }
        var packet: [UInt8] = [size == 1_024 ? XModemByte.stx : XModemByte.soh, number, 0xFF &- number]
        packet += data
        if crc {
            let value = crc16(data[...])
            packet += [UInt8(value >> 8), UInt8(value & 0xFF)]
        } else {
            packet.append(checksum(data[...]))
        }
        return packet
    }

    /// Bloc 0 de YMODEM : « nom NUL taille date-octale », bourré de NUL ; nom vide : fin du lot.
    public static func ymodemHeader(_ file: SerialFile?, crc: Bool = true) -> [UInt8] {
        guard let file else { return block(number: 0, payload: [], size: 128, crc: crc, padding: 0) }
        var name = Array(file.name.utf8.filter { $0 != 0 && $0 != 0x2F })
        if name.isEmpty { name = Array("fichier.bin".utf8) }
        var info = "\(file.data.count)"
        if let modified = file.modified { info += " " + String(Int(max(0, modified.timeIntervalSince1970)), radix: 8) }
        let payload = name + [0] + Array(info.utf8) + [0]
        let size = payload.count > 128 ? 1_024 : 128
        return block(number: 0, payload: payload[...], size: size, crc: crc, padding: 0)
    }

    /// Lecture du bloc 0 : nom (vide : fin du lot), taille et date si présentes.
    public static func parseHeader(_ data: [UInt8]) -> (name: String, size: Int?, modified: Date?) {
        guard let end = data.firstIndex(of: 0) else { return (String(decoding: data, as: UTF8.self), nil, nil) }
        let name = String(decoding: data[..<end], as: UTF8.self)
        let rest = data[(end + 1)...]
        let infoEnd = rest.firstIndex(of: 0) ?? rest.endIndex
        let fields = String(decoding: rest[..<infoEnd], as: UTF8.self).split(separator: " ")
        let size = fields.first.flatMap { Int($0) }
        let modified = fields.count > 1 ? Int(fields[1], radix: 8).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        return (name, size, modified)
    }

    /// Nom sûr pour un fichier reçu : dernier élément, sans « .. », point de tête ni caractère de contrôle.
    public static func safeName(_ name: String, fallback: String = "fichier-recu.bin") -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\\" && $0 != ":" }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        // Pas de fichier caché (« .zshrc ») : l'appareil distant choisit le nom en YMODEM.
        let visible = String(cleaned.drop(while: { $0 == "." })).trimmingCharacters(in: .whitespaces)
        if visible.isEmpty { return fallback }
        return String(visible.prefix(200))
    }

    /// Séquence d'annulation : huit CAN, puis huit retours arrière (effacent les CAN à l'écran).
    public static let cancelSequence = [UInt8](repeating: XModemByte.can, count: 8) + [UInt8](repeating: XModemByte.backspace, count: 8)
}

/// Automate commun : état, avancement, fichiers reçus.
public protocol SerialTransferMachine: AnyObject {
    var state: SerialTransferState { get }
    var progress: SerialTransferProgress { get }
    /// Octets à envoyer au démarrage.
    func start(now: Double) -> [UInt8]
    /// Octets reçus du port ; renvoie les octets à envoyer.
    func receive(_ bytes: [UInt8], now: Double) -> [UInt8]
    /// Appelé régulièrement (délais) ; renvoie les octets à envoyer.
    func tick(now: Double) -> [UInt8]
    /// Annulation par l'utilisateur ; renvoie la séquence d'annulation.
    func cancel() -> [UInt8]
}

// MARK: - Envoi

/// Émetteur XMODEM (somme, CRC, 1 Kio) et YMODEM (lot).
public final class XModemSender: SerialTransferMachine {
    private enum Phase {
        /// Attente du « C » ou du NAK qui lance un fichier (YMODEM : avant le bloc 0 et avant le bloc 1).
        case waitStart(header: Bool)
        case waitAck
        case waitEOTAck
        /// YMODEM : bloc 0 vide envoyé, attente de son ACK.
        case waitBatchEndAck
        case done
    }

    public let proto: SerialFileProtocol
    public let files: [SerialFile]
    public let timings: SerialTransferTimings
    public private(set) var state: SerialTransferState = .waiting
    public private(set) var progress: SerialTransferProgress

    private var phase: Phase
    private var fileIndex = 0
    private var offset = 0
    private var blockNumber: UInt8 = 1
    private var lastPacket: [UInt8] = []
    private var lastPacketSize = 0
    private var deadline: Double = 0
    private var retries = 0
    private var crc = false
    private var cancelSeen = 0
    private var started = false

    public init(proto: SerialFileProtocol, files: [SerialFile], timings: SerialTransferTimings = SerialTransferTimings()) {
        self.proto = proto
        self.files = proto.isBatch ? files : Array(files.prefix(1))
        self.timings = timings
        phase = .waitStart(header: proto.isBatch)
        progress = SerialTransferProgress(fileName: files.first?.name, fileIndex: 1, fileCount: proto.isBatch ? files.count : 1,
                                          total: files.first.map { Int64($0.data.count) },
                                          blockSize: proto.usesLargeBlocks ? 1_024 : 128)
    }

    private var file: SerialFile? { fileIndex < files.count ? files[fileIndex] : nil }

    public func start(now: Double) -> [UInt8] {
        guard !started else { return [] }
        started = true
        if files.isEmpty {
            state = .failed("aucun fichier à envoyer")
            return []
        }
        deadline = now + timings.startTimeout
        return []
    }

    public func receive(_ bytes: [UInt8], now: Double) -> [UInt8] {
        var out: [UInt8] = []
        for byte in bytes {
            guard !state.isOver else { break }
            if byte == XModemByte.can {
                cancelSeen += 1
                if cancelSeen >= 2 {
                    state = .cancelled(byPeer: true)
                    phase = .done
                }
                continue
            }
            cancelSeen = 0
            out += handle(byte, now: now)
        }
        return out
    }

    private func handle(_ byte: UInt8, now: Double) -> [UInt8] {
        switch phase {
        case .waitStart(let header):
            guard byte == XModemByte.crcRequest || byte == XModemByte.nak else { return [] }
            // Le récepteur choisit : « C » pour le CRC, NAK pour la somme de contrôle.
            crc = byte == XModemByte.crcRequest
            progress.useCRC = crc
            state = .transferring
            if header {
                return sendHeader(now: now)
            }
            return sendNextBlock(now: now)
        case .waitAck:
            if byte == XModemByte.ack {
                retries = 0
                progress.blocks += 1
                if blockNumber == 0 && proto.isBatch && lastPacketSize == 0 {
                    // ACK du bloc 0 (en-tête) : on attend maintenant le « C » du bloc 1.
                    blockNumber = 1
                    phase = .waitStart(header: false)
                    deadline = now + timings.startTimeout
                    return []
                }
                offset += lastPacketSize
                progress.bytes = Int64(offset)
                blockNumber &+= 1
                return sendNextBlock(now: now)
            }
            // Un « C » reçu ici est un « C » de démarrage en retard (déjà en route ou en mémoire
            // tampon) : le renvoi ne se fait que sur NAK ou à l'échéance, comme lrzsz. Renvoyer le
            // bloc 1 sur un « C » le ferait acquitter deux fois et décalerait tous les ACK suivants.
            if byte == XModemByte.nak {
                return resend(now: now)
            }
            return []
        case .waitEOTAck:
            if byte == XModemByte.ack {
                retries = 0
                return fileDone(now: now)
            }
            if byte == XModemByte.nak {
                // Beaucoup de récepteurs refusent le premier EOT pour s'assurer qu'il est réel.
                return eot(now: now, retry: true)
            }
            return []
        case .waitBatchEndAck:
            if byte == XModemByte.ack {
                state = .finished
                phase = .done
            } else if byte == XModemByte.nak || byte == XModemByte.crcRequest {
                return resend(now: now)
            }
            return []
        case .done:
            return []
        }
    }

    private func sendHeader(now: Double) -> [UInt8] {
        let packet = XModem.ymodemHeader(file, crc: crc)
        blockNumber = 0
        lastPacket = packet
        lastPacketSize = 0
        if file == nil {
            phase = .waitBatchEndAck
        } else {
            phase = .waitAck
        }
        deadline = now + timings.blockTimeout
        return packet
    }

    private func sendNextBlock(now: Double) -> [UInt8] {
        guard let file else { return [] }
        let remaining = file.data.count - offset
        if remaining <= 0 { return eot(now: now, retry: false) }
        // 1 Kio si le récepteur accepte le CRC ; 128 octets pour un petit reste (moins de bourrage).
        let size = proto.usesLargeBlocks && crc && remaining > 128 ? 1_024 : 128
        progress.blockSize = size
        let end = min(file.data.count, offset + size)
        let packet = XModem.block(number: blockNumber, payload: file.data[offset..<end], size: size, crc: crc)
        lastPacket = packet
        lastPacketSize = end - offset
        phase = .waitAck
        deadline = now + timings.blockTimeout
        return packet
    }

    private func eot(now: Double, retry: Bool) -> [UInt8] {
        if retry {
            retries += 1
            progress.retries += 1
            if retries > timings.maxRetries { return fail("fin de fichier (EOT) jamais acquittée") }
        }
        phase = .waitEOTAck
        lastPacket = [XModemByte.eot]
        deadline = now + timings.blockTimeout
        return [XModemByte.eot]
    }

    private func fileDone(now: Double) -> [UInt8] {
        guard proto.isBatch else {
            state = .finished
            phase = .done
            return []
        }
        fileIndex += 1
        offset = 0
        blockNumber = 0
        progress.fileIndex = min(fileIndex + 1, files.count)
        if let next = file {
            progress.fileName = next.name
            progress.total = Int64(next.data.count)
            progress.bytes = 0
        }
        // Fichier suivant, ou bloc 0 vide (fin du lot), après le prochain « C ».
        phase = .waitStart(header: true)
        deadline = now + timings.startTimeout
        return []
    }

    private func resend(now: Double) -> [UInt8] {
        retries += 1
        progress.retries += 1
        if retries > timings.maxRetries { return fail("trop d’erreurs sur le bloc \(blockNumber)") }
        deadline = now + timings.blockTimeout
        return lastPacket
    }

    private func fail(_ reason: String) -> [UInt8] {
        state = .failed(reason)
        phase = .done
        return XModem.cancelSequence
    }

    public func tick(now: Double) -> [UInt8] {
        guard started, !state.isOver, now >= deadline else { return [] }
        switch phase {
        case .waitStart:
            return fail(progress.blocks == 0 ? "l’appareil n’a pas demandé le fichier (ni « C » ni NAK)" : "l’appareil ne demande pas la suite")
        case .waitAck, .waitBatchEndAck:
            return resend(now: now)
        case .waitEOTAck:
            return eot(now: now, retry: true)
        case .done:
            return []
        }
    }

    public func cancel() -> [UInt8] {
        guard !state.isOver else { return [] }
        state = .cancelled(byPeer: false)
        phase = .done
        return XModem.cancelSequence
    }
}

// MARK: - Réception

/// Récepteur XMODEM (somme ou CRC, blocs de 128 octets ou 1 Kio) et YMODEM (lot).
public final class XModemReceiver: SerialTransferMachine {
    private enum Phase {
        /// « C »/NAK envoyés, attente du premier bloc (YMODEM : le bloc 0 d'un fichier).
        case waitFirst(header: Bool)
        case receiving
        case done
    }

    public let proto: SerialFileProtocol
    public let timings: SerialTransferTimings
    /// Nom donné au fichier XMODEM (le protocole ne transmet pas de nom).
    public let defaultName: String
    public private(set) var state: SerialTransferState = .waiting
    public private(set) var progress: SerialTransferProgress
    /// Fichiers complets reçus.
    public private(set) var receivedFiles: [SerialFile] = []

    private var phase: Phase
    private var buffer: [UInt8] = []
    private var crc: Bool
    private var startAttempts = 0
    private var expected: UInt8 = 1
    private var current: [UInt8] = []
    private var currentName: String?
    private var currentSize: Int?
    private var currentDate: Date?
    private var nextPoke: Double = 0
    private var giveUpAt: Double = 0
    private var lastByteAt: Double = 0
    private var retries = 0
    private var cancelSeen = 0
    private var started = false

    public init(proto: SerialFileProtocol, defaultName: String = "fichier-recu.bin", timings: SerialTransferTimings = SerialTransferTimings()) {
        self.proto = proto
        self.timings = timings
        self.defaultName = defaultName
        crc = proto.requestsCRC
        phase = .waitFirst(header: proto.isBatch)
        progress = SerialTransferProgress(fileName: proto.isBatch ? nil : defaultName, useCRC: proto.requestsCRC,
                                          blockSize: proto.usesLargeBlocks ? 1_024 : 128)
    }

    private var poke: UInt8 { crc ? XModemByte.crcRequest : XModemByte.nak }

    public func start(now: Double) -> [UInt8] {
        guard !started else { return [] }
        started = true
        startAttempts = 1
        nextPoke = now + timings.startInterval
        giveUpAt = now + timings.startTimeout
        return [poke]
    }

    public func receive(_ bytes: [UInt8], now: Double) -> [UInt8] {
        guard started, !state.isOver else { return [] }
        if !bytes.isEmpty { lastByteAt = now }
        buffer += bytes
        var out: [UInt8] = []
        while !buffer.isEmpty, !state.isOver {
            let first = buffer[0]
            if first == XModemByte.can {
                cancelSeen += 1
                buffer.removeFirst()
                if cancelSeen >= 2 {
                    state = .cancelled(byPeer: true)
                    phase = .done
                }
                continue
            }
            cancelSeen = 0
            if first == XModemByte.eot {
                buffer.removeFirst()
                out += endOfFile(now: now)
                continue
            }
            guard first == XModemByte.soh || first == XModemByte.stx else {
                // Écho, texte de l'appareil ou bruit entre deux blocs : ignoré.
                buffer.removeFirst()
                continue
            }
            let size = first == XModemByte.stx ? 1_024 : 128
            let length = 3 + size + (crc ? 2 : 1)
            guard buffer.count >= length else { break }
            let packet = Array(buffer.prefix(length))
            buffer.removeFirst(length)
            out += handle(packet, size: size, now: now)
        }
        return out
    }

    private func handle(_ packet: [UInt8], size: Int, now: Double) -> [UInt8] {
        let number = packet[1]
        let data = packet[3..<(3 + size)]
        let valid: Bool
        if crc {
            let value = UInt16(packet[3 + size]) << 8 | UInt16(packet[4 + size])
            valid = XModem.crc16(data) == value
        } else {
            valid = XModem.checksum(data) == packet[3 + size]
        }
        guard number == 0xFF &- packet[2], valid else { return reject(now: now, reason: "bloc abîmé") }
        state = .transferring
        progress.useCRC = crc
        progress.blockSize = size
        switch phase {
        case .waitFirst(let header) where header:
            if number == 0 { return acceptHeader(Array(data), now: now) }
            // Dernier bloc de données du fichier précédent répété (ACK perdu) : acquitté.
            if number == expected &- 1 { return [XModemByte.ack] }
            return reject(now: now, reason: "bloc \(number) au lieu de l’en-tête")
        case .waitFirst, .receiving:
            if number == expected {
                retries = 0
                current += data
                if current.count > XModem.maxReceiveSize {
                    state = .failed("fichier de plus de \(XModem.maxReceiveSize >> 20)\u{00A0}Mio")
                    phase = .done
                    return XModem.cancelSequence
                }
                expected &+= 1
                phase = .receiving
                progress.blocks += 1
                progress.bytes = Int64(min(current.count, currentSize ?? current.count))
                giveUpAt = now + timings.blockTimeout
                return [XModemByte.ack]
            }
            if number == expected &- 1 {
                // Bloc déjà reçu (notre ACK s'est perdu) : acquitté sans le garder.
                return [XModemByte.ack]
            }
            state = .failed("désynchronisé (bloc \(number), attendu \(expected))")
            phase = .done
            return XModem.cancelSequence
        case .done:
            return []
        }
    }

    private func acceptHeader(_ data: [UInt8], now: Double) -> [UInt8] {
        let header = XModem.parseHeader(data)
        if header.name.isEmpty {
            // Bloc 0 vide : fin du lot.
            state = .finished
            phase = .done
            return [XModemByte.ack]
        }
        currentName = XModem.safeName(header.name, fallback: defaultName)
        currentSize = header.size
        currentDate = header.modified
        current = []
        expected = 1
        retries = 0
        progress.fileName = currentName
        progress.fileIndex = receivedFiles.count + 1
        progress.total = header.size.map(Int64.init)
        progress.bytes = 0
        progress.blocks += 1
        phase = .waitFirst(header: false)
        giveUpAt = now + timings.blockTimeout
        nextPoke = now + timings.startInterval
        // ACK de l'en-tête, puis « C » pour lancer les données.
        return [XModemByte.ack, poke]
    }

    private func endOfFile(now: Double) -> [UInt8] {
        switch phase {
        case .receiving:
            var data = current
            if let size = currentSize, size <= data.count {
                data = Array(data.prefix(size))
            } else if !proto.isBatch {
                // XMODEM ne transmet pas la taille : le bourrage CP/M (0x1A) de la fin est retiré.
                while data.last == XModemByte.sub { data.removeLast() }
            }
            receivedFiles.append(SerialFile(name: currentName ?? defaultName, data: data, modified: currentDate))
            current = []
            progress.bytes = Int64(data.count)
            if proto.isBatch {
                expected = 1
                currentSize = nil
                phase = .waitFirst(header: true)
                giveUpAt = now + timings.blockTimeout
                nextPoke = now + timings.startInterval
                return [XModemByte.ack, poke]
            }
            state = .finished
            phase = .done
            return [XModemByte.ack]
        case .waitFirst(let header) where header && !receivedFiles.isEmpty:
            // EOT répété (notre ACK s'est perdu) : acquitté de nouveau.
            return [XModemByte.ack, poke]
        default:
            return [XModemByte.nak]
        }
    }

    private func reject(now: Double, reason: String) -> [UInt8] {
        retries += 1
        progress.retries += 1
        // Le reste de ce qui est arrivé appartient au bloc abîmé : jeté, l'émetteur renvoie tout.
        buffer.removeAll()
        if retries > timings.maxRetries {
            state = .failed("trop d’erreurs (\(reason))")
            phase = .done
            return XModem.cancelSequence
        }
        giveUpAt = now + timings.blockTimeout
        return [XModemByte.nak]
    }

    public func tick(now: Double) -> [UInt8] {
        guard started, !state.isOver else { return [] }
        // Bloc commencé puis silence : perdu, on le redemande.
        if !buffer.isEmpty, now - lastByteAt >= timings.interByteTimeout {
            return reject(now: now, reason: "bloc incomplet")
        }
        switch phase {
        case .waitFirst(let header):
            let waitingStart = progress.blocks == 0 || header || current.isEmpty
            guard waitingStart, buffer.isEmpty else { break }
            if now >= giveUpAt {
                state = .failed(progress.blocks == 0 ? "aucun bloc reçu (l’envoi est-il lancé sur l’appareil\u{00A0}?)" : "l’appareil n’envoie plus rien")
                phase = .done
                return XModem.cancelSequence
            }
            if now >= nextPoke {
                startAttempts += 1
                nextPoke = now + timings.startInterval
                // XMODEM-CRC sans réponse : repli sur la somme de contrôle (vieux émetteurs).
                if crc, !proto.usesLargeBlocks, progress.blocks == 0, startAttempts > timings.crcAttempts {
                    crc = false
                    progress.useCRC = false
                }
                return [poke]
            }
        case .receiving:
            if now >= giveUpAt {
                return reject(now: now, reason: "délai dépassé")
            }
        case .done:
            break
        }
        return []
    }

    public func cancel() -> [UInt8] {
        guard !state.isOver else { return [] }
        state = .cancelled(byPeer: false)
        phase = .done
        return XModem.cancelSequence
    }
}
