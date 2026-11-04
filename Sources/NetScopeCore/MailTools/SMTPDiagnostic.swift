import Foundation
import Network
import Security

// Diagnostic SMTP (note 14) : connexion TCP par Network.framework au port 25, 587 ou 465 d'un
// serveur, bannière 220, EHLO et extensions, STARTTLS puis poignée TLS et certificat, QUIT.
// Seules les commandes EHLO, STARTTLS et QUIT sont envoyées (SMTPCommand) : jamais de MAIL FROM,
// RCPT TO ni DATA, donc aucun courriel envoyé et aucun test de relais ouvert.
//
// STARTTLS avec Network.framework : un « framer » (SMTPStartTLSFramer) mène la partie en clair
// (bannière, EHLO, STARTTLS) sous la connexion, puis ajoute TLS au-dessus de lui-même
// (prependApplicationProtocol) et se déclare prêt : la poignée TLS démarre alors sur la même
// connexion TCP. Au port 465, TLS est ajouté dès l'ouverture.

/// Une étape du diagnostic, avec sa durée.
public struct SMTPStep: Identifiable, Sendable, Hashable {
    public enum Status: String, Sendable { case ok, warning, failed, skipped }

    public var name: String
    public var durationMs: Double?
    public var status: Status
    public var detail: String

    public var id: String { name }

    public init(_ name: String, durationMs: Double?, status: Status, detail: String) {
        self.name = name
        self.durationMs = durationMs
        self.status = status
        self.detail = detail
    }
}

/// Une ligne de l'échange (C : client, S : serveur, note : événement).
public struct SMTPTranscriptLine: Identifiable, Sendable, Hashable {
    public enum Direction: String, Sendable { case client, server, note }

    public var id: Int
    public var direction: Direction
    public var text: String
    /// Millisecondes depuis le début du diagnostic.
    public var offsetMs: Double

    public init(id: Int, direction: Direction, text: String, offsetMs: Double) {
        self.id = id
        self.direction = direction
        self.text = text
        self.offsetMs = offsetMs
    }
}

/// Serveur à tester : nom (ou adresse) et préférence MX.
public struct SMTPTarget: Identifiable, Sendable, Hashable {
    public var host: String
    public var preference: Int?

    public var id: String { host }

    public init(host: String, preference: Int? = nil) {
        self.host = host
        self.preference = preference
    }
}

/// Résultat complet du diagnostic d'un serveur.
public struct SMTPDiagnosticResult: Identifiable, Sendable {
    public var host: String
    public var port: UInt16
    public var preference: Int?
    public var address: String?
    public var mode: SMTPTLSMode
    public var connectOutcome: SMTPConnectOutcome
    public var steps: [SMTPStep]
    public var transcript: [SMTPTranscriptLine]
    public var banner: SMTPReply?
    public var ehloGreeting: String?
    /// Extensions annoncées en clair (ports 25 et 587).
    public var extensions: [SMTPExtension]
    /// Extensions annoncées après le chiffrement (et au port 465).
    public var extensionsAfterTLS: [SMTPExtension]
    public var tls: SMTPTLSState
    public var tlsVersion: String?
    public var cipher: String?
    public var certificate: SMTPCertificate?
    public var ptrNames: [String]
    public var ptrConfirmed: Bool?
    public var findings: [SMTPFinding]
    public var totalMs: Double

    public var id: String { "\(host):\(port)" }

    public init(host: String, port: UInt16, preference: Int? = nil, address: String? = nil, mode: SMTPTLSMode,
                connectOutcome: SMTPConnectOutcome, steps: [SMTPStep] = [], transcript: [SMTPTranscriptLine] = [],
                banner: SMTPReply? = nil, ehloGreeting: String? = nil, extensions: [SMTPExtension] = [],
                extensionsAfterTLS: [SMTPExtension] = [], tls: SMTPTLSState = .notReached, tlsVersion: String? = nil,
                cipher: String? = nil, certificate: SMTPCertificate? = nil, ptrNames: [String] = [],
                ptrConfirmed: Bool? = nil, findings: [SMTPFinding] = [], totalMs: Double = 0) {
        self.host = host
        self.port = port
        self.preference = preference
        self.address = address
        self.mode = mode
        self.connectOutcome = connectOutcome
        self.steps = steps
        self.transcript = transcript
        self.banner = banner
        self.ehloGreeting = ehloGreeting
        self.extensions = extensions
        self.extensionsAfterTLS = extensionsAfterTLS
        self.tls = tls
        self.tlsVersion = tlsVersion
        self.cipher = cipher
        self.certificate = certificate
        self.ptrNames = ptrNames
        self.ptrConfirmed = ptrConfirmed
        self.findings = findings
        self.totalMs = totalMs
    }

    /// Constat le plus grave.
    public var verdict: SMTPFinding.Level { findings.map(\.level).max() ?? .ok }

    /// Toutes les extensions, sans doublon (après chiffrement d'abord).
    public var allExtensions: [SMTPExtension] {
        var seen = Set<String>()
        return (extensionsAfterTLS + extensions).filter { seen.insert($0.keyword).inserted }
    }

    public var software: String? { banner.flatMap { SMTPBanner.software(in: $0.firstLine) } }

    /// Échange complet en texte (« C: EHLO… », « S: 250-… »), pour le copier.
    public var transcriptText: String {
        transcript.map { line in
            switch line.direction {
            case .client: return "C: \(line.text)"
            case .server: return "S: \(line.text)"
            case .note: return "-- \(line.text)"
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Diagnostic

public enum SMTPDiagnostic {
    /// Ports proposés : réception entre serveurs, soumission (STARTTLS), soumission chiffrée.
    public static let ports: [UInt16] = [25, 587, 465]

    /// « exemple.ca » → ses MX par préférence ; un nom sans MX (ou une adresse) est testé tel quel.
    /// Un MX nul (« 0 . ») renvoie une liste vide : le domaine refuse tout courriel.
    public static func targets(for input: String, timeout: TimeInterval = 4) async throws -> [SMTPTarget] {
        var text = input.trimmingCharacters(in: .whitespaces).lowercased()
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, !text.hasPrefix("-"), (try? DNSMessageCodec.encodeName(text)) != nil else {
            throw SMTPError.invalidHostname(input)
        }
        if IPv4Address(text) != nil { return [SMTPTarget(host: text)] }
        let lookup = try await DNSLookup.resolve(text, type: .mx, timeout: timeout)
        let mx = mailExchangers(in: lookup.answerCount > 0 ? lookup.records : [])
        return mx ?? [SMTPTarget(host: text)]
    }

    /// MX d'une réponse, triés par préférence ; nil s'il n'y en a pas ; [] pour un MX nul.
    public static func mailExchangers(in records: [DNSRecord]) -> [SMTPTarget]? {
        let list = records.filter { $0.type == .mx }.compactMap { record -> SMTPTarget? in
            let fields = record.value.split(separator: " ")
            guard fields.count == 2, let preference = Int(fields[0]) else { return nil }
            var host = String(fields[1]).lowercased()
            if host.hasSuffix(".") { host.removeLast() }
            return SMTPTarget(host: host, preference: preference)
        }
        guard !list.isEmpty else { return nil }
        if list.count == 1, list[0].host.isEmpty { return [] }
        return list.filter { !$0.host.isEmpty }.sorted { ($0.preference ?? 0, $0.host) < ($1.preference ?? 0, $1.host) }
    }

    /// Diagnostic complet d'un serveur. Ne lève pas d'erreur : un échec devient une étape et un constat.
    /// `mode` force le mode de chiffrement (sinon : TLS direct au port 465, STARTTLS ailleurs).
    public static func run(host: String, port: UInt16, preference: Int? = nil, mode forcedMode: SMTPTLSMode? = nil,
                           timeout: TimeInterval = 10, checkPTR: Bool = true) async -> SMTPDiagnosticResult {
        let mode = forcedMode ?? SMTPTLSMode.forPort(port)
        let start = Date()
        var steps: [SMTPStep] = []
        var findings: [SMTPFinding] = []
        var target = host.trimmingCharacters(in: .whitespaces).lowercased()
        if target.hasSuffix(".") { target.removeLast() }

        // 1. Résolution du nom
        var address: String?
        if IPv4Address(target) != nil {
            address = target
        } else {
            let began = Date()
            do {
                let lookup = try await DNSLookup.resolve(target, type: .a, timeout: 4)
                let ips = lookup.records.filter { $0.type == .a }.map(\.value)
                address = ips.first
                steps.append(SMTPStep("Résolution DNS", durationMs: elapsed(began), status: ips.isEmpty ? .warning : .ok,
                                      detail: ips.isEmpty ? "Aucune adresse IPv4 (\(lookup.rcode))" : "\(target) → \(ips.joined(separator: ", "))"))
                if ips.isEmpty && lookup.rcode == "NXDOMAIN" {
                    findings.append(SMTPFinding(.critical, "Nom introuvable", "« \(target) » n’existe pas dans le DNS."))
                    return SMTPDiagnosticResult(host: target, port: port, preference: preference, mode: mode,
                                                connectOutcome: .failed("nom introuvable"), steps: steps,
                                                findings: findings, totalMs: elapsed(start))
                }
            } catch {
                steps.append(SMTPStep("Résolution DNS", durationMs: elapsed(began), status: .warning, detail: message(error)))
            }
        }

        // 2. Session SMTP
        let context = SMTPSessionContext(mode: mode, serverName: IPv4Address(target) == nil ? target : nil, start: start)
        let session = await openSession(endpointHost: address ?? target, port: port, context: context, timeout: timeout)
        let state = context.snapshot
        var connectOutcome = session.outcome

        if let connected = state.tcpConnectedAt {
            steps.append(SMTPStep("Connexion TCP", durationMs: connected.timeIntervalSince(state.connectStartedAt ?? start) * 1000,
                                  status: .ok, detail: "\(address ?? target) port \(port)"))
            connectOutcome = .connected
        } else {
            steps.append(SMTPStep("Connexion TCP", durationMs: nil, status: .failed, detail: "Port \(port)\u{00A0}: \(session.outcome.label)"))
        }
        if mode == .implicit, let began = state.tlsStartedAt {
            steps.append(tlsStep(state: state, began: began))
        }
        if let banner = state.banner, let at = state.bannerAt {
            let from = mode == .implicit ? (state.tlsReadyAt ?? state.tcpConnectedAt) : state.tcpConnectedAt
            steps.append(SMTPStep("Bannière", durationMs: from.map { at.timeIntervalSince($0) * 1000 },
                                  status: banner.code == 220 ? .ok : .failed, detail: "\(banner.code) \(banner.firstLine)"))
        } else if state.tcpConnectedAt != nil {
            steps.append(SMTPStep("Bannière", durationMs: nil, status: .failed, detail: state.failure ?? "Aucune bannière reçue"))
        }
        if let ehlo = state.ehlo, let sent = state.ehloSentAt, let at = state.ehloAt {
            let count = SMTPExtension.parse(ehlo: ehlo).count
            steps.append(SMTPStep("EHLO", durationMs: at.timeIntervalSince(sent) * 1000, status: ehlo.code == 250 ? .ok : .failed,
                                  detail: ehlo.code == 250 ? "\(count) extension\(count > 1 ? "s" : "") annoncée\(count > 1 ? "s" : "")"
                                                           : "\(ehlo.code) \(ehlo.firstLine)"))
        }
        if mode == .startTLS && state.ehlo?.code == 250 {
            if let reply = state.startTLSReply, let sent = state.startTLSSentAt, let at = state.startTLSAt {
                steps.append(SMTPStep("STARTTLS", durationMs: at.timeIntervalSince(sent) * 1000, status: reply.code == 220 ? .ok : .failed,
                                      detail: "\(reply.code) \(reply.firstLine)"))
            } else if state.tls == .notOffered {
                steps.append(SMTPStep("STARTTLS", durationMs: nil, status: .warning, detail: "Non proposé par le serveur"))
            }
            if let began = state.tlsStartedAt { steps.append(tlsStep(state: state, began: began)) }
        }
        for step in session.laterSteps { steps.append(step) }

        // 3. Port 25 bloqué ?
        if port == 25, session.outcome == .timedOut, state.tcpConnectedAt == nil {
            let probeHost = address ?? target
            async let p587 = probeTCP(host: probeHost, port: 587, timeout: 5)
            async let p465 = probeTCP(host: probeHost, port: 465, timeout: 5)
            let alternatives = await [(port: UInt16(587), outcome: p587), (port: UInt16(465), outcome: p465)]
            for alternative in alternatives {
                steps.append(SMTPStep("Contrôle du port \(alternative.port)", durationMs: nil,
                                      status: alternative.outcome == .connected ? .ok : .warning, detail: alternative.outcome.label))
            }
            if let finding = SMTPAssessment.port25Block(port25: .timedOut, alternatives: alternatives) { findings.append(finding) }
        } else if state.tcpConnectedAt == nil {
            switch session.outcome {
            case .refused:
                findings.append(SMTPFinding(.critical, "Connexion refusée sur le port \(port)", "Aucun service SMTP n’écoute sur ce port."))
            case .timedOut:
                findings.append(SMTPFinding(.critical, "Délai dépassé sur le port \(port)", "Le serveur ne répond pas, ou un pare-feu filtre ce port."))
            case .failed(let text):
                findings.append(SMTPFinding(.critical, "Connexion impossible", text))
            case .connected:
                break
            }
        }

        // 4. DNS inverse
        var ptrNames: [String] = []
        var ptrConfirmed: Bool?
        if checkPTR, let ip = address, IPv4Address(ip) != nil, state.tcpConnectedAt != nil {
            let began = Date()
            if let lookup = try? await DNSLookup.resolve(ip, type: .ptr, timeout: 4) {
                ptrNames = lookup.records.filter { $0.type == .ptr }.map { SMTPCertificate.normalize($0.value) }
                if let first = ptrNames.first, let forward = try? await DNSLookup.resolve(first, type: .a, timeout: 4) {
                    ptrConfirmed = forward.records.contains { $0.type == .a && $0.value == ip }
                }
            }
            steps.append(SMTPStep("DNS inverse (PTR)", durationMs: elapsed(began), status: ptrNames.isEmpty ? .warning : (ptrConfirmed == false ? .warning : .ok),
                                  detail: ptrNames.first.map { "\(ip) → \($0)" + (ptrConfirmed == true ? " ⇄ confirmé" : "") } ?? "Aucun PTR pour \(ip)"))
        }

        let extensions = mode == .startTLS ? (state.ehlo.map(SMTPExtension.parse(ehlo:)) ?? []) : []
        let afterTLS = session.ehloAfterTLS.map(SMTPExtension.parse(ehlo:)) ?? []
        if state.tcpConnectedAt != nil {
            findings += SMTPAssessment.findings(
                host: target, port: port, banner: state.banner,
                bannerDelayMs: state.bannerAt.flatMap { at in state.tcpConnectedAt.map { at.timeIntervalSince($0) * 1000 } },
                ehloGreeting: (session.ehloAfterTLS ?? state.ehlo)?.firstLine, extensions: extensions, extensionsAfterTLS: afterTLS,
                tls: state.tls, tlsVersion: state.tlsVersion, certificate: state.certificate,
                ptrNames: checkPTR ? ptrNames : nil, ptrConfirmed: ptrConfirmed)
        }
        findings.sort { $0.level > $1.level }

        return SMTPDiagnosticResult(
            host: target, port: port, preference: preference, address: address, mode: mode, connectOutcome: connectOutcome,
            steps: steps, transcript: context.snapshot.transcript, banner: state.banner,
            ehloGreeting: (session.ehloAfterTLS ?? state.ehlo)?.firstLine, extensions: extensions, extensionsAfterTLS: afterTLS,
            tls: state.tls, tlsVersion: state.tlsVersion, cipher: state.cipher, certificate: state.certificate,
            ptrNames: ptrNames, ptrConfirmed: ptrConfirmed, findings: findings, totalMs: elapsed(start))
    }

    private static func tlsStep(state: SMTPSessionState, began: Date) -> SMTPStep {
        if let ready = state.tlsReadyAt {
            let detail = [state.tlsVersion, state.cipher].compactMap { $0 }.joined(separator: " · ")
            return SMTPStep("Poignée TLS", durationMs: ready.timeIntervalSince(began) * 1000, status: .ok,
                            detail: detail.isEmpty ? "Réussie" : detail)
        }
        if case .failed(let reason) = state.tls {
            return SMTPStep("Poignée TLS", durationMs: nil, status: .failed, detail: reason)
        }
        return SMTPStep("Poignée TLS", durationMs: nil, status: .failed, detail: state.failure ?? "Inachevée")
    }

    static func elapsed(_ date: Date) -> Double { Date().timeIntervalSince(date) * 1000 }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Session

    struct SessionOutcome {
        var outcome: SMTPConnectOutcome
        var ehloAfterTLS: SMTPReply?
        var laterSteps: [SMTPStep]
    }

    /// Ouvre la connexion (framer + TLS), attend la fin de la partie en clair, puis termine
    /// la session (EHLO chiffré, QUIT).
    static func openSession(endpointHost: String, port: UInt16, context: SMTPSessionContext,
                            timeout: TimeInterval) async -> SessionOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return SessionOutcome(outcome: .failed("port invalide"), ehloAfterTLS: nil, laterSteps: [])
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let framerOptions = NWProtocolFramer.Options(definition: SMTPStartTLSFramer.definition)
        framerOptions[SMTPStartTLSFramer.contextKey] = context
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        let queue = DispatchQueue(label: "netscope.smtp")
        context.tlsOptions = makeTLSOptions(context: context, queue: queue)

        let connection = NWConnection(host: NWEndpoint.Host(endpointHost), port: nwPort, using: parameters)
        context.update { $0.connectStartedAt = Date() }
        let channel = SMTPChannel(connection: connection, queue: queue, context: context)
        defer { connection.cancel() }

        // Partie en clair menée par le framer : bannière, EHLO, STARTTLS (au plus 3 attentes).
        let ready = await channel.waitReady(timeout: timeout * 3 + 2)
        switch ready {
        case .failure(let outcome):
            let state = context.snapshot
            if state.tlsStartedAt != nil, state.tlsReadyAt == nil {
                let reason = context.snapshot.failure ?? outcome.label
                context.update { $0.tls = .failed(reason) }
            }
            if state.tcpConnectedAt != nil, state.failure == nil {
                context.update { $0.failure = outcome == .timedOut ? "Délai dépassé" : outcome.label }
            }
            context.note(state.tcpConnectedAt == nil ? "Connexion impossible : \(outcome.label)" : "Session interrompue : \(outcome.label)")
            return SessionOutcome(outcome: outcome, ehloAfterTLS: nil, laterSteps: [])
        case .success:
            break
        }

        var later: [SMTPStep] = []
        var ehloAfterTLS: SMTPReply?
        let state = context.snapshot
        let encrypted = state.tlsReadyAt != nil
        do {
            if state.mode == .implicit {
                // Port 465 : la bannière arrive après la poignée TLS.
                let banner = try await channel.readReply(timeout: timeout)
                context.update {
                    $0.banner = banner
                    $0.bannerAt = Date()
                }
                guard banner.code == 220 else { throw ToolError.processFailed("bannière refusée") }
            }
            if encrypted, context.snapshot.banner?.code == 220 {
                let name = ehloName(for: connection.currentPath?.localEndpoint)
                let sent = Date()
                try await channel.send(.ehlo(name))
                let reply = try await channel.readReply(timeout: timeout)
                ehloAfterTLS = reply
                if state.mode == .implicit {
                    context.update {
                        $0.ehlo = reply
                        $0.ehloSentAt = sent
                        $0.ehloAt = Date()
                    }
                } else {
                    let count = SMTPExtension.parse(ehlo: reply).count
                    later.append(SMTPStep("EHLO (chiffré)", durationMs: elapsed(sent), status: reply.code == 250 ? .ok : .warning,
                                          detail: "\(count) extension\(count > 1 ? "s" : "")"))
                }
            }
            let sent = Date()
            try await channel.send(.quit)
            if let reply = try? await channel.readReply(timeout: min(timeout, 5)) {
                later.append(SMTPStep("QUIT", durationMs: elapsed(sent), status: .ok, detail: "\(reply.code) \(reply.firstLine)"))
            } else {
                later.append(SMTPStep("QUIT", durationMs: nil, status: .warning, detail: "Connexion fermée sans réponse"))
            }
        } catch {
            if state.mode == .implicit, context.snapshot.banner == nil {
                context.update { $0.failure = message(error) }
            } else {
                later.append(SMTPStep("Fin de session", durationMs: nil, status: .warning, detail: message(error)))
            }
            context.note("Session interrompue : \(message(error))")
        }
        return SessionOutcome(outcome: .connected, ehloAfterTLS: ehloAfterTLS, laterSteps: later)
    }

    /// Nom annoncé par EHLO : l'adresse locale entre crochets (« [192.168.1.20] »), forme
    /// prévue par la RFC 5321 pour un poste sans nom public.
    static func ehloName(for endpoint: NWEndpoint?) -> String {
        if case .hostPort(let host, _)? = endpoint, case .ipv4(let address) = host {
            let bytes = [UInt8](address.rawValue)
            if bytes.count == 4 { return "[\(bytes.map(String.init).joined(separator: "."))]" }
        }
        return "[127.0.0.1]"
    }

    /// Options TLS : la chaîne est examinée (certificat, confiance) mais toujours acceptée, pour
    /// pouvoir décrire un certificat expiré ou auto-signé au lieu d'échouer sans rien dire.
    static func makeTLSOptions(context: SMTPSessionContext, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        if let name = context.serverName {
            sec_protocol_options_set_tls_server_name(security, name)
        }
        sec_protocol_options_set_verify_block(security, { metadata, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let certificate = SMTPCertificateReader.read(trust: secTrust)
            let version = SMTPCertificateReader.versionName(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata))
            let cipher = SMTPCertificateReader.cipherName(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata))
            context.update {
                $0.certificate = certificate
                $0.tlsVersion = version
                $0.cipher = cipher
            }
            complete(true)
        }, queue)
        return options
    }

    /// Simple essai de connexion TCP (contrôle du port 25 bloqué).
    public static func probeTCP(host: String, port: UInt16, timeout: TimeInterval) async -> SMTPConnectOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failed("port invalide") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        let queue = DispatchQueue(label: "netscope.smtp.probe")
        defer { connection.cancel() }
        return await withCheckedContinuation { continuation in
            let once = ToolOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: .connected) }
                case .waiting(let error), .failed(let error):
                    if once.claim() { continuation.resume(returning: outcome(of: error)) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    static func outcome(of error: NWError) -> SMTPConnectOutcome {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .ETIMEDOUT: return .timedOut
            case .EHOSTUNREACH, .ENETUNREACH: return .failed("hôte injoignable")
            case .ECONNRESET: return .failed("connexion fermée par le serveur")
            default: return .failed(String(cString: strerror(code.rawValue)))
            }
        case .dns: return .failed("nom introuvable")
        case .tls(let status): return .failed("échec TLS (\(status))")
        default: return .failed(error.localizedDescription)
        }
    }
}

// MARK: - État partagé de la session

/// Ce que la session a vu, rempli par le framer (file de la connexion) et par la tâche du diagnostic.
struct SMTPSessionState {
    var mode: SMTPTLSMode
    var connectStartedAt: Date?
    var tcpConnectedAt: Date?
    var banner: SMTPReply?
    var bannerAt: Date?
    var ehlo: SMTPReply?
    var ehloSentAt: Date?
    var ehloAt: Date?
    var startTLSReply: SMTPReply?
    var startTLSSentAt: Date?
    var startTLSAt: Date?
    var tlsStartedAt: Date?
    var tlsReadyAt: Date?
    var tls: SMTPTLSState = .notReached
    var tlsVersion: String?
    var cipher: String?
    var certificate: SMTPCertificate?
    var failure: String?
    var transcript: [SMTPTranscriptLine] = []
}

final class SMTPSessionContext: @unchecked Sendable {
    let start: Date
    let serverName: String?
    /// Options TLS ajoutées par le framer au-dessus de lui-même.
    var tlsOptions: NWProtocolTLS.Options?
    private let box: ToolBox<SMTPSessionState>

    init(mode: SMTPTLSMode, serverName: String?, start: Date) {
        self.start = start
        self.serverName = serverName
        box = ToolBox(SMTPSessionState(mode: mode))
    }

    var snapshot: SMTPSessionState { box.value }

    func update(_ body: (inout SMTPSessionState) -> Void) { box.mutate(body) }

    func log(_ direction: SMTPTranscriptLine.Direction, _ text: String) {
        let offset = Date().timeIntervalSince(start) * 1000
        box.mutate { state in
            state.transcript.append(SMTPTranscriptLine(id: state.transcript.count, direction: direction, text: text, offsetMs: offset))
        }
    }

    func log(_ reply: SMTPReply) {
        for line in reply.rawLines { log(.server, line) }
    }

    func note(_ text: String) { log(.note, text) }
}

// MARK: - Framer : partie en clair puis STARTTLS

final class SMTPStartTLSFramer: NWProtocolFramerImplementation {
    static let label = "NetScope SMTP"
    static let definition = NWProtocolFramer.Definition(implementation: SMTPStartTLSFramer.self)
    static let contextKey = "netscope.smtp.context"

    private enum Phase { case banner, ehlo, startTLS, done }

    private var context: SMTPSessionContext?
    private var parser = SMTPReplyParser()
    private var phase = Phase.banner
    private var ehloName = "[127.0.0.1]"

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        context = framer.options[Self.contextKey] as? SMTPSessionContext
        ehloName = SMTPDiagnostic.ehloName(for: framer.local)
        context?.update { $0.tcpConnectedAt = Date() }
        context?.note("Connecté à \(framer.remote.map { "\($0)" } ?? "?")")
        if context?.snapshot.mode == .implicit {
            // Port 465 : TLS tout de suite, la session SMTP se fait ensuite au-dessus.
            startTLS(framer)
        }
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
        guard phase != .done else { return 0 }
        if !bytes.isEmpty {
            do {
                for reply in try parser.feed(bytes) {
                    advance(framer, reply)
                    if phase == .done { break }
                }
            } catch {
                context?.update { $0.failure = SMTPDiagnostic.message(error) }
                fail(framer)
                return 0
            }
        }
        if closed && phase != .done {
            context?.update { $0.failure = "Connexion fermée par le serveur" }
            fail(framer)
        }
        return 0
    }

    private func advance(_ framer: NWProtocolFramer.Instance, _ reply: SMTPReply) {
        guard let context else { return }
        context.log(reply)
        let now = Date()
        switch phase {
        case .banner:
            context.update {
                $0.banner = reply
                $0.bannerAt = now
            }
            guard reply.code == 220 else { return finishInClear(framer) }
            send(.ehlo(ehloName), framer)
            context.update { $0.ehloSentAt = Date() }
            phase = .ehlo
        case .ehlo:
            context.update {
                $0.ehlo = reply
                $0.ehloAt = now
            }
            guard reply.code == 250 else { return finishInClear(framer) }
            guard SMTPExtension.parse(ehlo: reply).contains("STARTTLS") else {
                context.update { $0.tls = .notOffered }
                return finishInClear(framer)
            }
            send(.startTLS, framer)
            context.update { $0.startTLSSentAt = Date() }
            phase = .startTLS
        case .startTLS:
            context.update {
                $0.startTLSReply = reply
                $0.startTLSAt = now
            }
            guard reply.code == 220 else {
                context.update { $0.tls = .failed("STARTTLS refusé\u{00A0}: \(reply.code) \(reply.firstLine)") }
                return finishInClear(framer)
            }
            startTLS(framer)
        case .done:
            break
        }
    }

    private func send(_ command: SMTPCommand, _ framer: NWProtocolFramer.Instance) {
        context?.log(.client, command.line)
        framer.writeOutput(data: Data(command.bytes))
    }

    /// Ajoute TLS au-dessus du framer, puis se déclare prêt : la poignée TLS démarre.
    private func startTLS(_ framer: NWProtocolFramer.Instance) {
        phase = .done
        guard let context, let options = context.tlsOptions else { return fail(framer) }
        do {
            try framer.prependApplicationProtocol(options: options)
        } catch {
            context.update { $0.tls = .failed("TLS impossible à démarrer") }
            return fail(framer)
        }
        context.update { $0.tlsStartedAt = Date() }
        context.note("Poignée TLS…")
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.async { framer.markReady() }
    }

    /// Pas de chiffrement (refus, STARTTLS absent) : la connexion devient prête en clair pour QUIT.
    private func finishInClear(_ framer: NWProtocolFramer.Instance) {
        phase = .done
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.markReady()
    }

    private func fail(_ framer: NWProtocolFramer.Instance) {
        phase = .done
        framer.markFailed(error: .posix(.ECONNABORTED))
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

    func cleanup(framer: NWProtocolFramer.Instance) {}
}

// MARK: - Échange après la partie en clair

/// Envoi de commandes et lecture des réponses sur la connexion prête (chiffrée ou non).
final class SMTPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let context: SMTPSessionContext
    private var parser = SMTPReplyParser()
    private var pending: [SMTPReply] = []

    init(connection: NWConnection, queue: DispatchQueue, context: SMTPSessionContext) {
        self.connection = connection
        self.queue = queue
        self.context = context
    }

    enum Ready { case success, failure(SMTPConnectOutcome) }

    func waitReady(timeout: TimeInterval) async -> Ready {
        let context = self.context
        let connection = self.connection
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            let once = ToolOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if context.snapshot.tlsStartedAt != nil {
                        context.update {
                            $0.tlsReadyAt = Date()
                            $0.tls = .succeeded
                        }
                        let state = context.snapshot
                        context.note("Chiffré\u{00A0}: " + ([state.tlsVersion, state.cipher].compactMap { $0 }.joined(separator: ", ")))
                    }
                    if once.claim() { continuation.resume(returning: .success) }
                case .waiting(let error), .failed(let error):
                    if case .tls(let status) = error, context.snapshot.tlsStartedAt != nil {
                        context.update { $0.tls = .failed("Poignée TLS refusée (\(status))") }
                    }
                    if once.claim() { continuation.resume(returning: .failure(SMTPDiagnostic.outcome(of: error))) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .failure(.timedOut)) }
            }
        }
    }

    func send(_ command: SMTPCommand) async throws {
        context.log(.client, command.line)
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(command.bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: ToolError.socket(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    func readReply(timeout: TimeInterval) async throws -> SMTPReply {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ToolError.timeout(timeout) }
            let chunk = try await receive(timeout: remaining)
            pending += try parser.feed([UInt8](chunk))
        }
        let reply = pending.removeFirst()
        context.log(reply)
        return reply
    }

    private func receive(timeout: TimeInterval) async throws -> Data {
        let connection = self.connection
        let queue = self.queue
        return try await withCheckedThrowingContinuation { continuation in
            let once = ToolOnce()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                guard once.claim() else { return }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: ToolError.socket(error.localizedDescription))
                } else {
                    continuation.resume(throwing: ToolError.socket(complete ? "connexion fermée par le serveur" : "réponse vide"))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: ToolError.timeout(timeout)) }
            }
        }
    }
}

// MARK: - Lecture du certificat

enum SMTPCertificateReader {
    static func read(trust: SecTrust) -> SMTPCertificate? {
        // Confiance de la chaîne seule (sans nom d'hôte) : la correspondance du nom est jugée à part.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore,
                    kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName] as CFArray
        let values = (SecCertificateCopyValues(leaf, keys, nil) as? [String: Any]) ?? [:]
        func property(_ key: CFString) -> Any? {
            (values[key as String] as? [String: Any])?[kSecPropertyKeyValue as String]
        }
        func names(_ key: CFString) -> [(String, String)] {
            ((property(key) as? [[String: Any]]) ?? []).compactMap { entry in
                guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                      let value = entry[kSecPropertyKeyValue as String] as? String else { return nil }
                return (label, value)
            }
        }
        func date(_ key: CFString) -> Date? {
            (property(key) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        func summary(_ entries: [(String, String)]) -> String {
            let cn = entries.first { $0.0 == "2.5.4.3" }?.1
            let org = entries.first { $0.0 == "2.5.4.10" }?.1
            return [cn, org].compactMap { $0 }.joined(separator: " · ")
        }
        let subjectEntries = names(kSecOIDX509V1SubjectName)
        let commonName = subjectEntries.first { $0.0 == "2.5.4.3" }?.1
        var dnsNames = names(kSecOIDSubjectAltName).filter { $0.0.localizedCaseInsensitiveContains("DNS") }.map(\.1)
        if dnsNames.isEmpty, let commonName { dnsNames = [commonName] }
        var selfSigned = false
        if let subject = SecCertificateCopyNormalizedSubjectSequence(leaf), let issuer = SecCertificateCopyNormalizedIssuerSequence(leaf) {
            selfSigned = (subject as Data) == (issuer as Data)
        }
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? commonName ?? ""
        return SMTPCertificate(subject: subject, issuer: summary(names(kSecOIDX509V1IssuerName)),
                               notBefore: date(kSecOIDX509V1ValidityNotBefore), notAfter: date(kSecOIDX509V1ValidityNotAfter),
                               dnsNames: dnsNames, isTrusted: trusted, isSelfSigned: selfSigned,
                               trustError: trusted ? nil : error.map { CFErrorCopyDescription($0) as String })
    }

    static func versionName(_ version: tls_protocol_version_t) -> String? {
        switch version {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        case .TLSv11: return "TLS 1.1"
        case .TLSv10: return "TLS 1.0"
        default: return nil
        }
    }

    static func cipherName(_ suite: tls_ciphersuite_t) -> String? {
        switch suite {
        case .AES_128_GCM_SHA256: return "AES-128-GCM"
        case .AES_256_GCM_SHA384: return "AES-256-GCM"
        case .CHACHA20_POLY1305_SHA256: return "ChaCha20-Poly1305"
        case .ECDHE_RSA_WITH_AES_128_GCM_SHA256, .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256: return "ECDHE · AES-128-GCM"
        case .ECDHE_RSA_WITH_AES_256_GCM_SHA384, .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384: return "ECDHE · AES-256-GCM"
        case .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256, .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256: return "ECDHE · ChaCha20-Poly1305"
        default: return nil
        }
    }
}
