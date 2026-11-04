import Foundation

// Note 36 : mémoire des calculs d'un inventaire. Les écrans (Inventaire, Analyse, Carte) relisent
// l'inventaire à chaque rendu SwiftUI : tri des fiches, événements d'une fiche, doublons probables,
// lignes à plusieurs sites et texte de recherche. Ces calculs sont faits une fois, puis relus tant
// que les fiches et les événements de CETTE copie de l'inventaire ne changent pas.
//
// `InventoryStore` est une valeur : chaque modification de `records` ou `events` lui donne une
// mémoire neuve (didSet), les autres copies gardent la leur, toujours exacte pour elles.

final class InvMemo: @unchecked Sendable {
    private let lock = NSLock()

    var sorted: [InvRecord]?
    var byIP: [IPv4Address: InvRecord]?
    var eventsByKey: [String: [InvEvent]]?
    var conflictIPs: Set<IPv4Address>?
    var duplicates: [InvDuplicate]?
    /// Lignes à plusieurs sites, par « site|nom du site ».
    var scoped: [String: [SiteScopedRecord]] = [:]
    /// Texte de recherche plié de chaque fiche, calculé à la première recherche d'un mot.
    private var folded: [String: String] = [:]

    func foldedText(for record: InvRecord) -> String {
        lock.lock()
        if let known = folded[record.key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let made = SearchText.foldedJoined(record.searchFreeText)
        lock.lock()
        folded[record.key] = made
        lock.unlock()
        return made
    }

    /// Valeur gardée, sinon calculée puis gardée. Le calcul se fait hors du verrou (il peut être
    /// long) : deux lectures simultanées calculent au pire deux fois la même chose.
    func value<T>(_ path: ReferenceWritableKeyPath<InvMemo, T?>, _ make: () -> T) -> T {
        lock.lock()
        if let known = self[keyPath: path] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let made = make()
        lock.lock()
        self[keyPath: path] = made
        lock.unlock()
        return made
    }

    func scopedRows(_ id: String, _ make: () -> [SiteScopedRecord]) -> [SiteScopedRecord] {
        lock.lock()
        if let known = scoped[id] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let made = make()
        lock.lock()
        scoped[id] = made
        lock.unlock()
        return made
    }
}

extension InventoryStore {
    /// Fiches triées par IP avec leur site (gardées en mémoire) ; leur texte de recherche est plié
    /// à la première recherche d'un mot, puis gardé lui aussi.
    func scopedRecords(site key: String, name: String) -> [SiteScopedRecord] {
        let memo = self.memo
        return memo.scopedRows(key + "|" + name) {
            sortedRecords.map { record in
                var row = SiteScopedRecord(siteKey: key, siteName: name, record: record)
                row.memo = memo
                return row
            }
        }
    }
}
