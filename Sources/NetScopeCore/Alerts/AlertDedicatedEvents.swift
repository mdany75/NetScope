import Foundation

// Note 78 (0.26.0) : événements dédiés des sondes. Une licence qui expire, un firmware à mettre à
// jour, un message Syslog grave ou un WAN en panne partaient jusqu'ici comme « sonde en panne » ou
// « sonde en alerte » génériques ; ils ont maintenant leur propre type, réglable à part dans
// Réglages › Alertes (règles) et Réglages › Notifications (macOS). Rien ici n'ouvre de connexion.

extension AlertEventKind {
    /// Types apparus après la première version des règles (absents des fichiers plus anciens).
    public static let introducedLater: Set<AlertEventKind> = [.licenseExpiring, .firmwareOutdated, .syslogSevere, .wanDown]

    /// Type générique qui portait ce type avant qu'il n'existe : à la relecture d'anciennes
    /// règles, le nouveau type reprend son état (coupé si l'utilisateur avait coupé les pannes).
    public var formerGeneric: AlertEventKind? {
        switch self {
        case .wanDown: return .probeDown
        case .licenseExpiring, .firmwareOutdated, .syslogSevere: return .probeWarning
        default: return nil
        }
    }

    /// Événement qui ouvre un incident : son rétablissement partira (sonde revenue à la normale).
    public var opensIncident: Bool {
        switch self {
        case .probeDown, .probeWarning, .licenseExpiring, .firmwareOutdated, .syslogSevere, .wanDown: return true
        default: return false
        }
    }

    /// Types choisis relus d'un fichier : `known` (types connus de la version qui l'a écrit, nil
    /// avant la 0.26.0). Un type inconnu de cette version prend l'état de son ancien type générique,
    /// ou sa valeur par défaut s'il n'en a pas.
    public static func migrated(_ saved: Set<AlertEventKind>, known: Set<AlertEventKind>?) -> Set<AlertEventKind> {
        let known = known ?? Set(configurable).subtracting(introducedLater)
        var result = saved
        for kind in configurable where !known.contains(kind) {
            let enabled = kind.formerGeneric.map { saved.contains($0) } ?? AlertRules.defaultKinds.contains(kind)
            if enabled { result.insert(kind) } else { result.remove(kind) }
        }
        return result
    }

    /// Type d'une alerte de sonde, selon le type de la sonde et la gravité (nil : rien à envoyer).
    public static func forProbe(_ probe: MonProbeKind, severity: MonSeverity) -> AlertEventKind? {
        switch severity {
        case .success:
            return nil
        case .info:
            return probe == .newDevices ? .newDevice : nil
        case .critical, .warning:
            switch probe {
            case .licenseExpiring: return .licenseExpiring
            case .firmwareOutdated: return .firmwareOutdated
            case .syslogSeverity: return .syslogSevere
            // Un lien dégradé (alerte) reste une « sonde en alerte » : seule la panne est dédiée.
            case .wanLink, .vpnTunnel: return severity == .critical ? .wanDown : .probeWarning
            default: return severity == .critical ? .probeDown : .probeWarning
            }
        }
    }

    /// Titre d'une alerte de sonde (« WAN en panne · Siège / wan1 »).
    public static func probeTitle(_ kind: AlertEventKind, probeName: String, target: String) -> String {
        switch kind {
        case .probeDown: return "\(probeName) hors ligne"
        case .probeWarning: return "\(probeName) en alerte"
        case .newDevice: return "Nouvel appareil sur \(target)"
        case .licenseExpiring: return "Licence à renouveler · \(probeName)"
        case .firmwareOutdated: return "Firmware à mettre à jour · \(probeName)"
        case .syslogSevere: return "Message Syslog grave · \(probeName)"
        case .wanDown: return "WAN en panne · \(probeName)"
        default: return probeName
        }
    }
}

extension NetScopeEventKind {
    /// Type générique qui portait ce type avant la 0.26.0 (relecture des anciens réglages).
    public var formerGeneric: NetScopeEventKind? {
        switch self {
        case .wanDown: return .probeDown
        case .licenseExpiring, .firmwareOutdated, .syslogSevere: return .probeWarning
        default: return nil
        }
    }

    /// Type de la notification macOS d'une alerte de sonde (même répartition que les alertes
    /// envoyées hors du Mac) ; nil : rien à notifier.
    public static func forProbe(_ probe: MonProbeKind, severity: MonSeverity) -> NetScopeEventKind? {
        switch severity {
        case .success:
            return nil
        case .info:
            return probe == .newDevices ? .newDevice : .probeWarning
        case .critical, .warning:
            switch probe {
            case .licenseExpiring: return .licenseExpiring
            case .firmwareOutdated: return .firmwareOutdated
            case .syslogSeverity: return .syslogSevere
            case .wanLink, .vpnTunnel: return severity == .critical ? .wanDown : .probeWarning
            case .switchPort where severity == .warning: return .deviceMoved
            default: return severity == .critical ? .probeDown : .probeWarning
            }
        }
    }

    /// Titre de la notification d'une alerte de sonde (« WAN en panne : Siège / wan1 »).
    public static func probeTitle(_ kind: NetScopeEventKind, severity: MonSeverity, probeName: String) -> String {
        let critical = severity == .critical
        switch kind {
        case .probeDown: return "\(probeName) hors ligne"
        case .probeWarning, .deviceMoved: return severity == .info ? probeName : "\(probeName) en alerte"
        case .licenseExpiring: return (critical ? "Licence expirée" : "Licence à renouveler") + "\u{00A0}: \(probeName)"
        case .firmwareOutdated: return "Firmware à mettre à jour\u{00A0}: \(probeName)"
        case .syslogSevere: return (critical ? "Message Syslog critique" : "Message Syslog grave") + "\u{00A0}: \(probeName)"
        case .wanDown: return "WAN en panne\u{00A0}: \(probeName)"
        default: return probeName
        }
    }
}
