import Foundation

// Contenu d'un rapport, indépendant du format : sections faites de blocs (paragraphe,
// indicateurs, barres, tableau, note, texte brut). Les exports PDF, HTML, CSV et JSON et
// l'aperçu lisent tous ce même document.

/// Gravité d'un problème ou d'un port ouvert.
public enum ReportSeverity: String, Codable, CaseIterable, Sendable, Comparable {
    case critique, eleve, moyen, faible

    public var label: String {
        switch self {
        case .critique: return "Critique"
        case .eleve: return "Élevé"
        case .moyen: return "Moyen"
        case .faible: return "Faible"
        }
    }

    var rank: Int {
        switch self {
        case .critique: return 0
        case .eleve: return 1
        case .moyen: return 2
        case .faible: return 3
        }
    }

    public static func < (lhs: ReportSeverity, rhs: ReportSeverity) -> Bool { lhs.rank < rhs.rank }

    public var tone: ReportTone {
        switch self {
        case .critique: return .critical
        case .eleve: return .warning
        case .moyen: return .caution
        case .faible: return .neutral
        }
    }
}

/// Couleur sémantique d'un texte ou d'une pastille.
public enum ReportTone: String, Codable, Sendable {
    case normal, muted, neutral, success, caution, warning, critical
}

public struct ReportCell: Codable, Hashable, Sendable {
    public var text: String
    /// Texte présenté en pastille colorée (gravité, état).
    public var badge: ReportTone?
    public var tone: ReportTone
    public var bold: Bool
    /// Barre d'occupation (0…1) dessinée devant le texte.
    public var bar: Double?

    public init(_ text: String, badge: ReportTone? = nil, tone: ReportTone = .normal, bold: Bool = false, bar: Double? = nil) {
        self.text = text
        self.badge = badge
        self.tone = tone
        self.bold = bold
        self.bar = bar
    }
}

public struct ReportColumn: Codable, Hashable, Sendable {
    public var title: String
    /// Part de la largeur du tableau quand la largeur ne peut pas être estimée (les poids sont normalisés).
    public var weight: Double
    public var trailing: Bool
    public var mono: Bool
    /// Taille du texte des cellules, en points PDF ; nil : texte courant.
    public var size: Double?
    /// La colonne peut rétrécir (texte coupé ou renvoyé à la ligne) ; nil : oui sauf en SF Mono.
    public var shrinks: Bool?

    public init(_ title: String, weight: Double = 1, trailing: Bool = false, mono: Bool = false, size: Double? = nil,
                shrinks: Bool? = nil) {
        self.title = title
        self.weight = weight
        self.trailing = trailing
        self.mono = mono
        self.size = size
        self.shrinks = shrinks
    }
}

public struct ReportRow: Codable, Hashable, Sendable {
    public var cells: [ReportCell]
    /// Ligne de sous-total (fond gris, gras).
    public var isTotal: Bool

    public init(_ cells: [ReportCell], isTotal: Bool = false) {
        self.cells = cells
        self.isTotal = isTotal
    }
}

public struct ReportTable: Codable, Hashable, Sendable {
    public var columns: [ReportColumn]
    public var rows: [ReportRow]
    /// Lignes sur plusieurs lignes de texte (recommandations).
    public var wraps: Bool
    /// Tableau dense (inventaire) : marges et en-têtes réduits, lignes de 24 px du croquis.
    public var dense: Bool
    /// Largeurs des colonnes en points, fixées par la pagination sur le tableau entier : les
    /// morceaux d'un tableau coupé gardent les mêmes colonnes d'une page à l'autre.
    public var widths: [Double]?

    public init(columns: [ReportColumn], rows: [ReportRow], wraps: Bool = false, dense: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.wraps = wraps
        self.dense = dense
    }

    /// Largeurs relatives normalisées (somme 1).
    public var fractions: [Double] {
        let total = columns.map(\.weight).reduce(0, +)
        return columns.map { total > 0 ? $0.weight / total : 1 / Double(max(columns.count, 1)) }
    }
}

public struct ReportKPI: Codable, Hashable, Sendable {
    public var value: String
    public var label: String
    public var tone: ReportTone

    public init(_ value: String, _ label: String, tone: ReportTone = .normal) {
        self.value = value
        self.label = label
        self.tone = tone
    }
}

public struct ReportBar: Codable, Hashable, Sendable {
    public var label: String
    public var count: Int
    /// Longueur relative à la plus grande barre (0…1).
    public var fraction: Double
    public var share: String
    public var muted: Bool

    public init(label: String, count: Int, fraction: Double, share: String, muted: Bool = false) {
        self.label = label
        self.count = count
        self.fraction = fraction
        self.share = share
        self.muted = muted
    }
}

public enum ReportBlock: Codable, Hashable, Sendable {
    case paragraph(String)
    case kpis([ReportKPI])
    case bars(title: String, [ReportBar])
    case table(ReportTable)
    case note(String)
    case code([String])
}

public struct ReportSection: Codable, Hashable, Sendable, Identifiable {
    /// « inventaire » ; rapport multisite : « Siège|inventaire » (une section par site).
    public var id: String { site.map { $0 + "|" + kind.rawValue } ?? kind.rawValue }
    public var kind: ReportSectionKind
    /// « 3. Switchs et ports »
    public var heading: String
    public var blocks: [ReportBlock]
    /// Site décrit par la section (rapport multisite) ; nil : rapport d'un seul site.
    public var site: String?

    public init(kind: ReportSectionKind, heading: String, blocks: [ReportBlock], site: String? = nil) {
        self.kind = kind
        self.heading = heading
        self.blocks = blocks
        self.site = site
    }

    /// Tableaux de la section (exports CSV).
    public var tables: [ReportTable] {
        blocks.compactMap { if case .table(let table) = $0 { return table } else { return nil } }
    }
}

/// Un problème constaté et sa recommandation.
public struct ReportProblem: Codable, Hashable, Sendable {
    public var title: String
    public var severity: ReportSeverity
    public var recommendation: String

    public init(title: String, severity: ReportSeverity, recommendation: String) {
        self.title = title
        self.severity = severity
        self.recommendation = recommendation
    }
}

public struct ReportDocument: Codable, Hashable, Sendable {
    public var title: String
    public var template: ReportTemplate
    public var client: String
    public var site: String
    public var technician: String
    public var date: String
    public var dateLabel: String
    public var reference: String
    public var generator: String
    public var signature: Bool
    public var sections: [ReportSection]
    public var problems: [ReportProblem]

    public init(title: String, template: ReportTemplate, client: String, site: String, technician: String, date: String,
                dateLabel: String, reference: String, generator: String, signature: Bool, sections: [ReportSection],
                problems: [ReportProblem]) {
        self.title = title
        self.template = template
        self.client = client
        self.site = site
        self.technician = technician
        self.date = date
        self.dateLabel = dateLabel
        self.reference = reference
        self.generator = generator
        self.signature = signature
        self.sections = sections
        self.problems = problems
    }

    public var clientLabel: String { client.isEmpty ? ReportText.missing : client }
    public var technicianLabel: String { technician.isEmpty ? ReportText.missing : technician }

    public func section(_ kind: ReportSectionKind) -> ReportSection? { sections.first { $0.kind == kind } }
}

// MARK: - Pagination

/// Mesure de la largeur d'un texte avec la vraie police de dessin (fournie par l'application, qui
/// seule peut utiliser AppKit). Sans mesureur, `ReportPageMetrics` se rabat sur une estimation.
public struct ReportTextMeasurer: Hashable, Sendable {
    /// Nom du mesureur (égalité et hachage).
    public let name: String
    /// Largeur en points d'un texte sur une ligne, à `size` points (mono : police à chasse fixe).
    public let measure: @Sendable (_ text: String, _ size: Double, _ mono: Bool, _ bold: Bool) -> Double

    public init(name: String, measure: @escaping @Sendable (_ text: String, _ size: Double, _ mono: Bool, _ bold: Bool) -> Double) {
        self.name = name
        self.measure = measure
    }

    public static func == (lhs: ReportTextMeasurer, rhs: ReportTextMeasurer) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var value: ReportTextMeasurer?
    }
    private static let slot = Slot()

    /// Mesureur installé par l'application au lancement ; repris par chaque `ReportPageMetrics()`.
    public static var installed: ReportTextMeasurer? {
        get { slot.lock.lock(); defer { slot.lock.unlock() }; return slot.value }
        set { slot.lock.lock(); slot.value = newValue; slot.lock.unlock() }
    }
}

/// Dimensions d'une page lettre (en points PDF) et hauteurs des éléments, d'après le croquis
/// Rapport.dc.html (page de 680 px de large ramenée à 612 pt : facteur 0,9). La vue de page de
/// l'application dessine chaque élément exactement à ces hauteurs : la pagination reste fidèle.
public struct ReportPageMetrics: Hashable, Sendable {
    /// Points PDF par pixel du croquis.
    public static let scale = 0.9

    public var pageWidth: Double = 612
    public var pageHeight: Double = 792
    public var marginX: Double = 39.6
    public var marginTop: Double = 36
    public var marginBottom: Double = 25.2
    /// En-tête du document (logo, titre, date) et l'espace qui le suit.
    public var headerHeight: Double = 68.4
    public var footerHeight: Double = 35
    public var signatureHeight: Double = 65
    public var sectionGap: Double = 16.2
    public var blockGap: Double = 9
    public var headingHeight: Double = 19.8
    /// Texte courant : 12 px du croquis.
    public var bodySize: Double = 10.8
    /// Notes sous les tableaux : 11 px du croquis.
    public var noteSize: Double = 9.9
    public var tableHeaderHeight: Double = 23.4
    public var rowHeight: Double = 22.5
    public var kpiHeight: Double = 58
    public var barTitleHeight: Double = 18
    public var barHeight: Double = 16.2
    public var codeLineHeight: Double = 15.3
    public var codePadding: Double = 14.4
    /// Vraie police de dessin, si l'application en a installé une (sinon : estimation).
    public var measurer: ReportTextMeasurer? = ReportTextMeasurer.installed

    public init() {}

    public var contentWidth: Double { pageWidth - 2 * marginX }
    /// Hauteur disponible entre l'en-tête et le pied.
    public var contentHeight: Double { pageHeight - marginTop - marginBottom - headerHeight - footerHeight }
    public var lineHeight: Double { bodySize * 1.5 }
    public var noteLineHeight: Double { noteSize * 1.5 }

    /// Nombre de lignes d'un texte sur `width` points : retour à la ligne mot par mot (un mot trop
    /// long est coupé). Avec la vraie police, 1 pt de marge ; avec l'estimation, 5 % de la largeur.
    public func lines(_ text: String, width: Double, size: Double? = nil, mono: Bool = false, bold: Bool = false) -> Int {
        let size = size ?? bodySize
        let usable = measurer == nil ? width * 0.95 : width - 1
        guard usable > 1 else { return max(1, text.count) }
        let space = textWidth(" ", size: size, mono: mono, bold: bold)
        var total = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var count = 1
            var line = 0.0
            for word in paragraph.split(separator: " ") {
                // Comme le dessin, on peut passer à la ligne après un trait d'union (« SW-|ETG2-01 »).
                for (index, piece) in Self.hyphenPieces(String(word)).enumerated() {
                    var w = textWidth(piece, size: size, mono: mono, bold: bold)
                    let gap = index == 0 ? space : 0
                    let needed = line == 0 ? w : line + gap + w
                    if needed <= usable {
                        line = needed
                        continue
                    }
                    if line > 0 { count += 1 }
                    while w > usable {
                        count += 1
                        w -= usable
                    }
                    line = w
                }
            }
            total += count
        }
        return total
    }

    /// Morceaux d'un mot coupables après un trait d'union suivi d'une lettre, comme le fait le
    /// dessin (« SW-ETG2-01 » → « SW- », « ETG2-01 » ; « FortiAP-231F » reste entier).
    public static func hyphenPieces(_ word: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        let chars = Array(word)
        for (index, char) in chars.enumerated() {
            current.append(char)
            if char == "-", current.count > 1, index + 1 < chars.count, chars[index + 1].isLetter {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    public func paragraphHeight(_ text: String) -> Double {
        Double(lines(text, width: contentWidth)) * lineHeight
    }

    public func noteHeight(_ text: String) -> Double {
        Double(lines(text, width: contentWidth, size: noteSize)) * noteLineHeight
    }

    /// Largeur estimée d'un texte sur une ligne (volontairement un peu large : mieux vaut une
    /// colonne trop large qu'une adresse IP tronquée).
    public func textWidth(_ text: String, size: Double, mono: Bool = false, bold: Bool = false) -> Double {
        if let measurer { return measurer.measure(text, size, mono, bold) }
        if mono { return Double(text.count) * size * 0.64 }
        // Police proportionnelle : majuscules et chiffres plus larges que les minuscules.
        var em = 0.0
        for char in text {
            if char == " " { em += 0.3 }
            else if char.isUppercase || char == "W" || char == "m" || char == "w" { em += 0.7 }
            else if char.isNumber { em += 0.62 }
            else if ".,:;·'’()/|-_".contains(char) { em += 0.38 }
            else { em += 0.56 }
        }
        return em * size * (bold ? 1.07 : 1)
    }

    /// Marges horizontales d'une cellule (6 px du croquis de chaque côté ; 4 px en tableau dense).
    public func cellPadding(_ table: ReportTable) -> Double { table.dense ? 7.2 : 10.8 }
    /// Marges verticales d'une cellule sur plusieurs lignes.
    public func cellVerticalPadding(_ table: ReportTable) -> Double { table.dense ? 6 : 10.8 }
    /// En-têtes de colonne : 11 px du croquis (9 px en tableau dense), en majuscules.
    public func headerSize(_ table: ReportTable) -> Double { table.dense ? 8.1 : 9.9 }
    /// Taille du texte des pastilles (10 px du croquis).
    public var badgeSize: Double { 9 }

    /// Largeur d'une cellule sans retour à la ligne, marges comprises.
    func naturalWidth(_ cell: ReportCell, column: ReportColumn, padding: Double) -> Double {
        if cell.bar != nil { return 110 }
        if cell.badge != nil { return textWidth(cell.text, size: badgeSize, bold: true) + 10.8 + padding }
        return textWidth(cell.text, size: column.size ?? bodySize, mono: column.mono, bold: cell.bold) + padding
    }

    /// Largeur de chaque colonne (somme : largeur utile de la page). Chaque colonne reçoit la largeur
    /// de son plus long contenu. S'il manque de la place, seules les colonnes qui peuvent céder (texte :
    /// noms, modèles, recommandations, ports) rétrécissent, la plus large d'abord, jusqu'à 45 pt ; les
    /// adresses IP et MAC et les pastilles gardent leur largeur.
    public func columnWidths(_ table: ReportTable) -> [Double] {
        if let widths = table.widths, widths.count == table.columns.count { return widths }
        let width = contentWidth
        let padding = cellPadding(table)
        var natural = table.columns.map { Double($0.title.count) * headerSize(table) * 0.7 + padding }
        var flexible = table.columns.map { $0.shrinks ?? !$0.mono }
        // Plus long mot de chaque colonne : une colonne souple ne descend pas en dessous, pour ne pas
        // couper un nom d'hôte, un nom de switch ou de port au milieu (plafonné à 22 % de la page).
        var longestWord = table.columns.map { _ in 0.0 }
        for row in table.rows {
            for (index, cell) in row.cells.enumerated() where index < natural.count {
                let column = table.columns[index]
                natural[index] = max(natural[index], naturalWidth(cell, column: column, padding: padding))
                if cell.badge != nil || cell.bar != nil { flexible[index] = false; continue }
                // Le dessin peut passer à la ligne après un trait d'union : seul le plus long morceau compte.
                for word in cell.text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                    for piece in Self.hyphenPieces(String(word)) {
                        let w = textWidth(piece, size: column.size ?? bodySize, mono: column.mono, bold: cell.bold)
                        longestWord[index] = max(longestWord[index], w)
                    }
                }
            }
        }
        let total = natural.reduce(0, +)
        guard total > 0 else { return table.fractions.map { $0 * width } }
        if total <= width {
            // Place en trop : répartie selon les largeurs naturelles.
            return natural.map { $0 + ($0 / total) * (width - total) }
        }
        // Remplissage par niveau : chaque colonne souple est plafonnée à T × son poids, avec T le plus
        // grand possible (recherche par dichotomie).
        let fixed = natural.indices.filter { !flexible[$0] }.map { natural[$0] }.reduce(0, +)
        let soft = natural.indices.filter { flexible[$0] }
        let budget = width - fixed
        var widths = natural
        if !soft.isEmpty {
            var minimum = natural.indices.map { index in
                min(natural[index], max(45.0, min(longestWord[index] + padding + 1, width * 0.22)))
            }
            // Si ces planchers ne tiennent pas tous, les colonnes de plus faible poids (type, modèle)
            // cèdent d'abord, jusqu'à 45 pt ; les noms et ports en dernier. Les adresses et pastilles
            // ne rétrécissent jamais à cause d'un long mot.
            var excess = soft.map { minimum[$0] }.reduce(0, +) - budget
            for index in soft.sorted(by: { table.columns[$0].weight < table.columns[$1].weight }) where excess > 0 {
                let cut = min(excess, max(0, minimum[index] - 45))
                minimum[index] -= cut
                excess -= cut
            }
            func fill(_ t: Double) -> Double {
                soft.map { min(natural[$0], max(minimum[$0], t * table.columns[$0].weight)) }.reduce(0, +)
            }
            var low = 0.0
            var high = (soft.map { natural[$0] / max(table.columns[$0].weight, 0.01) }.max() ?? 0) + 1
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if fill(mid) <= budget { low = mid } else { high = mid }
            }
            for index in soft { widths[index] = min(natural[index], max(minimum[index], low * table.columns[index].weight)) }
        }
        let remaining = widths.reduce(0, +)
        if remaining > width { widths = widths.map { $0 * width / remaining } }
        else if remaining < width, let widest = soft.max(by: { widths[$0] < widths[$1] }) { widths[widest] += width - remaining }
        return widths
    }

    /// Hauteur d'une ligne de tableau.
    public func rowHeight(_ row: ReportRow, in table: ReportTable) -> Double {
        let base = table.dense ? denseRowHeight : rowHeight
        guard table.wraps else { return base }
        let widths = columnWidths(table)
        var height = base
        for (index, cell) in row.cells.enumerated() where index < widths.count && cell.badge == nil && cell.bar == nil {
            let column = table.columns[index]
            let size = column.size ?? bodySize
            let available = widths[index] - cellPadding(table)
            // Une cellule qui tient sur une ligne garde la hauteur ordinaire.
            if naturalWidth(cell, column: column, padding: 0) <= available { continue }
            let count = lines(cell.text, width: available, size: size, mono: column.mono, bold: cell.bold)
            if count <= 1 { continue }
            height = max(height, Double(count) * size * 1.45 + cellVerticalPadding(table))
        }
        return height.rounded(.up)
    }

    /// Ligne d'un tableau dense (24 px du croquis : inventaire).
    public var denseRowHeight: Double = 21.6

    public func height(of block: ReportBlock) -> Double {
        switch block {
        case .paragraph(let text): return paragraphHeight(text)
        case .kpis: return kpiHeight
        case .bars(_, let bars): return barTitleHeight + Double(bars.count) * barHeight
        case .table(let table): return tableHeaderHeight + table.rows.map { rowHeight($0, in: table) }.reduce(0, +)
        case .note(let text): return noteHeight(text)
        case .code(let lines): return codePadding + Double(lines.count) * codeLineHeight
        }
    }
}

/// Élément placé sur une page.
public enum ReportPageItem: Hashable, Sendable {
    /// Titre de section ; `continued` : suite d'une section commencée à la page précédente.
    case heading(String, continued: Bool)
    case block(ReportBlock)
}

public struct ReportPage: Hashable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var items: [ReportPageItem]
    /// Sections qui commencent sur cette page.
    public var sections: [ReportSectionKind]
    /// Hauteur occupée estimée.
    public var used: Double
    /// La signature est dessinée au bas de cette page (la dernière).
    public var hasSignature: Bool
}

public enum ReportPaginator {
    /// Répartit les sections sur des pages lettre. Un tableau trop long est coupé entre deux lignes
    /// (le titre de section est répété avec « (suite) ») ; un titre ne reste jamais seul en bas de page.
    public static func paginate(_ document: ReportDocument, metrics: ReportPageMetrics = ReportPageMetrics()) -> [ReportPage] {
        let capacity = metrics.contentHeight
        var pages: [ReportPage] = []
        var items: [ReportPageItem] = []
        var starts: [ReportSectionKind] = []
        var used = 0.0

        func newPage() {
            pages.append(ReportPage(number: pages.count + 1, items: items, sections: starts, used: used, hasSignature: false))
            items = []
            starts = []
            used = 0
        }
        func gap(_ value: Double) -> Double { items.isEmpty ? 0 : value }

        for section in document.sections {
            let headingCost = metrics.headingHeight
            // Le titre, une note d'introduction éventuelle et le début du premier tableau tiennent ensemble.
            var firstMin = 0.0
            for (index, block) in section.blocks.prefix(2).enumerated() {
                let spacing = index == 0 ? 0 : metrics.blockGap
                if case .table = block {
                    firstMin += spacing + minimumHeight(block, metrics)
                    break
                }
                firstMin += spacing + minimumHeight(block, metrics)
                if case .note = block { continue }
                break
            }
            if !items.isEmpty && used + gap(metrics.sectionGap) + headingCost + firstMin > capacity { newPage() }
            used += gap(metrics.sectionGap) + headingCost
            items.append(.heading(section.heading, continued: false))
            starts.append(section.kind)

            for (index, original) in section.blocks.enumerated() {
                var block = original
                if case .table(var whole) = original {
                    whole.widths = metrics.columnWidths(whole)
                    block = .table(whole)
                }
                let spacing = index == 0 ? 0 : metrics.blockGap
                let height = metrics.height(of: block)
                if used + spacing + height <= capacity {
                    used += spacing + height
                    items.append(.block(block))
                    continue
                }
                if case .code(let lines) = block {
                    // Texte brut : coupé entre deux lignes, la suite sur les pages suivantes.
                    var remaining = lines[...]
                    var currentSpacing = spacing
                    while !remaining.isEmpty {
                        let room = capacity - used - currentSpacing - metrics.codePadding
                        let count = max(0, Int(room / metrics.codeLineHeight))
                        if count == 0 && !(used <= metrics.headingHeight + 0.5) {
                            newPage()
                            items.append(.heading(section.heading, continued: true))
                            used = metrics.headingHeight
                            currentSpacing = 0
                            continue
                        }
                        let slice = Array(remaining.prefix(max(1, count)))
                        remaining = remaining.dropFirst(slice.count)
                        used += currentSpacing + metrics.height(of: .code(slice))
                        items.append(.block(.code(slice)))
                        if !remaining.isEmpty {
                            newPage()
                            items.append(.heading(section.heading, continued: true))
                            used = metrics.headingHeight
                            currentSpacing = 0
                        }
                    }
                    continue
                }
                guard case .table(let table) = block else {
                    // Bloc insécable : page suivante (ou coupé s'il dépasse une page entière). Une note
                    // qui suit un tableau n'y part pas seule : la dernière ligne du tableau l'accompagne.
                    var carried: [ReportPageItem] = []
                    var carriedHeight = 0.0
                    if case .note = block, case .block(.table(var previous))? = items.last, previous.rows.count >= 2,
                       let lastRow = previous.rows.last {
                        let rowHeight = metrics.rowHeight(lastRow, in: previous)
                        previous.rows.removeLast()
                        items[items.count - 1] = .block(.table(previous))
                        used -= rowHeight
                        var part = previous
                        part.rows = [lastRow]
                        carried = [.block(.table(part))]
                        carriedHeight = metrics.height(of: .table(part)) + metrics.blockGap
                    }
                    newPage()
                    items.append(.heading(section.heading, continued: true))
                    items.append(contentsOf: carried)
                    used = metrics.headingHeight + carriedHeight + height
                    items.append(.block(block))
                    continue
                }
                // Tableau : autant de lignes que possible, la suite sur les pages suivantes.
                var remaining = table.rows[...]
                var currentSpacing = spacing
                // Page neuve ouverte pour ce tableau : la première ligne y entre même trop haute.
                var freshPage = false
                while !remaining.isEmpty {
                    var room = capacity - used - currentSpacing - metrics.tableHeaderHeight
                    var slice: [ReportRow] = []
                    while let row = remaining.first {
                        let rowHeight = metrics.rowHeight(row, in: table)
                        if rowHeight > room && !(slice.isEmpty && freshPage) { break }
                        slice.append(row)
                        room -= rowHeight
                        remaining = remaining.dropFirst()
                    }
                    // Pas de ligne veuve : un tableau qui ne tient pas en entier ne commence pas en bas
                    // de page avec moins de trois lignes (sur une page déjà entamée).
                    let minimumRows = min(3, table.rows.count)
                    if !freshPage, !remaining.isEmpty, !slice.isEmpty, slice.count < minimumRows,
                       items.count > 1 || !(items.first.map(Self.isHeading) ?? false) {
                        remaining = table.rows[...]
                        slice = []
                    }
                    if slice.isEmpty {
                        newPage()
                        items.append(.heading(section.heading, continued: true))
                        used = metrics.headingHeight
                        currentSpacing = 0
                        freshPage = true
                        continue
                    }
                    var part = table
                    part.rows = slice
                    used += currentSpacing + metrics.height(of: .table(part))
                    items.append(.block(.table(part)))
                    if !remaining.isEmpty {
                        newPage()
                        items.append(.heading(section.heading, continued: true))
                        used = metrics.headingHeight
                        currentSpacing = 0
                        freshPage = true
                    }
                }
            }
        }
        if !items.isEmpty || pages.isEmpty { newPage() }
        if document.signature, let last = pages.last {
            if last.used + metrics.sectionGap + metrics.signatureHeight <= capacity || last.items.isEmpty {
                pages[pages.count - 1].hasSignature = true
            } else {
                // Pas de page de signature seule : les dernières lignes du tableau final l'accompagnent.
                pages.append(signaturePage(after: &pages[pages.count - 1], number: pages.count + 1, metrics: metrics))
            }
        }
        return pages
    }

    /// Page finale portant la signature, jamais seule : si la page précédente finit par un tableau,
    /// ses deux dernières lignes passent sur la nouvelle page (titre « (suite) ») ; si elle finit par
    /// un texte brut, ses trois dernières lignes ; sinon, son dernier bloc (avec son titre s'il
    /// resterait seul en bas de page).
    static func signaturePage(after previous: inout ReportPage, number: Int, metrics: ReportPageMetrics) -> ReportPage {
        var page = ReportPage(number: number, items: [], sections: [], used: 0, hasSignature: true)
        guard let heading = previous.items.reversed().compactMap({ item -> String? in
            if case .heading(let title, _) = item { return title }
            return nil
        }).first, let last = previous.items.last else { return page }
        let lastIndex = previous.items.count - 1
        switch last {
        case .block(.table(var table)) where table.rows.count >= 3:
            let moved = Array(table.rows.suffix(2))
            let movedHeight = moved.map { metrics.rowHeight($0, in: table) }.reduce(0, +)
            table.rows.removeLast(2)
            previous.items[lastIndex] = .block(.table(table))
            previous.used -= movedHeight
            var part = table
            part.rows = moved
            page.items = [.heading(heading, continued: true), .block(.table(part))]
            page.used = metrics.headingHeight + metrics.height(of: .table(part))
        case .block(.code(var lines)) where lines.count >= 4:
            let moved = Array(lines.suffix(3))
            lines.removeLast(3)
            previous.items[lastIndex] = .block(.code(lines))
            previous.used -= Double(moved.count) * metrics.codeLineHeight
            page.items = [.heading(heading, continued: true), .block(.code(moved))]
            page.used = metrics.headingHeight + metrics.height(of: .code(moved))
        case .block(let block):
            // La page précédente doit garder au moins un titre et un bloc.
            guard previous.items.count >= 3 else { return page }
            previous.items.removeLast()
            previous.used -= metrics.height(of: block) + metrics.blockGap
            var moved: [ReportPageItem] = [.block(block)]
            if case .heading(let title, let continued)? = previous.items.last, previous.items.count >= 3 {
                // Titre qui resterait seul en bas de page : il part avec son bloc.
                previous.items.removeLast()
                previous.used -= metrics.headingHeight + metrics.sectionGap
                moved.insert(.heading(title, continued: continued), at: 0)
                if !continued, let kind = previous.sections.popLast() { page.sections = [kind] }
            } else {
                moved.insert(.heading(heading, continued: true), at: 0)
            }
            page.items = moved
            page.used = metrics.headingHeight + metrics.height(of: block)
        case .heading:
            break
        }
        return page
    }

    static func isHeading(_ item: ReportPageItem) -> Bool {
        if case .heading = item { return true }
        return false
    }

    /// Hauteur minimale d'un bloc pour qu'il commence sur une page (en-tête et trois lignes d'un tableau).
    static func minimumHeight(_ block: ReportBlock, _ metrics: ReportPageMetrics) -> Double {
        if case .table(let table) = block, !table.rows.isEmpty {
            return metrics.tableHeaderHeight + table.rows.prefix(3).map { metrics.rowHeight($0, in: table) }.reduce(0, +)
        }
        if case .code(let lines) = block {
            return metrics.codePadding + Double(min(3, lines.count)) * metrics.codeLineHeight
        }
        return metrics.height(of: block)
    }

    /// Page où commence chaque section (« p. 1 »).
    public static func startPages(_ pages: [ReportPage]) -> [ReportSectionKind: Int] {
        var result: [ReportSectionKind: Int] = [:]
        for page in pages { for kind in page.sections where result[kind] == nil { result[kind] = page.number } }
        return result
    }
}
