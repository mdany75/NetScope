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
        // Note 35 : journal de l'app dans ~/Library/Logs/NetScope, avant tout autre module.
        RegDiagnosticController.installLogFile()
        // Restauration d'une sauvegarde demandée avant le redémarrage : appliquée avant que les
        // écrans ne lisent leurs fichiers (jamais en démonstration ni pendant une capture).
        if !RegEnvironment.isSandboxed { RegBackupController.applyPendingRestore() }
        // Note 56 : import de configuration et changements synchronisés en attente, au même moment.
        if !RegEnvironment.isSandboxed {
            RegConfigController.applyPending()
            RegSyncController.applyPending()
        }
        // Note 64 : l'app ouverte reprend la main sur l'agent, avant de lire la Surveillance et les Journaux.
        AppPresenceKeeper.launch()
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
        // Note 90 : interface VLAN temporaire restée d'un arrêt brutal : retirée.
        MainActor.assumeIsolated { VLANScanModel.shared.cleanupLeftovers() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Délégué des notifications en place avant tout : un clic sur une notification qui lance
        // NetScope doit ouvrir la sonde.
        MainActor.assumeIsolated { MonNotifier.shared.install() }
    }

    /// Tant que des sondes de surveillance sont actives, NetScope reste dans la barre de menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Note 43 : les récepteurs Syslog et traps continuent aussi fenêtre fermée.
        MainActor.assumeIsolated { !MonStore.shared.hasActiveProbes && !LogStore.isListeningIfLoaded }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MonStore.shared.save()
            // Note 28 : derniers résultats et inventaire du site actif.
            SiteModel.shared.saveOnQuit()
            // Note 43 : journal des messages reçus depuis le dernier enregistrement.
            LogStore.saveOnQuitIfLoaded()
            // Note 64 : l'agent (s'il est activé) reprend les sondes, Syslog et les scans planifiés.
            AppPresenceKeeper.quit()
            // Note 90 : l'interface VLAN temporaire n'est jamais laissée derrière.
            VLANScanModel.shared.removeOnQuit()
        }
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
                    // Note 35 : plantage récent de NetScope (bannière) et rapports des 30 derniers jours.
                    RegDiagnosticController.shared.start()
                    // Vitesse des disques : fichiers d'essai restés après un arrêt brutal, supprimés.
                    Task.detached(priority: .utility) { DiskPendingCleanup.standard.cleanAll() }
                    // Note 28 : résultats du dernier scan du site actif.
                    SiteModel.shared.attach(to: state)
                    await state.detectInterface()
                    // Sondes de surveillance : elles tournent dès le lancement, fenêtre fermée comprise.
                    MonStore.shared.attach(to: state)
                    // Note 42 : rapports planifiés (jamais de scan ; rattrapage unique au lancement).
                    RapportScheduleStore.shared.attach(to: state)
                    // Note 63 : scans planifiés par site (jamais pendant un autre scan).
                    ScanScheduleStore.shared.attach(to: state)
                    // Note 29 : relecture automatique du site actif (FortiGate, bornes, switchs SNMP).
                    AutoRefreshStore.shared.attach(to: state)
                    // État des services en ligne : reprend si l'outil a déjà servi (aucune requête sinon).
                    SvcStore.shared.attach()
                    // Vérification des mises à jour (Releases GitHub) selon la fréquence choisie.
                    await UpdController.shared.applicationDidLaunch(state)
                    // Sauvegarde automatique quotidienne (Réglages › Export et sauvegarde).
                    RegBackupController.shared.startSchedule()
                    // Note 56 : synchronisation par iCloud Drive (si activée), puis toutes les 15 minutes.
                    RegSyncController.shared.startIfEnabled(state: state)
                    // Note 81 : base des fabricants mise à jour automatiquement (au plus une fois par mois).
                    OUIAutoController.shared.start()
                    // Note 78 : débit Internet planifié du site actif (une fois par jour).
                    SpeedScheduleStore.shared.attach(to: state)
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
