import AppKit
import NetScopeCore
import SwiftUI

/// Enregistreur de touches : pendant l'enregistrement, la prochaine combinaison tapée est lue
/// par un moniteur local d'AppKit (avant les menus, pour qu'un raccourci existant ne se déclenche
/// pas). ⎋ annule, ⌫ seul retire le raccourci.
@MainActor
final class RegKeyRecorder: ObservableObject {
    enum Outcome {
        case recorded(KeyCombo)
        case cleared
        case cancelled
        case rejected(String)
    }

    /// Commande en cours d'enregistrement.
    @Published private(set) var recordingID: String?
    private var monitor: Any?
    private var completion: ((Outcome) -> Void)?

    func start(_ id: String, completion: @escaping (Outcome) -> Void) {
        stop()
        recordingID = id
        self.completion = completion
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Seules des valeurs simples passent dans le contexte de l'acteur principal.
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let characters = event.characters(byApplyingModifiers: [])
            let consumed = MainActor.assumeIsolated {
                self.handle(keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: flags), characters: characters)
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
        completion = nil
    }

    private func finish(_ outcome: Outcome) {
        let completion = self.completion
        stop()
        completion?(outcome)
    }

    /// Vrai si l'événement est consommé.
    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard recordingID != nil else { return false }
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard let key = KeyCombo.key(keyCode: keyCode, characters: characters) else {
            return true
        }
        if modifiers.isEmpty, key == "escape" { finish(.cancelled); return true }
        if modifiers.isEmpty, key == "delete" || key == "forwardDelete" { finish(.cleared); return true }
        let combo = KeyCombo(key, modifiers)
        if let problem = combo.problem {
            finish(.rejected(problem))
        } else {
            finish(.recorded(combo))
        }
        return true
    }
}

/// Touches d'un raccourci, une case par touche (« ⇧ », « ⌘ », « R »), comme le croquis.
struct RegKeyCaps: View {
    let parts: [String]
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(tone == .neutral ? Theme.text : tone.foreground)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tone == .neutral ? Theme.panelMuted : tone.background))
                    .overlay(alignment: .bottom) {
                        // Bord inférieur plus épais, comme une touche.
                        RoundedRectangle(cornerRadius: 4).fill(Theme.borderStrong).frame(height: 2).padding(.horizontal, 1)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.borderStrong))
            }
        }
        .fixedSize()
    }
}
