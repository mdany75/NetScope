import NetScopeCore
import SwiftUI

/// Bannière discrète au lancement (note 35) : NetScope s'est fermé de façon inattendue depuis le
/// dernier plantage vu. « Exporter un diagnostic » ou « Ignorer » (date retenue).
struct CrashBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var controller = RegDiagnosticController.shared

    var body: some View {
        if let report = controller.pendingCrash {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NetScope s’est fermé de façon inattendue le \(Self.when(report.date)).")
                        .font(Theme.small).fontWeight(.semibold).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    Text("Un diagnostic (journal masqué et rapport de plantage, sans aucun secret) aide à trouver la cause.")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button("Exporter un diagnostic") {
                    RegNavigation.shared.section = .diagnostic
                    state.open(.reglages)
                    controller.export()
                }
                .buttonStyle(.secondary)
                .fixedSize()
                Button("Ignorer") { controller.dismissCrash() }
                    .buttonStyle(.ghost)
                    .fixedSize()
                    .help("Masque ce message jusqu’au prochain plantage")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.warningSoft.opacity(0.55))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    /// « 4 novembre à 16 h 42 ».
    static func when(_ date: Date) -> String {
        let locale = Locale(identifier: "fr_CA")
        let day = date.formatted(.dateTime.day().month(.wide).locale(locale))
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)
        return "\(day) à \(hour)\u{00A0}h\u{00A0}\(String(format: "%02d", minute))"
    }
}
