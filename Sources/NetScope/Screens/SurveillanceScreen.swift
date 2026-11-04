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
                SidePanelSplit(sideWidth: Self.asideWidth, collapse: .below, matchesHeight: true) {
                    MonProbeTable()
                } side: {
                    MonEditor()
                }
                SidePanelSplit(sideWidth: Self.asideWidth, collapse: .below) {
                    MonJournalPanel()
                } side: {
                    VStack(spacing: 14) {
                        MonMenuPreview()
                        MonNotificationPreview()
                    }
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
        HStack(spacing: 6) {
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
            // Dans le même groupe que le statut, après un séparateur : sinon la barre d'outils colle
            // le point bleu à « hors ligne » (« 1 hors ligne● 00:42 »).
            if store.activeCount > 0 {
                Text("·").foregroundStyle(Theme.textTertiary)
                MonEngineIndicator()
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.trailing, 6)
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

/// Point bleu pulsé et durée du cycle « 00:42 » (croquis : « Surveillance en arrière-plan · cycle
/// 00:42 », raccourci ici pour tenir dans la barre d'outils à 1440 px ; la phrase complète est dans
/// l'infobulle).
struct MonEngineIndicator: View {
    @ObservedObject private var store = MonStore.shared
    @State private var dim = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)
                .opacity(dim ? 0.35 : 1)
                .onAppear {
                    guard store.demoNow == nil else { return }
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
                }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(
                    (store.demoNow ?? context.date).timeIntervalSince(store.cycleStart)))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .help("Surveillance en arrière-plan, cycle en cours depuis cette durée\u{00A0}: les sondes continuent de tourner fenêtre fermée (icône de la barre de menus).")
    }

    /// « 00:42 », « 59:59 », « 1:02:03 ».
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

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
