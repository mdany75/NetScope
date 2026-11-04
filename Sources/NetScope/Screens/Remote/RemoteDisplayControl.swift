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

    /// Fenêtres de Partage d'écran présentes avant l'ouverture (pour reconnaître la nouvelle).
    static func currentWindows() -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        return windows(of: AXUIElementCreateApplication(app.processIdentifier))
    }

    /// Attend la fenêtre de session (après l'authentification, deux minutes au plus) et la passe
    /// en plein écran. Renvoie vrai si c'est fait.
    static func enterFullScreen(host: String, before: [AXUIElement], timeout: TimeInterval = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let all = windows(of: AXUIElementCreateApplication(app.processIdentifier))
            let survey = all.map { window in
                RemoteFullScreenTarget.Window(
                    title: string(window, kAXTitleAttribute) ?? "",
                    subrole: string(window, kAXSubroleAttribute) ?? "",
                    isNew: !before.contains { CFEqual($0, window) },
                    canFullScreen: isSettable(window, "AXFullScreen"),
                    isFullScreen: bool(window, "AXFullScreen") ?? false)
            }
            guard let index = RemoteFullScreenTarget.pick(survey, host: host) else { continue }
            return AXUIElementSetAttributeValue(all[index], "AXFullScreen" as CFString, kCFBooleanTrue) == .success
        }
        return false
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
