import NetScopeCore
import SwiftUI

/// Note 56 : Réglages › Export et sauvegarde › « Configuration » : exporter toute la configuration
/// dans un seul fichier et l'importer sur un autre Mac, avec un aperçu de ce qui change.
struct RegConfigSection: View {
    @ObservedObject private var config = RegConfigController.shared

    var body: some View {
        RegPanel(title: "Configuration",
                 subtitle: "Exporter toute la configuration dans un seul fichier et l’importer sur un autre Mac, en un clic.") {
            VStack(alignment: .leading, spacing: 12) {
                snapshotSheet
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        summary
                        Spacer(minLength: 8)
                        buttons
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        summary
                        buttons
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                partsLine
                if let message = config.message {
                    RegNotice(message.text, tone: message.tone)
                }
            }
        }
        .onAppear { config.takeReport() }
        .sheet(isPresented: $config.exporting) {
            RegConfigExportSheet(contents: config.contents) { config.exporting = false }
        }
        .sheet(item: Binding(get: { config.unlockRequest.map(RegConfigFile.init) }, set: { if $0 == nil { config.unlockRequest = nil } })) { file in
            RegConfigUnlockSheet(url: file.url) { config.unlockRequest = nil }
        }
        .sheet(item: Binding(get: { config.preview.map(RegConfigPreviewItem.init) }, set: { if $0 == nil { config.cancelImport() } })) { item in
            RegConfigPreviewSheet(plan: item.plan) { config.cancelImport() }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.gearshape").font(.system(size: 17)).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fichier .\(ConfigArchive.fileExtension)").font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Chiffré par mot de passe dès qu’un jeton ou un secret est inclus (même chiffrement que les sauvegardes). L’import montre d’abord ce qui sera ajouté, remplacé ou en conflit.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: config.beginExport) { Label("Exporter la configuration…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
                .regDisabled(config.isWorking)
            Button(action: config.beginImport) {
                if config.isWorking {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Lecture…") }
                } else {
                    Label("Importer la configuration…", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.secondary)
            .regDisabled(config.isWorking)
        }
        .fixedSize()
    }

    /// Les parties, en une ligne (pastilles).
    private var partsLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            RegLabel("Parties incluses par défaut")
            RegConfigFlow(spacing: 6) {
                ForEach(config.registry.parts) { part in
                    Chip(text: part.title, tone: .neutral, systemImage: part.systemImage)
                }
            }
        }
    }

    /// Captures : NETSCOPE_CONFIG_FEUILLE=exporter|importer|motdepasse dessine la feuille dans la page.
    @ViewBuilder private var snapshotSheet: some View {
        switch ConfigSyncDemo.snapshotSheet {
        case "exporter":
            RegConfigExportSheet(contents: ConfigSyncDemo.exportContents(), inline: true, initialPassword: "Lune7-Fenetre-Rouge", dismiss: {})
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        case "importer":
            RegConfigPreviewSheet(plan: ConfigSyncDemo.importPlan(), inline: true, dismiss: {})
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        case "motdepasse":
            RegConfigUnlockSheet(url: URL(fileURLWithPath: "/Users/demo/Documents/" + ConfigArchive.suggestedName(for: Date())), inline: true, dismiss: {})
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        default:
            EmptyView()
        }
    }
}

struct RegConfigFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct RegConfigPreviewItem: Identifiable {
    let plan: ConfigImportPlan
    var id: Date { plan.package.manifest.createdAt }
}

/// Pastilles qui passent à la ligne.
struct RegConfigFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Export

/// Feuille d'export : parties cochées (toutes par défaut), mot de passe obligatoire avec un secret.
struct RegConfigExportSheet: View {
    @ObservedObject private var config = RegConfigController.shared
    let contents: [ConfigPartContents]
    var inline = false
    var initialPassword = ""
    let dismiss: () -> Void

    @State private var selected: Set<String> = []
    @State private var encryptAnyway = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var didAppear = false

    private var withSecrets: Bool { contents.contains { selected.contains($0.id) && !$0.secrets.isEmpty } }
    private var needsPassword: Bool { withSecrets || encryptAnyway }
    private var strength: BackupPasswordStrength { .evaluate(password) }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }
    private var canExport: Bool {
        !selected.isEmpty && (!needsPassword || (strength.isAcceptable && confirmation == password))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                form
            }
            .frame(maxHeight: inline ? nil : 560)
            Divider()
            footer
        }
        .frame(width: inline ? nil : 600)
        .frame(maxWidth: inline ? 680 : nil, alignment: .leading)
        .background(Theme.panel)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            selected = Set(contents.map(\.id))
            if !initialPassword.isEmpty {
                password = initialPassword
                confirmation = initialPassword
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 17)).foregroundStyle(Theme.accent)
                Text("Exporter la configuration").font(Theme.panelTitle).foregroundStyle(Theme.text)
            }
            Text("Un seul fichier, à importer sur un autre Mac. Tout est coché\u{00A0}; décochez ce que vous ne voulez pas transmettre.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                RegLabel("Parties (\(selected.count) sur \(contents.count))")
                Spacer()
                Button("Tout cocher") { selected = Set(contents.map(\.id)) }.buttonStyle(RegSmallButtonStyle())
                Button("Tout décocher") { selected = [] }.buttonStyle(RegSmallButtonStyle())
            }
            partList
            passwordArea
        }
        .padding(20)
    }

    private var partList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(contents.enumerated()), id: \.element.id) { index, part in
                Toggle(isOn: Binding(get: { selected.contains(part.id) }, set: { on in
                    if on { selected.insert(part.id) } else { selected.remove(part.id) }
                })) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: part.part.systemImage).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(part.part.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                                if !part.secrets.isEmpty {
                                    Chip(text: MonText.plural(part.secrets.count, "secret", "secrets"), tone: .accent, systemImage: "key.fill")
                                }
                            }
                            Text(part.part.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(part.summary).font(Theme.mono(11)).foregroundStyle(part.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                .help(helpText(part))
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func helpText(_ part: ConfigPartContents) -> String {
        (part.files.map { BackupEngine.label(for: $0) } + part.secrets.map(\.usage)).joined(separator: "\n")
    }

    @ViewBuilder private var passwordArea: some View {
        if withSecrets {
            RegNotice("Jetons et secrets inclus\u{00A0}: le fichier est obligatoirement chiffré (AES-GCM 256\u{00A0}bits, clé dérivée du mot de passe par PBKDF2, \(RegBackupSheetsFormat.iterations) itérations). Les secrets seront remis au Trousseau du Mac qui importe.",
                      tone: .accent)
        } else {
            Toggle(isOn: $encryptAnyway) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chiffrer par mot de passe").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text("Facultatif sans secret\u{00A0}: le fichier contient tout de même vos sites, plages et inventaires.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
        }
        if needsPassword {
            RegField(label: "Mot de passe") {
                RegTextField(placeholder: "Au moins \(BackupPasswordStrength.minimumLength) caractères (une phrase de passe convient bien)",
                             text: $password, secure: true)
            }
            RegBackupStrengthMeter(strength: strength)
            RegField(label: "Confirmation") {
                RegTextField(placeholder: "Le même mot de passe", text: $confirmation, secure: true, invalid: mismatch)
            }
            if mismatch {
                Text("Les deux mots de passe ne sont pas identiques.").font(Theme.small).foregroundStyle(Theme.critical)
            }
            Text("Sans ce mot de passe, le fichier ne peut pas être importé\u{00A0}: NetScope ne peut ni le retrouver ni le réinitialiser.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: needsPassword ? "lock.fill" : "lock.open").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(needsPassword ? "Fichier chiffré" : "Fichier non chiffré, sans aucun secret")
                .font(Theme.small).foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Annuler", action: close).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button("Exporter…") {
                let parts = selected
                let chosen = needsPassword ? password : nil
                close()
                config.export(parts: parts, password: chosen)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .regDisabled(!canExport)
            .help(exportHelp)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Pourquoi « Exporter… » est grisé (ou ce qu'il fait).
    private var exportHelp: String {
        if canExport { return "Choisir l’emplacement du fichier" }
        if selected.isEmpty { return "Cochez au moins une partie" }
        if !strength.isAcceptable { return "Mot de passe trop faible (au moins \(BackupPasswordStrength.minimumLength) caractères, variés)" }
        return "Saisissez deux fois le même mot de passe"
    }

    private func close() {
        password = ""
        confirmation = ""
        dismiss()
    }
}

// MARK: - Mot de passe d'un fichier chiffré

struct RegConfigUnlockSheet: View {
    @ObservedObject private var config = RegConfigController.shared
    let url: URL
    var inline = false
    let dismiss: () -> Void

    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open.rotation").font(.system(size: 17)).foregroundStyle(Theme.accent)
                    Text("Importer une configuration chiffrée").font(Theme.panelTitle).foregroundStyle(Theme.text)
                }
                Text("Saisissez le mot de passe choisi à l’export. Rien n’est importé avant l’aperçu.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                RegField(label: "Mot de passe") {
                    HStack(spacing: 8) {
                        RegTextField(placeholder: "Mot de passe de l’export", text: $password, secure: true, invalid: error != nil)
                            .onSubmit(unlock)
                        Button(action: unlock) {
                            if working {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Vérification…") }
                            } else {
                                Label("Ouvrir", systemImage: "key")
                            }
                        }
                        .buttonStyle(.secondary)
                        .regDisabled(password.isEmpty || working)
                    }
                }
                if let error {
                    RegNotice(error, tone: .critical)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Text(url.lastPathComponent).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Annuler") { password = ""; dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: inline ? nil : 500)
        .frame(maxWidth: inline ? 560 : nil, alignment: .leading)
        .background(Theme.panel)
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        let typed = password
        Task {
            let failure = await config.open(url, password: typed)
            working = false
            if let failure { error = failure } else { password = "" }
        }
    }
}

// MARK: - Aperçu de l'import

/// Aperçu : parties (cochées), et pour chacune ce qui sera ajouté, remplacé ou en conflit ;
/// chaque élément se décoche, un conflit n'est jamais coché d'office.
struct RegConfigPreviewSheet: View {
    @ObservedObject private var config = RegConfigController.shared
    let plan: ConfigImportPlan
    var inline = false
    let dismiss: () -> Void

    @State private var parts: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var didAppear = false

    private var manifest: ConfigManifest { plan.package.manifest }

    private var chosen: [ConfigChange] {
        plan.changes.filter { parts.contains($0.part) && selected.contains($0.id) && $0.action != .identique }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if inline {
                form
            } else {
                ScrollView { form }.frame(maxHeight: 600)
            }
            Divider()
            footer
        }
        .frame(width: inline ? nil : 680)
        .frame(maxWidth: inline ? 760 : nil, alignment: .leading)
        .background(Theme.panel)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            parts = Set(plan.parts.map(\.id))
            selected = plan.defaultSelection
            // Les parties où l'on doit décider (conflits) sont ouvertes d'office.
            expanded = Set(plan.changes.filter { $0.action == .conflit }.map(\.part))
            if inline { expanded.formUnion(["sites"]) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 17)).foregroundStyle(Theme.accent)
                Text("Importer la configuration").font(Theme.panelTitle).foregroundStyle(Theme.text)
            }
            RegTileRow {
                RegTile("Exportée", RegFormat.moment(manifest.createdAt))
                RegTile(manifest.origin == "sauvegarde" ? "Source" : "Depuis", manifest.origin == "sauvegarde" ? "Sauvegarde de NetScope" : (manifest.deviceName.isEmpty ? "Autre Mac" : manifest.deviceName))
                RegTile("Version de NetScope", manifest.appVersion, mono: true)
                RegTile("Chiffrée", manifest.encrypted ? "Oui · " + MonText.plural(manifest.secretCount, "secret", "secrets") : "Non, sans secret")
            }
            HStack(spacing: 6) {
                countChip(.ajout, tone: .success, icon: "plus.circle.fill")
                countChip(.remplacement, tone: .accent, icon: "arrow.triangle.2.circlepath")
                countChip(.conflit, tone: .warning, icon: "exclamationmark.triangle.fill")
                countChip(.identique, tone: .neutral, icon: "equal.circle")
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.parts.enumerated()), id: \.element.id) { index, part in
                    partBlock(part)
                        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            RegNotice("Avant l’import, l’état actuel est gardé dans une sauvegarde de sécurité. Les secrets vont au Trousseau de ce Mac\u{00A0}; le reste est appliqué au redémarrage de NetScope. Un élément modifié ici entre-temps n’est jamais écrasé.",
                      tone: .neutral)
        }
        .padding(20)
    }

    private func countChip(_ action: ConfigChangeAction, tone: Tone, icon: String) -> some View {
        let count = plan.changes.filter { $0.action == action && parts.contains($0.part) }.count
        let label: String
        switch action {
        case .ajout: label = count > 1 ? "ajoutés" : "ajouté"
        case .remplacement: label = count > 1 ? "remplacés" : "remplacé"
        case .conflit: label = count > 1 ? "conflits" : "conflit"
        case .identique: label = count > 1 ? "identiques" : "identique"
        }
        return Chip(text: "\(count)\u{00A0}\(label)", tone: count == 0 ? .neutral : tone, systemImage: icon)
    }

    private func partBlock(_ part: ConfigPart) -> some View {
        let changes = plan.changes(in: part.id)
        let visible = changes.filter { $0.action != .identique }
        let same = changes.count - visible.count
        let isOn = parts.contains(part.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { isOn }, set: { on in if on { parts.insert(part.id) } else { parts.remove(part.id) } })) {
                    HStack(spacing: 8) {
                        Image(systemName: part.systemImage).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
                        Text(part.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                Text(partSummary(changes)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if !visible.isEmpty {
                    Button {
                        if expanded.contains(part.id) { expanded.remove(part.id) } else { expanded.insert(part.id) }
                    } label: {
                        Image(systemName: expanded.contains(part.id) ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help(expanded.contains(part.id) ? "Masquer le détail" : "Voir le détail")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if expanded.contains(part.id), !visible.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { change in changeRow(change, enabled: isOn) }
                    if same > 0 {
                        Text("et " + MonText.plural(same, "élément identique", "éléments identiques") + " (rien à faire)")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 36).padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 6)
                .opacity(isOn ? 1 : 0.5)
            }
        }
    }

    private func partSummary(_ changes: [ConfigChange]) -> String {
        var items: [String] = []
        let add = changes.filter { $0.action == .ajout }.count
        let replace = changes.filter { $0.action == .remplacement }.count
        let conflict = changes.filter { $0.action == .conflit }.count
        if add > 0 { items.append("+\(add)") }
        if replace > 0 { items.append("\(replace)\u{00A0}remplacé\(replace > 1 ? "s" : "")") }
        if conflict > 0 { items.append("\(conflict)\u{00A0}conflit\(conflict > 1 ? "s" : "")") }
        return items.isEmpty ? "identique" : items.joined(separator: " · ")
    }

    private func changeRow(_ change: ConfigChange, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selected.contains(change.id) }, set: { on in
                if on { selected.insert(change.id) } else { selected.remove(change.id) }
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!enabled)
            Chip(text: change.action.label, tone: tone(change.action))
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if change.kind == .secret { Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                    Text(change.label).font(change.kind == .preference ? Theme.mono(11) : Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                }
                if let detail = rowDetail(change) {
                    Text(detail).font(Theme.caption).foregroundStyle(change.action == .conflit ? Theme.warning : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 28).padding(.trailing, 10).padding(.vertical, 4)
    }

    private func rowDetail(_ change: ConfigChange) -> String? {
        if change.action == .conflit, let local = change.localModified {
            return "Modifié sur ce Mac après l’export (\(RegFormat.moment(local)))\u{00A0}: gardé tel quel, sauf si vous le cochez"
        }
        guard let detail = change.detail, change.kind != .fichier || change.action != .ajout else { return nil }
        return detail
    }

    private func tone(_ action: ConfigChangeAction) -> Tone {
        switch action {
        case .ajout: return .success
        case .remplacement: return .accent
        case .conflit: return .warning
        case .identique: return .neutral
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(MonText.plural(chosen.count, "élément sera importé", "éléments seront importés"))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button("Importer et redémarrer") {
                let chosenIDs = selected, chosenParts = parts
                config.confirmImport(selected: chosenIDs, parts: chosenParts)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .regDisabled(chosen.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
