import NetScopeCore
import SwiftUI

/// Journal horodaté des événements : coupures, alertes, retours en ligne.
struct PingJournalPanel: View {
    @ObservedObject var controller: PingController
    var maxRows = 40

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let events = controller.events
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Journal des événements").font(Theme.panelTitle).foregroundStyle(Theme.text)
                Text("\(events.count) \(events.count > 1 ? "événements" : "événement")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("Effacer") { controller.clearEvents() }
                    .buttonStyle(PingSmallButtonStyle())
                    .disabled(events.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            HStack(spacing: 8) {
                counter("Coupures", events.filter { $0.level == .coupure }.count, Theme.critical)
                counter("Alertes", events.filter { $0.level == .alerte }.count, Theme.warning)
                counter("Rétablis", events.filter { $0.level == .retabli }.count, Theme.success)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            if events.isEmpty {
                Text("Aucun événement depuis la réinitialisation. Les pertes, retours en ligne et pics de latence s’afficheront ici.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(events.prefix(maxRows)) { event in row(event) }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func counter(_ title: String, _ count: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PingMiniLabel(text: title, size: 11)
            Text("\(count)").font(Theme.mono(15, weight: .semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ event: PingEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: event.date))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    tag(event.level)
                    Text(event.subject).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                }
                Text(event.message)
                    .font(Theme.small)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        .textSelection(.enabled)
    }

    private func tag(_ level: PingEvent.Level) -> some View {
        let colors: (Color, Color)
        switch level {
        case .coupure: colors = (Theme.criticalSoft, Theme.critical)
        case .alerte: colors = (Theme.warningSoft, Theme.warning)
        case .retabli: colors = (Theme.successSoft, Theme.success)
        case .info: colors = (Color(hex: 0xDBEAFE), Color(hex: 0x1E40AF))
        }
        return Text(level.label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(colors.1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(colors.0))
            .fixedSize()
    }
}
