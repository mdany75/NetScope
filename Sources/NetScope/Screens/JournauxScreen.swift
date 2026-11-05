import NetScopeCore
import SwiftUI

/// Sources montrées (choix segmenté de l'en-tête).
enum LogSourceChoice: String, CaseIterable, Identifiable {
    case all, syslog, trap, fortigate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Toutes"
        case .syslog: return "Syslog"
        case .trap: return "Traps"
        case .fortigate: return "FortiGate"
        }
    }

    var sources: Set<LogSource> {
        switch self {
        case .all: return Set(LogSource.allCases)
        case .syslog: return [.syslog]
        case .trap: return [.trap]
        case .fortigate: return [.fortigate]
        }
    }
}

/// État d'affichage de l'écran Journaux, gardé d'une visite à l'autre.
@MainActor
final class JournauxScreenState: ObservableObject {
    static let shared = JournauxScreenState()

    @Published var period: LogPeriod = .day
    @Published var customFrom: Date
    @Published var customTo: Date
    @Published var minimumSeverity: LogSeverity = .info
    @Published var sources: LogSourceChoice = .all
    @Published var grouped = true
    @Published var selection: Set<UUID> = []
    @Published var showOutage = false
    @Published var outageCenter: Date
    @Published var outageSpan: TimeInterval = 600

    private init() {
        let now = LogStore.shared.now
        customFrom = now.addingTimeInterval(-3600)
        customTo = now
        outageCenter = now.addingTimeInterval(-7 * 60)
        if LogStore.shared.isDemo {
            if let id = JournauxDemo.selectedID { selection = [id] }
            outageCenter = JournauxDemo.now.addingTimeInterval(-7 * 60)
            showOutage = false
        }
    }

    /// Filtre de l'en-tête (période, gravité, sources, sites montrés).
    func filter(now: Date, siteKeys: [String]) -> LogFilter {
        let from: Date
        let to: Date?
        if period == .custom {
            from = min(customFrom, customTo)
            to = max(customFrom, customTo)
        } else {
            from = now.addingTimeInterval(-(period.seconds ?? 86_400))
            to = nil
        }
        return LogFilter(from: from, to: to, minimumSeverity: minimumSeverity, sources: sources.sources, siteKeys: Set(siteKeys))
    }
}

/// Écran `Screen.journaux` (note 43, groupe Suivi, juste après Surveillance) : messages Syslog et
/// traps SNMP reçus par ce Mac, journaux d'événements lus sur la FortiGate, recherche par heure,
/// appareil, gravité et source, regroupement des répétitions, « Comprendre une coupure » et export
/// CSV. Un écran à part plutôt qu'un onglet de la Surveillance : le journal est un grand tableau qui
/// veut toute la largeur, sa propre recherche multiple (appareil:, gravite:, source:) et son menu
/// « Site ▾ » ; la Surveillance, déjà une page dense sans onglets, garde les sondes « Message
/// Syslog de gravité ≥ X » et « Trap reçue » qui lisent ce journal. Pas de croquis propre :
/// disposition du journal des alertes de la Surveillance et des tableaux du Trafic.
struct JournauxScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = LogStore.shared
    @ObservedObject private var screen = JournauxScreenState.shared
    @ObservedObject private var scope = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @StateObject private var table = LogTable.makeModel()
    @State private var exportDocument: InvCSVDocument?
    @State private var exporting = false
    @State private var confirmingClear = false

    static let sideWidth: CGFloat = 352

    var body: some View {
        let keys = scope.keys(for: .journaux)
        let filter = screen.filter(now: store.now, siteKeys: keys)
        let query = state.searchQuery(for: .journaux)
        let rows = store.rows(filter: filter, search: query, grouped: screen.grouped)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(keys)
                if screen.period == .custom { customRange }
                if let toast = store.toast { TrafficToast(text: toast) { store.toast = nil } }
                LogSummaryTiles(rows: rows, grouped: screen.grouped)
                SidePanelSplit(sideWidth: Self.sideWidth, collapse: .below, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.journal.isEmpty { emptyNotice }
                        LogTable(rows: rows, grouped: screen.grouped, multiSite: keys.count > 1, table: table,
                                 selection: $screen.selection) { date in openOutage(at: date) }
                        if let row = selectedRow(rows) {
                            LogDetailPanel(row: row) { openOutage(at: row.message.date) }
                        }
                    }
                } side: {
                    LogReceiversPanel(keys: keys, since: filter.from ?? store.now.addingTimeInterval(-86_400), until: filter.to)
                }
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .searchResults(rows.count, screen.grouped ? "ligne" : "message", screen.grouped ? "lignes" : "messages")
        .screenToolbar { toolbar(rows, keys: keys) }
        .sheet(isPresented: $screen.showOutage) {
            LogOutageSheet(siteKeys: Set(keys)).environmentObject(state)
        }
        // Captures : « Comprendre une coupure » dessiné dans la page.
        .overlay(alignment: .top) {
            if RegEnvironment.isSnapshot, JournauxDemo.requested == "coupure" {
                LogOutageSheet(siteKeys: Set(keys))
                    .environmentObject(state)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel).shadow(radius: 18))
                    .padding(.top, 30)
                    .padding(.bottom, 16)
            }
        }
        .onAppear { store.attach(state) }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "journaux-\(InvFormat.day(store.now)).csv") { result in
            if case .success(let url) = result { store.toast = "CSV enregistré\u{00A0}: \(url.lastPathComponent)" }
        }
        .confirmationDialog("Effacer le journal des sites affichés\u{00A0}?", isPresented: $confirmingClear) {
            Button("Effacer les messages", role: .destructive) { store.clear(siteKeys: Set(keys)) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les messages reçus et lus de «\u{00A0}\(scope.label(for: .journaux))\u{00A0}» sont retirés de NetScope. Les équipements et la FortiGate gardent leurs propres journaux.")
        }
    }

    private func selectedRow(_ rows: [LogRow]) -> LogRow? {
        guard screen.selection.count == 1, let id = screen.selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    private func openOutage(at date: Date) {
        screen.outageCenter = date
        screen.showOutage = true
    }

    // MARK: Barre d'outils

    @ViewBuilder private func toolbar(_ rows: [LogRow], keys: [String]) -> some View {
        LogListeningIndicator()
        Menu {
            Button {
                exportDocument = InvCSVDocument(text: store.csv(rows, grouped: screen.grouped))
                exporting = true
            } label: { Label("Exporter le tableau (CSV)…", systemImage: "square.and.arrow.down") }
                .disabled(rows.isEmpty)
            Button {
                let filter = screen.filter(now: store.now, siteKeys: keys)
                store.readFortiGate(keys: keys, since: filter.from ?? store.now.addingTimeInterval(-86_400), until: filter.to)
            } label: { Label("Lire les journaux de la FortiGate", systemImage: "arrow.clockwise") }
                .disabled(!store.canReadFortiGate(keys: keys) || store.isReadingFortiGate)
            Button { store.sendTest() } label: { Label("Envoyer un message d’essai à ce Mac", systemImage: "paperplane") }
                .disabled(!store.isListening)
            Divider()
            Button(role: .destructive) { confirmingClear = true } label: { Label("Effacer le journal…", systemImage: "trash") }
                .disabled(store.journal.isEmpty)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
        .help("Exporter, lire la FortiGate, envoyer un essai ou effacer le journal")
        Button {
            openOutage(at: selectedRow(rows)?.message.date ?? screen.outageCenter)
        } label: {
            Label("Comprendre une coupure", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.secondary)
        .help("Messages de tous les appareils autour d’une heure choisie, mis en ordre, avec les constats")
        Button {
            store.isListening ? store.stop() : store.start()
        } label: {
            Label(store.isListening ? "Arrêter la réception" : "Démarrer la réception",
                  systemImage: store.isListening ? "stop.fill" : "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.primary)
        .help(store.isListening ? "Ferme les ports Syslog et traps de ce Mac"
              : "Ouvre UDP\(store.syslogTCPEnabled ? " et TCP" : "") \(store.syslogPort) (Syslog) et UDP \(store.trapPort) (traps) sur ce Mac, jusqu’à l’arrêt automatique")
    }

    // MARK: En-tête

    private func header(_ keys: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                SiteScopeMenu(screen: .journaux)
                periodPicker
                severityMenu
                sourcePicker
                groupToggle
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    SiteScopeMenu(screen: .journaux)
                    periodPicker
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    severityMenu
                    sourcePicker
                    groupToggle
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var periodPicker: some View {
        InvSegmented(options: LogPeriod.allCases.map { ($0, $0.label) }, selection: $screen.period)
            .help("Période affichée\u{00A0}; «\u{00A0}Plage…\u{00A0}» pour choisir le début et la fin")
    }

    private var severityMenu: some View {
        Picker("Gravité", selection: $screen.minimumSeverity) {
            ForEach(LogSeverity.allCases) { severity in
                Text(severity == .debug ? "Toutes les gravités" : "Gravité " + severity.atLeastLabel).tag(severity)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Gravité minimale\u{00A0}: «\u{00A0}≥ Erreur\u{00A0}» montre les erreurs, messages critiques, alertes et urgences")
    }

    private var sourcePicker: some View {
        InvSegmented(options: LogSourceChoice.allCases.map { ($0, $0.label) }, selection: $screen.sources)
            .help("Source\u{00A0}: Syslog et traps reçus par ce Mac, ou journaux lus sur la FortiGate")
    }

    private var groupToggle: some View {
        Toggle("Regrouper les répétitions", isOn: $screen.grouped)
            .toggleStyle(.checkbox)
            .font(Theme.small)
            .fixedSize()
            .help("Messages identiques du même appareil réunis sur une ligne, avec leur nombre et la première fois")
    }

    private var customRange: some View {
        HStack(spacing: 10) {
            Text("Du").font(Theme.small).foregroundStyle(Theme.textSecondary)
            DatePicker("Du", selection: $screen.customFrom, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .fixedSize()
            Text("au").font(Theme.small).foregroundStyle(Theme.textSecondary)
            DatePicker("Au", selection: $screen.customTo, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var emptyNotice: some View {
        ToolNotice(tone: .accent, title: store.isListening ? "En attente des premiers messages" : "Aucun message pour l’instant",
                   message: store.isListening
                   ? "Réglez l’envoi des journaux sur les équipements vers ce Mac (commandes dans le panneau «\u{00A0}Récepteurs\u{00A0}»), ou envoyez un message d’essai depuis le menu Actions."
                   : "Démarrez la réception pour recevoir les messages Syslog et les traps SNMP des équipements sur ce Mac, ou lisez les journaux d’événements de la FortiGate (menu Actions). Rien n’est écouté tant que vous ne le demandez pas.")
    }
}

/// Indicateur de la barre d'outils : « En écoute · UDP 5514 et 1162 » ou « Réception arrêtée ».
struct LogListeningIndicator: View {
    @ObservedObject private var store = LogStore.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isListening ? Theme.successDot : Theme.neutralDot).frame(width: 8, height: 8)
            Text(text)
                .font(Theme.bodySemibold)
                .foregroundStyle(store.isListening ? Theme.text : Theme.textSecondary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.trailing, 6)
        .help(store.isListening ? "Récepteurs en écoute sur toutes les interfaces de ce Mac" : "Aucun port ouvert\u{00A0}: la réception démarre seulement à la demande")
    }

    private var text: String {
        guard store.isListening else { return "Réception arrêtée" }
        // « En écoute · UDP et TCP 5514, UDP 1162 ».
        var ports: [String] = []
        if store.syslogListening, store.syslogTCPListening {
            ports.append("UDP et TCP \(store.syslogPort)")
        } else if store.syslogListening {
            ports.append("UDP \(store.syslogPort)")
        } else if store.syslogTCPListening {
            ports.append("TCP \(store.syslogPort)")
        }
        if store.trapListening { ports.append("UDP \(store.trapPort)") }
        return "En écoute · " + ports.joined(separator: ", ")
    }
}

/// Cases de résumé : messages, graves, traps, appareils.
struct LogSummaryTiles: View {
    let rows: [LogRow]
    let grouped: Bool

    var body: some View {
        let total = rows.reduce(0) { $0 + $1.count }
        let severe = rows.filter { $0.message.severity.isAtLeast(.error) }.reduce(0) { $0 + $1.count }
        let traps = rows.filter { $0.message.source == .trap }.reduce(0) { $0 + $1.count }
        let devices = Set(rows.map { $0.message.siteKey + "|" + $0.message.host }).count
        let repeated = rows.filter { $0.count > 1 }.count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ToolStatTile(label: "Messages", value: "\(total)", detail: grouped && repeated > 0 ? "\(rows.count) lignes, \(repeated) regroupée\(repeated > 1 ? "s" : "")" : "dans la période")
            ToolStatTile(label: "Erreurs ou pire", value: "\(severe)", detail: "gravité ≥\u{00A0}Erreur",
                         valueColor: severe > 0 ? Theme.critical : Theme.text)
            ToolStatTile(label: "Traps SNMP", value: "\(traps)", detail: "reçues par ce Mac")
            ToolStatTile(label: "Appareils", value: "\(devices)", detail: "ont envoyé un message")
        }
    }
}
