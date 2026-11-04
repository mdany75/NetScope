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
    @State private var showProfiles = false

    var body: some View {
        VStack(spacing: 14) {
            ScanRangesPanel(scan: scan)
            SidePanelSplit(sideWidth: 360, scrolls: false, title: "Détail de l’appareil") {
                ScanResultsPanel(scan: scan, filter: $filter, table: table)
            } side: {
                ScanDetailPanel(scan: scan)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            // Fenêtre basse : le tableau garde quelques lignes visibles ; l'écran défile au besoin.
            .frame(minHeight: 340, maxHeight: .infinity)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenToolbar { toolbar }
        // Passerelle et DNS de la barre latérale : lus sur la machine, sans trafic.
        .task(id: state.activeInterface.map { "\($0.name) \($0.subnet)" }) { scan.fillLocalInfo(state) }
    }

    @ViewBuilder private var toolbar: some View {
        Button { scan.start(state) } label: { Label("Lancer le scan", systemImage: "play.fill") }
            .buttonStyle(.primary)
            .disabled(scan.isRunning)
            .opacity(scan.isRunning ? 0.55 : 1)
            .keyboardShortcut("r", modifiers: .command)
        Button { scan.stop() } label: { Label("Arrêter", systemImage: "stop") }
            .buttonStyle(.secondary)
            .disabled(!scan.isRunning)
            .opacity(scan.isRunning ? 1 : 0.55)
            .keyboardShortcut(".", modifiers: .command)
        Button { scan.clear(state) } label: { Image(systemName: "trash").accessibilityLabel("Effacer") }
            .buttonStyle(.secondary)
            .disabled(state.devices.isEmpty && !scan.isRunning)
            .help("Effacer les résultats du scan")
        Button { showProfiles.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Profil : \(state.scanProfile.label)")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
        }
        .buttonStyle(.secondary)
        .popover(isPresented: $showProfiles, arrowEdge: .bottom) {
            ScanProfilePicker(scan: scan) { showProfiles = false }
        }
        portsMenu
        Button { scan.exportCSV(exportRows) } label: { Label("Exporter", systemImage: "square.and.arrow.down") }
            .buttonStyle(.secondary)
            .disabled(state.devices.isEmpty)
            .help("Exporter les appareils affichés en CSV")
    }

    /// Appareils affichés (filtres et tri du tableau), pour l'export.
    private var exportRows: [Device] {
        ScanResultsPanel.visibleRows(state: state, scan: scan, filter: filter, sortOrder: table.sortOrder)
    }

    /// « Ports : 20 essentiels ▾ » (note 19) : préréglages des Réglages, coche sur celui en vigueur.
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
            .disabled(scan.isRunning || online.isEmpty)
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

/// Choix du profil de scan (menu du croquis : libellé et description).
struct ScanProfilePicker: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scan: ScanController
    let close: () -> Void

    @ObservedObject private var prefs = RegPrefs.shared

    private var portsValid: Bool { !prefs.tuning.ports.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ScanProfile.allCases) { profile in
                Button {
                    state.scanProfile = profile
                    // Choisir un profil reprend ses ports ; le menu « Ports » permet ensuite d'en changer.
                    scan.portPresetProfile = profile
                    if profile != .personnalise { close() }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.label)
                            .font(.system(size: 13, weight: state.scanProfile == profile ? .bold : .semibold))
                            .foregroundStyle(state.scanProfile == profile ? Theme.accentStrong : Theme.text)
                        Text(profile.summary).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ScanMenuItemStyle())
            }
            if state.scanProfile == .personnalise {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ports TCP").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    TextField("", text: $prefs.tuning.portsText, prompt: Text("22, 80, 8000-8010"))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(12))
                    if !portsValid {
                        Text("Liste invalide : ports de 1 à 65535, séparés par des virgules.")
                            .font(Theme.caption).foregroundStyle(Theme.critical)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(width: 270)
    }
}

/// Élément de menu : fond gris au survol.
struct ScanMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScanHoverRow(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct ScanHoverRow<Content: View>: View {
    let pressed: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 4).fill(pressed || hovering ? Theme.neutralSoft : Color.clear))
            .onHover { hovering = $0 }
    }
}
