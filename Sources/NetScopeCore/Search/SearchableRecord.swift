import Foundation

/// Élément qu'une recherche multiple peut filtrer : chaque module déclare ses champs (avec leurs
/// préfixes français et anglais) et les valeurs d'un élément pour chacun.
public protocol SearchableRecord {
    /// Champs du module, dans l'ordre du menu des préfixes.
    static var searchSchema: SearchSchema { get }
    /// Valeurs de l'élément pour un champ (vide : le champ ne s'applique pas à lui).
    func searchValues(for field: SearchAttribute) -> [String]
    /// Textes lus par un mot sans préfixe ; par défaut, toutes les valeurs des champs. Un module
    /// qui avait déjà une recherche garde ici exactement ses anciennes colonnes, pour qu'une
    /// recherche d'un mot donne le même résultat qu'avant.
    var searchFreeText: [String] { get }
}

public extension SearchableRecord {
    var searchFreeText: [String] {
        Self.searchSchema.fields.flatMap { searchValues(for: $0) }
    }

    /// Recherche multiple avec les champs du module (une requête vide trouve tout).
    func matchesSearch(_ text: String) -> Bool {
        SearchQuery(text, schema: Self.searchSchema).matches(self)
    }
}

/// Élément de recherche fait à la volée (ligne d'un tableau de l'app) : valeurs par clé de champ.
public struct SearchDocument: SearchableRecord {
    public static let searchSchema = SearchSchema.textOnly

    public var values: [String: [String]]
    public var freeText: [String]

    /// `freeText` nil : toutes les valeurs des champs.
    public init(_ values: [String: [String]], freeText: [String]? = nil) {
        self.values = values
        self.freeText = freeText ?? values.keys.sorted().flatMap { values[$0] ?? [] }
    }

    public func searchValues(for field: SearchAttribute) -> [String] { values[field.key] ?? [] }
    public var searchFreeText: [String] { freeText }
}

public extension Sequence where Element: SearchableRecord {
    /// Éléments qui correspondent à la requête (analysée avec les champs du type).
    func filtered(by text: String) -> [Element] {
        SearchQuery(text, schema: Element.searchSchema).filter(self)
    }
}
