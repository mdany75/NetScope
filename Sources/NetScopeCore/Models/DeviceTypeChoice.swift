import Foundation

/// Type d'un appareil tel qu'il est affiché : celui choisi à la main s'il existe, sinon celui
/// détecté par le scan. Un scan ne change que `detected` ; le choix manuel reste (note 20).
public struct DeviceTypeChoice: Equatable, Sendable {
    public var detected: DeviceType
    public var manual: DeviceType?

    public init(detected: DeviceType, manual: DeviceType? = nil) {
        self.detected = detected
        self.manual = manual
    }

    /// Type à afficher.
    public var type: DeviceType { manual ?? detected }
    public var isManual: Bool { manual != nil }

    /// État d'un menu « Changer le type » pour plusieurs appareils : le type coché quand ils ont
    /// tous le même, nil sinon.
    public static func common(_ choices: [DeviceTypeChoice]) -> DeviceType? {
        guard let first = choices.first?.type else { return nil }
        return choices.allSatisfy { $0.type == first } ? first : nil
    }
}
