import NetScopeCore
import SwiftUI

/// Contenu du menu de la barre de menus (MenuBarExtra), aussi montré en aperçu dans l'écran :
/// état du réseau, passerelle, interface, alertes en cours, « Scan rapide », « Ouvrir NetScope ».
struct MonMenuContent: View {
    @ObservedObject private var store = MonStore.shared
    /// Aperçu dans l'écran Surveillance (la fenêtre est déjà ouverte).
    var isPreview = false
    var onScan: () -> Void
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("NetScope").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                RegPill(text: network.0, tone: network.1)
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    label("Passerelle")
                    value(gatewayText)
                }
                GridRow {
                    label("Interface")
                    value(store.interfaceSummary ?? "Aucune interface active")
                }
            }
            MonMenuResourceTile(isPreview: isPreview)
            MonMenuServiceSection(isPreview: isPreview)
            VStack(alignment: .leading, spacing: 5) {
                let alerting = store.alertingProbes
                MonHeading(alerting.isEmpty ? "Aucune alerte" : MonText.plural(alerting.count, "alerte", "alertes"))
                ForEach(alerting.prefix(4)) { probe in
                    HStack(spacing: 7) {
                        Circle().fill(store.state(of: probe) == .down ? Theme.critical : Theme.warning).frame(width: 8, height: 8)
                        Text(probe.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(1).fixedSize()
                        Text(store.lastValue(of: probe)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.vertical, 1)
                }
                if alerting.isEmpty {
                    Text(store.activeCount == 0 ? "Aucune sonde active." : "Toutes les sondes répondent.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            HStack(spacing: 6) {
                Button(action: onScan) {
                    Label("Scan rapide", systemImage: "magnifyingglass").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(MonSmallPrimaryStyle())
                .help("Ouvrir le Scanner")
                Button(action: onOpen) {
                    Text("Ouvrir NetScope").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(MonCompactButtonStyle(height: 28))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .frame(width: 290, alignment: .leading)
        .background(Theme.panel)
    }

    private var network: (String, Tone) {
        if store.downCount > 0 { return ("Réseau dégradé", .critical) }
        if store.warningCount > 0 { return ("Attention requise", .warning) }
        return ("Réseau OK", .success)
    }

    private var gatewayText: String {
        guard let gateway = store.gatewayAddress else { return "Inconnue" }
        guard let latency = store.gatewayLatency else { return "\(gateway) · —" }
        return "\(gateway) · \(ToolFormat.milliseconds(latency))"
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
    }
}

/// Icône de la barre de menus : la cible de NetScope et le nombre de sondes en alerte.
struct MonMenuLabel: View {
    @ObservedObject private var store = MonStore.shared

    var body: some View {
        let count = store.alertingProbes.count
        if count > 0 {
            Label("\(count)", systemImage: "scope")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "scope")
        }
    }
}

/// Bouton principal compact (28 pt) du menu.
struct MonSmallPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.accentStrong : Theme.accent))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
            .fixedSize()
    }
}

// MARK: - Aperçus dans l'écran

/// Panneau « Barre de menus » : aperçu du menu tel qu'il s'ouvre depuis l'icône.
struct MonMenuPreview: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = MonStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonHeading("Barre de menus")
                Text("Aperçu du menu").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 4).fill(Color(light: 0xCBD5E1, dark: 0x273444)).frame(width: 26, height: 20)
                            .overlay(Image(systemName: "scope").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text))
                        let count = store.alertingProbes.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 13, minHeight: 13)
                                .background(Capsule().fill(Theme.critical))
                                .offset(x: 4, y: -2)
                        }
                    }
                    Image(systemName: "wifi").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "switch.2").font(.system(size: 12, weight: .semibold))
                    Text(Self.clock(store.now)).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.border)
                HStack {
                    Spacer(minLength: 0)
                    MonMenuContent(isPreview: true, onScan: { state.open(.scanner) }, onOpen: { state.open(.scanner) })
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong))
                        .shadow(color: Color(hex: 0x0F172A, opacity: 0.16), radius: 14, y: 8)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .background(Theme.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    /// « mar. 3 nov. 14:32 ».
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

/// Panneau « Notification macOS » : aperçu de la bannière de l'alerte la plus récente.
struct MonNotificationPreview: View {
    @ObservedObject private var store = MonStore.shared
    @State private var hiddenID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonHeading("Notification macOS")
                Text("Aperçu de la bannière").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            if let alert = latest {
                if hiddenID == alert.id {
                    HStack(spacing: 8) {
                        Text("Notification ignorée.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        Button("Réafficher") { hiddenID = nil }
                            .buttonStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    banner(alert)
                }
            } else {
                Text("Aucune alerte en cours\u{00A0}: rien à notifier.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            Text(footnote)
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    /// Alerte active la plus récente (critique ou alerte, non résolue).
    private var latest: MonAlert? {
        let open = store.journal.alerts.filter { !$0.isResolved && $0.probeID != nil }
        // La panne d'abord, comme la notification la plus importante.
        return open.first { $0.severity == .critical } ?? open.first { $0.severity == .warning }
    }

    private var footnote: String {
        let failures = store.selectedProbe?.thresholds.failures ?? 3
        var text = "Envoyée après \(failures) échec\(failures > 1 ? "s" : "") consécutif\(failures > 1 ? "s" : "") · regroupée par sonde · sans son pendant le mode Concentration."
        if !store.isSimulated && !MonNotifier.shared.isAvailable {
            text += " Notifications indisponibles hors de l’app installée."
        }
        return text
    }

    private func banner(_ alert: MonAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.accent)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "scope").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.onAccent))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("NETSCOPE").font(Theme.captionSemibold).kerning(0.44)
                    Spacer(minLength: 4)
                    Text("maintenant").font(Theme.caption)
                }
                .foregroundStyle(Theme.textSecondary)
                Text(title(alert)).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(alert.message).font(Theme.small).foregroundStyle(Theme.neutralText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Ouvrir la sonde") {
                        if let id = alert.probeID { store.selectedID = id }
                    }
                    Button("Ignorer") { hiddenID = alert.id }
                }
                .buttonStyle(MonCompactButtonStyle(height: 26))
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.borderStrong))
        .shadow(color: Color(hex: 0x0F172A, opacity: 0.10), radius: 9, y: 6)
    }

    private func title(_ alert: MonAlert) -> String {
        alert.severity == .critical ? "\(alert.probeName) hors ligne" : "\(alert.probeName) en alerte"
    }
}
