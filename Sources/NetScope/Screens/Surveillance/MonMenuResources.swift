import NetScopeCore
import SwiftUI

/// Tuile « Ce Mac » du menu de la barre de menus (note 21) : processeur, mémoire et réseau en
/// direct, lecture locale seulement. Les relevés tournent tant que le menu est ouvert.
struct MonMenuResourceTile: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var monitor = LocalResourceMonitor.shared
    /// Aperçu dans l'écran Surveillance : « Détails » change d'écran sans rouvrir la fenêtre.
    var isPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                MonHeading("Ce Mac")
                Spacer(minLength: 4)
                if let mac = thisMac {
                    Button("Détails") { show(mac) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accentStrong)
                        .help("Ouvrir l’onglet Ressources de ce Mac")
                }
            }
            row("Processeur", percent: monitor.cpu?.total, spark: monitor.timeline.series("cpu"))
            row("Mémoire", percent: monitor.memory?.usedPercent, spark: [],
                note: monitor.memory?.pressure.flatMap { $0 == .normal ? nil : "pression " + $0.label.lowercased() })
            HStack(spacing: 6) {
                Text("Réseau").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 74, alignment: .leading)
                let total = monitor.totalRate
                Text("↓\u{00A0}\(ResourceFormat.bitsPerSecond(total?.inBps))  ↑\u{00A0}\(ResourceFormat.bitsPerSecond(total?.outBps))")
                    .font(Theme.mono(11)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .onAppear { monitor.retain() }
        .onDisappear { monitor.release() }
    }

    /// Fiche de ce Mac dans l'inventaire (après un scan), pour « Détails ».
    private var thisMac: Device? {
        guard let address = state.activeInterface?.address else { return nil }
        return state.devices.first { $0.ip == address }
    }

    private func show(_ device: Device) {
        DeviceSession.shared.tab = .ressources
        state.selectedDeviceID = device.id
        if isPreview { state.open(.appareil) } else { MonWindow.open(screen: .appareil) }
    }

    private func row(_ title: String, percent: Double?, spark: [Double?], note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 74, alignment: .leading)
            ResourceBar(percent: percent, height: 5).frame(width: 70)
            Text(ResourceFormat.percent(percent)).font(Theme.mono(11)).foregroundStyle(Theme.text).frame(width: 46, alignment: .trailing)
            if let note {
                Text(note).font(Theme.caption).foregroundStyle(Theme.warning).lineLimit(1)
            } else if spark.count > 1 {
                Sparkline(values: Array(spark.suffix(40)), color: ResourceColors.load(percent), lineWidth: 1.2, filled: false)
                    .frame(height: 14)
            }
            Spacer(minLength: 0)
        }
    }
}
