import AppKit
import NetScopeCore
import SwiftUI

/// Réglages › Journal et diagnostic (note 35) : journal de l'app (tableau standard filtrable par
/// niveau et par module, recherche, copie, effacement) et « Exporter un diagnostic… » (.zip sans
/// aucun secret, pour un signalement).
struct RegDiagnosticSection: View {
    @ObservedObject private var controller = RegDiagnosticController.shared
    @StateObject private var table = StandardTableModel<AppLogEntry>(
        id: "journalApp", columns: RegDiagnosticSection.columns, sortKeys: RegDiagnosticSection.sortKeys,
        defaultSort: "heure", defaultAscending: false)
    @State private var level: LevelFilter = .all
    @State private var module = ""
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var confirmClear = false

    /// Filtre de niveau : tout, ou un seul niveau.
    enum LevelFilter: String, CaseIterable, Hashable {
        case all, error, warning, info

        var label: String {
            switch self {
            case .all: return "Tous"
            case .error: return "Erreurs"
            case .warning: return "Avertissements"
            case .info: return "Infos"
            }
        }

        func matches(_ level: AppLogLevel) -> Bool {
            switch self {
            case .all: return true
            case .error: return level == .error
            case .warning: return level == .warning
            case .info: return level == .info
            }
        }
    }

    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure", isRequired: true),
        StandardColumn(id: "niveau", title: "Niveau"),
        StandardColumn(id: "module", title: "Module"),
        StandardColumn(id: "message", title: "Message", isRequired: true),
    ]

    static let sortKeys: [String: KeyPathComparator<AppLogEntry>] = [
        "heure": KeyPathComparator(\.date, order: .reverse),
        "niveau": KeyPathComparator(\.level, order: .reverse),
        "module": KeyPathComparator(\.module),
        "message": KeyPathComparator(\.message),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Captures (NETSCOPE_DIAGNOSTIC_EXPORT=1) : l'export d'abord, pour le montrer entier.
            if DiagnosticDemo.focusOnExport {
                exportPanel
                journalPanel
            } else {
                journalPanel
                exportPanel
            }
        }
        .onAppear {
            controller.isJournalVisible = true
            controller.reloadCrashes()
        }
        .onDisappear { controller.isJournalVisible = false }
    }

    // MARK: Journal

    private var filtered: [AppLogEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return controller.entries.filter { entry in
            guard level.matches(entry.level), module.isEmpty || entry.module == module else { return false }
            guard !words.isEmpty else { return true }
            let haystack = (entry.module + " " + entry.message + " " + entry.level.label).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var journalPanel: some View {
        let rows = filtered.sorted(using: table.sortOrder)
        let total = controller.entries.count
        let errors = controller.entries.filter { $0.level == .error && $0.date > Date().addingTimeInterval(-86_400) }.count
        return RegPanel(title: "Journal de NetScope",
                        subtitle: "Erreurs, avertissements et étapes des modules (FortiGate, SNMP, courriel, mises à jour, sauvegarde, scan). Les jetons, mots de passe et communautés sont masqués avant l’écriture.") {
            VStack(alignment: .leading, spacing: 12) {
                RegTileRow {
                    RegTile("Entrées gardées", "\(Self.number(total)) sur \(Self.number(AppLog.shared.capacity))")
                    RegTile("Erreurs des dernières 24 h", errors == 0 ? "Aucune" : Self.number(errors))
                    RegTile("Fichiers (3 × 1 Mo au plus)", "~/Library/Logs/NetScope", mono: true)
                }
                filters
                VStack(alignment: .leading, spacing: 6) {
                    // Petite fenêtre : les boutons perdent leur texte (infobulle) plutôt que de déborder.
                    ViewThatFits(in: .horizontal) {
                        entriesBar(rows: rows, total: total, compact: false)
                        entriesBar(rows: rows, total: total, compact: true)
                    }
                    ToolStandardTableFrame(rowCount: rows.count, maxRows: 14,
                                           emptyText: total == 0 ? "Le journal est vide." : "Aucune entrée pour ces critères.") {
                        Table(rows, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                            TableColumn("HEURE", sortUsing: table.sort("heure")) { entry in
                                ToolTableText(Self.timeText(entry.date), size: 11.5)
                                    .help(Self.fullDate(entry.date))
                            }
                            .width(min: 60, ideal: 66, max: 96)
                            .customizationID("heure").disabledCustomizationBehavior(.visibility)
                            TableColumn("NIVEAU", sortUsing: table.sort("niveau")) { entry in
                                AppLogLevelChip(level: entry.level)
                            }
                            .width(min: 56, ideal: 66, max: 116)
                            .customizationID("niveau")
                            TableColumn("MODULE", sortUsing: table.sort("module")) { entry in
                                ToolTableText(entry.module, mono: false, weight: .medium)
                            }
                            .width(min: 64, ideal: 76, max: 130)
                            .customizationID("module")
                            TableColumn("MESSAGE", sortUsing: table.sort("message")) { entry in
                                ToolTableText(entry.message, mono: false)
                                    .help(entry.message)
                            }
                            .width(min: 160, ideal: 420)
                            .customizationID("message").disabledCustomizationBehavior(.visibility)
                        }
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            let chosen = rows.filter { ids.contains($0.id) }
                            if !chosen.isEmpty {
                                Button(chosen.count > 1 ? "Copier les \(chosen.count) entrées" : "Copier l’entrée") { controller.copy(chosen) }
                                Button("Copier le message") { ToolActions.copy(chosen.map(\.message).joined(separator: "\n")) }
                                if let first = chosen.first {
                                    Divider()
                                    Button("Filtrer sur le module «\u{00A0}\(first.module)\u{00A0}»") { module = first.module }
                                }
                            }
                        }
                    }
                }
                if let message = controller.message {
                    RegNotice(message.text, tone: message.tone)
                }
            }
        }
        .confirmationDialog("Effacer le journal de NetScope\u{00A0}?", isPresented: $confirmClear) {
            Button("Effacer le journal", role: .destructive) {
                selection = []
                controller.clear()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text((total == 1 ? "L’entrée et les fichiers" : "Les \(Self.number(total)) entrées et les fichiers")
                 + " de ~/Library/Logs/NetScope sont supprimés. Les rapports de plantage de macOS ne sont pas touchés.")
        }
    }

    private func entriesBar(rows: [AppLogEntry], total: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
            ToolFieldLabel("Entrées")
            Text("· \(rows.count) affichée\(rows.count > 1 ? "s" : "")" + (rows.count == total ? "" : " sur \(total)"))
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Button {
                controller.copy(selectedOrAll(rows))
            } label: {
                if compact {
                    Image(systemName: "doc.on.doc")
                } else {
                    Label(selection.isEmpty ? "Copier" : "Copier la sélection", systemImage: "doc.on.doc")
                }
            }
            .disabled(rows.isEmpty)
            .help("Copie les entrées affichées (ou sélectionnées), secrets masqués")
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                if compact {
                    Image(systemName: "trash")
                } else {
                    Label("Effacer le journal", systemImage: "trash")
                }
            }
            .disabled(total == 0)
            .help("Vide le journal en mémoire et ses fichiers dans ~/Library/Logs/NetScope")
            ToolColumnsMenu(model: table)
        }
        .controlSize(.small)
        .fixedSize(horizontal: compact, vertical: false)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                levelPicker
                modulePicker
                SearchField(text: $query, placeholder: "Rechercher dans le journal")
                    .frame(minWidth: 180, maxWidth: 320)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    levelPicker
                    modulePicker
                    Spacer(minLength: 0)
                }
                SearchField(text: $query, placeholder: "Rechercher dans le journal")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    levelMenu
                    modulePicker
                    Spacer(minLength: 0)
                }
                SearchField(text: $query, placeholder: "Rechercher dans le journal")
            }
        }
    }

    /// Niveau en menu, quand le sélecteur segmenté ne tient pas.
    private var levelMenu: some View {
        Picker("Niveau", selection: $level) {
            ForEach(LevelFilter.allCases, id: \.self) { filter in
                Text(filter == .all ? "Tous les niveaux" : filter.label).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var levelPicker: some View {
        InvSegmented(options: LevelFilter.allCases.map { ($0, $0.label) }, selection: $level)
            .help("Niveau des entrées affichées")
    }

    private var modulePicker: some View {
        Picker("Module", selection: $module) {
            Text("Tous les modules").tag("")
            Divider()
            ForEach(moduleChoices, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Module qui a écrit l’entrée")
    }

    /// Modules du journal, plus celui choisi s'il n'a plus d'entrée (journal effacé).
    private var moduleChoices: [String] {
        var list = controller.modules
        if !module.isEmpty, !list.contains(module) { list.append(module) }
        return list
    }

    private func selectedOrAll(_ rows: [AppLogEntry]) -> [AppLogEntry] {
        let chosen = rows.filter { selection.contains($0.id) }
        // Copie dans l'ordre chronologique, comme le fichier.
        return (chosen.isEmpty ? rows : chosen).sorted { $0.date < $1.date }
    }

    // MARK: Export

    private var exportPanel: some View {
        RegPanel(title: "Exporter un diagnostic",
                 subtitle: "Une archive .zip à joindre à un signalement, sans aucun secret\u{00A0}: tout son texte passe par le masqueur.") {
            Button {
                controller.export()
            } label: {
                Label(controller.isExporting ? "Exportation…" : "Exporter un diagnostic…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.primary)
            .disabled(controller.isExporting)
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                RegLabel("Contenu de l’archive")
                VStack(alignment: .leading, spacing: 6) {
                    contentRow("doc.text", "journal.txt", "le journal de NetScope, secrets masqués")
                    contentRow("desktopcomputer", "systeme.txt", "version de NetScope et de macOS, modèle du Mac, interfaces actives (adresses publiques abrégées)")
                    contentRow("mappin.and.ellipse", "sites.json", "sites et plages, sans identifiants ni notes")
                    contentRow("slider.horizontal.3", "reglages.json", "réglages non secrets")
                    contentRow("exclamationmark.triangle", "plantages/", "rapports de plantage de NetScope des 30 derniers jours")
                }
                RegLabel("Plantages récents").padding(.top, 4)
                if controller.recentCrashes.isEmpty {
                    Text("Aucun plantage de NetScope ces 30 derniers jours.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.recentCrashes.prefix(5)) { report in
                            crashRow(report)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                }
                if !RegEnvironment.isSandboxed {
                    ActionRow {
                        Button("Afficher les journaux dans le Finder") {
                            let folder = AppLogFile.standardDirectory
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        .buttonStyle(.secondary)
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func contentRow(_ symbol: String, _ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
            Text(name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func crashRow(_ report: CrashReport) -> some View {
        // Petite fenêtre : le nom du fichier, puis la version, passent dans l'infobulle.
        ViewThatFits(in: .horizontal) {
            crashLine(report, version: true, file: true)
            crashLine(report, version: true, file: false)
            crashLine(report, version: false, file: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .help([report.fileName, report.appVersion.map { "NetScope " + $0 }, report.osVersion, report.exception]
            .compactMap { $0 }.joined(separator: " · "))
    }

    private func crashLine(_ report: CrashReport, version: Bool, file: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.critical)
            Text(Self.fullDate(report.date)).font(Theme.small).fontWeight(.semibold).foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize()
            if version, let appVersion = report.appVersion {
                Text("NetScope \(appVersion)").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            }
            if let exception = report.exception {
                Text(exception).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            if file {
                Text(report.fileName).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
            }
        }
    }

    // MARK: Format

    /// « 5 000 » (espace insécable fine des milliers).
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "fr_CA")))
    }

    /// « 14:02:05 » aujourd'hui, sinon « 3 nov. 14:02:05 ».
    static func timeText(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().locale(Locale(identifier: "fr_CA")))
        if Calendar.current.isDateInToday(date) { return time }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_CA"))) + " " + time
    }

    /// « 4 novembre 2026 à 16:42:10 ».
    static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().hour(.twoDigits(amPM: .omitted)).minute().second()
            .locale(Locale(identifier: "fr_CA")))
    }
}

/// Puce du niveau d'une entrée (Erreur en rouge, Avertissement en orange, Info en gris).
struct AppLogLevelChip: View {
    let level: AppLogLevel

    var body: some View {
        // Colonne étroite (petite fenêtre) : « Avert. », le mot entier en infobulle.
        ViewThatFits(in: .horizontal) {
            Chip(text: level.label, tone: Self.tone(level))
            Chip(text: Self.shortLabel(level), tone: Self.tone(level)).help(level.label)
        }
    }

    static func shortLabel(_ level: AppLogLevel) -> String {
        level == .warning ? "Avert." : level.label
    }

    static func tone(_ level: AppLogLevel) -> Tone {
        switch level {
        case .error: return .critical
        case .warning: return .warning
        case .info: return .neutral
        }
    }
}
