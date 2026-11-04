import AppKit
import NetScopeCore
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        raiseFileLimit()
        RapportTextMeasure.install()
        // Outil de développement : captures de chaque écran, hors écran, puis sortie.
        if arguments.contains("--snapshot") {
            Snapshots.run(arguments: arguments)
        }
        // Restauration d'une sauvegarde demandée avant le redémarrage : appliquée avant que les
        // écrans ne lisent leurs fichiers (jamais en démonstration ni pendant une capture).
        if !RegEnvironment.isSandboxed { RegBackupController.applyPendingRestore() }
        NetScopeApp.main()
    }

    /// Une app graphique n'a que 256 descripteurs par défaut ; un scan ouvre jusqu'à 128 sockets TCP,
    /// plus les sockets UDP des noms et du SNMP. On monte à 4096 (dans la limite permise).
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(rlim_t(4096), limit.rlim_max)
        guard limit.rlim_cur < wanted else { return }
        limit.rlim_cur = wanted
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// Mode démonstration (« --demo ») : appareils fictifs des croquis, rien d'enregistré sur le disque.
    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Exécutable SwiftPM lancé hors paquet : il faut le déclarer comme application ordinaire.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Délégué des notifications en place avant tout : un clic sur une notification qui lance
        // NetScope doit ouvrir la sonde.
        MainActor.assumeIsolated { MonNotifier.shared.install() }
    }

    /// Tant que des sondes de surveillance sont actives, NetScope reste dans la barre de menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !MonStore.shared.hasActiveProbes }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MonStore.shared.save() }
    }
}

struct NetScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var monitor = MonStore.shared
    @StateObject private var state: AppState = {
        if Launcher.isDemo {
            let state = AppState(store: nil)
            DemoData.apply(to: state)
            return state
        }
        return AppState()
    }()

    var body: some Scene {
        WindowGroup("NetScope", id: MonWindow.windowID) {
            ContentView()
                .background(MonWindowHook())
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Base des fabricants (registre IEEE) : chargée en arrière-plan dès le lancement.
                    Task.detached(priority: .utility) { _ = OUIDatabase.builtIn.count }
                    guard !Launcher.isDemo else { return }
                    // Vitesse des disques : fichiers d'essai restés après un arrêt brutal, supprimés.
                    Task.detached(priority: .utility) { DiskPendingCleanup.standard.cleanAll() }
                    await state.detectInterface()
                    // Sondes de surveillance : elles tournent dès le lancement, fenêtre fermée comprise.
                    MonStore.shared.attach(to: state)
                    // État des services en ligne : reprend si l'outil a déjà servi (aucune requête sinon).
                    SvcStore.shared.attach()
                    // Vérification des mises à jour (Releases GitHub) selon la fréquence choisie.
                    await UpdController.shared.applicationDidLaunch(state)
                    // Sauvegarde automatique quotidienne (Réglages › Export et sauvegarde).
                    RegBackupController.shared.startSchedule()
                }
                .task {
                    // Changement d'interface ou de réseau (lecture locale, toutes les 15 s) : le bilan
                    // des switchs et l'encart LLDP/CDP d'un autre réseau ne sont plus présentés comme actuels.
                    guard !Launcher.isDemo else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        guard !Task.isCancelled else { return }
                        await state.refreshInterface()
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            UpdCommands(state: state)
            // Menus Scan, Appareil, Aller… : raccourcis de Réglages › Raccourcis.
            AppCommands(state: state)
        }

        // Icône de la barre de menus : état, passerelle, alertes, « Scan rapide », « Ouvrir NetScope ».
        MenuBarExtra(isInserted: .constant(!monitor.probes.isEmpty)) {
            MonMenuContent(onScan: { MonWindow.open(screen: .scanner) }, onOpen: { MonWindow.open() })
                .environmentObject(state)
        } label: {
            MonMenuLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
