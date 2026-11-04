import NetScopeCore
import SwiftUI

/// Écran « Analyseur Wi-Fi » (croquis docs/croquis/Wifi.dc.html) : connexion actuelle (lecture
/// locale par CoreWLAN), occupation des canaux et réseaux voisins (analyse à la demande seulement),
/// recommandations, RSSI récent et relevé de couverture.
struct WifiScreen: View {
    @ObservedObject private var store = WifiStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let toast = store.toast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold))
                        Text(toast).font(Theme.small)
                        Spacer()
                        Button { store.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .buttonStyle(.plain)
                            .help("Fermer le message")
                    }
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.successSoft))
                }
                if let error = store.scanError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
                        Text("Analyse impossible\u{00A0}: \(error)").font(Theme.small)
                        Spacer()
                    }
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warningSoft))
                }

                WifiConnectionPanel(store: store)

                SidePanelSplit(sideWidth: 300, collapse: .below) {
                    VStack(spacing: 14) {
                        WifiChannelPanel(store: store)
                        WifiNetworksTable(store: store)
                    }
                } side: {
                    VStack(spacing: 14) {
                        WifiRecommendationsPanel(store: store)
                        WifiHistoryPanel(store: store)
                        WifiSurveyPanel(store: store)
                    }
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .screenToolbar {
            statusBadge
            Button { store.surveyActive.toggle() } label: {
                Label(store.surveyActive ? "Terminer le relevé" : "Relevé", systemImage: "figure.walk")
            }
            .buttonStyle(.secondary)
            Button { store.scan() } label: {
                HStack(spacing: 6) {
                    if store.isScanning {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                    }
                    Text(store.isScanning ? "Analyse…" : "Analyser")
                }
            }
            .buttonStyle(.primary)
            .disabled(store.isScanning || store.noInterface)
            .help("Balaye les canaux Wi-Fi une fois (quelques secondes). Rien n’est lancé automatiquement.")
            Button { store.exportCSV() } label: { Label("Exporter CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .disabled(store.networks.isEmpty)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(store.lastScan == nil ? Theme.textTertiary : Theme.accent).frame(width: 8, height: 8)
            Text(store.isScanning ? "Analyse en cours…" : (store.lastScan.map { "Dernière analyse\u{00A0}: \(WifiText.timeSeconds($0))" } ?? "Aucune analyse"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(store.lastScan == nil ? Theme.textSecondary : Theme.accentStrong)
        .fixedSize()
    }
}
