import NetScopeCore
import SwiftUI

/// Tuile « Services en ligne » de l'écran Surveillance (note 15) : bilan des grands services et
/// ceux en difficulté ; un clic ouvre l'outil « État des services ».
struct MonServiceTile: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var svc = SvcStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonHeading("Services en ligne")
                RegPill(text: pill, tone: svc.overallTone)
                Spacer(minLength: 4)
                Button("Ouvrir l’outil") { open(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentStrong)
            }
            Text(svc.summaryLine).font(Theme.small).foregroundStyle(Theme.textSecondary)
            let problems = svc.problemServices
            if problems.isEmpty {
                Text(svc.currentSnapshots.isEmpty
                     ? "Ouvrir l’outil «\u{00A0}État des services\u{00A0}» de la Boîte à outils pour suivre Microsoft 365, AWS, Google, GitHub…"
                     : "Tous les services suivis fonctionnent.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(problems.prefix(4)) { service in
                MonServiceRow(service: service) { open(service.id) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private var pill: String {
        if svc.currentSnapshots.isEmpty { return "Non suivi" }
        switch svc.overallTone {
        case .critical: return "Problème"
        case .warning: return "Dégradé"
        default: return "OK"
        }
    }

    private func open(_ id: String?) {
        if let id { svc.selectedServiceID = id }
        ToolStore.shared.open(.cloud, in: state)
    }
}

/// Ligne d'un service en difficulté (tuile de Surveillance et menu de la barre de menus).
struct MonServiceRow: View {
    let service: SvcService
    var action: () -> Void
    @ObservedObject private var svc = SvcStore.shared

    var body: some View {
        let verdict = svc.snapshot(service.id)?.verdict
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(SvcTone.tone(verdict?.health).dot).frame(width: 8, height: 8)
                Text(service.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).fixedSize()
                Text(verdict.map { ($0.health == .unreachable ? "" : $0.health.label + " · ") + $0.headline } ?? "")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(verdict.map { [$0.headline, $0.detail].compactMap { $0 }.joined(separator: "\n") } ?? "")
    }
}

/// Section « Services en ligne » du menu de la barre de menus : visible dès qu'un service est suivi.
struct MonMenuServiceSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var svc = SvcStore.shared
    var isPreview = false

    var body: some View {
        if !svc.currentSnapshots.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                MonHeading("Services en ligne")
                Text(svc.summaryLine).font(Theme.small)
                    .foregroundStyle(svc.overallTone == .success ? Theme.textSecondary : svc.overallTone.foreground)
                    .lineLimit(1)
                ForEach(svc.problemServices.prefix(3)) { service in
                    MonServiceRow(service: service) { open(service.id) }
                }
            }
            .padding(.top, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    private func open(_ id: String) {
        svc.selectedServiceID = id
        ToolStore.shared.selectedTool = .cloud
        ToolStore.shared.toolFilter = ""
        if isPreview { state.open(.outils) } else { MonWindow.open(screen: .outils) }
    }
}

/// Condition de la sonde « Service en ligne » : choix du service dans le catalogue.
struct MonServiceConditionFields: View {
    @Binding var probe: MonProbe
    @ObservedObject private var svc = SvcStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Service").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                MonMenuField(title: matched?.name ?? "Choisir dans le catalogue") {
                    ForEach(svc.services) { service in
                        Button(service.name) {
                            probe.target = service.name
                            if probe.name.isEmpty || probe.name == "Nouvelle sonde" { probe.name = service.name }
                        }
                    }
                }
            }
            Text(matched == nil && !probe.target.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "«\u{00A0}\(probe.target)\u{00A0}» n’est pas dans le catalogue (Boîte à outils › État des services)."
                 : "Panne publiée ou service injoignable d’ici\u{00A0}: échec\u{00A0}; service dégradé\u{00A0}: alerte. Page d’état officielle et test DNS, TLS et HTTPS depuis ce réseau.")
                .font(Theme.caption)
                .foregroundStyle(matched == nil && !probe.target.isEmpty ? Theme.warning : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var matched: SvcService? { SvcCatalog.find(probe.target, in: svc.services) }

    /// Au passage à ce type : pas de seuil de latence ni de perte (la latence HTTPS d'un grand
    /// service dépasse souvent 50 ms sans que ce soit un problème), cinq minutes d'intervalle.
    static func prepare(_ probe: inout MonProbe) {
        guard probe.kind == .onlineService else { return }
        probe.thresholds.latencyMs = nil
        probe.thresholds.lossPercent = nil
        if probe.interval < 300 { probe.interval = 300 }
        if SvcCatalog.find(probe.target, in: SvcStore.shared.services) == nil { probe.target = "Microsoft 365" }
    }
}
