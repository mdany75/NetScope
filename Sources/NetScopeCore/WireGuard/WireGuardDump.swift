import Foundation

// Note 100 (1.3.0) : serveur WireGuard (wg-easy) lu par SSH. Analyse de « wg show all dump ».
// La clé privée de l'interface et les clés partagées des pairs ne sont jamais gardées : le script
// distant les remplace déjà, et l'analyse ignore ces colonnes de toute façon.

/// Interface WireGuard du serveur (wg0).
public struct WireGuardInterfaceInfo: Equatable, Codable, Sendable {
    public var name: String
    public var publicKey: String
    public var listenPort: Int?

    public init(name: String, publicKey: String, listenPort: Int?) {
        self.name = name
        self.publicKey = publicKey
        self.listenPort = listenPort
    }
}

/// Pair (client) vu par le noyau : clé publique, IP d'origine, adresses permises, poignée de main, octets.
public struct WireGuardPeer: Equatable, Codable, Identifiable, Sendable {
    public var id: String { publicKey }
    public var interface: String
    public var publicKey: String
    /// « 203.0.113.58:51820 » (nil : jamais vu).
    public var endpoint: String?
    public var allowedIPs: [String]
    public var latestHandshake: Date?
    /// Octets reçus par le serveur (envoyés par le client) et envoyés au client.
    public var receivedBytes: Int64
    public var sentBytes: Int64
    public var keepalive: Int?

    public init(interface: String = "wg0", publicKey: String, endpoint: String?, allowedIPs: [String], latestHandshake: Date?,
                receivedBytes: Int64, sentBytes: Int64, keepalive: Int? = nil) {
        self.interface = interface
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.latestHandshake = latestHandshake
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.keepalive = keepalive
    }

    /// Adresse IP d'origine seule (sans le port, IPv6 sans crochets).
    public var endpointAddress: String? {
        guard let endpoint else { return nil }
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<colon])
    }
}

/// Résultat de « wg show all dump ».
public struct WireGuardDump: Equatable, Codable, Sendable {
    public var interfaces: [WireGuardInterfaceInfo]
    public var peers: [WireGuardPeer]

    public init(interfaces: [WireGuardInterfaceInfo] = [], peers: [WireGuardPeer] = []) {
        self.interfaces = interfaces
        self.peers = peers
    }

    /// Une poignée de main de moins de 3 minutes : client connecté (WireGuard renégocie toutes les 2 minutes).
    public static let connectedWindow: TimeInterval = 180

    /// Analyse ligne par ligne (tabulations). Interface : 5 colonnes (nom, clé privée, clé publique,
    /// port, fwmark) ; pair : 9 colonnes (nom, clé publique, clé partagée, endpoint, adresses,
    /// poignée de main, reçus, envoyés, keepalive). Les colonnes secrètes sont ignorées.
    public static func parse(_ text: String) -> WireGuardDump {
        var dump = WireGuardDump()
        for raw in text.split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            if fields.count == 5 {
                guard isKey(fields[2]) else { continue }
                dump.interfaces.append(WireGuardInterfaceInfo(name: fields[0], publicKey: fields[2], listenPort: Int(fields[3])))
            } else if fields.count == 9 {
                guard isKey(fields[1]) else { continue }
                let endpoint = fields[3] == "(none)" || fields[3].isEmpty ? nil : fields[3]
                let allowed = fields[4] == "(none)" ? [] : fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let stamp = TimeInterval(fields[5]) ?? 0
                dump.peers.append(WireGuardPeer(interface: fields[0], publicKey: fields[1], endpoint: endpoint, allowedIPs: allowed,
                                                latestHandshake: stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil,
                                                receivedBytes: Int64(fields[6]) ?? 0, sentBytes: Int64(fields[7]) ?? 0,
                                                keepalive: Int(fields[8])))
            }
        }
        return dump
    }

    /// Clé WireGuard en base64 (44 caractères, « = » final).
    public static func isKey(_ text: String) -> Bool {
        text.count == 44 && text.hasSuffix("=") && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }
    }
}
