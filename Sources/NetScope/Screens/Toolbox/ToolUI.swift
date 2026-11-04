import AppKit
import NetScopeCore
import SwiftUI

// Petits éléments communs aux outils et à la fiche appareil, d'après les croquis
// (étiquettes 11 pt en majuscules, champs de 34 pt, puces SF Mono, grilles à filets de 1 pt).

/// Étiquette de champ : 11 pt, semi-gras, majuscules, gris.
struct ToolFieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

/// Champ de saisie du système (bordure arrondie de macOS, suit le mode sombre), cadre rouge si la
/// saisie est invalide. `height` choisit la taille du contrôle : 28 pt et plus, grande taille (même
/// hauteur que les boutons `.primary` et `.secondary`) ; en dessous, taille normale.
struct ToolTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = true
    var invalid = false
    var height: CGFloat = 34
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .controlSize(height >= 28 ? .large : .regular)
            .font(mono ? Theme.mono(13, weight: .medium) : Theme.body)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
            .overlay {
                if invalid {
                    RoundedRectangle(cornerRadius: Theme.buttonRadius)
                        .strokeBorder(Theme.critical, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(placeholder)
    }
}

/// Champ avec son étiquette au-dessus.
struct ToolLabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ToolFieldLabel(label)
            content
        }
    }
}

/// Choix parmi quelques valeurs (profil, plage récente, préfixe) : bouton bascule du système, mis
/// en évidence par macOS quand il est choisi.
struct ToolChoiceChip: View {
    let label: String
    let isSelected: Bool
    var mono = true
    let action: () -> Void

    var body: some View {
        // Un clic sur le choix déjà fait le garde choisi (l'action est idempotente).
        Toggle(isOn: Binding(get: { isSelected }, set: { _ in action() })) {
            Text(label)
                .font(mono ? Theme.mono(12, weight: isSelected ? .semibold : .medium)
                           : .system(size: 12, weight: isSelected ? .semibold : .medium))
                // Le fond « choisi » de macOS est la couleur d'accent : texte blanc pour le contraste.
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.text)
        }
        .toggleStyle(.button)
        .fixedSize()
    }
}

/// Rangée de champs (étiquette au-dessus) qui passe en colonne quand la largeur manque (petite
/// fenêtre). Donner aux champs souples une largeur minimale (`frame(minWidth:)`) : c'est elle qui
/// décide du passage en colonne.
struct ToolAdaptiveRow<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: spacing) { content() }
        }
    }
}

/// Mise en page qui passe à la ligne (puces, boutons).
struct ToolFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y + (lineHeight > 0 ? 0 : 0)), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Cellule « clé / valeur / précision » d'une grille de résultats (calculateur, Whois).
struct ToolCell: Identifiable {
    var id: String { key }
    let key: String
    let value: String
    var detail: String? = nil
}

/// Grille de cellules séparées par des filets de 1 pt, dans un cadre arrondi. `columns` est le
/// nombre de colonnes au plus : la grille en retire quand une colonne ferait moins de
/// `minCellWidth` (petite fenêtre), pour que les valeurs tiennent sur une ligne.
struct ToolCellGrid: View {
    let cells: [ToolCell]
    var columns = 3
    var valueSize: CGFloat = 14
    var minCellWidth: CGFloat = 170
    /// Valeurs longues (objet d'un courriel, noms de certificat) : tronquées dans leur cellule au
    /// lieu d'imposer moins de colonnes (le texte complet reste en infobulle).
    var truncatesLongValues = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: max(columns, 1), through: 2, by: -1)), id: \.self) { count in
                grid(count).frame(minWidth: CGFloat(count) * minCellWidth)
            }
            grid(1)
        }
    }

    private func grid(_ columns: Int) -> some View {
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        return VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    ForEach(0..<columns, id: \.self) { index in
                        if index < row.count {
                            cell(row[index])
                        } else {
                            Theme.panel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func cell(_ cell: ToolCell) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ToolFieldLabel(cell.key)
            Text(cell.value)
                .font(Theme.mono(valueSize, weight: .semibold))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(truncatesLongValues ? 1 : 0.7)
                .help(cell.value)
                .frame(minWidth: truncatesLongValues ? 0 : nil, idealWidth: truncatesLongValues ? minCellWidth - 24 : nil,
                       maxWidth: truncatesLongValues ? .infinity : nil, alignment: .leading)
            if let detail = cell.detail {
                Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .frame(minWidth: truncatesLongValues ? 0 : nil, idealWidth: truncatesLongValues ? minCellWidth - 24 : nil,
                           maxWidth: truncatesLongValues ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }
}

/// Encadré d'information, d'alerte ou d'erreur.
struct ToolNotice<Trailing: View>: View {
    var tone: Tone = .critical
    var title: String? = nil
    let message: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Bouton à droite du texte s'il reste au moins 300 pt au texte, sinon dessous (petite
        // fenêtre) : le texte n'est jamais coincé dans une colonne étroite.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                symbol
                text.frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                trailing
            }
            HStack(alignment: .top, spacing: 10) {
                symbol
                VStack(alignment: .leading, spacing: 6) {
                    text
                    trailing
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(tone.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(border))
    }

    private var symbol: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .padding(.top, 1)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                // Le titre passe à la ligne plutôt que d'être coupé (feuilles étroites).
                Text(title).font(Theme.bodySemibold).foregroundStyle(tone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .font(title == nil ? Theme.body : Theme.small)
                .foregroundStyle(tone == .accent ? Color(light: 0x1E3A8A, dark: 0x9AAFE9) : tone.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch tone {
        case .critical: return "exclamationmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .success: return "checkmark.circle"
        default: return "info.circle"
        }
    }

    private var border: Color {
        switch tone {
        case .critical: return Color(light: 0xFCA5A5, dark: 0x501B1B)
        case .warning: return Color(light: 0xFED7AA, dark: 0x50371B)
        case .success: return Color(light: 0xBBF7D0, dark: 0x1B502E)
        case .accent: return Color(light: 0xBFDBFE, dark: 0x1B3350)
        case .neutral: return Theme.border
        }
    }
}

extension ToolNotice where Trailing == EmptyView {
    init(tone: Tone = .critical, title: String? = nil, message: String) {
        self.init(tone: tone, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Tableaux (tableau standard, note 8)

/// Tableaux des outils et de la fiche appareil : tableau standard (Shared/StandardTable.swift) dans
/// un cadre arrondi. L'outil défile avec la page : le tableau prend la hauteur de ses lignes (comme
/// les tableaux des croquis) et ne défile lui-même qu'au-delà de `maxRows` lignes.
///
/// Mode d'emploi : le modèle `StandardTableModel` (clé « outils.xxx » ou « appareil.xxx ») est gardé
/// par la vue qui affiche le tableau ; `Table(…)` va dans ce cadre ; `ToolColumnsMenu` se place dans
/// la barre au-dessus du tableau (ou dans l'en-tête du panneau).
struct ToolStandardTableFrame<Content: View>: View {
    let rowCount: Int
    var rowHeight: CGFloat = ToolTableMetrics.rowHeight
    var maxRows = ToolTableMetrics.maxRows
    /// Texte sous l'en-tête quand le tableau est vide.
    var emptyText: String? = nil
    /// Cadre arrondi ; false quand le tableau est déjà dans un bloc encadré (découpage en sous-réseaux).
    var bordered = true
    @ViewBuilder var content: Content

    var body: some View {
        let table = content
            .standardTableStyle()
            .frame(height: ToolTableMetrics.height(rows: rowCount, rowHeight: rowHeight, maxRows: maxRows))
            .overlay(alignment: .top) {
                if rowCount == 0, let emptyText {
                    Text(emptyText)
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: ToolTableMetrics.emptyHeight)
                        .padding(.top, ToolTableMetrics.headerHeight)
                        .allowsHitTesting(false)
                }
            }
            .background(Theme.panel)
        if bordered {
            table
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        } else {
            table
        }
    }
}

/// Mesures des tableaux standard des outils (style `.inset` de macOS).
enum ToolTableMetrics {
    /// Ligne d'une seule ligne de texte (cellule d'au plus `cellHeight`).
    static let rowHeight: CGFloat = 26
    /// Hauteur maximale du contenu d'une cellule d'une ligne (un bouton plus haut agrandirait sa ligne).
    static let cellHeight: CGFloat = 18
    /// Ligne de deux lignes de texte (Test DHCP).
    static let doubleRowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 28
    /// Hauteur de la zone « Aucun… » d'un tableau vide.
    static let emptyHeight: CGFloat = 40
    static let maxRows = 14
    /// Marges haute et basse du style `.inset`.
    static let insets: CGFloat = 16

    static func height(rows: Int, rowHeight: CGFloat = rowHeight, maxRows: Int = maxRows) -> CGFloat {
        guard rows > 0 else { return headerHeight + emptyHeight + insets }
        return headerHeight + CGFloat(min(rows, maxRows)) * rowHeight + insets
    }
}

/// Texte d'une cellule de tableau d'outil : une ligne, tronquée à la fin.
struct ToolTableText: View {
    let text: String
    var size: CGFloat = 12
    var mono = true
    var weight: Font.Weight = .regular
    var color: Color = Theme.text
    var alignment: Alignment = .leading

    init(_ text: String, size: CGFloat = 12, mono: Bool = true, weight: Font.Weight = .regular,
         color: Color = Theme.text, alignment: Alignment = .leading) {
        self.text = text
        self.size = size
        self.mono = mono
        self.weight = weight
        self.color = color
        self.alignment = alignment
    }

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(size, weight: weight) : .system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// Bouton « Colonnes » d'un tableau d'outil, en petit format (barre au-dessus du tableau).
struct ToolColumnsMenu<Row: Identifiable>: View {
    @ObservedObject var model: StandardTableModel<Row>

    var body: some View {
        StandardColumnsMenu(model: model)
            .controlSize(.small)
    }
}

/// Petite case (« Uptime », « Latence moy. ») sur fond gris clair.
struct ToolStatTile: View {
    let label: String
    let value: String
    var detail: String? = nil
    var valueColor: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.mono(14, weight: .semibold)).foregroundStyle(valueColor).lineLimit(1).minimumScaleFactor(0.75)
            if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Case à cocher compacte.
struct ToolCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Text(label).font(Theme.small).foregroundStyle(Theme.text) }
            .toggleStyle(.checkbox)
            .controlSize(.small)
    }
}

enum ToolActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ text: String) {
        // Adresse saisie par l'utilisateur : seulement http, https et ssh (pas de file://, d'applications…).
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https", "ssh"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}
