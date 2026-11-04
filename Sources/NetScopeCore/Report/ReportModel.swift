import Foundation

// Modèle d'un rapport client : modèle (audit, inventaire…), sections cochées, client, site,
// technicien, date et options. Rien ici ne dépend de l'interface.

/// Modèle de rapport : choisit le titre et les sections cochées par défaut.
public enum ReportTemplate: String, Codable, CaseIterable, Sendable, Identifiable {
    case audit, inventaire, securite, intervention

    public var id: String { rawValue }

    /// Libellé du bouton de choix.
    public var label: String {
        switch self {
        case .audit: return "Audit réseau complet"
        case .inventaire: return "Inventaire simple"
        case .securite: return "Sécurité"
        case .intervention: return "Intervention technique"
        }
    }

    /// Description courte, sous le libellé.
    public var summary: String {
        switch self {
        case .audit: return "7 sections, client final"
        case .inventaire: return "Appareils et adressage"
        case .securite: return "Ports ouverts et risques"
        case .intervention: return "Bon de travail signé"
        }
    }

    /// Titre du document.
    public var documentTitle: String {
        switch self {
        case .audit: return "Rapport d’audit réseau"
        case .inventaire: return "Inventaire réseau"
        case .securite: return "Rapport de sécurité réseau"
        case .intervention: return "Rapport d’intervention technique"
        }
    }

    /// Libellé court pour la liste des rapports récents.
    public var shortTitle: String {
        switch self {
        case .audit: return "Audit réseau"
        case .inventaire: return "Inventaire simple"
        case .securite: return "Sécurité"
        case .intervention: return "Intervention"
        }
    }

    public var defaultSections: Set<ReportSectionKind> {
        switch self {
        case .audit: return [.resume, .inventaire, .plan, .switchs, .wifi, .securite, .problemes]
        case .inventaire: return [.resume, .inventaire, .plan, .annexe]
        case .securite: return [.resume, .switchs, .securite, .problemes]
        case .intervention: return [.resume, .switchs, .problemes]
        }
    }
}

/// Section d'un rapport. L'ordre des cas est celui de la liste à cocher (croquis Rapport).
public enum ReportSectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case resume, inventaire, plan, switchs, wifi, securite, problemes, courriel, annexe
    /// Vitesse des disques (note 22), facultative.
    case disques
    /// Wi-Fi géré par les FortiGate (note 27), facultative.
    case fortiap
    /// Occupation des étendues DHCP (note 37), facultative.
    case dhcp

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .resume: return "Résumé"
        case .inventaire: return "Inventaire"
        case .plan: return "Plan d’adressage et occupation"
        case .switchs: return "Switchs et ports"
        case .wifi: return "Wi-Fi"
        case .securite: return "Ports ouverts / sécurité"
        case .problemes: return "Problèmes et recommandations"
        case .courriel: return "Santé courriel"
        case .disques: return "Vitesse des disques"
        case .fortiap: return "Wi-Fi FortiAP"
        case .dhcp: return "Étendues DHCP"
        case .annexe: return "Annexe brute"
        }
    }

    /// Ordre dans le document : le détail (inventaire, annexe) vient après la synthèse. « Santé
    /// courriel » est facultative : aucun modèle ne la coche par défaut.
    public static let documentOrder: [ReportSectionKind] = [.resume, .plan, .dhcp, .switchs, .wifi, .fortiap, .securite, .problemes,
                                                            .courriel, .disques, .inventaire, .annexe]
}

/// Format de sortie.
public enum ReportFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case pdf, csv, json, html

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }

    public var hint: String {
        switch self {
        case .pdf: return "Document mis en page, prêt à remettre au client."
        case .csv: return "Tableaux seulement (inventaire, ports, problèmes)."
        case .json: return "Données structurées pour un outil tiers ou un RMM."
        case .html: return "Page autonome lisible dans un navigateur."
        }
    }

    public var actionLabel: String {
        switch self {
        case .pdf: return "Générer le PDF"
        case .csv: return "Exporter en CSV"
        case .json: return "Exporter en JSON"
        case .html: return "Générer la page HTML"
        }
    }
}

/// Réglages d'un rapport (aussi enregistrés comme modèle personnel).
public struct ReportConfig: Codable, Hashable, Sendable {
    public var template: ReportTemplate
    public var sections: Set<ReportSectionKind>
    public var client: String
    public var site: String
    public var technician: String
    /// Date du rapport, « 2026-11-03 ».
    public var date: String
    public var maskMAC: Bool
    public var signature: Bool
    public var format: ReportFormat

    public init(template: ReportTemplate = .audit, sections: Set<ReportSectionKind>? = nil, client: String = "",
                site: String = "", technician: String = "", date: String = "", maskMAC: Bool = false,
                signature: Bool = true, format: ReportFormat = .pdf) {
        self.template = template
        self.sections = sections ?? template.defaultSections
        self.client = client
        self.site = site
        self.technician = technician
        self.date = date
        self.maskMAC = maskMAC
        self.signature = signature
        self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case template, sections, client, site, technician, date, maskMAC, signature, format
    }

    /// Décodage tolérant : un champ absent prend sa valeur par défaut, une valeur inconnue (format ou
    /// section ajoutés par une autre version) est ignorée au lieu de rendre tout l'index illisible.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let template = (try? c.decodeIfPresent(String.self, forKey: .template)).flatMap(ReportTemplate.init(rawValue:)) ?? .audit
        self.template = template
        if let raw = try? c.decodeIfPresent([String].self, forKey: .sections) {
            sections = Set(raw.compactMap(ReportSectionKind.init(rawValue:)))
        } else {
            sections = template.defaultSections
        }
        client = (try? c.decodeIfPresent(String.self, forKey: .client)) ?? ""
        site = (try? c.decodeIfPresent(String.self, forKey: .site)) ?? ""
        technician = (try? c.decodeIfPresent(String.self, forKey: .technician)) ?? ""
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        maskMAC = (try? c.decodeIfPresent(Bool.self, forKey: .maskMAC)) ?? false
        signature = (try? c.decodeIfPresent(Bool.self, forKey: .signature)) ?? true
        format = (try? c.decodeIfPresent(String.self, forKey: .format)).flatMap(ReportFormat.init(rawValue:)) ?? .pdf
    }

    /// Change de modèle et recoche ses sections par défaut.
    public mutating func apply(_ template: ReportTemplate) {
        self.template = template
        sections = template.defaultSections
    }

    public func includes(_ kind: ReportSectionKind) -> Bool { sections.contains(kind) }

    /// « Rapport d’audit réseau — Siège »
    public var documentTitle: String {
        template.documentTitle + " — " + (site.reportTrimmed.isEmpty ? ReportText.missing : site.reportTrimmed)
    }

    /// « 3 novembre 2026 », ou « [À COMPLÉTER] ».
    public var dateLabel: String { ReportText.longDate(date) ?? ReportText.missing }

    /// La date est une vraie date du calendrier, au format « 2026-11-03 ».
    public var isDateValid: Bool { ReportText.longDate(date) != nil }

    /// « RPT-20261103-01 » ; « RPT-SANS-DATE-01 » si la date est invalide.
    public var reference: String {
        "RPT-" + (isDateValid ? date.replacingOccurrences(of: "-", with: "") : "SANS-DATE") + "-01"
    }

    /// « rapport-audit-siege-2026-11-03.pdf »
    public var fileName: String { fileName(for: format) }

    public func fileName(for format: ReportFormat) -> String {
        let site = ReportText.slug(self.site.reportTrimmed.isEmpty ? "site" : self.site)
        // Une date invalide (« 2026/11/03 ») ne doit jamais produire de sous-dossier.
        let day = isDateValid ? date : "sans-date"
        return "rapport-\(template.rawValue)-\(site)-\(day).\(format.fileExtension)"
    }
}

/// Modèle personnel enregistré (« Enregistrer comme modèle »).
public struct ReportSavedTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var config: ReportConfig
    public var saved: Date

    public init(id: UUID = UUID(), name: String, config: ReportConfig, saved: Date = Date()) {
        self.id = id
        self.name = name
        self.config = config
        self.saved = saved
    }
}

/// Rapport déjà produit (liste « Rapports récents »).
public struct ReportRecent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// Nom du fichier, dans le dossier des rapports.
    public var fileName: String
    public var format: ReportFormat
    public var date: String
    /// Nombre de pages (PDF) ou de lignes (CSV) ; nil si sans objet.
    public var pages: Int?
    public var rows: Int?
    public var technician: String
    public var created: Date

    public init(id: UUID = UUID(), title: String, fileName: String, format: ReportFormat, date: String,
                pages: Int? = nil, rows: Int? = nil, technician: String, created: Date = Date()) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.format = format
        self.date = date
        self.pages = pages
        self.rows = rows
        self.technician = technician
        self.created = created
    }

    /// « 2026-10-06 · 6 pages · Dany Ménard »
    public var meta: String {
        var parts = [date]
        if let pages { parts.append(pages > 1 ? "\(pages) pages" : "1 page") }
        if let rows { parts.append(rows > 1 ? "\(rows) lignes" : "\(rows) ligne") }
        if !technician.isEmpty { parts.append(technician) }
        return parts.joined(separator: " · ")
    }
}

/// Dossier des rapports : index des rapports récents et modèles personnels
/// (~/Library/Application Support/NetScope/rapports/).
public struct ReportLibrary: Codable, Hashable, Sendable {
    public static let maxRecents = 30
    public var version = 1
    public var recents: [ReportRecent] = []
    public var templates: [ReportSavedTemplate] = []

    public init(recents: [ReportRecent] = [], templates: [ReportSavedTemplate] = []) {
        self.recents = recents
        self.templates = templates
    }

    enum CodingKeys: String, CodingKey { case version, recents, templates }

    /// Entrées écartées au décodage (illisibles ou d'un format inconnu) ; non enregistré.
    public private(set) var droppedEntries = 0

    /// Décodage élément par élément : une entrée illisible est écartée, pas tout l'index.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        let recents = (try? c.decodeIfPresent([Lossy<ReportRecent>].self, forKey: .recents)) ?? []
        let templates = (try? c.decodeIfPresent([Lossy<ReportSavedTemplate>].self, forKey: .templates)) ?? []
        self.recents = recents.compactMap(\.value)
        self.templates = templates.compactMap(\.value)
        droppedEntries = recents.count - self.recents.count + templates.count - self.templates.count
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(recents, forKey: .recents)
        try c.encode(templates, forKey: .templates)
    }

    /// Élément d'un tableau dont le décodage peut échouer sans faire échouer le tableau.
    struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("rapports", isDirectory: true)
    }

    static let indexName = "index.json"

    /// Ajoute un rapport en tête de liste (un même fichier n'apparaît qu'une fois).
    public mutating func add(_ recent: ReportRecent) {
        recents.removeAll { $0.fileName == recent.fileName }
        recents.insert(recent, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }

    /// Enregistre un modèle ; un modèle du même nom est remplacé.
    public mutating func save(_ template: ReportSavedTemplate) {
        templates.removeAll { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }
        templates.insert(template, at: 0)
    }

    /// Rapports dont le fichier existe encore dans `directory`.
    public func existingRecents(in directory: URL) -> [ReportRecent] {
        recents.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
    }

    /// Nom libre dans `directory` : « rapport.pdf », sinon « rapport-2.pdf », « rapport-3.pdf »…
    public static func availableName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent("\(base)-\(n).\(ext)").path) { n += 1 }
        return "\(base)-\(n).\(ext)"
    }

    static let backupName = "index.json.bak"

    /// Lit l'index. S'il est illisible en tout ou en partie, une copie intacte est gardée dans
    /// index.json.bak avant que le prochain enregistrement ne le réécrive.
    public static func load(from directory: URL) -> ReportLibrary {
        let url = directory.appendingPathComponent(indexName)
        guard let data = try? Data(contentsOf: url) else { return ReportLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try? decoder.decode(ReportLibrary.self, from: data)
        if library == nil || library!.droppedEntries > 0 {
            try? data.write(to: directory.appendingPathComponent(backupName), options: .atomic)
        }
        return library ?? ReportLibrary()
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.indexName), options: .atomic)
    }
}

// MARK: - Textes

public enum ReportText {
    /// Champ à remplir par le technicien.
    public static let missing = "[À COMPLÉTER]"

    static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                         "octobre", "novembre", "décembre"]

    /// « 2026-11-03 » → « 3 novembre 2026 » ; nil si la date est invalide (format autre que
    /// AAAA-MM-JJ, ou jour qui n'existe pas : « 2026-02-31 »).
    public static func longDate(_ iso: String) -> String? {
        let pieces = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              year >= 1, (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        return "\(day) \(months[month - 1]) \(year)"
    }

    /// Nombre de jours du mois (calendrier grégorien).
    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Date du jour au format « 2026-11-03 » (calendrier grégorien, fuseau local).
    public static func isoDay(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Nom de fichier sûr : minuscules, sans accents, tirets (« Siège social » → « siege-social »).
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CA"))
            .lowercased()
        var result = ""
        var dash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
                dash = false
            } else if !dash && !result.isEmpty {
                result.append("-")
                dash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "site" : String(result.prefix(60))
    }

    /// Pourcentage à la française : « 44 % » (espace insécable).
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))\u{00A0}%"
    }

    /// MAC masquée : « 8C:16:45:xx:xx:xx ».
    public static func mac(_ mac: MACAddress?, masked: Bool) -> String {
        guard let mac else { return "—" }
        let text = mac.formatted(.upperColon)
        return masked ? String(text.prefix(8)) + ":xx:xx:xx" : text
    }
}

extension String {
    var reportTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
