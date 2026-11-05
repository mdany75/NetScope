import Foundation

// Note 10 (Inventaire, phase 3) : déplacer un ou plusieurs appareils vers un autre site (appareil
// rangé dans le mauvais site, matériel envoyé dans une succursale). Règles de la note 28 :
//
// - Jamais de fusion entre sites : un appareil dont la clé (même MAC, même adresse sans MAC) existe
//   déjà dans le site d'arrivée, en fiche ou en archive, n'est pas déplacé ; il est signalé.
// - Le site n'est jamais choisi par l'IP seule : c'est le technicien qui choisit le site d'arrivée.
// - Une même MAC vue sur deux sites est signalée (`SiteScope.sharedMACs`), jamais fusionnée.
//
// Le déplacement se fait en deux temps, chaque inventaire étant écrit séparément : le site de départ
// rend les fiches (`takeForTransfer`), le site d'arrivée les reçoit (`receive`) ; ce qu'il refuse
// est rendu au site de départ (`giveBack`).

/// Fiches et événements qui changent de site.
public struct InvTransfer: Hashable, Sendable {
    public var records: [InvRecord]
    public var events: [InvEvent]

    public init(records: [InvRecord] = [], events: [InvEvent] = []) {
        self.records = records
        self.events = events
    }

    public var isEmpty: Bool { records.isEmpty }
    public var keys: [String] { records.map(\.key) }

    /// Partie du transfert limitée à ces clés.
    public func only(_ keys: Set<String>) -> InvTransfer {
        InvTransfer(records: records.filter { keys.contains($0.key) }, events: events.filter { keys.contains($0.key) })
    }
}

/// Appareil refusé par le site d'arrivée.
public struct InvTransferRefusal: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var reason: String

    public init(key: String, name: String, reason: String) {
        self.key = key
        self.name = name
        self.reason = reason
    }
}

public extension InventoryStore {
    /// Pourquoi ce site refuserait ces fiches (même MAC ou même clé déjà là) ; vide : tout est accepté.
    func transferRefusals(for records: [InvRecord]) -> [InvTransferRefusal] {
        records.compactMap { record in
            if let here = self.records[record.key] ?? record.mac.flatMap({ mac in self.records.values.first { $0.mac == mac } }) {
                let what = record.mac != nil ? "même MAC" : "même adresse"
                return InvTransferRefusal(key: record.key, name: record.displayName,
                                          reason: "\(what) déjà dans l’inventaire («\u{00A0}\(here.displayName)\u{00A0}»)")
            }
            if archive?[record.key] != nil || (record.mac != nil && archive?.values.contains { $0.record.mac == record.mac } == true) {
                return InvTransferRefusal(key: record.key, name: record.displayName, reason: "appareil archivé dans ce site")
            }
            return nil
        }
    }

    /// Retire des fiches et leurs événements pour les donner à un autre site.
    mutating func takeForTransfer(_ keys: [String]) -> InvTransfer {
        var transfer = InvTransfer()
        var taken: Set<String> = []
        for key in keys where !taken.contains(key) {
            guard let record = records[key] else { continue }
            taken.insert(key)
            transfer.records.append(record)
            records[key] = nil
        }
        guard !taken.isEmpty else { return transfer }
        transfer.events = events.filter { taken.contains($0.key) }
        events.removeAll { taken.contains($0.key) }
        return transfer
    }

    /// Reçoit des fiches d'un autre site ; renvoie celles refusées (déjà là : jamais fusionnées).
    /// Chaque fiche reçue garde ses champs saisis, son historique et ses pièces jointes, et reçoit
    /// l'événement « Déplacé depuis « site » ».
    @discardableResult
    mutating func receive(_ transfer: InvTransfer, from siteName: String, at date: Date = Date()) -> InvTransfer {
        let refused = Set(transferRefusals(for: transfer.records).map(\.key))
        var back: [InvEvent] = []
        for record in transfer.records where !refused.contains(record.key) {
            var moved = record
            // Rien de ce site : l'état en ligne vient du scan de l'autre site.
            moved.conflictWith = []
            liftExclusions(for: moved)
            records[moved.key] = moved
            back += transfer.events.filter { $0.key == moved.key }
            back.append(InvEvent(date: date, kind: .fiche, severity: .info, key: moved.key, ip: moved.ip,
                                 title: "Déplacé depuis «\u{00A0}\(siteName)\u{00A0}»",
                                 detail: "Fiche, notes, garantie, historique et pièces jointes déplacés depuis l’inventaire de «\u{00A0}\(siteName)\u{00A0}»"))
        }
        if !back.isEmpty { insertEvents(back) }
        return transfer.only(refused)
    }

    /// Rend des fiches refusées au site de départ, telles qu'elles étaient.
    mutating func giveBack(_ transfer: InvTransfer) {
        for record in transfer.records where records[record.key] == nil { records[record.key] = record }
        if !transfer.events.isEmpty { insertEvents(transfer.events) }
    }

    /// Annule un déplacement côté site d'arrivée : retire les fiches reçues (et l'événement
    /// « Déplacé depuis… ») ; renvoie le transfert à rendre au site de départ.
    mutating func undoReceive(_ keys: [String]) -> InvTransfer {
        var transfer = takeForTransfer(keys)
        transfer.events.removeAll { $0.kind == .fiche && $0.title.hasPrefix("Déplacé depuis") }
        return transfer
    }
}

public extension SiteScope {
    /// MAC vues dans plusieurs sites : MAC → clés des sites (dans l'ordre des inventaires). Les
    /// fiches restent distinctes : c'est un signalement, jamais une fusion.
    static func sharedMACs(_ inventories: [SiteInventory]) -> [MACAddress: [String]] {
        var sites: [MACAddress: [String]] = [:]
        for inventory in inventories {
            var seen: Set<MACAddress> = []
            for record in inventory.store.records.values {
                guard let mac = record.mac, seen.insert(mac).inserted else { continue }
                sites[mac, default: []].append(inventory.key)
            }
        }
        return sites.filter { $0.value.count > 1 }
    }
}
