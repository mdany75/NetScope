import Foundation
import Network

/// État d'un port TCP après une tentative de connexion.
public enum PortState: String, Sendable, Codable {
    /// Connexion acceptée.
    case open
    /// Connexion refusée (RST) : l'hôte répond, rien n'écoute.
    case closed
    /// Aucune réponse dans le délai (pare-feu, hôte absent).
    case filtered

    public var label: String {
        switch self {
        case .open: return "ouvert"
        case .closed: return "fermé"
        case .filtered: return "filtré"
        }
    }
}

public struct PortScanResult: Identifiable, Hashable, Sendable, Codable {
    public var port: UInt16
    public var state: PortState
    /// Délai d'établissement de la connexion.
    public var rttMs: Double?
    public var banner: String?
    /// Note 68 : ce que le service a répondu (en-têtes HTTP, certificat TLS, dialecte SMB…), pour l'empreinte.
    public var observation: FPServiceObservation?
    public var id: UInt16 { port }

    public init(port: UInt16, state: PortState, rttMs: Double? = nil, banner: String? = nil,
                observation: FPServiceObservation? = nil) {
        self.port = port
        self.state = state
        self.rttMs = rttMs
        self.banner = banner
        self.observation = observation
    }

    public var service: String? { PortScanner.serviceName(port) }
}

public struct PortScanOptions: Sendable {
    /// Délai de connexion par port.
    public var timeout: TimeInterval
    /// Connexions simultanées.
    public var concurrency: Int
    /// Lit une bannière sur les ports texte (SSH, FTP, SMTP…) et envoie HEAD sur les ports HTTP.
    public var grabBanners: Bool
    public var bannerTimeout: TimeInterval
    /// Ports supplémentaires sur lesquels écouter une bannière (tests, services maison).
    public var extraListenPorts: Set<UInt16>

    public init(timeout: TimeInterval = 1.5, concurrency: Int = 64, grabBanners: Bool = true,
                bannerTimeout: TimeInterval = 2, extraListenPorts: Set<UInt16> = []) {
        self.timeout = timeout
        self.concurrency = concurrency
        self.grabBanners = grabBanners
        self.bannerTimeout = bannerTimeout
        self.extraListenPorts = extraListenPorts
    }
}

/// Bilan d'un scan.
public struct PortScanSummary: Sendable {
    public var host: String
    public var results: [PortScanResult]
    public var scannedCount: Int
    public var duration: TimeInterval
    public var wasCancelled: Bool

    public var open: [PortScanResult] { results.filter { $0.state == .open } }
    public var closedCount: Int { results.filter { $0.state == .closed }.count }
    public var filteredCount: Int { results.filter { $0.state == .filtered }.count }

    /// « 4 ports ouverts, 1 filtré, 1 019 fermés ».
    public var summary: String {
        let openCount = open.count
        var parts = [openCount <= 1 ? "\(openCount) port ouvert" : "\(openCount) ports ouverts"]
        if filteredCount > 0 { parts.append(filteredCount == 1 ? "1 filtré" : "\(ToolFormat.integer(filteredCount)) filtrés") }
        if closedCount > 0 { parts.append(closedCount == 1 ? "1 fermé" : "\(ToolFormat.integer(closedCount)) fermés") }
        return parts.joined(separator: ", ")
    }
}

/// Scan de ports TCP par NWConnection, avec concurrence limitée et lecture de bannières simples.
public enum PortScanner {
    /// Ports où le serveur parle le premier (bannière à lire).
    public static let listenBannerPorts: Set<UInt16> = [21, 22, 23, 25, 110, 143, 587, 3306, 5900]
    /// Ports HTTP en clair (requête HEAD).
    public static let httpPorts: Set<UInt16> = [80, 81, 591, 8000, 8008, 8080, 8081, 8088, 8888, 9000]
    public static let maxPorts = 65_535

    /// Scanne `ports` sur `host` (IP ou nom). `progress` reçoit (faits, total, dernier résultat).
    public static func scan(host: String, ports: [UInt16], options: PortScanOptions = PortScanOptions(),
                            progress: (@Sendable (Int, Int, PortScanResult) -> Void)? = nil) async -> PortScanSummary {
        let start = Date()
        let list = Array(Set(ports)).sorted()
        let width = max(1, min(options.concurrency, 256))
        var results: [PortScanResult] = []
        results.reserveCapacity(list.count)
        await withTaskGroup(of: PortScanResult.self) { group in
            var iterator = list.makeIterator()
            for _ in 0..<width {
                guard let port = iterator.next() else { break }
                group.addTask { await probe(host: host, port: port, options: options) }
            }
            var done = 0
            while let result = await group.next() {
                done += 1
                results.append(result)
                progress?(done, list.count, result)
                if Task.isCancelled { group.cancelAll(); continue }
                if let port = iterator.next() {
                    group.addTask { await probe(host: host, port: port, options: options) }
                }
            }
        }
        return PortScanSummary(host: host, results: results.sorted { $0.port < $1.port }, scannedCount: results.count,
                               duration: Date().timeIntervalSince(start), wasCancelled: Task.isCancelled)
    }

    /// Une connexion TCP : ouvert, fermé ou filtré, avec bannière si demandé.
    public static func probe(host: String, port: UInt16, options: PortScanOptions = PortScanOptions()) async -> PortScanResult {
        guard !Task.isCancelled, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return PortScanResult(port: port, state: .filtered)
        }
        let strategy = options.grabBanners ? bannerStrategy(port, extra: options.extraListenPorts) : .none
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = max(1, Int(options.timeout.rounded(.up)))
            tcp.noDelay = true
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "netscope.portscan.\(port)")
        let start = Date()

        return await withCheckedContinuation { continuation in
            let once = ToolOnce()
            @Sendable func finish(_ result: PortScanResult) {
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let rtt = Date().timeIntervalSince(start) * 1000
                    grabService(connection, host: host, port: port, strategy: strategy, timeout: options.bannerTimeout,
                                queue: queue) { banner, observation in
                        finish(PortScanResult(port: port, state: .open, rttMs: rtt, banner: banner, observation: observation))
                    }
                case .waiting(let error), .failed(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        finish(PortScanResult(port: port, state: .closed, rttMs: Date().timeIntervalSince(start) * 1000))
                    } else if case .failed = state {
                        finish(PortScanResult(port: port, state: .filtered))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + options.timeout) {
                // Connexion pas encore établie : filtré. Une bannière en cours de lecture a son propre délai.
                if connection.state != .ready { finish(PortScanResult(port: port, state: .filtered)) }
            }
        }
    }

    /// Vrai si l'hôte répond sur l'un des ports (connexion acceptée ou refusée).
    public static func isHostUp(host: String, ports: [UInt16] = [445, 22, 3389, 80, 443, 139, 5900],
                                timeout: TimeInterval = 1.5) async -> Bool {
        let options = PortScanOptions(timeout: timeout, concurrency: ports.count, grabBanners: false)
        let summary = await scan(host: host, ports: ports, options: options)
        return summary.results.contains { $0.state != .filtered }
    }

    // MARK: Bannières

    enum BannerStrategy: Equatable {
        /// Note 68 : `tls` (certificat, puis HEAD sur un port web), `smb` (négociation SMB2 seule).
        case none, listen, httpHead, tls, smb
    }

    static func bannerStrategy(_ port: UInt16, extra: Set<UInt16>) -> BannerStrategy {
        if listenBannerPorts.contains(port) || extra.contains(port) { return .listen }
        if httpPorts.contains(port) { return .httpHead }
        if tlsBannerPorts.contains(port) { return .tls }
        if port == 445 { return .smb }
        return .none
    }

    /// Première ligne lisible ; pour HTTP, ligne d'état + en-tête Server.
    public static func cleanBanner(_ data: Data, http: Bool) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: CharacterSet.newlines).map {
            String($0.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        if http {
            let server = lines.first { $0.lowercased().hasPrefix("server:") }
            let status = first.hasPrefix("HTTP/") ? first : nil
            let parts = [status, server].compactMap { $0 }
            return parts.isEmpty ? String(first.prefix(120)) : parts.joined(separator: " · ")
        }
        return String(first.prefix(120))
    }

    // MARK: Services

    /// Nom usuel d'un port TCP.
    public static func serviceName(_ port: UInt16) -> String? {
        serviceNames[port]
    }

    /// Nom usuel d'un port UDP (21116/udp de RustDesk, sinon le nom TCP du même port).
    public static func udpServiceName(_ port: UInt16) -> String? {
        RustDeskPorts.udpServiceName(port) ?? serviceNames[port]
    }

    static let serviceNames: [UInt16: String] = [
        20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns", 67: "dhcp", 69: "tftp",
        80: "http", 81: "http", 88: "kerberos", 110: "pop3", 111: "rpcbind", 123: "ntp", 135: "msrpc",
        137: "netbios-ns", 139: "netbios", 143: "imap", 161: "snmp", 389: "ldap", 443: "https", 445: "smb",
        465: "smtps", 515: "lpd", 541: "fortinet", 548: "afp", 554: "rtsp", 587: "submission", 631: "ipp",
        636: "ldaps", 853: "dns-tls", 873: "rsync", 902: "vmware", 993: "imaps", 995: "pop3s",
        1080: "socks", 1433: "mssql", 1521: "oracle", 1723: "pptp", 1883: "mqtt", 1900: "ssdp",
        2049: "nfs", 2222: "ssh-alt", 3000: "http-dev", 3128: "proxy", 3268: "ldap-gc", 3306: "mysql",
        3389: "rdp", 4443: "https-alt", 5000: "upnp", 5001: "https-alt", 5060: "sip", 5061: "sips", 5222: "xmpp",
        5353: "mdns", 5432: "postgresql", 5900: "vnc", 5985: "winrm", 5986: "winrm-tls", 6379: "redis",
        6443: "kubernetes", 7070: "rtsp-alt", 8000: "http-alt", 8008: "http-alt", 8080: "http-alt",
        8081: "http-alt", 8088: "http-alt", 8291: "winbox", 8443: "https-alt", 8554: "rtsp-alt",
        8883: "mqtt-tls", 8888: "http-alt", 9000: "http-alt", 9100: "jetdirect", 9200: "elasticsearch",
        9443: "https-alt", 10000: "webmin", 11211: "memcached", 27017: "mongodb", 32400: "plex",
        21115: "rustdesk-nat", 21116: "rustdesk-id", 21117: "rustdesk-relais", 21118: "rustdesk-direct",
        21119: "rustdesk-ws", 37777: "dahua",
    ]

    /// Ports à ouvrir dans un navigateur, avec le schéma correspondant.
    public static func webScheme(for port: UInt16) -> String? {
        switch port {
        case 443, 4443, 5001, 8443, 9443, 10443: return "https"
        case 80, 81, 591, 3000, 5000, 8000, 8008, 8080, 8081, 8088, 8888, 9000, 10000: return "http"
        default: return nil
        }
    }
}
