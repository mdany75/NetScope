import AppKit
import ApplicationServices
import Foundation
import NetScopeCore

/// Réglages d'affichage de Partage d'écran (VNC), appliqués au moment de « Connecter ».
@MainActor
enum RemoteScreenSharingControl {
    static let bundleID = "com.apple.ScreenSharing"

    /// Écrit la préférence d'échelle de Partage d'écran (« Ajuster à l'espace disponible » ou
    /// « Afficher la taille originale ») ; rien pour « Selon Partage d'écran ».
    static func applyScale(_ scale: RemoteVNCScale) {
        guard let value = scale.shouldScaleScreen else { return }
        let domain = RemoteScreenSharingPreferences.domain as CFString
        CFPreferencesSetAppValue(RemoteScreenSharingPreferences.scaleKey as CFString, value as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// Accessibilité accordée à NetScope ; `prompt` : macOS propose d'ouvrir les Réglages.
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// État de Partage d'écran juste avant l'ouverture (pour reconnaître la nouvelle fenêtre).
    struct Snapshot {
        var appWasRunning: Bool
        var windows: [AXUIElement]
    }

    enum Outcome: Equatable {
        case done, cancelled, appClosed, timedOut
    }

    static func snapshot() -> Snapshot {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return Snapshot(appWasRunning: false, windows: [])
        }
        return Snapshot(appWasRunning: true, windows: windows(of: AXUIElementCreateApplication(app.processIdentifier)))
    }

    /// Attend la fenêtre de session (après l'authentification, deux minutes au plus) et la passe
    /// en plein écran. S'arrête si la tâche est annulée ou si Partage d'écran se ferme (ou ne
    /// démarre pas dans les 20 premières secondes).
    static func enterFullScreen(host: String, name: String, before: Snapshot, timeout: TimeInterval = 120) async -> Outcome {
        let start = Date()
        var sawApp = before.appWasRunning
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return .cancelled }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                if sawApp || Date().timeIntervalSince(start) > 20 { return .appClosed }
                continue
            }
            sawApp = true
            let all = windows(of: AXUIElementCreateApplication(app.processIdentifier))
            let survey = all.map { window in
                RemoteFullScreenTarget.Window(
                    title: string(window, kAXTitleAttribute) ?? "",
                    subrole: string(window, kAXSubroleAttribute) ?? "",
                    identifier: string(window, kAXIdentifierAttribute) ?? "",
                    isNew: !before.windows.contains { CFEqual($0, window) },
                    canFullScreen: isSettable(window, "AXFullScreen"),
                    isFullScreen: bool(window, "AXFullScreen") ?? false)
            }
            // Une session déjà ouverte vers le même hôte peut être réutilisée : elle ne compte
            // qu'après quelques secondes, le temps qu'une nouvelle fenêtre apparaisse.
            let decision = RemoteFullScreenTarget.pick(survey, host: host, name: name,
                                                       appWasRunning: before.appWasRunning,
                                                       allowExisting: Date().timeIntervalSince(start) > 5)
            switch decision {
            case .alreadyFullScreen?:
                return .done
            case .enter(let index)?:
                if AXUIElementSetAttributeValue(all[index], "AXFullScreen" as CFString, kCFBooleanTrue) == .success { return .done }
            case nil:
                continue
            }
        }
        return .timedOut
    }

    // MARK: Accessibilité

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
}
