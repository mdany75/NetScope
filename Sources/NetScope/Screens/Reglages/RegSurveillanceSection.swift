import NetScopeCore
import SwiftUI

/// Réglages › Surveillance (notes 63 et 64) : scans planifiés par site, journal de leurs exécutions,
/// et agent en arrière-plan (sondes, Syslog et scans planifiés quand NetScope est fermé).
struct RegSurveillanceSection: View {
    @ObservedObject private var store = ScanScheduleStore.shared
    @ObservedObject private var agent = AgentController.shared
    @ObservedObject private var sites = SiteModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            schedulesPanel
            runsPanel
            agentPanel
        }
        .sheet(item: $store.draft) { _ in ScanScheduleEditor() }
        .task {
            // État de l'agent relu pendant que la section est affichée.
            guard !agent.isDemo else { return }
            while !Task.isCancelled {
                agent.refresh()
                store.reload()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: Scans planifiés

    private var schedulesPanel: some View {
        RegPanel(title: "Scans planifiés",
                 subtitle: "Chaque site à ses jours et à son heure, avec son profil. Ils alimentent l’historique, l’adressage, l’alerte «\u{00A0}nouvel appareil\u{00A0}» et les rapports planifiés\u{00A0}; jamais pendant un autre scan.") {
            VStack(alignment: .leading, spacing: 10) {
                if store.schedules.isEmpty {
                    RegNotice("Aucun scan planifié. Ajoutez-en un pour scanner un site chaque nuit, par exemple.", tone: .neutral)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.schedules) { schedule in
                            scheduleRow(schedule)
                        }
                    }
                }
                ActionRow {
                    Button {
                        store.newDraft()
                    } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                    .buttonStyle(.secondary)
                    .regDisabled(sites.sites.isEmpty)
                    .help(sites.sites.isEmpty ? "Enregistrez d’abord un site (Réglages › Sites et plages)." : "Nouveau scan planifié")
                }
            }
        }
    }

    /// Deux lignes par scan planifié (lisible aussi en petite fenêtre) : site et rythme, puis profil,
    /// prochaine exécution et dernière issue.
    private func scheduleRow(_ schedule: ScanSchedule) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if store.runningID == schedule.id { ProgressView().controlSize(.small) }
                    Text(store.siteName(schedule.siteKey)).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                    Text(ScanScheduler.rhythmLabel(schedule)).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                }
                // Petite fenêtre : la dernière issue passe sous la prochaine exécution.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        nextText(schedule)
                        lastCell(schedule)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        nextText(schedule)
                        lastCell(schedule)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                RegSwitch(isOn: Binding(get: { schedule.isEnabled }, set: { store.setEnabled($0, for: schedule.id) }))
                    .help(schedule.isEnabled ? "Mettre en pause" : "Reprendre")
                Button { store.draft = schedule } label: { Image(systemName: "pencil") }
                    .buttonStyle(RegSmallButtonStyle()).help("Modifier")
                Button { store.remove(schedule.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(RegSmallButtonStyle()).help("Supprimer")
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    private func nextText(_ schedule: ScanSchedule) -> some View {
        Text(schedule.profile.label + (schedule.isEnabled ? " · Prochain\u{00A0}: \(store.nextLabel(schedule))" : " · En pause"))
            .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
    }

    @ViewBuilder private func lastCell(_ schedule: ScanSchedule) -> some View {
        if let outcome = schedule.lastOutcome, let run = schedule.lastRun {
            HStack(spacing: 6) {
                RegPill(text: outcome.label, tone: Self.tone(outcome))
                Text(ScanScheduler.dateLabel(run, now: store.now, calendar: store.calendar))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .fixedSize()
            .help(schedule.lastMessage ?? "")
        } else {
            Text("Jamais").font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    static func tone(_ outcome: ScanRunOutcome) -> Tone {
        switch outcome {
        case .ok: return .success
        case .partial, .skipped, .missed: return .warning
        case .failed: return .critical
        }
    }

    // MARK: Journal des exécutions

    private var runsPanel: some View {
        RegPanel(title: "Journal des scans planifiés",
                 subtitle: "Les dernières exécutions, par l’app ou par l’agent. Une échéance manquée de plus de 6\u{00A0}h n’est pas rattrapée.") {
            VStack(alignment: .leading, spacing: 10) {
                if store.book.runs.isEmpty {
                    RegNotice("Aucune exécution pour l’instant.", tone: .neutral)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.book.runs.prefix(8)) { run in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    RegPill(text: run.outcome.label, tone: Self.tone(run.outcome))
                                    Text(run.siteName).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(ScanScheduler.dateLabel(run.date, now: store.now, calendar: store.calendar))
                                        .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    Chip(text: run.host.label, tone: .neutral)
                                }
                                Text(run.message).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                        }
                    }
                }
                ActionRow {
                    Button("Effacer") { store.clearRuns() }
                        .buttonStyle(.secondary)
                        .regDisabled(store.book.runs.isEmpty)
                }
            }
        }
    }

    // MARK: Agent

    private var agentPanel: some View {
        RegPanel(title: "Agent en arrière-plan",
                 subtitle: "Quand NetScope est fermé, un agent sans fenêtre continue les sondes réseau (ping, TCP, HTTP, DNS), la réception Syslog et les scans planifiés. NetScope reprend la main dès qu’il s’ouvre.") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                RegToggleRow(title: "Surveiller quand NetScope est fermé",
                             detail: "Désactivé par défaut. macOS peut demander de l’autoriser dans Réglages Système › Général › Ouverture.",
                             isOn: Binding(get: { agent.isEnabled }, set: { agent.setEnabled($0) }))
                if let message = agent.message {
                    RegNotice(text: message, tone: .warning) {
                        Button("Ouvrir les Réglages Système") { agent.openLoginItems() }
                            .buttonStyle(RegSmallButtonStyle())
                    }
                }
                RegTileRow {
                    RegTile(title: "État") {
                        Text(agent.stateLabel.text).foregroundStyle(agent.stateLabel.tone == .neutral ? Theme.text : agent.stateLabel.tone.foreground)
                    }
                    RegTile("Sondes reprises", agent.status.map { "\($0.probes) sonde\($0.probes > 1 ? "s" : "") réseau" } ?? "—")
                    RegTile("Syslog", syslogLabel)
                    RegTile("Prochain scan planifié", nextScanLabel)
                }
                if agent.isEnabled {
                    RegToggleRow(title: "Sondes réseau", detail: "Les autres sondes (SNMP, FortiGate, inventaire) attendent NetScope.",
                                 isOn: $agent.settings.monitor)
                    RegToggleRow(title: "Réception Syslog", detail: "Même port que l’écran Journaux (UDP seulement).", isOn: $agent.settings.syslog)
                    RegToggleRow(title: "Scans planifiés", isOn: $agent.settings.scans)
                }
                agentJournal
            }
        }
    }

    private var syslogLabel: String {
        guard let status = agent.status, status.mode == .active else { return "Repris quand NetScope est fermé" }
        if let error = status.syslogError { return "Erreur\u{00A0}: \(error)" }
        return status.syslogPort.map { "Écoute sur le port \($0)" } ?? "Inactif"
    }

    private var nextScanLabel: String {
        if let site = agent.status?.scanning { return "En cours\u{00A0}: \(site)" }
        guard let next = ScanScheduler.nextRun(store.schedules, after: store.now, calendar: store.calendar) else { return "Aucun" }
        let site = store.schedules.first { $0.id == next.id }.map { store.siteName($0.siteKey) } ?? ""
        return ScanScheduler.dateLabel(next.date, now: store.now, calendar: store.calendar) + (site.isEmpty ? "" : " · " + site)
    }

    @ViewBuilder private var agentJournal: some View {
        if !agent.journal.entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                RegLabel("Journal de l’agent").padding(.bottom, 4)
                ForEach(agent.journal.entries.prefix(8)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ScanScheduler.dateLabel(entry.date, now: agent.now, calendar: store.calendar))
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .frame(width: 125, alignment: .leading)
                        Image(systemName: entry.level == .info ? "info.circle" : "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(entry.level == .info ? Theme.textSecondary : (entry.level == .error ? Tone.critical.foreground : Tone.warning.foreground))
                        Text(entry.text).font(Theme.small).foregroundStyle(Theme.text).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                }
            }
        }
    }
}

/// Éditeur d'un scan planifié : site, jours, heure, profil.
struct ScanScheduleEditor: View {
    @ObservedObject private var store = ScanScheduleStore.shared
    @ObservedObject private var sites = SiteModel.shared

    private static let dayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let dayLetters = [1: "D", 2: "L", 3: "M", 4: "M", 5: "J", 6: "V", 7: "S"]
    private static let dayNames = [1: "dimanche", 2: "lundi", 3: "mardi", 4: "mercredi", 5: "jeudi", 6: "vendredi", 7: "samedi"]

    var body: some View {
        if let draft = store.draft {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.schedules.contains { $0.id == draft.id } ? "Modifier le scan planifié" : "Nouveau scan planifié")
                    .font(Theme.panelTitle).foregroundStyle(Theme.text)
                RegField(label: "Site") {
                    Picker("", selection: binding(\.siteKey)) {
                        ForEach(sites.sites) { site in Text(site.displayName).tag(SiteFiles.key(for: site.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                RegField(label: "Jours") {
                    HStack(spacing: 4) {
                        ForEach(Self.dayOrder, id: \.self) { day in
                            let on = draft.weekdays.contains(day)
                            Button { toggle(day) } label: {
                                Text(Self.dayLetters[day] ?? "")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(on ? Color.white : Theme.text)
                                    .frame(width: 28, height: 26)
                                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(on ? Color.accentColor : Theme.panelMuted))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                            .help(Self.dayNames[day] ?? "")
                        }
                        Text(ScanScheduler.daysLabel(draft.weekdays)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 8)
                    }
                }
                RegField(label: "Heure") {
                    HStack(spacing: 6) {
                        Picker("", selection: binding(\.hour)) {
                            ForEach(0..<24, id: \.self) { Text("\($0)\u{00A0}h").tag($0) }
                        }
                        .labelsHidden().frame(width: 80)
                        Picker("", selection: binding(\.minute)) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 70)
                    }
                }
                RegField(label: "Profil de scan") {
                    Picker("", selection: binding(\.profile)) {
                        ForEach(ScanProfile.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                RegNotice("Site actif\u{00A0}: le scan passe par le Scanner (switchs et FortiGate compris). Autre site, ou NetScope fermé\u{00A0}: découverte, noms et ports seulement.", tone: .neutral)
                HStack {
                    Spacer()
                    Button("Annuler") { store.draft = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Enregistrer") { store.saveDraft() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.weekdays.isEmpty || sites.site(forKey: draft.siteKey) == nil)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }

    private func binding<T>(_ path: WritableKeyPath<ScanSchedule, T>) -> Binding<T> {
        Binding(get: { (store.draft ?? ScanSchedule(siteKey: SiteFiles.noSiteKey))[keyPath: path] }, set: { store.draft?[keyPath: path] = $0 })
    }

    private func toggle(_ day: Int) {
        guard var draft = store.draft else { return }
        if let index = draft.weekdays.firstIndex(of: day) { draft.weekdays.remove(at: index) } else { draft.weekdays = (draft.weekdays + [day]).sorted() }
        store.draft = draft
    }
}
