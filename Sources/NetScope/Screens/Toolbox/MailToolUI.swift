import NetScopeCore
import SwiftUI

// Éléments communs des outils courriel (Super outil, Santé courriel, Recherche MX, Listes noires,
// SPF/DKIM/DMARC) : source des réponses DNS, puces d'état, liste des constats, note sur 100 et
// tableau standard des vérifications.

enum MailTools {
    /// Réponses DNS : fixes en démonstration (aucun accès réseau), sinon le résolveur du système.
    static var client: MailDNSClient {
        Launcher.isDemo ? MailDemo.client : LiveMailDNSClient()
    }

    /// Saisie ramenée à un domaine (« ventes@exemple.ca », « https://exemple.ca/ » → « exemple.ca »).
    static func domain(from text: String) -> String? {
        let (kind, value) = MailInput.classify(text)
        switch kind {
        case .email: return MailInput.domain(ofEmail: value)
        case .domain, .hostname: return value
        default: return nil
        }
    }
}

extension MailStatus {
    var tone: Tone {
        switch self {
        case .ok: return .success
        case .info: return .accent
        case .warning: return .warning
        case .error: return .critical
        }
    }

    /// Libellé court des tableaux (comme les résultats récents : « Alerte »).
    var shortLabel: String {
        switch self {
        case .ok: return "OK"
        case .info: return "Info"
        case .warning: return "Alerte"
        case .error: return "Erreur"
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Puce d'état (OK, Info, Avertissement, Erreur) ; `text` remplace le libellé.
struct MailStatusChip: View {
    let status: MailStatus
    var text: String? = nil

    var body: some View {
        Chip(text: text ?? status.shortLabel, tone: status.tone, systemImage: status.symbol)
    }
}

/// « 4 OK · 3 avertissements · 2 erreurs » en puces colorées.
struct MailTallyChips: View {
    let statuses: [MailStatus]

    var body: some View {
        HStack(spacing: 6) {
            ForEach([MailStatus.error, .warning, .ok, .info], id: \.self) { status in
                let count = statuses.filter { $0 == status }.count
                if count > 0 { MailStatusChip(status: status, text: label(status, count)) }
            }
        }
    }

    private func label(_ status: MailStatus, _ count: Int) -> String {
        switch status {
        case .ok: return "\(count) OK"
        case .info: return "\(count) info\(count > 1 ? "s" : "")"
        case .warning: return "\(count) avertissement\(count > 1 ? "s" : "")"
        case .error: return "\(count) erreur\(count > 1 ? "s" : "")"
        }
    }
}

/// Note sur 100 dans un anneau coloré.
struct MailScoreRing: View {
    let score: Int
    var size: CGFloat = 64

    var body: some View {
        let grade = MailHealthGrade(score: score)
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                .stroke(grade.status.tone.dot, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: size * 0.34, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text("/ 100").font(.system(size: size * 0.15, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note \(score) sur 100")
    }
}

/// Constats d'une analyse : icône d'état, titre, explication et correction proposée.
struct MailFindingList: View {
    let findings: [MailFinding]
    var showFix = true
    var limit: Int? = nil

    var body: some View {
        let shown = limit.map { Array(findings.prefix($0)) } ?? findings
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, finding in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: finding.status.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(finding.status.tone.foreground)
                        .frame(width: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                        if !finding.detail.isEmpty {
                            Text(finding.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        if showFix, let fix = finding.fix {
                            Label(fix, systemImage: "arrow.turn.down.right")
                                .font(Theme.small)
                                .foregroundStyle(Theme.accentStrong)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            if let limit, findings.count > limit {
                Text("… et \(findings.count - limit) autre\(findings.count - limit > 1 ? "s" : "")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Ligne « en cours » : indicateur et étape.
struct MailProgressLine: View {
    let text: String
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            if let fraction { ProgressBar(fraction: fraction) }
        }
    }
}

/// Encadré d'un enregistrement brut (TXT), en SF Mono, sélectionnable.
struct MailRawRecord: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.consoleText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
    }
}

// MARK: - Tableau des vérifications

/// Ligne du tableau des vérifications (Super outil, Santé courriel).
struct MailCheckRow: Identifiable {
    let id: Int
    let check: MailCheck

    var sortStatus: Int { [MailStatus.error, .warning, .info, .ok].firstIndex(of: check.status) ?? 4 }
    var sortTitle: String { check.title.lowercased() }
    var sortResult: String { check.result.lowercased() }
    var sortDetail: String { check.detail.lowercased() }
    var sortPoints: Int { check.points ?? -1 }

    static func rows(_ checks: [MailCheck]) -> [MailCheckRow] {
        checks.enumerated().map { MailCheckRow(id: $0.offset, check: $0.element) }
    }
}

/// Vérifications (tableau standard « outils.courriel.super » ou « outils.courriel.sante ») :
/// état, vérification, résultat, détail ; points (santé) ; facultatives : catégorie, rang.
struct MailChecksTable: View {
    let rows: [MailCheckRow]
    @ObservedObject var table: StandardTableModel<MailCheckRow>
    var showPoints = false

    static func columns(points: Bool) -> [StandardColumn] {
        [
            StandardColumn(id: "etat", title: "État", isRequired: true),
            StandardColumn(id: "verification", title: "Contrôle"),
            StandardColumn(id: "resultat", title: "Résultat"),
            StandardColumn(id: "detail", title: "Détail"),
            StandardColumn(id: "points", title: "Points", isDefaultVisible: points),
            StandardColumn(id: "rang", title: "Ordre du bilan", isDefaultVisible: false),
        ]
    }

    static let sortKeys: [String: KeyPathComparator<MailCheckRow>] = [
        "etat": KeyPathComparator(\MailCheckRow.sortStatus),
        "verification": KeyPathComparator(\MailCheckRow.sortTitle),
        "resultat": KeyPathComparator(\MailCheckRow.sortResult),
        "detail": KeyPathComparator(\MailCheckRow.sortDetail),
        "points": KeyPathComparator(\MailCheckRow.sortPoints),
        "rang": KeyPathComparator(\MailCheckRow.id),
    ]

    /// Tri par défaut : l'ordre du bilan (MX, SPF, DMARC…).
    @MainActor
    static func makeModel(id: String, points: Bool) -> StandardTableModel<MailCheckRow> {
        StandardTableModel(id: id, columns: columns(points: points), sortKeys: sortKeys, defaultSort: "rang")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, emptyText: "Aucune vérification.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                    MailStatusChip(status: row.check.status)
                }
                .width(min: 70, ideal: 74)
                .customizationID("etat")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("CONTRÔLE", sortUsing: table.sort("verification")) { row in
                    ToolTableText(row.check.title, size: 12, mono: false, weight: .semibold).help(row.check.title)
                }
                .width(min: 70, ideal: 80)
                .customizationID("verification")

                TableColumn("RÉSULTAT", sortUsing: table.sort("resultat")) { row in
                    ToolTableText(row.check.result).help(row.check.result)
                }
                .width(min: 100, ideal: showPoints ? 130 : 150)
                .customizationID("resultat")

                TableColumn("DÉTAIL", sortUsing: table.sort("detail")) { row in
                    ToolTableText(row.check.detail, mono: false, color: Theme.textSecondary).help(row.check.detail)
                }
                .width(min: 90, ideal: showPoints ? 100 : 150)
                .customizationID("detail")

                TableColumn("POINTS", sortUsing: table.sort("points")) { row in
                    ToolTableText(row.check.pointsLabel, color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 46, ideal: 50)
                .customizationID("points")
                .defaultVisibility(showPoints ? .visible : .hidden)

                TableColumn("ORDRE", sortUsing: table.sort("rang")) { row in
                    ToolTableText("\(row.id + 1)", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 36, ideal: 48)
                .customizationID("rang")
                .defaultVisibility(.hidden)
            }
        }
    }
}
