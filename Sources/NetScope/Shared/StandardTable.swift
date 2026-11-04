import AppKit
import NetScopeCore
import SwiftUI

// MARK: - Tableau standard (note 8)
//
// Un seul modèle de tableau dans toute l'application : tri en cliquant sur l'en-tête (flèche),
// colonnes qu'on élargit, déplace, masque ou ajoute, et tout cela retenu PAR TABLEAU d'un lancement
// à l'autre (UserDefaults, clés « tableau.<id>.colonnes » et « tableau.<id>.tri »). En démonstration
// et pendant les captures, rien n'est lu ni écrit : les captures restent identiques.
//
// ADOPTER LE COMPOSANT DANS UN ÉCRAN (exemple complet : Screens/Scanner/ScanResultsPanel.swift)
//
// 1. Décrire les colonnes et les clés de tri, une fois (souvent en `static` dans le fichier de l'écran) :
//
//        static let columns: [StandardColumn] = [
//            StandardColumn(id: "ip", title: "IP", isRequired: true),            // jamais masquable
//            StandardColumn(id: "nom", title: "Nom"),                             // visible par défaut
//            StandardColumn(id: "premiereVue", title: "Première vue", isDefaultVisible: false),
//        ]
//        static let sortKeys: [String: KeyPathComparator<Row>] = [
//            "ip": KeyPathComparator(\Row.ip),
//            "nom": KeyPathComparator(\Row.sortName),   // clés String/Int/Date… : toujours Comparable
//            "premiereVue": KeyPathComparator(\Row.firstSeen),
//        ]
//
// 2. Garder le modèle dans l'écran qui possède le tableau (il vit tant que l'écran est affiché) :
//
//        @StateObject private var table = StandardTableModel<Row>(id: "inventaire", columns: Self.columns,
//                                                                 sortKeys: Self.sortKeys, defaultSort: "ip")
//
// 3. Construire le `Table` avec `sortOrder` et `columnCustomization` du modèle ; chaque colonne
//    trie avec `sortUsing: table.sort("id")` (pas `value:`, pour que le tri retenu retrouve sa
//    colonne) et porte `.customizationID("id")` ; les facultatives ajoutent `.defaultVisibility(.hidden)`,
//    les obligatoires `.disabledCustomizationBehavior(.visibility)`. Plus de dix colonnes : les
//    regrouper dans des `Group { … }`.
//
//        Table(rows, selection: $selection, sortOrder: $table.sortOrder,
//              columnCustomization: $table.customization) {
//            TableColumn("IP", sortUsing: table.sort("ip")) { row in … }
//                .customizationID("ip").disabledCustomizationBehavior(.visibility)
//            TableColumn("Première vue", sortUsing: table.sort("premiereVue")) { row in … }
//                .customizationID("premiereVue").defaultVisibility(.hidden)
//        }
//        .standardTableStyle()
//
//    Trier les lignes avec `rows.sorted(using: table.sortOrder)`.
//
// 4. Placer `StandardColumnsMenu(model: table)` dans la barre de l'écran (ou du panneau) : mêmes
//    cases à cocher que le clic droit sur l'en-tête, plus « Rétablir les colonnes par défaut ».
//
// 5. Une liste dans une cellule (ports, étiquettes, adresses) : `StandardTagList(tags: […])`
//    affiche autant d'étiquettes que la largeur le permet, puis « +N », liste complète en infobulle.
//    Couleurs propres à chaque étiquette : `colors: { tag in (texte, fond) }`.
//
// 6. Tableau dans une page qui défile déjà : `.standardTableHeight(rows:rowHeight:maxRows:)` donne
//    la hauteur (en-tête + lignes, plafonnée) et coupe le défilement interne quand tout tient.
//    Panneau étroit : en-têtes `StandardTableHeading("TITRE")` (11 pt, comme les croquis) et
//    `StandardColumnsMenu(model:, compact: true)` (icône seule).
//
// Tri par défaut décroissant (dates, signal) : `defaultAscending: false`. Menu de tri hors de
// l'en-tête : `table.currentSort` et `table.setSort(_:ascending:)`.
//
// Une nouvelle donnée = une nouvelle colonne facultative (`isDefaultVisible: false`) : elle apparaît
// dans les deux menus sans rien changer ailleurs.
//
// Plusieurs sites (0.12.0) : colonne facultative `StandardColumn.site` (« Site »), que l'écran
// affiche d'office quand il montre plus d'un site : `.standardSiteColumn(table, multiple:)`.

/// Colonne d'un tableau standard, pour le menu « Colonnes ».
struct StandardColumn: Identifiable, Hashable {
    /// Identifiant stable (`.customizationID`) : ne jamais le changer, il est enregistré.
    let id: String
    /// Titre lisible dans le menu (« Première vue »).
    let title: String
    var isDefaultVisible = true
    /// Colonne qu'on ne peut pas masquer (ex. l'adresse IP).
    var isRequired = false
}

/// État d'un tableau standard : colonnes (visibilité, ordre, largeurs) et tri, enregistrés par tableau.
@MainActor
final class StandardTableModel<Row: Identifiable>: ObservableObject {
    let id: String
    let columns: [StandardColumn]

    @Published var customization: TableColumnCustomization<Row> {
        didSet { if !automaticChange { saveCustomization() } }
    }
    /// Changement fait par l'écran (`setAutomaticVisibility`), pas par l'utilisateur : non enregistré.
    private var automaticChange = false
    @Published var sortOrder: [KeyPathComparator<Row>] {
        didSet { saveSort() }
    }

    private let sortKeys: [String: KeyPathComparator<Row>]
    private let defaultSort: [KeyPathComparator<Row>]
    private let defaults: UserDefaults?

    /// Tri enregistré : la colonne et le sens.
    private struct SavedSort: Codable {
        var column: String
        var ascending: Bool
    }

    /// - `defaultSort` : identifiant de la colonne triée au premier lancement.
    /// - `defaultAscending` : sens de ce tri (false : décroissant, ex. dates récentes ou signal fort en haut) ;
    ///   nil garde le sens de la clé dans `sortKeys` (croissant, sauf clé déclarée `order: .reverse`).
    init(id: String, columns: [StandardColumn], sortKeys: [String: KeyPathComparator<Row>], defaultSort: String,
         defaultAscending: Bool? = nil, defaults: UserDefaults? = StandardTableStorage.defaults) {
        self.id = id
        self.columns = columns
        self.sortKeys = sortKeys
        self.defaults = defaults
        let fallback = sortKeys[defaultSort].map { comparator -> [KeyPathComparator<Row>] in
            var comparator = comparator
            if let defaultAscending { comparator.order = defaultAscending ? .forward : .reverse }
            return [comparator]
        } ?? []
        self.defaultSort = fallback
        customization = Self.loadCustomization(defaults, key: "tableau.\(id).colonnes")
        sortOrder = Self.loadSort(defaults, key: "tableau.\(id).tri", keys: sortKeys) ?? fallback
    }

    /// Comparateur d'une colonne, pour `TableColumn(_:sortUsing:)`.
    func sort(_ column: String) -> KeyPathComparator<Row> {
        guard let comparator = sortKeys[column] else {
            assertionFailure("Clé de tri inconnue « \(column) » dans le tableau « \(id) »")
            return defaultSort.first ?? KeyPathComparator(\Row.id.hashValue)
        }
        return comparator
    }

    // MARK: Tri en vigueur

    /// Colonne et sens du tri en vigueur (nil : aucun tri ou clé inconnue).
    var currentSort: (column: String, ascending: Bool)? {
        guard let first = sortOrder.first, let column = columnID(of: first) else { return nil }
        return (column, first.order == .forward)
    }

    /// Trie par une colonne, dans le sens voulu (même effet qu'un clic sur l'en-tête).
    func setSort(_ column: String, ascending: Bool) {
        guard var comparator = sortKeys[column] else { return }
        comparator.order = ascending ? .forward : .reverse
        sortOrder = [comparator]
    }

    private func columnID(of comparator: KeyPathComparator<Row>) -> String? {
        sortKeys.first(where: { $0.value.keyPath == comparator.keyPath })?.key
    }

    // MARK: Colonnes visibles

    func isVisible(_ column: StandardColumn) -> Bool {
        switch customization[visibility: column.id] {
        case .visible: return true
        case .hidden: return false
        default: return column.isDefaultVisible
        }
    }

    func setVisible(_ visible: Bool, _ column: StandardColumn) {
        guard !column.isRequired else { return }
        customization[visibility: column.id] = visible ? .visible : .hidden
    }

    /// Colonne affichée ou masquée par l'écran lui-même, sans enregistrer ce choix : ex. la colonne
    /// facultative « Site », affichée automatiquement quand le tableau montre plusieurs sites.
    func setAutomaticVisibility(_ visible: Bool, _ id: String) {
        let current = customization[visibility: id] == .visible
        guard current != visible else { return }
        automaticChange = true
        customization[visibility: id] = visible ? .visible : .hidden
        automaticChange = false
    }

    /// Colonnes, largeurs, ordre et tri d'origine.
    func reset() {
        customization = TableColumnCustomization()
        sortOrder = defaultSort
    }

    var isDefault: Bool {
        columns.allSatisfy { isVisible($0) == $0.isDefaultVisible }
    }

    // MARK: Enregistrement (lecture tolérante : un état illisible redonne les colonnes par défaut)

    private static func loadCustomization(_ defaults: UserDefaults?, key: String) -> TableColumnCustomization<Row> {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data) else {
            return TableColumnCustomization()
        }
        return decoded
    }

    private static func loadSort(_ defaults: UserDefaults?, key: String,
                                 keys: [String: KeyPathComparator<Row>]) -> [KeyPathComparator<Row>]? {
        guard let data = defaults?.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedSort.self, from: data),
              var comparator = keys[saved.column] else { return nil }
        comparator.order = saved.ascending ? .forward : .reverse
        return [comparator]
    }

    private func saveCustomization() {
        guard let defaults, let data = try? JSONEncoder().encode(customization) else { return }
        defaults.set(data, forKey: "tableau.\(id).colonnes")
    }

    private func saveSort() {
        guard let defaults else { return }
        let key = "tableau.\(id).tri"
        guard let first = sortOrder.first,
              let column = columnID(of: first),
              let data = try? JSONEncoder().encode(SavedSort(column: column, ascending: first.order == .forward)) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

extension StandardColumn {
    /// Colonne facultative « Site » des tableaux à plusieurs sites (identifiant « site »).
    static let site = StandardColumn(id: "site", title: "Site", isDefaultVisible: false)
}

extension View {
    /// Affiche la colonne « Site » quand le tableau montre plusieurs sites, la masque sinon.
    func standardSiteColumn<Row: Identifiable>(_ table: StandardTableModel<Row>, multiple: Bool) -> some View {
        onAppear { table.setAutomaticVisibility(multiple, StandardColumn.site.id) }
            .onChange(of: multiple) { _, value in table.setAutomaticVisibility(value, StandardColumn.site.id) }
    }
}

/// Où les tableaux enregistrent leur état : nulle part en démonstration ou en capture.
enum StandardTableStorage {
    static var defaults: UserDefaults? {
        let arguments = CommandLine.arguments
        return arguments.contains("--demo") || arguments.contains("--snapshot") ? nil : .standard
    }
}

extension View {
    /// Apparence commune des tableaux standard (sans bandes alternées, comme les croquis).
    func standardTableStyle() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    /// Hauteur d'un tableau standard placé dans une page qui défile déjà : en-tête plus `rows`
    /// lignes, au plus `maxRows` (au-delà, le tableau défile seul) ; quand tout tient, le
    /// défilement interne est coupé pour que la molette fasse défiler la page.
    /// - `extra` : marge ajoutée (ex. barre de défilement horizontale).
    func standardTableHeight(rows: Int, rowHeight: CGFloat, maxRows: Int = .max,
                             headerHeight: CGFloat = StandardTableMetrics.headerHeight,
                             extra: CGFloat = 0) -> some View {
        frame(height: StandardTableMetrics.height(rows: rows, rowHeight: rowHeight, maxRows: maxRows,
                                                  headerHeight: headerHeight, extra: extra))
            .scrollDisabled(rows <= maxRows)
    }
}

/// Mesures communes des tableaux standard.
enum StandardTableMetrics {
    /// Hauteur de l'en-tête d'un `Table` (style `.inset`).
    static let headerHeight: CGFloat = 36

    static func height(rows: Int, rowHeight: CGFloat, maxRows: Int = .max,
                       headerHeight: CGFloat = headerHeight, extra: CGFloat = 0) -> CGFloat {
        headerHeight + CGFloat(min(max(rows, 0), maxRows)) * rowHeight + extra
    }
}

/// Titre de colonne compact (11 pt demi-gras, à écrire en majuscules), comme les en-têtes des
/// croquis : pour les tableaux des panneaux étroits, où l'en-tête 13 pt par défaut tronquerait.
/// S'emploie ainsi : `TableColumn(StandardTableHeading("ACTIF"), sortUsing: …)`.
func StandardTableHeading(_ title: String) -> Text {
    Text(title).font(.system(size: 11, weight: .semibold)).kerning(0.3)
}

// MARK: - Menu « Colonnes »

/// Bouton « Colonnes » : une case par colonne (mêmes réglages que le clic droit sur l'en-tête)
/// et « Rétablir les colonnes par défaut ».
struct StandardColumnsMenu<Row: Identifiable>: View {
    @ObservedObject var model: StandardTableModel<Row>
    var title = "Colonnes"
    /// Icône seule, sans flèche de menu : pour un en-tête de panneau déjà plein.
    var compact = false

    var body: some View {
        Menu {
            Section("Colonnes affichées") {
                ForEach(model.columns) { column in
                    Toggle(column.title, isOn: Binding(get: { model.isVisible(column) },
                                                       set: { model.setVisible($0, column) }))
                        .disabled(column.isRequired)
                }
            }
            Divider()
            Button("Rétablir les colonnes par défaut") { model.reset() }
        } label: {
            if compact {
                Label(title, systemImage: "tablecells").labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "tablecells")
            }
        }
        .menuStyle(.button)
        .menuIndicator(compact ? .hidden : .automatic)
        .accessibilityLabel(title)
        .font(Theme.small)
        .fixedSize()
        .help("Choisir les colonnes du tableau (aussi au clic droit sur l’en-tête)")
    }
}

// MARK: - Liste adaptative dans une cellule

/// Étiquettes dans une cellule : autant que la largeur le permet, puis « +N » ; la liste complète
/// est en infobulle. Plus la colonne est large, plus on en voit.
struct StandardTagList: View {
    let tags: [String]
    /// Étiquettes mises en avant (bleu), ex. ports web.
    var highlighted: (String) -> Bool = { _ in false }
    /// Couleurs propres à une étiquette (texte, fond), ex. « Critique » en rouge ; nil : couleurs
    /// ordinaires (ou bleu si `highlighted`).
    var colors: ((String) -> (Color, Color)?)?
    /// Texte de l'infobulle ; par défaut, la liste séparée par des virgules.
    var help: String?
    /// Texte quand la liste est vide.
    var empty = "—"

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let spacing: CGFloat = 3
    private static let padding: CGFloat = 5

    var body: some View {
        if tags.isEmpty {
            Text(empty).font(Theme.small).foregroundStyle(Theme.textTertiary)
        } else {
            GeometryReader { proxy in
                let shown = Self.visibleCount(tags, width: proxy.size.width)
                HStack(spacing: Self.spacing) {
                    ForEach(Array(tags.prefix(shown).enumerated()), id: \.offset) { _, tag in
                        tagView(tag)
                    }
                    if shown < tags.count {
                        Text("+\(tags.count - shown)")
                            .font(Font(Self.font))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 20)
            .help(help ?? tags.joined(separator: ", "))
        }
    }

    private func tagView(_ tag: String) -> some View {
        let strong = highlighted(tag)
        let (foreground, background) = colors?(tag)
            ?? (strong ? (Theme.accentStrong, Theme.accentSoft) : (Theme.neutralText, Theme.neutralSoft))
        return Text(tag)
            .font(Font(Self.font))
            .foregroundStyle(foreground)
            .padding(.horizontal, Self.padding)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
            .fixedSize()
    }

    /// Nombre d'étiquettes qui tiennent dans `width` (calcul pur : NetScopeCore.TagOverflow).
    static func visibleCount(_ tags: [String], width: CGFloat) -> Int {
        let widths = tags.map { Double(textWidth($0) + padding * 2) }
        return TagOverflow.visibleCount(widths: widths, available: Double(width), spacing: Double(spacing)) { hidden in
            Double(textWidth("+\(hidden)"))
        }
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
