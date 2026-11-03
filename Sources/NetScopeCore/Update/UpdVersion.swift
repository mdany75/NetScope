import Foundation

/// Version sémantique (« 1.2.3 », « v0.9.2-beta.2 »). Le « v » initial est facultatif, une
/// composante absente vaut 0 (« 1.0 » = « 1.0.0 ») et les métadonnées de build (« +abc ») sont
/// ignorées. Ordre : 0.1.0 < 0.1.1 < 1.0.0-beta.1 < 1.0.0-beta.2 < 1.0.0-rc.1 < 1.0.0.
public struct UpdVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Identifiants de préversion (« beta », « 2 ») ; vide pour une version finale.
    public let prerelease: [String]

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var core = rest
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            core = rest[..<dash]
            let tail = rest[rest.index(after: dash)...]
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: UpdVersion, rhs: UpdVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Une version finale passe après toutes ses préversions.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a.lowercased() != b.lowercased() {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true      // numérique avant alphanumérique
            case (nil, .some): return false
            case (nil, nil): return a.lowercased() < b.lowercased()
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: UpdVersion, rhs: UpdVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease.map { $0.lowercased() })
    }
}

/// Canal de mise à jour.
public enum UpdChannel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Versions finales seulement.
    case stable
    /// Inclut les préversions (« Pre-release » sur GitHub).
    case beta

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Bêta"
        }
    }
}

/// Fréquence de la vérification automatique.
public enum UpdFrequency: String, Codable, CaseIterable, Sendable, Identifiable {
    case auDemarrage, quotidienne, hebdomadaire

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auDemarrage: return "Au démarrage"
        case .quotidienne: return "Chaque jour"
        case .hebdomadaire: return "Chaque semaine"
        }
    }

    /// Délai minimal entre deux vérifications (0 : à chaque démarrage).
    public var interval: TimeInterval {
        switch self {
        case .auDemarrage: return 0
        case .quotidienne: return 24 * 3600
        case .hebdomadaire: return 7 * 24 * 3600
        }
    }

    /// Vrai si une vérification est due. `atLaunch` : appel au démarrage de l'application.
    public func isDue(lastCheck: Date?, now: Date = Date(), atLaunch: Bool) -> Bool {
        guard let lastCheck else { return true }
        if self == .auDemarrage { return atLaunch }
        // Une date dans le futur (horloge modifiée) ne doit pas bloquer les vérifications.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
