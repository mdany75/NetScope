import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

// Note 10 : fiche matériel (garantie) et pièces jointes, dans le détail d'une fiche de l'Inventaire.

/// Pastille d'état de la garantie (« Garantie bientôt échue (dans 24 j) »).
struct InvWarrantyPill: View {
    let state: InvWarrantyState
    var short = false

    var body: some View {
        let colors = Self.colors(state)
        InvPill(text: short ? Self.shortLabel(state) : state.label, foreground: colors.0, background: colors.1, size: short ? 10 : 11)
            .help(state.label)
    }

    static func colors(_ state: InvWarrantyState) -> (Color, Color) {
        switch state {
        case .expiringSoon: return (Theme.warning, Theme.warningSoft)
        case .expired: return (Theme.critical, Theme.criticalSoft)
        case .active: return (Theme.success, Theme.successSoft)
        case .unknown: return (Theme.textSecondary, Theme.neutralSoft)
        }
    }

    /// « 24 j », « Échue », « OK ».
    static func shortLabel(_ state: InvWarrantyState) -> String {
        switch state {
        case .expiringSoon(let days): return days == 0 ? "Aujourd’hui" : "Dans \(days)\u{00A0}j"
        case .expired: return "Échue"
        case .active: return "Active"
        case .unknown: return "—"
        }
    }
}

/// Date facultative : « Ajouter » tant qu'elle est vide, puis le champ de date natif et « ✕ ».
struct InvOptionalDateField: View {
    let label: String
    @Binding var date: Date?
    /// Date proposée au premier clic.
    var suggestion: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 4) {
                if let value = date {
                    DatePicker(label, selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .environment(\.locale, Locale(identifier: "fr_CA"))
                    Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Effacer la date")
                        .accessibilityLabel("Effacer \(label.lowercased())")
                } else {
                    Button("Ajouter une date") { date = Calendar.current.startOfDay(for: suggestion) }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 22)
        }
    }
}

/// Champs « Matériel et garantie » d'une fiche (brouillon de la fiche : enregistrés avec elle).
struct InvWarrantyFields: View {
    @Binding var hardware: InvHardware
    let now: Date
    @State private var priceText = ""
    @State private var editingPrice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Matériel et garantie").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                let state = hardware.warranty(now: now)
                if state != .unknown { InvWarrantyPill(state: state, short: false) }
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    InvOptionalDateField(label: "Date d’achat", date: $hardware.purchaseDate, suggestion: now)
                    InvOptionalDateField(label: "Fin de garantie", date: $hardware.warrantyEnd,
                                         suggestion: Calendar.current.date(byAdding: .year, value: 3, to: hardware.purchaseDate ?? now) ?? now)
                }
                GridRow {
                    InvField(label: "Fournisseur", text: $hardware.supplier, placeholder: "Ex. CDW Canada")
                    InvField(label: "N° de série", text: $hardware.serialNumber, placeholder: "Ex. E78123K4N")
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prix (facultatif)").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                        TextField("Prix", text: Binding(get: {
                            editingPrice ? priceText : (hardware.price.map(InvHardware.priceLabel) ?? "")
                        }, set: { value in
                            editingPrice = true
                            priceText = value
                            hardware.price = InvHardware.parsePrice(value)
                        }), prompt: Text("Ex. 1 249,99\u{00A0}$"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { editingPrice = false }
                    }
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
}

/// Pièces jointes d'une fiche : liste, Ouvrir, Retirer, Ajouter (ou glisser des fichiers).
struct InvAttachmentsPanel: View {
    @ObservedObject private var model = InvModel.shared
    let record: InvRecord
    let siteKey: String
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        let list = record.attachmentList.sorted { $0.added > $1.added }
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Pièces jointes",
                              subtitle: list.isEmpty ? "Factures, contrats, photos…" : "\(list.count) fichier\(list.count > 1 ? "s" : "")")
                if list.isEmpty {
                    Text("Aucune pièce jointe. Glissez des fichiers ici ou choisissez «\u{00A0}Ajouter…\u{00A0}»\u{00A0}: ils sont copiés dans le dossier de l’appareil (Application Support/NetScope/Inventaire).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(list) { attachment in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (attachment.fileName as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.fileName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text("\(attachment.sizeLabel) · ajoutée le \(InvFormat.day(attachment.added))")
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Button("Ouvrir") { model.open(attachment, of: record, site: siteKey) }
                            .controlSize(.small)
                        Button { model.removeAttachment(attachment, of: record, site: siteKey) } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .help("Retirer la pièce jointe (le fichier va dans la corbeille)")
                        .accessibilityLabel("Retirer \(attachment.fileName)")
                    }
                    .padding(.vertical, 2)
                }
                ActionRow {
                    if !list.isEmpty, !model.isEphemeral {
                        Button("Afficher dans le Finder") { model.revealAttachments(of: record, site: siteKey) }
                            .buttonStyle(.secondary)
                    }
                    Button { importing = true } label: { Label("Ajouter…", systemImage: "paperclip") }
                        .buttonStyle(.secondary)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.accent, lineWidth: targeted ? 2 : 0))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.attach(files, to: record.key, site: siteKey)
            return true
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.attach(urls, to: record.key, site: siteKey) }
        }
    }
}
