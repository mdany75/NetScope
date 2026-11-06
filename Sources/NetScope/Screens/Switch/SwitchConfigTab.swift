import AppKit
import NetScopeCore
import SwiftUI

/// Note 40 (0.31.0) : onglet « Configurations » de Switchs et ports. Équipements du site (FortiGate
/// par l'API, switchs par SSH), « Sauvegarder maintenant » (un équipement ou le site), alerte quand
/// une configuration a changé, historique et comparaison avant/après (secrets masqués).
struct SwitchConfigTab: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = ConfigBackupModel.shared
    @ObservedObject private var credentials = RegRemoteCredentialStore.shared
    @ObservedObject private var sites = SiteModel.shared
    let snapshots: [SNMPSwitchSnapshot]

    var body: some View {
        let list = model.equipments(state: state, snapshots: snapshots)
        VStack(alignment: .leading, spacing: 16) {
            header(list)
            ForEach(list.filter { model.settings.pendingChanges[$0.id] != nil }) { equipment in
                changeBanner(equipment)
            }
            if list.isEmpty {
                Panel(padding: 0) {
                    EmptyState(systemImage: SwitchPageTab.configurations.symbol, title: "Aucun équipement à sauvegarder",
                               message: "Ajoutez la FortiGate du site ou interrogez les switchs dans l’onglet Switchs\u{00A0}: leurs configurations se sauvegardent ici.")
                        .frame(height: 220)
                }
            } else {
                SidePanelSplit(sideWidth: 340, collapse: .below, spacing: 16) {
                    equipmentTable(list)
                } side: {
                    historyPanel(list.first { $0.id == model.selectedID })
                }
                if let selected = list.first(where: { $0.id == model.selectedID }) {
                    ConfigDiffPanel(model: model, equipment: selected)
                }
            }
        }
        .onAppear { model.load(siteKey: sites.activeKey, equipments: list) }
        .onChange(of: list.map(\.id)) { _, _ in model.load(siteKey: sites.activeKey, equipments: list) }
        .onChange(of: sites.activeKey) { _, key in model.load(siteKey: key, equipments: list) }
    }

    // MARK: En-tête

    private func header(_ list: [ConfigEquipment]) -> some View {
        Panel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    headerText(list)
                    Spacer(minLength: 8)
                    headerControls(list)
                }
                VStack(alignment: .leading, spacing: 10) {
                    headerText(list)
                    headerControls(list)
                }
            }
        }
    }

    private func headerText(_ list: [ConfigEquipment]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sauvegarde des configurations").font(Theme.panelTitle)
            let count = list.count
            Text("\(count) équipement\(count > 1 ? "s" : "") · lecture seule (API REST de la FortiGate, SSH des switchs) · historique dans le dossier du site (configurations)")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }

    private func headerControls(_ list: [ConfigEquipment]) -> some View {
        HStack(spacing: 12) {
            Stepper(value: Binding(get: { model.settings.keep }, set: { model.setKeep($0) }),
                    in: ConfigBackupSettings.keepRange, step: 5) {
                Text("Versions gardées\u{00A0}: \(model.settings.keep)").font(Theme.small).monospacedDigit()
            }
            .fixedSize()
            .help("Nombre de versions gardées par équipement\u{00A0}; les plus anciennes sont retirées.")
            Button {
                Task { await model.backupAll(list) }
            } label: {
                Label("Sauvegarder le site", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.primary)
            .disabled(list.isEmpty || model.isRunning)
            .fixedSize()
        }
    }

    // MARK: Alerte de changement

    private func changeBanner(_ equipment: ConfigEquipment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.dot)
            VStack(alignment: .leading, spacing: 2) {
                Text("La configuration de \(equipment.name) a changé").font(Theme.bodySemibold)
                Text(bannerDetail(equipment)).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Voir les différences") {
                model.select(equipment.id)
                let list = model.versions[equipment.id] ?? []
                model.compareNew = list.first?.id
                model.compareOld = list.dropFirst().first?.id
            }
            .buttonStyle(.secondary)
            Button("Marquer comme vue") { model.markSeen(equipment.id) }
                .buttonStyle(.ghost)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Tone.warning.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Tone.warning.dot.opacity(0.35)))
    }

    private func bannerDetail(_ equipment: ConfigEquipment) -> String {
        let when = model.settings.pendingChanges[equipment.id].map(ConfigDates.long) ?? ""
        let list = model.versions[equipment.id] ?? []
        var detail = "Nouvelle version du \(when)"
        if list.count > 1, let a = model.text(of: list[1]), let b = model.text(of: list[0]) {
            let diff = ConfigDiff.make(old: a, new: b)
            detail += "\u{00A0}: \(diff.added) ligne\(diff.added > 1 ? "s" : "") ajoutée\(diff.added > 1 ? "s" : ""), \(diff.removed) retirée\(diff.removed > 1 ? "s" : "")"
        }
        return detail + ", par rapport à la version précédente."
    }

    // MARK: Tableau des équipements

    private func equipmentTable(_ list: [ConfigEquipment]) -> some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Équipement").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Type").frame(width: 118, alignment: .leading)
                    Text("Accès").frame(width: 150, alignment: .leading)
                    Text("Dernière version").frame(width: 120, alignment: .leading)
                    Text("Versions").frame(width: 56, alignment: .trailing)
                    Color.clear.frame(width: 28, height: 1)
                }
                .font(Theme.captionSemibold)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                ForEach(list) { equipment in
                    row(equipment)
                    Divider()
                }
            }
        }
    }

    private func row(_ equipment: ConfigEquipment) -> some View {
        let selected = model.selectedID == equipment.id
        let error = model.errors[equipment.id]
        let latest = model.versions[equipment.id]?.first
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(tone: error != nil ? .critical : (latest == nil ? .neutral : .success))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(equipment.name).font(Theme.bodySemibold).lineLimit(1)
                        Text(equipment.host).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                kindCell(equipment).frame(width: 118, alignment: .leading)
                accessCell(equipment).frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.map { ConfigDates.short($0.date) } ?? "Jamais").font(Theme.small)
                        .foregroundStyle(latest == nil ? Theme.textTertiary : Theme.text)
                    if model.settings.pendingChanges[equipment.id] != nil {
                        Chip(text: "Modifiée", tone: .warning)
                    }
                }
                .frame(width: 120, alignment: .leading)
                Text("\(model.versions[equipment.id]?.count ?? 0)").font(Theme.small).monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                Group {
                    if model.running.contains(equipment.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await model.backup(equipment) } } label: { Image(systemName: "arrow.down.doc") }
                            .buttonStyle(.ghost)
                            .help("Sauvegarder maintenant la configuration de \(equipment.name)")
                    }
                }
                .frame(width: 28)
            }
            if let error {
                errorView(error, equipment: equipment)
            } else if let notice = model.notices[equipment.id] {
                Text(notice).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(selected ? Theme.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(equipment.id) }
    }

    @ViewBuilder private func kindCell(_ equipment: ConfigEquipment) -> some View {
        if equipment.controllerID != nil {
            Chip(text: "FortiGate", tone: .accent)
        } else {
            Picker("Type", selection: Binding(get: { model.kind(of: equipment) }, set: { model.setKind($0, for: equipment.id) })) {
                Text("À choisir").tag(ConfigDeviceKind?.none)
                ForEach(ConfigDeviceKind.ordered.filter { !$0.usesAPI }) { kind in
                    Text(kind.label).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help(model.kind(of: equipment).map { "Commandes de lecture\u{00A0}: \($0.commandSummary)" } ?? "Type de l’équipement")
        }
    }

    @ViewBuilder private func accessCell(_ equipment: ConfigEquipment) -> some View {
        if equipment.controllerID != nil {
            Text("API REST · jeton du site").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        } else {
            let ssh = credentials.credentials.filter { $0.kind == .ssh }
            if ssh.isEmpty {
                Text("Aucun identifiant SSH").font(Theme.small).foregroundStyle(Theme.warning)
                    .help("Ajoutez un identifiant SSH dans Réglages › Identifiants.")
            } else {
                Picker("Identifiant SSH", selection: Binding(get: { model.credentialID(of: equipment) },
                                                             set: { model.setCredential($0, for: equipment.id) })) {
                    ForEach(ssh) { credential in
                        Text("\(credential.name) (\(credential.user))").tag(Optional(credential.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 150, alignment: .leading)
                .help("Identifiant SSH retenu pour cet équipement\u{00A0}; mot de passe lu au Trousseau.")
            }
        }
    }

    private func errorView(_ error: ConfigBackupError, equipment: ConfigEquipment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Tone.critical.dot).font(.system(size: 11))
                Text(error.title).font(Theme.captionSemibold).foregroundStyle(Theme.critical)
                Text(error.detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).textSelection(.enabled)
            }
            Text(error.advice).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if error.kind == .unknownHostKey {
                Button("Accepter l’empreinte et sauvegarder") { model.acceptHostKey(for: equipment) }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Tone.critical.background.opacity(0.6)))
    }

    // MARK: Historique

    @ViewBuilder private func historyPanel(_ equipment: ConfigEquipment?) -> some View {
        Panel {
            if let equipment {
                let list = model.versions[equipment.id] ?? []
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Historique", subtitle: equipment.name)
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.backup(equipment) }
                        } label: {
                            Label("Sauvegarder maintenant", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.secondary)
                        .disabled(model.running.contains(equipment.id))
                        if !model.isDemo, let first = list.first {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([first.url])
                            } label: {
                                Label("Finder", systemImage: "folder")
                            }
                            .buttonStyle(.ghost)
                            .help("Montrer les fichiers .conf dans le Finder")
                        }
                    }
                    Text(methodText(equipment)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let checked = model.settings.lastChecked[equipment.id] {
                        Text("Dernière vérification\u{00A0}: \(ConfigDates.long(checked))").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Divider()
                    if list.isEmpty {
                        Text("Aucune version gardée. «\u{00A0}Sauvegarder maintenant\u{00A0}» lit la configuration actuelle.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, version in
                                versionRow(version, older: index + 1 < list.count ? list[index + 1] : nil)
                            }
                        }
                        Text("\(list.count) version\(list.count > 1 ? "s" : "") sur \(model.settings.keep) gardées au plus.")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            } else {
                Text("Choisissez un équipement.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func methodText(_ equipment: ConfigEquipment) -> String {
        guard let kind = model.kind(of: equipment) else { return "Type à choisir pour connaître les commandes de lecture." }
        return kind.usesAPI ? "Lecture\u{00A0}: \(kind.commandSummary)" : "Lecture par SSH\u{00A0}: «\u{00A0}\(kind.commandSummary)\u{00A0}» (aucune commande qui modifie)"
    }

    private func versionRow(_ version: ConfigVersion, older: ConfigVersion?) -> some View {
        let isNew = model.compareNew == version.id, isOld = model.compareOld == version.id
        return HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(Theme.textTertiary).font(.system(size: 11))
            Text(ConfigDates.long(version.date)).font(Theme.small)
            Spacer(minLength: 6)
            if isNew { Chip(text: "Après", tone: .accent) }
            if isOld { Chip(text: "Avant", tone: .neutral) }
            Text(ConfigDates.size(version.size)).font(Theme.caption).foregroundStyle(Theme.textTertiary).monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(isNew ? Theme.accentSoft.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.compareNew = version.id
            model.compareOld = older?.id ?? model.compareOld
        }
        .help("Comparer cette version à la précédente")
    }
}

// MARK: - Comparaison

/// Comparaison avant/après de deux versions : lignes ajoutées et retirées surlignées.
struct ConfigDiffPanel: View {
    @ObservedObject var model: ConfigBackupModel
    let equipment: ConfigEquipment

    var body: some View {
        let list = model.versions[equipment.id] ?? []
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        title
                        Spacer(minLength: 8)
                        controls(list)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        controls(list)
                    }
                }
                if list.count < 2 {
                    Text("Une seule version pour l’instant\u{00A0}: la comparaison sera possible après la prochaine sauvegarde qui trouve un changement.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else if let comparison = model.comparison(for: equipment.id) {
                    summary(comparison.diff, old: comparison.old, new: comparison.new)
                    if comparison.diff.isIdentical {
                        Text("Aucune différence (secrets rechiffrés et lignes datées ignorés).")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    } else {
                        ConfigDiffLines(diff: comparison.diff, changesOnly: model.changesOnly)
                    }
                } else {
                    Text("Choisissez deux versions à comparer.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Comparaison avant/après").font(Theme.panelTitle)
            Text(equipment.name + " · secrets masqués").font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    private func controls(_ list: [ConfigVersion]) -> some View {
        HStack(spacing: 10) {
            picker("Avant", selection: $model.compareOld, list: list)
            Image(systemName: "arrow.right").foregroundStyle(Theme.textTertiary)
            picker("Après", selection: $model.compareNew, list: list)
            Toggle("Modifications seulement", isOn: $model.changesOnly)
                .toggleStyle(.checkbox)
                .font(Theme.small)
                .fixedSize()
        }
    }

    private func picker(_ label: String, selection: Binding<String?>, list: [ConfigVersion]) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Picker(label, selection: selection) {
                ForEach(list) { version in
                    Text(ConfigDates.long(version.date)).tag(Optional(version.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func summary(_ diff: ConfigDiff, old: ConfigVersion, new: ConfigVersion) -> some View {
        HStack(spacing: 8) {
            Chip(text: "+\(diff.added)", tone: .success, mono: true)
            Chip(text: "−\(diff.removed)", tone: .critical, mono: true)
            Text("du \(ConfigDates.long(old.date)) au \(ConfigDates.long(new.date))")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            if diff.approximate {
                Chip(text: "Comparaison simplifiée", tone: .warning)
            }
        }
    }
}

/// Lignes de la comparaison, en police à chasse fixe, numérotées (avant, après).
struct ConfigDiffLines: View {
    let diff: ConfigDiff
    let changesOnly: Bool
    /// Au-delà, la liste est coupée (le fichier .conf reste complet).
    static let limit = 3000

    private enum Item: Identifiable {
        case line(Int, ConfigDiffLine)
        case gap(Int, Int)
        var id: Int {
            switch self {
            case .line(let index, _): return index * 2
            case .gap(let index, _): return index * 2 + 1
            }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        if changesOnly {
            var index = 0
            for hunk in diff.hunks(context: 3) {
                if hunk.skippedBefore > 0 { out.append(.gap(index, hunk.skippedBefore)); index += 1 }
                for line in hunk.lines { out.append(.line(index, line)); index += 1 }
            }
            let shown = out.reduce(0) { if case .line(_, let l) = $1, let n = l.oldNumber { return max($0, n) }; return $0 }
            let total = diff.lines.compactMap(\.oldNumber).max() ?? 0
            if total > shown { out.append(.gap(index, total - shown)) }
        } else {
            out = diff.lines.enumerated().map { .line($0.offset, $0.element) }
        }
        return Array(out.prefix(Self.limit))
    }

    var body: some View {
        let rows = items
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { item in
                    switch item {
                    case .line(_, let line): lineView(line)
                    case .gap(_, let count):
                        Text("···  \(count) ligne\(count > 1 ? "s" : "") identique\(count > 1 ? "s" : "")  ···")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 3)
                            .background(Theme.panelMuted)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .frame(height: min(CGFloat(rows.count) * 17 + 8, 460))
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }

    private func lineView(_ line: ConfigDiffLine) -> some View {
        let (sign, tone): (String, Tone?) = {
            switch line.kind {
            case .same: return (" ", nil)
            case .added: return ("+", .success)
            case .removed: return ("−", .critical)
            }
        }()
        return HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(sign).frame(width: 22, alignment: .center).foregroundStyle(tone?.foreground ?? Theme.textTertiary)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(tone?.foreground ?? Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.mono(11.5))
        .foregroundStyle(Theme.textTertiary)
        .frame(height: 17)
        .background(tone?.background ?? Color.clear)
    }
}

/// Dates et tailles de l'onglet, en français.
enum ConfigDates {
    private static let locale = Locale(identifier: "fr_CA")

    /// « 5 nov., 09 h 12 ».
    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute().locale(locale))
    }

    /// « 5 nov. 2026, 09 h 12 ».
    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour(.twoDigits(amPM: .omitted)).minute().locale(locale))
    }

    /// « 18,4 ko ».
    static func size(_ bytes: Int) -> String {
        bytes < 1000 ? "\(bytes)\u{00A0}o" : String(format: "%.1f\u{00A0}ko", Double(bytes) / 1000).replacingOccurrences(of: ".", with: ",")
    }
}
