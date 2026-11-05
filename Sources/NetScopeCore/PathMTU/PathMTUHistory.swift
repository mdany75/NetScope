import Foundation

/// Une mesure enregistrée dans l'historique du test MTU.
public struct PathMTUMeasurement: Codable, Equatable, Identifiable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// Socket ICMP de NetScope (bit DF).
        case socket
        /// /sbin/ping -D -s (secours).
        case pingCommand

        public var label: String {
            switch self {
            case .socket: return "ICMP DF"
            case .pingCommand: return "ping -D"
            }
        }
    }

    public var id: UUID
    public var date: Date
    /// Texte saisi (nom ou adresse).
    public var target: String
    public var address: String
    /// nil : cible injoignable ou mesure interrompue.
    public var mtu: Int?
    public var maxTested: Int
    public var kind: PathMTUDiagnosis.Kind?
    public var probes: Int
    public var blackHole: Bool
    public var method: Method
    /// Message d'erreur quand il n'y a pas de MTU.
    public var note: String?

    public init(id: UUID = UUID(), date: Date = Date(), target: String, address: String, mtu: Int?, maxTested: Int,
                kind: PathMTUDiagnosis.Kind?, probes: Int, blackHole: Bool, method: Method, note: String? = nil) {
        self.id = id
        self.date = date
        self.target = target
        self.address = address
        self.mtu = mtu
        self.maxTested = maxTested
        self.kind = kind
        self.probes = probes
        self.blackHole = blackHole
        self.method = method
        self.note = note
    }

    /// Mesure tirée d'un résultat.
    public init(result: PathMTUResult, target: String, address: IPv4Address, method: Method, date: Date = Date()) {
        var note: String?
        switch result.status {
        case .found: note = nil
        case let .unreachable(message), let .interrupted(message): note = message
        }
        let found = result.status == .found
        self.init(date: date, target: target, address: address.description, mtu: found ? result.mtu : nil,
                  maxTested: result.options.maxSize, kind: found ? result.diagnosis?.kind : nil, probes: result.probesSent,
                  blackHole: result.isBlackHole, method: method, note: note)
    }

    public var diagnosis: PathMTUDiagnosis? { mtu.map { PathMTUDiagnosis(mtu: $0, maxTested: maxTested) } }

    /// « MTU du chemin = 1492 octets vers 1.1.1.1 ».
    public var sentence: String {
        guard let mtu else { return "MTU non mesuré vers \(target)" }
        let destination = target == address ? address : "\(target) (\(address))"
        return "MTU du chemin = \(mtu)\u{00A0}octets vers \(destination)"
    }
}

/// Historique borné (les plus récentes d'abord) et son export.
public enum PathMTUHistory {
    public static let capacity = 50

    public static func inserting(_ measurement: PathMTUMeasurement, into list: [PathMTUMeasurement]) -> [PathMTUMeasurement] {
        Array(([measurement] + list).prefix(capacity))
    }

    /// Dernière mesure réussie vers la même adresse avant `measurement`, pour signaler un changement.
    public static func previous(of measurement: PathMTUMeasurement, in list: [PathMTUMeasurement]) -> PathMTUMeasurement? {
        list.filter { $0.id != measurement.id && $0.address == measurement.address && $0.mtu != nil && $0.date < measurement.date }
            .max { $0.date < $1.date }
    }

    /// CSV (séparateur « ; », comme Excel en français).
    public static func csv(_ list: [PathMTUMeasurement]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines = ["date;cible;adresse;mtu;diagnostic;sondes;trou_noir;methode"]
        for item in list {
            let fields = [formatter.string(from: item.date), item.target, item.address, item.mtu.map(String.init) ?? "",
                          item.diagnosis?.title ?? (item.note ?? ""), "\(item.probes)", item.blackHole ? "oui" : "non", item.method.label]
            lines.append(fields.map { $0.replacingOccurrences(of: ";", with: ",") }.joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }
}
