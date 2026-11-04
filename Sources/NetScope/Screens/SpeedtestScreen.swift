import NetScopeCore
import SwiftUI

/// Écran `Screen.speedtest` (croquis docs/croquis/Speedtest.dc.html) : débit Internet par
/// Cloudflare, débit local par iperf3, historique.
struct SpeedtestScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = SpeedtestModel.shared

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                Group {
                    switch model.tab {
                    case .internet: SpeedInternetView(model: model)
                    case .lan: SpeedLanView(model: model)
                    case .historique: SpeedHistoryView(model: model)
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .screenToolbar {
            statusPill
            Button {
                model.exportCSV()
            } label: {
                Label("Exporter CSV", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.secondary)
            .speedDisabled(model.history.isEmpty)
        }
    }

    private var statusPill: some View {
        let (text, tone, pulsing): (String, Tone, Bool) = {
            switch model.runState {
            case .running: return ("Test Internet en cours", .accent, true)
            case .stopped: return ("Test arrêté", .warning, false)
            case .failed: return ("Échec du test", .critical, false)
            case .done:
                if let down = model.downMbps, let up = model.upMbps {
                    return ("Dernier test : \(SpeedFormat.rate(down)) / \(SpeedFormat.rate(up)) Mb/s", .success, false)
                }
                return ("Prêt", .neutral, false)
            case .idle:
                return model.lanRunning ? ("iperf3 en cours", .accent, true) : ("Prêt", .neutral, false)
            }
        }()
        return SpeedStatusPill(text: model.lanRunning && !model.runState.isRunning ? "iperf3 en cours" : text,
                               tone: model.lanRunning && !model.runState.isRunning ? .accent : tone,
                               pulsing: pulsing || model.lanRunning)
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            // Onglets : contrôle segmenté natif (le nombre de tests suit « Historique »).
            Picker("Onglet", selection: $model.tab) {
                ForEach(SpeedTab.allCases) { tab in
                    Text(tab == .historique ? "\(tab.label) (\(model.history.count))" : tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Phrase d'aide : passe à la ligne en petite fenêtre plutôt que d'être tronquée.
            Text(model.tab.hint).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if let toast = model.toast {
                HStack(spacing: 6) {
                    Text(toast).font(Theme.small)
                    Button {
                        model.toast = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Fermer le message")
                }
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
