import Foundation

// Choix d'un, de plusieurs ou de tous les sites affichés par l'Analyse, l'Inventaire, la Carte et
// les Rapports (demande de Dany, 0.12.0), sans changer le site actif du Scanner.
//
// Règle : les lignes de deux sites ne fusionnent JAMAIS. La même IP ou la même MAC sur deux sites
// donne deux lignes distinctes, d'identifiant composé « site|fiche ». Les inventaires des autres
// sites sont lus depuis leur fichier (sites/<id>/inventory.json) ; seul l'inventaire du site
// concerné est écrit.

/// Sites affichés par un écran.
public enum SiteSelection: Hashable, Sendable {
    /// Le site actif du Scanner (par défaut) : suit le changement de site.
    case active
    /// Des sites choisis (clés `SiteFiles.key`), dans l'ordre du choix.
    case sites([String])
    /// Tous les sites.
    case all

    /// Clés des sites affichés : le site actif d'abord, puis les autres dans l'ordre de `available`.
    /// Un site supprimé disparaît du choix ; un choix vide redevient le site actif.
    public func resolve(activeKey: String, available: [String]) -> [String] {
        switch self {
        case .active:
            return [activeKey]
        case .all:
            return [activeKey] + available.filter { $0 != activeKey }
        case .sites(let keys):
            let wanted = Set(keys)
            var result = ([activeKey] + available).filter { wanted.contains($0) }
            var seen: Set<String> = []
            result = result.filter { seen.insert($0).inserted }
            return result.isEmpty ? [activeKey] : result
        }
    }

    /// Choix équivalent pour l'enregistrement : « actif », « tous » ou « clé1,clé2 ».
    public var stored: String {
        switch self {
        case .active: return "actif"
        case .all: return "tous"
        case .sites(let keys): return keys.joined(separator: ",")
        }
    }

    public init(stored: String) {
        switch stored {
        case "", "actif": self = .active
        case "tous": self = .all
        default: self = .sites(stored.split(separator: ",").map(String.init))
        }
    }

    /// Choix écrit à la main (captures : NETSCOPE_SITES_VUE="siege,laval" ou « tous ») : « tous »,
    /// « actif », sinon des parties de noms de sites séparées par des virgules (sans tenir compte
    /// des accents ni des majuscules). Nil si aucun site ne correspond.
    public static func parse(_ text: String, sites: [(key: String, name: String)]) -> SiteSelection? {
        func fold(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CA"))
                .trimmingCharacters(in: .whitespaces)
        }
        let cleaned = fold(text)
        if ["tous", "all", "tous les sites"].contains(cleaned) { return .all }
        if ["actif", "active", ""].contains(cleaned) { return .active }
        var keys: [String] = []
        for part in cleaned.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let match = sites.first { fold($0.name) == part } ?? sites.first { fold($0.name).contains(part) }
            if let match, !keys.contains(match.key) { keys.append(match.key) }
        }
        return keys.isEmpty ? nil : .sites(keys)
    }

    /// Bascule un site dans le choix (case du menu « Site ») : le dernier site retiré laisse le site actif.
    public func toggling(_ key: String, activeKey: String, available: [String]) -> SiteSelection {
        var keys = resolve(activeKey: activeKey, available: available)
        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
        } else {
            keys.append(key)
        }
        if keys.isEmpty || keys == [activeKey] { return .active }
        let others = available.filter { $0 != activeKey }
        if keys.count == others.count + 1, Set(keys) == Set([activeKey] + others) { return .all }
        return .sites(keys)
    }
}

/// Inventaire d'un site, lu pour l'affichage.
public struct SiteInventory: Sendable {
    public var key: String
    public var name: String
    public var store: InventoryStore

    public init(key: String, name: String, store: InventoryStore) {
        self.key = key
        self.name = name
        self.store = store
    }
}

/// Fiche d'inventaire avec son site : une ligne des tableaux à plusieurs sites.
public struct SiteScopedRecord: Identifiable, Hashable, Sendable {
    public var siteKey: String
    public var siteName: String
    public var record: InvRecord

    public init(siteKey: String, siteName: String, record: InvRecord) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.record = record
    }

    /// « site|fiche » : jamais deux lignes au même identifiant, même à IP ou MAC égale.
    public var id: String { SiteScope.id(site: siteKey, key: record.key) }
}

/// Événement d'inventaire avec son site (alertes de l'Analyse).
public struct SiteScopedEvent: Identifiable, Hashable, Sendable {
    public var siteKey: String
    public var siteName: String
    public var event: InvEvent
    /// Fiche de l'appareil dans ce site (nil : fiche supprimée).
    public var record: InvRecord?

    public init(siteKey: String, siteName: String, event: InvEvent, record: InvRecord? = nil) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.event = event
        self.record = record
    }

    public var id: String { siteKey + "|" + event.id.uuidString }
}

public enum SiteScope {
    public static let separator: Character = "|"

    public static func id(site: String, key: String) -> String { site + String(separator) + key }

    /// Site et fiche d'un identifiant composé.
    public static func split(_ id: String) -> (site: String, key: String)? {
        guard let index = id.firstIndex(of: separator) else { return nil }
        return (String(id[..<index]), String(id[id.index(after: index)...]))
    }

    /// Fiches de plusieurs sites, une ligne par site et par fiche (aucune fusion), dans l'ordre des
    /// sites puis par IP.
    public static func records(_ inventories: [SiteInventory]) -> [SiteScopedRecord] {
        inventories.flatMap { inventory in
            inventory.store.sortedRecords.map { SiteScopedRecord(siteKey: inventory.key, siteName: inventory.name, record: $0) }
        }
    }

    /// Alertes (hors référence) de plusieurs sites depuis `since`, regroupées par site (ordre des
    /// sites), de la plus récente à la plus ancienne dans chaque site.
    public static func alerts(_ inventories: [SiteInventory], since: Date) -> [SiteScopedEvent] {
        inventories.flatMap { inventory in
            inventory.store.events.filter { $0.isAlert && $0.date >= since }.sorted { $0.date > $1.date }.map {
                SiteScopedEvent(siteKey: inventory.key, siteName: inventory.name, event: $0, record: inventory.store.record($0.key))
            }
        }
    }

    /// Identifiants composés regroupés par site, dans l'ordre d'apparition des sites.
    public static func grouped(_ ids: [String]) -> [(site: String, keys: [String])] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for id in ids {
            guard let parts = split(id) else { continue }
            if groups[parts.site] == nil { order.append(parts.site) }
            if groups[parts.site]?.contains(parts.key) != true { groups[parts.site, default: []].append(parts.key) }
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

// MARK: - Recherche

extension SiteScopedRecord: SearchableRecord {
    public static var searchSchema: SearchSchema { .inventaire }

    public func searchValues(for field: SearchAttribute) -> [String] {
        field.key == SearchAttribute.site.key ? [siteName] : record.searchValues(for: field)
    }

    /// Mêmes colonnes que l'Inventaire d'un seul site : un mot seul donne le même résultat.
    public var searchFreeText: [String] { record.searchFreeText }
}
