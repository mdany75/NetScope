import Darwin
import Foundation

/// Service annoncé en Bonjour. `host` et `port` restent vides tant qu'il n'est pas résolu.
public struct BonjourService: Identifiable, Hashable, Sendable {
    public var type: String
    public var instance: String
    public var domain: String
    public var host: String?
    public var port: Int?
    public var ipv4: [String]
    public var ipv6: [String]
    public var txt: [String: String]

    public init(type: String, instance: String, domain: String = "local.", host: String? = nil, port: Int? = nil,
                ipv4: [String] = [], ipv6: [String] = [], txt: [String: String] = [:]) {
        self.type = BonjourCatalog.normalized(type)
        self.instance = instance
        self.domain = domain
        self.host = host
        self.port = port
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.txt = txt
    }

    public var id: String { "\(instance)|\(type)|\(domain)" }
    public var typeLabel: String { BonjourCatalog.label(for: type) }
    public var addresses: [String] { ipv4 + ipv6 }
    /// Nom d'hôte sans le point final (« imprimante.local »).
    public var hostName: String? {
        guard var text = host?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
    public var sortedTXT: [(key: String, value: String)] {
        txt.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { (key: $0.key, value: $0.value) }
    }
}

/// Enregistrement TXT : suite de chaînes préfixées par leur longueur, « clé=valeur » (RFC 6763, section 6).
public enum BonjourTXT {
    public static func decode(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var result: [String: String] = [:]
        var seen = Set<String>()
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard index + length <= bytes.count else { break }
            let item = bytes[index ..< index + length]
            index += length
            let separator = item.firstIndex(of: UInt8(ascii: "="))
            let keyBytes = item[item.startIndex ..< (separator ?? item.endIndex)]
            guard !keyBytes.isEmpty else { continue }
            let key = String(decoding: keyBytes, as: UTF8.self)
            // La RFC ignore la casse des clés et retient la première occurrence.
            guard seen.insert(key.lowercased()).inserted else { continue }
            result[key] = separator.map { text(item[($0 + 1)...]) } ?? ""
        }
        return result
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Adresses d'un service, livrées par le système sous forme de `sockaddr` brutes.
public enum BonjourAddress {
    public static func split(_ socketAddresses: [Data]) -> (ipv4: [String], ipv6: [String]) {
        var ipv4 = Set<String>()
        var ipv6 = Set<String>()
        for data in socketAddresses {
            let bytes = [UInt8](data)
            guard bytes.count >= 2 else { continue }
            if Int32(bytes[1]) == AF_INET, bytes.count >= 8 {
                ipv4.insert(bytes[4 ..< 8].map(String.init).joined(separator: "."))
            } else if Int32(bytes[1]) == AF_INET6, bytes.count >= 24, let text = ipv6Text(Array(bytes[8 ..< 24])) {
                ipv6.insert(text)
            }
        }
        return (ipv4.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, ipv6.sorted())
    }

    private static func ipv6Text(_ bytes: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, bytes, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
}

/// Codes d'erreur par lesquels macOS signale un furetage interdit.
public enum BonjourAccess {
    public static func isDenied(errorCode: Int) -> Bool {
        // Configuration manquante (NetService), NoAuth et PolicyDenied (dns_sd).
        [-72008, -65555, -65570].contains(errorCode)
    }
}

public struct BonjourGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Adresses de l'appareil, ou type brut.
    public let detail: String
    public let services: [BonjourService]

    public init(id: String, title: String, detail: String, services: [BonjourService]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.services = services
    }

    public var countText: String { "\(services.count) service\(services.count > 1 ? "s" : "")" }
    public var subtitle: String { detail.isEmpty ? countText : "\(detail) · \(countText)" }
}

public enum BonjourGrouping: String, CaseIterable, Sendable {
    case device, type

    public var label: String {
        switch self {
        case .device: return "Appareil"
        case .type: return "Type"
        }
    }

    public func groups(_ services: [BonjourService]) -> [BonjourGroup] {
        switch self {
        case .device: return Self.byDevice(services)
        case .type: return Self.byType(services)
        }
    }

    private static let unresolvedKey = "?"

    private static func hostKey(_ service: BonjourService) -> String? { service.hostName?.lowercased() }

    /// Par nom d'hôte seulement : une IP ne prouve pas à quel appareil appartient un service.
    private static func byDevice(_ services: [BonjourService]) -> [BonjourGroup] {
        let grouped = Dictionary(grouping: services) { hostKey($0) ?? unresolvedKey }
        let groups = grouped.map { key, members -> BonjourGroup in
            let hosted = members.compactMap(\.hostName).first
            let addresses = Array(Set(members.flatMap(\.ipv4))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                + Array(Set(members.flatMap(\.ipv6))).sorted()
            let title = key == unresolvedKey ? "Non résolus" : (hosted ?? key)
            return BonjourGroup(id: key, title: title, detail: addresses.prefix(2).joined(separator: ", "), services: members)
        }
        return groups.sorted { left, right in
            if (left.id == unresolvedKey) != (right.id == unresolvedKey) { return right.id == unresolvedKey }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private static func byType(_ services: [BonjourService]) -> [BonjourGroup] {
        Dictionary(grouping: services, by: \.type)
            .map { BonjourGroup(id: $0.key, title: BonjourCatalog.label(for: $0.key), detail: $0.key, services: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

public enum BonjourFilter {
    /// Tous les mots doivent se trouver dans un champ du service, TXT compris (sans casse ni accents).
    public static func apply(_ services: [BonjourService], query: String) -> [BonjourService] {
        let words = query.split(whereSeparator: \.isWhitespace).map { SearchText.fold(String($0)) }
        guard !words.isEmpty else { return services }
        return services.filter { service in
            let fields = [service.instance, service.type, service.typeLabel, service.host ?? "", service.port.map(String.init) ?? ""]
                + service.addresses + service.txt.flatMap { [$0.key, $0.value] }
            let text = SearchText.fold(fields.joined(separator: "\n"))
            return words.allSatisfy(text.contains)
        }
    }
}

public enum BonjourFormat {
    public static func report(_ groups: [BonjourGroup]) -> String {
        groups.map { group in
            let lines = group.services.map { service -> String in
                let endpoint = [service.hostName, service.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
                let txt = service.sortedTXT.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                return ["  \(service.typeLabel) (\(service.type))", service.instance, endpoint, service.addresses.joined(separator: ", "), txt]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return (["\(group.title) · \(group.subtitle)"] + lines).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
