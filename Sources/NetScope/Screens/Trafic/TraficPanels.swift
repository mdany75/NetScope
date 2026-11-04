import NetScopeCore
import SwiftUI

// Panneaux de l'écran Trafic (note 54) : tuiles, charge des liens WAN, « Qui sature le lien ? »
// et emplacement de l'état du WAN (note 39).

// MARK: - Tuiles

struct TrafficSummaryTiles: View {
    @ObservedObject private var store = TrafficStore.shared
    @ObservedObject private var screen = TrafficScreenState.shared
    let overview: TrafficOverview

    var body: some View {
        let rates = TrafficAnalysis.wanRates(overview)
        let usages = TrafficAnalysis.linkUsage(overview, thresholds: store.thresholds)
        let worst = usages.first
        let consumers = TrafficAnalysis.consumers(overview, limit: 1)
        let threats = TrafficAnalysis.threats(overview)
        let passed = threats.filter { !$0.isBlocked }.count
        let unexpected = TrafficAnalysis.unexpectedApplications(overview)
        let realtime = overview.period.isRealtime
        let totalBytes = overview.entries(.sources).reduce(UInt64(0)) { $0 &+ $1.bytes }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            if realtime {
                InvTile(title: "Débit Internet", value: "↓\u{00A0}" + TrafficFormat.rate(rates.rx),
                        subtitle: "↑\u{00A0}" + TrafficFormat.rate(rates.tx) + " · \(overview.wanLinks.count) lien\(overview.wanLinks.count > 1 ? "s" : "") WAN")
            } else {
                InvTile(title: "Volume", value: TrafficFormat.bytes(totalBytes), subtitle: "Appareils, \(overview.period.span)")
            }
            InvTile(title: "Lien le plus chargé", value: worst?.percent.map(ResourceFormat.percent) ?? "—",
                    subtitle: worst.map { $0.link.label + (overview.isMultiSite ? " · \($0.link.site)" : "") } ?? "Aucun lien WAN lu",
                    valueColor: worst?.percent.map { TrafficStyle.color(percent: $0, text: true) } ?? Theme.text,
                    tint: worst?.level == .critical ? .critical : nil) {
                if let percent = worst?.percent {
                    ProgressBar(fraction: percent / 100, color: TrafficStyle.color(percent: percent)).padding(.top, 2)
                }
            }
            InvTile(title: "Premier consommateur", value: consumers.first.map { realtime ? TrafficFormat.rate($0.entry.bandwidth) : TrafficFormat.bytes($0.entry.bytes) } ?? "—",
                    subtitle: consumers.first.map { "\($0.entry.name) · \(ResourceFormat.percent($0.sharePercent)) du trafic" } ?? "Aucune source lue",
                    action: consumers.isEmpty ? nil : { screen.showSaturation = true })
            InvTile(title: "Applications", value: "\(overview.entries(.applications).count)",
                    subtitle: unexpected.isEmpty ? "Aucune application inattendue" : "\(unexpected.count) inattendue\(unexpected.count > 1 ? "s" : "")\u{00A0}: " + unexpected.prefix(2).map(\.name).joined(separator: ", "),
                    valueColor: unexpected.isEmpty ? Theme.text : Theme.warning,
                    action: { screen.tab = .view(.applications) })
            InvTile(title: "Menaces", value: "\(threats.count)",
                    subtitle: threats.isEmpty ? "Aucune \(overview.period.span)" : (passed == 0 ? "Toutes bloquées" : "\(passed) non bloquée\(passed > 1 ? "s" : "")"),
                    valueColor: passed > 0 ? Theme.critical : (threats.isEmpty ? Theme.text : Theme.warning),
                    tint: passed > 0 ? .critical : nil,
                    action: { screen.tab = .view(.threats) })
            InvTile(title: realtime ? "Sessions en cours" : "Sessions", value: ToolFormat.integer(overview.entries(.sources).reduce(0) { $0 + $1.sessions }),
                    subtitle: "\(overview.entries(.sources).count) appareil\(overview.entries(.sources).count > 1 ? "s" : "") actif\(overview.entries(.sources).count > 1 ? "s" : "")",
                    action: { screen.tab = .view(realtime ? .sessions : .sources) })
        }
    }
}

// MARK: - Liens WAN

struct TrafficLinksPanel: View {
    @ObservedObject private var store = TrafficStore.shared
    let overview: TrafficOverview

    var body: some View {
        let usages = TrafficAnalysis.linkUsage(overview, thresholds: store.thresholds)
        if !usages.isEmpty {
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    InvPanelTitle("Liens WAN", subtitle: overview.period.isRealtime ? "charge en temps réel" : "débit moyen \(overview.period.span)")
                    ForEach(usages) { usage in
                        TrafficLinkRow(usage: usage, multiSite: overview.isMultiSite)
                    }
                }
            }
        }
    }
}

struct TrafficLinkRow: View {
    let usage: TrafficLinkUsage
    let multiSite: Bool

    var body: some View {
        let link = usage.link
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title.frame(width: 230, alignment: .leading)
                direction("↓", rate: link.rxBps, capacity: link.downCapacity)
                direction("↑", rate: link.txBps, capacity: link.upCapacity)
                percent.frame(width: 64, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    title
                    Spacer()
                    percent
                }
                HStack(spacing: 12) {
                    direction("↓", rate: link.rxBps, capacity: link.downCapacity)
                    direction("↑", rate: link.txBps, capacity: link.upCapacity)
                }
            }
        }
        .help(TrafficStyle.capacityLabel(link))
    }

    private var title: some View {
        HStack(spacing: 6) {
            StatusDot(tone: usage.link.linkUp == false ? .critical : (usage.level == .critical ? .critical : (usage.level == .warning ? .warning : .success)))
            Text(usage.link.label).font(Theme.bodySemibold).lineLimit(1)
            if multiSite { Text(usage.link.site).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
    }

    private var percent: some View {
        Text(usage.percent.map(ResourceFormat.percent) ?? "—")
            .font(Theme.mono(13, weight: .semibold))
            .foregroundStyle(usage.percent.map { TrafficStyle.color(percent: $0, text: true) } ?? Theme.textTertiary)
    }

    private func direction(_ arrow: String, rate: Double, capacity: Double?) -> some View {
        let fraction = capacity.map { $0 > 0 ? rate / $0 : 0 } ?? 0
        return HStack(spacing: 6) {
            Text(arrow).font(Theme.small).foregroundStyle(Theme.textSecondary)
            ProgressBar(fraction: fraction, color: TrafficStyle.color(percent: fraction * 100))
                .frame(minWidth: 80, maxWidth: .infinity)
            Text(TrafficFormat.rate(rate) + (capacity.map { " / " + ResourceFormat.bitsPerSecond($0) } ?? ""))
                .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).fixedSize()
        }
    }
}

// MARK: - Qui sature le lien ?

struct TrafficSaturationSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TrafficStore.shared
    let verdict: TrafficSaturationVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .font(.system(size: 22)).foregroundStyle(verdict.isSaturated ? Theme.critical : Theme.accent)
                Text("Qui sature le lien\u{00A0}?").font(Theme.panelTitle)
                Spacer()
                if let link = verdict.link {
                    Chip(text: link.percent.map { ResourceFormat.percent($0) } ?? "capacité inconnue",
                         tone: link.level == .critical ? .critical : (link.level == .warning ? .warning : .success))
                }
            }
            ToolNotice(tone: verdict.isSaturated ? (verdict.link?.level == .critical ? .critical : .warning) : .success,
                       title: verdict.headline, message: verdict.advice)
            if !verdict.consumers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(verdict.consumers.enumerated()), id: \.element.id) { index, consumer in
                        consumerRow(index + 1, consumer)
                        if index < verdict.consumers.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            }
            HStack {
                Text("Double-clic sur un appareil\u{00A0}: sa fiche (port de switch, borne Wi-Fi).")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func consumerRow(_ rank: Int, _ consumer: TrafficConsumer) -> some View {
        let entry = consumer.entry
        let ref = store.deviceRef(ip: entry.ip, mac: entry.mac, name: entry.name, site: entry.site, state: state)
        let name = ref.map { $0.name != $0.ip ? $0.name : entry.name } ?? entry.name
        let location = ref?.switchName.map { $0 + (ref?.switchPort.map { " · " + $0 } ?? "") }
        return HStack(alignment: .top, spacing: 10) {
            Text("\(rank)").font(Theme.mono(13, weight: .bold)).foregroundStyle(Theme.textTertiary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(Theme.bodySemibold)
                    if let ip = entry.ip { Text(ip.description).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary) }
                }
                Text([consumer.mainApplication, consumer.mainDestination, location].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(2)
                ProgressBar(fraction: consumer.sharePercent / 100, color: rank == 1 && TrafficAnalysis.whoSaturates(store.overview, thresholds: store.thresholds).isSaturated ? Theme.critical : Theme.accent)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(store.overview.period.isRealtime ? TrafficFormat.rate(entry.bandwidth) : TrafficFormat.bytes(entry.bytes))
                    .font(Theme.mono(13, weight: .semibold))
                Text(ResourceFormat.percent(consumer.sharePercent) + " du trafic").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if let link = consumer.linkPercent {
                    Text(ResourceFormat.percent(link) + " du lien").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if let ref {
                Button {
                    dismiss()
                    state.perform(.device(ref))
                } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Ouvrir la fiche de \(name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let ref else { return }
            dismiss()
            state.perform(.device(ref))
        }
    }
}

// MARK: - WAN (note 39)

/// Onglet « WAN » : emplacement de l'état du WAN et des tunnels (note 39). À la fusion, remplacer
/// le contenu par `WANStatusView()` de la note 39 ; d'ici là, la charge des liens WAN lue par
/// FortiView et leur capacité.
struct TrafficWANSlot: View {
    @ObservedObject private var store = TrafficStore.shared
    let overview: TrafficOverview

    var body: some View {
        let usages = TrafficAnalysis.linkUsage(overview, thresholds: store.thresholds)
        VStack(alignment: .leading, spacing: 10) {
            ToolNotice(tone: .accent, title: "État du WAN et des tunnels",
                       message: "Latence, perte et gigue des liens SD-WAN et état des tunnels VPN IPsec de chaque site\u{00A0}: lus par la FortiGate (sondes de santé SD-WAN). Ci-dessous, la charge des liens WAN mesurée par FortiView.")
            if usages.isEmpty {
                Text("Aucun lien de rôle «\u{00A0}WAN\u{00A0}» lu sur ces FortiGate.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                Panel(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(usages) { usage in
                            TrafficLinkRow(usage: usage, multiSite: overview.isMultiSite)
                            Text(TrafficStyle.capacityLabel(usage.link) + (usage.link.linkUp == false ? " · lien coupé" : ""))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }
}
