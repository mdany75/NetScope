import Foundation

// Note 105 : trafic d'un seul appareil, pour sa fiche. Les vues Destinations et Applications de
// FortiView totalisent tout le réseau : pour une adresse, on les recalcule d'après ses sessions
// (/monitor/firewall/session, filtrées par srcaddr puis dstaddr). Sa ligne de la vue Sources donne
// le débit total, sa ligne de la vue Menaces les menaces qui le visent. Lecture seule (GET).
//
// Une adresse IP n'identifie un appareil que dans son site : l'appelant n'interroge que les
// FortiGate du site de la fiche, jamais celles des autres sites.

/// Ce qu'une FortiGate sait d'une adresse.
public struct DeviceTrafficRead: Hashable, Sendable {
    public var ip: IPv4Address
    /// Ligne de l'adresse dans la vue Sources ; nil si FortiView ne la montre pas.
    public var source: TrafficEntry?
    /// Sessions où l'adresse est la source ou la destination.
    public var sessions: [TrafficSession]
    public var threats: [TrafficEntry]
    public var notes: [String]
    public var readAt: Date
    /// La vue Sources et les sessions ont-elles répondu ? Faux : leur absence ne prouve rien.
    public var sourcesRead: Bool
    public var sessionsRead: Bool

    public init(ip: IPv4Address, source: TrafficEntry? = nil, sessions: [TrafficSession] = [], threats: [TrafficEntry] = [],
                notes: [String] = [], readAt: Date, sourcesRead: Bool = true, sessionsRead: Bool = true) {
        self.ip = ip
        self.source = source
        self.sessions = sessions
        self.threats = threats
        self.notes = notes
        self.readAt = readAt
        self.sourcesRead = sourcesRead
        self.sessionsRead = sessionsRead
    }

    /// Extrait d'un relevé complet d'une FortiGate (démonstration).
    public init(report: TrafficReadReport, ip: IPv4Address) {
        self.init(ip: ip,
                  source: report.entries(.sources).first { $0.ip == ip },
                  sessions: report.sessions.filter { DeviceTrafficAnalysis.involves($0, ip: ip) },
                  threats: report.entries(.threats).filter { $0.ip == ip },
                  readAt: report.readAt)
    }

    /// Lignes renommées d'après la FortiGate lue (deux FortiGate d'un site ne se confondent pas).
    public func relabeled(site: String) -> DeviceTrafficRead {
        var copy = self
        copy.source = source.map { var e = $0; e.site = site; return e }
        copy.sessions = sessions.map { var s = $0; s.site = site; return s }
        copy.threats = threats.map { var e = $0; e.site = site; return e }
        return copy
    }
}

/// Compteurs d'octets des sessions à un instant donné : deux relevés successifs donnent les débits.
public struct DeviceTrafficCounters: Hashable, Sendable {
    public struct Counter: Hashable, Sendable {
        public var sent: UInt64
        public var received: UInt64

        public init(sent: UInt64, received: UInt64) {
            self.sent = sent
            self.received = received
        }
    }

    public var at: Date
    public var values: [String: Counter]

    public init(at: Date, values: [String: Counter]) {
        self.at = at
        self.values = values
    }
}

/// Trafic d'un appareil, vu de l'appareil : « envoyé » est ce qu'il envoie, même quand il répond à
/// une connexion entrante.
public struct DeviceTrafficOverview: Hashable, Sendable {
    public var ip: IPv4Address
    /// Débit total en bits par seconde : celui de FortiView, sinon la somme des sessions ; nil si inconnu.
    public var bandwidth: Double?
    /// Réception et émission, tirées de deux relevés successifs ; nil au premier relevé.
    public var receiveBps: Double?
    public var sendBps: Double?
    public var sentBytes: UInt64
    public var receivedBytes: UInt64
    public var sessionCount: Int
    /// Mêmes lignes que les vues de l'écran Trafic, propres à cet appareil.
    public var destinations: [TrafficEntry]
    public var applications: [TrafficEntry]
    public var sessions: [TrafficSession]
    public var threats: [TrafficEntry]
    public var notes: [String]
    public var readAt: Date
    /// Au moins une FortiGate a rendu ses sessions : les compteurs peuvent servir au relevé suivant.
    public var sessionsKnown: Bool
    /// Toutes les lectures ont répondu : l'absence de trafic est établie.
    public var isComplete: Bool

    public init(ip: IPv4Address, bandwidth: Double? = nil, receiveBps: Double? = nil, sendBps: Double? = nil,
                sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0, sessionCount: Int = 0,
                destinations: [TrafficEntry] = [], applications: [TrafficEntry] = [], sessions: [TrafficSession] = [],
                threats: [TrafficEntry] = [], notes: [String] = [], readAt: Date, sessionsKnown: Bool = true, isComplete: Bool = true) {
        self.ip = ip
        self.bandwidth = bandwidth
        self.receiveBps = receiveBps
        self.sendBps = sendBps
        self.sentBytes = sentBytes
        self.receivedBytes = receivedBytes
        self.sessionCount = sessionCount
        self.destinations = destinations
        self.applications = applications
        self.sessions = sessions
        self.threats = threats
        self.notes = notes
        self.readAt = readAt
        self.sessionsKnown = sessionsKnown
        self.isComplete = isComplete
    }

    /// Aucune trace de l'appareil, et toutes les lectures ont répondu.
    public var isIdle: Bool { isComplete && sessionCount == 0 && bandwidth == nil && threats.isEmpty }
    /// Destination et application qui pèsent le plus (débit, puis volume).
    public var topDestination: TrafficEntry? { destinations.first }
    public var topApplication: TrafficEntry? { applications.first }
}

public enum DeviceTrafficAnalysis {
    /// Au-delà, deux relevés sont trop éloignés pour en tirer un débit (fenêtre cachée, veille).
    static let maxRateGap: TimeInterval = 60

    public static func involves(_ session: TrafficSession, ip: IPv4Address) -> Bool {
        session.source == ip || session.destination == ip
    }

    /// Clé stable d'une session : FortiGate, protocole et extrémités. Le numéro de FortiOS n'y
    /// entre pas : il peut être réutilisé, et sans numéro le relevé n'a qu'un rang dans la liste.
    public static func sessionKey(_ s: TrafficSession) -> String {
        "\(s.site)|\(s.proto)|\(s.source?.description ?? "")|\(s.sourcePort ?? -1)|\(s.destination?.description ?? "")|\(s.destinationPort ?? -1)"
    }

    /// L'autre extrémité et les volumes, vus de l'appareil.
    private static func oriented(_ s: TrafficSession, ip: IPv4Address) -> (remote: IPv4Address?, sent: UInt64, received: UInt64) {
        s.source == ip ? (s.destination, s.sentBytes, s.receivedBytes) : (s.source, s.receivedBytes, s.sentBytes)
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    /// Compteurs de sessions d'un relevé, à garder pour le relevé suivant.
    public static func counters(_ sessions: [TrafficSession], at: Date) -> DeviceTrafficCounters {
        var values: [String: DeviceTrafficCounters.Counter] = [:]
        for session in sessions {
            values[sessionKey(session)] = DeviceTrafficCounters.Counter(sent: session.sentBytes, received: session.receivedBytes)
        }
        return DeviceTrafficCounters(at: at, values: values)
    }

    /// Réunit les relevés des FortiGate du site. `known` : lignes Destinations et Applications déjà
    /// lues par l'écran Trafic (noms, pays, catégories, risques). `previous` : compteurs du relevé
    /// précédent. Une session absente du relevé précédent ne compte pas dans les débits : ses
    /// octets peuvent dater d'avant, si la liste était tronquée.
    public static func build(reads: [DeviceTrafficRead], ip: IPv4Address, known: [TrafficEntry] = [],
                             previous: DeviceTrafficCounters? = nil, now: Date = Date()) -> DeviceTrafficOverview {
        var seen = Set<String>()
        let sessions = reads.flatMap(\.sessions)
            .filter { involves($0, ip: ip) && seen.insert(sessionKey($0)).inserted }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }

        let elapsed = previous.map { now.timeIntervalSince($0.at) }
        // Sans session lue (droit manquant, panne) ou sans session du tout, les débits sont inconnus.
        let usable = reads.contains(where: \.sessionsRead) && !sessions.isEmpty && (elapsed.map { $0 >= 1 && $0 <= maxRateGap } ?? false)

        struct Sum {
            var entry: TrafficEntry
            var sendRate = 0.0
            var receiveRate = 0.0
        }
        var destinations: [String: Sum] = [:]
        var applications: [String: Sum] = [:]
        var totalSend = 0.0
        var totalReceive = 0.0

        func accumulate(_ store: inout [String: Sum], key: String, country: String?, make: () -> TrafficEntry,
                        sent: UInt64, received: UInt64, sendRate: Double, receiveRate: Double) {
            var sum = store[key] ?? Sum(entry: make())
            sum.entry.sentBytes = add(sum.entry.sentBytes, sent)
            sum.entry.receivedBytes = add(sum.entry.receivedBytes, received)
            sum.entry.sessions += 1
            sum.sendRate += sendRate
            sum.receiveRate += receiveRate
            sum.entry.bandwidth = sum.sendRate + sum.receiveRate
            if sum.entry.country == nil { sum.entry.country = country }
            store[key] = sum
        }

        let knownDestinations = Dictionary(known.filter { $0.view == .destinations && $0.ip != nil }.map { ($0.ip!, $0) }) { a, _ in a }
        let knownApplications = Dictionary(known.filter { $0.view == .applications }.map { ($0.name, $0) }) { a, _ in a }

        for session in sessions {
            let side = oriented(session, ip: ip)
            var sendRate = 0.0
            var receiveRate = 0.0
            if usable, let elapsed, let before = previous?.values[sessionKey(session)] {
                let beforeSent = session.source == ip ? before.sent : before.received
                let beforeReceived = session.source == ip ? before.received : before.sent
                // Compteur revenu en arrière (numéro réutilisé) : aucun débit plutôt qu'un pic.
                if side.sent >= beforeSent, side.received >= beforeReceived {
                    sendRate = Double(side.sent - beforeSent) * 8 / elapsed
                    receiveRate = Double(side.received - beforeReceived) * 8 / elapsed
                }
            }
            totalSend += sendRate
            totalReceive += receiveRate

            if let remote = side.remote {
                let name = remote.description
                // Le pays d'une session est celui de sa destination : valable seulement si elle sort.
                accumulate(&destinations, key: name, country: session.source == ip ? session.country : nil, make: {
                    let info = knownDestinations[remote]
                    return TrafficEntry(site: session.site, view: .destinations, key: name, name: info?.name ?? name, ip: remote,
                                        hostname: info?.hostname, country: info?.country)
                }, sent: side.sent, received: side.received, sendRate: sendRate, receiveRate: receiveRate)
            }
            let application = applicationName(session)
            accumulate(&applications, key: application, country: nil, make: {
                let info = knownApplications[application]
                return TrafficEntry(site: session.site, view: .applications, key: application, name: application,
                                    category: info?.category, risk: info?.risk)
            }, sent: side.sent, received: side.received, sendRate: sendRate, receiveRate: receiveRate)
        }

        let source = reads.compactMap(\.source)
        let fortiViewRate = source.isEmpty ? nil : source.reduce(0) { $0 + $1.bandwidth }
        let sessionSent = sessions.reduce(UInt64(0)) { add($0, oriented($1, ip: ip).sent) }
        let sessionReceived = sessions.reduce(UInt64(0)) { add($0, oriented($1, ip: ip).received) }
        let fortiViewSent = source.reduce(UInt64(0)) { add($0, $1.sentBytes) }
        let fortiViewReceived = source.reduce(UInt64(0)) { add($0, $1.receivedBytes) }
        let sessionRate = usable ? totalSend + totalReceive : nil

        var threatsSeen = Set<String>()
        var notes: [String] = []
        for note in reads.flatMap(\.notes) where !notes.contains(note) { notes.append(note) }

        return DeviceTrafficOverview(
            ip: ip,
            bandwidth: fortiViewRate.flatMap { $0 > 0 ? $0 : nil } ?? sessionRate ?? fortiViewRate,
            receiveBps: usable ? totalReceive : nil,
            sendBps: usable ? totalSend : nil,
            // La plus grande valeur : FortiView ne compte que les sessions dont l'appareil est la
            // source, la liste des sessions est limitée à ce que la FortiGate rend.
            sentBytes: max(fortiViewSent, sessionSent),
            receivedBytes: max(fortiViewReceived, sessionReceived),
            sessionCount: max(source.reduce(0) { $0 + $1.sessions }, sessions.count),
            destinations: ranked(destinations.values.map(\.entry)),
            applications: ranked(applications.values.map(\.entry)),
            sessions: sessions,
            threats: reads.flatMap(\.threats).filter { $0.ip == ip && threatsSeen.insert($0.id).inserted },
            notes: notes,
            readAt: reads.map(\.readAt).max() ?? now,
            sessionsKnown: reads.contains(where: \.sessionsRead),
            isComplete: !reads.isEmpty && reads.allSatisfy { $0.sessionsRead && $0.sourcesRead })
    }

    /// Application de FortiOS, sinon le protocole et le port (sans contrôle d'applications).
    private static func applicationName(_ session: TrafficSession) -> String {
        if let name = session.application?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return session.destinationPort.map { "\(session.proto)/\($0)" } ?? session.proto
    }

    private static func ranked(_ entries: [TrafficEntry]) -> [TrafficEntry] {
        entries.sorted {
            if $0.bandwidth != $1.bandwidth { return $0.bandwidth > $1.bandwidth }
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.key < $1.key
        }
    }
}

extension FortiGateReader {
    /// Sessions au plus par sens (limite de l'API).
    static let deviceSessionLimit = 1000

    /// Lit le trafic d'une adresse : sa ligne Sources, ses sessions (source et destination) et ses
    /// menaces. Erreur levée seulement si le jeton est refusé, si la FortiGate est injoignable ou
    /// si aucune des lectures n'a abouti.
    public func readDeviceTraffic(ip: IPv4Address, now: Date = Date()) async throws -> DeviceTrafficRead {
        var read = DeviceTrafficRead(ip: ip, readAt: now)
        var endpoints = Self.trafficEndpoints(.realtime)
        var failures: [FortiGateError] = []

        let sources = try await deviceView(.sources, count: 1000, endpoints: &endpoints, now: now)
        if let entries = sources.entries { read.source = entries.first { $0.ip == ip } }
        read.sourcesRead = sources.entries != nil
        note(.sources, sources.status, sources.error, into: &read, failures: &failures)

        let threats = try await deviceView(.threats, count: 200, endpoints: &endpoints, now: now)
        if let entries = threats.entries { read.threats = entries.filter { $0.ip == ip } }
        note(.threats, threats.status, threats.error, into: &read, failures: &failures)

        let sessions = try await deviceSessions(ip: ip)
        read.sessions = sessions.list
        read.sessionsRead = sessions.status == .ok || sessions.status == .empty
        read.notes += sessions.notes
        note(.sessions, sessions.status, sessions.error, into: &read, failures: &failures)

        let succeeded = [sources.status, threats.status, sessions.status].contains { $0 == .ok || $0 == .empty }
        if !succeeded, let failure = failures.first(where: { if case .forbidden = $0 { return true } else { return false } }) ?? failures.first {
            throw failure
        }
        return read
    }

    private func note(_ view: TrafficView, _ status: TrafficViewStatus, _ error: FortiGateError?,
                      into read: inout DeviceTrafficRead, failures: inout [FortiGateError]) {
        if let text = Self.trafficNote(view, status: status, error: error, period: .realtime) { read.notes.append(text) }
        if let error, status != .ok, status != .empty { failures.append(error) }
    }

    /// Une vue FortiView en temps réel : la première adresse qui existe sur cette version de FortiOS.
    private func deviceView(_ view: TrafficView, count: Int, endpoints: inout [String],
                            now: Date) async throws -> (entries: [TrafficEntry]?, status: TrafficViewStatus, error: FortiGateError?) {
        let options = TrafficReadOptions(period: .realtime, views: [view], sort: .bandwidth, count: count)
        var status = TrafficViewStatus.absent
        var lastError: FortiGateError?
        for reportBy in view.reportBy {
            while let endpoint = endpoints.first {
                let fetched = try await fetch(endpoint, query: Self.trafficQuery(endpoint: endpoint, reportBy: reportBy, options: options, now: now))
                guard let error = fetched.error else {
                    endpoints = [endpoint]
                    if let body = fetched.response?.body, let parsed = TrafficParsers.entries(body, view: view) {
                        return (parsed, parsed.isEmpty ? .empty : .ok, nil)
                    }
                    return (nil, .failed, .invalidResponse(path: endpoint))
                }
                if case .notFound = error, endpoints.count > 1 {
                    endpoints.removeFirst()
                    continue
                }
                lastError = error
                if case .forbidden = error { return (nil, .refused, error) }
                if case .notFound = error { return (nil, .absent, error) }
                // Valeur de « report_by » inconnue de cette version : la suivante, comme l'écran Trafic.
                if isUnsupported(error) {
                    status = .absent
                    break
                }
                return (nil, .failed, error)
            }
        }
        return (nil, status, lastError)
    }

    /// Réponse d'une version de FortiOS qui ne connaît pas une valeur ou un paramètre.
    private func isUnsupported(_ error: FortiGateError?) -> Bool {
        switch error {
        case .apiError?: return true
        case .http(let code, _)?: return code == 400 || code == 422 || code == 500
        default: return false
        }
    }

    /// Sessions de l'adresse. Si FortiOS ne connaît pas le filtre (refus ou réponse non filtrée), on
    /// garde ses sessions dans la liste générale, et une remarque le dit. Si seul le second sens
    /// échoue, le premier est gardé, et une remarque le dit aussi.
    private func deviceSessions(ip: IPv4Address) async throws -> (list: [TrafficSession], status: TrafficViewStatus, error: FortiGateError?, notes: [String]) {
        var found: [TrafficSession] = []
        var anyRead = false
        var lastError: FortiGateError?
        var filterIgnored = false
        var truncated = false
        var incomingLost: FortiGateError?

        func request(_ filter: String?) async throws -> (list: [TrafficSession]?, error: FortiGateError?) {
            var query = [URLQueryItem(name: "count", value: String(Self.deviceSessionLimit)), URLQueryItem(name: "summary", value: "true")]
            if let filter { query.append(URLQueryItem(name: filter, value: ip.description)) }
            let fetched = try await fetch(TrafficPaths.sessions, query: query)
            if let error = fetched.error { return (nil, error) }
            guard let body = fetched.response?.body, let list = TrafficParsers.sessions(body) else {
                return (nil, .invalidResponse(path: TrafficPaths.sessions))
            }
            return (list, nil)
        }

        func keep(_ list: [TrafficSession]) {
            anyRead = true
            truncated = truncated || list.count >= Self.deviceSessionLimit
            found += list.filter { DeviceTrafficAnalysis.involves($0, ip: ip) }
        }

        for (index, filter) in ["srcaddr", "dstaddr"].enumerated() {
            let result = try await request(filter)
            if let list = result.list {
                keep(list)
                if list.contains(where: { !DeviceTrafficAnalysis.involves($0, ip: ip) }) {
                    // Filtre sans effet : la liste contient déjà les deux sens.
                    filterIgnored = true
                    break
                }
                continue
            }
            lastError = result.error
            if isUnsupported(result.error) {
                // Paramètre inconnu de cette version : la liste générale.
                let general = try await request(nil)
                if let list = general.list {
                    keep(list)
                    filterIgnored = true
                    break
                }
                lastError = general.error
            }
            if index == 0 {
                if case .forbidden? = lastError { return ([], .refused, lastError, []) }
                if case .notFound? = lastError { return ([], .absent, lastError, []) }
            } else {
                incomingLost = lastError
            }
            break
        }

        guard anyRead else { return ([], .failed, lastError, []) }
        let status: TrafficViewStatus = found.isEmpty ? .empty : .ok
        var notes: [String] = []
        if let incomingLost {
            notes.append("Sessions\u{00A0}: connexions entrantes illisibles (\(incomingLost.errorDescription ?? "erreur de lecture"))\u{00A0}; seules les sortantes sont montrées.")
        }
        if filterIgnored {
            notes.append("Sessions\u{00A0}: cette version de FortiOS ne filtre pas par adresse\u{00A0}; seules les sessions de cet appareil parmi les \(Self.deviceSessionLimit) premières sont montrées.")
        } else if truncated {
            notes.append("Sessions\u{00A0}: plus de \(Self.deviceSessionLimit) sessions pour cet appareil\u{00A0}; les suivantes ne sont pas comptées.")
        }
        return (found, status, nil, notes)
    }
}
