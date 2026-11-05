import NetScopeCore
import SwiftUI

/// Note 79 : le « Bilan de santé » (note sur 100, établi dans Trafic) rappelé en tête de l'écran
/// Historique et adressage quand il existe, avec un lien vers le détail. Rien n'est calculé ni lu
/// sur le réseau ici : le bilan est celui de l'écran Trafic, montré seulement s'il a été établi pour
/// les mêmes sites que ceux de l'écran ; en démonstration, celui du site actif (même calcul que la
/// section du rapport, sans rien modifier).
struct AnaHealthBanner: View {
    /// Sites (clés `SiteFiles.key`) montrés par l'écran.
    let siteKeys: [String]
    @EnvironmentObject private var state: AppState
    @ObservedObject private var traffic = TrafficStore.shared
    @ObservedObject private var sites = SiteModel.shared

    var body: some View {
        if let analysis = shownAnalysis ?? demoAnalysis {
            content(analysis)
        }
    }

    /// Bilan de Trafic, s'il porte exactement sur les sites de l'écran (jamais celui d'un autre site).
    private var shownAnalysis: NetworkAnalysisResult? {
        guard let analysis = traffic.analysis, let keys = traffic.analysisKeys,
              !keys.isEmpty, Set(keys) == Set(siteKeys) else { return nil }
        return analysis
    }

    /// Démonstration : bilan du site actif, calculé une fois par site (rien n'est modifié ni lu sur
    /// le réseau) ; montré seulement si l'écran montre ce site.
    private var demoAnalysis: NetworkAnalysisResult? {
        guard traffic.isDemo, traffic.analysis == nil else { return nil }
        let key = sites.activeKey
        guard siteKeys.contains(key) else { return nil }
        if let cached = AnaHealthDemoCache.analyses[key] { return cached }
        let analysis = traffic.reportContent(state: state).analysis
        AnaHealthDemoCache.analyses[key] = analysis
        return analysis
    }

    private func tone(_ analysis: NetworkAnalysisResult) -> Tone {
        analysis.count(.critical) > 0 ? .critical : (analysis.count(.warning) > 0 ? .warning : .success)
    }

    private func content(_ analysis: NetworkAnalysisResult) -> some View {
        Panel(padding: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    score(analysis)
                    text(analysis).frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                    chips(analysis).fixedSize()
                    openButton.fixedSize()
                }
                HStack(alignment: .center, spacing: 14) {
                    score(analysis)
                    VStack(alignment: .leading, spacing: 8) {
                        text(analysis)
                        HStack(spacing: 10) {
                            chips(analysis)
                            Spacer(minLength: 0)
                            openButton
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func score(_ analysis: NetworkAnalysisResult) -> some View {
        let tone = tone(analysis)
        return VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(analysis.score)").font(.system(size: 24, weight: .bold)).foregroundStyle(tone.foreground)
                Text("/\u{00A0}100").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            ProgressBar(fraction: Double(analysis.score) / 100, color: tone.foreground)
                .frame(width: 64)
        }
        .frame(width: 76)
        .accessibilityLabel("Note\u{00A0}: \(analysis.score) sur 100")
    }

    private func text(_ analysis: NetworkAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                Text("Bilan de santé du réseau").font(Theme.bodySemibold)
                Text("· \(analysis.grade)").font(Theme.bodyMedium).foregroundStyle(Theme.textSecondary)
            }
            .lineLimit(1)
            Text(analysis.summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Établi dans Trafic · \(InvFormat.timeOrStamp(analysis.date))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
        .help(analysis.summary)
    }

    private func chips(_ analysis: NetworkAnalysisResult) -> some View {
        let critical = analysis.count(.critical)
        let warning = analysis.count(.warning)
        return HStack(spacing: 6) {
            Chip(text: "\(critical) critique\(critical > 1 ? "s" : "")", tone: critical > 0 ? .critical : .neutral)
            Chip(text: "\(warning) alerte\(warning > 1 ? "s" : "")", tone: warning > 0 ? .warning : .neutral)
        }
    }

    private var openButton: some View {
        Button {
            TrafficScreenState.shared.part = .analyse
            state.open(.trafic)
        } label: {
            Label("Ouvrir le bilan", systemImage: "arrow.right")
        }
        .buttonStyle(.secondary)
        .help("Détail du bilan dans Trafic › Bilan de santé")
    }
}

/// Bilans de démonstration, calculés une fois par site actif (captures et --demo).
@MainActor
enum AnaHealthDemoCache {
    static var analyses: [String: NetworkAnalysisResult] = [:]
}
