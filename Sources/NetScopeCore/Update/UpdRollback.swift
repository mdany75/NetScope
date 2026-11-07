import Foundation

// Note 93 : revenir à une version précédente de NetScope (Réglages › Mises à jour › « Réinstaller
// cette version »). Le mécanisme est celui de la mise à jour : Release GitHub de la version
// choisie, téléchargement de NetScope.dmg, vérification de la signature Developer ID, de l'équipe
// et de la version, puis remplacement de l'application. Ce fichier ne contient que la logique pure
// (testée sans réseau) : ce qui sera fait, les avertissements, et la suspension de la mise à jour
// automatique.

/// Suspension de la mise à jour automatique après un retour arrière. Les réglages coupés sont
/// gardés pour être rétablis par « Réactiver ».
public struct UpdRollbackHold: Codable, Hashable, Sendable {
    public var version: String
    public var date: Date
    public var previousAutomaticCheck: Bool
    public var previousAutomaticInstall: Bool

    public init(version: String, date: Date, previousAutomaticCheck: Bool, previousAutomaticInstall: Bool) {
        self.version = version
        self.date = date
        self.previousAutomaticCheck = previousAutomaticCheck
        self.previousAutomaticInstall = previousAutomaticInstall
    }
}

/// Ce que fera la réinstallation d'une version, pour la confirmation.
public struct UpdRollbackPlan: Hashable, Sendable {
    public enum Direction: Hashable, Sendable { case older, same, newer }

    public var target: UpdVersion
    public var current: UpdVersion
    public var direction: Direction
    public var title: String
    public var confirmLabel: String
    /// Étapes, dans l'ordre.
    public var steps: [String]
    /// Avertissements (données plus récentes que la version visée).
    public var warnings: [String]

    /// Texte complet de la confirmation.
    public var message: String {
        var lines = steps.map { "• " + $0 }
        if !warnings.isEmpty { lines.append("") ; lines += warnings.map { "⚠︎ " + $0 } }
        return lines.joined(separator: "\n")
    }
}

public enum UpdRollback {
    /// Première version qui lit le schéma 2 de la synchronisation complète (note 86, 0.30.0).
    public static let fullSyncVersion = UpdVersion(major: 0, minor: 30, patch: 0)
    /// Première version qui sait se mettre à jour (et donc revenir) depuis les Releases GitHub.
    public static let firstUpdaterVersion = UpdVersion(major: 0, minor: 18, patch: 0)

    /// Plus ancienne version qui lit les données d'un schéma de synchronisation.
    public static func minimumVersion(forSchema schema: Int) -> UpdVersion {
        schema >= 2 ? fullSyncVersion : firstUpdaterVersion
    }

    /// Plan de la réinstallation de `target` alors que `current` tourne.
    /// `dataSchema` : schéma des données de ce Mac ; `syncEnabled` : synchronisation entre Mac active.
    public static func plan(target: UpdVersion, current: UpdVersion,
                            dataSchema: Int = ConfigSyncBundle.currentSchema, syncEnabled: Bool = false) -> UpdRollbackPlan {
        let direction: UpdRollbackPlan.Direction = target < current ? .older : (target == current ? .same : .newer)
        let title: String
        let confirm: String
        switch direction {
        case .older:
            title = "Revenir à NetScope \(target)\u{00A0}?"
            confirm = "Revenir à la \(target)"
        case .same:
            title = "Réinstaller NetScope \(target)\u{00A0}?"
            confirm = "Réinstaller la \(target)"
        case .newer:
            title = "Installer NetScope \(target)\u{00A0}?"
            confirm = "Installer la \(target)"
        }
        var steps = [
            "Télécharger l’image disque NetScope.dmg de la Release GitHub v\(target).",
            "Vérifier la signature Developer ID, l’équipe \(UpdSignature.expectedTeamID), la notarisation et la version avant toute installation\u{00A0}; rien n’est remplacé si une vérification échoue.",
            "Remplacer NetScope \(current) par la \(target), puis relancer l’application (bouton «\u{00A0}Installer et relancer\u{00A0}»).",
            "Vos données sont gardées\u{00A0}: sites, inventaire, réglages, Trousseau.",
        ]
        if direction == .older {
            steps.append("La vérification et l’installation automatiques sont suspendues jusqu’à ce que vous les réactiviez ici, pour que la \(current) ne revienne pas d’elle-même.")
        }
        var warnings: [String] = []
        let minimum = minimumVersion(forSchema: dataSchema)
        if target < minimum {
            warnings.append("La \(target) est plus ancienne que le format de vos données (synchronisation complète, format \(dataSchema), lu à partir de la \(minimum))\u{00A0}: les éléments ajoutés depuis seront ignorés par cette version, sans être effacés.")
            if syncEnabled {
                warnings.append("La synchronisation est active\u{00A0}: ce Mac sera signalé comme «\u{00A0}version plus ancienne\u{00A0}» aux autres Mac\u{00A0}; ce qu’il envoie ne retire aucun champ qu’il ne connaît pas.")
            }
        }
        if target < firstUpdaterVersion {
            warnings.append("La \(target) ne sait pas se mettre à jour elle-même\u{00A0}: pour revenir ensuite, réinstallez l’image disque depuis GitHub.")
        }
        return UpdRollbackPlan(target: target, current: current, direction: direction, title: title,
                               confirmLabel: confirm, steps: steps, warnings: warnings)
    }

    /// Préférences après le choix d'un retour à `target` : vérification et installation automatiques
    /// coupées (aussi pour la version visée, qui ne connaît pas `rollbackHold`), réglages d'avant gardés.
    public static func suspend(_ prefs: UpdPreferences, target: UpdVersion, now: Date = Date()) -> UpdPreferences {
        var next = prefs
        let hold = prefs.rollbackHold ?? UpdRollbackHold(version: target.description, date: now,
                                                         previousAutomaticCheck: prefs.automaticCheck,
                                                         previousAutomaticInstall: prefs.automaticInstall)
        next.rollbackHold = UpdRollbackHold(version: target.description, date: now,
                                            previousAutomaticCheck: hold.previousAutomaticCheck,
                                            previousAutomaticInstall: hold.previousAutomaticInstall)
        next.automaticCheck = false
        next.automaticInstall = false
        return next
    }

    /// « Réactiver » : rétablit les réglages d'avant la suspension.
    public static func resume(_ prefs: UpdPreferences) -> UpdPreferences {
        var next = prefs
        if let hold = prefs.rollbackHold {
            next.automaticCheck = hold.previousAutomaticCheck
            next.automaticInstall = hold.previousAutomaticInstall
        } else {
            next.automaticCheck = true
        }
        next.rollbackHold = nil
        return next
    }

    /// Version précédente à proposer : la plus récente des versions publiées plus anciennes que `current`.
    public static func previousVersion(published: [UpdVersion], current: UpdVersion) -> UpdVersion? {
        published.filter { $0 < current && !$0.isPrerelease }.max()
    }
}
