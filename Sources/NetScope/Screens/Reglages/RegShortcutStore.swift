import Foundation
import NetScopeCore
import SwiftUI

/// Raccourcis clavier choisis (UserDefaults « reglages.raccourcis », JSON des écarts aux valeurs
/// par défaut). Les menus de l'app (`AppCommands`) les lisent : un changement met les menus à jour.
@MainActor
final class RegShortcutStore: ObservableObject {
    static let shared = RegShortcutStore()

    static let key = "reglages.raccourcis"

    /// Toutes les commandes : fixes, puis une par écran (⌘1 à ⌘9 pour les neuf premiers ; Réglages a ⌘,).
    static let actions: [ShortcutAction] = ShortcutCatalog.fixedActions
        + ShortcutCatalog.screenActions(Screen.allCases.filter { $0 != .reglages }.map { ($0.rawValue, $0.title) })

    private let defaults: UserDefaults?

    @Published var settings: ShortcutSettings {
        didSet { if settings != oldValue { defaults?.set(settings.encoded(), forKey: Self.key) } }
    }

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if RegEnvironment.isSandboxed {
            settings = RegEnvironment.isDemo ? NotificationsDemo.shortcuts : ShortcutSettings()
        } else {
            settings = ShortcutSettings.decoded(UserDefaults.standard.data(forKey: Self.key))
        }
    }

    static func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    func combo(_ id: String) -> KeyCombo? {
        Self.action(id).flatMap { settings.combo(for: $0) }
    }

    /// Raccourci de SwiftUI d'une commande (nil : aucun).
    func shortcut(_ id: String) -> KeyboardShortcut? {
        combo(id).flatMap(Self.keyboardShortcut)
    }

    var conflicts: [String: [ShortcutConflict]] { settings.conflicts(in: Self.actions) }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) { settings.set(combo, for: action) }
    func reset(_ action: ShortcutAction) { settings.reset(action) }
    func resetAll() { settings.resetAll() }

    /// Texte d'un conflit (« Déjà pris par « Ouvrir la fiche appareil » », « Réservé par macOS : … »).
    static func describe(_ conflict: ShortcutConflict) -> String {
        switch conflict {
        case .duplicate(let id):
            return "Aussi utilisé par « \(action(id)?.title ?? id) »"
        case .system(let name):
            return "Réservé par macOS\u{00A0}: \(name)"
        }
    }

    /// Traduction d'une combinaison en KeyboardShortcut de SwiftUI.
    static func keyboardShortcut(_ combo: KeyCombo) -> KeyboardShortcut? {
        let key: KeyEquivalent
        switch combo.key {
        case "return": key = .return
        case "escape": key = .escape
        case "delete": key = .delete
        case "forwardDelete": key = .deleteForward
        case "tab": key = .tab
        case "space": key = .space
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        case "home": key = .home
        case "end": key = .end
        case "pageUp": key = .pageUp
        case "pageDown": key = .pageDown
        default:
            if combo.isFunctionKey, let number = Int(combo.key.dropFirst()), (1...12).contains(number),
               let scalar = Unicode.Scalar(0xF704 + number - 1) {
                // NSF1FunctionKey = U+F704, puis F2, F3… à la suite.
                key = KeyEquivalent(Character(scalar))
            } else if combo.key.count == 1, let character = combo.key.first {
                key = KeyEquivalent(character)
            } else {
                return nil
            }
        }
        var modifiers: EventModifiers = []
        if combo.modifiers.contains(.command) { modifiers.insert(.command) }
        if combo.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if combo.modifiers.contains(.option) { modifiers.insert(.option) }
        if combo.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}

extension View {
    /// Raccourci enregistré d'une commande des menus (aucun si l'utilisateur l'a retiré).
    @ViewBuilder func regShortcut(_ id: String, _ store: RegShortcutStore) -> some View {
        if let shortcut = store.shortcut(id) {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
