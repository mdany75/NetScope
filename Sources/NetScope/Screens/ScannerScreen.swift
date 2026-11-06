import NetScopeCore
import SwiftUI

/// Écran principal « Scanner » (croquis docs/croquis/Main.dc.html) : plages à scanner,
/// résultats en direct dans un tableau trié, détail de l'appareil sélectionné.
struct ScannerScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var scan = ScanController.shared
    @ObservedObject private var prefs = RegPrefs.shared
    @State private var filter = ScanFilter()
    /// Tableau standard des résultats (colonnes et tri retenus, note 8).
    @StateObject private var table = ScanDeviceTable.makeModel()

    /// Panneau de détail un peu plus étroit que le croquis (340, qui le laisse rétrécir), pour laisser
    /// au tableau la place de ses colonnes essentielles à 1440 × 900.
    static let detailWidth: CGFloat = 320
    /// Filtres (deux lignes), en-tête, huit lignes (36 pt au plus) et pied.
    static let resultsMinHeight: CGFloat = 480

    /// Hauteur mesurée du panneau des plages (pour donner le reste de la hauteur aux résultats).
    @State private var rangesHeight: CGFloat = 0

    var body: some View {
        // L'écran défile lui-même, verticalement seulement : en fenêtre basse, la barre de défilement
        // verticale prend sa place dans la largeur au lieu de provoquer un défilement horizontal de
        // toute la page. Quand tout tient, rien ne défile et les résultats prennent la hauteur restante.
        GeometryReader { geometry in
            let padding: CGFloat = 16
            let spacing: CGFloat = 14
            let remaining = geometry.size.height - 2 * padding - spacing - rangesHeight
            ScrollView(.vertical) {
                VStack(spacing: spacing) {
                    ScanRangesPanel(scan: scan)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rangesHeight = $0 }
                    SidePanelSplit(sideWidth: Self.detailWidth, scrolls: false, title: "Détail de l’appareil") {
                        ScanResultsPanel(scan: scan, filter: $filter, table: table)
                    } side: {
                        ScanDetailPanel(scan: scan)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    // Fenêtre basse : le tableau garde au moins huit lignes visibles ; l’écran défile.
                    .frame(height: max(Self.resultsMinHeight, remaining))
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, padding)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .screenToolbar { toolbar }
        .vlanScanPrompt()
        // Passerelle et DNS de la barre latérale : lus sur la machine, sans trafic.
        .task(id: state.activeInterface.map { "\($0.name) \($0.subnet)" }) { scan.fillLocalInfo(state) }
        .onAppear {
            let filter = $filter, table = table, state = state, scan = scan
            ScanController.displayedRows = {
                ScanResultsPanel.visibleRows(state: state, scan: scan, filter: filter.wrappedValue, sortOrder: table.sortOrder)
            }
        }
    }

    @ViewBuilder private var toolbar: some View {
        Button { scan.start(state) } label: { Label("Lancer le scan", systemImage: "play.fill") }
            .buttonStyle(.primary)
            .disabled(scan.isRunning)
            .opacity(scan.isRunning ? 0.55 : 1)
            // Raccourcis (⌘R, ⌘.) : menu Scan, réglables dans Réglages › Raccourcis.
            .help(RegShortcutStore.shared.combo(ShortcutID.startScan).map { "Lancer le scan (\($0.display))" } ?? "Lancer le scan")
        Button { scan.stop() } label: { Label("Arrêter", systemImage: "stop.fill") }
            .buttonStyle(.secondary)
            .disabled(!scan.isBusy)
            .opacity(scan.isBusy ? 1 : 0.55)
            .help(scan.portProbe != nil ? "Arrêter la sonde des ports" : "Arrêter le scan")
        Button { scan.clear(state) } label: { Image(systemName: "trash").accessibilityLabel("Effacer") }
            .buttonStyle(.secondary)
            .disabled(state.devices.isEmpty && !scan.isRunning)
            .help("Effacer les résultats du scan")
        profileMenu
        portsMenu
        // Note 90 : scanner un autre VLAN par une interface 802.1Q temporaire.
        Button { VLANScanModel.shared.isPresented = true } label: { Label("VLAN tagué…", systemImage: "point.3.connected.trianglepath.dotted") }
            .buttonStyle(.secondary)
            .disabled(scan.isRunning)
            .help("Scanner un VLAN tagué depuis ce Mac (port en trunk), sans changer de port")
        Button { scan.export(exportRows, state: state) } label: { Label("Exporter", systemImage: "square.and.arrow.down") }
            .buttonStyle(.secondary)
            .disabled(state.devices.isEmpty)
            .help(prefs.exportFormat == .csv ? "Exporter les appareils affichés en CSV" : ScanController.exportHelp)
    }

    /// Appareils affichés (filtres et tri du tableau), pour l'export.
    private var exportRows: [Device] {
        ScanResultsPanel.visibleRows(state: state, scan: scan, filter: filter, sortOrder: table.sortOrder)
    }

    /// « Profil : Rapide ▾ » : un menu plutôt qu'un popover, pour qu'il reste utilisable quand macOS
    /// le range dans le menu de débordement (») de la barre d'outils (petite fenêtre).
    private var profileMenu: some View {
        Menu {
            Section("Profil de scan") {
                ForEach(ScanProfile.allCases) { profile in
                    Toggle(isOn: Binding(get: { state.scanProfile == profile }, set: { _ in
                        state.scanProfile = profile
                        // Choisir un profil reprend ses ports ; le menu « Ports » permet ensuite d'en changer.
                        scan.portPresetProfile = profile
                    })) {
                        Text(profile.label)
                        Text(profile.summary)
                    }
                }
            }
            Divider()
            Button("Modifier les ports personnalisés…") {
                RegNavigation.shared.section = .profils
                state.open(.reglages)
            }
        } label: {
            Label("Profil\u{00A0}: \(state.scanProfile.label)", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
        .help(state.scanProfile.summary)
    }

    /// « Ports : 22 essentiels ▾ » (note 19) : préréglages des Réglages, coche sur celui en vigueur.
    private var portsMenu: some View {
        let current = scan.portPreset
        let online = exportRows.filter(\.isOnline)
        return Menu {
            Section("Préréglage de ports") {
                ForEach(scan.portPresets) { preset in
                    Toggle(preset.label, isOn: Binding(get: { preset.profile == current.profile },
                                                       set: { _ in scan.portPresetProfile = preset.profile }))
                }
            }
            Divider()
            Button("Rescanner les ports avec ce préréglage (\(online.count) en ligne)") {
                scan.probePorts(of: online, preset: current, state: state)
            }
            .disabled(scan.isBusy || online.isEmpty)
            Button("Modifier les préréglages…") {
                RegNavigation.shared.section = .profils
                state.open(.reglages)
            }
        } label: {
            Text("Ports\u{00A0}: \(current.shortLabel)")
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
        .help("Ports TCP sondés par le prochain scan (\(PortPreset.count(current.ports.count)))")
    }
}
