import NetScopeCore
import SwiftUI

/// Note 78 : panneau « Horaires et maintenance » de la Surveillance : heures ouvrables de chaque
/// site (plage « Heures ouvrables du site » des sondes), fenêtres de maintenance planifiées
/// (alertes suspendues et notées au journal) et rappel des alertes non accusées. Les éditeurs
/// s'ouvrent dans le panneau, comme celui des rapports planifiés.
struct MonPlanningPanel: View {
    @ObservedObject private var store = MonStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @State private var mode: Mode = MonPlanningPanel.initialMode

    enum Mode: Equatable {
        case list
        /// Heures d'un site (nil : horaire par défaut).
        case hours(UUID?)
        case window(MonMaintenanceWindow)
    }

    /// Captures : NETSCOPE_SURV_PLANIF=heures (Siège) ou =fenetre (« Mises à jour FortiOS »).
    static var initialMode: Mode {
        switch MonPlanningDemo.editorMode {
        case "heures": return .hours(SitesDemo.siegeID)
        case "fenetre":
            if let window = MonStore.shared.planning.windows.first(where: { $0.repeats == .weekly }) { return .window(window) }
            return .list
        default: return .list
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch mode {
            case .list: list
            case .hours(let site): MonHoursEditor(site: site, close: { mode = .list })
            case .window(let window): MonWindowEditor(window: window, isNew: !store.planning.windows.contains { $0.id == window.id },
                                                      close: { mode = .list })
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monPanel()
    }

    // MARK: Liste

    @ViewBuilder private var list: some View {
        HStack(spacing: 8) {
            MonHeading("Horaires et maintenance")
            Spacer(minLength: 4)
            Button { mode = .window(newWindow()) } label: {
                Label("Maintenance", systemImage: "plus").font(Theme.small)
            }
            .buttonStyle(MonCompactButtonStyle())
            .help("Planifier une fenêtre de maintenance\u{00A0}: les alertes des sondes visées sont suspendues et notées au journal.")
        }

        Text("Heures ouvrables").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
        VStack(spacing: 0) {
            ForEach(sites.sortedSites.filter { store.planning.hasOwnHours($0.id) }) { site in
                hoursRow(name: site.displayName, site: site.id)
            }
            defaultHoursRow
        }

        Text("Fenêtres de maintenance").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary).padding(.top, 2)
        if store.planning.windows.isEmpty {
            Text("Aucune fenêtre. Pendant une fenêtre, les sondes tournent mais leurs alertes sont suspendues, notées au journal, et ces vérifications ne comptent pas dans la disponibilité.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(sortedWindows) { window in windowRow(window) }
            }
        }

        HStack(spacing: 8) {
            Text("Rappel si non accusée").font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            Picker("Rappel si non accusée", selection: Binding(get: { store.planning.reminderMinutes },
                                                               set: { store.setReminder(minutes: $0) })) {
                ForEach(MonPlanning.reminderChoices, id: \.self) { Text(MonPlanning.reminderLabel($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.top, 2)
        .help("Une alerte (panne ou avertissement) toujours ouverte et non accusée est rappelée par une notification et par les canaux des Alertes, au plus \(store.planning.reminderLimit) fois.")
        Text(store.planning.reminderMinutes == 0
             ? "Aucun rappel\u{00A0}: une alerte non accusée n’est notifiée qu’une fois."
             : "Notification et canaux des Alertes, au plus \(store.planning.reminderLimit) rappels par alerte.")
            .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private var sortedWindows: [MonMaintenanceWindow] {
        let now = store.now
        return store.planning.windows.sorted { a, b in
            let left = a.nextOccurrence(after: now)?.start ?? .distantFuture
            let right = b.nextOccurrence(after: now)?.start ?? .distantFuture
            return (left, a.name) < (right, b.name)
        }
    }

    private func hoursRow(name: String, site: UUID?) -> some View {
        let own = site.map { store.planning.hasOwnHours($0) } ?? true
        let hours = store.planning.hours(for: site)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                Text(own ? hours.summary : "Horaire par défaut")
                    .font(Theme.caption).foregroundStyle(own ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(hours.summary)
            }
            Spacer(minLength: 4)
            Button { mode = .hours(site) } label: { Image(systemName: "pencil") }
                .buttonStyle(MonCompactButtonStyle(height: 24))
                .help("Modifier les heures ouvrables de \(name)")
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    /// Horaire par défaut : sondes sans site et sites sans horaire propre (un menu en ajoute un).
    private var defaultHoursRow: some View {
        let others = sites.sortedSites.filter { !store.planning.hasOwnHours($0.id) }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sites.sites.isEmpty ? "Toutes les sondes" : "Par défaut").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(store.planning.defaultHours.summary)
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                if !others.isEmpty {
                    Text((others.count == sites.sites.count ? "Tous les sites" : "Autres sites") + "\u{00A0}: "
                         + others.map(\.displayName).joined(separator: ", "))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                        .help(others.map(\.displayName).joined(separator: "\n"))
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Modifier l’horaire par défaut…") { mode = .hours(nil) }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { site in
                        Button("Horaire propre à «\u{00A0}\(site.displayName)\u{00A0}»…") { mode = .hours(site.id) }
                    }
                }
            } label: {
                Image(systemName: "pencil")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Modifier l’horaire par défaut, ou donner un horaire propre à un site")
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    private func windowRow(_ window: MonMaintenanceWindow) -> some View {
        let now = store.now
        let current = window.occurrence(containing: now)
        let next = window.nextOccurrence(after: now)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { window.isEnabled }, set: { on in
                var copy = window
                copy.isEnabled = on
                store.saveWindow(copy)
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(window.name).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(window.isEnabled ? Theme.text : Theme.textSecondary)
                    if current != nil { RegPill(text: "En cours", tone: .accent) }
                }
                Text(window.rhythmLabel() + " · " + scopeLabel(window))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                    .help(window.note.isEmpty ? window.rhythmLabel() : window.note)
                Text(statusLabel(window, current: current, next: next, now: now))
                    .font(Theme.caption).foregroundStyle(current != nil ? Theme.accentStrong : Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Modifier…") { mode = .window(window) }
                Divider()
                Button("Supprimer", role: .destructive) { store.deleteWindow(window.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { mode = .window(window) }
    }

    private func scopeLabel(_ window: MonMaintenanceWindow) -> String {
        if !window.probeIDs.isEmpty {
            let names = window.probeIDs.compactMap { store.probe($0)?.name }
            return names.count == 1 ? names[0] : "\(names.count) sondes"
        }
        return window.siteID.map { store.siteName($0) } ?? "Tous les sites"
    }

    private func statusLabel(_ window: MonMaintenanceWindow, current: DateInterval?, next: DateInterval?, now: Date) -> String {
        if !window.isEnabled { return "Désactivée" }
        if let current { return "Jusqu’à " + MonPlanningFormat.moment(current.end, now: now) + "\u{00A0}: alertes suspendues" }
        if let next { return "Prochaine\u{00A0}: " + MonPlanningFormat.moment(next.start, now: now) }
        return "Terminée"
    }

    /// Nouvelle fenêtre : ce soir à 22 h, 2 h, pour le site actif.
    private func newWindow() -> MonMaintenanceWindow {
        let calendar = Calendar.current
        var start = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: store.now) ?? store.now
        if start <= store.now { start = calendar.date(byAdding: .day, value: 1, to: start) ?? start }
        return MonMaintenanceWindow(name: "", start: start, durationMinutes: 120, siteID: sites.activeID)
    }
}

enum MonPlanningFormat {
    /// « 17 h 00 », « demain 2 h 00 », « dim. 8 nov. 2 h 00 ».
    static func moment(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .day, .month, .weekday], from: date)
        let time = "\(parts.hour ?? 0)\u{00A0}h\u{00A0}" + String(format: "%02d", parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain " + time
        }
        let months = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juill.", "août", "sept.", "oct.", "nov.", "déc."]
        let day = MonBusinessHours.shortNames[((parts.weekday ?? 1) - 1 + 7) % 7]
        return "\(day) \(parts.day ?? 1) \(months[max(1, min(12, parts.month ?? 1)) - 1]) " + time
    }
}

// MARK: - Éditeur des heures ouvrables

/// Heures ouvrables d'un site, jour par jour (lundi d'abord), par demi-heure.
struct MonHoursEditor: View {
    let site: UUID?
    let close: () -> Void
    @ObservedObject private var store = MonStore.shared
    @State private var hours: MonBusinessHours

    init(site: UUID?, close: @escaping () -> Void) {
        self.site = site
        self.close = close
        _hours = State(initialValue: MonStore.shared.planning.hours(for: site))
    }

    var body: some View {
        HStack(spacing: 8) {
            MonHeading("Heures ouvrables")
            Text(site.map { store.siteName($0) } ?? "Par défaut")
                .font(Theme.bodySemibold).lineLimit(1)
            Spacer(minLength: 0)
        }
        VStack(spacing: 4) {
            ForEach(MonBusinessHours.displayOrder, id: \.self) { index in dayRow(index) }
        }
        Text(hours.summary)
            .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        Text("Les sondes en «\u{00A0}Heures ouvrables du site\u{00A0}» n’alertent que pendant ces heures (ou en dehors, pour «\u{00A0}Hors heures ouvrables\u{00A0}»)\u{00A0}; elles tournent toujours.")
            .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        HStack(spacing: 6) {
            if let site, store.planning.hasOwnHours(site) {
                Button("Horaire par défaut") {
                    store.setHours(nil, site: site)
                    close()
                }
                .buttonStyle(.secondary)
                .help("Retirer l’horaire propre à ce site")
            }
            Spacer(minLength: 0)
            Button("Annuler", action: close)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button("Enregistrer") {
                store.setHours(hours, site: site)
                close()
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func dayRow(_ index: Int) -> some View {
        let day = hours.days[index]
        return HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { hours.days[index].isOpen }, set: { hours.days[index].isOpen = $0 })) {
                Text(MonBusinessHours.longNames[index]).font(Theme.small).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .frame(width: 92, alignment: .leading)
            if day.isOpen {
                timePicker(Binding(get: { hours.days[index].start }, set: { value in
                    hours.days[index] = MonDayHours(isOpen: true, start: value, end: max(hours.days[index].end, value + 30))
                }), choices: MonBusinessHours.choices.filter { $0 < 1_440 })
                Text("à").font(Theme.small).foregroundStyle(Theme.textSecondary)
                timePicker(Binding(get: { hours.days[index].end }, set: { value in
                    hours.days[index] = MonDayHours(isOpen: true, start: hours.days[index].start, end: value)
                }), choices: MonBusinessHours.choices.filter { $0 > day.start })
            } else {
                Text("Fermé").font(Theme.small).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }

    private func timePicker(_ value: Binding<Int>, choices: [Int]) -> some View {
        Picker("Heure", selection: value) {
            ForEach(choices, id: \.self) { Text(MonBusinessHours.time($0)).tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

// MARK: - Éditeur d'une fenêtre de maintenance

struct MonWindowEditor: View {
    let isNew: Bool
    let close: () -> Void
    @ObservedObject private var store = MonStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @State private var window: MonMaintenanceWindow
    @State private var confirmDelete = false

    init(window: MonMaintenanceWindow, isNew: Bool, close: @escaping () -> Void) {
        self.isNew = isNew
        self.close = close
        _window = State(initialValue: window)
    }

    var body: some View {
        HStack(spacing: 8) {
            MonHeading(isNew ? "Nouvelle maintenance" : "Fenêtre de maintenance")
            Spacer(minLength: 0)
        }
        field("Nom") {
            MonInput(placeholder: "Mises à jour FortiOS", text: $window.name)
        }
        HStack(alignment: .top, spacing: 8) {
            field("Début") {
                DatePicker("Début", selection: $window.start, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .environment(\.locale, Locale(identifier: "fr_CA"))
                    .fixedSize()
            }
            field("Durée") {
                MonMenuField(title: MonMaintenanceWindow.durationLabel(window.durationMinutes)) {
                    ForEach(MonMaintenanceWindow.durations, id: \.self) { minutes in
                        Button(MonMaintenanceWindow.durationLabel(minutes)) { window.durationMinutes = minutes }
                    }
                }
            }
        }
        field("Répétition") {
            Picker("Répétition", selection: $window.repeats) {
                Text("Une fois").tag(MonMaintenanceRepeat.once)
                Text("Jour").tag(MonMaintenanceRepeat.daily)
                Text("Semaine").tag(MonMaintenanceRepeat.weekly)
                Text("Mois").tag(MonMaintenanceRepeat.monthly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if window.repeats != .once {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { window.until != nil }, set: { on in
                    window.until = on ? Calendar.current.date(byAdding: .month, value: 3, to: window.start) : nil
                })) { Text("Jusqu’au").font(Theme.small) }
                .toggleStyle(.checkbox)
                if let until = window.until {
                    DatePicker("Jusqu’au", selection: Binding(get: { until }, set: { window.until = $0 }), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .environment(\.locale, Locale(identifier: "fr_CA"))
                        .fixedSize()
                } else {
                    Text("sans fin").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        Text(window.rhythmLabel() + (nextLabel.map { ". Prochaine\u{00A0}: " + $0 + "." } ?? "."))
            .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        field("Sondes visées") {
            MonMenuField(title: scopeTitle) {
                Button("Toutes les sondes de tous les sites") {
                    window.siteID = nil
                    window.probeIDs = []
                }
                ForEach(sites.sortedSites) { site in
                    Button("Toutes les sondes de «\u{00A0}\(site.displayName)\u{00A0}»") {
                        window.siteID = site.id
                        window.probeIDs = []
                    }
                }
                Divider()
                Menu("Sondes choisies") {
                    ForEach(store.probes) { probe in
                        Toggle(probe.name, isOn: Binding(get: { window.probeIDs.contains(probe.id) }, set: { on in
                            if on { window.probeIDs.append(probe.id) } else { window.probeIDs.removeAll { $0 == probe.id } }
                        }))
                    }
                }
            }
        }
        field("Note (facultative)") {
            MonInput(placeholder: "Redémarrages prévus, technicien sur place…", text: $window.note)
        }
        Text("Pendant la fenêtre, les sondes visées continuent de tourner\u{00A0}; leurs alertes sont suspendues et notées au journal, et ces vérifications ne comptent pas dans la disponibilité. Un problème qui dure après la fenêtre alerte normalement.")
            .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        HStack(spacing: 6) {
            if !isNew {
                Button { confirmDelete = true } label: { Image(systemName: "trash").foregroundStyle(Theme.critical) }
                    .buttonStyle(MonCompactButtonStyle(height: 28))
                    .help("Supprimer la fenêtre")
            }
            Spacer(minLength: 0)
            Button("Annuler", action: close)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Planifier" : "Enregistrer") {
                store.saveWindow(window)
                close()
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog("Supprimer la fenêtre «\u{00A0}\(window.name)\u{00A0}»\u{00A0}?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) {
                store.deleteWindow(window.id)
                close()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les notes déjà inscrites au journal restent.")
        }
    }

    private var nextLabel: String? {
        guard let next = window.nextOccurrence(after: store.now) else { return nil }
        return MonPlanningFormat.moment(next.start, now: store.now)
    }

    private var scopeTitle: String {
        if !window.probeIDs.isEmpty {
            let names = window.probeIDs.compactMap { store.probe($0)?.name }
            return names.count == 1 ? names[0] : "\(names.count) sondes choisies"
        }
        return window.siteID.map { "Toutes les sondes de «\u{00A0}\(store.siteName($0))\u{00A0}»" } ?? "Toutes les sondes de tous les sites"
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
