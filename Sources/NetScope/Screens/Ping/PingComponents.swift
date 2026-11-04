import NetScopeCore
import SwiftUI

// Petits éléments de l'écran Ping continu, d'après docs/croquis/Ping.dc.html.

extension PingTargetStatus {
    var tone: Tone {
        switch self {
        case .attente: return .neutral
        case .enLigne: return .success
        case .perte: return .warning
        case .horsLigne: return .critical
        }
    }
}

/// Couleur d'une perte : orange dès qu'il y en a, rouge à partir de 5 %.
func pingLossColor(_ percent: Double) -> Color {
    percent >= 5 ? Theme.critical : percent > 0 ? Theme.warning : Theme.text
}

/// Pastille d'état arrondie (« En ligne », « Perte », « Hors ligne »).
struct PingStatusPill: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(Theme.captionSemibold)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(tone.background))
            .fixedSize()
    }
}

/// Courbe de latence d'une carte : 60 mesures, traits rouges aux pertes.
struct PingSparkline: View {
    let values: [Double?]
    var capacity = PingController.cardWindow
    var color: Color = Theme.accent

    var body: some View {
        Canvas { context, size in
            let offset = capacity - values.count
            let present = values.compactMap { $0 }
            let top = max((present.max() ?? 1) * 1.2, 0.001)
            let x = { (index: Int) in CGFloat(offset + index) / CGFloat(max(1, capacity - 1)) * size.width }
            let y = { (value: Double) in size.height - 2 - CGFloat(value / top) * (size.height - 4) }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(Theme.border), lineWidth: 1)

            var losses = Path()
            var line = Path()
            var penDown = false
            for (index, value) in values.enumerated() {
                guard let value else {
                    penDown = false
                    losses.move(to: CGPoint(x: x(index), y: 3))
                    losses.addLine(to: CGPoint(x: x(index), y: size.height - 3))
                    continue
                }
                let point = CGPoint(x: x(index), y: y(value))
                if penDown { line.addLine(to: point) } else { line.move(to: point) }
                penDown = true
            }
            context.stroke(losses, with: .color(Theme.critical.opacity(0.8)), lineWidth: 2)
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Groupe de boutons segmentés (« 56 o | 1472 o · MTU »).
struct PingSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var enabled = true
        var help: String? = nil
    }

    let options: [Option]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                // Choix pas encore disponible : texte secondaire, sans l'estompage de `.disabled` qui
                // le rendait presque illisible en mode sombre ; le clic ne fait rien.
                Button { if option.enabled { onSelect(option.value) } } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Color.white : option.enabled ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 4).fill(active ? Theme.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(option.enabled ? "" : "Pas encore disponible")
                .help(option.help ?? option.title)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Petite étiquette en capitales au-dessus d'une valeur.
struct PingMiniLabel: View {
    let text: String
    var size: CGFloat = 10

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

/// Tuile de statistique du grand graphe (« Actuel 13,9 ms »).
struct PingStatTile: View {
    let label: String
    let value: String
    var color: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PingMiniLabel(text: label, size: 11)
            Text(value)
                .font(Theme.mono(16, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Carte d'une cible : latence actuelle, état, courbe des 60 dernières mesures et statistiques.
struct PingTargetCard: View {
    let target: PingTarget
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let values = target.history.values(last: PingController.cardWindow)
        let stats = PingStatistics(values: values)
        let status = target.status
        let last = target.history.last
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                            .font(Theme.bodySemibold)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        (Text(target.addressLabel).font(Theme.mono(12)).foregroundColor(Theme.text)
                            + Text(target.role.isEmpty ? "" : " · \(target.role)").font(Theme.small).foregroundColor(Theme.textSecondary))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if target.error != nil {
                        PingStatusPill(text: "Erreur", tone: .critical)
                    } else {
                        PingStatusPill(text: status.label, tone: status.tone)
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latencyText(last))
                            .font(Theme.mono(26, weight: .semibold))
                            .foregroundStyle(status == .horsLigne || last?.isLost == true ? Theme.critical : Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(unitText(last))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(width: 96, alignment: .leading)
                    PingSparkline(values: values, color: sparkColor(status))
                        .frame(height: 40)
                }
                HStack(spacing: 4) {
                    statCell("Min", PingFormat.decimal(stats.min))
                    statCell("Moy", PingFormat.decimal(stats.average))
                    statCell("Max", PingFormat.decimal(stats.max))
                    statCell("Jitter", PingFormat.decimal(stats.jitter))
                    statCell("Perte", PingFormat.percent(stats.lossPercent), color: pingLossColor(stats.lossPercent),
                             bold: stats.lossPercent > 0)
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                HStack {
                    (Text("Envoyés / reçus ").foregroundColor(Theme.textSecondary)
                        + Text("\(target.history.totalSent) / \(target.history.totalReceived)").font(Theme.mono(11)).foregroundColor(Theme.text))
                    Spacer()
                    Text("seq \(last?.sequence ?? 0)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
                .font(Theme.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius)
                .strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        }
        .buttonStyle(.plain)
        .help(target.error ?? "Analyser \(target.addressLabel)")
        .contextMenu {
            Button("Copier l’adresse") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.addressLabel, forType: .string)
            }
            Divider()
            Button("Retirer la cible", role: .destructive, action: onRemove)
        }
    }

    private func latencyText(_ last: PingSample?) -> String {
        if target.error != nil { return "—" }
        guard let last else { return "—" }
        return last.rttMs.map { PingFormat.decimal($0) } ?? "—"
    }

    private func unitText(_ last: PingSample?) -> String {
        if let error = target.error { return error.contains("introuvable") ? "nom introuvable" : "socket refusée" }
        guard let last else { return target.address == nil ? "résolution…" : "en attente" }
        return last.failure?.label ?? "ms"
    }

    private func sparkColor(_ status: PingTargetStatus) -> Color {
        switch status {
        case .horsLigne: return Theme.critical
        case .perte: return Theme.warning
        default: return Theme.accent
        }
    }

    private func statCell(_ label: String, _ value: String, color: Color = Theme.text, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            PingMiniLabel(text: label)
            Text(value)
                .font(Theme.mono(12, weight: bold ? .semibold : .regular))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
