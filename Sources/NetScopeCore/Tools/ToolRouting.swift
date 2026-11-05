import Foundation

// Note 79 : allègements de la Boîte à outils. Les sept outils de courriel deviennent les onglets
// d'un seul outil « Courriel » (une seule entrée dans la liste) ; les anciens identifiants restent
// valables (liens « Ouvrir dans › », historique, NETSCOPE_OUTIL_DEMO) et mènent au bon onglet.
// Règles pures, sans interface : l'application (`ToolKind`) s'y réfère pour sa liste et ses liens.

/// Onglets de l'outil « Courriel », dans l'ordre affiché. Les valeurs sont les identifiants
/// historiques des anciens outils (`ToolKind.rawValue`), gardés tels quels.
public enum MailToolTab: String, CaseIterable, Sendable {
    case superTool = "mailSuper"
    case smtp
    case headers = "entetes"
    case health = "mailHealth"
    case records = "mailRecords"
    case mx
    case blacklist

    /// Libellé court de l'onglet.
    public var tabLabel: String {
        switch self {
        case .superTool: return "Super outil"
        case .smtp: return "SMTP"
        case .headers: return "En-têtes"
        case .health: return "Santé"
        case .records: return "SPF/DKIM"
        case .mx: return "MX"
        case .blacklist: return "Listes noires"
        }
    }

    /// Ancien nom de l'outil, gardé pour la recherche (« Analyse d’en-têtes », « Recherche MX »).
    public var formerName: String {
        switch self {
        case .superTool: return "Super outil courriel"
        case .smtp: return "Diagnostic SMTP"
        case .headers: return "Analyse d’en-têtes"
        case .health: return "Santé courriel"
        case .records: return "SPF, DKIM, DMARC…"
        case .mx: return "Recherche MX"
        case .blacklist: return "Listes noires"
        }
    }
}

public enum ToolRouting {
    /// Identifiant de l'entrée unique « Courriel » dans la liste des outils (et alias accepté).
    public static let mailEntryID = "courriel"
    /// Onglet ouvert par l'entrée « Courriel » quand aucun n'a encore été choisi.
    public static let defaultMailTab: MailToolTab = .superTool

    /// Autres noms acceptés pour un outil (liens anciens, variables de capture, saisie libre).
    /// Tout identifiant inconnu de cette table est rendu tel quel.
    public static let aliases: [String: String] = [
        "courriel": MailToolTab.superTool.rawValue,
        "mail": MailToolTab.superTool.rawValue,
        "email": MailToolTab.superTool.rawValue,
        "supercourriel": MailToolTab.superTool.rawValue,
        "headers": MailToolTab.headers.rawValue,
        "en-tetes": MailToolTab.headers.rawValue,
        "sante": MailToolTab.health.rawValue,
        "spf": MailToolTab.records.rawValue,
        "dkim": MailToolTab.records.rawValue,
        "dmarc": MailToolTab.records.rawValue,
        "rbl": MailToolTab.blacklist.rawValue,
        "dnsbl": MailToolTab.blacklist.rawValue,
        // TFTP (note 51) : un seul outil, serveur et client ensemble.
        "tftpd": "tftp",
        "tftp-serveur": "tftp",
        "tftp-client": "tftp",
    ]

    /// Identifiant actuel d'un outil : l'alias résolu, sinon l'identifiant tel quel (minuscules
    /// pour les alias seulement : « mailSuper » garde sa casse).
    public static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if MailToolTab(rawValue: trimmed) != nil { return trimmed }
        return aliases[trimmed.lowercased()] ?? trimmed
    }

    /// Onglet de courriel d'un identifiant (alias compris) ; nil si ce n'est pas un outil de courriel.
    public static func mailTab(for raw: String) -> MailToolTab? {
        MailToolTab(rawValue: canonical(raw))
    }

    /// Entrée de la liste qui porte cet outil : « courriel » pour un onglet de courriel, sinon lui-même.
    public static func listEntry(for raw: String) -> String {
        mailTab(for: raw) != nil ? mailEntryID : canonical(raw)
    }

    /// Entrées de la liste à partir des identifiants des outils, dans leur ordre : les onglets de
    /// courriel se fondent en une seule entrée (à la place du premier), et aucun outil n'apparaît
    /// deux fois (TFTP compris).
    public static func listedEntries(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids {
            let entry = listEntry(for: id)
            if seen.insert(entry).inserted { result.append(entry) }
        }
        return result
    }
}
