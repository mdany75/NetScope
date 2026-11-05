import Foundation
import NetScopeCore

/// Démonstration du journal de l'app (note 35) : entrées réalistes d'une journée de travail
/// (FortiGate 403, SNMP sans réponse, SMTP refusé…), un plantage de la veille. Rien n'est lu
/// ni écrit sur le disque, rien n'est envoyé.
///
/// Captures : NETSCOPE_PLANTAGE=1 montre la bannière « NetScope s’est fermé de façon
/// inattendue » ; NETSCOPE_JOURNAL_PASTILLE=1 la pastille d'erreurs à côté de Réglages.
enum DiagnosticDemo {
    static var showsCrashBanner: Bool { ProcessInfo.processInfo.environment["NETSCOPE_PLANTAGE"] == "1" }

    /// Captures : NETSCOPE_DIAGNOSTIC_EXPORT=1 place « Exporter un diagnostic » en tête de la section.
    static var focusOnExport: Bool {
        Launcher.isDemo && ProcessInfo.processInfo.environment["NETSCOPE_DIAGNOSTIC_EXPORT"] == "1"
    }

    /// Dernière consultation du journal : jamais dans le futur des entrées (pas de pastille),
    /// sauf sur demande.
    static var journalSeen: Date {
        ProcessInfo.processInfo.environment["NETSCOPE_JOURNAL_PASTILLE"] == "1" ? .distantPast : .distantFuture
    }

    /// Aujourd'hui à 14 h 30 : heures stables d'une capture à l'autre.
    static var anchor: Date {
        Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date()) ?? Date()
    }

    /// (minutes avant 14 h 30, niveau, module, message) ; les secrets écrits ici sont masqués
    /// par `AppLog.seed`, comme en vrai.
    private static let plan: [(Double, AppLogLevel, String, String)] = [
        (392, .info, "NetScope", "Lancement de NetScope 0.23.0 (build 230), Version 26.1 (Build 25B78)"),
        (391, .info, "Sites", "Site actif : Siège (2 plages, 1 FortiGate)"),
        (388, .info, "Scanner", "Scan de 10.182.122.0/24 terminé : 47 appareils en 38 s"),
        (371, .warning, "SNMP", "SW-ETG2 (10.182.122.4) : aucune réponse SNMP après 2 essais (délai de 2 s)"),
        (350, .info, "Mises à jour", "NetScope 0.23.0 est à jour sur le canal stable"),
        (322, .error, "FortiGate", "FGT-LAVAL (10.20.0.1) : certificat non approuvé, empreinte SHA-256 à confirmer"),
        (301, .info, "Sauvegarde", "Sauvegarde automatique créée (8 fichiers, 252 Ko, chiffrée)"),
        (266, .warning, "Synchronisation", "Synchronisé, sans les jetons : définissez le mot de passe de synchronisation."),
        (244, .error, "Alertes", "Courriel « Équipe réseau » : 535 5.7.3 Authentication unsuccessful (smtp.office365.com:587)"),
        (243, .error, "Alertes", "Webhook Teams : HTTP 401 pour https://exemple.webhook.office.com/webhookb2/a1b2?sig=Zx81kQpLm2Nw7Rt4&api-version=1"),
        (210, .info, "Scanner", "Scan de 10.182.122.0/24 terminé : 48 appareils en 36 s"),
        (184, .warning, "SNMP", "IMP-COMPTA (10.182.122.61) : communauté refusée, essai avec les autres identifiants"),
        (151, .warning, "Wi-Fi", "FAP-ETG1-NORD : lecture des clients incomplète (HTTP 424 du contrôleur)"),
        (122, .error, "SMTP", "Diagnostic SMTP de mail.exemple.ca:25 : connexion refusée (port fermé ou filtré)"),
        (96, .info, "FortiGate", "FGT-SIEGE (10.182.122.1) : lecture complète, 6 FortiSwitch et 9 FortiAP en 3,1 s"),
        (64, .error, "Inventaire", "Enregistrement impossible de inventaire-siege.json : l’espace disque est insuffisant"),
        (41, .warning, "Surveillance", "Sonde « Imprimante RH » : 3 échecs de suite, alerte envoyée"),
        (18, .error, "FortiGate", "FGT-SIEGE (10.182.122.1) : HTTP 403 sur /api/v2/monitor/switch-controller/managed-switch/port-stats, le profil du jeton n’autorise pas la lecture des switchs"),
        (9, .warning, "SNMP", "SW-ETG2 (10.182.122.4) : relevé SNMP impossible, l’appareil ne répond pas"),
        (2, .info, "Relecture", "Relecture automatique du site Siège : FortiGate et 2 switchs SNMP à jour"),
    ]

    static func entries() -> [AppLogEntry] {
        let anchor = anchor
        return plan.enumerated().map { index, item in
            let (minutes, level, module, message) = item
            // Secondes variées (heures réalistes) ; espace insécable avant « : » (typographie française).
            let seconds = Double((index * 23 + 7) % 60)
            return AppLogEntry(date: anchor.addingTimeInterval(-minutes * 60 + seconds), level: level, module: module,
                               message: message.replacingOccurrences(of: " : ", with: "\u{00A0}: "))
        }
    }

    static func seed(_ log: AppLog) {
        log.seed(entries())
    }

    /// Plantage de la veille, à 16 h 42.
    static func crashes() -> [CrashReport] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: anchor) ?? anchor
        let date = Calendar.current.date(bySettingHour: 16, minute: 42, second: 10, of: yesterday) ?? yesterday
        let url = CrashReports.standardDirectory.appendingPathComponent("NetScope-demo-164210.ips")
        return [CrashReport(url: url, date: date, appVersion: "0.22.0", osVersion: "macOS 26.1 (25B78)", exception: "EXC_BAD_ACCESS (SIGSEGV)")]
    }

    static func crashFiles() -> [DiagnosticInput.CrashFile] {
        crashes().map { report in
            let header = #"{"app_name":"NetScope","timestamp":"démonstration","app_version":"0.22.0","name":"NetScope"}"#
            let body = #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"note":"Rapport fictif du mode démonstration."}"#
            return DiagnosticInput.CrashFile(name: report.fileName, data: Data((header + "\n" + body + "\n").utf8))
        }
    }

    static let settings: [String: String] = [
        "reglages.scan.threads": "128", "reglages.scan.delaiMs": "400", "reglages.scan.profilParDefaut": "rapide",
        "sauvegarde.automatique": "1", "sauvegarde.conserver": "30", "majs.canal": "stable",
    ]
}
