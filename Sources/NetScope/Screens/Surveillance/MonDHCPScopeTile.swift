import NetScopeCore
import SwiftUI

/// Tuile « Étendues DHCP » de l'écran Surveillance (note 37) : bilan des étendues de la FortiGate
/// du site (ou estimation) et celles qui approchent de la saturation ; un clic ouvre l'outil
/// « Étendues DHCP » sur l'étendue.
struct MonDHCPScopeTile: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var scopes = DHCPScopeStore.shared
    @ObservedObject private var dhcp = ToolStore.shared.dhcp

    var body: some View {
        let overview = scopes.overview(devices: state.devices)
        let levelled = DHCPScopeAnalysis.relevel(overview.scopes, thresholds: scopes.thresholds)
        let active = levelled.filter { $0.level != .inactive }
        let alerting = active.filter { $0.level >= .warning }.sorted { ($0.level, $0.percent) > ($1.level, $1.percent) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonHeading("Étendues DHCP")
                RegPill(text: pill(overview, alerting: alerting), tone: tone(alerting))
                Spacer(minLength: 4)
                Button("Ouvrir l’outil") { open(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentStrong)
            }
            Text(summary(overview, active: active))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if overview.scopes.isEmpty {
                Text("Relire la FortiGate du site dans l’outil «\u{00A0}Étendues DHCP\u{00A0}» de la Boîte à outils, ou lancer un Test DHCP pour une estimation.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if alerting.isEmpty {
                Text("Toutes les étendues ont des adresses libres (sous \(MonFormat.percent(scopes.thresholds.warningPercent))).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            ForEach(alerting.prefix(4)) { scope in
                MonDHCPScopeRow(scope: scope, multiSite: overview.isMultiSite) { open(scope.id) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private func summary(_ overview: DHCPScopeOverview, active: [DHCPScopeUsage]) -> String {
        guard !overview.scopes.isEmpty else { return "Aucune étendue lue." }
        let free = active.reduce(0) { $0 + $1.free }
        var text = MonText.plural(active.count, "étendue active", "étendues actives") + " · \(free) adresse\(free > 1 ? "s" : "") libre\(free > 1 ? "s" : "")"
        if overview.isEstimate {
            text += " · estimation (Test DHCP et scan)"
        } else {
            text += " · \(scopes.sitesLabel)"
            if let date = scopes.lastRefresh { text += ", lue \(ToolText.relative(date))" }
        }
        return text
    }

    private func pill(_ overview: DHCPScopeOverview, alerting: [DHCPScopeUsage]) -> String {
        if overview.scopes.isEmpty { return "Non lu" }
        if alerting.contains(where: { $0.level == .critical }) { return "Critique" }
        if !alerting.isEmpty { return "Presque pleine" + (alerting.count > 1 ? "s" : "") }
        return overview.isEstimate ? "Estimation" : "OK"
    }

    private func tone(_ alerting: [DHCPScopeUsage]) -> Tone {
        if alerting.contains(where: { $0.level == .critical }) { return .critical }
        return alerting.isEmpty ? .success : .warning
    }

    private func open(_ id: String?) {
        if let id { scopes.selectedScopeID = id }
        ToolStore.shared.open(.dhcpScopes, in: state)
    }
}

/// Ligne d'une étendue presque pleine : nom, jauge, adresses libres.
private struct MonDHCPScopeRow: View {
    let scope: DHCPScopeUsage
    let multiSite: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(DHCPScopeRow.color(scope.level)).frame(width: 8, height: 8)
                Text(scope.displayName + (multiSite ? " · \(scope.site)" : ""))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                ProgressBar(fraction: scope.percent / 100, color: DHCPScopeRow.color(scope.level), height: 5)
                    .frame(width: 56)
                Text(scope.percentLabel)
                    .font(Theme.mono(11, weight: .semibold)).foregroundStyle(DHCPScopeRow.color(scope.level))
                    .frame(minWidth: 34, alignment: .trailing)
                Text("\(scope.free) libre\(scope.free > 1 ? "s" : "")")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).fixedSize()
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(DHCPScopeAnalysis.alertText(scope) ?? scope.displayName)
    }
}

/// Conditions de la sonde « Étendue DHCP presque pleine » dans l'éditeur.
struct MonDHCPScopeConditionFields: View {
    @Binding var probe: MonProbe
    @State private var warningText: String?
    @State private var criticalText: String?

    var body: some View {
        let t = probe.dhcpThresholds ?? .standard
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Alerte à").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                MonInput(placeholder: "80", text: Binding(get: { warningText ?? MonFormat.number(t.warningPercent) }, set: { text in
                    warningText = text
                    guard let v = Self.number(text) else { return }
                    let current = probe.dhcpThresholds ?? .standard
                    probe.dhcpThresholds = DHCPScopeThresholds(warningPercent: v, criticalPercent: max(v, current.criticalPercent),
                                                               expiringMinutes: current.expiringMinutes)
                }), mono: true)
                .frame(width: 52)
                Text("%, critique à").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                MonInput(placeholder: "95", text: Binding(get: { criticalText ?? MonFormat.number(t.criticalPercent) }, set: { text in
                    criticalText = text
                    guard let v = Self.number(text) else { return }
                    let current = probe.dhcpThresholds ?? .standard
                    probe.dhcpThresholds = DHCPScopeThresholds(warningPercent: min(v, current.warningPercent), criticalPercent: v,
                                                               expiringMinutes: current.expiringMinutes)
                }), mono: true)
                .frame(width: 52)
                Text("%").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
            }
            .onChange(of: probe.id) { _, _ in
                warningText = nil
                criticalText = nil
            }
            Text("D’après la dernière lecture des étendues de la FortiGate (relue au plus à chaque intervalle, en lecture seule)\u{00A0}; sans FortiGate, d’après l’estimation du Test DHCP.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func number(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), v > 0, v <= 100 else { return nil }
        return v
    }

    /// Nouveau type choisi : toutes les étendues, seuils par défaut, sans seuil de latence.
    static func prepare(_ probe: inout MonProbe) {
        guard probe.kind == .dhcpScope else { return }
        probe.thresholds.latencyMs = nil
        probe.thresholds.lossPercent = nil
        if probe.interval < 300 { probe.interval = 300 }
        if probe.dhcpThresholds == nil { probe.dhcpThresholds = DHCPScopeStore.shared.thresholds }
        if probe.target.trimmingCharacters(in: .whitespaces).isEmpty { probe.target = "*" }
    }
}
