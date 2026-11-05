import Foundation

// « Tester le serveur » (note 55), avant le test de vitesse d'un partage : nom résolu, ping, et
// ports des services de partage (445 SMB, 139 NetBIOS, 2049 NFS, 548 AFP, 80 et 443 WebDAV). Le
// bilan en clair (`assessment`) est pur et vérifié sur des relevés fixes ; seul `DiskServerProbe.run`
// touche au réseau, et il n'est jamais appelé dans les tests ni en démonstration.

/// Port vérifié et ce qu'il indique.
public struct DiskServerPort: Hashable, Sendable {
    public var port: UInt16
    /// « SMB », « NetBIOS (SMB1) », « NFS », « AFP », « WebDAV (HTTP) », « WebDAV (HTTPS) ».
    public var service: String

    public init(port: UInt16, service: String) {
        self.port = port
        self.service = service
    }
}

public enum DiskServerCheck {
    /// Ports vérifiés, dans l'ordre affiché.
    public static let ports: [DiskServerPort] = [
        DiskServerPort(port: 445, service: "SMB"),
        DiskServerPort(port: 139, service: "NetBIOS (SMB1)"),
        DiskServerPort(port: 2049, service: "NFS"),
        DiskServerPort(port: 548, service: "AFP"),
        DiskServerPort(port: 80, service: "WebDAV (HTTP)"),
        DiskServerPort(port: 443, service: "WebDAV (HTTPS)"),
    ]

    /// Ports à vérifier pour un emplacement : la liste habituelle, plus un port choisi à la main.
    public static func portsToTest(kind: DiskShareKind, customPort: Int? = nil) -> [UInt16] {
        var list = ports.map(\.port)
        for port in kind.ports() where !list.contains(port) { list.append(port) }
        if let customPort, (1...65_535).contains(customPort), !list.contains(UInt16(customPort)) {
            list.append(UInt16(customPort))
        }
        return list
    }

    public static func serviceName(_ port: UInt16) -> String {
        ports.first { $0.port == port }?.service ?? PortScanner.serviceName(port)?.uppercased() ?? "TCP \(port)"
    }
}

/// Résultat de « Tester le serveur ».
public struct DiskServerReport: Hashable, Sendable {
    public var host: String
    /// Adresse IPv4 résolue (nil : nom introuvable).
    public var address: String?
    /// Latence moyenne du ping (nil : pas de réponse, souvent filtré).
    public var pingMs: Double?
    public var ports: [PortScanResult]
    public var date: Date

    public init(host: String, address: String?, pingMs: Double?, ports: [PortScanResult], date: Date = Date()) {
        self.host = host
        self.address = address
        self.pingMs = pingMs
        self.ports = ports
        self.date = date
    }

    public func state(_ port: UInt16) -> PortState? { ports.first { $0.port == port }?.state }
    public func isOpen(_ port: UInt16) -> Bool { state(port) == .open }

    /// Le serveur a répondu d'une façon ou d'une autre (ping, port ouvert ou refusé).
    public var isReachable: Bool {
        pingMs != nil || ports.contains { $0.state == .open || $0.state == .closed }
    }

    /// Bilan pour le type choisi.
    public func assessment(kind: DiskShareKind, secure: Bool = true, customPort: Int? = nil) -> DiskServerAssessment {
        guard address != nil else {
            return DiskServerAssessment(tone: .critical, title: "Nom introuvable",
                                        detail: "«\u{00A0}\(host)\u{00A0}» ne se résout pas en adresse IP. Vérifiez l’orthographe, ou utilisez l’adresse IP (bouton de la liste des appareils).")
        }
        let open = ports.filter { $0.state == .open }.map(\.port)
        let wanted = customPort.map { [UInt16($0)] } ?? kind.ports(secure: secure)
        let ping = pingMs.map { "ping " + DiskFormat.latency($0) } ?? "pas de réponse au ping (souvent filtré)"
        if let port = wanted.first(where: { isOpen($0) }) {
            let rtt = ports.first { $0.port == port }?.rttMs.map { " en " + DiskFormat.latency($0) } ?? ""
            return DiskServerAssessment(tone: .success, title: "\(kind.label) joignable",
                                        detail: "Port \(port) (\(DiskServerCheck.serviceName(port))) ouvert\(rtt)\u{00A0}; \(ping). Le partage peut être monté.")
        }
        // Service voulu fermé : un autre service de partage répond ?
        let suggestion = DiskShareKind.suggested(openPorts: open)
        if kind == .smb, !isOpen(445), isOpen(139) {
            return DiskServerAssessment(tone: .warning, title: "SMB1 seulement, probablement",
                                        detail: "Le port 445 est \(state(445)?.label ?? "fermé") mais le 139 (NetBIOS) répond\u{00A0}: vieux serveur qui ne parle que SMB1, que macOS refuse. Activez SMB2 ou SMB3 sur le serveur.",
                                        suggested: nil)
        }
        if let suggestion, suggestion.kind != kind, kind.isMountable || kind == .dossier {
            let list = open.map { "\($0)" }.joined(separator: ", ")
            return DiskServerAssessment(tone: .warning, title: "\(kind.label) ne répond pas",
                                        detail: "Port \(wanted.map(String.init).joined(separator: "/")) \(state(wanted.first ?? 0)?.label ?? "fermé")\u{00A0}; ports ouverts\u{00A0}: \(list). Le serveur propose plutôt \(suggestion.kind.label).",
                                        suggested: suggestion.kind)
        }
        if isReachable {
            let what = state(wanted.first ?? 0) == .filtered ? "filtré (pare-feu)" : "fermé (service arrêté)"
            return DiskServerAssessment(tone: .warning, title: "Serveur joignable, \(kind.label) fermé",
                                        detail: "Le serveur répond (\(ping)), mais le port \(wanted.map(String.init).joined(separator: "/")) est \(what). Activez le service \(kind.label) sur le NAS ou ouvrez le port.")
        }
        return DiskServerAssessment(tone: .critical, title: "Serveur injoignable",
                                    detail: "Ni ping ni port de partage\u{00A0}: appareil éteint, autre VLAN ou VPN déconnecté. Adresse résolue\u{00A0}: \(address ?? host).")
    }
}

/// Bilan affiché sous « Tester le serveur ».
public struct DiskServerAssessment: Hashable, Sendable {
    public var tone: DiskVerdict.Tone
    public var title: String
    public var detail: String
    /// Type à essayer à la place (le service choisi ne répond pas, un autre oui).
    public var suggested: DiskShareKind?

    public init(tone: DiskVerdict.Tone, title: String, detail: String, suggested: DiskShareKind? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.suggested = suggested
    }
}

public enum DiskServerProbe {
    /// Résout, pingue (3 fois) et vérifie les ports. Réseau réel : jamais dans les tests.
    public static func run(host: String, kind: DiskShareKind, customPort: Int? = nil) async -> DiskServerReport {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = try? await PingResolver.resolveAsync(trimmed) else {
            return DiskServerReport(host: trimmed, address: nil, pingMs: nil, ports: [])
        }
        let target = address.description
        async let ping = DiskNetworkProbe.serverLatency(target, count: 3)
        async let scan = PortScanner.scan(host: target, ports: DiskServerCheck.portsToTest(kind: kind, customPort: customPort),
                                          options: PortScanOptions(timeout: 2, concurrency: 8, grabBanners: false))
        let (latency, summary) = await (ping, scan)
        return DiskServerReport(host: trimmed, address: target, pingMs: latency, ports: summary.results)
    }
}
