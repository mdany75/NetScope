import Foundation

// Note 90 : scanner un VLAN tagué depuis le Mac. NetScope crée une interface 802.1Q temporaire
// sur l'Ethernet (networksetup -createVLAN, droits administrateur demandés par macOS), obtient
// une adresse (DHCP ou IP fixe), scanne le sous-réseau, puis retire l'interface : à la fin, après
// une erreur, une annulation, à la fermeture de l'app et, s'il en reste, au lancement suivant.
// Ce fichier est pur (commandes, validations, analyse de « networksetup -listVLANs ») : rien
// n'est lancé ici, ni dans les tests ni en démonstration.

/// Adressage de l'interface temporaire.
public enum VLANAddressing: Equatable, Sendable {
    case dhcp
    /// IP fixe : adresse, longueur du préfixe et passerelle.
    case manual(address: IPv4Address, prefix: Int, router: IPv4Address)
}

/// Erreur de saisie, expliquée en français.
public struct VLANScanInputError: Error, Equatable, Sendable {
    public var message: String

    public init(message: String) { self.message = message }
}

/// Demande validée : VLAN, Ethernet parent et adressage.
public struct VLANScanRequest: Equatable, Sendable {
    public static let validIDs = 1...4094
    public static let namePrefix = "NetScope-VLAN-"

    public var vlan: Int
    /// Interface Ethernet parente (« en0 », « en7 »).
    public var parent: String
    public var addressing: VLANAddressing

    public init(vlan: Int, parent: String, addressing: VLANAddressing) throws {
        guard Self.validIDs.contains(vlan) else {
            throw VLANScanInputError(message: "Numéro de VLAN hors limites\u{00A0}: de 1 à 4094.")
        }
        guard Self.isValidParent(parent) else {
            throw VLANScanInputError(message: "Interface Ethernet «\u{00A0}\(parent)\u{00A0}» refusée.")
        }
        if case .manual(let address, let prefix, let router) = addressing {
            guard (8...30).contains(prefix) else { throw VLANScanInputError(message: "Masque refusé\u{00A0}: de /8 à /30.") }
            let subnet = Subnet(address: address, prefix: prefix)
            guard address != subnet.network, address != subnet.broadcast, address.octets.0 != 0, address.octets.0 < 224 else {
                throw VLANScanInputError(message: "Adresse fixe \(address) inutilisable dans /\(prefix).")
            }
            guard subnet.contains(router), router != address else {
                throw VLANScanInputError(message: "La passerelle \(router) doit être dans \(subnet) et différente de l’adresse.")
            }
        }
        self.vlan = vlan
        self.parent = parent
        self.addressing = addressing
    }

    /// Numéro saisi (« 20 », « vlan 20 ») → VLAN valide.
    public static func parseID(_ text: String) -> Int? {
        let digits = text.lowercased().replacingOccurrences(of: "vlan", with: "").trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isASCII), let value = Int(digits),
              validIDs.contains(value) else { return nil }
        return value
    }

    /// « en » suivi d'un ou deux chiffres seulement (jamais une option ni un caractère du shell).
    public static func isValidParent(_ name: String) -> Bool {
        name.range(of: "^en\\d{1,2}$", options: .regularExpression) != nil
    }

    /// Nom de l'interface et du service réseau (« NetScope-VLAN-20 »).
    public var name: String { Self.namePrefix + String(vlan) }
}

/// Commandes networksetup (chemins absolus, arguments validés : aucun guillemet ni espace).
public enum VLANScanCommands {
    public static let networksetup = "/usr/sbin/networksetup"

    /// Création puis adressage (un seul script : une seule demande des droits administrateur).
    public static func createScript(_ request: VLANScanRequest) -> String {
        let create = "\(networksetup) -createVLAN \(request.name) \(request.parent) \(request.vlan)"
        switch request.addressing {
        case .dhcp:
            return create + " && \(networksetup) -setdhcp \(request.name)"
        case .manual(let address, let prefix, let router):
            let mask = Subnet(address: address, prefix: prefix).mask
            return create + " && \(networksetup) -setmanual \(request.name) \(address) \(mask) \(router)"
        }
    }

    /// Retrait d'une interface créée par NetScope (nom au préfixe « NetScope-VLAN- » seulement).
    public static func deleteScript(_ entries: [VLANEntry]) -> String? {
        let mine = entries.filter(\.isNetScope)
        guard !mine.isEmpty else { return nil }
        return mine.map { "\(networksetup) -deleteVLAN \($0.name) \($0.parent) \($0.tag)" }.joined(separator: "; ")
    }

    /// Message de la fenêtre d'autorisation de macOS.
    public static func prompt(creating request: VLANScanRequest) -> String {
        "NetScope crée une interface temporaire sur le VLAN \(request.vlan) (\(request.parent)) pour le scanner, puis la retire."
    }

    public static let removalPrompt = "NetScope retire son interface VLAN temporaire."
}

/// Interface VLAN listée par « networksetup -listVLANs ».
public struct VLANEntry: Codable, Equatable, Sendable {
    public var name: String
    public var parent: String
    /// Interface BSD (« vlan0 »), vide si inconnue.
    public var device: String
    public var tag: Int

    public init(name: String, parent: String, device: String = "", tag: Int) {
        self.name = name
        self.parent = parent
        self.device = device
        self.tag = tag
    }

    /// Créée par NetScope : nom exact « NetScope-VLAN-<n> », parent et numéro valides.
    public var isNetScope: Bool {
        name == VLANScanRequest.namePrefix + String(tag) && VLANScanRequest.validIDs.contains(tag)
            && VLANScanRequest.isValidParent(parent)
    }

    /// Analyse de « networksetup -listVLANs » (blocs « VLAN User Defined Name: … »).
    public static func parseList(_ text: String) -> [VLANEntry] {
        var result: [VLANEntry] = []
        var name: String?, parent = "", device = "", tag: Int?
        func flush() {
            if let name, let tag { result.append(VLANEntry(name: name, parent: parent, device: device, tag: tag)) }
            name = nil; parent = ""; device = ""; tag = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("vlan user defined name") { flush(); name = value }
            else if key.hasPrefix("parent device") { parent = value }
            else if key.hasPrefix("device") { device = value }
            else if key == "tag" { tag = Int(value) }
        }
        flush()
        return result
    }
}

/// Sous-réseau à scanner une fois l'adresse obtenue (limité à 1 024 adresses autour de la nôtre).
public enum VLANScanPlan {
    public static func range(address: IPv4Address, netmask: IPv4Address) -> String? {
        guard address.value != 0 else { return nil }
        let prefix = netmask.value.nonzeroBitCount
        guard (8...30).contains(prefix) else { return nil }
        return Subnet(address: address, prefix: max(prefix, 22)).description
    }

    /// Adresse d'autoconfiguration (169.254.x.x) : le DHCP n'a pas répondu.
    public static func isSelfAssigned(_ address: IPv4Address) -> Bool {
        address.octets.0 == 169 && address.octets.1 == 254
    }
}

/// VLAN proposé (vu par LLDP/CDP, sur la FortiGate ou sur les switchs).
public struct VLANProposal: Equatable, Sendable, Identifiable {
    public var vlan: Int
    public var sources: [String]
    public var id: Int { vlan }

    public init(vlan: Int, sources: [String]) {
        self.vlan = vlan
        self.sources = sources
    }

    /// Regroupe (numéro, source) : VLAN valides, sans doublon, triés par numéro.
    public static func merge(_ seen: [(vlan: Int, source: String)]) -> [VLANProposal] {
        var bySource: [Int: [String]] = [:]
        for item in seen where VLANScanRequest.validIDs.contains(item.vlan) {
            if !(bySource[item.vlan] ?? []).contains(item.source) { bySource[item.vlan, default: []].append(item.source) }
        }
        return bySource.keys.sorted().map { VLANProposal(vlan: $0, sources: bySource[$0] ?? []) }
    }
}

/// Trace des interfaces créées (Application Support/NetScope/vlan-temporaire.json) : retirées au
/// lancement suivant si l'app s'est arrêtée avant de le faire.
public enum VLANScanLedger {
    public static let fileName = "vlan-temporaire.json"

    public static func load(from url: URL) -> [VLANEntry] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([VLANEntry].self, from: data) else { return [] }
        return list.filter(\.isNetScope)
    }

    public static func save(_ entries: [VLANEntry], to url: URL) {
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
