import Foundation

// Note 10 (Inventaire, phase 3) : fiche matériel d'un appareil. Garantie (date d'achat, fin de
// garantie, fournisseur, numéro de série, prix facultatif) avec l'alerte « garantie bientôt échue »,
// et pièces jointes (factures, contrats, photos) copiées dans
// ~/Library/Application Support/NetScope/Inventaire/<site>/<appareil>/.
//
// La garantie est un champ saisi (InvAnnotations.hardware) : jamais écrasée par un scan, elle suit
// la fiche (archive, déplacement vers un autre site, fusion de doublons). Les pièces jointes sont
// sur la fiche (InvRecord.attachments) : elles changent tout de suite, sans brouillon à enregistrer.

/// Achat et garantie d'un appareil.
public struct InvHardware: Codable, Hashable, Sendable {
    public var purchaseDate: Date?
    public var warrantyEnd: Date?
    public var supplier: String
    public var serialNumber: String
    /// Prix d'achat (facultatif), en dollars.
    public var price: Double?

    public init(purchaseDate: Date? = nil, warrantyEnd: Date? = nil, supplier: String = "", serialNumber: String = "",
                price: Double? = nil) {
        self.purchaseDate = purchaseDate
        self.warrantyEnd = warrantyEnd
        self.supplier = supplier
        self.serialNumber = serialNumber
        self.price = price
    }

    public var isEmpty: Bool {
        purchaseDate == nil && warrantyEnd == nil && supplier.trimmingCharacters(in: .whitespaces).isEmpty
            && serialNumber.trimmingCharacters(in: .whitespaces).isEmpty && price == nil
    }

    /// Champs vides retirés (texte rogné) ; nil si rien n'est rempli.
    public var cleaned: InvHardware? {
        var copy = self
        copy.supplier = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.serialNumber = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if let price, !price.isFinite || price < 0 { copy.price = nil }
        return copy.isEmpty ? nil : copy
    }

    /// État de la garantie à la date donnée ; `soonDays` : seuil de « bientôt échue ».
    public func warranty(now: Date = Date(), soonDays: Int = InvHardware.warrantySoonDays) -> InvWarrantyState {
        guard let end = warrantyEnd else { return .unknown }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        let last = calendar.startOfDay(for: end)
        let days = calendar.dateComponents([.day], from: today, to: last).day ?? 0
        if days < 0 { return .expired(days: -days) }
        if days <= soonDays { return .expiringSoon(days: days) }
        return .active(days: days)
    }

    /// Seuil de l'alerte « garantie bientôt échue » : 60 jours.
    public static let warrantySoonDays = 60

    /// « 1 249,99 $ »
    public static func priceLabel(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CAD"
        formatter.currencySymbol = "$"
        return formatter.string(from: NSNumber(value: price)) ?? String(format: "%.2f $", price)
    }

    /// Lit un prix saisi (« 1249,99 », « 1 249.99 $ ») ; nil si vide ou illisible.
    public static func parsePrice(_ text: String) -> Double? {
        var cleaned = text.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        // Les deux séparateurs : le dernier est celui des décimales (« 1.249,99 » ou « 1,249.99 »).
        if let comma = cleaned.lastIndex(of: ","), let dot = cleaned.lastIndex(of: ".") {
            cleaned = comma > dot ? cleaned.replacingOccurrences(of: ".", with: "") : cleaned.replacingOccurrences(of: ",", with: "")
        }
        cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// État d'une garantie.
public enum InvWarrantyState: Hashable, Sendable {
    /// Aucune date de fin saisie.
    case unknown
    case active(days: Int)
    /// Échéance dans `days` jours (0 : aujourd'hui), sous le seuil d'alerte.
    case expiringSoon(days: Int)
    /// Échue depuis `days` jours.
    case expired(days: Int)

    /// À signaler : bientôt échue (les garanties déjà échues ne sont plus une alerte).
    public var isAlert: Bool {
        if case .expiringSoon = self { return true }
        return false
    }

    /// « Garantie jusqu'au 2027-03-01 », « Échue dans 24 j », « Échue depuis 12 j ».
    public var label: String {
        switch self {
        case .unknown: return "Garantie non renseignée"
        case .active(let days): return days > 365 ? "Sous garantie (\(days / 365) an\(days >= 730 ? "s" : "") et plus)" : "Sous garantie (\(days) j)"
        case .expiringSoon(let days):
            return days == 0 ? "Garantie échue aujourd’hui" : "Garantie bientôt échue (dans \(days) j)"
        case .expired(let days): return "Garantie échue depuis \(days) j"
        }
    }

    /// Ordre de tri : bientôt échue, puis active, échue, inconnue.
    public var rank: Int {
        switch self {
        case .expiringSoon(let days): return days
        case .active(let days): return 10_000 + days
        case .expired(let days): return 100_000 + days
        case .unknown: return 1_000_000
        }
    }
}

// MARK: - Pièces jointes

/// Fichier joint à une fiche : copié dans le dossier de l'appareil, jamais lu par NetScope.
public struct InvAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Nom d'origine, affiché.
    public var fileName: String
    /// Nom du fichier dans le dossier de l'appareil (unique dans ce dossier).
    public var storedName: String
    public var size: Int64
    public var added: Date

    public init(id: UUID = UUID(), fileName: String, storedName: String, size: Int64, added: Date) {
        self.id = id
        self.fileName = fileName
        self.storedName = storedName
        self.size = size
        self.added = added
    }

    /// « 184 Ko », « 2,4 Mo »
    public var sizeLabel: String {
        // Unités françaises (Ko, Mo, Go), base 1000 comme le Finder.
        let value = Double(size)
        if value < 1_000 { return "\(size)\u{00A0}octet\(size > 1 ? "s" : "")" }
        let units = ["Ko", "Mo", "Go", "To"]
        var scaled = value / 1_000
        var index = 0
        while scaled >= 1_000 && index < units.count - 1 {
            scaled /= 1_000
            index += 1
        }
        let text = scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled).replacingOccurrences(of: ".", with: ",")
        return text + "\u{00A0}" + units[index]
    }
}

/// Fichiers joints sur le disque : ~/Library/Application Support/NetScope/Inventaire/<site>/<dossier>/.
/// Toute l'écriture passe ici (les essais utilisent un dossier temporaire).
public struct InvAttachmentFiles: Sendable {
    public let base: URL
    /// Vrai : un fichier retiré va à la corbeille de macOS (récupérable) ; faux (essais) : supprimé.
    public let useTrash: Bool

    public init(base: URL, useTrash: Bool = true) {
        self.base = base
        self.useTrash = useTrash
    }

    /// ~/Library/Application Support/NetScope/Inventaire
    public static var standard: InvAttachmentFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return InvAttachmentFiles(base: support.appendingPathComponent("NetScope", isDirectory: true)
            .appendingPathComponent("Inventaire", isDirectory: true))
    }

    /// Nom de dossier lisible et unique : « Imprimante-accueil-1A2B3C4D ».
    public static func folderName(for record: InvRecord, id: UUID = UUID()) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let base = record.displayName
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
            .unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let short = String(id.uuidString.prefix(8))
        let trimmed = String(base.prefix(40))
        return trimmed.isEmpty ? "Appareil-" + short : trimmed + "-" + short
    }

    /// Dossier d'un site (clé `SiteFiles.key`, déjà sûre pour un nom de fichier).
    public func siteURL(_ site: String) -> URL {
        base.appendingPathComponent(Self.safe(site), isDirectory: true)
    }

    public func folderURL(site: String, folder: String) -> URL {
        siteURL(site).appendingPathComponent(Self.safe(folder), isDirectory: true)
    }

    public func url(of attachment: InvAttachment, site: String, folder: String) -> URL {
        folderURL(site: site, folder: folder).appendingPathComponent(Self.safe(attachment.storedName))
    }

    /// Copie un fichier dans le dossier de l'appareil (nom rendu unique : « facture 2.pdf »).
    public func add(_ source: URL, site: String, folder: String, at date: Date = Date()) throws -> InvAttachment {
        let manager = FileManager.default
        let directory = folderURL(site: site, folder: folder)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = source.lastPathComponent
        let stem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var name = Self.safe(original)
        var counter = 2
        while manager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = Self.safe(stem + " \(counter)" + (ext.isEmpty ? "" : "." + ext))
            counter += 1
        }
        let target = directory.appendingPathComponent(name)
        try manager.copyItem(at: source, to: target)
        let size = (try? manager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        return InvAttachment(fileName: original, storedName: name, size: size, added: date)
    }

    /// Retire un fichier joint (corbeille de macOS, ou suppression pendant les essais).
    public func remove(_ attachment: InvAttachment, site: String, folder: String) throws {
        let url = url(of: attachment, site: site, folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try discard(url)
    }

    /// Dossier entier d'un appareil supprimé définitivement : à la corbeille (récupérable).
    public func removeFolder(site: String, folder: String) throws {
        let url = folderURL(site: site, folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try discard(url)
    }

    /// Dossier d'un appareil supprimé pour de bon : à la corbeille de macOS ; renvoie son adresse
    /// dans la corbeille (pour « Annuler »), nil s'il n'y avait rien (ou pendant les essais).
    public func trashFolder(site: String, folder: String) throws -> URL? {
        let url = folderURL(site: site, folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard useTrash else {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Remet un dossier sorti de la corbeille (« Annuler » une suppression définitive).
    public func recoverFolder(_ trashed: URL, site: String, folder: String) throws {
        let url = folderURL(site: site, folder: folder)
        guard FileManager.default.fileExists(atPath: trashed.path), !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed, to: url)
    }

    /// Déplace le dossier d'un appareil vers un autre site (l'appareil change de site). Un dossier
    /// du même nom dans le site d'arrivée n'est jamais écrasé : erreur.
    public func moveFolder(_ folder: String, from source: String, to destination: String) throws {
        let manager = FileManager.default
        let from = folderURL(site: source, folder: folder)
        guard manager.fileExists(atPath: from.path) else { return }
        let to = folderURL(site: destination, folder: folder)
        try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: from, to: to)
    }

    private func discard(_ url: URL) throws {
        if useTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Nom sûr pour un fichier : ni « / », ni « : », ni nom caché, ni « .. ».
    static func safe(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "fichier" : cleaned
    }
}

// MARK: - Inventaire

public extension InventoryStore {
    /// Garanties bientôt échues (sous le seuil), de la plus proche à la plus lointaine.
    /// Exposé aussi pour les rapports (note 42).
    func expiringWarranties(now: Date = Date(), soonDays: Int = InvHardware.warrantySoonDays) -> [InvRecord] {
        records.values
            .filter { $0.annotations.hardware?.warranty(now: now, soonDays: soonDays).isAlert == true }
            .sorted { ($0.annotations.hardware?.warrantyEnd ?? .distantFuture, $0.key) < ($1.annotations.hardware?.warrantyEnd ?? .distantFuture, $1.key) }
    }

    /// Ajoute une pièce jointe à une fiche ; le dossier est retenu à la première pièce.
    /// Faux si la fiche n'existe pas.
    @discardableResult
    mutating func addAttachment(_ attachment: InvAttachment, folder: String, to key: String) -> Bool {
        guard var record = records[key] else { return false }
        if record.attachmentFolder == nil { record.attachmentFolder = folder }
        record.attachments = record.attachmentList + [attachment]
        records[key] = record
        return true
    }

    /// Retire une pièce jointe de la fiche (le fichier est retiré à part) ; renvoie la pièce retirée.
    @discardableResult
    mutating func removeAttachment(_ id: UUID, from key: String) -> InvAttachment? {
        guard var record = records[key], let index = record.attachmentList.firstIndex(where: { $0.id == id }) else { return nil }
        var list = record.attachmentList
        let removed = list.remove(at: index)
        record.attachments = list.isEmpty ? nil : list
        records[key] = record
        return removed
    }

    /// Étiquettes utilisées dans l'inventaire, sans doublon (casse ignorée), dans l'ordre alphabétique.
    var allTags: [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        // Dans l'ordre des fiches (par IP) : la première graphie rencontrée l'emporte, toujours la même.
        for record in sortedRecords {
            for tag in record.annotations.tags {
                let key = tag.lowercased()
                if seen.insert(key).inserted { tags.append(tag) }
            }
        }
        return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public extension SiteScope {
    /// Garanties bientôt échues de plusieurs sites, une ligne par site et par fiche (note 42 : rapports).
    static func expiringWarranties(_ inventories: [SiteInventory], now: Date = Date(),
                                   soonDays: Int = InvHardware.warrantySoonDays) -> [SiteScopedRecord] {
        inventories.flatMap { inventory in
            inventory.store.expiringWarranties(now: now, soonDays: soonDays).map {
                SiteScopedRecord(siteKey: inventory.key, siteName: inventory.name, record: $0)
            }
        }
    }
}
