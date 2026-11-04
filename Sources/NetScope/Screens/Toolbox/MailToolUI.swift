import NetScopeCore
import SwiftUI

// Éléments communs au diagnostic SMTP, à l'analyse d'en-têtes et à la recherche DNS étendue
// (note 14) : couleur d'un constat, liste de constats, console d'échange.

extension SMTPFinding.Level {
    var tone: Tone {
        switch self {
        case .ok: return .success
        case .info: return .accent
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    var recentStatus: ToolRecent.Status {
        switch self {
        case .ok: return .ok
        case .info: return .info
        case .warning: return .warning
        case .critical: return .failure
        }
    }
}

/// Liste de constats : pastille, titre, précision (du plus grave au plus rassurant).
struct ToolFindingList: View {
    let findings: [SMTPFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(findings.enumerated()), id: \.offset) { index, finding in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: finding.level.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(finding.level.tone.foreground)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if !finding.detail.isEmpty {
                            Text(finding.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Titre de section d'un résultat d'outil, avec un élément à droite (bouton, compte).
struct ToolSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolFieldLabel(title)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension ToolSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Console d'un échange SMTP (C : client, S : serveur), fond sombre comme le Whois.
struct SMTPTranscriptView: View {
    let lines: [SMTPTranscriptLine]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timestamp(line.offsetMs))
                            .foregroundColor(Theme.consoleMuted)
                            .frame(width: 64, alignment: .trailing)
                        Text(prefix(line.direction))
                            .foregroundColor(line.direction == .client ? Theme.consolePrompt : Theme.consoleMuted)
                            .frame(width: 18, alignment: .leading)
                        Text(line.text)
                            .foregroundColor(line.direction == .note ? Theme.consoleMuted : Theme.consoleText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(Theme.mono(11))
                }
            }
            .textSelection(.enabled)
            .padding(12)
        }
        .frame(minHeight: 120, maxHeight: 300)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
    }

    private func prefix(_ direction: SMTPTranscriptLine.Direction) -> String {
        switch direction {
        case .client: return "C:"
        case .server: return "S:"
        case .note: return "--"
        }
    }

    private func timestamp(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded()))\u{00A0}ms" : "\(ToolFormat.decimal(ms / 1000, digits: 2))\u{00A0}s"
    }
}
