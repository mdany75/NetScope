import NetScopeCore
import SwiftUI

/// Écran « Surveillance » (docs/croquis/Surveillance.dc.html) : état global, sondes avec
/// disponibilité 24 h, éditeur de sonde, journal des alertes, aperçus de la barre de menus et de
/// la notification. Les sondes tournent en arrière-plan (MonStore), fenêtre fermée comprise.
struct SurveillanceScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = MonStore.shared

    static let asideWidth: CGFloat = 352

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    MonProbeTable()
                        .frame(maxWidth: .infinity)
                    MonEditor()
                        .frame(width: Self.asideWidth)
                }
                HStack(alignment: .top, spacing: 14) {
                    MonJournalPanel()
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 14) {
                        MonMenuPreview()
                        MonNotificationPreview()
                    }
                    .frame(width: Self.asideWidth)
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
        }
        .screenToolbar { toolbarActions }
        .onAppear { store.attach(to: state) }
    }

    // MARK: Barre d'outils

    @ViewBuilder private var toolbarActions: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.success).frame(width: 8, height: 8)
                Text(MonText.plural(store.activeCount, "sonde active", "sondes actives"))
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.text)
            }
            Text("·").foregroundStyle(Theme.textTertiary)
            Text("\(store.warningCount) en alerte")
                .font(Theme.bodySemibold)
                .foregroundStyle(store.warningCount > 0 ? Theme.warning : Theme.textSecondary)
            Text("·").foregroundStyle(Theme.textTertiary)
            Text("\(store.downCount) hors ligne")
                .font(Theme.bodySemibold)
                .foregroundStyle(store.downCount > 0 ? Theme.critical : Theme.textSecondary)
        }
        .padding(.trailing, 4)
        Button { store.toggleAll() } label: {
            Label(store.activeCount > 0 ? "Tout suspendre" : "Tout reprendre",
                  systemImage: store.activeCount > 0 ? "pause" : "play")
        }
        .buttonStyle(.secondary)
        .disabled(store.probes.isEmpty)
        Button { store.exportJournal() } label: {
            Label("Exporter le journal", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.secondary)
        .disabled(store.journal.alerts.isEmpty)
        .help("Enregistrer le journal des alertes en CSV")
        Button { store.addProbe() } label: {
            Label("Nouvelle sonde", systemImage: "plus")
        }
        .buttonStyle(.primary)
    }
}

// MARK: - Éléments communs de l'écran

enum MonText {
    /// « 1 sonde active », « 12 sondes actives ».
    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) " + (count > 1 ? many : one)
    }

    static func tone(_ state: MonState?) -> Tone {
        switch state {
        case .ok: return .success
        case .warning: return .warning
        case .down: return .critical
        default: return .neutral
        }
    }

    static func label(_ state: MonState?) -> String { state?.label ?? "Inactive" }

    static func tone(_ severity: MonSeverity) -> Tone {
        switch severity {
        case .critical: return .critical
        case .warning: return .warning
        case .info: return .neutral
        case .success: return .success
        }
    }
}

/// Puce de filtre du croquis : capsule blanche, bleu clair bordé d'accent quand active.
struct MonFilterChip: View {
    let title: String
    let count: Int
    var dot: Color? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(isOn ? Theme.accentStrong : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(isOn ? Theme.accentSoft : Theme.panel))
            .overlay(Capsule().strokeBorder(isOn ? Theme.accent : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Intertitre de panneau (11 pt, majuscules, gris).
struct MonHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.55)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Cadre de panneau du croquis (blanc, bordure grise, rayon 8), sans marge intérieure.
struct MonPanelFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

extension View {
    func monPanel() -> some View { modifier(MonPanelFrame()) }
}
