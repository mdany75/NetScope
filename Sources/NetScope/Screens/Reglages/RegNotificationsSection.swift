import NetScopeCore
import SwiftUI

/// Réglages › Notifications (croquis Reglages.dc.html, section « Notifications ») : événements
/// signalés, canaux (Centre de notifications, son, regroupement), heures de silence, notification
/// de test et état de l'autorisation macOS. Les décisions passent par `NotificationPolicy`.
struct RegNotificationsSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = RegNotifStore.shared
    /// Largeur de la liste des derniers événements (décision à droite ou sous le détail).
    @State private var listWidth: CGFloat = 900

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RegPanel(title: "Notifications", subtitle: "Événements signalés pendant les scans et la surveillance.") {
                HStack(spacing: 8) {
                    authorizationPill
                    Button("Valeurs par défaut") { store.reset() }
                        .buttonStyle(RegSmallButtonStyle())
                        .regDisabled(store.settings == NotificationSettings())
                        .help("Remet tous les réglages des notifications à leurs valeurs d’origine")
                }
                .fixedSize()
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    authorizationNotice
                        .padding(.bottom, 8)
                    ForEach(NetScopeEventKind.configurable) { kind in
                        eventRow(kind)
                    }
                    AdaptiveStack(breakpoint: 640, spacing: 14, horizontalAlignment: .top) {
                        channelsBox
                        quietBox
                    }
                    .padding(.top, 10)
                }
            }
            RegPanel(title: "Derniers événements",
                     subtitle: "Ce que NetScope a reçu depuis son lancement et ce qui en a été fait (le plus récent en haut).") {
                recentList
            }
        }
        .onAppear { MonNotifier.shared.refreshAuthorization() }
    }

    // MARK: Autorisation macOS

    @ViewBuilder private var authorizationPill: some View {
        switch store.authorization {
        case .authorized: RegPill(text: "Autorisées par macOS", tone: .success)
        case .denied: RegPill(text: "Refusées par macOS", tone: .critical)
        case .notDetermined: RegPill(text: "Autorisation à demander", tone: .warning)
        case .unavailable: RegPill(text: "Indisponibles ici", tone: .neutral)
        case .unknown: EmptyView()
        }
    }

    @ViewBuilder private var authorizationNotice: some View {
        switch store.authorization {
        case .denied:
            RegNotice(text: "macOS refuse les notifications de NetScope\u{00A0}: rien ne s’affiche. Autorisez-les dans Réglages Système › Notifications › NetScope.",
                      tone: .critical) {
                Button("Ouvrir Réglages Système") { store.openSystemSettings() }
                    .buttonStyle(.secondary)
            }
        case .notDetermined:
            RegNotice(text: "macOS demandera l’autorisation à la première notification. Vous pouvez la demander dès maintenant.",
                      tone: .warning) {
                Button("Autoriser…") { MonNotifier.shared.requestAuthorization() }
                    .buttonStyle(.secondary)
            }
        case .unavailable:
            RegNotice("Notifications indisponibles\u{00A0}: NetScope n’est pas lancé depuis l’app installée (.app). Les réglages s’appliqueront à l’app installée.",
                      tone: .neutral)
        case .authorized, .unknown:
            EmptyView()
        }
    }

    // MARK: Événements

    private func eventRow(_ kind: NetScopeEventKind) -> some View {
        let severity = kind.defaultSeverity
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(kind.label).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Chip(text: severity.tag, tone: Self.tone(severity))
                }
                Text(kind.explanation).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RegSwitch(isOn: Binding(get: { store.isEnabled(kind) }, set: { store.set(kind, enabled: $0) }))
                .accessibilityLabel(kind.label)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    static func tone(_ severity: NetScopeEventSeverity) -> Tone {
        switch severity {
        case .critical: return .critical
        case .warning: return .warning
        case .success: return .success
        case .info: return .accent
        }
    }

    // MARK: Canaux

    private var channelsBox: some View {
        box("Canaux") {
            compactToggle("Centre de notifications macOS", detail: "Bannières et historique.", isOn: $store.settings.bannersEnabled)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Son").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(soundDetail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RegSegmented(selection: $store.settings.sound,
                                 options: NotificationSound.allCases.map { .init(value: $0, label: $0.label) })
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
            compactToggle("Regrouper les rafales",
                          detail: "Au-delà de \(store.settings.groupBurst) événements du même type en \(Int(store.settings.groupWindow / 60))\u{00A0}min, une seule notification résume les suivants.",
                          isOn: $store.settings.grouping)
            // Autres canaux (courriel, webhook) : ils reçoivent les mêmes événements (NetScopeEventCenter).
        }
    }

    private var soundDetail: String {
        switch store.settings.sound {
        case .off: return "Jamais de son."
        case .critical: return "Événements critiques, et sondes réglées avec le son."
        case .all: return "À chaque notification."
        }
    }

    // MARK: Heures de silence

    private var quietBox: some View {
        box("Plages horaires") {
            compactToggle("Ne pas déranger", detail: quietDetail, isOn: $store.settings.quietHours.isEnabled)
            HStack(spacing: 8) {
                Text("De").font(Theme.small).foregroundStyle(Theme.textSecondary)
                timePicker($store.settings.quietHours.start, label: "Début de la période sans notification")
                Text("à").font(Theme.small).foregroundStyle(Theme.textSecondary)
                timePicker($store.settings.quietHours.end, label: "Fin de la période sans notification")
                Spacer(minLength: 0)
            }
            .regDisabled(!store.settings.quietHours.isEnabled)
            .padding(.bottom, 4)
            compactToggle("Les événements critiques passent outre",
                          detail: "Conflit d’adresse IP, DHCP non autorisé, sonde en panne.",
                          isOn: $store.settings.criticalBypassQuietHours)
                .regDisabled(!store.settings.quietHours.isEnabled)
            VStack(alignment: .leading, spacing: 6) {
                Button("Envoyer une notification de test") {
                    store.testMessage = MonNotifier.shared.postTest()
                }
                .buttonStyle(.secondary)
                if let message = store.testMessage {
                    Text(message).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        }
    }

    private var quietDetail: String {
        let quiet = store.settings.quietHours
        guard quiet.isEnabled else { return "Aucune période de silence." }
        guard quiet.durationMinutes > 0 else { return "Début et fin identiques\u{00A0}: aucune période de silence." }
        let hours = quiet.durationMinutes / 60, minutes = quiet.durationMinutes % 60
        let length = minutes == 0 ? "\(hours)\u{00A0}h" : "\(hours)\u{00A0}h\u{00A0}\(String(format: "%02d", minutes))"
        let overnight = quiet.end < quiet.start ? ", par-dessus minuit" : ""
        return "Silence de \(quiet.start.text) à \(quiet.end.text) (\(length)\(overnight))."
    }

    /// Champ d'heure natif (24 h).
    private func timePicker(_ value: Binding<DayMinute>, label: String) -> some View {
        let calendar = Calendar.current
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let binding = Binding<Date>(
            get: { calendar.date(byAdding: .minute, value: value.wrappedValue.minutes, to: reference) ?? reference },
            set: { value.wrappedValue = DayMinute.of($0, calendar: calendar) })
        return DatePicker("", selection: binding, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .controlSize(.small)
            .environment(\.locale, RegFormat.timeLocale)
            .fixedSize()
            .accessibilityLabel(label)
    }

    // MARK: Derniers événements

    @ViewBuilder private var recentList: some View {
        if store.log.isEmpty {
            Text("Aucun événement depuis le lancement de NetScope.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(store.log.prefix(8)) { entry in
                    recentRow(entry)
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        }
    }

    private func recentRow(_ entry: RegNotifStore.LogEntry) -> some View {
        let outcome = Self.outcome(entry.decision)
        let label = Label(outcome.text, systemImage: outcome.symbol)
            .font(Theme.small)
            .foregroundStyle(outcome.tone == .neutral ? Theme.textSecondary : outcome.tone.foreground)
            .lineLimit(1)
            .fixedSize()
        let texts = VStack(alignment: .leading, spacing: 1) {
            Text(entry.event.title).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
            Text(entry.event.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.moment(entry.event.date))
                .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                .frame(width: 118, alignment: .leading)
            Chip(text: entry.event.severity.tag, tone: Self.tone(entry.event.severity))
                .frame(width: 70, alignment: .leading)
            // Fenêtre étroite : la décision passe sous le détail au lieu de pousser la ligne.
            if listWidth >= 620 {
                texts.frame(maxWidth: .infinity, alignment: .leading)
                label
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    texts
                    label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    /// « aujourd’hui 13:46 », « hier 23:14 » ou « 2 nov. 23:14 » (tient dans la colonne).
    static func moment(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) { return RegFormat.moment(date) }
        let locale = Locale(identifier: "fr_FR")
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        return "\(day) \(time)"
    }

    static func outcome(_ decision: NotificationDecision) -> (text: String, symbol: String, tone: Tone) {
        switch decision {
        case .deliver(let delivery):
            if !delivery.banner { return ("Son seul", "speaker.wave.2", .neutral) }
            if delivery.groupedCount > 1 || delivery.identifier.hasPrefix("groupe-") {
                return ("Regroupée (\(delivery.groupedCount))", "square.stack", .accent)
            }
            return (delivery.sound ? "Envoyée avec son" : "Envoyée", delivery.sound ? "bell.and.waves.left.and.right" : "bell", .success)
        case .suppress(let reason):
            let symbol = reason == .quietHours ? "moon" : "bell.slash"
            return ("Non envoyée\u{00A0}: \(reason.label)", symbol, .neutral)
        }
    }

    // MARK: Petits éléments

    private func box<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RegLabel(title).padding(.bottom, 6)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func compactToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RegSwitch(isOn: isOn)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }
}
