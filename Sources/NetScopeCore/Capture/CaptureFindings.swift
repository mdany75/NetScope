import Foundation

// Note 78 (Capture de paquets) : constats automatiques sur une capture, en clair, avec le filtre
// d'affichage qui montre les paquets concernés :
// - TCP : retransmissions, fenêtre nulle, ACK en double, connexions refusées ou coupées (RST) ;
// - latence par flux : poignée de main TCP, DNS, HTTP, SNMP, RADIUS, NTP, SIP (requête → réponse) ;
// - requêtes sans réponse et réponses en échec (nom inexistant, Access-Reject, erreurs SIP…) ;
// - flux RTP : perte (numéros de séquence), gigue (RFC 3550, section 6.4.1), plus grand écart ;
// - horloge d'un client NTP décalée par rapport à son serveur.
// Fonctions pures sur la liste des paquets : aucun accès réseau.

/// Gravité d'un constat.
public enum CaptureFindingSeverity: Int, Comparable, Sendable, CaseIterable {
    case info = 0, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .info: return "Information"
        case .warning: return "À surveiller"
        case .critical: return "Problème"
        }
    }
}

/// Un constat : titre, explication, paquets concernés et filtre d'affichage pour les voir.
public struct CaptureFinding: Identifiable, Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        case retransmission, zeroWindow, duplicateAck, reset, refused, latency, unanswered, failure, rtpLoss, rtpJitter, clock
    }

    public var id: String
    public var category: Category
    public var severity: CaptureFindingSeverity
    public var title: String
    public var detail: String
    /// Numéros des paquets concernés (dans l'ordre).
    public var packets: [Int]
    /// Filtre d'affichage qui montre ces paquets (syntaxe de NetScope, proche de Wireshark).
    public var filter: String?
}

/// Latence mesurée d'un flux (une mesure : poignée de main TCP, DNS, SNMP…).
public struct FlowLatency: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: PacketProtocol
    /// « Poignée de main TCP », « DNS », « SNMP »…
    public var measure: String
    /// « 10.182.122.142 → 52.96.88.50:443 ».
    public var flow: String
    /// Secondes, dans l'ordre des mesures.
    public var samples: [Double]
    public var unanswered: Int
    public var failures: Int
    public var firstPacket: Int
    public var filter: String?

    public var count: Int { samples.count }
    public var minimum: Double? { samples.min() }
    public var maximum: Double? { samples.max() }
    public var median: Double? { CaptureFindingsAnalyzer.median(samples) }
}

/// Flux RTP : perte, gigue et écarts.
public struct RTPStreamSummary: Identifiable, Sendable, Equatable {
    public var id: String
    public var ssrc: UInt32
    public var source: Endpoint
    public var destination: Endpoint
    public var payloadType: UInt8
    /// « PCMU (G.711 µ-loi) », « opus » (d'après le SDP), « dynamique (101) ».
    public var codec: String
    public var clockRate: Double
    public var packets: Int
    public var expected: Int
    public var lost: Int
    /// Gigue (RFC 3550) en millisecondes.
    public var jitter: Double
    /// Plus grand écart entre deux paquets, en millisecondes.
    public var maxDelta: Double
    public var duration: Double
    public var firstPacket: Int
    /// Perte et gigue annoncées par l'autre extrémité (RTCP), si présentes.
    public var reportedLoss: Double?
    public var reportedJitter: Double?

    public init(id: String, ssrc: UInt32, source: Endpoint, destination: Endpoint, payloadType: UInt8, codec: String,
                clockRate: Double, packets: Int, expected: Int, lost: Int, jitter: Double, maxDelta: Double,
                duration: Double, firstPacket: Int, reportedLoss: Double? = nil, reportedJitter: Double? = nil) {
        self.id = id
        self.ssrc = ssrc
        self.source = source
        self.destination = destination
        self.payloadType = payloadType
        self.codec = codec
        self.clockRate = clockRate
        self.packets = packets
        self.expected = expected
        self.lost = lost
        self.jitter = jitter
        self.maxDelta = maxDelta
        self.duration = duration
        self.firstPacket = firstPacket
        self.reportedLoss = reportedLoss
        self.reportedJitter = reportedJitter
    }

    public var lossRatio: Double { expected > 0 ? Double(lost) / Double(expected) : 0 }
    public var label: String { "\(source.label) → \(destination.label)" }
    public var filter: String { "rtp.ssrc == \(ssrc)" }
}

/// Résultat de l'analyse.
public struct CaptureFindingsReport: Sendable, Equatable {
    public var findings: [CaptureFinding] = []
    public var latencies: [FlowLatency] = []
    public var rtpStreams: [RTPStreamSummary] = []
    public var packetCount = 0

    public init() {}

    public func count(_ severity: CaptureFindingSeverity) -> Int { findings.filter { $0.severity == severity }.count }
    /// Constats à surveiller ou graves (pastille de l'onglet).
    public var notableCount: Int { findings.filter { $0.severity >= .warning }.count }
}

public enum CaptureFindingsAnalyzer {
    /// Une requête n'est dite sans réponse que si la capture a continué au moins ce délai après elle.
    public static let answerTimeout: Double = 2
    /// Au plus ce nombre de numéros de paquets dans un filtre « frame.number == … ».
    static let filterLimit = 12

    /// Seuils de latence (médiane) au-delà desquels la latence est signalée.
    public static func latencyThreshold(_ kind: PacketProtocol, handshake: Bool) -> Double {
        if handshake { return 0.2 }
        switch kind {
        case .dns: return 0.15
        case .snmp, .ntp, .sip: return 0.5
        case .radius: return 1.0
        case .http: return 1.5
        default: return 1.0
        }
    }

    public static func analyze(_ log: PacketCaptureLog) -> CaptureFindingsReport {
        var report = CaptureFindingsReport()
        report.packetCount = log.count
        guard !log.isEmpty else { return report }
        var findings: [CaptureFinding] = []
        tcpFindings(log, into: &findings)
        let latencies = latencyAnalysis(log, findings: &findings)
        let streams = rtpAnalysis(log)
        for stream in streams { findings.append(contentsOf: rtpFindings(stream)) }
        clockFindings(log, into: &findings)
        report.findings = findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : ($0.packets.first ?? 0) < ($1.packets.first ?? 0)
        }
        report.latencies = latencies
        report.rtpStreams = streams
        return report
    }

    // MARK: TCP

    static func tcpFilter(_ key: ConversationKey, _ extra: String) -> String {
        var filter = "\(extra) && ip.addr == \(key.a.address) && ip.addr == \(key.b.address)"
        if let a = key.a.port, let b = key.b.port { filter += " && tcp.port == \(a) && tcp.port == \(b)" }
        return filter
    }

    static func tcpFindings(_ log: PacketCaptureLog, into findings: inout [CaptureFinding]) {
        struct Conversation {
            var key: ConversationKey
            var dataSegments = 0
            var retransmissions: [Int] = []
            var duplicateAcks: [Int] = []
            var zeroWindows: [String: [Int]] = [:]
            var resets: [Int] = []
            var synFrom: String?
            var synPacket: Int?
            var established = false
            var resetBy: String?
        }
        var conversations: [ConversationKey: Conversation] = [:]
        var order: [ConversationKey] = []
        for packet in log.packets {
            guard let key = packet.conversation, key.kind == .tcp, let tcp = packet.decoded.tcp else { continue }
            if conversations[key] == nil { conversations[key] = Conversation(key: key); order.append(key) }
            let source = packet.decoded.ipSource ?? "?"
            if tcp.payloadLength > 0 { conversations[key]!.dataSegments += 1 }
            if tcp.has(TCPSegmentInfo.syn), !tcp.has(TCPSegmentInfo.ack), conversations[key]!.synFrom == nil {
                conversations[key]!.synFrom = source
                conversations[key]!.synPacket = packet.id
            }
            if tcp.has(TCPSegmentInfo.syn), tcp.has(TCPSegmentInfo.ack) { conversations[key]!.established = true }
            if packet.analysis.contains(.retransmission) { conversations[key]!.retransmissions.append(packet.id) }
            if packet.analysis.contains(.duplicateAck) { conversations[key]!.duplicateAcks.append(packet.id) }
            if packet.analysis.contains(.zeroWindow) { conversations[key]!.zeroWindows[source, default: []].append(packet.id) }
            if packet.analysis.contains(.reset) {
                conversations[key]!.resets.append(packet.id)
                if conversations[key]!.resetBy == nil { conversations[key]!.resetBy = source }
            }
        }
        for key in order {
            guard let c = conversations[key] else { continue }
            let label = key.label
            if !c.retransmissions.isEmpty {
                let ratio = Double(c.retransmissions.count) / Double(max(1, c.dataSegments))
                let severity: CaptureFindingSeverity = ratio >= 0.1 ? .critical : (ratio >= 0.02 || c.retransmissions.count >= 3) ? .warning : .info
                let count = c.retransmissions.count
                findings.append(CaptureFinding(
                    id: "retrans|\(label)", category: .retransmission, severity: severity,
                    title: "\(count) retransmission\(count > 1 ? "s" : "") TCP · \(label)",
                    detail: "\(percent(ratio)) des segments de données ont été renvoyés"
                        + (c.duplicateAcks.isEmpty ? "" : ", avec \(c.duplicateAcks.count) ACK en double")
                        + "\u{00A0}: des paquets se perdent sur le chemin (câble ou port en erreur, duplex, Wi-Fi saturé, lien chargé). Comparez avec les erreurs du port du switch.",
                    packets: c.retransmissions, filter: tcpFilter(key, "tcp.analysis.retransmission")))
            } else if c.duplicateAcks.count >= 3 {
                findings.append(CaptureFinding(
                    id: "dupack|\(label)", category: .duplicateAck, severity: .info,
                    title: "\(c.duplicateAcks.count) ACK en double · \(label)",
                    detail: "Le récepteur signale des segments manquants sans retransmission visible\u{00A0}: perte probable en amont de ce point de capture.",
                    packets: c.duplicateAcks, filter: tcpFilter(key, "tcp.analysis.duplicate_ack")))
            }
            for (source, packets) in c.zeroWindows.sorted(by: { $0.key < $1.key }) {
                findings.append(CaptureFinding(
                    id: "zero|\(label)|\(source)", category: .zeroWindow, severity: .warning,
                    title: "Fenêtre nulle annoncée par \(source) (\(packets.count) fois)",
                    detail: "\(source) ne vide plus son tampon de réception sur \(label)\u{00A0}: l’application ou l’appareil est saturé (disque, processeur, imprimante occupée). Le réseau n’est pas en cause.",
                    packets: packets, filter: tcpFilter(key, "tcp.analysis.zero_window")))
            }
            if let first = c.resets.first {
                let refused = !c.established && c.synFrom != nil
                let server = c.synFrom == key.a.address ? key.b : key.a
                if refused {
                    findings.append(CaptureFinding(
                        id: "refused|\(label)", category: .refused, severity: .info,
                        title: "Connexion refusée par \(server.label)",
                        detail: "Le SYN a reçu une réinitialisation (RST)\u{00A0}: aucun service n’écoute sur ce port, ou un coupe-feu refuse activement la connexion.",
                        packets: [c.synPacket ?? first, first], filter: tcpFilter(key, "tcp.flags.reset == 1")))
                } else {
                    findings.append(CaptureFinding(
                        id: "reset|\(label)", category: .reset, severity: .warning,
                        title: "Connexion coupée (RST) par \(c.resetBy ?? "?") · \(label)",
                        detail: "La connexion établie a été interrompue brutalement\u{00A0}: application fermée, délai d’inactivité d’un coupe-feu ou d’un équilibreur, ou refus après coup.",
                        packets: c.resets, filter: tcpFilter(key, "tcp.flags.reset == 1")))
                }
            }
        }
    }

    // MARK: Latence par flux

    private struct Pending {
        var time: Double
        var packet: Int
        var label: String
        var flowID: String
        var answered = false
        var retries = 0
    }

    private struct LatencyGroup {
        var kind: PacketProtocol
        var measure: String
        var flow: String
        var samples: [Double] = []
        var unanswered: [Int] = []
        var failures: [(Int, String)] = []
        var firstPacket: Int
        var filter: String?
    }

    static func latencyAnalysis(_ log: PacketCaptureLog, findings: inout [CaptureFinding]) -> [FlowLatency] {
        var groups: [String: LatencyGroup] = [:]
        var order: [String] = []
        func group(_ id: String, _ make: @autoclosure () -> LatencyGroup) {
            if groups[id] == nil { groups[id] = make(); order.append(id) }
        }
        let end = log.packets.last?.record.timestamp ?? 0

        // Poignée de main TCP : SYN → SYN/ACK, par client et serveur.
        var syns: [ConversationKey: (time: Double, packet: Int, client: String, server: Endpoint)] = [:]
        // HTTP : requêtes en attente par conversation (dans l'ordre).
        var httpPending: [ConversationKey: [(time: Double, packet: Int)]] = [:]
        // Transactions d'application.
        var pending: [String: Pending] = [:]
        var pendingOrder: [String] = []

        for packet in log.packets {
            let time = packet.record.timestamp
            let source = packet.decoded.ipSource ?? "?"
            if let tcp = packet.decoded.tcp, let key = packet.conversation, let transport = packet.decoded.transport {
                if tcp.has(TCPSegmentInfo.syn), !tcp.has(TCPSegmentInfo.ack), syns[key] == nil {
                    let server = Endpoint(address: packet.decoded.ipDestination ?? "?", port: transport.destinationPort)
                    syns[key] = (time, packet.id, source, server)
                    let id = "tcp|\(source)|\(server.label)"
                    group(id, LatencyGroup(kind: .tcp, measure: "Poignée de main TCP", flow: "\(source) → \(server.label)", firstPacket: packet.id,
                                           filter: "tcp.flags.syn == 1 && ip.addr == \(source) && ip.addr == \(server.address) && tcp.port == \(transport.destinationPort)"))
                } else if tcp.has(TCPSegmentInfo.syn), tcp.has(TCPSegmentInfo.ack), let syn = syns[key], syn.time >= 0 {
                    groups["tcp|\(syn.client)|\(syn.server.label)"]?.samples.append(time - syn.time)
                    syns[key] = (-1, syn.packet, syn.client, syn.server)
                } else if tcp.has(TCPSegmentInfo.rst), let syn = syns[key], syn.time >= 0 {
                    groups["tcp|\(syn.client)|\(syn.server.label)"]?.failures.append((packet.id, "connexion refusée"))
                    syns[key] = (-1, syn.packet, syn.client, syn.server)
                }
                if packet.decoded.httpRequest != nil {
                    httpPending[key, default: []].append((time, packet.id))
                    let server = Endpoint(address: packet.decoded.ipDestination ?? "?", port: transport.destinationPort)
                    group("http|\(source)|\(server.label)", LatencyGroup(kind: .http, measure: "HTTP (requête → réponse)", flow: "\(source) → \(server.label)",
                                                                       firstPacket: packet.id, filter: "http && ip.addr == \(source) && ip.addr == \(server.address)"))
                } else if let status = packet.decoded.httpStatus, var queue = httpPending[key], !queue.isEmpty {
                    let request = queue.removeFirst()
                    httpPending[key] = queue
                    let client = packet.decoded.ipDestination ?? "?"
                    let server = Endpoint(address: source, port: transport.sourcePort)
                    let id = "http|\(client)|\(server.label)"
                    groups[id]?.samples.append(time - request.time)
                    if status >= 500 { groups[id]?.failures.append((packet.id, "HTTP \(status)")) }
                }
            }
            guard let transaction = packet.decoded.transaction else { continue }
            let conversation = packet.conversation?.label ?? ""
            let matchKey = transaction.global ? transaction.key : transaction.key + "|" + conversation
            if transaction.isRequest {
                if pending[matchKey] != nil {
                    pending[matchKey]!.retries += 1
                    continue
                }
                let destination = packet.decoded.ipDestination ?? "?"
                let port = packet.decoded.transport.map { ":\($0.destinationPort)" } ?? ""
                let flowID = "\(transaction.kind.rawValue)|\(source)|\(destination)\(port)"
                group(flowID, LatencyGroup(kind: transaction.kind, measure: measureName(transaction.kind), flow: "\(source) → \(destination)\(port)",
                                           firstPacket: packet.id, filter: "\(transaction.kind.filterName) && ip.addr == \(source) && ip.addr == \(destination)"))
                pending[matchKey] = Pending(time: time, packet: packet.id, label: transaction.label, flowID: flowID)
                pendingOrder.append(matchKey)
            } else if var request = pending[matchKey] {
                if !request.answered {
                    groups[request.flowID]?.samples.append(time - request.time)
                    request.answered = true
                }
                if let failure = transaction.failure {
                    groups[request.flowID]?.failures.append((packet.id, "\(request.label)\u{00A0}: \(failure)"))
                }
                if transaction.provisional { pending[matchKey] = request } else { pending[matchKey] = nil }
            }
        }
        // Requêtes restées sans réponse (la capture a continué assez longtemps après elles).
        for key in pendingOrder {
            guard let request = pending[key], !request.answered, end - request.time >= answerTimeout else { continue }
            groups[request.flowID]?.unanswered.append(request.packet)
        }
        // Connexions TCP sans SYN/ACK.
        for (_, syn) in syns where syn.time >= 0 && end - syn.time >= answerTimeout {
            groups["tcp|\(syn.client)|\(syn.server.label)"]?.unanswered.append(syn.packet)
        }

        var result: [FlowLatency] = []
        for id in order {
            guard let g = groups[id] else { continue }
            result.append(FlowLatency(id: id, kind: g.kind, measure: g.measure, flow: g.flow, samples: g.samples,
                                      unanswered: g.unanswered.count, failures: g.failures.count, firstPacket: g.firstPacket, filter: g.filter))
            let name = g.kind == .tcp ? "Connexion TCP" : g.measure
            if !g.unanswered.isEmpty, !(g.kind == .tcp && !g.failures.isEmpty) {
                let count = g.unanswered.count
                findings.append(CaptureFinding(
                    id: "unanswered|\(id)", category: .unanswered, severity: .warning,
                    title: "\(count) requête\(count > 1 ? "s" : "") \(name) sans réponse · \(g.flow)",
                    detail: unansweredAdvice(g.kind),
                    packets: g.unanswered, filter: numbersFilter(g.unanswered)))
            }
            // Connexion TCP refusée : déjà dite par les constats TCP (RST).
            if !g.failures.isEmpty, g.kind != .tcp {
                // Échecs regroupés par message (« A imprimante-rh.bureau.local : nom inexistant »).
                var byText: [String: [Int]] = [:]
                var textOrder: [String] = []
                for (packet, text) in g.failures {
                    if byText[text] == nil { textOrder.append(text) }
                    byText[text, default: []].append(packet)
                }
                for text in textOrder {
                    let packets = byText[text] ?? []
                    findings.append(CaptureFinding(
                        id: "failure|\(id)|\(text)", category: .failure, severity: failureSeverity(g.kind, text),
                        title: "\(failureTitle(g.kind))\u{00A0}: \(text)" + (packets.count > 1 ? " (\(packets.count) fois)" : ""),
                        detail: failureAdvice(g.kind, text) + " Flux\u{00A0}: \(g.flow).",
                        packets: packets, filter: numbersFilter(packets)))
                }
            }
            if let median = median(g.samples), median > latencyThreshold(g.kind, handshake: g.kind == .tcp) {
                findings.append(CaptureFinding(
                    id: "latency|\(id)", category: .latency, severity: .warning,
                    title: "Latence élevée\u{00A0}: \(name) \(milliseconds(median)) (médiane) · \(g.flow)",
                    detail: "Sur \(g.samples.count) mesure\(g.samples.count > 1 ? "s" : "")"
                        + (g.samples.count > 1 ? " (de \(milliseconds(g.samples.min() ?? median)) à \(milliseconds(g.samples.max() ?? median)))" : "")
                        + ". " + latencyAdvice(g.kind),
                    packets: [g.firstPacket], filter: g.filter))
            } else if g.samples.count >= 3, let median = median(g.samples), let maximum = g.samples.max(),
                      maximum > 0.3, maximum > 5 * max(median, 0.001) {
                findings.append(CaptureFinding(
                    id: "spike|\(id)", category: .latency, severity: .info,
                    title: "Pic de latence\u{00A0}: \(name) jusqu’à \(milliseconds(maximum)) · \(g.flow)",
                    detail: "Médiane de \(milliseconds(median)) sur \(g.samples.count) mesures, mais un pic à \(milliseconds(maximum))\u{00A0}: charge passagère du serveur ou du lien.",
                    packets: [g.firstPacket], filter: g.filter))
            }
        }
        return result
    }

    static func measureName(_ kind: PacketProtocol) -> String {
        switch kind {
        case .dns: return "DNS"
        case .snmp: return "SNMP"
        case .radius: return "RADIUS"
        case .ntp: return "NTP"
        case .sip: return "SIP (première réponse)"
        default: return kind.label
        }
    }

    static func unansweredAdvice(_ kind: PacketProtocol) -> String {
        switch kind {
        case .dns: return "Le serveur DNS ne répond pas\u{00A0}: serveur arrêté, port 53 filtré ou mauvaise adresse de serveur reçue par DHCP."
        case .snmp: return "L’agent SNMP se tait\u{00A0}: communauté ou utilisateur v3 refusé, liste d’accès SNMP qui exclut ce Mac, ou agent désactivé (un agent ne répond jamais à une mauvaise communauté)."
        case .radius: return "Le serveur RADIUS se tait\u{00A0}: client RADIUS non déclaré sur le serveur, secret partagé différent, ou port 1812 filtré. Le journal du serveur (NPS, FreeRADIUS) dit lequel."
        case .ntp: return "Le serveur NTP ne répond pas\u{00A0}: port UDP 123 filtré en sortie, ou serveur injoignable."
        case .sip: return "La requête SIP n’a reçu aucune réponse\u{00A0}: serveur ou trunk injoignable, NAT ou ALG SIP qui perd les réponses (désactivez l’ALG SIP de la FortiGate)."
        case .tcp: return "Le SYN est resté sans réponse\u{00A0}: hôte éteint, ou coupe-feu qui jette la connexion sans la refuser."
        default: return "Aucune réponse n’a été vue dans la capture."
        }
    }

    static func failureTitle(_ kind: PacketProtocol) -> String {
        switch kind {
        case .dns: return "Échec DNS"
        case .snmp: return "Erreur SNMP"
        case .radius: return "Refus RADIUS"
        case .ntp: return "Réponse NTP refusée"
        case .sip: return "Échec SIP"
        case .http: return "Erreur du serveur web"
        case .tcp: return "Connexion TCP"
        default: return "Échec"
        }
    }

    static func failureSeverity(_ kind: PacketProtocol, _ text: String) -> CaptureFindingSeverity {
        switch kind {
        case .dns, .tcp: return .info
        case .radius, .sip, .ntp: return .warning
        default: return .info
        }
    }

    static func failureAdvice(_ kind: PacketProtocol, _ text: String) -> String {
        switch kind {
        case .dns: return "Le serveur DNS a répondu par une erreur (nom inexistant ou refus)\u{00A0}: vérifiez le nom demandé et le suffixe DNS."
        case .radius: return "Le serveur RADIUS a refusé l’accès\u{00A0}: identifiants, groupe ou stratégie réseau (NPS) qui ne correspond pas, certificat refusé."
        case .sip: return "Le serveur SIP a répondu par une erreur\u{00A0}: compte, numéro composé, codec refusé (488) ou trunk indisponible (503)."
        case .snmp: return "L’agent SNMP a répondu par une erreur\u{00A0}: objet absent de cet équipement ou droits de la vue SNMP."
        case .ntp: return "Le serveur NTP refuse de servir ce client (limite de débit ou accès refusé) ou n’est pas synchronisé lui-même."
        case .http: return "Le serveur web a répondu par une erreur 5xx."
        case .tcp: return "Le serveur a refusé la connexion (RST)."
        default: return ""
        }
    }

    static func latencyAdvice(_ kind: PacketProtocol) -> String {
        switch kind {
        case .tcp: return "Le temps d’aller-retour réseau est long\u{00A0}: lien lent ou saturé, Wi-Fi faible, ou serveur lointain."
        case .dns: return "Le serveur DNS répond lentement\u{00A0}: il relaie peut-être vers un serveur lointain\u{00A0}; chaque nouvelle page attend cette réponse."
        case .snmp: return "L’agent SNMP répond lentement\u{00A0}: processeur de l’équipement chargé ou requêtes trop grosses."
        case .radius: return "Le serveur RADIUS répond lentement\u{00A0}: annuaire lent ou serveur surchargé\u{00A0}; les clients Wi-Fi peuvent abandonner l’authentification."
        default: return "Le serveur répond lentement."
        }
    }

    // MARK: RTP

    private struct RTPState {
        var ssrc: UInt32
        var source: Endpoint
        var destination: Endpoint
        var payloadType: UInt8
        var firstPacket: Int
        var firstTime: Double
        var lastTime: Double
        var packets = 0
        var cycles = 0
        var baseSequence: Int
        var maxSequence: UInt16
        var maxExtended: Int
        var previousArrival: Double?
        var maxDelta: Double = 0
        var samples: [(time: Double, timestamp: UInt32)] = []
    }

    static func rtpAnalysis(_ log: PacketCaptureLog) -> [RTPStreamSummary] {
        let codecs = sdpCodecs(log)
        var states: [String: RTPState] = [:]
        var order: [String] = []
        var reports: [UInt32: RTCPReportBlock] = [:]
        for packet in log.packets {
            for report in packet.decoded.rtcpReports { reports[report.ssrc] = report }
            guard let rtp = packet.decoded.rtp, let transport = packet.decoded.transport,
                  let source = packet.decoded.ipSource, let destination = packet.decoded.ipDestination else { continue }
            let from = Endpoint(address: source, port: transport.sourcePort)
            let to = Endpoint(address: destination, port: transport.destinationPort)
            let id = "\(rtp.ssrc)|\(from.label)|\(to.label)"
            let time = packet.record.timestamp
            if states[id] == nil {
                states[id] = RTPState(ssrc: rtp.ssrc, source: from, destination: to, payloadType: rtp.payloadType, firstPacket: packet.id,
                                      firstTime: time, lastTime: time, baseSequence: Int(rtp.sequence), maxSequence: rtp.sequence,
                                      maxExtended: Int(rtp.sequence))
                order.append(id)
            }
            var state = states[id]!
            state.packets += 1
            // Numéro de séquence étendu (bouclage à 65 536).
            let sequence = rtp.sequence
            if sequence != state.maxSequence || state.packets == 1 {
                let forward = UInt16(truncatingIfNeeded: Int(sequence) - Int(state.maxSequence))
                if forward < 0x8000 {
                    if sequence < state.maxSequence { state.cycles += 65_536 }
                    state.maxSequence = sequence
                    state.maxExtended = state.cycles + Int(sequence)
                }
            }
            if let previous = state.previousArrival { state.maxDelta = max(state.maxDelta, time - previous) }
            state.previousArrival = time
            state.lastTime = time
            // Gigue : seulement le type de charge principal (pas les événements DTMF).
            if rtp.payloadType == state.payloadType { state.samples.append((time, rtp.timestamp)) }
            states[id] = state
        }
        return order.compactMap { id in
            guard let state = states[id] else { return nil }
            let known = codecs[state.payloadType]
            let rate = RTPRecognizer.clockRate(state.payloadType) ?? known?.rate ?? estimatedRate(state.samples)
            let expected = max(state.packets, state.maxExtended - state.baseSequence + 1)
            let codec = known.map { $0.name } ?? RTPRecognizer.codecName(state.payloadType)
            var summary = RTPStreamSummary(id: id, ssrc: state.ssrc, source: state.source, destination: state.destination,
                                           payloadType: state.payloadType, codec: codec, clockRate: rate, packets: state.packets,
                                           expected: expected, lost: max(0, expected - state.packets),
                                           jitter: jitter(state.samples, rate: rate) * 1000, maxDelta: state.maxDelta * 1000,
                                           duration: state.lastTime - state.firstTime, firstPacket: state.firstPacket)
            if let report = reports[state.ssrc] {
                summary.reportedLoss = report.fractionLost
                summary.reportedJitter = Double(report.jitter) / rate * 1000
            }
            return summary
        }
    }

    /// Gigue d'arrivée (RFC 3550, section 6.4.1), en secondes.
    public static func jitter(_ samples: [(time: Double, timestamp: UInt32)], rate: Double) -> Double {
        guard samples.count >= 2, rate > 0 else { return 0 }
        var value = 0.0
        for index in 1..<samples.count {
            let arrival = samples[index].time - samples[index - 1].time
            let sent = Double(Int32(bitPattern: samples[index].timestamp &- samples[index - 1].timestamp)) / rate
            let difference = abs(arrival - sent)
            value += (difference - value) / 16
        }
        return value
    }

    /// Fréquence d'horloge d'un type dynamique, d'après l'écart des horodatages et des arrivées.
    static func estimatedRate(_ samples: [(time: Double, timestamp: UInt32)]) -> Double {
        var ratios: [Double] = []
        for index in samples.indices.dropFirst() {
            let dt = samples[index].time - samples[index - 1].time
            let ticks = Double(Int32(bitPattern: samples[index].timestamp &- samples[index - 1].timestamp))
            if dt > 0.005, ticks > 0 { ratios.append(ticks / dt) }
        }
        guard let middle = median(ratios) else { return 8_000 }
        let rates: [Double] = [8_000, 16_000, 24_000, 32_000, 44_100, 48_000, 90_000]
        return rates.min { abs($0 - middle) < abs($1 - middle) } ?? 8_000
    }

    /// Codecs annoncés par le SDP des messages SIP de la capture (« a=rtpmap:111 opus/48000/2 »).
    static func sdpCodecs(_ log: PacketCaptureLog) -> [UInt8: (name: String, rate: Double)] {
        var result: [UInt8: (String, Double)] = [:]
        for packet in log.packets where packet.decoded.contains(.sip) {
            guard let sdp = packet.decoded.firstField(named: "Description de session (SDP)") else { continue }
            for field in sdp.children where field.value.hasPrefix("rtpmap:") {
                let body = field.value.dropFirst("rtpmap:".count)
                let parts = body.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let type = UInt8(parts[0]) else { continue }
                let codec = parts[1].split(separator: "/")
                let rate = codec.count > 1 ? Double(codec[1]) ?? 8_000 : 8_000
                result[type] = (String(codec.first ?? ""), rate)
            }
        }
        return result
    }

    static func rtpFindings(_ stream: RTPStreamSummary) -> [CaptureFinding] {
        var list: [CaptureFinding] = []
        let ratio = stream.lossRatio
        if stream.lost > 0, ratio >= 0.01 {
            list.append(CaptureFinding(
                id: "rtploss|\(stream.id)", category: .rtpLoss, severity: ratio >= 0.05 ? .critical : .warning,
                title: "Perte RTP de \(percent(ratio)) · \(stream.label) (\(stream.codec))",
                detail: "\(stream.lost) paquet\(stream.lost > 1 ? "s" : "") sur \(stream.expected) manquent\u{00A0}: la voix se hache au-delà de 1\u{00A0}%. Cherchez la congestion (QoS, priorité de la voix, lien saturé) ou un Wi-Fi faible sur ce trajet.",
                packets: [stream.firstPacket], filter: stream.filter))
        }
        if stream.jitter > 30 {
            list.append(CaptureFinding(
                id: "rtpjitter|\(stream.id)", category: .rtpJitter, severity: stream.jitter > 60 ? .critical : .warning,
                title: "Gigue RTP de \(milliseconds(stream.jitter / 1000)) · \(stream.label)",
                detail: "Les paquets de voix arrivent irrégulièrement (au-delà de 30\u{00A0}ms, le tampon du téléphone ne suffit plus)\u{00A0}; plus grand écart entre deux paquets\u{00A0}: \(milliseconds(stream.maxDelta / 1000)). La QoS (DSCP EF) doit prioriser la voix.",
                packets: [stream.firstPacket], filter: stream.filter))
        }
        return list
    }

    // MARK: Horloge NTP

    static func clockFindings(_ log: PacketCaptureLog, into findings: inout [CaptureFinding]) {
        var requests: [String: (capture: Double, client: String, packet: Int)] = [:]
        var reported = Set<String>()
        for packet in log.packets {
            guard let ntp = packet.decoded.ntp else { continue }
            if ntp.mode == 3, ntp.transmit != 0 {
                requests[String(format: "%.6f", ntp.transmit)] = (packet.record.timestamp, packet.decoded.ipSource ?? "?", packet.id)
            } else if ntp.mode == 4, ntp.origin != 0, ntp.stratum > 0, let request = requests[String(format: "%.6f", ntp.origin)] {
                // Horloge du client à la réception, estimée par le temps écoulé dans la capture.
                let t1 = ntp.origin, t2 = ntp.receive, t3 = ntp.transmit
                let t4 = t1 + (packet.record.timestamp - request.capture)
                let offset = ((t2 - t1) + (t3 - t4)) / 2
                guard abs(offset) >= 1, !reported.contains(request.client) else { continue }
                reported.insert(request.client)
                let server = packet.decoded.ipSource ?? "?"
                findings.append(CaptureFinding(
                    id: "clock|\(request.client)", category: .clock, severity: abs(offset) >= 60 ? .warning : .info,
                    title: "Horloge de \(request.client) décalée de \(seconds(offset)) par rapport à \(server)",
                    detail: "Mesuré sur l’échange NTP\u{00A0}: l’horloge du client \(offset > 0 ? "retarde" : "avance"). Des journaux mal datés ou des certificats refusés peuvent en venir\u{00A0}; l’écart devrait se résorber si le client applique la réponse.",
                    packets: [request.packet, packet.id], filter: numbersFilter([request.packet, packet.id])))
            }
        }
    }

    // MARK: Outils

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Filtre qui montre une liste de paquets par numéro (au plus `filterLimit`).
    static func numbersFilter(_ numbers: [Int]) -> String? {
        guard !numbers.isEmpty else { return nil }
        return numbers.prefix(filterLimit).map { "frame.number == \($0)" }.joined(separator: " || ")
    }

    /// « 2,4 % ».
    public static func percent(_ ratio: Double) -> String {
        String(format: "%.1f", ratio * 100).replacingOccurrences(of: ".", with: ",") + "\u{00A0}%"
    }

    /// « 23 ms », « 1,24 s », « 0,4 ms ».
    public static func milliseconds(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.2f", seconds).replacingOccurrences(of: ".", with: ",") + "\u{00A0}s" }
        let ms = seconds * 1000
        if ms < 10 { return String(format: "%.1f", ms).replacingOccurrences(of: ".", with: ",") + "\u{00A0}ms" }
        return "\(Int(ms.rounded()))\u{00A0}ms"
    }

    /// « +2,3 s », « −1 min 05 s ».
    static func seconds(_ value: Double) -> String {
        let sign = value < 0 ? "−" : "+"
        let magnitude = abs(value)
        if magnitude >= 60 { return sign + LogFormat.offset(magnitude).replacingOccurrences(of: "+", with: "") }
        return sign + String(format: "%.1f", magnitude).replacingOccurrences(of: ".", with: ",") + "\u{00A0}s"
    }
}
