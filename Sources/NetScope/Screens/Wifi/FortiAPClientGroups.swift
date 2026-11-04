import NetScopeCore
import SwiftUI

// Note 46 : clients d'une borne (clic sur une borne du tableau), par radio (2,4 / 5 / 6 GHz) puis
// par SSID, avec le nombre de clients de chaque SSID. Un clic sur un client ouvre sa fiche
// complète ; le bouton ‹ de la fiche ramène à cette borne.

/// Ligne compacte d'un client (clients d'une borne) : nom, signal, SNR, débit, adresse.
struct FortiAPClientLine: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    let client: FortiWifiClient
    let linked: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let weak = store.isWeak(client)
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(client.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if linked {
                    Image(systemName: "link").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                        .help("Appareil du Scanner")
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let rssi = client.rssi {
                    WifiSignalBar(rssi: rssi, width: 28)
                    Text(WifiQuality.dbm(rssi)).font(Theme.mono(11.5, weight: .semibold))
                        .foregroundStyle(weak ? Theme.critical : WifiText.qualityColor(rssi).foreground).lineLimit(1)
                } else {
                    Text("—").font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 96, alignment: .leading)
            Text(client.snr.map { "SNR \($0)" } ?? "SNR —").font(Theme.mono(11))
                .foregroundStyle((client.snr ?? 99) < store.thresholds.weakSNR ? Theme.critical : Theme.neutralText)
                .frame(width: 56, alignment: .trailing)
            Text(FortiAPText.rate(client.rateMbps)).font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                .frame(width: 84, alignment: .trailing)
            Text(client.ip?.description ?? "—").font(Theme.mono(11)).foregroundStyle(client.ip == nil ? Theme.textTertiary : Theme.neutralText)
                .frame(width: 104, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help("Ouvrir la fiche du client")
        .contextMenu {
            Button("Fiche du client", action: open)
            OpenInMenu(object: .wifiClient(mac: client.mac.formatted(.upperColon), ip: client.ip?.description,
                                           name: client.hostname ?? client.mac.formatted(.upperColon), apID: store.ap(for: client)?.id))
        }
    }
}

/// Clients connectés à la borne choisie, par radio et par SSID.
struct FortiAPClientsOfAP: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    let apID: FortiManagedAP.ID?

    var body: some View {
        if let ap = store.shownOverview.aps.first(where: { $0.id == apID }) {
            let clients = store.shownOverview.clients
            let groups = FortiWifiClientGroups.byRadio(ap: ap, clients: clients)
            let counts = FortiWifiClientGroups.ssidCounts(ap: ap, clients: clients)
            let links = store.deviceLinks(state.devices)
            let total = groups.reduce(0) { $0 + $1.count }
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { title(ap, total: total); Spacer(minLength: 8); chips(counts) }
                        VStack(alignment: .leading, spacing: 6) { title(ap, total: total); chips(counts) }
                    }
                    if ap.isOffline {
                        Text("Borne hors ligne\u{00A0}: aucun client associé.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    } else if groups.isEmpty {
                        Text("Aucune radio en service sur cette borne.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(groups) { group in radio(group, links: links) }
                    }
                }
            }
        }
    }

    private func title(_ ap: FortiManagedAP, total: Int) -> some View {
        HStack(spacing: 8) {
            WifiHeading("Clients de la borne")
            Text(ap.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text("\(total)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.neutralText)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.neutralSoft))
        }
        .fixedSize()
    }

    private func chips(_ counts: [(ssid: String, count: Int)]) -> some View {
        HStack(spacing: 6) {
            ForEach(counts, id: \.ssid) { item in
                WifiPill(text: "\(item.ssid) · \(item.count)")
            }
        }
        .fixedSize()
    }

    private func radio(_ group: FortiWifiRadioGroup, links: [FortiWifiClient.ID: Device.ID]) -> some View {
        let util = group.radio?.channelUtilization
        let busy = (util ?? 0) > store.thresholds.maxChannelUtilization
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("\(group.count) client\(group.count > 1 ? "s" : "")").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                if let util {
                    Text("canal occupé \(FortiAPText.percent(util))").font(Theme.mono(11))
                        .foregroundStyle(busy ? Theme.warning : Theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            if group.ssids.isEmpty {
                Text("Aucun client sur cette radio.").font(Theme.small).foregroundStyle(Theme.textTertiary).padding(.leading, 8)
            }
            ForEach(group.ssids) { ssid in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                        Text(ssid.ssid).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("· \(ssid.count) client\(ssid.count > 1 ? "s" : "")").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 3)
                    ForEach(ssid.clients) { client in
                        FortiAPClientLine(client: client, linked: links[client.id] != nil) { openClient(client) }
                    }
                }
            }
        }
    }

    private func openClient(_ client: FortiWifiClient) {
        store.viewedSSID = nil
        store.viewedAP = apID
        state.navigate(store.clientDestination(client))
    }
}
