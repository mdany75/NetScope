import Darwin
import Foundation

/// Réglages d'un ping continu.
public struct PingOptions: Equatable, Sendable {
    /// Intervalles proposés : 0,2 / 0,5 / 1 / 5 s.
    public static let intervals: [TimeInterval] = [0.2, 0.5, 1, 5]
    /// Tailles proposées : 56 octets (classique) et 1472 octets (test MTU 1500 avec DF).
    public static let payloadSizes = [56, 1472]

    public var interval: TimeInterval
    /// Octets de données après l'en-tête ICMP.
    public var payloadSize: Int
    public var dontFragment: Bool
    /// Délai d'attente d'une réponse ; nil : 1 s sous 1 s d'intervalle, 2 s sinon.
    public var timeout: TimeInterval?

    public init(interval: TimeInterval = 1, payloadSize: Int = 56, dontFragment: Bool = false, timeout: TimeInterval? = nil) {
        self.interval = max(0.05, interval)
        self.payloadSize = min(max(0, payloadSize), 65_000)
        self.dontFragment = dontFragment
        self.timeout = timeout
    }

    public var effectiveTimeout: TimeInterval { timeout ?? (interval >= 1 ? 2 : 1) }
}

/// Ping continu d'une adresse : un Echo Request à chaque intervalle, réponses rapprochées par
/// identifiant et séquence. Les mesures sont rendues dans l'ordre des séquences (une perte est
/// déclarée à l'expiration du délai). Tout se passe sur une file série propre au moniteur.
public final class PingMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (PingSample) -> Void

    public let address: IPv4Address
    public let identifier: UInt16
    private let handler: Handler
    private let queue: DispatchQueue
    private var options: PingOptions
    private var socket: PingSocket?
    private var timer: DispatchSourceTimer?
    private var reader: DispatchSourceRead?

    private struct Pending { let sentMs: Double; let date: Date }
    private var nextSequence = 1
    private var nextToEmit = 1
    private var pending: [Int: Pending] = [:]
    private var resolved: [Int: PingSample] = [:]
    private var dontFragmentAccepted = false
    /// Vrai si le système a accepté l'option DF demandée.
    public var dontFragmentApplied: Bool { queue.sync { dontFragmentAccepted } }

    public init(address: IPv4Address, options: PingOptions = PingOptions(), identifier: UInt16 = PingIdentifiers.next(),
                handler: @escaping Handler) {
        self.address = address
        self.options = options
        self.identifier = identifier
        self.handler = handler
        queue = DispatchQueue(label: "netscope.ping.\(address)", qos: .userInitiated)
    }

    deinit {
        timer?.cancel()
        reader?.cancel()
    }

    /// Ouvre la socket et lance les envois. Lève une erreur si la socket ICMP est refusée.
    public func start() throws {
        let socket = try PingSocket()
        queue.sync {
            guard self.socket == nil else { return }
            self.socket = socket
            if options.dontFragment { dontFragmentAccepted = socket.setDontFragment(true) }
            let reader = DispatchSource.makeReadSource(fileDescriptor: socket.descriptor, queue: queue)
            reader.setEventHandler { [weak self] in self?.drain() }
            reader.setCancelHandler { socket.close() }
            self.reader = reader
            reader.resume()
            scheduleTimer()
        }
    }

    /// Arrête les envois et ferme la socket ; les paquets en attente sont abandonnés.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            reader?.cancel()
            reader = nil
            socket = nil
            pending.removeAll()
            resolved.removeAll()
            nextToEmit = nextSequence
        }
    }

    /// Change l'intervalle, la taille ou le bit DF sans perdre la séquence.
    public func update(_ newOptions: PingOptions) {
        queue.async { [self] in
            let intervalChanged = newOptions.interval != options.interval
            options = newOptions
            if let socket {
                let accepted = socket.setDontFragment(newOptions.dontFragment)
                dontFragmentAccepted = newOptions.dontFragment && accepted
            }
            if intervalChanged, timer != nil { scheduleTimer() }
        }
    }

    public var isRunning: Bool { queue.sync { timer != nil } }

    // MARK: File série

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leeway = DispatchTimeInterval.milliseconds(max(1, Int(options.interval * 50)))
        timer.schedule(deadline: .now(), repeating: options.interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        expire()
        guard let socket else { return }
        let sequence = nextSequence
        nextSequence += 1
        let packet = PingICMP.echoRequestPacket(identifier: identifier, sequence: UInt16(truncatingIfNeeded: sequence),
                                                payloadSize: options.payloadSize)
        let date = Date()
        let sentMs = PingClock.nowMs()
        let error = socket.send(packet, to: address)
        if error == 0 {
            pending[sequence] = Pending(sentMs: sentMs, date: date)
            // Sans cela, avec un intervalle plus long que le délai (5 s), la perte ne serait
            // constatée qu'au prochain envoi et une réponse tardive serait encore acceptée.
            let timeout = options.effectiveTimeout
            if timeout < options.interval {
                queue.asyncAfter(deadline: .now() + timeout + 0.01) { [weak self] in
                    guard let self, self.socket != nil else { return }
                    self.expire()
                    self.flush()
                }
            }
        } else {
            let failure: PingFailure = error == EMSGSIZE ? .messageTooLong : .sendFailed(errno: error)
            resolved[sequence] = PingSample(sequence: sequence, date: date, rttMs: nil, failure: failure)
        }
        flush()
    }

    /// Déclare perdus les paquets restés sans réponse au-delà du délai.
    private func expire() {
        let now = PingClock.nowMs()
        let limit = options.effectiveTimeout * 1000
        for (sequence, entry) in pending where now - entry.sentMs > limit {
            pending[sequence] = nil
            resolved[sequence] = PingSample(sequence: sequence, date: entry.date, rttMs: nil, failure: .timeout)
        }
    }

    private func drain() {
        guard let socket else { return }
        while let packet = socket.receive() {
            let now = PingClock.nowMs()
            guard let (message, header) = PingICMP.parse(packet.bytes), message.identifier == identifier,
                  let sequence = pendingSequence(for: message.sequence), let entry = pending[sequence] else { continue }
            switch message {
            case .echoReply:
                // Une réponse ne compte que si elle vient bien de la cible.
                guard (header ?? packet.from) == address || packet.from == address else { continue }
                pending[sequence] = nil
                resolved[sequence] = PingSample(sequence: sequence, date: entry.date, rttMs: max(0, now - entry.sentMs))
            case let .unreachable(code, _, _, _):
                pending[sequence] = nil
                resolved[sequence] = PingSample(sequence: sequence, date: entry.date, rttMs: nil,
                                                failure: code == 4 ? .messageTooLong : .unreachable(code: code, from: header ?? packet.from))
            case .timeExceeded:
                pending[sequence] = nil
                resolved[sequence] = PingSample(sequence: sequence, date: entry.date, rttMs: nil,
                                                failure: .unreachable(code: 255, from: header ?? packet.from))
            }
        }
        flush()
    }

    private func pendingSequence(for wire: UInt16) -> Int? {
        pending.keys.first { UInt16(truncatingIfNeeded: $0) == wire }
    }

    /// Rend les mesures dans l'ordre des séquences.
    private func flush() {
        while let sample = resolved.removeValue(forKey: nextToEmit) {
            nextToEmit += 1
            handler(sample)
        }
    }
}
