import AppKit
import Foundation
import NetScopeCore
import SwiftUI
import UserNotifications

/// Notifications macOS (UserNotifications). Tous les émetteurs publient un `NetScopeEvent` dans
/// `NetScopeEventCenter` ; MonNotifier s'y abonne et livre ce que décide `NotificationPolicy`
/// (Réglages › Notifications : types, son, heures de silence, regroupement). L'autorisation est
/// demandée à la première notification. Hors paquet .app (exécutable de .build/) ou en
/// démonstration, rien n'est envoyé : UNUserNotificationCenter exige un paquet d'application signé.
@MainActor
final class MonNotifier: NSObject {
    static let shared = MonNotifier()

    /// Nom de l'abonnement au centre des événements.
    static let subscriberName = "notifications-macos"

    private enum Authorization { case unknown, pending, granted, denied }
    private var authorization = Authorization.unknown
    /// Notifications prêtes pendant que l'utilisateur répond à la demande d'autorisation.
    private var queued: [UNNotificationRequest] = []
    /// Décision et état du regroupement.
    private var policy = NotificationPolicy()

    /// À appeler au lancement : le délégué doit être en place avant que macOS ne transmette le clic
    /// sur une notification qui a lancé l'app.
    func install() {
        NetScopeEventCenter.shared.subscribe(Self.subscriberName) { event in
            MonNotifier.shared.handle(event)
        }
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    /// Vrai si les notifications sont possibles ici.
    var isAvailable: Bool {
        !MonStore.shared.isSimulated && Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    // MARK: Émetteurs existants (convertis en événements communs)

    /// Nouvelle alerte d'une sonde (regroupée par sonde), avec le son si la sonde le demande.
    func post(_ alert: MonAlert, probe: MonProbe) {
        // Note 78 : licence, firmware, Syslog et WAN ont leur propre type (AlertDedicatedEvents.swift).
        guard let kind = NetScopeEventKind.forProbe(probe.kind, severity: alert.severity) else { return }
        let severity: NetScopeEventSeverity = alert.severity == .critical ? .critical : alert.severity == .warning ? .warning : .info
        let title = NetScopeEventKind.probeTitle(kind, severity: alert.severity, probeName: probe.name)
        NetScopeEventCenter.shared.publish(NetScopeEvent(
            id: alert.id.uuidString, kind: kind, severity: severity, title: title, detail: alert.message, date: alert.date,
            link: .probe(probe.id), source: probe.id.uuidString,
            sourceAllowsBanner: probe.notify, sourceRequestsSound: probe.sound))
    }

    /// Retour à la normale d'une sonde qui était en alerte.
    func postRecovery(probe: MonProbe, value: String) {
        NetScopeEventCenter.shared.publish(NetScopeEvent(
            kind: .probeRecovered, title: "\(probe.name) rétablie", detail: "Retour à la normale\u{00A0}: \(value).",
            link: .probe(probe.id), source: probe.id.uuidString, sourceAllowsBanner: probe.notify))
    }

    /// Nouvel incident d'un service en ligne (outil « État des services », note 15).
    func postService(title: String, body: String, serviceID: String, identifier: String) {
        NetScopeEventCenter.shared.publish(NetScopeEvent(
            id: identifier, kind: .serviceIncident, title: title, detail: body, link: .service(serviceID),
            source: "service-" + serviceID))
    }

    /// Notification de test (Réglages › Notifications) ; renvoie le message à afficher.
    @discardableResult
    func postTest() -> String {
        let event = NetScopeEvent(kind: .test, title: "NetScope\u{00A0}: notification de test",
                                  detail: "Les notifications de NetScope arrivent bien dans le Centre de notifications.",
                                  link: .screen(Screen.reglages.rawValue))
        NetScopeEventCenter.shared.publish(event)
        if RegEnvironment.isSandboxed { return "Démonstration\u{00A0}: aucune notification réelle n’est envoyée." }
        if !isAvailable { return "Indisponible hors de l’app installée (.app)\u{00A0}: lancez NetScope depuis Applications." }
        switch RegNotifStore.shared.authorization {
        case .denied: return "Refusée par macOS\u{00A0}: autorisez NetScope dans Réglages Système › Notifications."
        case .notDetermined: return "macOS demande l’autorisation\u{00A0}: répondez « Autoriser » pour recevoir la notification."
        default: return "Notification de test envoyée au Centre de notifications."
        }
    }

    // MARK: Décision et livraison

    private func handle(_ event: NetScopeEvent) {
        let store = RegNotifStore.shared
        let context = NotificationContext(now: Date(), appIsActive: NSApp?.isActive ?? false)
        let decision = policy.decide(event, settings: store.settings, context: context)
        store.record(event, decision: decision)
        guard let delivery = decision.delivery, !RegEnvironment.isSandboxed else { return }
        if !delivery.banner {
            if delivery.sound { NSSound.beep() }
            return
        }
        deliver(delivery, link: event.link)
    }

    private func deliver(_ delivery: NotificationDelivery, link: NetScopeEventLink) {
        guard isAvailable else {
            if delivery.sound { NSSound.beep() }
            return
        }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        let content = UNMutableNotificationContent()
        content.title = delivery.title
        content.body = delivery.body
        content.threadIdentifier = delivery.thread
        content.userInfo = ["lien": link.url]
        if delivery.sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: delivery.identifier, content: content, trigger: nil)
        switch authorization {
        case .granted:
            center.add(request) { _ in }
        case .denied:
            if delivery.sound { NSSound.beep() }
        case .pending:
            queued.append(request)
        case .unknown:
            queued.append(request)
            requestAuthorization()
        }
    }

    /// Demande l'autorisation à macOS (une seule fois : ensuite, seul Réglages Système la change).
    func requestAuthorization() {
        guard isAvailable, authorization != .pending else { return }
        authorization = .pending
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MonNotifier.shared.authorized(granted) }
            }
        }
    }

    /// Relit l'état de l'autorisation (Réglages › Notifications l'affiche).
    func refreshAuthorization() {
        guard isAvailable else {
            RegNotifStore.shared.authorization = RegEnvironment.isDemo ? .authorized : .unavailable
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MonNotifier.shared.apply(status) }
            }
        }
    }

    private func apply(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional:
            authorization = .granted
            RegNotifStore.shared.authorization = .authorized
        case .denied:
            authorization = .denied
            RegNotifStore.shared.authorization = .denied
        case .notDetermined:
            if authorization != .pending { authorization = .unknown }
            RegNotifStore.shared.authorization = .notDetermined
        @unknown default:
            RegNotifStore.shared.authorization = .authorized
        }
    }

    /// Réponse à la demande d'autorisation : la file d'attente part (ou est abandonnée).
    private func authorized(_ granted: Bool) {
        authorization = granted ? .granted : .denied
        RegNotifStore.shared.authorization = granted ? .authorized : .denied
        let pending = queued
        queued = []
        guard granted else { return }
        let center = UNUserNotificationCenter.current()
        for request in pending { center.add(request) { _ in } }
    }

    /// Ouvre le lien interne d'une notification (clic).
    static func open(_ link: NetScopeEventLink) {
        switch link {
        case .none:
            MonWindow.open()
        case .probe(let id):
            MonStore.shared.selectedID = id
            MonWindow.open(screen: .surveillance)
        case .service(let id):
            // Incident d'un service en ligne : ouvre l'outil « État des services » sur ce service.
            SvcStore.shared.selectedServiceID = id
            ToolStore.shared.selectedTool = .cloud
            ToolStore.shared.toolFilter = ""
            MonWindow.open(screen: .outils)
        case .device(let ip):
            MonWindow.open(screen: .scanner)
            if let state = MonWindow.appState, state.device(withID: ip) != nil { state.showDevice(ip) }
        case .screen(let raw):
            if raw == Screen.reglages.rawValue { RegNavigation.shared.section = .notifications }
            MonWindow.open(screen: Screen(rawValue: raw) ?? .scanner)
        case .updates:
            RegNavigation.shared.section = .majs
            MonWindow.open(screen: .reglages)
        }
    }
}

extension MonNotifier: UNUserNotificationCenterDelegate {
    /// Bannière affichée même quand NetScope est au premier plan.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Clic sur la notification : ouvre NetScope sur la sonde, le service, l'appareil ou l'écran.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let text = info["lien"] as? String
        // Notifications envoyées par une version précédente (clés « probe » et « service »).
        let legacyProbe = (info["probe"] as? String).flatMap(UUID.init(uuidString:))
        let legacyService = info["service"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let link = text.flatMap(NetScopeEventLink.init(url:))
                    ?? legacyService.map(NetScopeEventLink.service) ?? legacyProbe.map(NetScopeEventLink.probe) ?? .none
                MonNotifier.open(link)
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
