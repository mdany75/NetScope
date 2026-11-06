import Foundation

/// Ordre alphabétique de NetScope (demande de Dany, 5 novembre 2026 : « en ordre alphabétique…
/// donc partout dans NetScope »). Comparaison en français du Canada, sans tenir compte des
/// majuscules ni des accents (« Étendues DHCP » avec les E), nombres comparés comme des nombres
/// (« Port 2 » avant « Port 10 »). Les éléments de tête (vue d'ensemble, défaut : « Général »,
/// « Tous », « Automatique »…) et de fin (« À propos », « Autre », « Personnalisé… ») gardent leur
/// place, dans l'ordre où on les donne.
public enum FrenchOrder {
    public static let locale = Locale(identifier: "fr_CA")
    public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .numeric]

    /// Compare deux libellés ; à égalité (« Cisco » et « cisco »), l'ordre binaire tranche pour
    /// que le tri soit stable d'une exécution à l'autre.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let result = lhs.compare(rhs, options: options, range: nil, locale: locale)
        if result != .orderedSame { return result }
        return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// Trie `items` par libellé ; `first` et `last` (libellés exacts) restent en tête et à la fin,
    /// dans l'ordre donné, s'ils sont présents.
    public static func sorted<T>(_ items: [T], by label: (T) -> String,
                                 first: [String] = [], last: [String] = []) -> [T] {
        let labelled = items.map { (item: $0, label: label($0)) }
        let pinned = Set(first).union(last)
        let head = first.flatMap { name in labelled.filter { $0.label == name }.map(\.item) }
        let tail = last.flatMap { name in labelled.filter { $0.label == name }.map(\.item) }
        let middle = labelled.filter { !pinned.contains($0.label) }
            .enumerated()
            .sorted { lhs, rhs in
                let order = compare(lhs.element.label, rhs.element.label)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }
            .map(\.element.item)
        return head + middle + tail
    }

    public static func sorted(_ labels: [String], first: [String] = [], last: [String] = []) -> [String] {
        sorted(labels, by: { $0 }, first: first, last: last)
    }
}

public extension Sequence {
    /// Éléments en ordre alphabétique français (voir `FrenchOrder`).
    func sortedFrench(by label: (Element) -> String, first: [String] = [], last: [String] = []) -> [Element] {
        FrenchOrder.sorted(Array(self), by: label, first: first, last: last)
    }
}

public extension Sequence where Element == String {
    func sortedFrench(first: [String] = [], last: [String] = []) -> [String] {
        FrenchOrder.sorted(Array(self), first: first, last: last)
    }
}
