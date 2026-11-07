import Darwin
import Foundation

// Note 96 : serveur DHCP pirate (inspiré de dhcp_probe). Un DHCPDISCOVER sur clic (Test DHCP) ou
// par la sonde de Surveillance « Serveur DHCP pirate » ; toutes les offres reçues sont listées
// (serveur, MAC, passerelle, DNS, plage) et jugées contre les serveurs attendus du site : ceux qui
// sont déclarés et la FortiGate (reconnue par son adresse ou, quand elle se donne elle-même pour
// passerelle, par le fabricant de sa MAC). Jamais d'envoi pendant les tests ni en démonstration.

/// Verdict sur un serveur qui a répondu.
public enum RogueDHCPVerdict: String, Codable, Sendable {
    /// Serveur déclaré pour le site.
    case attendu
    /// FortiGate du site (adresse connue, ou passerelle d'elle-même avec une MAC Fortinet).
    case fortiGate
    /// Ni déclaré ni FortiGate : serveur pirate.
    case pirate
    /// Rien n'est attendu pour le site : impossible de juger.
    case nonVerifie

    public var label: String {
        switch self {
        case .attendu: return "Attendu"
        case .fortiGate: return "FortiGate du site"
        case .pirate: return "Pirate"
        case .nonVerifie: return "Non vérifié"
        }
    }

    public var isRogue: Bool { self == .pirate }
}

/// Serveurs attendus d'un site : déclarés et FortiGate.
public struct RogueDHCPPolicy: Equatable, Sendable {
    /// Serveurs déclarés (Test DHCP, « Serveurs autorisés »).
    public var declared: [IPv4Address]
    /// Adresses des FortiGate du site (hôte de l'API, interfaces connues).
    public var fortiGates: [IPv4Address]

    public init(declared: [IPv4Address] = [], fortiGates: [IPv4Address] = []) {
        self.declared = declared
        self.fortiGates = fortiGates
    }

    /// Liste saisie (virgules, points-virgules, espaces) et adresses des FortiGate.
    public init(text: String, fortiGates: [IPv4Address] = []) {
        self.init(declared: DHCPServerPolicy(text: text).allowed, fortiGates: fortiGates)
    }

    /// Vrai si l'utilisateur a déclaré quelque chose ou si une FortiGate est connue.
    public var isConfigured: Bool { !declared.isEmpty || !fortiGates.isEmpty }

    /// `isFortinet` : fabricant de la MAC (OUI) ; la FortiGate est passerelle et serveur à la fois.
    public func verdict(of offer: DHCPOffer, isFortinet: (MACAddress) -> Bool = { _ in false }) -> RogueDHCPVerdict {
        let candidates = [offer.serverIdentifier, offer.sourceAddress].compactMap { $0 }
        if candidates.contains(where: declared.contains) { return .attendu }
        if candidates.contains(where: fortiGates.contains) { return .fortiGate }
        // FortiGate sans adresse déclarée : elle se donne pour passerelle et sa MAC est Fortinet.
        if let mac = offer.sourceMAC, isFortinet(mac), let server = offer.server, offer.routers.contains(server) {
            return .fortiGate
        }
        return isConfigured ? .pirate : .nonVerifie
    }
}

/// Offre reçue, jugée et prête à afficher (une par serveur).
public struct RogueDHCPFinding: Identifiable, Hashable, Sendable {
    public var id: String { server?.description ?? offered.description }
    public var server: IPv4Address?
    public var mac: MACAddress?
    public var vendor: String?
    public var offered: IPv4Address
    public var subnet: String?
    public var gateway: IPv4Address?
    public var dns: [IPv4Address]
    public var lease: String
    public var verdict: RogueDHCPVerdict
    /// Explication courte (« routeur domestique probable », « se donne pour passerelle »).
    public var reason: String

    /// « Plage » distribuée : réseau de l'offre, sinon l'adresse offerte.
    public var pool: String { subnet ?? offered.description }
}

public enum RogueDHCPAnalyzer {
    /// Fabricants grand public : un serveur pirate de ces marques est presque toujours un routeur
    /// domestique branché à l'envers.
    public static let homeBrands = ["asus", "belkin", "d-link", "huawei", "linksys", "netgear", "tenda", "tp-link", "xiaomi", "zyxel"]

    /// Une ligne par serveur (première offre reçue), pirates d'abord puis par adresse.
    public static func findings(_ offers: [DHCPOffer], policy: RogueDHCPPolicy,
                                vendor: (MACAddress) -> String? = { _ in nil }) -> [RogueDHCPFinding] {
        var seen = Set<UInt32>()
        var result: [RogueDHCPFinding] = []
        for offer in offers where offer.messageType == .offer || offer.messageType == .ack || offer.messageType == nil {
            let key = offer.server?.value ?? 0
            guard seen.insert(key).inserted else { continue }
            let brand = offer.sourceMAC.flatMap(vendor)
            let isFortinet: (MACAddress) -> Bool = { mac in (vendor(mac) ?? "").lowercased().contains("fortinet") }
            let verdict = policy.verdict(of: offer, isFortinet: isFortinet)
            result.append(RogueDHCPFinding(server: offer.server, mac: offer.sourceMAC, vendor: brand, offered: offer.offeredAddress,
                                           subnet: offer.subnet?.description, gateway: offer.routers.first, dns: offer.dnsServers,
                                           lease: DHCPOffer.leaseText(offer.leaseTime), verdict: verdict,
                                           reason: reason(offer, verdict: verdict, vendor: brand)))
        }
        return result.sorted { lhs, rhs in
            if lhs.verdict.isRogue != rhs.verdict.isRogue { return lhs.verdict.isRogue }
            return (lhs.server?.value ?? 0) < (rhs.server?.value ?? 0)
        }
    }

    static func reason(_ offer: DHCPOffer, verdict: RogueDHCPVerdict, vendor: String?) -> String {
        switch verdict {
        case .attendu: return "Serveur déclaré pour le site"
        case .fortiGate: return "FortiGate du site"
        case .nonVerifie: return "Aucun serveur attendu déclaré pour le site"
        case .pirate:
            let brand = (vendor ?? "").lowercased()
            let text = offer.offeredAddress.description
            if homeBrands.contains(where: brand.contains) || text.hasPrefix("192.168.0.") || text.hasPrefix("192.168.1.") {
                return "Routeur domestique probable (branché à l’envers)"
            }
            if let server = offer.server, offer.routers.contains(server) { return "Se donne pour passerelle du réseau" }
            return "Serveur ni déclaré ni FortiGate"
        }
    }

    /// Résultat de la sonde « Serveur DHCP pirate » : panne si un pirate répond, alerte si aucun
    /// serveur ne répond ou si rien n'est attendu pour juger.
    public static func monitorResult(_ findings: [RogueDHCPFinding], policyConfigured: Bool, now: Date) -> MonResult {
        let rogues = findings.filter(\.verdict.isRogue)
        if !rogues.isEmpty {
            let names = rogues.prefix(3).map { finding -> String in
                var text = finding.server?.description ?? finding.offered.description
                if let mac = finding.mac { text += " (" + mac.formatted(.upperColon) + ")" }
                return text
            }.joined(separator: ", ")
            return MonResult(date: now, reachable: false,
                             value: "\(rogues.count) pirate\(rogues.count > 1 ? "s" : "") sur \(findings.count)",
                             error: "Serveur DHCP pirate\u{00A0}: \(names)")
        }
        guard !findings.isEmpty else {
            return MonResult(date: now, reachable: true, value: "Aucune offre", problem: "Aucun serveur DHCP n’a répondu")
        }
        let list = findings.compactMap { $0.server?.description }.joined(separator: ", ")
        guard policyConfigured else {
            return MonResult(date: now, reachable: true, value: list,
                             problem: "Aucun serveur attendu déclaré (Test DHCP › Serveurs autorisés) ni FortiGate connue")
        }
        return MonResult(date: now, reachable: true, value: "\(findings.count) attendu\(findings.count > 1 ? "s" : "") · \(list)")
    }
}

/// DHCPDISCOVER sans droits particuliers (port 68 partagé, sinon port libre) pour la sonde :
/// aucun bail n'est pris (jamais de DHCPREQUEST). L'application ne l'appelle jamais en démonstration.
public enum RogueDHCPDiscover {
    public static func run(interface: String, mac: MACAddress, seconds: TimeInterval = 4) async -> Result<[DHCPOffer], RogueDHCPError> {
        await Task.detached { () -> Result<[DHCPOffer], RogueDHCPError> in
            let xid = DHCPDiscover.randomXID()
            let packet = DHCPDiscover.build(xid: xid, mac: mac)
            do {
                guard let fd = try DHCPProbe.openSocket(interface: interface, port: DHCPProbe.clientPort)
                        ?? DHCPProbe.openSocket(interface: interface, port: 0) else {
                    return .failure(RogueDHCPError(message: "Port DHCP indisponible sur \(interface)"))
                }
                defer { close(fd) }
                let sent = Date()
                try DHCPProbe.send(packet, fd: fd)
                let offers = DHCPProbe.receive(fd: fd, xid: xid, until: sent.addingTimeInterval(seconds), sentAt: sent)
                return .success(DHCPServerPolicy.uniqueServers(offers, xid: xid))
            } catch {
                return .failure(RogueDHCPError(message: error.localizedDescription))
            }
        }.value
    }
}

public struct RogueDHCPError: Error, Sendable, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}
