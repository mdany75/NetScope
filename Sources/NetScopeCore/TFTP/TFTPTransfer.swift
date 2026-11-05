import Foundation

// Machines d'état d'un transfert TFTP, pures (aucun socket, aucune horloge) : on leur donne les
// paquets reçus et les délais écoulés, elles répondent par les paquets à envoyer. Le serveur et le
// client (TFTPServer, TFTPClient) ne font que les relier à un socket UDP.

/// Raison de l'échec d'un transfert, en clair.
public enum TFTPFailure: Error, Equatable, Sendable, LocalizedError {
    /// L'autre côté a répondu par un paquet ERROR.
    case remote(TFTPErrorCode, String)
    /// Plus de réponse après toutes les retransmissions.
    case timeout(retries: Int)
    /// Erreur de ce côté (fichier, disque), envoyée aussi à l'autre côté.
    case local(TFTPErrorCode, String)
    /// Paquet inattendu ou mal formé.
    case protocolError(String)
    /// Transfert annulé (arrêt du serveur, bouton Annuler).
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .remote(let code, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty || detail.lowercased() == code.label.lowercased()
                ? "\(code.label) (réponse de l’appareil)."
                : "\(code.label)\u{00A0}: «\u{00A0}\(detail)\u{00A0}» (réponse de l’appareil)."
        case .timeout(let retries):
            return "Délai dépassé\u{00A0}: aucune réponse après \(retries) retransmission\(retries > 1 ? "s" : "")."
        case .local(let code, let message):
            return message.isEmpty ? "\(code.label)." : message
        case .protocolError(let message):
            return "Échange TFTP invalide\u{00A0}: \(message)."
        case .cancelled:
            return "Transfert annulé."
        }
    }

    /// Raison courte (colonne « État » du journal).
    public var shortLabel: String {
        switch self {
        case .remote(let code, _), .local(let code, _): return code == .notDefined ? "Erreur" : code.label
        case .timeout: return "Délai dépassé"
        case .protocolError: return "Échange invalide"
        case .cancelled: return "Annulé"
        }
    }

    /// Paquet ERROR à envoyer à l'autre côté pour cet échec (aucun pour un délai dépassé ou une
    /// erreur reçue de l'autre côté).
    public var packetToPeer: TFTPPacket? {
        switch self {
        case .remote, .timeout: return nil
        case .local(let code, _): return .error(code: code, message: TFTPWire.message(code))
        case .protocolError: return .error(code: .illegalOperation, message: TFTPWire.message(.illegalOperation))
        case .cancelled: return .error(code: .notDefined, message: TFTPWire.message(.notDefined, cancelled: true))
        }
    }
}

/// Messages envoyés sur le fil dans les paquets ERROR : en ASCII (sans accents), car beaucoup
/// d'appareils les affichent tels quels sur leur console.
public enum TFTPWire {
    public static func message(_ code: TFTPErrorCode, cancelled: Bool = false) -> String {
        switch code {
        case .notDefined: return cancelled ? "Transfert annule" : "Erreur"
        case .fileNotFound: return "Fichier introuvable"
        case .accessViolation: return "Acces refuse"
        case .diskFull: return "Disque plein"
        case .illegalOperation: return "Operation TFTP illegale"
        case .unknownTransferID: return "Transfert inconnu"
        case .fileExists: return "Le fichier existe deja"
        case .noSuchUser: return "Utilisateur inconnu"
        case .optionRefused: return "Options refusees"
        }
    }
}

/// Réponse d'une machine d'état.
public enum TFTPAction: Equatable, Sendable {
    /// Envoyer ces paquets (peut être vide : rien à faire) et attendre la suite.
    case send([TFTPPacket])
    /// Envoyer ces paquets ; le transfert est terminé avec succès.
    case complete([TFTPPacket])
    /// Le transfert échoue ; envoyer `failure.packetToPeer` s'il y en a un.
    case fail(TFTPFailure)

    /// Paquets à envoyer pour cette action.
    public var packets: [TFTPPacket] {
        switch self {
        case .send(let packets), .complete(let packets): return packets
        case .fail(let failure): return failure.packetToPeer.map { [$0] } ?? []
        }
    }
}

/// Numéro de bloc sur le fil : les 16 bits de poids faible (retour à 0 après 65 535, comme
/// tftp-hpa, pour les fichiers de plus de 65 535 blocs).
@inline(__always) func wireBlock(_ block: UInt64) -> UInt16 { UInt16(truncatingIfNeeded: block) }

// MARK: - Émetteur (DATA → ACK)

/// Côté qui envoie le fichier : serveur pour une lecture (RRQ), client pour une écriture (put).
/// Fenêtre de `windowSize` blocs (RFC 7440) ; un ACK en double est ignoré (pas de « Sorcerer's
/// Apprentice ») ; un délai écoulé renvoie toute la fenêtre non acquittée.
public struct TFTPSender {
    public private(set) var settings: TFTPTransferSettings
    /// Lit au plus `count` octets ; moins que `count` signifie la fin du fichier.
    private let read: (Int) throws -> [UInt8]
    private var window: [(block: UInt64, payload: [UInt8])] = []
    private var nextBlock: UInt64 = 1
    private var reachedEnd = false
    private var attempts = 0
    /// OACK à faire acquitter (ACK 0) avant le premier bloc (serveur).
    private var pendingOACK: [TFTPOption]?
    public private(set) var bytesAcknowledged: Int64 = 0
    public private(set) var bytesSent: Int64 = 0
    public private(set) var retransmissions = 0
    public private(set) var isFinished = false

    public init(settings: TFTPTransferSettings, oack: [TFTPOption]? = nil, read: @escaping (Int) throws -> [UInt8]) {
        self.settings = settings
        self.read = read
        self.pendingOACK = (oack?.isEmpty ?? true) ? nil : oack
    }

    /// Premiers paquets : l'OACK s'il y en a un, sinon la première fenêtre de données.
    public mutating func start() -> TFTPAction {
        if let pendingOACK { return .send([.oack(pendingOACK)]) }
        return fill()
    }

    public mutating func receive(_ packet: TFTPPacket) -> TFTPAction {
        guard !isFinished else { return .send([]) }
        switch packet {
        case .ack(let block):
            if pendingOACK != nil {
                // ACK 0 : le client accepte l'OACK ; un autre numéro est ignoré.
                guard block == 0 else { return .send([]) }
                pendingOACK = nil
                attempts = 0
                return fill()
            }
            guard let index = window.firstIndex(where: { wireBlock($0.block) == block }) else {
                // ACK en double ou ancien : ignoré (le délai fera renvoyer la fenêtre au besoin).
                return .send([])
            }
            attempts = 0
            for entry in window[...index] { bytesAcknowledged += Int64(entry.payload.count) }
            window.removeFirst(index + 1)
            if window.isEmpty && reachedEnd {
                isFinished = true
                return .complete([])
            }
            // RFC 7440 : un ACK au milieu de la fenêtre fait repartir du bloc suivant.
            let resend = window.map { TFTPPacket.data(block: wireBlock($0.block), payload: $0.payload) }
            if !resend.isEmpty { retransmissions += resend.count }
            switch fill() {
            case .send(let fresh): return .send(resend + fresh)
            case .fail(let failure): return .fail(failure)
            case .complete(let packets): return .complete(resend + packets)
            }
        case .error(let code, let message):
            return .fail(.remote(code, message))
        case .oack:
            // OACK en double (le client n'a pas encore reçu l'ACK 0 ?) : ignoré.
            return .send([])
        case .data, .request:
            return .fail(.protocolError("paquet inattendu pendant l’envoi (\(packet.summary))"))
        }
    }

    /// Délai écoulé sans ACK : renvoie l'OACK ou la fenêtre, ou abandonne.
    public mutating func timeout() -> TFTPAction {
        guard !isFinished else { return .send([]) }
        attempts += 1
        guard attempts <= settings.retries else { return .fail(.timeout(retries: settings.retries)) }
        if let pendingOACK { return .send([.oack(pendingOACK)]) }
        let packets = window.map { TFTPPacket.data(block: wireBlock($0.block), payload: $0.payload) }
        retransmissions += packets.count
        return .send(packets)
    }

    /// Remplit la fenêtre de nouveaux blocs.
    private mutating func fill() -> TFTPAction {
        var fresh: [TFTPPacket] = []
        while window.count < settings.windowSize && !reachedEnd {
            let payload: [UInt8]
            do {
                payload = try read(settings.blockSize)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return .fail(.local(.accessViolation, "Lecture du fichier impossible\u{00A0}: \(message)"))
            }
            let block = nextBlock
            nextBlock += 1
            if payload.count < settings.blockSize { reachedEnd = true }
            window.append((block, payload))
            bytesSent += Int64(payload.count)
            fresh.append(.data(block: wireBlock(block), payload: payload))
        }
        return .send(fresh)
    }
}

// MARK: - Récepteur (DATA → ACK)

/// Côté qui reçoit le fichier : serveur pour une écriture (WRQ), client pour une lecture (get).
/// Acquitte chaque fenêtre ; un bloc hors d'ordre fait renvoyer l'ACK du dernier bloc reçu en
/// ordre (une seule fois par trou) ; le dernier bloc (plus court que blksize) termine.
public struct TFTPReceiver {
    public private(set) var settings: TFTPTransferSettings
    private let write: ([UInt8]) throws -> Void
    private var expected: UInt64 = 1
    private var sinceAck = 0
    private var gapAcknowledged = false
    private var attempts = 0
    /// Paquet renvoyé quand le délai expire : ACK 0 ou OACK au début, puis le dernier ACK.
    private var lastSent: TFTPPacket?
    public private(set) var bytesReceived: Int64 = 0
    public private(set) var isFinished = false
    /// Dernier ACK (renvoyé si le dernier bloc arrive en double après la fin).
    public private(set) var finalAck: TFTPPacket?

    /// `initial` : paquet qui ouvre le transfert et qui est renvoyé tant qu'aucun bloc n'arrive
    /// (ACK 0 ou OACK côté serveur ; nil côté client, la requête étant gérée par TFTPClientMachine).
    public init(settings: TFTPTransferSettings, initial: TFTPPacket?, write: @escaping ([UInt8]) throws -> Void) {
        self.settings = settings
        self.write = write
        self.lastSent = initial
    }

    public mutating func start() -> TFTPAction {
        .send(lastSent.map { [$0] } ?? [])
    }

    public mutating func receive(_ packet: TFTPPacket) -> TFTPAction {
        if isFinished {
            // Dernier bloc en double : l'ACK final s'est perdu.
            if case .data = packet, let finalAck { return .send([finalAck]) }
            return .send([])
        }
        switch packet {
        case .data(let block, let payload):
            guard payload.count <= settings.blockSize else {
                return .fail(.protocolError("bloc de \(payload.count) octets, plus grand que blksize (\(settings.blockSize))"))
            }
            guard block == wireBlock(expected) else {
                // Bloc en double ou hors d'ordre : on redit où on en est (une fois par trou).
                if gapAcknowledged { return .send([]) }
                gapAcknowledged = true
                sinceAck = 0
                let ack = TFTPPacket.ack(block: wireBlock(expected &- 1))
                lastSent = ack
                return .send([ack])
            }
            if let limit = settings.transferSize, settings.mode == .octet, bytesReceived + Int64(payload.count) > limit + Int64(settings.blockSize) {
                return .fail(.local(.diskFull, "Le fichier dépasse la taille annoncée (\(limit) octets)."))
            }
            do {
                try write(payload)
            } catch let failure as TFTPFailure {
                return .fail(failure)
            } catch let error as TFTPFileError {
                return .fail(error.failure)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return .fail(.local(.diskFull, "Écriture impossible\u{00A0}: \(message)"))
            }
            attempts = 0
            gapAcknowledged = false
            bytesReceived += Int64(payload.count)
            expected += 1
            sinceAck += 1
            let ack = TFTPPacket.ack(block: block)
            if payload.count < settings.blockSize {
                isFinished = true
                finalAck = ack
                lastSent = ack
                return .complete([ack])
            }
            if sinceAck >= settings.windowSize {
                sinceAck = 0
                lastSent = ack
                return .send([ack])
            }
            lastSent = ack
            return .send([])
        case .error(let code, let message):
            return .fail(.remote(code, message))
        case .oack, .ack, .request:
            return .fail(.protocolError("paquet inattendu pendant la réception (\(packet.summary))"))
        }
    }

    public mutating func timeout() -> TFTPAction {
        guard !isFinished else { return .send([]) }
        attempts += 1
        guard attempts <= settings.retries else { return .fail(.timeout(retries: settings.retries)) }
        sinceAck = 0
        return .send(lastSent.map { [$0] } ?? [])
    }
}

// MARK: - Client

/// Client TFTP pur : envoie la requête (RRQ ou WRQ avec options), lit la réponse (OACK, DATA 1,
/// ACK 0 ou ERROR), repart sans options si le serveur les refuse (ERROR 8), puis confie le
/// transfert à un TFTPSender ou un TFTPReceiver.
public struct TFTPClientMachine {
    public enum Phase: Equatable, Sendable { case requesting, transferring, finished }

    public private(set) var phase: Phase = .requesting
    public private(set) var request: TFTPRequest
    public private(set) var settings: TFTPTransferSettings
    private let base: TFTPTransferSettings
    private let read: ((Int) throws -> [UInt8])?
    private let write: (([UInt8]) throws -> Void)?
    private var sender: TFTPSender?
    private var receiver: TFTPReceiver?
    private var attempts = 0
    /// Vrai quand la requête a été renvoyée sans options après un ERROR 8 (ou une réponse invalide).
    public private(set) var fellBackWithoutOptions = false

    /// Lecture (get) : les blocs reçus passent par `write`.
    public init(get filename: String, options: [TFTPOption], settings: TFTPTransferSettings, write: @escaping ([UInt8]) throws -> Void) {
        request = TFTPRequest(kind: .read, filename: filename, mode: settings.mode, options: options)
        self.settings = settings
        base = settings
        read = nil
        self.write = write
    }

    /// Écriture (put) : les blocs envoyés viennent de `read`.
    public init(put filename: String, options: [TFTPOption], settings: TFTPTransferSettings, read: @escaping (Int) throws -> [UInt8]) {
        request = TFTPRequest(kind: .write, filename: filename, mode: settings.mode, options: options)
        self.settings = settings
        base = settings
        self.read = read
        write = nil
    }

    public var bytesTransferred: Int64 {
        sender?.bytesAcknowledged ?? receiver?.bytesReceived ?? 0
    }

    public var retransmissions: Int { sender?.retransmissions ?? 0 }

    public mutating func start() -> TFTPAction {
        .send([.request(request)])
    }

    public mutating func receive(_ packet: TFTPPacket) -> TFTPAction {
        switch phase {
        case .finished:
            if var receiver { let action = receiver.receive(packet); self.receiver = receiver; return action }
            return .send([])
        case .transferring:
            return forward(packet)
        case .requesting:
            switch (request.kind, packet) {
            case (_, .oack(let options)):
                switch TFTPNegotiation.client(oack: options, requested: request.options, base: base) {
                case .failure(let failure):
                    phase = .finished
                    return .fail(.local(.optionRefused, failure.errorDescription ?? ""))
                case .success(let negotiated):
                    settings = negotiated
                    phase = .transferring
                    if request.kind == .read {
                        var receiver = TFTPReceiver(settings: negotiated, initial: .ack(block: 0), write: write ?? { _ in })
                        let action = receiver.start()
                        self.receiver = receiver
                        return action
                    }
                    var sender = TFTPSender(settings: negotiated, read: read ?? { _ in [] })
                    let action = sender.start()
                    self.sender = sender
                    return track(action)
                }
            case (.read, .data(let block, _)):
                // Serveur sans options (RFC 1350) : blocs de 512 octets, sans fenêtre.
                guard block == 1 else { return .send([]) }
                settings = Self.plain(base)
                phase = .transferring
                // Tant qu'aucun ACK n'est parti, le délai renvoie la requête.
                receiver = TFTPReceiver(settings: settings, initial: .request(request), write: write ?? { _ in })
                return forward(packet)
            case (.write, .ack(let block)):
                guard block == 0 else { return .send([]) }
                settings = Self.plain(base)
                phase = .transferring
                var sender = TFTPSender(settings: settings, read: read ?? { _ in [] })
                let action = sender.start()
                self.sender = sender
                return track(action)
            case (_, .error(let code, let message)):
                if code == .optionRefused && !request.options.isEmpty && !fellBackWithoutOptions {
                    // Le serveur refuse les options : on redemande en RFC 1350 pure.
                    fellBackWithoutOptions = true
                    request.options = []
                    attempts = 0
                    return .send([.request(request)])
                }
                phase = .finished
                return .fail(.remote(code, message))
            default:
                return .send([])
            }
        }
    }

    public mutating func timeout() -> TFTPAction {
        switch phase {
        case .requesting:
            attempts += 1
            guard attempts <= base.retries else {
                phase = .finished
                return .fail(.timeout(retries: base.retries))
            }
            return .send([.request(request)])
        case .transferring:
            if var sender {
                let action = sender.timeout()
                self.sender = sender
                return track(action)
            }
            if var receiver {
                let action = receiver.timeout()
                self.receiver = receiver
                return track(action)
            }
            return .send([])
        case .finished:
            return .send([])
        }
    }

    private mutating func forward(_ packet: TFTPPacket) -> TFTPAction {
        if var sender {
            let action = sender.receive(packet)
            self.sender = sender
            return track(action)
        }
        if var receiver {
            let action = receiver.receive(packet)
            self.receiver = receiver
            return track(action)
        }
        return .send([])
    }

    private mutating func track(_ action: TFTPAction) -> TFTPAction {
        switch action {
        case .complete, .fail: phase = .finished
        case .send: break
        }
        return action
    }

    private static func plain(_ base: TFTPTransferSettings) -> TFTPTransferSettings {
        var settings = base
        settings.blockSize = TFTPLimits.defaultBlockSize
        settings.windowSize = 1
        return settings
    }
}
