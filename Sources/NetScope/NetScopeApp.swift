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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct NetScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state: AppState = {
        if Launcher.isDemo {
            let state = AppState(store: nil)
            DemoData.apply(to: state)
            return state
        }
        return AppState()
    }()

    var body: some Scene {
        WindowGroup("NetScope") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    // Base des fabricants (registre IEEE) : chargée en arrière-plan dès le lancement.
                    Task.detached(priority: .utility) { _ = OUIDatabase.builtIn.count }
                    guard !Launcher.isDemo else { return }
                    await state.detectInterface()
                    // Vérification des mises à jour (Releases GitHub) selon la fréquence choisie.
                    await UpdController.shared.applicationDidLaunch(state)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { UpdCommands(state: state) }
    }
}
