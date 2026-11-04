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
                .foregroundStyle(tint == .critical ? Color(light: 0x991B1B, dark: 0xED9797) : Theme.textSecondary)
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: valueSize, weight: .semibold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.small)
                    .foregroundStyle(tint == .critical ? Color(light: 0x7F1D1D, dark: 0xE89B9B) : Theme.textSecondary)
                    // Petite fenêtre : trois lignes plutôt qu'un sous-titre coupé.
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(tint == .critical ? Theme.criticalSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius)
            .strokeBorder(tint == .critical ? Color(light: 0xFCA5A5, dark: 0x822B2B) : Theme.border))
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

/// Groupe de boutons exclusifs (vues sauvegardées, périodes, gravités) : contrôle segmenté natif
/// de macOS, qui suit la couleur d'accent et le mode sombre du système.
struct InvSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
    static let infoSoft = Color(light: 0xDBEAFE, dark: 0x1B3250)

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
        case .console: return "gamecontroller"
        case .domotique: return "house"
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
    /// Versions plus courtes du sous-titre, essayées dans l'ordre quand il ne tient pas (jamais une
    /// phrase coupée ; le sous-titre complet reste au survol).
    var shorterSubtitles: [String] = []
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
            if let subtitle, !shorterSubtitles.isEmpty {
                ViewThatFits(in: .horizontal) {
                    ForEach([subtitle] + shorterSubtitles, id: \.self) { Text($0).fixedSize() }
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .help(subtitle)
            } else if let subtitle {
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

/// Champ de saisie d'une fiche : intitulé 11 pt au-dessus, champ natif de macOS.
struct InvField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            TextField(label, text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
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

// MARK: - Appareils qu'on ne suit plus

/// Appareil exclu d'un site (« Ne plus suivre ces appareils »).
struct InvExcludedRow: Identifiable {
    let site: String
    let siteName: String
    let exclusion: InvExclusion
    var id: String { SiteScope.id(site: site, key: exclusion.key) }
}

/// « 2 non suivis » : liste des appareils qu'un scan ne remet plus dans l'inventaire, avec
/// « Suivre de nouveau » (le prochain scan de leur site les remettra).
struct InvExcludedButton: View {
    let rows: [InvExcludedRow]
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Label("\(rows.count) non suivi\(rows.count > 1 ? "s" : "")", systemImage: "eye.slash")
                .font(Theme.small)
        }
        .buttonStyle(.ghost)
        .fixedSize()
        .help("Appareils supprimés avec «\u{00A0}Ne plus suivre\u{00A0}»\u{00A0}: un scan ne les remet pas dans l’inventaire")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Appareils non suivis").font(Theme.bodySemibold)
                Text("Un scan ne les remet pas dans l’inventaire de leur site.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.exclusion.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text([row.siteName, row.exclusion.ip.description,
                                          row.exclusion.mac?.formatted(.upperColon) ?? "sans MAC"].joined(separator: " · "))
                                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    if row.exclusion.mac == nil {
                                        // Exclusion par adresse : elle vise l'adresse, pas un appareil précis.
                                        Text("Par adresse\u{00A0}: tout appareil vu sans MAC à \(row.exclusion.ip.description) est ignoré")
                                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button("Suivre de nouveau") {
                                    guard InvModel.shared.include(row.exclusion.key, site: row.site) else { return }
                                    InvModel.shared.show("\(row.exclusion.name) sera remis dans l’inventaire au prochain scan de «\u{00A0}\(row.siteName)\u{00A0}».")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            .padding(14)
            .frame(width: 380)
        }
    }
}
