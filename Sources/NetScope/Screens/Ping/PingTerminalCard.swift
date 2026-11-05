import NetScopeCore
import SwiftUI

/// Carte retournée d'une cible (croquis C) : ses dernières réponses défilent comme un ping dans
/// Terminal. Un clic la remet à l'endroit. Sombre dans les deux apparences, comme Terminal.
struct PingTerminalCard: View {
    let target: PingTarget
    let payloadSize: Int
    let onFlipBack: () -> Void
    let onTogglePause: () -> Void
    let onRemove: () -> Void

    /// Lignes affichées : la carte garde la hauteur d'une carte à l'endroit.
    private static let lines = 7

    var body: some View {
        // Pas un Button : le petit bouton pause de l'en-tête doit recevoir son propre clic.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(target.name).font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.consolePrompt)
                    .lineLimit(1)
                Text(target.endpointLabel).font(Theme.mono(11)).foregroundStyle(Theme.consoleMuted).lineLimit(1)
                Spacer(minLength: 4)
                if target.isPaused {
                    Text("EN PAUSE").font(Theme.mono(10, weight: .semibold)).foregroundStyle(Color(hex: 0xFFB340))
                }
                PingPauseButton(isPaused: target.isPaused, action: onTogglePause, console: true)
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.consoleMuted)
            }
            .padding(.bottom, 4)
            let samples = target.history.samples.suffix(target.isPaused ? Self.lines - 1 : Self.lines)
            if samples.isEmpty {
                Text(target.error ?? "En attente de la première réponse…")
                    .font(Theme.mono(11)).foregroundStyle(Theme.consoleMuted)
            }
            ForEach(Array(samples), id: \.sequence) { sample in
                line(sample)
            }
            if let since = target.pauses.pausedSince {
                Text("--- en pause depuis \(Self.clock.string(from: since)), aucun envoi ---")
                    .font(Theme.mono(11)).foregroundStyle(Color(hex: 0xFFB340))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Clic\u{00A0}: revenir à la carte")
                .font(Theme.mono(10)).foregroundStyle(Theme.consoleMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.accent, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .onTapGesture(perform: onFlipBack)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Revenir à la carte", onFlipBack)
        .help("Réponses de \(target.endpointLabel) · clic\u{00A0}: revenir à la carte")
        .contextMenu {
            Button(target.isPaused ? "Reprendre la cible" : "Mettre la cible en pause", action: onTogglePause)
            Button("Copier les réponses") {
                NSPasteboard.general.clearContents()
                let lines: [String] = target.history.samples.suffix(60).map { text($0) }
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Retirer la cible", role: .destructive, action: onRemove)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func line(_ sample: PingSample) -> some View {
        let slow = (sample.rttMs ?? 0) > target.thresholdMs
        return Text(text(sample, compact: true) + (slow ? "  ← lent" : ""))
            .font(Theme.mono(11))
            .foregroundStyle(sample.isLost ? Color(hex: 0xFF6B6B) : slow ? Color(hex: 0xFFB340) : Theme.consoleText)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// `compact` : ligne de la carte (HTTP : seulement le temps TCP, le détail complet est copié).
    private func text(_ sample: PingSample, compact: Bool = false) -> String {
        guard let rtt = sample.rttMs else {
            let reason = sample.failure?.label ?? "délai dépassé"
            let detail = sample.detail.map { " (\($0))" } ?? ""
            return "\(reason.prefix(1).uppercased() + reason.dropFirst())\u{00A0}: seq=\(sample.sequence)\(detail)"
        }
        // Note 65 : réponses façon tcping et curl pour les cibles TCP et HTTP(S).
        switch target.kind {
        case .icmp:
            return "\(payloadSize + 8) octets de \(target.addressLabel)\u{00A0}: seq=\(sample.sequence) temps=\(PingFormat.decimal(rtt)) ms"
        case .tcp:
            return "Connecté à \(target.endpointLabel)\u{00A0}: seq=\(sample.sequence) temps=\(PingFormat.decimal(rtt)) ms"
        case .http:
            let code = sample.statusCode.map { "HTTP \($0)" } ?? "HTTP"
            let parts = sample.detail?.components(separatedBy: " · ") ?? []
            let tcp = parts.first { $0.hasPrefix("TCP") }?.replacingOccurrences(of: "\u{00A0}ms", with: "")
            let detail = compact ? (tcp.map { " · \($0)" } ?? "") : (sample.detail.map { " (\($0))" } ?? "")
            return "\(code)\u{00A0}: seq=\(sample.sequence) temps=\(PingFormat.decimal(rtt)) ms\(detail)"
        }
    }
}
