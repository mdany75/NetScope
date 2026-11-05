import Foundation

/// Erreurs de lecture d'une plage d'adresses (messages destinés à l'utilisateur).
public enum IPRangeError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case invalidAddress(String)
    case invalidPrefix(String)
    case invalidSpan(String)
    case reversedSpan(String)
    case tooLarge(count: UInt64)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Aucune plage indiquée."
        case .invalidAddress(let text):
            return "« \(text) » n’est pas une adresse IPv4 valide."
        case .invalidPrefix(let text):
            return "Le préfixe de « \(text) » doit être compris entre 0 et 32."
        case .invalidSpan(let text):
            return "La plage « \(text) » n’est pas valide (exemples : 192.168.1.1-254, 10.10.0.1-10.10.0.50)."
        case .reversedSpan(let text):
            return "Dans « \(text) », la fin précède le début."
        case .tooLarge(let count):
            return "La plage contient \(count) adresses ; la limite de sécurité est de \(IPRange.maxAddresses)."
        }
    }
}

/// Plage d'adresses à scanner : une ou plusieurs portions (CIDR, début-fin, adresse seule).
///
/// Formats acceptés, séparés par des virgules, points-virgules, espaces ou retours à la ligne :
/// « 10.182.122.0/24 », « 192.168.1.1-254 », « 10.10.0.1-10.10.0.50 », « 10.0.0.5 ».
public struct IPRange: Hashable, Sendable, CustomStringConvertible {
    /// Limite de sécurité : au-delà, la plage est refusée.
    public static let maxAddresses: UInt64 = 65_536

    public enum Segment: Hashable, Sendable, CustomStringConvertible {
        case cidr(Subnet)
        case span(IPv4Address, IPv4Address)
        case single(IPv4Address)

        /// Première et dernière adresse d'hôte de la portion (sans réseau ni broadcast pour un CIDR < /31).
        public var bounds: (first: IPv4Address, last: IPv4Address) {
            switch self {
            case .cidr(let subnet): return (subnet.firstHost, subnet.lastHost)
            case .span(let a, let b): return (a, b)
            case .single(let a): return (a, a)
            }
        }

        public var count: UInt64 {
            let b = bounds
            return UInt64(b.last.value - b.first.value) + 1
        }

        public var description: String {
            switch self {
            case .cidr(let subnet): return subnet.description
            case .span(let a, let b): return "\(a)-\(b)"
            case .single(let a): return a.description
            }
        }

        public func contains(_ address: IPv4Address) -> Bool {
            let b = bounds
            return address >= b.first && address <= b.last
        }
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// Lit une ou plusieurs plages ; lève `IPRangeError` (message en français) si une portion est invalide
    /// ou si le total dépasse `maxAddresses`.
    public init(parsing text: String) throws {
        let range = IPRange(segments: try IPRange.segments(parsing: text))
        let total = range.segmentsTotal
        guard total <= IPRange.maxAddresses else { throw IPRangeError.tooLarge(count: total) }
        self = range
    }

    /// Portions lues sans limite de taille (plages exclues de la note 82 : « 10.0.0.0/8 » est permis).
    public static func segments(parsing text: String) throws -> [Segment] {
        let separators = CharacterSet(charactersIn: ",; \t\r\n")
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw IPRangeError.empty }
        return try tokens.map(IPRange.parseSegment)
    }

    private static func parseSegment(_ token: String) throws -> Segment {
        if token.contains("/") {
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw IPRangeError.invalidAddress(token) }
            guard let address = IPv4Address(String(parts[0])) else { throw IPRangeError.invalidAddress(String(parts[0])) }
            guard let prefix = Int(parts[1]), (0...32).contains(prefix), parts[1].allSatisfy(\.isNumber) else {
                throw IPRangeError.invalidPrefix(token)
            }
            return .cidr(Subnet(address: address, prefix: prefix))
        }
        if token.contains("-") {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let start = IPv4Address(parts[0]) else { throw IPRangeError.invalidSpan(token) }
            let end: IPv4Address
            if let full = IPv4Address(parts[1]) {
                end = full
            } else if !parts[1].isEmpty, parts[1].count <= 3, parts[1].allSatisfy(\.isNumber),
                      let last = UInt32(parts[1]), last <= 255 {
                // Forme courte : seul le dernier octet est donné (192.168.1.1-254).
                end = IPv4Address(start.value & 0xFFFF_FF00 | last)
            } else {
                throw IPRangeError.invalidSpan(token)
            }
            guard end >= start else { throw IPRangeError.reversedSpan(token) }
            return start == end ? .single(start) : .span(start, end)
        }
        guard let address = IPv4Address(token) else { throw IPRangeError.invalidAddress(token) }
        return .single(address)
    }

    /// Somme des tailles des portions (les recouvrements comptent deux fois).
    private var segmentsTotal: UInt64 { segments.reduce(0) { $0 + $1.count } }

    /// Adresses d'hôte, sans doublon, dans l'ordre des portions.
    public func addresses() -> [IPv4Address] {
        var seen = Set<UInt32>()
        var result: [IPv4Address] = []
        result.reserveCapacity(Int(min(segmentsTotal, IPRange.maxAddresses)))
        for segment in segments {
            let b = segment.bounds
            var value = b.first.value
            while true {
                if seen.insert(value).inserted { result.append(IPv4Address(value)) }
                if value == b.last.value { break }
                value += 1
            }
        }
        return result
    }

    /// Nombre d'adresses distinctes.
    public var count: Int { addresses().count }

    public func contains(_ address: IPv4Address) -> Bool {
        segments.contains { $0.contains(address) }
    }

    public var description: String { segments.map(\.description).joined(separator: ", ") }
}
