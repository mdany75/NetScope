import NetScopeCore
import SwiftUI

/// Note 78 : meilleur canal conseillé dans chaque bande (2,4, 5 et 6 GHz), d'après la dernière
/// analyse. Une ligne par bande : canal conseillé, verdict sur le canal de la connexion, explication ;
/// « Voir » montre la bande dans l'occupation des canaux.
struct WifiChannelAdvicePanel: View {
    @ObservedObject var store: WifiStore

    var body: some View {
        let advices = store.channelAdvice
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WifiHeading("Meilleur canal")
                    Spacer(minLength: 0)
                }
                if advices.allSatisfy({ $0.verdict == .noScan }) {
                    Text("Cliquez sur «\u{00A0}Analyser\u{00A0}»\u{00A0}: le canal le moins encombré de chaque bande est conseillé d’après les réseaux voisins.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(advices) { advice in row(advice) }
                    }
                }
            }
        }
    }

    private func row(_ advice: WifiChannelAdvice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(advice.band.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    .frame(minWidth: 48, alignment: .leading)
                if let best = advice.shown {
                    Text(best.label).font(Theme.mono(13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                } else {
                    Text("—").font(Theme.mono(13)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
                verdictPill(advice)
            }
            if let best = advice.shown, best.isDFS || best.isPSC {
                HStack(spacing: 6) {
                    if best.isDFS {
                        WifiPill(text: "DFS", foreground: Theme.warning, background: Theme.warningSoft, size: 10)
                            .help("Canal DFS (52 à 144)\u{00A0}: la borne doit écouter les radars avant d’émettre, et change de canal si elle en détecte un.")
                    }
                    if best.isPSC {
                        WifiPill(text: "PSC", size: 10)
                            .help("Canal PSC\u{00A0}: les appareils le sondent en priorité en 6\u{00A0}GHz.")
                    }
                }
            }
            Text(advice.summary).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if advice.best != nil, store.band != advice.band {
                Button("Voir la bande \(advice.band.label)") { store.band = advice.band }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Montre cette bande dans l’occupation des canaux")
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private func verdictPill(_ advice: WifiChannelAdvice) -> some View {
        switch advice.verdict {
        case .keep: WifiPill(text: "Canal actuel bon", foreground: Theme.success, background: Theme.successSoft, size: 10)
        case .change: WifiPill(text: "À changer", foreground: Theme.warning, background: Theme.warningSoft, size: 10)
        case .suggest: WifiPill(text: advice.networkCount == 0 ? "Bande libre" : "Conseillé", foreground: Theme.accentStrong,
                                background: Theme.accentSoft, size: 10)
        case .noScan: EmptyView()
        }
    }
}
