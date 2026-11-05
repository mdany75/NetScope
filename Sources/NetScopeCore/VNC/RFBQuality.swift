import Foundation

/// Qualité de l'image d'une session VNC (croquis : « Adaptative » ou « Haute »).
public enum RFBQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 32 bits sur un lien rapide, 16 bits (deux fois moins de données) quand le débit mesuré baisse.
    case adaptive = "adaptative"
    /// Toujours 32 bits, sans perte.
    case high = "haute"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .adaptive: return "Adaptative"
        case .high: return "Haute"
        }
    }
}

/// Décide du format des pixels en qualité adaptative, d'après le débit mesuré sur les grosses mises
/// à jour : passage en 16 bits sous `lowThreshold`, retour en 32 bits au-dessus de
/// `highThreshold`, jamais plus d'un changement par `minimumDwell` secondes (hystérésis).
public struct RFBQualityGovernor: Sendable {
    public var quality: RFBQuality
    public private(set) var format: RFBPixelFormat = .rgb888
    /// Octets par seconde (moyenne glissante exponentielle).
    public private(set) var throughput: Double?

    public var lowThreshold: Double = 3_000_000
    public var highThreshold: Double = 8_000_000
    public var minimumDwell: TimeInterval = 5
    /// Mises à jour trop petites pour mesurer le débit (latence dominante).
    public var minimumSample = 64 * 1024

    private var lastChange: Date?

    public init(quality: RFBQuality) {
        self.quality = quality
    }

    /// Change la qualité ; renvoie le nouveau format s'il change.
    public mutating func setQuality(_ quality: RFBQuality, now: Date = Date()) -> RFBPixelFormat? {
        self.quality = quality
        if quality == .high, format != .rgb888 {
            format = .rgb888
            lastChange = now
            return format
        }
        return nil
    }

    /// Enregistre une mise à jour ; renvoie le format à demander s'il change.
    public mutating func record(bytes: Int, duration: TimeInterval, now: Date = Date()) -> RFBPixelFormat? {
        guard bytes >= minimumSample, duration > 0 else { return nil }
        let sample = Double(bytes) / duration
        throughput = throughput.map { $0 * 0.6 + sample * 0.4 } ?? sample
        guard quality == .adaptive, let throughput else { return nil }
        if let lastChange, now.timeIntervalSince(lastChange) < minimumDwell { return nil }
        if format == .rgb888, throughput < lowThreshold {
            format = .rgb565
            lastChange = now
            return format
        }
        if format == .rgb565, throughput > highThreshold {
            format = .rgb888
            lastChange = now
            return format
        }
        return nil
    }
}
