import AppKit
import NetScopeCore
import SwiftUI

/// Menus de NetScope (barre de menus) : Fichier (nouveau scan, exporter), Scan, Appareil, Aller,
/// Réglages… Les raccourcis viennent de Réglages › Raccourcis (`RegShortcutStore`) ; les menus
/// se mettent à jour dès qu'un raccourci change.
struct AppCommands: Commands {
    @ObservedObject var state: AppState
    @ObservedObject private var shortcuts = RegShortcutStore.shared
    @ObservedObject private var scan = ScanController.shared

    init(state: AppState) {
        self.state = state
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Réglages…") { AppActions.open(.reglages, state: state) }
                .regShortcut(ShortcutID.settings, shortcuts)
        }
        // NetScope n'a qu'une fenêtre principale : « Nouveau » lance un nouveau scan.
        CommandGroup(replacing: .newItem) {
            Button("Nouveau scan") { AppActions.newScan(state) }
                .regShortcut(ShortcutID.newScan, shortcuts)
                .disabled(scan.isRunning)
        }
        CommandGroup(replacing: .importExport) {
            Button("Exporter les résultats du scan…") { AppActions.export(state) }
                .regShortcut(ShortcutID.export, shortcuts)
                .disabled(state.filteredDevices.isEmpty)
        }
        // Pas d'impression générale (le rapport s'imprime depuis l'écran Rapports).
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .textEditing) {
            Button("Rechercher partout") { AppActions.focusSearch() }
                .regShortcut(ShortcutID.search, shortcuts)
        }

        CommandMenu("Scan") {
            Button("Lancer le scan") { AppActions.startScan(state) }
                .regShortcut(ShortcutID.startScan, shortcuts)
                .disabled(scan.isRunning)
            Button(scan.portProbe != nil ? "Arrêter la sonde des ports" : "Arrêter le scan") { scan.stop() }
                .regShortcut(ShortcutID.stopScan, shortcuts)
                .disabled(!scan.isBusy)
            Divider()
            Button("Rescanner les ports de la sélection") { AppActions.rescanSelection(state) }
                .regShortcut(ShortcutID.rescanSelection, shortcuts)
                .disabled(state.selectedDevice == nil || scan.isBusy)
            Button("Changer de profil (\(state.scanProfile.label))") { AppActions.nextProfile(state) }
                .regShortcut(ShortcutID.nextProfile, shortcuts)
        }

        CommandMenu("Appareil") {
            let device = state.selectedDevice
            Button("Ping continu") { AppActions.ping(state) }
                .regShortcut(ShortcutID.ping, shortcuts)
                .disabled(device == nil)
            Button("Ouvrir la fiche appareil") { AppActions.openDevice(state) }
                .regShortcut(ShortcutID.openDevice, shortcuts)
                .disabled(device == nil)
            Divider()
            Button("Copier l’IP") { AppActions.copyIP(state) }
                .regShortcut(ShortcutID.copyIP, shortcuts)
                .disabled(device == nil)
            Button("Copier la MAC") { AppActions.copyMAC(state) }
                .regShortcut(ShortcutID.copyMAC, shortcuts)
                .disabled(device?.mac == nil)
            Button("Ouvrir dans le navigateur") { AppActions.openBrowser(state) }
                .regShortcut(ShortcutID.openBrowser, shortcuts)
                .disabled(device == nil)
            Divider()
            // Note 34 : les autres modules pertinents pour l'appareil choisi (⌥⌘1 à ⌥⌘0).
            if let device {
                Menu("Ouvrir dans") {
                    ForEach(state.openInItems(.device(NavDeviceRef(device)))) { item in
                        NavMenuButton(item: item).environmentObject(state)
                    }
                }
            } else {
                Menu("Ouvrir dans") {}.disabled(true)
            }
        }

        CommandMenu("Aller") {
            // Note 34 : Retour / Avancer rendent l'écran, la sélection et le filtre d'avant.
            Button("Retour") { state.goBack() }
                .regShortcut(ShortcutID.back, shortcuts)
                .disabled(!state.canGoBack)
            Button("Avancer") { state.goForward() }
                .regShortcut(ShortcutID.forward, shortcuts)
                .disabled(!state.canGoForward)
            Divider()
            ForEach(Screen.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(group.screens) { screen in
                        Button(screen.title) { AppActions.open(screen, state: state) }
                            .regShortcut(ShortcutCatalog.screenID(screen.rawValue), shortcuts)
                    }
                }
            }
        }
    }
}

/// Actions des menus (et de leurs raccourcis), sur l'état partagé.
@MainActor
enum AppActions {
    static func open(_ screen: Screen, state: AppState) {
        MonWindow.open()
        state.open(screen)
    }

    static func startScan(_ state: AppState) {
        let scan = ScanController.shared
        guard !scan.isRunning else { return }
        state.open(.scanner)
        scan.start(state)
    }

    static func newScan(_ state: AppState) {
        let scan = ScanController.shared
        guard !scan.isRunning else { return }
        scan.clear(state)
        state.open(.scanner)
        scan.start(state)
    }

    static func rescanSelection(_ state: AppState) {
        let scan = ScanController.shared
        guard let device = state.selectedDevice, !scan.isBusy else { return }
        state.open(.scanner)
        scan.probePorts(of: [device], preset: scan.portPreset, state: state)
    }

    static func nextProfile(_ state: AppState) {
        let all = ScanProfile.allCases
        let index = all.firstIndex(of: state.scanProfile).map { ($0 + 1) % all.count } ?? 0
        state.scanProfile = all[index]
        ScanController.shared.portPresetProfile = all[index]
        ScanController.shared.show("Profil de scan\u{00A0}: \(all[index].label)", tone: .neutral, place: .actions)
    }

    static func ping(_ state: AppState) {
        guard let device = state.selectedDevice else { return }
        state.sendToPing(device.ip.description)
    }

    static func openDevice(_ state: AppState) {
        guard let device = state.selectedDevice else { return }
        state.showDevice(device.id)
    }

    static func copyIP(_ state: AppState) {
        guard let device = state.selectedDevice else { return }
        ScanController.shared.copy(device.ip.description, label: "IP")
    }

    static func copyMAC(_ state: AppState) {
        guard let mac = state.selectedDevice?.mac else { return }
        ScanController.shared.copy(mac.formatted(.upperColon), label: "MAC")
    }

    /// Ouvre http(s):// de l'appareil choisi dans le navigateur par défaut (HTTPS si seul 443 est ouvert).
    static func openBrowser(_ state: AppState) {
        guard let device = state.selectedDevice else { return }
        let https = device.openPorts.contains(443) && !device.openPorts.contains(80)
        guard let url = URL(string: (https ? "https://" : "http://") + device.ip.description) else { return }
        ScanFormat.open(url)
    }

    static func export(_ state: AppState) {
        // Mêmes lignes et même format que le bouton « Exporter » du Scanner.
        let rows = ScanController.displayedRows?() ?? state.filteredDevices
        guard !rows.isEmpty else { return }
        ScanController.shared.export(rows, state: state)
    }

    /// Place le curseur dans le champ de recherche de la barre d'outils.
    static func focusSearch() {
        MonWindow.open()
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return
        }
        if let field = searchField(in: window.contentView?.superview) {
            window.makeFirstResponder(field)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
