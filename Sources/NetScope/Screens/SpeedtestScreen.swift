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
            HStack(spacing: 2) {
                ForEach(SpeedTab.allCases) { tab in
                    let selected = model.tab == tab
                    Button {
                        model.tab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Text(tab.label).font(.system(size: 13, weight: .semibold))
                            if tab == .historique {
                                Text("\(model.history.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                            .fill(selected ? Theme.panel : Color.clear)
                            .shadow(color: selected ? Color(hex: 0x0F172A, opacity: 0.12) : .clear, radius: 1, y: 1))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.neutralSoft))
            Text(model.tab.hint).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Spacer()
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
