import NetScopeCore
import SwiftUI

// Note 77 : éléments communs aux contrôleurs UniFi, Omada et Meraki (Switchs et ports, Wi-Fi,
// Réglages › Sites) : icône de la marque, puce d'état et bandeau des contrôleurs du site actif.

extension ControllerKind {
    /// Symbole de la marque (générique, jamais un logo).
    var symbol: String {
        switch self {
        case .unifi: return "circle.hexagongrid"
        case .omada: return "point.3.filled.connected.trianglepath.dotted"
        case .meraki: return "cloud"
        }
    }
}

/// Icône carrée de la marque d'un contrôleur (couleurs dynamiques de Theme).
struct ControllerKindIcon: View {
    let kind: ControllerKind
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
            Image(systemName: kind.symbol).font(.system(size: size * 0.44)).foregroundStyle(Theme.accentStrong)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.label)
    }
}

/// État d'un contrôleur : en lecture, lu, à configurer, erreur, pas encore lu.
struct ControllerStatusChip: View {
    @ObservedObject var store: SiteControllerStore
    let controller: SiteController

    var body: some View {
        let r = store.runtime[controller.id]
        if !controller.isEnabled {
            Chip(text: "Désactivé", tone: .neutral)
        } else if r?.busy == true {
            Chip(text: "Lecture…", tone: .accent)
        } else if r?.pending != nil {
            Chip(text: "Certificat à accepter", tone: .warning)
        } else if store.reading(controller.id) != nil, r?.error == nil {
            Chip(text: "Lu", tone: .success)
        } else if store.notReadyReason(controller) != nil {
            Chip(text: "À configurer", tone: .warning)
        } else if r?.error != nil {
            Chip(text: "Erreur", tone: .critical)
        } else {
            Chip(text: "Pas encore lu", tone: .neutral)
        }
    }
}

/// Ligne d'un contrôleur : marque, nom, adresse, état et ce qui a été lu (ou pourquoi rien).
struct ControllerSummaryLine: View {
    @ObservedObject var store: SiteControllerStore
    let controller: SiteController

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ControllerStatusChip(store: store, controller: controller)
            (Text(controller.displayName).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text)
                + Text(" · \(controller.kind.label)") + Text(controller.kind == .meraki ? "" : " · ")
                + Text(controller.kind == .meraki ? "" : controller.addressLabel).font(Theme.mono(11.5)).foregroundStyle(Theme.text)
                + Text(" · ") + detail)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detail: Text {
        let r = store.runtime[controller.id]
        if r?.busy == true { return Text("lecture en cours…") }
        if !controller.isEnabled { return Text("lecture désactivée dans Réglages › Sites.") }
        var parts: [String] = []
        if let reading = store.reading(controller.id) {
            let report = reading.report
            parts.append(report.siteName.map { "\(controller.kind == .meraki ? "réseau" : "site") «\u{00A0}\($0)\u{00A0}»" } ?? controller.scopeLabel)
            if let version = report.version { parts.append("version \(version)") }
            parts.append("\(report.switches.count) switch\(report.switches.count > 1 ? "s" : "")")
            parts.append("\(report.aps.count) borne\(report.aps.count > 1 ? "s" : "")")
            parts.append("\(report.clients.count) client\(report.clients.count > 1 ? "s" : "")")
            parts.append("lu \(SwitchText.ago(report.readAt))")
        }
        if let error = r?.error {
            parts.append(parts.isEmpty ? error : "dernière lecture en échec\u{00A0}: \(error)")
        } else if parts.isEmpty, let reason = store.notReadyReason(controller) {
            parts.append(reason.prefix(1).uppercased() + reason.dropFirst())
        } else if parts.isEmpty {
            parts.append("lu à la fin du prochain scan, ou avec «\u{00A0}Relire\u{00A0}».")
        }
        return Text(parts.joined(separator: " · "))
    }
}

/// Bandeau des contrôleurs UniFi, Omada et Meraki du site actif (Switchs et ports, Wi-Fi).
struct ControllerSitePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SiteControllerStore.shared
    @ObservedObject private var sites = SiteModel.shared
    /// « switchs » ou « bornes » : ce que l'écran montre de la lecture.
    var subject = "switchs"

    var body: some View {
        let controllers = store.activeControllers
        if !controllers.isEmpty {
            Panel(padding: 14) {
                AdaptiveStack(breakpoint: 900, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        ControllerKindIcon(kind: controllers[0].kind)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(controllers.count == 1 ? "Contrôleur du site\u{00A0}: \(controllers[0].kind.label)"
                                                        : "Contrôleurs du site\u{00A0}: \(controllers.count)")
                                .font(Theme.bodySemibold).foregroundStyle(Theme.text)
                            ForEach(controllers) { c in ControllerSummaryLine(store: store, controller: c) }
                            Text("Lecture seule par l’API du contrôleur (HTTPS)\u{00A0}: \(subject), ports, voisins et clients, prioritaires sur SNMP. Aucune modification n’est envoyée.")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button("Réglages…") {
                            RegNavigation.shared.section = .sites
                            state.open(.reglages)
                        }
                        .buttonStyle(.secondary)
                        Button { store.refreshNow(state: state) } label: {
                            HStack(spacing: 6) {
                                if store.isBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                                }
                                Text(store.isBusy ? "Lecture…" : "Relire")
                            }
                        }
                        .buttonStyle(.secondary)
                        .disabled(store.isBusy || !(store.hasReadyControllers || store.isDemo))
                        .help("Relit les contrôleurs du site actif (HTTPS, lecture seule)\u{00A0}: switchs, ports, bornes et clients.")
                    }
                    .fixedSize()
                }
            }
        }
    }
}
