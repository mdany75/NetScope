import Foundation

/// Correctif 0.27.3 : onglet « Assistance RustDesk » d'Accès distant. Règles de la page (sans
/// interface) : pastille du jour, recherche dans l'historique, présence au carnet, nom proposé
/// pour le carnet. Aucun réseau, aucun fichier.
public enum RustDeskAssistance {
    /// Nombre de lancements faits aujourd'hui (pastille de l'onglet ; 0 : pas de pastille).
    public static func todayCount(_ history: [RustDeskLaunch], now: Date = Date(), calendar: Calendar = .current) -> Int {
        history.filter { calendar.isDate($0.date, inSameDayAs: now) }.count
    }

    /// Nombre de postes différents (ID ou adresses) dans l'historique.
    public static func distinctTargets(_ history: [RustDeskLaunch]) -> Int {
        Set(history.map { $0.target.lowercased() }).count
    }

    /// Recherche dans l'historique : chaque mot doit se trouver dans le nom du poste, l'usager, le
    /// site ou la destination (casse et accents ignorés). Une recherche faite seulement de chiffres
    /// (espaces, tirets et espaces insécables permis, comme un ID dicté « 263 418 ») cherche dans
    /// l'ID sans tenir compte des groupes. Recherche vide : tout l'historique, dans le même ordre.
    public static func filter(_ history: [RustDeskLaunch], query: String) -> [RustDeskLaunch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        let separators: Set<Character> = [" ", "-", "\u{00A0}", "\u{202F}", "\t"]
        let compact = String(trimmed.filter { !separators.contains($0) })
        if !compact.isEmpty, compact.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return history.filter { launch in
                launch.target.filter { $0.isASCII && $0.isNumber }.contains(compact)
            }
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
        return history.filter { launch in
            let haystack = fold([launch.name, launch.endUser, launch.site, launch.target, launch.targetLabel].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Le poste du lancement est-il au carnet ? Par la connexion d'origine (si elle existe encore),
    /// ou par une connexion RustDesk qui a la même destination (ID ou adresse).
    public static func isInBook(_ launch: RustDeskLaunch, connectionIDs: Set<UUID>, targets: Set<String>) -> Bool {
        if let id = launch.connectionID, connectionIDs.contains(id) { return true }
        return targets.contains(launch.target.lowercased())
    }

    /// Destinations du carnet, au format de `isInBook` (connexions RustDesk seulement).
    public static func bookTargets(_ connections: [RemoteConnection]) -> Set<String> {
        Set(connections.filter { $0.proto == .rustdesk }.map { $0.host.lowercased() })
    }

    /// Nom proposé pour ajouter le poste au carnet : le nom du lancement, sauf s'il n'est que le nom
    /// automatique d'un ID collé (« Poste 123 456 789 ») ; vide alors (le carnet le recompose).
    public static func suggestedName(_ launch: RustDeskLaunch) -> String {
        let name = launch.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        if name == launch.target { return "" }
        if let id = RustDeskID.parse(launch.target) {
            let automatic = ["Poste " + RustDeskID.grouped(id), "Poste " + RustDeskID.grouped(id, separator: " "), "Poste " + id]
            if automatic.contains(name) { return "" }
        }
        return name
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_CA"))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
