import Foundation

/// Nom Bonjour (mDNS) d'un hôte : requête PTR « d.c.b.a.in-addr.arpa » envoyée en unicast à
/// <ip>:5353 (Mac, iPhone, imprimantes, Chromecast, NAS y répondent), puis, en repli, au groupe
/// 224.0.0.251:5353 avec le bit QU (réponse unicast demandée).
///
/// Un seul socket UDP sert toutes les requêtes de l'instance, même simultanées : les réponses
/// sont associées par le nom interrogé (ou par l'adresse d'un enregistrement A).
public final class NamesMDNS: ScanNameResolving, @unchecked Sendable {
    public static let defaultPort: UInt16 = 5353

    /// Port de destination de la requête unicast (5353 ; injectable pour les tests).
    public let unicastPort: UInt16
    /// Hôte de destination forcé (tests) ; `nil` : l'adresse interrogée elle-même.
    public let unicastHost: IPv4Address?
    /// Destination du repli multicast ; `nil` : pas de repli.
    public let multicast: NamesEndpoint?
    /// Attente avant le repli multicast si l'unicast reste muet.
    public let fallbackDelay: Duration

    private let provider: NamesChannelProvider

    public init(unicastPort: UInt16 = NamesMDNS.defaultPort, unicastHost: IPv4Address? = nil,
                multicast: NamesEndpoint? = .mdnsMulticast, fallbackDelay: Duration = .milliseconds(350)) {
        self.unicastPort = unicastPort
        self.unicastHost = unicastHost
        self.multicast = multicast
        self.fallbackDelay = fallbackDelay
        provider = NamesChannelProvider()
    }

    /// Nom complet (« Macmini-de-Dany.local »), ou `nil` sans réponse dans le délai.
    public func name(for ip: IPv4Address, timeout: Duration = .milliseconds(1500)) async -> String? {
        guard let channel = provider.get() else { return nil }
        let id = channel.makeTransactionID()
        var sends = [NamesUDPChannel.Send(delay: .zero, bytes: Self.query(for: ip, id: id, unicastResponse: false),
                                          destination: NamesEndpoint(unicastHost ?? ip, port: unicastPort))]
        if let multicast {
            sends.append(NamesUDPChannel.Send(delay: fallbackDelay, bytes: Self.query(for: ip, id: id, unicastResponse: true),
                                              destination: multicast))
        }
        let packet = await channel.request(sends, timeout: timeout) { packet, _ in
            Self.hostname(in: packet, for: ip) != nil
        }
        return packet.flatMap { Self.hostname(in: $0, for: ip) }
    }

    /// Requête PTR pour l'adresse : une question, sans récursion, classe IN
    /// (0x8001 avec le bit QU si `unicastResponse`).
    public static func query(for ip: IPv4Address, id: UInt16, unicastResponse: Bool) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in DNSLookup.reverseName(for: ip).split(separator: ".") {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes += [0, 0, 12, unicastResponse ? 0x80 : 0x00, 0x01]
        return bytes
    }

    /// Nom de l'hôte dans une réponse : PTR du nom inverse de `ip` (réponses ou additionnels),
    /// sinon nom d'un enregistrement A qui pointe vers `ip`. `nil` si la réponse ne le concerne pas.
    public static func hostname(in response: [UInt8], for ip: IPv4Address) -> String? {
        guard let message = try? DNSMessageCodec.parse(response), message.isResponse, message.rcode == 0 else { return nil }
        let records = message.answers + message.additional
        let reverse = DNSLookup.reverseName(for: ip).lowercased() + "."
        if let ptr = records.first(where: { $0.typeCode == 12 && $0.name.lowercased() == reverse }),
           let name = NamesFormat.clean(ptr.value, for: ip) {
            return name
        }
        if let a = records.first(where: { $0.typeCode == 1 && $0.value == ip.description }),
           let name = NamesFormat.clean(a.name, for: ip) {
            return name
        }
        return nil
    }
}
