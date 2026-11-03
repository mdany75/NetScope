import AppKit
import NetScopeCore
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        // Outil de développement : captures de chaque écran, hors écran, puis sortie.
        if arguments.contains("--snapshot") {
            Snapshots.run(arguments: arguments)
        }
        NetScopeApp.main()
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
