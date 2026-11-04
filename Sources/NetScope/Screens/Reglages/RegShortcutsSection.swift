import NetScopeCore
import SwiftUI

/// Réglages › Raccourcis (croquis Reglages.dc.html, section « Raccourcis clavier ») : raccourcis
/// des menus par groupe, modifiables (clic sur les touches puis nouvelle combinaison), conflits
/// entre eux et avec macOS, retour aux valeurs par défaut. Les menus lisent `RegShortcutStore`.
struct RegShortcutsSection: View {
    @ObservedObject private var store = RegShortcutStore.shared
    @StateObject private var recorder = RegKeyRecorder()
    /// Message de l'enregistreur pour une commande (combinaison refusée).
    @State private var rejection: (id: String, text: String)?

    var body: some View {
        let conflicts = store.conflicts
        RegPanel(title: "Raccourcis clavier",
                 subtitle: "Raccourcis de la barre de menus. Les actions sur la sélection s’appliquent à l’appareil choisi dans le tableau.") {
            Button("Valeurs par défaut") {
                recorder.stop()
                rejection = nil
                store.resetAll()
            }
            .buttonStyle(RegSmallButtonStyle())
            .regDisabled(store.settings.customizedCount == 0)
            .help("Remet tous les raccourcis à leurs valeurs d’origine")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                summary(conflicts)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(ShortcutGroup.allCases) { group in
                        groupBox(group, conflicts: conflicts)
                    }
                }
                Text("Cliquez sur un raccourci puis tapez la nouvelle combinaison (avec ⌘, ⌃ ou ⌥)\u{00A0}; ⎋ annule, ⌫ retire le raccourci. Les raccourcis standard de macOS (⌘Q, ⌘H, ⌘W, ⌘C…) restent réservés.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { recorder.stop() }
    }

    @ViewBuilder private func summary(_ conflicts: [String: [ShortcutConflict]]) -> some View {
        let changed = store.settings.customizedCount
        if !conflicts.isEmpty {
            RegNotice("\(conflicts.count) raccourci\(conflicts.count > 1 ? "s" : "") en conflit\u{00A0}: un raccourci en double ou réservé par macOS ne fonctionne pas comme prévu. Choisissez-en un autre.",
                      tone: .warning)
        } else if changed > 0 {
            RegNotice("\(changed) raccourci\(changed > 1 ? "s" : "") personnalisé\(changed > 1 ? "s" : ""), aucun conflit.", tone: .success)
        }
    }

    private func groupBox(_ group: ShortcutGroup, conflicts: [String: [ShortcutConflict]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RegLabel(group.title).padding(.bottom, 6)
            ForEach(RegShortcutStore.actions.filter { $0.group == group }) { action in
                row(action, conflicts: conflicts[action.id] ?? [])
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func row(_ action: ShortcutAction, conflicts: [ShortcutConflict]) -> some View {
        let recording = recorder.recordingID == action.id
        let customized = store.settings.isCustomized(action)
        let combo = store.settings.combo(for: action)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(action.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(action.title)
                if customized {
                    Button { store.reset(action) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Revenir à " + (action.defaultCombo?.display ?? "aucun raccourci"))
                }
                Button {
                    rejection = nil
                    if recording {
                        recorder.stop()
                    } else {
                        recorder.start(action.id) { outcome in record(outcome, for: action) }
                    }
                } label: {
                    keys(combo: combo, recording: recording, conflicted: !conflicts.isEmpty)
                }
                .buttonStyle(.plain)
                .help(recording ? "Tapez la nouvelle combinaison (⎋ annule, ⌫ retire)" : "Cliquer pour changer le raccourci")
                .accessibilityLabel("Raccourci de « \(action.title) »\u{00A0}: \(combo?.display ?? "aucun")")
            }
            ForEach(conflicts, id: \.self) { conflict in
                Label(RegShortcutStore.describe(conflict), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rejection, rejection.id == action.id {
                Text(rejection.text).font(Theme.caption).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    @ViewBuilder private func keys(combo: KeyCombo?, recording: Bool, conflicted: Bool) -> some View {
        if recording {
            Text("Tapez le raccourci…")
                .font(Theme.small.weight(.medium))
                .foregroundStyle(Theme.accentStrong)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent))
        } else if let combo {
            RegKeyCaps(parts: combo.displayParts, tone: conflicted ? .warning : .neutral)
        } else {
            Text("Aucun")
                .font(Theme.small)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }

    private func record(_ outcome: RegKeyRecorder.Outcome, for action: ShortcutAction) {
        switch outcome {
        case .recorded(let combo):
            store.set(combo, for: action)
        case .cleared:
            store.set(nil, for: action)
        case .cancelled:
            break
        case .rejected(let text):
            rejection = (action.id, text)
        }
    }
}
