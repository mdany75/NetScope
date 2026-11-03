import NetScopeCore
import SwiftUI

/// Écran principal « Scanner » (croquis docs/croquis/Main.dc.html) : plages à scanner,
/// résultats en direct dans un tableau trié, détail de l'appareil sélectionné.
struct ScannerScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var scan = ScanController.shared
    @State private var filter = ScanFilter()
    @State private var sortOrder = [KeyPathComparator(\Device.ip)]
    @State private var showProfiles = false

    var body: some View {
        VStack(spacing: 14) {
            ScanRangesPanel(scan: scan)
            HStack(alignment: .top, spacing: 14) {
                ScanResultsPanel(scan: scan, filter: $filter, sortOrder: $sortOrder)
                ScanDetailPanel(scan: scan)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenToolbar { toolbar }
        // Passerelle et DNS de la barre latérale : lus sur la machine, sans trafic.
        .task(id: state.activeInterface?.name) { scan.fillLocalInfo(state) }
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
        Button { scan.clear(state) } label: { Label("Effacer", systemImage: "trash") }
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
        Button { scan.exportCSV(exportRows) } label: { Label("Exporter", systemImage: "square.and.arrow.down") }
            .buttonStyle(.secondary)
            .disabled(state.devices.isEmpty)
            .help("Exporter les appareils affichés en CSV")
    }

    /// Appareils affichés (filtres et tri du tableau), pour l'export.
    private var exportRows: [Device] {
        ScanResultsPanel.visibleRows(state: state, scan: scan, filter: filter, sortOrder: sortOrder)
    }
}

/// Choix du profil de scan (menu du croquis : libellé et description).
struct ScanProfilePicker: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scan: ScanController
    let close: () -> Void

    private var portsValid: Bool { ScanProfile.parsePorts(scan.customPortsText).map { !$0.isEmpty } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ScanProfile.allCases) { profile in
                Button {
                    state.scanProfile = profile
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
                    TextField("", text: $scan.customPortsText, prompt: Text("22, 80, 8000-8010"))
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
