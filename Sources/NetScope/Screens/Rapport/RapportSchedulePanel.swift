import NetScopeCore
import SwiftUI

/// Note 42 : « Rapports planifiés » dans la colonne des Rapports : liste (rythme, sites, prochaine
/// production, dernier résultat) et éditeur dans le panneau. Rien n'est envoyé sans un choix explicite :
/// un brouillon dans Mail, ou (note 78) l'envoi par le SMTP des Alertes. Aucun scan n'est lancé.
struct RapportSchedulePanel: View {
    @ObservedObject private var store = RapportScheduleStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @State private var pendingDelete: ReportSchedule?
    /// Note 78 : « Envoyer un essai… » en attente de confirmation.
    @State private var pendingTest: ReportSchedule?

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Rapports planifiés") {
                    if store.draft == nil {
                        Button { store.newDraft() } label: { Label("Planifier", systemImage: "plus") }
                            .buttonStyle(RapportSmallButtonStyle())
                    }
                }
                .padding(.bottom, 8)
                if store.draft != nil {
                    RapportScheduleEditor(store: store)
                } else {
                    list
                }
                if let message = store.message {
                    Text(message.text)
                        .font(Theme.small).foregroundStyle(message.tone.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(message.tone.background))
                        .padding(.top, 8)
                }
            }
        }
        .confirmationDialog("Supprimer ce rapport planifié\u{00A0}?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { schedule in
            Button("Supprimer «\u{00A0}\(schedule.name)\u{00A0}»", role: .destructive) { store.delete(schedule.id) }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Les rapports déjà produits restent dans leur dossier et dans les rapports passés.")
        }
        .confirmationDialog("Envoyer un essai de ce rapport\u{00A0}?", isPresented: Binding(get: { pendingTest != nil }, set: { if !$0 { pendingTest = nil } }),
                            presenting: pendingTest) { schedule in
            Button("Envoyer l’essai") { store.sendTest(schedule.id) }
            Button("Annuler", role: .cancel) {}
        } message: { schedule in
            Text("Le rapport «\u{00A0}\(schedule.name)\u{00A0}» est produit maintenant (dernier scan de chaque site), puis envoyé à\u{00A0}: \(store.testRecipients(schedule)), par le serveur SMTP des Alertes.")
        }
    }

    @ViewBuilder private var list: some View {
        if store.schedules.isEmpty {
            Text("Aucun rapport planifié. Un rapport planifié est produit à date fixe quand NetScope est ouvert, d’après le dernier scan du site (aucun scan n’est lancé).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
        ForEach(store.schedules) { schedule in
            row(schedule)
        }
    }

    private func row(_ schedule: ReportSchedule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { schedule.isEnabled }, set: { store.setEnabled($0, schedule.id) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(schedule.isEnabled ? "Mettre en pause" : "Reprendre")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(schedule.isEnabled ? Theme.text : Theme.textSecondary)
                Text(ReportScheduler.rhythmLabel(schedule) + " · " + schedule.config.format.label)
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Text(store.sitesLabel(schedule) + " · " + schedule.config.template.shortTitle)
                    .help("\(schedule.config.sections.count) section" + (schedule.config.sections.count > 1 ? "s" : "") + "\u{00A0}: "
                          + ReportSectionKind.documentOrder.filter(schedule.config.includes).map(\.label).joined(separator: ", "))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                (Text("Prochain\u{00A0}: ").foregroundColor(Theme.textSecondary) + Text(store.nextLabel(schedule)).foregroundColor(Theme.text))
                    .font(Theme.caption).lineLimit(1)
                if let produced = schedule.lastProduced, let message = schedule.lastMessage {
                    HStack(spacing: 5) {
                        StatusDot(tone: statusTone(schedule.lastStatus), size: 7)
                        Text(InvFormat.stamp(produced) + " · " + message)
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    }
                    .help(message + (schedule.lastFiles.isEmpty ? "" : "\n" + schedule.lastFiles.joined(separator: "\n")))
                }
                if schedule.email == .send {
                    let count = schedule.siteKeys.map { ReportMail.recipients(schedule, siteKey: $0).count }.reduce(0, +)
                    Label(store.sending == schedule.id ? "Envoi du courriel…"
                          : "Envoi automatique à \(count) destinataire\(count > 1 ? "s" : "")", systemImage: "paperplane")
                        .font(Theme.caption).foregroundStyle(Theme.accentStrong).lineLimit(1).truncationMode(.middle)
                        .help("Après chaque production, le rapport part par le serveur SMTP des Alertes\u{00A0}: \(store.testRecipients(schedule)).")
                }
                if schedule.email == .draft {
                    Label(schedule.emailTo.isEmpty ? "Brouillon de courriel (sans destinataire)" : "Brouillon pour \(schedule.emailTo)",
                          systemImage: "envelope")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        .help("À la fin, un brouillon s’ouvre dans Mail avec le rapport joint. Rien n’est envoyé.")
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Modifier…") { store.edit(schedule.id) }
                Button("Produire maintenant") { store.produceNow(schedule.id) }
                    .disabled(store.producing != nil)
                Button("Envoyer un essai…") { pendingTest = schedule }
                    .disabled(store.producing != nil || store.sending != nil
                              || schedule.siteKeys.allSatisfy { ReportMail.recipients(schedule, siteKey: $0).isEmpty })
                    .help("Produit le rapport maintenant et l’envoie aux destinataires, même si l’envoi automatique n’est pas activé")
                Button("Afficher le dossier") { store.revealFolder(schedule) }
                Divider()
                Button("Supprimer…", role: .destructive) { pendingDelete = schedule }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.edit(schedule.id) }
    }

    private func statusTone(_ status: ReportScheduleStatus?) -> Tone {
        switch status {
        case .ok: return .success
        case .partial: return .warning
        case .failed: return .critical
        case nil: return .neutral
        }
    }
}

/// Éditeur d'un rapport planifié, dans le panneau (petite colonne : un champ par ligne).
struct RapportScheduleEditor: View {
    @ObservedObject var store: RapportScheduleStore
    @ObservedObject private var sites = SiteModel.shared

    private var draft: Binding<ReportSchedule> {
        Binding(get: { store.draft ?? ReportSchedule(name: "", siteKeys: []) }, set: { store.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Nom") {
                TextField("Nom", text: draft.name, prompt: Text("Suivi hebdomadaire"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            field("Sites (un fichier par site)") { siteList }
            field("Rythme") {
                Picker("Rythme", selection: draft.cadence) {
                    Text("Jour").tag(ReportCadence.daily)
                    Text("Semaine").tag(ReportCadence.weekly)
                    Text("Mois").tag(ReportCadence.monthly)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack(spacing: 8) {
                switch draft.wrappedValue.cadence {
                case .daily:
                    Text("Chaque jour, à").font(Theme.small).foregroundStyle(Theme.textSecondary)
                case .weekly:
                    Picker("Jour", selection: draft.weekday) {
                        ForEach(1...7, id: \.self) { day in
                            // Lundi d'abord, comme au Québec.
                            let weekday = day % 7 + 1
                            Text("Le " + ReportScheduler.weekdayName(weekday)).tag(weekday)
                        }
                    }
                    .labelsHidden().fixedSize()
                case .monthly:
                    Picker("Jour du mois", selection: draft.monthDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text(day == 1 ? "Le 1er" : "Le \(day)").tag(day)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .help("Un jour qui n’existe pas dans le mois (31 en novembre) devient le dernier jour du mois.")
                }
                DatePicker("Heure", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .environment(\.locale, Locale(identifier: "fr_CA"))
                    .fixedSize()
                Spacer(minLength: 0)
            }
            Text(ReportScheduler.rhythmLabel(draft.wrappedValue) + ". Prochain\u{00A0}: " + store.nextLabel(draft.wrappedValue) + ".")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            field("Modèle et sections") {
                HStack(spacing: 6) {
                    Picker("Modèle", selection: Binding(get: { draft.wrappedValue.config.template },
                                                        set: { draft.wrappedValue.config.apply($0) })) {
                        ForEach(ReportTemplate.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    Menu {
                        ForEach(ReportSectionKind.documentOrder) { kind in
                            Toggle(kind.label, isOn: Binding(get: { draft.wrappedValue.config.includes(kind) }, set: { on in
                                if on { draft.wrappedValue.config.sections.insert(kind) } else { draft.wrappedValue.config.sections.remove(kind) }
                            }))
                        }
                    } label: {
                        let count = draft.wrappedValue.config.sections.count
                        Text("\(count) section\(count > 1 ? "s" : "")").font(Theme.small)
                    }
                    .fixedSize()
                    .help("Sections du rapport\u{00A0}; «\u{00A0}Depuis le dernier rapport\u{00A0}» compare au rapport précédent du même site.")
                }
            }
            field("Format") {
                Picker("Format", selection: draft.config.format) {
                    ForEach(ReportFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            field("Dossier de destination") {
                HStack(spacing: 6) {
                    Text(store.folderLabel(draft.wrappedValue))
                        .font(Theme.small).lineLimit(1).truncationMode(.middle)
                        .help(store.folderLabel(draft.wrappedValue))
                    Spacer(minLength: 4)
                    if draft.wrappedValue.folder != nil {
                        Button { draft.wrappedValue.folder = nil } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(RapportSmallButtonStyle(width: 28))
                            .help("Revenir au dossier des rapports de NetScope")
                    }
                    Button("Choisir…") { store.chooseFolder() }
                        .buttonStyle(RapportSmallButtonStyle())
                }
            }
            field("Nom du fichier") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Nom du fichier", text: draft.fileNamePattern, prompt: Text(ReportSchedule.defaultPattern))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .font(Theme.mono(12))
                        .help("Repères\u{00A0}: {site}, {modele}, {date}, {heure}, {client}. La date est toujours ajoutée.")
                    Text("→ " + previewName)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
            field("À la fin") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("À la fin", selection: draft.email) {
                        ForEach(ReportScheduleEmail.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if draft.wrappedValue.email == .draft {
                        TextField("Destinataire", text: draft.emailTo, prompt: Text("destinataire@exemple.ca"))
                            .textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    if draft.wrappedValue.email == .send {
                        RapportScheduleMailFields(store: store, draft: draft)
                    } else {
                        Text("Une notification annonce le rapport. Rien n’est envoyé par courriel\u{00A0}: au plus, un brouillon s’ouvre dans Mail pour relecture.")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Aucun scan n’est lancé\u{00A0}: le rapport reprend le dernier scan de chaque site et indique son âge. Produit quand NetScope est ouvert\u{00A0}; une échéance manquée est rattrapée une fois au lancement.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            HStack(spacing: 6) {
                Spacer()
                Button("Annuler") { store.draft = nil }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(store.isNewDraft ? "Planifier" : "Enregistrer") { store.saveDraft() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.wrappedValue.siteKeys.isEmpty)
            }
        }
    }

    private var previewName: String {
        let schedule = draft.wrappedValue
        let calendar = store.calendar
        let slot = ReportScheduler.nextSlot(after: store.now, schedule, calendar: calendar) ?? store.now
        let site = schedule.siteKeys.first.map { sites.name(forKey: $0) } ?? "site"
        return ReportScheduler.fileName(pattern: schedule.fileNamePattern, siteName: site, config: schedule.config, slot: slot,
                                        format: schedule.config.format, calendar: calendar)
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            store.calendar.date(bySettingHour: draft.wrappedValue.hour, minute: draft.wrappedValue.minute, second: 0, of: store.now) ?? store.now
        }, set: { date in
            let parts = store.calendar.dateComponents([.hour, .minute], from: date)
            draft.wrappedValue.hour = parts.hour ?? 7
            draft.wrappedValue.minute = parts.minute ?? 0
        })
    }

    @ViewBuilder private var siteList: some View {
        let choices = siteChoices
        VStack(alignment: .leading, spacing: 2) {
            ForEach(choices, id: \.key) { choice in
                Toggle(isOn: Binding(get: { draft.wrappedValue.siteKeys.contains(choice.key) }, set: { on in
                    if on { draft.wrappedValue.siteKeys.append(choice.key) } else { draft.wrappedValue.siteKeys.removeAll { $0 == choice.key } }
                })) {
                    Text(choice.name).font(Theme.body).lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    /// Sites connus ; sans site enregistré, les plages libres (« Aucun site »).
    private var siteChoices: [(key: String, name: String)] {
        let list = sites.sortedSites.map { (key: SiteFiles.key(for: $0.id), name: $0.displayName) }
        return list.isEmpty ? [(key: sites.activeKey, name: sites.activeName)] : list
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
