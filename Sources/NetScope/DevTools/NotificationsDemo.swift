import Foundation
import NetScopeCore

/// Démonstration (« --demo ») de Réglages › Notifications et Raccourcis : réglages crédibles et
/// derniers événements, dont la décision est calculée par la vraie `NotificationPolicy`. Rien
/// n'est envoyé à macOS.
@MainActor
enum NotificationsDemo {
    static var settings: NotificationSettings {
        var settings = NotificationSettings()
        settings.sound = .critical
        settings.quietHours = QuietHours(isEnabled: true, start: DayMinute(hour: 22), end: DayMinute(hour: 7))
        settings.criticalBypassQuietHours = true
        settings.grouping = true
        settings.set(.scanFinished, enabled: true)
        settings.set(.deviceMoved, enabled: false)
        return settings
    }

    /// Raccourcis personnalisés : la MAC copiée par ⌥⌘M, et un essai en conflit avec macOS (⌘H).
    static var shortcuts: ShortcutSettings {
        var settings = ShortcutSettings()
        if let copyMAC = RegShortcutStore.action(ShortcutID.copyMAC) { settings.set(KeyCombo("m", [.option, .command]), for: copyMAC) }
        if let browser = RegShortcutStore.action(ShortcutID.openBrowser) { settings.set(KeyCombo("h"), for: browser) }
        return settings
    }

    static func log(now: Date = Date()) -> [RegNotifStore.LogEntry] {
        let calendar = Calendar.current
        // Journée de référence : aujourd'hui l'après-midi, sinon hier (captures faites à toute heure :
        // les heures et les décisions restent les mêmes).
        let startOfToday = calendar.startOfDay(for: now)
        let today = calendar.component(.hour, from: now) >= 14
            ? startOfToday : calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        func clock(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: dayOffset * 1440 + hour * 60 + minute, to: today) ?? now
        }
        func ago(_ minutes: Double) -> Date { clock(13, 50).addingTimeInterval(-minutes * 60) }
        let s = "\u{00A0}"
        // (événement, NetScope au premier plan)
        let samples: [(NetScopeEvent, Bool)] = [
            (NetScopeEvent(kind: .probeWarning, title: "Ping passerelle en alerte",
                           detail: "Latence moyenne 63\(s)ms > 50\(s)ms pendant 2\(s)min.", date: clock(23, 14, dayOffset: -1),
                           link: .none, source: "ping-passerelle"), false),
            (NetScopeEvent(kind: .rogueDHCP, title: "Serveur DHCP non autorisé\(s): 10.182.122.250",
                           detail: "Offre 10.182.122.77 · passerelle 192.168.0.1 · MAC 50:C7:BF:3A:21:9E (TP-Link) · SW-ETG2-01 Gi1/0/18",
                           date: clock(2, 41), link: .screen("analyse")), false),
            (NetScopeEvent(kind: .deviceMoved, title: "Port de WKS346 en alerte",
                           detail: "WKS346 vu sur SW-CORE-01 Gi1/0/24 au lieu de Gi1/0/22.", date: ago(122), source: "port-wks346"), true),
            (NetScopeEvent(kind: .scanFinished, title: "Scan terminé",
                           detail: "254 adresses en 41\(s)s\(s): 38 appareils en ligne, 2 nouveaux.", date: ago(81), link: .screen("scanner")), true),
            (NetScopeEvent(kind: .newDevice, title: "Nouveaux appareils",
                           detail: "Nouvel appareil 10.182.122.133 Android_89UM1WTN (MAC aléatoire D6:4E:81:7A:33:C0).", date: ago(41),
                           source: "nouveaux-appareils"), false),
            (NetScopeEvent(kind: .probeDown, title: "Caméra-Quai hors ligne",
                           detail: "192.168.50.21 ne répond plus depuis 3 tentatives (ICMP et TCP 554).", date: ago(38),
                           source: "camera-quai", sourceRequestsSound: true), false),
            (NetScopeEvent(kind: .serviceIncident, title: "Microsoft 365\(s): incident",
                           detail: "Teams\(s): retards dans la livraison des messages de conversation (TM892341).", date: ago(4),
                           link: .service("microsoft365")), false),
        ]
        var policy = NotificationPolicy()
        let settings = settings
        var entries: [RegNotifStore.LogEntry] = []
        for (event, active) in samples.sorted(by: { $0.0.date < $1.0.date }) {
            let decision = policy.decide(event, settings: settings,
                                         context: NotificationContext(now: event.date, appIsActive: active, calendar: calendar))
            entries.insert(RegNotifStore.LogEntry(event: event, decision: decision), at: 0)
        }
        return entries
    }
}
