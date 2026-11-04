import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

// Petits composants communs aux écrans Inventaire, Analyse et Carte du réseau.

/// Tuile d'indicateur : intitulé, grande valeur, sous-titre (croquis : tuiles blanches, valeur 22 pt).
struct InvTile<Footer: View>: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var valueColor: Color = Theme.text
    var tint: Tone? = nil
    var valueSize: CGFloat = 22
    var action: (() -> Void)? = nil
    @ViewBuilder var footer: Footer

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.captionSemibold)
                .foregroundStyle(tint == .critical ? Color(hex: 0x991B1B) : Theme.textSecondary)
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: valueSize, weight: .semibold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.small)
                    .foregroundStyle(tint == .critical ? Color(hex: 0x7F1D1D) : Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(tint == .critical ? Theme.criticalSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius)
            .strokeBorder(tint == .critical ? Color(hex: 0xFCA5A5) : Theme.border))
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

extension InvTile where Footer == EmptyView {
    init(title: String, value: String, subtitle: String? = nil, valueColor: Color = Theme.text, tint: Tone? = nil,
         valueSize: CGFloat = 22, action: (() -> Void)? = nil) {
        self.init(title: title, value: value, subtitle: subtitle, valueColor: valueColor, tint: tint,
                  valueSize: valueSize, action: action) { EmptyView() }
    }
}

/// Groupe de boutons exclusifs (vues sauvegardées, périodes) : fond blanc, élément actif bleu pâle.
struct InvSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    /// `filled` : élément actif plein (accent, texte blanc), comme le choix de période de l'analyse.
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: filled ? .semibold : .medium))
                        .foregroundStyle(on ? (filled ? Color.white : Theme.accentStrong) : (filled ? Theme.textSecondary : Theme.text))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: filled ? 4 : 6)
                            .fill(on ? (filled ? Theme.accent : Theme.accentSoft) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(on && !filled ? Theme.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .fixedSize()
    }
}

/// Pastille arrondie (statut, étiquette).
struct InvPill: View {
    let text: String
    var foreground: Color
    var background: Color
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            .lineLimit(1)
            .fixedSize()
    }
}

enum InvStyle {
    static let infoSoft = Color(hex: 0xDBEAFE)

    static func status(_ status: InvStatus) -> (Color, Color) {
        switch status {
        case .enLigne: return (Theme.success, Theme.successSoft)
        case .horsLigne: return (Theme.textSecondary, Theme.neutralSoft)
        case .disparu: return (Theme.warning, Theme.warningSoft)
        case .conflit: return (Theme.critical, Theme.criticalSoft)
        }
    }

    static func tag(_ tag: String) -> (Color, Color) {
        switch tag {
        case "Critique", "Non autorisé": return (Theme.critical, Theme.criticalSoft)
        case "Locataire": return (Theme.warning, Theme.warningSoft)
        case "Imprimante": return (Theme.accentStrong, infoSoft)
        case "Sécurité": return (Theme.success, Theme.successSoft)
        default: return (Theme.neutralText, Theme.neutralSoft)
        }
    }

    static func severity(_ severity: InvSeverity) -> (Color, Color) {
        switch severity {
        case .critique: return (Theme.critical, Theme.criticalSoft)
        case .alerte: return (Theme.warning, Theme.warningSoft)
        case .info: return (Theme.accentStrong, infoSoft)
        }
    }

    /// Couleur de la chronologie selon le type d'événement.
    static func kind(_ kind: InvEventKind) -> (dot: Color, fg: Color, bg: Color) {
        switch kind {
        case .nouveau, .changementIP: return (Theme.accent, Theme.accentStrong, infoSoft)
        case .changementPort: return (Theme.warning, Theme.warning, Theme.warningSoft)
        case .horsLigne, .conflitIP, .dhcpNonAutorise: return (Theme.critical, Theme.critical, Theme.criticalSoft)
        case .retour: return (Theme.success, Theme.success, Theme.successSoft)
        case .fiche, .fusion, .importCSV: return (Theme.textSecondary, Theme.neutralText, Theme.neutralSoft)
        }
    }

    static func symbol(_ type: DeviceType) -> String {
        switch type {
        case .poste: return "desktopcomputer"
        case .serveur: return "server.rack"
        case .imprimante: return "printer"
        case .camera: return "video"
        case .pointAcces: return "wifi"
        case .switch: return "rectangle.connected.to.line.below"
        case .routeur: return "shield.lefthalf.filled"
        case .telephone: return "iphone"
        case .iot: return "tv"
        case .inconnu: return "questionmark.square.dashed"
        }
    }

    /// Étiquettes proposées sur une fiche (croquis), complétées par celles déjà utilisées.
    static let defaultTags = ["Critique", "Imprimante", "Locataire", "Réseau", "Poste", "Sécurité", "Affichage", "Non autorisé"]
}

/// Disposition en lignes qui passent à la ligne (puces d'étiquettes).
struct InvFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Intertitre de panneau à la manière des croquis (14 pt semi-gras, sous-titre gris).
struct InvPanelTitle<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
            if let subtitle {
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension InvPanelTitle where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Message d'état (vert) sous la barre d'outils.
struct InvToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.success)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
    }
}

/// Champ de saisie d'une fiche : intitulé 11 pt au-dessus, bordure grise, 30 pt de haut.
struct InvField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.small)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
        }
    }
}

/// Document texte CSV pour `fileExporter`.
struct InvCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // BOM UTF-8 : Excel reconnaît alors les accents.
        FileWrapper(regularFileWithContents: Data(("\u{FEFF}" + text).utf8))
    }
}

enum InvFiles {
    /// Lit un fichier choisi par l'utilisateur (UTF-8, sinon Windows-1252).
    static func readText(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
