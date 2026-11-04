import AppKit
import NetScopeCore
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        raiseFileLimit()
        // Outil de développement : captures de chaque écran, hors écran, puis sortie.
        if arguments.contains("--snapshot") {
            Snapshots.run(arguments: arguments)
        }
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
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    // Base des fabricants (registre IEEE) : chargée en arrière-plan dès le lancement.
                    Task.detached(priority: .utility) { _ = OUIDatabase.builtIn.count }
                    guard !Launcher.isDemo else { return }
                    await state.detectInterface()
                    // Sondes de surveillance : elles tournent dès le lancement, fenêtre fermée comprise.
                    MonStore.shared.attach(to: state)
                    // Vérification des mises à jour (Releases GitHub) selon la fréquence choisie.
                    await UpdController.shared.applicationDidLaunch(state)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { UpdCommands(state: state) }

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
