import NetScopeCore
import SwiftUI

/// Partie de l'écran Trafic.
enum TrafficPart: String, CaseIterable {
    case trafic, analyse
}

/// Onglet de la partie Trafic : une vue FortiView, ou l'état du WAN.
enum TrafficTab: Hashable {
    case view(TrafficView)
    case wan

    static let all: [TrafficTab] = TrafficView.allCases.map { .view($0) } + [.wan]

    var label: String {
        switch self {
        case .view(let view): return view.label
        case .wan: return "WAN"
        }
    }

    var symbol: String {
        switch self {
        case .view(let view): return view.symbol
        case .wan: return "network"
        }
    }

    init?(capture text: String) {
        switch text {
        case "wan": self = .wan
        case "sources": self = .view(.sources)
        case "destinations": self = .view(.destinations)
        case "applications": self = .view(.applications)
        case "categories", "web": self = .view(.webCategories)
        case "interfaces": self = .view(.interfaces)
        case "politiques": self = .view(.policies)
        case "sessions": self = .view(.sessions)
        case "menaces": self = .view(.threats)
        default: return nil
        }
    }
}

/// État d'affichage de l'écran Trafic (partie, onglet, feuille « Qui sature le lien ? »), gardé
/// d'une visite à l'autre.
@MainActor
final class TrafficScreenState: ObservableObject {
    static let shared = TrafficScreenState()

    @Published var part: TrafficPart
    @Published var tab: TrafficTab
    @Published var showSaturation = false

    init() {
        let requested = TrafficDemo.requestedView
        part = requested == "analyse" ? .analyse : .trafic
        tab = requested.flatMap(TrafficTab.init(capture:)) ?? .view(.sources)
        // Captures : la feuille est dessinée dans la page (overlay), jamais présentée.
        showSaturation = false
    }
}

/// Écran `Screen.trafic` (note 54, groupe Suivi) : trafic lu par FortiView sur la FortiGate de
/// chaque site (sources, destinations, applications, catégories web, interfaces, politiques,
/// sessions, menaces), charge des liens WAN, « Qui sature le lien ? » et « Analyse complète du
/// réseau ». Pas de croquis : disposition de l'Analyse (menu « Site ▾ », périodes, tuiles, tableaux
/// standard). Lecture seule par l'API REST ; rien n'est envoyé en démonstration ni en capture.
struct TraficScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = TrafficStore.shared
    @ObservedObject private var screen = TrafficScreenState.shared
    @ObservedObject private var scope = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    /// Observé pour que « Ajouter au rapport » passe tout de suite à « Dans le rapport ».
    @ObservedObject private var rapport = RapportModel.shared
    @State private var exportDocument: InvCSVDocument?
    @State private var exportName = "trafic.csv"
    @State private var exporting = false

    var body: some View {
        let overview = store.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(overview)
                if let toast = store.toast { TrafficToast(text: toast) { store.toast = nil } }
                ForEach(store.shownErrors, id: \.self) { message in
                    ToolNotice(tone: .critical, title: "Lecture du trafic impossible", message: message)
                }
                switch screen.part {
                case .trafic:
                    // Note 78 : sans FortiView, le trafic des ports relevé sur les switchs.
                    if showsFallback {
                        TraficSNMPFallback(keys: store.shownKeys, isReading: store.isBusy) {
                            screen.part = .analyse
                            store.runAnalysis(state: state)
                        }
                    } else if overview.isEmpty {
                        empty
                    } else {
                        TrafficSummaryTiles(overview: overview)
                        saturationBanner(overview)
                        TrafficLinksPanel(overview: overview)
                        tabs(overview)
                        notes(overview)
                    }
                case .analyse:
                    TrafficAnalysisView()
                }
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .screenToolbar { toolbar }
        .sheet(isPresented: $screen.showSaturation) {
            TrafficSaturationSheet(verdict: TrafficAnalysis.whoSaturates(store.overview, thresholds: store.thresholds))
                .environmentObject(state)
        }
        // Captures : la feuille « Qui sature le lien ? » dessinée dans la page.
        .overlay(alignment: .top) {
            if RegEnvironment.isSnapshot, TrafficDemo.requestedView == "saturation" {
                TrafficSaturationSheet(verdict: TrafficAnalysis.whoSaturates(store.overview, thresholds: store.thresholds))
                    .environmentObject(state)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel).shadow(radius: 18))
                    .padding(.top, 40)
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            store.attach(state)
            store.setScope(scope.keys(for: .trafic))
            store.loadDemoNow()
            store.refreshIfNeeded()
            if store.isDemo, screen.part == .analyse || TrafficDemo.requestedView == nil, store.analysis == nil {
                store.runAnalysis(state: state)
            }
        }
        .onChange(of: scope.keys(for: .trafic)) { _, keys in
            store.setScope(keys)
            store.loadDemoNow()
        }
        .onChange(of: sites.activeKey) { _, _ in store.setScope(scope.keys(for: .trafic)) }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: exportName) { result in
            if case .success(let url) = result { store.toast = "CSV enregistré\u{00A0}: \(url.lastPathComponent)" }
        }
    }

    /// Note 78 : FortiView non lu et historique des ports disponible : le secours SNMP est montré.
    private var showsFallback: Bool {
        screen.part == .trafic && (TraficSNMPFallback.forced || (store.overview.isEmpty && TraficSNMPFallback.hasData(keys: store.shownKeys)))
    }

    // MARK: Barre d'outils

    @ViewBuilder private var toolbar: some View {
        Button {
            store.addToReport()
        } label: {
            Label(store.isInReport ? "Dans le rapport" : "Ajouter au rapport", systemImage: store.isInReport ? "checkmark" : "doc.badge.plus")
        }
        .buttonStyle(.secondary)
        .disabled(store.isInReport)
        Button {
            store.refresh()
        } label: {
            Label("Relire", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.secondary)
        .disabled(store.isBusy || !store.canRefresh)
        .help(store.canRefresh ? "Relit FortiView sur les FortiGate des sites affichés (lecture seule, GET)"
              : "Aucune FortiGate prête pour ces sites\u{00A0}: Réglages › Switchs › Contrôleurs FortiGate.")
        Button {
            screen.part = .analyse
            store.runAnalysis(state: state)
        } label: {
            Label("Bilan de santé", systemImage: "stethoscope")
        }
        .buttonStyle(.secondary)
        .help("Bilan de santé du réseau, noté sur 100\u{00A0}: trafic, sécurité, santé (WAN, ports, Wi-Fi, DHCP) et inventaire")
        Button {
            screen.showSaturation = true
        } label: {
            Label("Qui sature le lien\u{00A0}?", systemImage: "gauge.with.dots.needle.100percent")
        }
        .buttonStyle(.primary)
        .disabled(store.overview.entries(.sources).isEmpty)
    }

    // MARK: En-tête

    /// Site, partie, période et source sur une ligne ; sur deux en petite fenêtre.
    private func header(_ overview: TrafficOverview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                SiteScopeMenu(screen: .trafic)
                partPicker
                periodPicker
                source(overview)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    SiteScopeMenu(screen: .trafic)
                    partPicker
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    periodPicker
                    source(overview)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var partPicker: some View {
        Picker("Partie", selection: $screen.part) {
            Text("Trafic").tag(TrafficPart.trafic)
            Text("Bilan de santé").tag(TrafficPart.analyse)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    @ViewBuilder private var periodPicker: some View {
        if screen.part == .trafic, !showsFallback {
            InvSegmented(options: TrafficPeriod.allCases.map { ($0, $0.label) }, selection: $store.period)
                .help("Temps réel\u{00A0}: sessions en cours. 5\u{00A0}min à 7\u{00A0}j\u{00A0}: historique de FortiView (journalisation sur disque, FortiAnalyzer ou FortiGate Cloud).")
        }
    }

    private func source(_ overview: TrafficOverview) -> some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                Text(sourceText(overview)).fixedSize()
                Text(shortSourceText(overview)).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .font(Theme.small).foregroundStyle(Theme.textSecondary)
            .help(sourceText(overview))
            if store.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private func sourceText(_ overview: TrafficOverview) -> String {
        if showsFallback { return "Compteurs des ports des switchs · \(store.sitesLabel)" }
        guard !overview.sites.isEmpty else { return "Aucune FortiGate lue" }
        return "FortiView · \(store.sitesLabel)" + (overview.readAt.map { " · lu \(ToolText.relative($0))" } ?? "")
    }

    private func shortSourceText(_ overview: TrafficOverview) -> String {
        if showsFallback { return "Compteurs des switchs" }
        return overview.readAt.map { "Lu \(ToolText.relative($0))" } ?? ""
    }

    // MARK: Contenu

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isBusy {
                ToolNotice(tone: .accent, title: "Lecture de FortiView…", message: "Sources, destinations, applications, menaces et sessions des FortiGate des sites affichés.")
            } else {
                ToolNotice(tone: .accent, title: "Aucun trafic à montrer",
                           message: fortigate.isConfigured
                           ? "Relisez les FortiGate des sites affichés. Le profil de l’administrateur API doit avoir les droits «\u{00A0}FortiView\u{00A0}» et «\u{00A0}Log & Report\u{00A0}» en lecture (System › Admin Profiles), en plus de «\u{00A0}WiFi & Switch Controller\u{00A0}». L’historique (5\u{00A0}min à 7\u{00A0}jours) demande la journalisation du trafic sur disque, FortiAnalyzer ou FortiGate Cloud."
                           : "Ajoutez la FortiGate du site dans Réglages › Switchs › Contrôleurs FortiGate. Donnez au profil de son administrateur API les droits «\u{00A0}FortiView\u{00A0}» et «\u{00A0}Log & Report\u{00A0}» en lecture pour lire le trafic.")
            }
            Button {
                screen.part = .analyse
                store.runAnalysis(state: state)
            } label: {
                Label("Bilan de santé sans le trafic", systemImage: "stethoscope")
            }
            .buttonStyle(.secondary)
            .fixedSize()
        }
    }

    @ViewBuilder private func saturationBanner(_ overview: TrafficOverview) -> some View {
        let verdict = TrafficAnalysis.whoSaturates(overview, thresholds: store.thresholds)
        if verdict.isSaturated {
            ToolNotice(tone: verdict.link?.level == .critical ? .critical : .warning, title: verdict.headline, message: verdict.advice) {
                Button("Qui sature le lien\u{00A0}?") { screen.showSaturation = true }
                    .buttonStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private func tabs(_ overview: TrafficOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                Picker("Vue", selection: $screen.tab) {
                    ForEach(TrafficTab.all, id: \.self) { tab in
                        Text(tabLabel(tab, overview)).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                HStack(spacing: 10) {
                    Text("Vue").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                    Picker("Vue", selection: $screen.tab) {
                        ForEach(TrafficTab.all, id: \.self) { tab in
                            Label(tabLabel(tab, overview), systemImage: tab.symbol).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            switch screen.tab {
            case .view(.sessions):
                TrafficSessionTable(rows: sessionRows(overview), multiSite: overview.isMultiSite) { tableTools(.sessions) }
            case .view(let view):
                TrafficEntryTable(view: view, rows: rows(view, overview), multiSite: overview.isMultiSite) { tableTools(view) }
                    .id(view)
            case .wan:
                TrafficWANSlot(overview: overview)
            }
        }
    }

    /// Tri et export, dans la barre au-dessus du tableau.
    private func tableTools(_ view: TrafficView) -> some View {
        HStack(spacing: 8) {
            if view != .sessions, view != .threats {
                Picker("Trier par", selection: $store.sort) {
                    ForEach(TrafficSort.allCases) { sort in
                        Text("Trier par " + sort.label.lowercased()).tag(sort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            Button {
                exportDocument = InvCSVDocument(text: store.csv(view))
                exportName = "trafic-\(view.rawValue)-\(InvFormat.day(Date())).csv"
                exporting = true
            } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .fixedSize()
        }
    }

    private func tabLabel(_ tab: TrafficTab, _ overview: TrafficOverview) -> String {
        switch tab {
        case .view(.threats):
            let count = overview.entries(.threats).count
            return count > 0 ? "Menaces (\(count))" : "Menaces"
        case .view(let view):
            return overview.statuses[view] == .refused ? view.label + " ⚠︎" : view.label
        case .wan:
            return tab.label
        }
    }

    private func rows(_ view: TrafficView, _ overview: TrafficOverview) -> [TrafficRow] {
        let linksBySite = Dictionary(grouping: overview.links, by: \.site)
        return overview.entries(view).map { entry in
            var ref: NavDeviceRef?
            var name = entry.name
            var accessPoint: String?
            if view == .sources || view == .threats {
                ref = store.deviceRef(ip: entry.ip, mac: entry.mac, name: entry.hostname ?? entry.name, site: entry.site, state: state)
                if store.siteKey(forLabel: entry.site) == sites.activeKey {
                    accessPoint = store.accessPointName(ip: entry.ip, mac: entry.mac, state: state)
                }
            }
            let location = ref.flatMap { r in r.switchName.map { $0 + (r.switchPort.map { " · " + $0 } ?? "") } }
            // Un appareil Wi-Fi (« FortiAP-231F · Wi-Fi ») n'a pas de port de switch : sa borne le dit.
            let wifiOnly = location?.hasSuffix("Wi-Fi") == true
            let link = view == .interfaces ? linksBySite[entry.site]?.first { $0.name == entry.key } : nil
            // Menace : `name` est l'appareil visé (colonne Appareil), la menace garde son nom.
            if view == .threats { name = ref.map { $0.name != $0.ip ? $0.name : (entry.hostname ?? $0.name) } ?? entry.hostname ?? entry.name }
            return TrafficRow(entry: entry, name: name, ref: ref,
                              location: wifiOnly ? nil : location,
                              accessPoint: accessPoint ?? (wifiOnly ? ref?.switchName : nil), link: link)
        }
    }

    private func sessionRows(_ overview: TrafficOverview) -> [TrafficSessionRow] {
        overview.sessions.map { session in
            let ref = store.deviceRef(ip: session.source, mac: nil, name: session.source?.description ?? "", site: session.site, state: state)
            return TrafficSessionRow(session: session, sourceName: ref?.name ?? session.source?.description ?? "—", ref: ref)
        }
    }

    @ViewBuilder private func notes(_ overview: TrafficOverview) -> some View {
        if !overview.notes.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(overview.notes, id: \.self) { note in
                        Text("• " + note).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Remarques de lecture (\(overview.notes.count))").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Message passager (CSV enregistré, section ajoutée au rapport).
struct TrafficToast: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold))
            Text(text).font(Theme.small)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .help("Fermer le message")
        }
        .foregroundStyle(Theme.success)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
    }
}
