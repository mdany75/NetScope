import Foundation
import Network
import Security

// Note 70 : connexion du vérificateur de certificat TLS (Network.framework). Une poignée
// principale lit la chaîne envoyée par le serveur, le verdict de macOS (SecTrust), la version et
// la suite négociées ; puis chaque version de TLS 1.0 à 1.3 est tentée seule (min = max). Le
// certificat est toujours accepté pour pouvoir décrire un certificat expiré ou auto-signé :
// aucune donnée n'est envoyée au-delà de la poignée (et de STARTTLS en clair).

public enum TLSProbe {
    /// Vérification complète d'un serveur.
    /// - serverName : nom envoyé par SNI et vérifié contre le certificat (nil : l'hôte, s'il n'est pas une adresse).
    public static func inspect(host rawHost: String, port: UInt16, serverName: String? = nil, mode: TLSStartMode = .direct,
                               timeout: TimeInterval = 8, testVersions: Bool = true) async -> TLSInspection {
        let host = TLSHostname.normalized(rawHost)
        let sni = serverName.map(TLSHostname.normalized).flatMap { $0.isEmpty ? nil : $0 }
            ?? (IPv4Address(host) == nil && !host.contains(":") ? host : nil)
        let start = Date()
        let main = await handshake(host: host, port: port, serverName: sni, mode: mode, version: nil, timeout: timeout)
        var inspection = TLSInspection(date: start, host: host, port: port, serverName: sni, mode: mode, address: main.address,
                                       chain: main.chain.compactMap { try? X509Certificate(der: $0) },
                                       trusted: main.trusted, trustReason: main.trustReason, chainTrusted: main.chainTrusted,
                                       negotiatedVersion: main.version, cipherSuite: main.cipher, handshakeMs: main.durationMs,
                                       error: main.error)
        guard testVersions, main.error == nil || !main.chain.isEmpty || main.reachedTLS else { return inspection }
        // Chaque version seule, en parallèle (quatre connexions courtes).
        inspection.versions = await withTaskGroup(of: TLSVersionSupport.self) { group in
            for version in TLSVersion.allCases {
                group.addTask {
                    let attempt = await handshake(host: host, port: port, serverName: sni, mode: mode, version: version,
                                                  timeout: min(timeout, 6))
                    if attempt.error == nil {
                        return TLSVersionSupport(version: version, accepted: true, detail: attempt.cipher)
                    }
                    // Échec avant TLS (port fermé, STARTTLS refusé) : version non jugée.
                    return TLSVersionSupport(version: version, accepted: attempt.reachedTLS ? false : nil, detail: attempt.error)
                }
            }
            var list: [TLSVersionSupport] = []
            for await item in group { list.append(item) }
            return list.sorted { $0.version > $1.version }
        }
        return inspection
    }

    // MARK: Une poignée

    struct Outcome: Sendable {
        var chain: [Data] = []
        var trusted = false
        var trustReason: String?
        var chainTrusted: Bool?
        var version: TLSVersion?
        var cipher: String?
        var durationMs: Double?
        var address: String?
        var error: String?
        /// La poignée TLS a commencé (la partie TCP et STARTTLS a réussi).
        var reachedTLS = false
    }

    static func handshake(host: String, port: UInt16, serverName: String?, mode: TLSStartMode,
                          version: TLSVersion?, timeout: TimeInterval) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return Outcome(error: "Port invalide") }
        let box = ToolBox(Outcome())
        let queue = DispatchQueue(label: "netscope.tls")
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if let serverName { sec_protocol_options_set_tls_server_name(security, serverName) }
        if let version, let raw = tls_protocol_version_t(rawValue: version.code) {
            sec_protocol_options_set_min_tls_protocol_version(security, raw)
            sec_protocol_options_set_max_tls_protocol_version(security, raw)
        } else if let lowest = tls_protocol_version_t(rawValue: TLSVersion.tls10.code) {
            // Poignée principale : accepter aussi un vieil appareil qui ne parle que TLS 1.0.
            sec_protocol_options_set_min_tls_protocol_version(security, lowest)
        }
        let checkedName = serverName ?? host
        sec_protocol_options_set_verify_block(security, { metadata, trust, complete in
            var ders: [Data] = []
            sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
                ders.append(SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data)
            }
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            var trusted = false
            var reason: String?
            var chainTrusted: Bool?
            if version == nil {
                // Verdict de macOS avec le nom, puis sans le nom (chaîne seule).
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, checkedName as CFString))
                var error: CFError?
                trusted = SecTrustEvaluateWithError(secTrust, &error)
                reason = error.map { CFErrorCopyDescription($0) as String }
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, nil))
                chainTrusted = SecTrustEvaluateWithError(secTrust, nil)
            }
            if ders.isEmpty, let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] {
                ders = chain.map { SecCertificateCopyData($0) as Data }
            }
            let negotiated = TLSVersion(code: sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata).rawValue)
            let suite = TLSCipherSuite.name(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue)
            box.mutate {
                $0.chain = ders
                $0.trusted = trusted
                $0.trustReason = reason
                $0.chainTrusted = chainTrusted
                $0.version = negotiated
                $0.cipher = suite
            }
            complete(true)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        tcp.noDelay = true
        let parameters: NWParameters
        if mode == .direct {
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
            let context = TLSStartContext(mode: mode, tlsOptions: tls)
            let framer = NWProtocolFramer.Options(definition: TLSStartTLSFramer.definition)
            framer[TLSStartTLSFramer.contextKey] = context
            parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
            return await run(host: host, port: nwPort, parameters: parameters, queue: queue, box: box, context: context,
                             timeout: timeout * 2)
        }
        return await run(host: host, port: nwPort, parameters: parameters, queue: queue, box: box, context: nil, timeout: timeout)
    }

    private static func run(host: String, port: NWEndpoint.Port, parameters: NWParameters, queue: DispatchQueue,
                            box: ToolBox<Outcome>, context: TLSStartContext?, timeout: TimeInterval) async -> Outcome {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let start = Date()
        let result: Outcome = await withCheckedContinuation { continuation in
            let once = ToolOnce()
            @Sendable func finish(_ error: String?, reachedTLS: Bool) {
                guard once.claim() else { return }
                var outcome = box.value
                outcome.error = error
                outcome.reachedTLS = reachedTLS || context?.tlsStarted == true && context?.failure == nil
                outcome.durationMs = error == nil ? Date().timeIntervalSince(start) * 1000 : nil
                if case .hostPort(let remote, _)? = connection.currentPath?.remoteEndpoint {
                    outcome.address = "\(remote)".components(separatedBy: "%").first
                }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(nil, reachedTLS: true)
                case .waiting(let error), .failed(let error):
                    if let failure = context?.failure { return finish(failure, reachedTLS: false) }
                    finish(describe(error), reachedTLS: reachedHandshake(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(context?.failure ?? "Délai dépassé (\(Int(timeout))\u{00A0}s)", reachedTLS: false)
            }
        }
        return result
    }

    /// L'erreur survient pendant la poignée TLS (refus d'une version), pas avant (port fermé, nom introuvable).
    static func reachedHandshake(_ error: NWError) -> Bool {
        switch error {
        case .tls: return true
        case .posix(let code): return code == .ECONNRESET || code == .ECONNABORTED || code == .EPIPE
        default: return false
        }
    }

    /// Raison lisible d'une erreur réseau ou TLS.
    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connexion refusée (port fermé)"
            case .ETIMEDOUT: return "Délai dépassé"
            case .EHOSTUNREACH, .ENETUNREACH: return "Hôte injoignable"
            case .ECONNRESET: return "Connexion fermée par le serveur"
            case .ECONNABORTED: return "Connexion interrompue"
            default: return "Erreur réseau (\(code.rawValue))"
            }
        case .dns: return "Nom introuvable"
        case .tls(let status): return tlsMessage(status)
        default: return error.localizedDescription
        }
    }

    /// Codes OSStatus TLS les plus courants.
    public static func tlsMessage(_ status: OSStatus) -> String {
        switch status {
        case -9836: return "Version refusée par le serveur"
        case -9824: return "Poignée refusée par le serveur (version ou suite)"
        case -9806: return "Connexion fermée pendant la poignée"
        case -9805: return "Connexion fermée proprement pendant la poignée"
        case -9800: return "Erreur de protocole TLS"
        case -9831: return "Version ou suite non négociable"
        case -9858: return "Version refusée par ce Mac"
        default: return "Échec de la poignée TLS (\(status))"
        }
    }
}

// MARK: - STARTTLS par un framer

final class TLSStartContext: @unchecked Sendable {
    let mode: TLSStartMode
    let tlsOptions: NWProtocolTLS.Options
    private let box = ToolBox<(failure: String?, tlsStarted: Bool)>((nil, false))

    init(mode: TLSStartMode, tlsOptions: NWProtocolTLS.Options) {
        self.mode = mode
        self.tlsOptions = tlsOptions
    }

    var failure: String? { box.value.failure }
    var tlsStarted: Bool { box.value.tlsStarted }
    func fail(_ reason: String) { box.mutate { $0.failure = $0.failure ?? reason } }
    func markTLSStarted() { box.mutate { $0.tlsStarted = true } }
}

/// Mène la partie en clair (TLSStartTLSDialogue), puis ajoute TLS au-dessus de lui-même.
final class TLSStartTLSFramer: NWProtocolFramerImplementation {
    static let label = "NetScope STARTTLS"
    static let definition = NWProtocolFramer.Definition(implementation: TLSStartTLSFramer.self)
    static let contextKey = "netscope.tls.context"

    private var context: TLSStartContext?
    private var dialogue = TLSStartTLSDialogue(mode: .smtp)
    private var finished = false

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        context = framer.options[Self.contextKey] as? TLSStartContext
        dialogue = TLSStartTLSDialogue(mode: context?.mode ?? .smtp, ehloName: SMTPDiagnostic.ehloName(for: framer.local))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var bytes: [UInt8] = []
        var closed = false
        while true {
            var consumed = 0
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 16_384) { buffer, isComplete in
                guard let buffer, buffer.count > 0 else {
                    if isComplete { closed = true }
                    return 0
                }
                bytes += buffer
                consumed = buffer.count
                return buffer.count
            }
            if !parsed || consumed == 0 { break }
        }
        guard !finished else { return 0 }
        for action in dialogue.feed(bytes) {
            switch action {
            case let .send(line):
                framer.writeOutput(data: Data((line + "\r\n").utf8))
            case .startTLS:
                startTLS(framer)
                return 0
            case let .fail(reason):
                fail(framer, reason)
                return 0
            }
        }
        if closed { fail(framer, "Connexion fermée par le serveur avant STARTTLS") }
        return 0
    }

    private func startTLS(_ framer: NWProtocolFramer.Instance) {
        finished = true
        guard let context else { return fail(framer, "Contexte absent") }
        do {
            try framer.prependApplicationProtocol(options: context.tlsOptions)
        } catch {
            return fail(framer, "TLS impossible à démarrer")
        }
        context.markTLSStarted()
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.async { framer.markReady() }
    }

    private func fail(_ framer: NWProtocolFramer.Instance, _ reason: String) {
        finished = true
        context?.fail(reason)
        framer.markFailed(error: .posix(.ECONNABORTED))
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
