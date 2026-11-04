import AppKit
import Foundation
import NetScopeCore
import SwiftUI
import UserNotifications

/// Notifications macOS des alertes (UserNotifications). L'autorisation est demandée à la première
/// alerte. Hors paquet .app (exécutable de .build/) ou en démonstration, rien n'est envoyé :
/// UNUserNotificationCenter exige un paquet d'application signé.
@MainActor
final class MonNotifier: NSObject {
    static let shared = MonNotifier()

    private enum Authorization { case unknown, pending, granted, denied }
    private var authorization = Authorization.unknown
    /// Notifications prêtes pendant que l'utilisateur répond à la demande d'autorisation.
    private var queued: [UNNotificationRequest] = []

    /// À appeler au lancement : le délégué doit être en place avant que macOS ne transmette le clic
    /// sur une notification qui a lancé l'app.
    func install() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Vrai si les notifications sont possibles ici.
    var isAvailable: Bool {
        !MonStore.shared.isSimulated && Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Notifie une nouvelle alerte (regroupée par sonde), avec le son si la sonde le demande.
    func post(_ alert: MonAlert, probe: MonProbe) {
        guard probe.notify || probe.sound else { return }
        let title: String
        switch alert.severity {
        case .critical: title = "\(probe.name) hors ligne"
        case .warning: title = "\(probe.name) en alerte"
        case .info: title = probe.name
        case .success: return
        }
        if probe.notify {
            deliver(title: title, body: alert.message, probe: probe, identifier: alert.id.uuidString, sound: probe.sound)
        } else if probe.sound {
            NSSound.beep()
        }
    }

    /// Notifie le retour à la normale d'une sonde qui était en alerte.
    func postRecovery(probe: MonProbe, value: String) {
        guard probe.notify else { return }
        deliver(title: "\(probe.name) rétablie", body: "Retour à la normale\u{00A0}: \(value).", probe: probe,
                identifier: UUID().uuidString, sound: false)
    }

    /// Notifie un nouvel incident d'un service en ligne (outil « État des services », note 15).
    func postService(title: String, body: String, serviceID: String, identifier: String) {
        deliver(title: title, body: body, thread: "service-" + serviceID, userInfo: ["service": serviceID],
                identifier: identifier, sound: false)
    }

    private func deliver(title: String, body: String, probe: MonProbe, identifier: String, sound: Bool) {
        deliver(title: title, body: body, thread: probe.id.uuidString, userInfo: ["probe": probe.id.uuidString],
                identifier: identifier, sound: sound)
    }

    private func deliver(title: String, body: String, thread: String, userInfo: [String: String], identifier: String, sound: Bool) {
        guard isAvailable else {
            if sound { NSSound.beep() }
            return
        }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.userInfo = userInfo
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        switch authorization {
        case .granted:
            center.add(request) { _ in }
        case .denied:
            if sound { NSSound.beep() }
        case .pending:
            queued.append(request)
        case .unknown:
            authorization = .pending
            queued.append(request)
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { MonNotifier.shared.authorized(granted) }
                }
            }
        }
    }

    /// Réponse à la demande d'autorisation : la file d'attente part (ou est abandonnée).
    private func authorized(_ granted: Bool) {
        authorization = granted ? .granted : .denied
        let pending = queued
        queued = []
        guard granted else { return }
        let center = UNUserNotificationCenter.current()
        for request in pending { center.add(request) { _ in } }
    }
}

extension MonNotifier: UNUserNotificationCenterDelegate {
    /// Bannière affichée même quand NetScope est au premier plan.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Clic sur la notification : ouvre NetScope sur la sonde.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let text = response.notification.request.content.userInfo["probe"] as? String
        let service = response.notification.request.content.userInfo["service"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Incident d'un service en ligne : ouvre l'outil « État des services » sur ce service.
                if let service {
                    SvcStore.shared.selectedServiceID = service
                    ToolStore.shared.selectedTool = .cloud
                    ToolStore.shared.toolFilter = ""
                    MonWindow.open(screen: .outils)
                    return
                }
                if let text, let id = UUID(uuidString: text) { MonStore.shared.selectedID = id }
                MonWindow.open(screen: .surveillance)
            }
        }
        completionHandler()
    }
}

/// Ouvre (ou ramène) la fenêtre principale depuis la barre de menus ou une notification.
@MainActor
enum MonWindow {
    /// Fournie par la fenêtre principale (Environment openWindow), pour la rouvrir une fois fermée.
    static var openAction: OpenWindowAction?
    static weak var appState: AppState?
    static let windowID = "principale"

    static func open(screen: Screen? = nil) {
        NSApp.setActivationPolicy(.regular)
        // Une app masquée (Cmd-H) ou une fenêtre réduite dans le Dock a isVisible == false : on
        // démasque et on cherche aussi les fenêtres réduites, pour ramener l'existante plutôt que
        // d'en ouvrir une seconde par openWindow.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
        let window = candidates.first { $0.identifier?.rawValue.hasPrefix(windowID) == true } ?? candidates.first
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openAction?(id: windowID)
        }
        guard let screen else { return }
        if let appState {
            appState.open(screen)
        } else {
            // Lancement par un clic sur une notification : la fenêtre n'est pas encore là.
            pendingScreen = screen
        }
    }

    /// Écran à ouvrir dès que la fenêtre principale apparaît.
    static var pendingScreen: Screen?
}

/// Retient l'action openWindow de la fenêtre principale.
struct MonWindowHook: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var state: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MonWindow.openAction = openWindow
                MonWindow.appState = state
                if let screen = MonWindow.pendingScreen {
                    MonWindow.pendingScreen = nil
                    state.open(screen)
                }
            }
    }
}
