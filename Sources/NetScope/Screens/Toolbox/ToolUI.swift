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

/// Champ de saisie aux couleurs des croquis (fond blanc, bordure grise, rouge si invalide).
struct ToolTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = true
    var invalid = false
    var height: CGFloat = 34
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(13, weight: .medium) : Theme.body)
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(invalid ? Color(hex: 0xFEF2F2) : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(invalid ? Theme.critical : Theme.border))
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

/// Puce de choix (profil, type DNS, préfixe) : SF Mono 12, bordure accent si choisie.
struct ToolChoiceChip: View {
    let label: String
    let isSelected: Bool
    var mono = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(mono ? Theme.mono(12, weight: isSelected ? .semibold : .medium) : .system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.accentStrong : Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(isSelected ? Theme.accentSoft : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(isSelected ? Theme.accent : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
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

/// Grille de cellules séparées par des filets de 1 pt, dans un cadre arrondi.
struct ToolCellGrid: View {
    let cells: [ToolCell]
    var columns = 3
    var valueSize: CGFloat = 14

    var body: some View {
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        VStack(spacing: 1) {
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
                .lineLimit(2)
            if let detail = cell.detail {
                Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.foreground)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(Theme.bodySemibold).foregroundStyle(tone.foreground) }
                Text(message)
                    .font(title == nil ? Theme.body : Theme.small)
                    .foregroundStyle(tone == .accent ? Color(hex: 0x1E3A8A) : tone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(tone.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(border))
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
        case .critical: return Color(hex: 0xFCA5A5)
        case .warning: return Color(hex: 0xFED7AA)
        case .success: return Color(hex: 0xBBF7D0)
        case .accent: return Color(hex: 0xBFDBFE)
        case .neutral: return Theme.border
        }
    }
}

extension ToolNotice where Trailing == EmptyView {
    init(tone: Tone = .critical, title: String? = nil, message: String) {
        self.init(tone: tone, title: title, message: message) { EmptyView() }
    }
}

/// Cadre de tableau (bordure, rayon 8) avec en-tête et lignes de 34 pt.
struct ToolTable<Rows: View>: View {
    let columns: [TableHeader.Column]
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(spacing: 0) {
            TableHeader(columns: columns)
            rows
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Ligne de tableau : cellules de largeur fixe ou extensible, filet en haut.
struct ToolTableRow<Content: View>: View {
    var height: CGFloat = 34
    var highlight: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(minHeight: height)
            .background(highlight ?? Color.clear)
            .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }
}

extension View {
    /// Cellule de tableau alignée sur une colonne de `TableHeader`.
    func toolCell(_ width: CGFloat?, alignment: Alignment = .leading) -> some View {
        self.lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : width, alignment: alignment)
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
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }
}
