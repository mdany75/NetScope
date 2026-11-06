import AppKit
import Foundation
import NetScopeCore

/// Réglages des notifications (UserDefaults « reglages.notifications », JSON de
/// `NotificationSettings`), état de l'autorisation macOS et journal des derniers événements avec
/// la décision prise (livrée, regroupée, silence…). En démonstration ou capture : rien n'est lu
/// ni écrit, réglages et journal de démonstration.
@MainActor
final class RegNotifStore: ObservableObject {
    static let shared = RegNotifStore()

    static let key = "reglages.notifications"

    /// Autorisation des notifications par macOS.
    enum Authorization: Equatable {
        /// Pas encore lue.
        case unknown
        /// Exécutable hors paquet .app : UserNotifications indisponible.
        case unavailable
        case notDetermined
        case denied
        case authorized
    }

    /// Un événement reçu et ce qui en a été fait.
    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        var event: NetScopeEvent
        var decision: NotificationDecision
    }

    private let defaults: UserDefaults?

    @Published var settings: NotificationSettings {
        didSet { if settings != oldValue { defaults?.set(settings.encoded(), forKey: Self.key) } }
    }
    @Published var authorization = Authorization.unknown
    @Published private(set) var log: [LogEntry] = []
    /// Message du dernier essai (« Notification de test envoyée… »).
    @Published var testMessage: String?

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if RegEnvironment.isSandboxed {
            settings = RegEnvironment.isDemo ? NotificationsDemo.settings : NotificationSettings()
            log = RegEnvironment.isDemo ? NotificationsDemo.log() : []
            authorization = RegEnvironment.isDemo ? .authorized : .unavailable
        } else {
            settings = NotificationSettings.decoded(UserDefaults.standard.data(forKey: Self.key))
        }
    }

    /// Note 86 : réglages des notifications reçus d'un autre Mac, relus sans redémarrer.
    func reloadFromDisk() {
        guard defaults != nil else { return }
        let saved = NotificationSettings.decoded(UserDefaults.standard.data(forKey: Self.key))
        if saved != settings { settings = saved }
    }

    func record(_ event: NetScopeEvent, decision: NotificationDecision) {
        log.insert(LogEntry(event: event, decision: decision), at: 0)
        if log.count > 30 { log.removeLast(log.count - 30) }
    }

    /// Liaison d'un type d'événement (interrupteur de la liste).
    func isEnabled(_ kind: NetScopeEventKind) -> Bool { settings.isEnabled(kind) }

    func set(_ kind: NetScopeEventKind, enabled: Bool) {
        settings.set(kind, enabled: enabled)
    }

    func reset() {
        settings = NotificationSettings()
    }

    /// Réglages Système › Notifications › NetScope (ou la liste des apps à défaut).
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.danymenard.netscope"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
    }
}
