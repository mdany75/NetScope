import Foundation

/// Préréglage de ports TCP (note 19) : les ports d'un profil de scan de Réglages › Profils de scan.
/// Même source que les Réglages : un profil ajouté à `ScanProfile` apparaît ici, et le profil
/// Personnalisé prend les ports saisis dans les Réglages.
public struct PortPreset: Identifiable, Hashable, Sendable {
    public var profile: ScanProfile
    public var ports: [UInt16]
    /// Préréglage thématique hors des profils de scan (« Accès distant ») : son nom ; nil pour un profil.
    public var name: String?

    public init(profile: ScanProfile, customPorts: [UInt16] = []) {
        self.profile = profile
        self.ports = profile.ports(custom: customPorts)
    }

    /// Préréglage thématique : `profile` reste Personnalisé (sans effet), le nom fait le libellé.
    public init(name: String, ports: [UInt16]) {
        self.profile = .personnalise
        self.ports = Array(Set(ports)).sorted()
        self.name = name
    }

    public var id: String { name.map { "nom." + $0 } ?? profile.rawValue }

    /// Ports d'accès distant : SSH, Telnet, RDP, VNC et RustDesk (21115 à 21119, note 6).
    public static let remoteAccessPorts: [UInt16] = [22, 23, 3389, 5900] + RustDeskPorts.tcpPorts

    /// « Accès distant et RustDesk (9 ports) » : menu « Scanner les ports › … » du Scanner.
    public static let remoteAccess = PortPreset(name: "Accès distant et RustDesk", ports: remoteAccessPorts)

    /// Préréglages thématiques proposés après ceux des profils.
    public static let thematic: [PortPreset] = [remoteAccess]

    /// Tous les préréglages, dans l'ordre des Réglages.
    public static func all(customPorts: [UInt16]) -> [PortPreset] {
        ScanProfile.allCases.map { PortPreset(profile: $0, customPorts: customPorts) }
    }

    /// Libellé du menu : « 22 ports essentiels », « Ports courants (31 ports) », « 1 091 ports (complet) »…
    public var label: String {
        let count = Self.count(ports.count)
        if let name { return "\(name) (\(count))" }
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
        if let name { return "\(name.lowercased()) (\(number))" }
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
