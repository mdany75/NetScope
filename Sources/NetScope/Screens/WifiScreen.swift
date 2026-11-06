import NetScopeCore
import SwiftUI

/// Écran « Analyseur Wi-Fi » (croquis docs/croquis/Wifi.dc.html) : connexion actuelle (lecture
/// locale par CoreWLAN), occupation des canaux et réseaux voisins (analyse à la demande seulement),
/// recommandations, RSSI récent et relevé de couverture. Partie « FortiAP » (note 27) : bornes,
/// clients et diagnostic lus par les FortiGate des sites (FortiAPView).
struct WifiScreen: View {
    @ObservedObject private var store = WifiStore.shared
    @ObservedObject private var fortiAP = FortiAPStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @EnvironmentObject private var state: AppState
    /// Note 48 : sites montrés par le menu « Site ▾ » de la partie FortiAP.
    @ObservedObject private var scopes = SiteScopeStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Note 77 : contrôleurs UniFi, Omada et Meraki du site actif.
    @ObservedObject private var controllers = SiteControllerStore.shared
    /// Partie affichée ; captures : NETSCOPE_WIFI_VUE=fortiap (ou controleurs).
    @AppStorage("NetScope.wifi.partie") private var savedPart = WifiScreenPart.local.rawValue
    @State private var part: WifiScreenPart = FortiAPDemo.opensFortiAP ? .fortiap : (Self.opensControllers ? .controllers : .local)

    /// Captures : NETSCOPE_WIFI_VUE=controleurs ouvre la partie des contrôleurs.
    private static var opensControllers: Bool {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_WIFI_VUE"] == "controleurs"
    }

    /// La partie « Contrôleurs » n'est proposée que pour un site qui en a.
    private var showsControllers: Bool { !controllers.activeControllers.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let toast = store.toast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold))
                        Text(toast).font(Theme.small)
                        Spacer()
                        Button { store.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .buttonStyle(.plain)
                            .help("Fermer le message")
                    }
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
                }
                if let error = store.scanError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
                        Text("Analyse impossible\u{00A0}: \(error)").font(Theme.small)
                        Spacer()
                    }
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft))
                }

                partPicker
                if part == .fortiap {
                    FortiAPView()
                } else if part == .controllers {
                    ControllerWifiView()
                } else {
                WifiConnectionPanel(store: store)

                SidePanelSplit(sideWidth: 300, collapse: .below) {
                    VStack(spacing: 14) {
                        // Note 78 : en mode relevé, le relevé par pièce passe en tête.
                        if store.surveyActive { WifiRoomSurveyPanel(wifi: store) }
                        WifiChannelPanel(store: store)
                        WifiNetworksTable(store: store)
                        if !store.surveyActive { WifiRoomSurveyPanel(wifi: store) }
                        WifiBeaconPanel(store: store)
                    }
                } side: {
                    VStack(spacing: 14) {
                        // Note 78 : meilleur canal par bande et historique du signal jusqu'à 1 h.
                        WifiChannelAdvicePanel(store: store)
                        WifiSignalHistoryPanel(store: store)
                        WifiRecommendationsPanel(store: store)
                    }
                }
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Note 47 : captures (NETSCOPE_WIFI_DIAG), la feuille du diagnostic dessinée dans la page.
        .overlay(alignment: .top) { if part == .fortiap { WifiDiagnosisSnapshotOverlay() } }
        .onAppear {
            store.start()
            if !FortiAPDemo.opensFortiAP, !RegEnvironment.isSnapshot, let saved = WifiScreenPart(rawValue: savedPart) { part = saved }
            if part == .controllers, !showsControllers { part = .local }
            if fortiAP.focusAP != nil || fortiAP.openFortiAPPart {
                part = .fortiap
                fortiAP.openFortiAPPart = false
            }
        }
        // Note 34 : une borne demandée par un autre écran ouvre la partie FortiAP.
        .onChange(of: fortiAP.focusAP) { _, id in if id != nil { part = .fortiap } }
        // Note 46 : fiche d'un client ou SSID demandés (Retour, « Ouvrir dans › », fiche Appareil).
        .onChange(of: fortiAP.openFortiAPPart) { _, wanted in
            if wanted { part = .fortiap; fortiAP.openFortiAPPart = false }
        }
        .onDisappear {
            store.stop()
            // La fiche d'un client ne reste pas ouverte d'une visite à l'autre (Retour la rouvre).
            if !RegEnvironment.isSnapshot { fortiAP.closeClient() }
        }
        .onAppear { fortiAP.setScope(scopes.keys(for: .wifi)) }
        .onChange(of: scopes.keys(for: .wifi)) { _, keys in fortiAP.setScope(keys) }
        .onChange(of: sites.activeKey) { _, _ in
            fortiAP.setScope(scopes.keys(for: .wifi))
            // Note 77 : un site sans contrôleur ne garde pas la partie « Contrôleurs ».
            if part == .controllers, !showsControllers { part = .local }
        }
        .onChange(of: part) { _, value in
            guard !RegEnvironment.isSnapshot else { return }
            savedPart = value.rawValue
            if value == .local { fortiAP.closeClient() }
        }
        .screenToolbar {
            if part == .fortiap {
                fortiToolbar
            } else if part == .controllers {
                controllersToolbar
            } else {
                localToolbar
            }
        }
    }

    /// Choix de la partie : analyse locale (ce Mac) ou Wi-Fi géré par les FortiGate.
    private var partPicker: some View {
        HStack(spacing: 10) {
            Picker("Partie", selection: $part) {
                Text("Ce Mac (analyse locale)").tag(WifiScreenPart.local)
                Text("FortiAP (\(fortiAP.shownOverview.aps.count) borne\(fortiAP.shownOverview.aps.count > 1 ? "s" : ""))").tag(WifiScreenPart.fortiap)
                if showsControllers {
                    // Note 77 : bornes des contrôleurs UniFi, Omada et Meraki du site actif.
                    let count = controllers.readings.reduce(0) { $0 + $1.report.aps.count }
                    let kinds = Set(controllers.activeControllers.map(\.kind))
                    let name = kinds.count == 1 ? kinds.first!.shortLabel : "Contrôleurs"
                    Text("\(name) (\(count) borne\(count > 1 ? "s" : ""))").tag(WifiScreenPart.controllers)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            if part == .fortiap {
                // Note 48 : le Wi-Fi d'un autre site, ou de plusieurs, sans changer le site actif.
                SiteScopeMenu(screen: .wifi)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var fortiToolbar: some View {
        if let keys = fortiAP.scopeKeys {
            // Note 48 : sites choisis par le menu « Site ▾ » ; la lecture du site actif est dans son bandeau.
            let ids = keys.filter { $0 != sites.activeKey }.flatMap { sites.site(forKey: $0)?.fortiGateIDs ?? [] }
            let reading = !fortiAP.viewReading.isDisjoint(with: ids)
            Button { fortiAP.readForView(ids) } label: {
                Label(reading ? "Lecture…" : "Lire les bornes des sites", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.secondary)
            .disabled(ids.isEmpty || reading || !fortigate.isEnabled)
            .help("Relit, par l’API REST (HTTPS, lecture seule), les bornes des FortiGate des sites affichés. Le site actif ne change pas.")
        } else {
            activeFortiToolbar
        }
    }

    @ViewBuilder private var activeFortiToolbar: some View {
        HStack(spacing: 6) {
            Circle().fill(fortiAP.lastRefresh == nil ? Theme.textTertiary : Theme.accent).frame(width: 8, height: 8)
            Text(fortiAP.busy ? "Lecture des bornes…" : (fortiAP.lastRefresh.map { "Lu à \(WifiText.timeSeconds($0))" } ?? "Bornes non lues"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(fortiAP.lastRefresh == nil ? Theme.textSecondary : Theme.accentStrong)
        .fixedSize()
        Button { fortiAP.refreshNow(state: state) } label: {
            Label(fortiAP.busy ? "Lecture…" : "Relire les bornes", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.secondary)
        .disabled(fortiAP.busy || !fortiAP.canRefresh(state: state))
    }

    /// Note 77 : état et relecture des contrôleurs du site actif.
    @ViewBuilder private var controllersToolbar: some View {
        HStack(spacing: 6) {
            Circle().fill(controllers.lastRefresh == nil ? Theme.textTertiary : Theme.accent).frame(width: 8, height: 8)
            Text(controllers.isBusy ? "Lecture des contrôleurs…" : (controllers.lastRefresh.map { "Lu à \(WifiText.timeSeconds($0))" } ?? "Contrôleurs non lus"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(controllers.lastRefresh == nil ? Theme.textSecondary : Theme.accentStrong)
        .fixedSize()
        Button { controllers.refreshNow(state: state) } label: {
            Label(controllers.isBusy ? "Lecture…" : "Relire les contrôleurs", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.secondary)
        .disabled(controllers.isBusy || !(controllers.hasReadyControllers || controllers.isDemo))
        .help("Relit les contrôleurs UniFi, Omada et Meraki du site actif (HTTPS, lecture seule).")
    }

    @ViewBuilder private var localToolbar: some View {
            statusBadge
            Button { store.surveyActive.toggle() } label: {
                Label(store.surveyActive ? "Terminer le relevé" : "Relevé", systemImage: "figure.walk")
            }
            .buttonStyle(.secondary)
            Button { store.scan() } label: {
                HStack(spacing: 6) {
                    if store.isScanning {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                    }
                    Text(store.isScanning ? "Analyse…" : "Analyser")
                }
            }
            .buttonStyle(.primary)
            .disabled(store.isScanning || store.noInterface)
            .help("Balaye les canaux Wi-Fi une fois (quelques secondes). Rien n’est lancé automatiquement.")
            Button { store.exportCSV() } label: { Label("Exporter CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .disabled(store.networks.isEmpty)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(store.lastScan == nil ? Theme.textTertiary : Theme.accent).frame(width: 8, height: 8)
            Text(store.isScanning ? "Analyse en cours…" : (store.lastScan.map { "Dernière analyse\u{00A0}: \(WifiText.timeSeconds($0))" } ?? "Aucune analyse"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(store.lastScan == nil ? Theme.textSecondary : Theme.accentStrong)
        .fixedSize()
    }
}
