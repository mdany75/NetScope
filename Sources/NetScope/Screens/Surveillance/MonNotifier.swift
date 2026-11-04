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

    private var authorizationRequested = false

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

    private func deliver(title: String, body: String, probe: MonProbe, identifier: String, sound: Bool) {
        guard isAvailable else {
            if sound { NSSound.beep() }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = probe.id.uuidString
        content.userInfo = ["probe": probe.id.uuidString]
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let send = { center.add(request) { _ in } }
        if authorizationRequested {
            send()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { send() }
            }
        }
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
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
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
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openAction?(id: windowID)
        }
        if let screen { appState?.open(screen) }
    }
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
            }
    }
}
