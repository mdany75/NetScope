import Foundation
import Network

// Note 6 : « Tester le serveur » RustDesk, seulement sur clic (jamais en démonstration ni dans
// les tests, sauf vers 127.0.0.1) : connexions TCP vers 21115, 21116 et 21117 avec leur temps de
// réponse, un vrai échange du protocole rendezvous sur 21115 (TestNatRequest → TestNatResponse) et
// sur UDP 21116 (RegisterPeer d'un ID impossible → RegisterPeerResponse, rien n'est enregistré par
// hbbs). Messages protobuf de hbb_common/protos/rendezvous.proto, écrits à la main (aucun paquet tiers).

// MARK: - Format des messages

/// Trames et messages du protocole rendezvous de RustDesk.
public enum RustDeskWire {
    /// Champs de RendezvousMessage (oneof union).
    public static let registerPeerField = 6
    public static let registerPeerResponseField = 7
    public static let testNatRequestField = 20
    public static let testNatResponseField = 21

    /// En-tête de longueur de hbb_common (BytesCodec) : 1 à 4 octets petit-boutistes, les deux
    /// bits de poids faible donnent la taille de l'en-tête moins un.
    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        var header: [UInt8]
        if n <= 0x3F {
            header = [UInt8(n << 2)]
        } else if n <= 0x3FFF {
            let h = UInt16(n << 2) | 0x1
            header = [UInt8(h & 0xFF), UInt8(h >> 8)]
        } else if n <= 0x3F_FFFF {
            let h = UInt32(n << 2) | 0x2
            header = [UInt8(h & 0xFF), UInt8((h >> 8) & 0xFF), UInt8((h >> 16) & 0xFF)]
        } else {
            let h = UInt32(n << 2) | 0x3
            header = [UInt8(h & 0xFF), UInt8((h >> 8) & 0xFF), UInt8((h >> 16) & 0xFF), UInt8(h >> 24)]
        }
        return header + payload
    }

    /// Première trame complète ; nil si les octets ne suffisent pas encore.
    public static func unframe(_ bytes: [UInt8]) -> (payload: [UInt8], consumed: Int)? {
        guard let first = bytes.first else { return nil }
        let headerLength = Int(first & 0x3) + 1
        guard bytes.count >= headerLength else { return nil }
        var value = 0
        for index in 0..<headerLength { value |= Int(bytes[index]) << (8 * index) }
        let length = value >> 2
        guard bytes.count >= headerLength + length else { return nil }
        return (Array(bytes[headerLength..<(headerLength + length)]), headerLength + length)
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// Champ de longueur variable (type 2).
    static func lengthDelimited(_ field: Int, _ body: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(body.count)) + body
    }

    /// RendezvousMessage { test_nat_request: TestNatRequest { serial: 0 } }, avec son en-tête (TCP).
    public static var testNatRequest: [UInt8] {
        frame(lengthDelimited(testNatRequestField, []))
    }

    /// RendezvousMessage { register_peer: RegisterPeer { id } }, sans en-tête (UDP : un datagramme).
    public static func registerPeer(id: String) -> [UInt8] {
        let body = lengthDelimited(1, Array(id.utf8))
        return lengthDelimited(registerPeerField, body)
    }

    /// Champs de premier niveau d'un message : numéro et contenu (types 0 et 2 seulement).
    static func fields(_ bytes: [UInt8]) -> [(field: Int, varint: UInt64?, body: [UInt8]?)]? {
        var index = 0
        var result: [(Int, UInt64?, [UInt8]?)] = []
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            let field = Int(key >> 3)
            switch key & 0x7 {
            case 0:
                guard let value = readVarint(bytes, &index) else { return nil }
                result.append((field, value, nil))
            case 2:
                guard let length = readVarint(bytes, &index), index + Int(length) <= bytes.count else { return nil }
                result.append((field, nil, Array(bytes[index..<(index + Int(length))])))
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
            default:
                return nil
            }
        }
        return result
    }

    /// Numéro du message reçu (champ du oneof de RendezvousMessage).
    public static func messageField(_ payload: [UInt8]) -> Int? {
        fields(payload)?.first?.field
    }

    /// Port source vu par le serveur dans un TestNatResponse (0 s'il est absent) ; nil si ce
    /// n'est pas un TestNatResponse.
    public static func testNatResponsePort(_ payload: [UInt8]) -> Int? {
        guard let top = fields(payload), let message = top.first(where: { $0.field == testNatResponseField }) else { return nil }
        let inner = fields(message.body ?? []) ?? []
        return Int(inner.first(where: { $0.field == 1 })?.varint ?? 0)
    }
}

// MARK: - Test du serveur

/// Résultat d'une vérification du serveur.
public struct RustDeskProbe: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case natTest, idServer, udp, relay
    }

    public var id: String { kind.rawValue }
    public var kind: Kind
    public var endpoint: RustDeskEndpoint
    /// Connexion établie (TCP) ou réponse reçue (UDP).
    public var ok: Bool
    /// Temps de réponse (connexion TCP, ou aller-retour du message), en millisecondes.
    public var millis: Int?
    /// TCP 21115 : un TestNatResponse a été reçu ; port source vu par le serveur.
    public var protocolAnswer: Bool
    public var observedPort: Int?

    public init(kind: Kind, endpoint: RustDeskEndpoint, ok: Bool, millis: Int? = nil, protocolAnswer: Bool = false, observedPort: Int? = nil) {
        self.kind = kind
        self.endpoint = endpoint
        self.ok = ok
        self.millis = millis
        self.protocolAnswer = protocolAnswer
        self.observedPort = observedPort
    }

    /// « TCP 21116 », « UDP 21116 ».
    public var portLabel: String { (kind == .udp ? "UDP " : "TCP ") + String(endpoint.port) }

    public var role: String {
        switch kind {
        case .natTest: return "Test NAT (hbbs)"
        case .idServer: return "Serveur d’ID (hbbs)"
        case .udp: return "Présence et percée NAT (hbbs)"
        case .relay: return "Relais (hbbr)"
        }
    }

    /// Phrase claire du résultat.
    public var summary: String {
        let time = millis.map { " en \($0)\u{00A0}ms" } ?? ""
        switch (kind, ok) {
        case (.natTest, true):
            return protocolAnswer
                ? "Test NAT\u{00A0}: le serveur a répondu\(time)" + (observedPort.map { " (il voit ce Mac sur le port \($0))" } ?? "")
                : "Port \(endpoint.port) ouvert\(time), mais sans réponse RustDesk"
        case (.idServer, true): return "Serveur d’ID joignable\(time)"
        case (.udp, true): return "UDP \(endpoint.port)\u{00A0}: le serveur d’ID a répondu\(time)"
        case (.relay, true): return "Relais joignable\(time)"
        case (.natTest, false): return "Test NAT injoignable\u{00A0}: vérifier le VIP TCP \(endpoint.port) sur la FortiGate"
        case (.idServer, false): return "Serveur d’ID injoignable\u{00A0}: vérifier le VIP TCP \(endpoint.port) et le conteneur hbbs"
        case (.udp, false): return "Aucune réponse en UDP \(endpoint.port)\u{00A0}: vérifier le VIP UDP \(endpoint.port) (l’UDP ne se confirme que par une réponse)"
        case (.relay, false): return "Relais injoignable\u{00A0}: vérifier le VIP TCP \(endpoint.port) sur la FortiGate et le conteneur hbbr"
        }
    }

    public var level: RustDeskFinding.Level {
        if !ok { return kind == .udp ? .warning : .error }
        return kind == .natTest && !protocolAnswer ? .warning : .ok
    }
}

public enum RustDeskServerTest {
    /// ID impossible pour un vrai poste (le point n'est pas permis dans un ID RustDesk) : hbbs
    /// répond « clé demandée » sans rien enregistrer ni toucher à un autre pair.
    public static func probeID(suffix: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        "netscope.sonde." + suffix
    }

    /// Vérifications à faire (dans l'ordre affiché).
    public static func plan(_ settings: RustDeskServerSettings) -> [(RustDeskProbe.Kind, RustDeskEndpoint)] {
        var result: [(RustDeskProbe.Kind, RustDeskEndpoint)] = []
        if let nat = settings.natTestEndpoint { result.append((.natTest, nat)) }
        if let id = settings.idEndpoint {
            result.append((.idServer, id))
            result.append((.udp, id))
        }
        if let relay = settings.relayEndpoint { result.append((.relay, relay)) }
        return result
    }

    /// Lance toutes les vérifications en parallèle (réseau : seulement sur demande de l'utilisateur).
    public static func run(_ settings: RustDeskServerSettings, timeout: TimeInterval = 3) async -> [RustDeskProbe] {
        let steps = plan(settings)
        return await withTaskGroup(of: (Int, RustDeskProbe).self) { group in
            for (index, step) in steps.enumerated() {
                group.addTask { (index, await probe(step.0, step.1, timeout: timeout)) }
            }
            var results: [(Int, RustDeskProbe)] = []
            for await item in group { results.append(item) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public static func probe(_ kind: RustDeskProbe.Kind, _ endpoint: RustDeskEndpoint, timeout: TimeInterval = 3) async -> RustDeskProbe {
        switch kind {
        case .natTest:
            let exchange = await RustDeskExchange.run(endpoint, udp: false, payload: RustDeskWire.testNatRequest, timeout: timeout)
            let payload = exchange.reply.flatMap { RustDeskWire.unframe($0)?.payload }
            let port = payload.flatMap { RustDeskWire.testNatResponsePort($0) }
            return RustDeskProbe(kind: kind, endpoint: endpoint, ok: exchange.connected, millis: port != nil ? exchange.replyMillis : exchange.connectMillis,
                                 protocolAnswer: port != nil, observedPort: port.flatMap { $0 > 0 ? $0 : nil })
        case .idServer, .relay:
            let exchange = await RustDeskExchange.run(endpoint, udp: false, payload: nil, timeout: timeout)
            return RustDeskProbe(kind: kind, endpoint: endpoint, ok: exchange.connected, millis: exchange.connectMillis)
        case .udp:
            let exchange = await RustDeskExchange.run(endpoint, udp: true, payload: RustDeskWire.registerPeer(id: probeID()), timeout: timeout)
            let field = exchange.reply.flatMap { RustDeskWire.messageField($0) }
            // Toute réponse rendezvous prouve le passage de l'UDP (RegisterPeerResponse, ou ConfigUpdate avant elle).
            return RustDeskProbe(kind: kind, endpoint: endpoint, ok: field != nil, millis: field != nil ? exchange.replyMillis : nil,
                                 protocolAnswer: field != nil)
        }
    }
}

/// Une connexion, un message envoyé et une réponse attendue (TCP ou UDP).
struct RustDeskExchange: Sendable {
    var connected = false
    var connectMillis: Int?
    var reply: [UInt8]?
    var replyMillis: Int?

    static func run(_ endpoint: RustDeskEndpoint, udp: Bool, payload: [UInt8]?, timeout: TimeInterval) async -> RustDeskExchange {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else { return RustDeskExchange() }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: udp ? .udp : .tcp)
            let queue = DispatchQueue(label: "netscope.rustdesk.test")
            let once = OnceFlag()
            let start = DispatchTime.now()
            let state = RustDeskExchangeState()
            func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }
            @Sendable func finish() {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: state.result)
            }
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 2_048) { data, _, complete, error in
                    if let data, !data.isEmpty {
                        state.append([UInt8](data), millis: elapsed())
                        // TCP : attendre une trame complète ; UDP : un datagramme suffit.
                        if udp || RustDeskWire.unframe(state.result.reply ?? []) != nil { return finish() }
                    }
                    if error != nil || complete { return finish() }
                    receive()
                }
            }
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    state.markConnected(millis: elapsed())
                    guard let payload else { return finish() }
                    connection.send(content: Data(payload), completion: .contentProcessed { error in
                        if error != nil { finish() } else { receive() }
                    })
                case .failed, .cancelled:
                    finish()
                case .waiting:
                    // Refus (RST) ou réseau absent : inutile d'attendre la fin du délai.
                    if !udp { finish() }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}

/// État partagé d'un échange (file série de la connexion, verrou par prudence).
final class RustDeskExchangeState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RustDeskExchange()

    var result: RustDeskExchange {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func markConnected(millis: Int) {
        lock.lock(); defer { lock.unlock() }
        value.connected = true
        value.connectMillis = millis
    }

    func append(_ bytes: [UInt8], millis: Int) {
        lock.lock(); defer { lock.unlock() }
        if value.replyMillis == nil { value.replyMillis = millis }
        value.reply = (value.reply ?? []) + bytes
    }
}

// MARK: - VIP de la FortiGate

/// Adresse IP virtuelle (redirection de port) lue dans /api/v2/cmdb/firewall/vip.
public struct RustDeskVIP: Equatable, Sendable {
    public var name: String
    public var externalIP: String
    public var mappedIP: String
    public var portForward: Bool
    /// « tcp », « udp », « sctp »… (tcp par défaut dans FortiOS).
    public var proto: String
    public var externalPorts: ClosedRange<Int>?
    public var mappedPorts: ClosedRange<Int>?

    public init(name: String, externalIP: String, mappedIP: String, portForward: Bool, proto: String = "tcp",
                externalPorts: ClosedRange<Int>? = nil, mappedPorts: ClosedRange<Int>? = nil) {
        self.name = name
        self.externalIP = externalIP
        self.mappedIP = mappedIP
        self.portForward = portForward
        self.proto = proto
        self.externalPorts = externalPorts
        self.mappedPorts = mappedPorts
    }

    /// Ce VIP fait passer `proto` sur `port` (redirection de port, ou NAT statique de toute l'adresse).
    public func covers(_ wanted: String, port: Int) -> Bool {
        guard portForward else { return true }
        return proto == wanted && (externalPorts?.contains(port) ?? false)
    }
}

/// Vérification en lecture seule des VIP de la FortiGate pour les ports de RustDesk.
public enum RustDeskVIPCheck {
    public static let path = "/api/v2/cmdb/firewall/vip"

    /// Ports à ouvrir : TCP 21115-21117 et UDP 21116 (ou ceux des réglages).
    public static func requiredPorts(_ settings: RustDeskServerSettings) -> [(proto: String, port: Int, role: String)] {
        let id = settings.idEndpoint?.port ?? RustDeskServerSettings.defaultIDPort
        let relay = settings.relayEndpoint?.port ?? RustDeskServerSettings.defaultRelayPort
        return [("tcp", id - 1, "test NAT"), ("tcp", id, "serveur d’ID"), ("udp", id, "présence et percée NAT"), ("tcp", relay, "relais")]
    }

    /// Lecture du JSON de FortiOS (« results » : name, extip, mappedip[].range, portforward, protocol, extport, mappedport).
    public static func parse(_ data: Data) -> [RustDeskVIP] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let mapped = (item["mappedip"] as? [[String: Any]])?.first?["range"] as? String
                ?? (item["mappedip"] as? String) ?? ""
            return RustDeskVIP(name: name,
                               externalIP: firstAddress(item["extip"] as? String ?? ""),
                               mappedIP: firstAddress(mapped),
                               portForward: (item["portforward"] as? String)?.lowercased() == "enable",
                               proto: ((item["protocol"] as? String) ?? "tcp").lowercased(),
                               externalPorts: portRange(item["extport"]),
                               mappedPorts: portRange(item["mappedport"]))
        }
    }

    /// « 10.0.0.5-10.0.0.5 » → « 10.0.0.5 ».
    static func firstAddress(_ text: String) -> String {
        String(text.split(separator: "-").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// « 21115-21117 », « 21116 » ou un nombre.
    static func portRange(_ value: Any?) -> ClosedRange<Int>? {
        if let number = value as? Int { return number > 0 ? number...number : nil }
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let low = parts.first, low > 0 else { return nil }
        let high = parts.count > 1 ? parts[1] : low
        return low <= high ? low...high : nil
    }

    static func isPrivate(_ text: String) -> Bool {
        let octets = text.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168): return true
        case (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    /// Constats pour chaque port requis : VIP trouvé, adresse interne visée, piège de l'IP publique.
    public static func evaluate(_ vips: [RustDeskVIP], settings: RustDeskServerSettings) -> [RustDeskFinding] {
        let interne = settings.internalAddress.trimmingCharacters(in: .whitespaces)
        return requiredPorts(settings).map { required in
            let label = "\(required.proto.uppercased()) \(required.port)"
            guard let vip = vips.first(where: { $0.portForward && $0.covers(required.proto, port: required.port) })
                    ?? vips.first(where: { $0.covers(required.proto, port: required.port) }) else {
                return RustDeskFinding(.error, "\(label) (\(required.role))\u{00A0}: aucun VIP",
                                       "Créer un VIP \(label) vers l’adresse interne du serveur, et la règle de pare-feu qui l’autorise.")
            }
            let target = vip.mappedIP
            if !interne.isEmpty, target != interne {
                return RustDeskFinding(.error, "\(label)\u{00A0}: VIP «\u{00A0}\(vip.name)\u{00A0}» vers \(target)",
                                       "Attendu\u{00A0}: \(interne), l’adresse interne du serveur RustDesk (champ «\u{00A0}mappedip\u{00A0}» du VIP).")
            }
            if target == vip.externalIP || !isPrivate(target) {
                return RustDeskFinding(.error, "\(label)\u{00A0}: VIP «\u{00A0}\(vip.name)\u{00A0}» mappé sur \(target)",
                                       "Le VIP pointe sur une adresse publique (souvent l’IP externe elle-même)\u{00A0}: mettre l’adresse interne du serveur dans «\u{00A0}mappedip\u{00A0}».")
            }
            if let mapped = vip.mappedPorts, let external = vip.externalPorts, vip.portForward,
               mapped.lowerBound + (required.port - external.lowerBound) != required.port {
                return RustDeskFinding(.warning, "\(label)\u{00A0}: VIP «\u{00A0}\(vip.name)\u{00A0}» change le port",
                                       "Port interne \(mapped.lowerBound + (required.port - external.lowerBound))\u{00A0}: RustDesk attend le même port des deux côtés.")
            }
            return RustDeskFinding(.ok, "\(label)\u{00A0}: VIP «\u{00A0}\(vip.name)\u{00A0}» vers \(target)",
                                   vip.portForward ? "" : "NAT statique de toute l’adresse \(vip.externalIP).")
        }
    }

    /// Lecture (GET seulement) par le client FortiGate existant.
    public static func read(transport: FortiTransport) async throws -> [RustDeskVIP] {
        let response = try await transport.get(path, query: [])
        if let error = FortiGateError.from(status: response.status, path: path) { throw error }
        return parse(response.body)
    }
}
