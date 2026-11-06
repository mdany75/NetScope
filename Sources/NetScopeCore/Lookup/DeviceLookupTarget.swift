import Foundation

// Boîte à outils › « Ressources d'un poste » : ce que la touche Entrée ouvre pour la saisie du
// champ (IP, nom ou MAC), sans choix aux flèches. Lecture locale seulement : un nom d'hôte inconnu
// n'est résolu que si l'utilisateur le demande.

/// Poste désigné par la saisie.
public enum DeviceLookupTarget: Equatable, Sendable {
    case empty
    /// Appareil connu désigné exactement (même IP, même MAC ou même nom), avec une adresse.
    case known(DeviceLookupCandidate)
    /// Adresse IP qu'aucun appareil connu ne porte : interrogée telle quelle.
    case address(IPv4Address)
    /// Nom d'hôte inconnu : à résoudre (sur demande) avant d'interroger.
    case hostname(String)
    /// Adresse MAC sans appareil connu (ou sans adresse IP connue) : rien à interroger.
    case unknownMAC(MACAddress)
    /// Saisie illisible (raison en français).
    case invalid(String)

    /// Adresse à interroger, si la saisie en donne une sans autre étape.
    public var address: IPv4Address? {
        switch self {
        case .known(let candidate): return candidate.ip
        case .address(let ip): return ip
        default: return nil
        }
    }
}

extension DeviceLookup {
    /// Poste désigné par la saisie : l'appareil connu identique s'il a une adresse, sinon ce que
    /// la saisie est (adresse, nom à résoudre, MAC sans adresse, erreur).
    public static func target(for text: String, in candidates: [DeviceLookupCandidate]) -> DeviceLookupTarget {
        let entry = DeviceEntry.parse(text)
        if case .empty = entry { return .empty }
        if let match = exactMatch(for: text, in: candidates), match.candidate.ip != nil {
            return .known(match.candidate)
        }
        switch entry {
        case .empty: return .empty
        case .ip(let ip): return .address(ip)
        case .hostname(let name): return .hostname(name)
        // Douze lettres hexadécimales sans appareil connu de ce nom : lues comme une MAC.
        case .mac(let mac), .ambiguous(let mac, _): return .unknownMAC(mac)
        case .invalid(let reason): return .invalid(reason)
        }
    }
}
