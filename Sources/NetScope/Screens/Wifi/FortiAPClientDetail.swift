import NetScopeCore
import SwiftUI

// Note 46 : fiche complète d'un client Wi-Fi, dans Wi-Fi › FortiAP. Ouverte par un double-clic
// sur un client (tableau des clients, clients d'une borne, clients d'un SSID) ; le bouton ‹ de la
// fiche ramène à la borne ou au SSID d'origine (même historique que Retour, note 45). Liens vers
// la fiche Appareil, l'Inventaire et le Ping continu (note 34). Lecture seule.

struct FortiAPClientDetailView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    let client: FortiWifiClient

    var body: some View {
        let ap = store.ap(for: client)
        let links = store.deviceLinks(state.devices)
        let device = links[client.id].flatMap { state.device(withID: $0) }
        let history = store.signalHistory(for: client)
        let facts = WifiClientFacts(client: client, ap: ap,
                                    ssid: store.shownOverview.ssids.first { $0.site == client.site && $0.ssid == client.ssid }
                                        ?? store.overview.ssids.first { $0.site == client.site && $0.ssid == client.ssid },
                                    history: history, device: device, thresholds: store.thresholds)
        VStack(alignment: .leading, spacing: 14) {
            header(facts, device: device, ap: ap)
            tiles(facts)
            SidePanelSplit(sideWidth: 330, collapse: .below) {
                VStack(spacing: 14) {
                    Panel(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                WifiHeading("Historique du signal")
                                Text(facts.samples.isEmpty ? "" : "\(facts.samples.count) relevé\(facts.samples.count > 1 ? "s" : "") · \(facts.trend.label)")
                                    .font(Theme.small).foregroundStyle(facts.trendColor)
                                Spacer()
                            }
                            WifiSignalHistoryChart(samples: facts.samples, roams: facts.roams, readings: history.readings,
                                                   threshold: store.thresholds.weakRSSI)
                            Text("Un relevé à chaque lecture des bornes (fin de scan, «\u{00A0}Relire les bornes\u{00A0}», sondes de la Surveillance), gardé par site sur ce Mac. Traits pointillés\u{00A0}: changements de borne.")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        section(facts.identity)
                        section(facts.connection)
                        section(facts.traffic)
                        section(facts.accessPoint)
                    }
                }
            } side: {
                VStack(spacing: 14) {
                    Panel(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            WifiHeading("Problèmes repérés")
                            WifiClientIssuesList(issues: facts.issues)
                            WifiDiagnoseSlot(client: client, site: store.siteKey(for: client))
                        }
                    }
                    Panel(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            WifiHeading("Itinérances")
                            WifiRoamList(roams: facts.roams)
                        }
                    }
                    section(facts.signal)
                }
            }
        }
    }

    // MARK: En-tête

    private func header(_ facts: WifiClientFacts, device: Device?, ap: FortiManagedAP?) -> some View {
        Panel(padding: 14) {
            AdaptiveStack(breakpoint: 900, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Button { back() } label: {
                        Label(backTitle, systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.secondary)
                    .help("Revenir à " + backTitle)
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(facts.isWeak ? Theme.criticalSoft : Theme.accentSoft)
                        Image(systemName: icon).font(.system(size: 15)).foregroundStyle(facts.isWeak ? Theme.critical : Theme.accentStrong)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(client.displayName).font(.system(size: 15, weight: .bold)).lineLimit(1)
                            if facts.isWeak {
                                WifiPill(text: "Signal faible", foreground: Theme.critical, background: Theme.criticalSoft)
                            }
                        }
                        Text(subtitle(ap: ap)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button { if let device { state.showDevice(device.id) } } label: { Label("Fiche de l’appareil", systemImage: Screen.appareil.symbol) }
                        .buttonStyle(.secondary)
                        .disabled(device == nil)
                        .help(device == nil ? "Ce client n’est pas dans le dernier scan du site actif" : "Ouvrir la fiche de \(device?.displayName ?? "")")
                    Button { open(.inventaire) } label: { Label("Inventaire", systemImage: Screen.inventaire.symbol) }
                        .buttonStyle(.secondary)
                        .disabled(destination(.inventaire) == nil)
                        .help(destination(.inventaire) == nil ? "Ce client n’a pas de fiche d’inventaire" : "Ouvrir la fiche d’inventaire de ce client")
                    Button { if let ip = client.ip { state.navigate(NavDestination(.ping, focus: .pingTarget(ip.description))) } } label: {
                        Label("Ping continu", systemImage: Screen.ping.symbol)
                    }
                    .buttonStyle(.secondary)
                    .disabled(client.ip == nil)
                    .help(client.ip == nil ? "Adresse IP inconnue\u{00A0}: rien à pinger" : "Ping continu vers \(client.ip?.description ?? "")")
                }
                .fixedSize()
            }
        }
    }

    private var icon: String {
        let os = (client.os ?? "").lowercased()
        if os.contains("ios") || os.contains("android") { return "iphone" }
        if os.contains("mac") || os.contains("windows") { return "laptopcomputer" }
        return "wifi"
    }

    private func subtitle(ap: FortiManagedAP?) -> String {
        var parts = [client.mac.formatted(.upperColon)]
        if let ip = client.ip { parts.append(ip.description) }
        if let ssid = client.ssid { parts.append(ssid) }
        parts.append(ap?.name ?? client.apName ?? "borne inconnue")
        if store.shownOverview.isMultiSite || store.scopeKeys != nil { parts.append(client.site) }
        return parts.joined(separator: " · ")
    }

    // MARK: Tuiles

    private func tiles(_ facts: WifiClientFacts) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: 10), count: 5), spacing: 10) {
            tile("Signal", FortiAPText.dbm(client.rssi), sub: facts.isWeak ? "sous le seuil de \(FortiAPText.dbm(store.thresholds.weakRSSI))" : (client.rssi.map { WifiQuality(rssi: $0).label } ?? "inconnu"),
                 color: facts.rssiColor)
            tile("SNR", client.snr.map { "\($0)\u{00A0}dB" } ?? "—", sub: client.noise.map { "bruit \($0)\u{00A0}dBm" } ?? "bruit inconnu", color: facts.snrColor)
            tile("Débit négocié", FortiAPText.rate(client.rateMbps), sub: client.standard?.shortLabel ?? "standard inconnu", color: Theme.text)
            tile("Bande", client.band?.label ?? "—", sub: facts.channelLabel, color: Theme.text)
            tile("Associé depuis", FortiAPText.duration(client.associatedFor), sub: "itinérances\u{00A0}: \(facts.roams.count)", color: Theme.text)
        }
    }

    private func tile(_ title: String, _ value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(Theme.mono(18, weight: .bold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .modifier(WifiTileStyle())
    }

    private func section(_ section: WifiClientFacts.Section) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                WifiHeading(section.title)
                VStack(spacing: 0) {
                    ForEach(section.rows) { row in
                        DeviceKVRow(key: row.key, value: row.value, mono: row.mono, valueColor: row.value == "—" ? Theme.textTertiary : row.color,
                                    detail: row.detail)
                            .help(row.help ?? "")
                    }
                }
            }
        }
    }

    // MARK: Navigation

    /// Endroit d'où l'on vient (borne, SSID), d'après l'historique Retour.
    private var origin: NavFocus? {
        guard let previous = state.history.previous, previous.module == .wifi else { return nil }
        return previous.focus
    }

    private var backTitle: String {
        switch origin {
        case .accessPoint(let id)?:
            let shown = store.shownAPID(for: id) ?? id
            return store.shownOverview.aps.first { $0.id == shown }?.name ?? "Borne"
        case .wifiSSID(let id)?:
            return id.lastIndex(of: "|").map { String(id[id.index(after: $0)...]) } ?? "SSID"
        default:
            return "Clients Wi-Fi"
        }
    }

    private func back() {
        if origin != nil {
            state.goBack()
        } else {
            store.closeClient()
        }
    }

    private var object: NavObject {
        .wifiClient(mac: client.mac.formatted(.upperColon), ip: client.ip?.description,
                    name: client.hostname ?? client.mac.formatted(.upperColon), apID: store.ap(for: client)?.id)
    }

    private func destination(_ module: NavModule) -> NavDestination? {
        state.openInItems(object).first { $0.destination.module == module }?.destination
    }

    private func open(_ module: NavModule) {
        if let destination = destination(module) { state.navigate(destination) }
    }
}
