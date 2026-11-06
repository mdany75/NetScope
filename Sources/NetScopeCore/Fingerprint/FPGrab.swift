import Foundation
import Network
import Security

// Note 68 : lecture des services pendant un scan de ports demandé par l'utilisateur (case « Détection
// de services »). Rien d'autre n'est envoyé que ce que le scan envoyait déjà (HEAD sur les ports HTTP),
// plus, sur les mêmes ports ouverts : une poignée de main TLS (certificat, puis HEAD sur un port web)
// et une négociation SMB2 seule sur 445 (sans session ni authentification).

extension PortScanner {
    /// Ports TLS dont on lit le certificat (et l'en-tête Server pour les ports web).
    public static let tlsBannerPorts: Set<UInt16> = [443, 465, 636, 993, 995, 4443, 5001, 8443, 9443, 10443]

    /// Lit ce que le service répond, selon la stratégie du port, puis appelle `completion` une fois.
    static func grabService(_ connection: NWConnection, host: String, port: UInt16, strategy: BannerStrategy,
                            timeout: TimeInterval, queue: DispatchQueue,
                            completion: @escaping @Sendable (String?, FPServiceObservation?) -> Void) {
        let once = ToolOnce()
        let deliver: @Sendable (String?, FPServiceObservation?) -> Void = { banner, observation in
            if once.claim() { completion(banner, observation) }
        }
        switch strategy {
        case .none:
            deliver(nil, nil)
        case .listen, .httpHead:
            queue.asyncAfter(deadline: .now() + timeout) { deliver(nil, nil) }
            let receive = {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, !data.isEmpty else { return deliver(nil, nil) }
                    let http = strategy == .httpHead
                    let observation = http ? FPBanner.httpObservation(port: port, data: data)
                        : FPBanner.listenObservation(port: port, data: data)
                    deliver(cleanBanner(data, http: http), observation)
                }
            }
            if strategy == .httpHead {
                let request = "HEAD / HTTP/1.0\r\nHost: \(host)\r\nUser-Agent: NetScope\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in receive() })
            } else {
                receive()
            }
        case .smb:
            queue.asyncAfter(deadline: .now() + timeout) { deliver(nil, nil) }
            connection.send(content: FPSMB.negotiateRequest(), completion: .contentProcessed { _ in
                connection.receive(minimumIncompleteLength: 4, maximumLength: 8192) { data, _, _, _ in
                    guard let data, let negotiation = FPSMB.parseNegotiateResponse(data) else { return deliver(nil, nil) }
                    let label = negotiation.smb1Only ? "SMB1 seulement"
                        : negotiation.dialect.map { FPSMB.dialectLabel($0) + (negotiation.sambaHint ? " · Samba" : "") }
                    deliver(label, FPSMB.observation(port: port, negotiation))
                }
            })
        case .tls:
            // Le port est ouvert : une seconde connexion, en TLS, lit le certificat (la première, sans
            // TLS, reste ouverte jusqu'à la fin pour que le scan ne la croie pas filtrée).
            tlsGrab(host: host, port: port, timeout: timeout, sendHead: webScheme(for: port) == "https") { banner, observation in
                deliver(banner, observation)
            }
        }
    }

    /// Poignée de main TLS (tout certificat accepté, TLS 1.0 et plus), puis HEAD sur un port web.
    static func tlsGrab(host: String, port: UInt16, timeout: TimeInterval, sendHead: Bool,
                        completion: @escaping @Sendable (String?, FPServiceObservation?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return completion(nil, nil) }
        let queue = DispatchQueue(label: "netscope.portscan.tls.\(port)")
        let leaf = ToolBox<Data?>(nil)
        let tls = NWProtocolTLS.Options()
        // TLS 1.0 accepté (vieilles imprimantes, caméras) : seule la lecture du certificat compte ici.
        if let oldest = tls_protocol_version_t(rawValue: 0x0301) {
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, oldest)
        }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let first = chain.first {
                let der = SecCertificateCopyData(first) as Data
                leaf.mutate { $0 = der }
            }
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tls, tcp: tcp))
        let once = ToolOnce()
        let finish: @Sendable (Data?) -> Void = { response in
            guard once.claim() else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            let certificate = leaf.value.flatMap { FPCertificate.parse(der: $0) }
            var observation = response.flatMap { FPBanner.httpObservation(port: port, data: $0, tls: true) }
                ?? FPServiceObservation(port: port, tls: true, observedAt: Date())
            observation.tls = true
            if let certificate {
                observation.certSubject = certificate.subject.isEmpty ? nil : certificate.subject
                observation.certIssuer = certificate.issuer.isEmpty ? nil : certificate.issuer
                observation.certSelfSigned = certificate.isSelfSigned
                observation.certNotAfter = certificate.notAfter
            }
            guard certificate != nil || response != nil else { return completion(nil, nil) }
            var parts: [String] = []
            if let status = observation.httpStatus { parts.append(status) }
            if let server = observation.httpServer { parts.append("Server: " + server) }
            if let subject = certificate?.subject, !subject.isEmpty {
                parts.append("TLS " + (subject.organization ?? subject.commonName ?? ""))
            }
            completion(parts.isEmpty ? nil : parts.joined(separator: " · "), observation)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard sendHead else { return finish(nil) }
                let request = "HEAD / HTTP/1.0\r\nHost: \(host)\r\nUser-Agent: NetScope\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in finish(data) }
                })
            case .failed, .cancelled:
                finish(nil)
            case .waiting:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout + 1) { finish(nil) }
    }
}
