import Foundation

/// Préréglage de ports TCP (note 19) : les ports d'un profil de scan de Réglages › Profils de scan.
/// Même source que les Réglages : un profil ajouté à `ScanProfile` apparaît ici, et le profil
/// Personnalisé prend les ports saisis dans les Réglages.
public struct PortPreset: Identifiable, Hashable, Sendable {
    public var profile: ScanProfile
    public var ports: [UInt16]

    public init(profile: ScanProfile, customPorts: [UInt16] = []) {
        self.profile = profile
        self.ports = profile.ports(custom: customPorts)
    }

    public var id: String { profile.rawValue }

    /// Tous les préréglages, dans l'ordre des Réglages.
    public static func all(customPorts: [UInt16]) -> [PortPreset] {
        ScanProfile.allCases.map { PortPreset(profile: $0, customPorts: customPorts) }
    }

    /// Libellé du menu : « 22 ports essentiels », « Ports courants (31 ports) », « 1 091 ports (complet) »…
    public var label: String {
        let count = Self.count(ports.count)
        switch profile {
        case .rapide: return "\(count) essentiels"
        case .portsCourants: return "Ports courants (\(count))"
        case .complet: return "\(count) (complet)"
        case .personnalise: return "Personnalisé (\(count))"
        }
    }

    /// Libellé court du bouton de la barre d'outils, après « Ports : » (« 22 essentiels »).
    public var shortLabel: String {
        let number = Self.number(ports.count)
        switch profile {
        case .rapide: return "\(number) essentiels"
        case .portsCourants: return "\(number) courants"
        case .complet: return "\(number) (complet)"
        case .personnalise: return "personnalisé (\(number))"
        }
    }

    /// « 1 port », « 20 ports », « 1 091 ports » (espace fine insécable des milliers).
    public static func count(_ value: Int) -> String {
        "\(number(value)) port" + (value > 1 ? "s" : "")
    }

    static func number(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append("\u{202F}") }
            result.append(character)
        }
        return result
    }
}
