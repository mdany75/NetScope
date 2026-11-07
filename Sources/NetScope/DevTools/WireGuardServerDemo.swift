import Foundation
import NetScopeCore

/// Note 100 (1.3.0) : serveur WireGuard fictif (wg-easy 15 sur le serveur de démonstration
/// assistance.exemple.ca). Noms inventés, adresses de documentation (198.51.100.0/24, 203.0.113.0/24),
/// clés publiques fabriquées ; aucune clé privée, aucun ssh, aucune requête.
enum WireGuardServerDemo {
    static let apiURL = "http://assistance.exemple.ca:51821"

    /// Clé publique fictive (base64 de 32 octets tirés du nom).
    static func key(_ seed: String) -> String {
        var bytes = Array(("netscope-demo-" + seed).utf8.prefix(32))
        while bytes.count < 32 { bytes.append(0x2E) }
        return Data(bytes).base64EncodedString()
    }

    struct Person {
        let id: Int
        let name: String
        let ip: Int
        let endpoint: String?
        /// Secondes depuis la dernière poignée de main (nil : jamais).
        let handshake: TimeInterval?
        let rx: Int64
        let tx: Int64
        var enabled = true
        var expiresInDays: Double?
    }

    static let people: [Person] = [
        Person(id: 1, name: "Portable de Julie (siège)", ip: 2, endpoint: "198.51.100.37:51820", handshake: 42, rx: 1_284_000_000, tx: 6_920_000_000),
        Person(id: 2, name: "Cellulaire de Marc", ip: 3, endpoint: "203.0.113.84:40213", handshake: 95, rx: 182_000_000, tx: 944_000_000),
        Person(id: 3, name: "Poste télétravail – comptabilité", ip: 4, endpoint: "203.0.113.19:51820", handshake: 12, rx: 3_410_000_000, tx: 12_800_000_000),
        Person(id: 4, name: "Routeur succursale Nord", ip: 5, endpoint: "198.51.100.140:51820", handshake: 7 * 3_600, rx: 21_400_000_000, tx: 8_310_000_000),
        Person(id: 5, name: "Tablette de l’entrepôt", ip: 6, endpoint: nil, handshake: 3 * 86_400, rx: 48_000_000, tx: 120_000_000),
        Person(id: 6, name: "Fournisseur – accès temporaire", ip: 7, endpoint: "203.0.113.201:62011", handshake: 600, rx: 9_000_000, tx: 31_000_000,
               expiresInDays: 3),
        Person(id: 7, name: "Ancien stagiaire", ip: 8, endpoint: nil, handshake: nil, rx: 0, tx: 0, enabled: false, expiresInDays: -12),
    ]

    static var serverKey: String { key("serveur-wg0") }

    /// Clients importants (surveillés) : le routeur de la succursale et le poste de comptabilité.
    static let watch = WireGuardWatchSettings(importantKeys: [key("Routeur succursale Nord"), key("Poste télétravail – comptabilité")],
                                              disconnectedHours: 4, expiryDays: 7)

    static func status(now: Date, edition: WireGuardEdition = .v15) -> WireGuardServerStatus {
        var status = WireGuardServerStatus(readAt: now, access: "ok",
                                           container: WireGuardContainer(name: "wg-easy", state: "running", startedAt: now.addingTimeInterval(-6 * 86_400 - 5 * 3_600),
                                                                         restarts: 0, image: edition == .v14 ? "ghcr.io/wg-easy/wg-easy:14" : "ghcr.io/wg-easy/wg-easy:15",
                                                                         imageID: "sha256:7c1e", version: edition == .v14 ? "14" : "15.1.0"))
        status.environment = ["INSECURE": "true", "PORT": "51821", "WG_PORT": "51820"]
        status.edition = edition
        status.complete = true
        status.dump = WireGuardDump(interfaces: [WireGuardInterfaceInfo(name: "wg0", publicKey: serverKey, listenPort: 51820)],
                                    peers: people.filter(\.enabled).map { person in
                                        WireGuardPeer(publicKey: key(person.name), endpoint: person.endpoint, allowedIPs: ["10.8.0.\(person.ip)/32"],
                                                      latestHandshake: person.handshake.map { now.addingTimeInterval(-$0) },
                                                      receivedBytes: person.rx, sentBytes: person.tx, keepalive: 25)
                                    })
        let known = people.map { person in
            WireGuardKnownClient(id: String(person.id), name: person.name, ipv4: "10.8.0.\(person.ip)", ipv6: "fdcc:ad94:bacf:61a4::cafe:\(person.ip)",
                                 publicKey: key(person.name), enabled: person.enabled,
                                 expiresAt: person.expiresInDays.map { now.addingTimeInterval($0 * 86_400) })
        }
        if edition == .v14 { status.legacyClients = known } else { status.databaseClients = known }
        status.logs = [
            "\(stamp(now, -6 * 86_400)) Starting Wireguard Interface wg0...",
            "\(stamp(now, -6 * 86_400)) Interface wg0 started successfully.",
            "\(stamp(now, -6 * 86_400)) Listening on http://0.0.0.0:51821",
            "\(stamp(now, -2 * 86_400)) Client 6 created.",
            "\(stamp(now, -3_600)) Cron job: client 7 expired, disabled.",
        ]
        return status
    }

    static func apiClients(now: Date) -> [WGEasyClient] {
        people.map { person in
            WGEasyClient(id: person.id, name: person.name, enabled: person.enabled, ipv4Address: "10.8.0.\(person.ip)",
                         ipv6Address: "fdcc:ad94:bacf:61a4::cafe:\(person.ip)", publicKey: key(person.name),
                         expiresAt: person.expiresInDays.map { now.addingTimeInterval($0 * 86_400) },
                         createdAt: now.addingTimeInterval(-Double(90 - person.id * 9) * 86_400),
                         latestHandshakeAt: person.handshake.map { now.addingTimeInterval(-$0) }, endpoint: person.endpoint,
                         transferRx: person.rx, transferTx: person.tx, dns: person.id == 4 ? ["10.20.0.1"] : nil)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static let information = WGEasyInformation(currentRelease: "15.1.0", latestRelease: "15.1.2", updateAvailable: true, insecure: true)

    /// Six heures de mesures : 3 à 5 clients connectés, débit de 2 à 9 Mbit/s.
    static func samples(now: Date) -> [WireGuardSample] {
        var result: [WireGuardSample] = []
        var rx: Int64 = 30_000_000_000, tx: Int64 = 26_000_000_000
        for step in stride(from: 6 * 3_600, through: 0, by: -300) {
            let phase = Double(step) / 3_600
            let rate = 400_000 + 300_000 * (1 + sin(phase * 1.3))
            rx += Int64(rate * 300 * 0.35)
            tx += Int64(rate * 300)
            result.append(WireGuardSample(date: now.addingTimeInterval(-Double(step)), connected: step > 4 * 3_600 ? 5 : (step > 3_600 ? 4 : 5),
                                          receivedBytes: rx, sentBytes: tx))
        }
        return result
    }

    /// Fichier .conf fictif (montré puis oublié) : la clé privée est remplacée par un texte d'exemple.
    static func configuration(for client: WGEasyClient) -> String {
        """
        [Interface]
        PrivateKey = (clé privée de démonstration, jamais gardée)
        Address = \(client.ipv4Address ?? "10.8.0.9")/24
        DNS = 1.1.1.1

        [Peer]
        PublicKey = \(serverKey)
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 0
        Endpoint = assistance.exemple.ca:51820
        """
    }

    private static func stamp(_ now: Date, _ offset: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: now.addingTimeInterval(offset))
    }
}
