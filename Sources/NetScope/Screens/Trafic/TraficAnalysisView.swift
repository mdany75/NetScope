import NetScopeCore
import SwiftUI

/// « Analyse complète du réseau » (note 54) : note, synthèse, ce qui a été analysé, puis les points
/// classés par gravité (trafic, sécurité, santé, inventaire) avec explication, action conseillée
/// et « Voir » vers l'appareil, le port, la borne, l'étendue ou l'onglet concerné.
struct TrafficAnalysisView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = TrafficStore.shared
    @ObservedObject private var screen = TrafficScreenState.shared
    @State private var area: NetworkFindingArea?

    var body: some View {
        if let analysis = store.analysis {
            content(analysis)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ToolNotice(tone: .accent, title: "Bilan de santé du réseau",
                           message: "Un bilan qui réunit le trafic (plus gros consommateurs, applications inattendues, pays inhabituels), la sécurité (menaces, appareils visés), la santé (WAN, ports de switch, Wi-Fi, étendues DHCP) et l’inventaire (appareils inconnus). Rien n’est envoyé sur le réseau\u{00A0}: le bilan réunit ce que NetScope a déjà lu.")
                Button {
                    store.runAnalysis(state: state)
                } label: { Label("Établir le bilan", systemImage: "stethoscope") }
                    .buttonStyle(.primary)
                    .fixedSize()
            }
        }
    }

    private func content(_ analysis: NetworkAnalysisResult) -> some View {
        let shown = analysis.findings.filter { area == nil || $0.area == area }
        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    scoreTile(analysis).frame(width: 280)
                    coverage(analysis)
                }
                VStack(alignment: .leading, spacing: 14) {
                    scoreTile(analysis)
                    coverage(analysis)
                }
            }
            HStack(spacing: 10) {
                Picker("Domaine", selection: $area) {
                    Text("Tout (\(analysis.findings.filter { $0.severity != .ok }.count))").tag(NetworkFindingArea?.none)
                    ForEach(NetworkFindingArea.allCases, id: \.self) { item in
                        Text("\(item.label) (\(analysis.findings(item).filter { $0.severity != .ok }.count))").tag(Optional(item))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 8)
                Text("Bilan du \(InvFormat.timeOrStamp(analysis.date))").font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
                Button {
                    store.runAnalysis(state: state)
                } label: { Label("Relancer", systemImage: "arrow.clockwise") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
            VStack(spacing: 8) {
                ForEach(shown) { finding in
                    TrafficFindingCard(finding: finding) { open(finding.target) }
                }
                if shown.isEmpty {
                    Text("Aucun point dans ce domaine.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func scoreTile(_ analysis: NetworkAnalysisResult) -> some View {
        let tone: Tone = analysis.count(.critical) > 0 ? .critical : (analysis.count(.warning) > 0 ? .warning : .success)
        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bilan de santé").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(analysis.score)").font(.system(size: 34, weight: .bold)).foregroundStyle(tone.foreground)
                    Text("/\u{00A0}100").font(Theme.mono(13)).foregroundStyle(Theme.textSecondary)
                }
                ProgressBar(fraction: Double(analysis.score) / 100, color: tone.foreground)
                Text(analysis.grade).font(Theme.bodySemibold)
                Text(analysis.summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Chip(text: "\(analysis.count(.critical)) critique\(analysis.count(.critical) > 1 ? "s" : "")", tone: analysis.count(.critical) > 0 ? .critical : .neutral)
                    Chip(text: "\(analysis.count(.warning)) alerte\(analysis.count(.warning) > 1 ? "s" : "")", tone: analysis.count(.warning) > 0 ? .warning : .neutral)
                    Chip(text: "\(analysis.count(.advice)) conseil\(analysis.count(.advice) > 1 ? "s" : "")", tone: .neutral)
                }
            }
        }
    }

    private func coverage(_ analysis: NetworkAnalysisResult) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Parties analysées").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                ForEach(analysis.coverage) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: part.analyzed ? "checkmark.circle.fill" : "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(part.analyzed ? Theme.success : Theme.textTertiary)
                        Text(part.part).font(Theme.bodyMedium).frame(width: 150, alignment: .leading)
                        Text(part.detail).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Voir

    private func open(_ target: NetworkFindingTarget) {
        switch target {
        case .device(let ip, let mac, let site):
            let key = store.siteKey(forLabel: site)
            let address = IPv4Address(ip)
            let ref = store.deviceRef(ip: address, mac: mac.flatMap(MACAddress.init), name: ip, site: site, state: state)
                ?? NavDeviceRef(ip: ip, mac: mac, siteKey: key)
            state.perform(.device(ref))
        case .link:
            screen.part = .trafic
            screen.showSaturation = true
        case .trafficView(let view):
            screen.part = .trafic
            screen.tab = .view(view)
        case .wan:
            screen.part = .trafic
            screen.tab = .wan
        case .accessPoint(let name, _):
            let wifi = FortiAPStore.shared
            if let ap = wifi.overview.aps.first(where: { $0.name == name }) ?? wifi.shownOverview.aps.first(where: { $0.name == name }) {
                state.navigate(NavDestination(.wifi, focus: .accessPoint(ap.id)))
            } else {
                state.navigate(NavDestination(.wifi))
            }
        case .switchPort(let host, let port):
            state.navigate(NavDestination(.switchs, focus: .switchPort(host: host, port: port)))
        case .dhcpScope(let id):
            DHCPScopeStore.shared.selectedScopeID = id
            state.navigate(NavDestination(.outils, focus: .tool("dhcpscopes")))
        case .inventory(let site):
            state.navigate(NavDestination(.inventaire, sites: .only([store.siteKey(forLabel: site)])))
        case .none:
            break
        }
    }
}

/// Un point de l'analyse : gravité, domaine, constat, explication, action et « Voir ».
struct TrafficFindingCard: View {
    let finding: NetworkFinding
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.foreground)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Chip(text: finding.severity.label, tone: tone)
                    Chip(text: finding.area.label, tone: .neutral, systemImage: finding.area.symbol)
                    Text(finding.title).font(Theme.bodySemibold).lineLimit(2)
                }
                Text(finding.explanation).font(Theme.small).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    Text(finding.action).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if finding.target != .none {
                Button("Voir", action: open)
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.panelRadius, bottomLeadingRadius: Theme.panelRadius)
                .fill(tone.dot).frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if finding.target != .none { open() } }
    }

    private var tone: Tone {
        switch finding.severity {
        case .critical: return .critical
        case .warning: return .warning
        case .advice: return .accent
        case .ok: return .success
        }
    }

    private var icon: String {
        switch finding.severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .advice: return "lightbulb"
        case .ok: return "checkmark.circle.fill"
        }
    }
}
