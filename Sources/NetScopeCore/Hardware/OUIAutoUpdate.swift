import Foundation

// Note 81 : mise à jour automatique de la base des fabricants (registre IEEE).
//
// La décision « faut-il vérifier maintenant ? » est une fonction pure (`OUIAutoUpdatePolicy`),
// testée sans réseau : option activée, base de plus de 30 jours, dernière vérification réussie il
// y a plus de 30 jours (un jour après un échec), aucun scan en cours, connexion présente et non
// limitée (partage de connexion du téléphone : NWPath « expensive » ou « constrained »), jamais en
// démonstration ni pendant les captures. Le téléchargement lui-même est passé en paramètre à
// `OUIAutoUpdateRun.perform` : les tests lui donnent des fichiers fixes.

/// Résultat de la dernière vérification automatique.
public enum OUIAutoUpdateOutcome: Codable, Equatable, Sendable {
    /// Base remplacée : préfixes ajoutés depuis la précédente, total.
    case updated(added: Int, total: Int)
    /// Échec (téléchargement, registre incomplet, écriture) : l'ancienne base est restée.
    case failed(String)

    /// « +312 préfixes » ou « Échec : … ».
    public var label: String {
        switch self {
        case .updated(let added, _):
            return added > 0 ? "+\(OUIDatabase.formatCount(added)) préfixes" : "Aucun préfixe ajouté"
        case .failed(let message):
            return "Échec\u{00A0}: \(message)"
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Réglage et mémoire de la mise à jour automatique (rien de secret : UserDefaults).
public struct OUIAutoUpdateSettings: Codable, Equatable, Sendable {
    /// Activée par défaut (décision de Dany, note 81) ; désactivable dans Réglages.
    public var isEnabled: Bool
    /// Dernière tentative de vérification automatique (réussie ou non).
    public var lastCheck: Date?
    /// Dernière base installée par la mise à jour automatique.
    public var lastUpdate: Date?
    public var lastOutcome: OUIAutoUpdateOutcome?

    public init(isEnabled: Bool = true, lastCheck: Date? = nil, lastUpdate: Date? = nil,
                lastOutcome: OUIAutoUpdateOutcome? = nil) {
        self.isEnabled = isEnabled
        self.lastCheck = lastCheck
        self.lastUpdate = lastUpdate
        self.lastOutcome = lastOutcome
    }

    /// Lecture tolérante : un réglage illisible redevient le réglage par défaut (activé).
    public static func decode(_ data: Data?) -> OUIAutoUpdateSettings {
        guard let data, let settings = try? JSONDecoder().decode(OUIAutoUpdateSettings.self, from: data) else {
            return OUIAutoUpdateSettings()
        }
        return settings
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Ce que l'application sait au moment de décider.
public struct OUIAutoUpdateContext: Equatable, Sendable {
    public var now: Date
    /// Date de la base en place (en-tête du fichier, « 2026-11-03 ») ; nil : table intégrée seule.
    public var databaseDate: Date?
    public var isScanning: Bool
    /// État de la connexion (NWPathMonitor) ; nil : pas encore lu.
    public var path: NetworkPathStatus?
    /// Démonstration ou captures : jamais de téléchargement.
    public var isSandboxed: Bool

    public init(now: Date, databaseDate: Date?, isScanning: Bool, path: NetworkPathStatus?, isSandboxed: Bool) {
        self.now = now
        self.databaseDate = databaseDate
        self.isScanning = isScanning
        self.path = path
        self.isSandboxed = isSandboxed
    }
}

/// Raison de ne pas vérifier maintenant.
public enum OUIAutoUpdateSkip: Equatable, Sendable {
    case disabled
    case sandboxed
    /// Base de moins de 30 jours : prochaine vérification à cette date.
    case databaseRecent(until: Date)
    /// Vérifiée récemment : prochaine vérification à cette date.
    case checkedRecently(until: Date)
    case scanning
    case offline
    /// Connexion limitée : partage de connexion, données mobiles, mode données réduites.
    case limitedConnection

    /// Phrase pour Réglages (« Reportée : scan en cours. »).
    public var label: String {
        switch self {
        case .disabled: return "Mise à jour automatique désactivée."
        case .sandboxed: return "Démonstration\u{00A0}: aucun téléchargement."
        case .databaseRecent: return "Base récente\u{00A0}: rien à vérifier pour l’instant."
        case .checkedRecently: return "Vérifiée récemment."
        case .scanning: return "Reportée\u{00A0}: scan en cours."
        case .offline: return "Reportée\u{00A0}: pas de connexion."
        case .limitedConnection: return "Reportée\u{00A0}: connexion limitée (partage de connexion ou données réduites)."
        }
    }

    /// Vrai si la vérification est seulement reportée (elle sera tentée dès que possible).
    public var isPostponed: Bool {
        switch self {
        case .scanning, .offline, .limitedConnection: return true
        default: return false
        }
    }
}

public enum OUIAutoUpdateDecision: Equatable, Sendable {
    case check
    case skip(OUIAutoUpdateSkip)
}

/// Décision pure : faut-il vérifier le registre IEEE maintenant ?
public enum OUIAutoUpdatePolicy {
    /// Âge au-delà duquel la base est vérifiée.
    public static let databaseMaxAge: TimeInterval = 30 * 86_400
    /// Intervalle minimal entre deux vérifications réussies : au plus une fois par mois.
    public static let checkInterval: TimeInterval = 30 * 86_400
    /// Après un échec (réseau, serveur), nouvel essai le lendemain.
    public static let retryAfterFailure: TimeInterval = 86_400

    public static func decide(_ settings: OUIAutoUpdateSettings, context: OUIAutoUpdateContext) -> OUIAutoUpdateDecision {
        guard settings.isEnabled else { return .skip(.disabled) }
        guard !context.isSandboxed else { return .skip(.sandboxed) }
        let byDatabase = context.databaseDate.map { $0.addingTimeInterval(databaseMaxAge) }
        let byCheck = settings.lastCheck.map { nextAfterCheck($0, outcome: settings.lastOutcome) }
        if let byCheck, byCheck > context.now {
            return .skip(.checkedRecently(until: max(byCheck, byDatabase ?? byCheck)))
        }
        if let byDatabase, byDatabase > context.now { return .skip(.databaseRecent(until: byDatabase)) }
        guard !context.isScanning else { return .skip(.scanning) }
        guard let path = context.path, path.isSatisfied else { return .skip(.offline) }
        guard !path.isLimited else { return .skip(.limitedConnection) }
        return .check
    }

    /// Première date à laquelle une vérification sera permise ; nil : dès maintenant.
    public static func nextCheck(_ settings: OUIAutoUpdateSettings, databaseDate: Date?) -> Date? {
        let byDatabase = databaseDate.map { $0.addingTimeInterval(databaseMaxAge) }
        let byCheck = settings.lastCheck.map { nextAfterCheck($0, outcome: settings.lastOutcome) }
        switch (byDatabase, byCheck) {
        case let (database?, check?): return max(database, check)
        case let (database?, nil): return database
        case let (nil, check?): return check
        default: return nil
        }
    }

    static func nextAfterCheck(_ lastCheck: Date, outcome: OUIAutoUpdateOutcome?) -> Date {
        lastCheck.addingTimeInterval(outcome?.isFailure == true ? retryAfterFailure : checkInterval)
    }

    /// Date de l'en-tête de la base (« 2026-11-03 »), à midi UTC pour éviter les écarts de fuseau.
    public static func databaseDate(_ header: String?) -> Date? {
        guard let header else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: header)?.addingTimeInterval(12 * 3_600)
    }
}

/// Une vérification automatique : téléchargement (passé en paramètre), mêmes vérifications que
/// la mise à jour manuelle (`OUIUpdater.install`), écriture atomique, rechargement.
public enum OUIAutoUpdateRun {
    /// Renvoie les réglages mis à jour (date de vérification, résultat) et le résultat.
    /// En cas d'échec, rien n'est écrit : la base en place reste celle qui est chargée.
    public static func perform(settings: OUIAutoUpdateSettings, updater: OUIUpdater, database: OUIDatabase,
                               now: Date = Date(),
                               fetch: () async throws -> [String: Data]) async -> (settings: OUIAutoUpdateSettings, outcome: OUIAutoUpdateOutcome)? {
        let previous = database.count
        var updated = settings
        let outcome: OUIAutoUpdateOutcome
        do {
            let csv = try await fetch()
            try Task.checkCancellation()
            try updater.install(csv: csv, date: now)
            let source = database.reload()
            outcome = .updated(added: max(0, source.count - previous), total: source.count)
            updated.lastUpdate = now
        } catch is CancellationError {
            // Annulée (fermeture de l'app) : ni échec ni vérification, on réessaiera.
            return nil
        } catch {
            outcome = .failed("\(error)")
        }
        updated.lastCheck = now
        updated.lastOutcome = outcome
        return (updated, outcome)
    }

    /// Texte de la notification discrète (« Base des fabricants mise à jour : +312 préfixes »).
    public static func notificationText(_ outcome: OUIAutoUpdateOutcome) -> (title: String, detail: String)? {
        guard case .updated(let added, let total) = outcome else { return nil }
        let title = added > 0 ? "Base des fabricants mise à jour\u{00A0}: +\(OUIDatabase.formatCount(added)) préfixes"
                              : "Base des fabricants mise à jour"
        return (title, "Registre IEEE vérifié\u{00A0}: \(OUIDatabase.formatCount(total)) préfixes connus.")
    }
}
