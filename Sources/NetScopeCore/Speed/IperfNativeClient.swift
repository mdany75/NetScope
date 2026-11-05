import Darwin
import Foundation

// Note 78 : client iperf3 intégré, pour mesurer sans installer iperf3 : vers un autre Mac qui fait
// tourner le serveur intégré de NetScope, ou vers un vrai « iperf3 -s ». TCP, sens normal (ce Mac
// envoie) ou inverse -R (ce Mac reçoit), 1 à 128 flux. L'UDP et le bidirectionnel restent
// l'affaire d'iperf3 installé (`IperfRunner`).

public enum IperfNativeClient {
    /// Le moteur intégré sait-il faire ce test ? Sinon, la raison.
    public static func unsupportedReason(_ options: IperfOptions) -> String? {
        if options.transport == .udp { return "Le moteur intégré mesure en TCP\u{00A0}; l’UDP demande iperf3 installé (brew install iperf3)." }
        if options.direction == .bidir { return "Le moteur intégré mesure un sens à la fois\u{00A0}; le bidirectionnel demande iperf3 installé." }
        return nil
    }

    /// Lance le test ; `onInterval` reçoit chaque seconde mesurée (sur un fil quelconque).
    /// L'annulation de la tâche arrête le test (CLIENT_TERMINATE envoyé au serveur).
    public static func run(_ options: IperfOptions, connectTimeout: Double = 5,
                           onInterval: (@Sendable (IperfInterval) -> Void)? = nil) async throws -> IperfResult {
        _ = try options.arguments()
        if let reason = unsupportedReason(options) { throw IperfProtocolError.unsupported(reason) }
        let stop = IperfFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    do {
                        let result = try IperfClientSession(options: options, connectTimeout: connectTimeout, stop: stop,
                                                            onInterval: onInterval).run()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: stop.isSet ? IperfProtocolError.cancelled : error)
                    }
                }
                thread.name = "NetScope – client iperf3"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            stop.set()
        }
    }
}

/// Un test côté client, sur son propre fil (appels bloquants).
final class IperfClientSession {
    let options: IperfOptions
    let connectTimeout: Double
    let stop: IperfFlag
    let onInterval: (@Sendable (IperfInterval) -> Void)?

    init(options: IperfOptions, connectTimeout: Double, stop: IperfFlag, onInterval: (@Sendable (IperfInterval) -> Void)?) {
        self.options = options
        self.connectTimeout = connectTimeout
        self.stop = stop
        self.onInterval = onInterval
    }

    func run() throws -> IperfResult {
        let host = options.host.trimmingCharacters(in: .whitespaces)
        let port = UInt16(clamping: options.port)
        let reverse = options.direction == .reverse
        let control = try IperfSocket.connect(host: host, port: port, timeout: connectTimeout)
        var workers: [IperfStreamWorker] = []
        var terminate = true
        defer {
            if terminate { try? IperfSocket.writeState(control, .clientTerminate) }
            for worker in workers { worker.finish() }
            for worker in workers { worker.closeSocket() }
            close(control)
        }
        let localHost = Self.localAddress(control)
        let cookie = IperfProtocol.makeCookie()
        try IperfSocket.writeAll(control, cookie, step: "cookie")
        IperfSocket.configure(control, timeout: 10)

        let parameters = IperfTestParameters(reverse: reverse, time: options.duration, parallel: options.streams)
        var t0 = 0.0, t1 = 0.0
        var serverResults: IperfExchangedResults?
        var intervals: [IperfInterval] = []
        var running = true
        while running {
            if stop.isSet { throw IperfProtocolError.cancelled }
            let byte = try IperfSocket.readState(control, step: "réponse du serveur")
            guard let state = IperfState(byte: byte) else { throw IperfProtocolError.unexpectedState(Int(Int8(bitPattern: byte))) }
            switch state {
            case .paramExchange:
                try IperfSocket.writeJSON(control, parameters.json, step: "paramètres du test")
            case .createStreams:
                let ids = IperfProtocol.streamIDs(count: options.streams)
                for id in ids {
                    let fd = try IperfSocket.connect(host: host, port: port, timeout: connectTimeout)
                    do {
                        try IperfSocket.writeAll(fd, cookie, step: "cookie du flux")
                    } catch {
                        close(fd)
                        throw error
                    }
                    workers.append(IperfStreamWorker(fd: fd, id: id, sending: !reverse, blockSize: IperfProtocol.defaultBlockSize))
                }
            case .testStart:
                break
            case .testRunning:
                t0 = IperfClock.now()
                for worker in workers { worker.start(at: t0) }
                intervals = try measure(control: control, workers: workers, t0: t0)
                t1 = IperfClock.now()
                for worker in workers { worker.finish() }
                try IperfSocket.writeState(control, .testEnd)
            case .exchangeResults:
                let elapsed = max(t1 - t0, 0.001)
                let ours = IperfExchangedResults(senderHasRetransmits: reverse ? -1 : 0, streams: workers.map {
                    IperfExchangedResults.Stream(id: $0.id, bytes: $0.counter.total, retransmits: -1, startTime: 0, endTime: elapsed)
                })
                try IperfSocket.writeJSON(control, ours.json, step: "résultats du client")
                serverResults = try IperfExchangedResults.parse(IperfSocket.readJSON(control, step: "résultats du serveur"))
            case .displayResults:
                try? IperfSocket.writeState(control, .iperfDone)
                terminate = false
                running = false
            case .iperfDone:
                terminate = false
                running = false
            case .accessDenied:
                terminate = false
                throw IperfProtocolError.accessDenied
            case .serverError:
                terminate = false
                let bytes = (try? IperfSocket.readExactly(control, 8, step: "erreur du serveur")) ?? [UInt8](repeating: 0, count: 8)
                func int32(_ slice: ArraySlice<UInt8>) -> Int32 {
                    slice.reduce(Int32(0)) { ($0 << 8) | Int32($1) }
                }
                throw IperfProtocolError.serverError(code: int32(bytes[0..<4]), errno: int32(bytes[4..<8]))
            case .serverTerminate:
                terminate = false
                throw IperfProtocolError.serverTerminated
            default:
                break
            }
        }

        let elapsed = max(t1 - t0, 0.001)
        let localBytes = workers.reduce(Int64(0)) { $0 + $1.counter.total }
        let remoteBytes = serverResults?.totalBytes ?? 0
        let remoteSeconds = (serverResults?.duration ?? 0) > 0 ? serverResults!.duration : elapsed
        var result = IperfResult(version: "NetScope (moteur intégré)", protocolName: "TCP", streams: workers.count,
                                 duration: elapsed, localHost: localHost, remoteHost: host, remotePort: options.port,
                                 reverse: reverse, bidirectional: false, intervals: intervals)
        if reverse {
            result.sentBytes = remoteBytes
            result.sentBitsPerSecond = Double(remoteBytes) * 8 / remoteSeconds
            result.receivedBytes = localBytes
            result.receivedBitsPerSecond = Double(localBytes) * 8 / elapsed
        } else {
            result.sentBytes = localBytes
            result.sentBitsPerSecond = Double(localBytes) * 8 / elapsed
            result.receivedBytes = remoteBytes
            result.receivedBitsPerSecond = Double(remoteBytes) * 8 / remoteSeconds
        }
        if reverse, serverResults?.senderHasRetransmits == 1 {
            result.retransmits = serverResults?.streams.reduce(0) { $0 + max($1.retransmits, 0) }
        }
        return result
    }

    /// Mesure jusqu'à la durée demandée : un intervalle par seconde. Le serveur peut interrompre.
    private func measure(control: Int32, workers: [IperfStreamWorker], t0: Double) throws -> [IperfInterval] {
        var intervals: [IperfInterval] = []
        var lastTime = t0
        var lastBytes: Int64 = 0
        let end = t0 + Double(options.duration)
        func addInterval(_ now: Double) {
            let bytes = workers.reduce(Int64(0)) { $0 + $1.counter.total }
            let seconds = now - lastTime
            guard seconds > 0.05 else { return }
            let interval = IperfInterval(start: lastTime - t0, end: now - t0, bytes: bytes - lastBytes,
                                         bitsPerSecond: Double(bytes - lastBytes) * 8 / seconds)
            intervals.append(interval)
            onInterval?(interval)
            lastTime = now
            lastBytes = bytes
        }
        while true {
            if stop.isSet { throw IperfProtocolError.cancelled }
            let now = IperfClock.now()
            if now >= end {
                addInterval(now)
                return intervals
            }
            if now - lastTime >= 1 { addInterval(now) }
            let wait = Int32(max(10, min(100, (min(end, lastTime + 1) - now) * 1000)))
            if IperfSocket.waitReadable(control, milliseconds: wait) {
                let byte = try IperfSocket.readState(control, step: "pendant le test")
                if IperfState(byte: byte) == .serverTerminate { throw IperfProtocolError.serverTerminated }
            }
        }
    }

    static func localAddress(_ fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return ok == 0 ? IperfSocket.address(of: storage) : nil
    }
}
