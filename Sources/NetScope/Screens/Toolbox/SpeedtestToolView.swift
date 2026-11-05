import NetScopeCore
import SwiftUI

/// Speedtest et iperf3 dans la Boîte à outils (croquis docs/croquis/Speedtest.dc.html) : débit
/// Internet (Cloudflare, M-Lab, LibreSpeed, Ookla), choix du serveur, débit local par iperf3,
/// historique. L'ancien écran à part est retiré de la barre latérale (groupe Accès).
struct SpeedtestToolView: View {
    @ObservedObject var model: SpeedtestModel
    let tool: ToolKind

    /// Onglets de l'outil : Speedtest (Internet, serveurs, historique) ou iperf3 (réseau local,
    /// historique).
    private var tabs: [SpeedTab] { tool == .iperf ? [.lan, .historique] : [.internet, .serveurs, .historique] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tabBar
            Group {
                switch model.tab {
                case .internet: SpeedInternetView(model: model)
                case .serveurs: SpeedServersView(model: model)
                case .lan: SpeedLanView(model: model)
                case .historique: SpeedHistoryView(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: fitTab)
        .onChange(of: tool) { fitTab() }
    }

    private func fitTab() {
        if !tabs.contains(model.tab) { model.tab = tabs[0] }
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
                ForEach(tabs) { tab in
                    Text(tab == .historique ? "\(tab.label) (\(model.history.count))" : tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(model.tab.hint)
            // La phrase d'aide de l'onglet passe en info-bulle : le titre de l'outil la donne déjà.
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
            // iperf3 : l'état du dernier test Internet n'a pas sa place, sauf iperf3 en cours.
            if tool == .speedtest || model.lanRunning { statusPill }
            Button {
                model.exportCSV()
            } label: {
                Label("Exporter CSV", systemImage: "square.and.arrow.down")
                    .fixedSize()
            }
            .buttonStyle(.secondary)
            .speedDisabled(model.history.isEmpty)
        }
    }
}
