import NetScopeCore
import SwiftUI

/// Colonne de configuration (croquis Rapport.dc.html, « aside ») : modèle, client, site,
/// technicien, date et logo ; sections à cocher ; format de sortie et actions ; rapports récents.
struct RapportConfigPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RapportModel
    /// Page de début de chaque section, d'après la pagination de l'aperçu.
    let startPages: [ReportSectionKind: Int]
    let totalPages: Int
    @State private var calendarOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            templatePanel
            sectionsPanel
            outputPanel
            recentsPanel
        }
    }

    // MARK: Modèle et identification

    private var templatePanel: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Modèle") {
                    if !model.library.templates.isEmpty {
                        Menu {
                            ForEach(model.library.templates) { saved in
                                Button(saved.name) { model.apply(saved) }
                            }
                        } label: {
                            Text("Mes modèles").font(.system(size: 12, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.bottom, 10)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(ReportTemplate.allCases) { template in
                        templateButton(template)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    field("Client", text: $model.config.client, placeholder: ReportText.missing)
                    field("Site", text: $model.config.site, placeholder: "Siège")
                    field("Technicien", text: $model.config.technician, placeholder: ReportText.missing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Date").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 4) {
                            TextField("", text: $model.config.date, prompt: Text("AAAA-MM-JJ").foregroundStyle(Theme.textTertiary))
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundStyle(Theme.text)
                            Button { calendarOpen = true } label: {
                                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Choisir la date")
                            .popover(isPresented: $calendarOpen, arrowEdge: .bottom) {
                                DatePicker("", selection: Binding(get: { model.dateValue }, set: { model.dateValue = $0 }),
                                           displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.graphical)
                                    .environment(\.locale, Locale(identifier: "fr_CA"))
                                    .padding(10)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                            .strokeBorder(ReportText.longDate(model.config.date) == nil ? Theme.critical : Theme.border))
                    }
                }
                .padding(.top, 12)
                HStack(spacing: 10) {
                    RapportLogoBox(logo: model.logo, width: 112, height: 44, fontSize: 11, radius: 6, filled: true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Button { model.chooseLogo() } label: {
                                Label("Choisir le logo…", systemImage: "photo")
                            }
                            .buttonStyle(RapportSmallButtonStyle())
                            if model.logo != nil {
                                Button { model.removeLogo() } label: { Image(systemName: "xmark") }
                                    .buttonStyle(RapportSmallButtonStyle())
                                    .help("Retirer le logo")
                            }
                        }
                        Text("PNG ou SVG, 600\u{00A0}×\u{00A0}200\u{00A0}px conseillé")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func templateButton(_ template: ReportTemplate) -> some View {
        let on = model.config.template == template
        return Button { model.pick(template) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.label)
                    .font(.system(size: 12, weight: on ? .bold : .semibold))
                    .foregroundStyle(on ? Theme.accentStrong : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(template.summary)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(on ? Theme.accentSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(on ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        }
    }

    // MARK: Sections

    private var sectionsPanel: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader("Sections")
                    Spacer()
                    Text("\(model.config.sections.count) sur \(ReportSectionKind.allCases.count) · \(totalPages) page\(totalPages > 1 ? "s" : "")")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                }
                .padding(.bottom, 6)
                ForEach(ReportSectionKind.allCases) { kind in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { model.config.includes(kind) }, set: { _ in model.toggle(kind) })) {
                            Text(kind.label).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 4)
                        if let start = startPages[kind] {
                            Text("p. \(start)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 28)
                }
                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 8).padding(.bottom, 4)
                Toggle(isOn: $model.config.maskMAC) { Text("Masquer les adresses MAC").font(Theme.body) }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 4)
                    .frame(height: 26)
                Toggle(isOn: $model.config.signature) { Text("Bloc de signature").font(Theme.body) }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 4)
                    .frame(height: 26)
            }
        }
    }

    // MARK: Format et actions

    private var outputPanel: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Format de sortie").padding(.bottom, 8)
                HStack(spacing: 4) {
                    ForEach(ReportFormat.allCases) { format in
                        let on = model.config.format == format
                        Button { model.config.format = format } label: {
                            Text(format.label)
                                .font(Theme.mono(11, weight: .semibold))
                                .foregroundStyle(on ? Theme.accentStrong : Theme.neutralText)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(on ? Theme.accentSoft : Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(on ? Theme.accent : Theme.border))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(model.config.format.hint)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)

                VStack(spacing: 6) {
                    Button { model.generate(state: state) } label: {
                        Label(model.config.format.actionLabel, systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accent))
                            .foregroundStyle(.white)
                            .font(Theme.bodyMedium)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 6) {
                        Button { model.emailOpen.toggle() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "envelope").font(.system(size: 11))
                                Text("Envoyer par courriel").minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RapportSmallButtonStyle(height: 32, fill: true, compact: true))
                        Button { model.saveTemplate() } label: {
                            // Sans icône : le libellé du croquis tient en entier dans la demi-colonne.
                            Text("Enregistrer comme modèle")
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RapportSmallButtonStyle(height: 32, fill: true, compact: true))
                    }
                    if model.emailOpen { emailPanel }
                    if let toast = model.toast {
                        HStack(alignment: .top, spacing: 6) {
                            Text(toast).font(Theme.small).foregroundStyle(Theme.success)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if model.lastFile != nil && toast.hasPrefix("Rapport généré") {
                                Button("Afficher") { model.revealLastFile() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.success)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private var emailPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Destinataire", text: $model.emailTo, placeholder: ReportText.missing)
            (Text("Objet\u{00A0}: ").foregroundColor(Theme.textSecondary) + Text(model.emailSubject).foregroundColor(Theme.text))
                .font(Theme.small)
            (Text("Pièce jointe\u{00A0}: ").foregroundColor(Theme.textSecondary)
                + Text(model.config.fileName(for: .pdf)).font(Theme.mono(12)).foregroundColor(Theme.text))
                .font(Theme.small)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Préparer le brouillon dans Mail") { model.emailDraft(state: state) }
                .buttonStyle(RapportSmallButtonStyle())
            Text("Rien n’est envoyé\u{00A0}: le brouillon s’ouvre dans Mail pour relecture.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    // MARK: Rapports récents

    private var recentsPanel: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Rapports récents").padding(.bottom, 6)
                let recents = Array(model.recents.prefix(5))
                if recents.isEmpty {
                    Text("Aucun rapport produit pour l’instant.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 6)
                }
                ForEach(recents) { recent in
                    HStack(spacing: 10) {
                        Text(recent.format.label)
                            .font(Theme.mono(10, weight: .bold))
                            .foregroundStyle(formatColor(recent.format).0)
                            .frame(width: 40, height: 24)
                            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(formatColor(recent.format).1))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(recent.title).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
                            Text(recent.meta).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { model.open(recent) } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 13))
                        }
                        .buttonStyle(RapportSmallButtonStyle(width: 28))
                        .help("Ouvrir \(recent.title)")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                }
            }
        }
    }

    private func formatColor(_ format: ReportFormat) -> (Color, Color) {
        switch format {
        case .pdf: return (Theme.critical, Theme.criticalSoft)
        case .html: return (Theme.accentStrong, Color(light: 0xDBEAFE, dark: 0x1B3250))
        case .csv, .json: return (Theme.success, Theme.successSoft)
        }
    }
}

/// Petit bouton secondaire (28 pt, 12 pt de texte), comme « Choisir le logo… » du croquis.
struct RapportSmallButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var width: CGFloat?
    var fill = false
    /// Marges réduites (8 pt) : deux boutons côte à côte dans la colonne.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, width == nil ? (compact ? 4 : 10) : 0)
            .frame(width: width, height: height)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.panelMuted : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(configuration.isPressed ? Theme.borderStrong : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}
