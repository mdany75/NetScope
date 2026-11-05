import NetScopeCore
import SwiftUI

/// Note 48 : bandeau de la partie FortiAP quand le menu « Site ▾ » montre un autre site, ou
/// plusieurs. Une ligne par site : pastille de sa FortiGate, bornes et clients connus, heure de la
/// lecture, message clair s'il n'a rien à montrer, et « Lire les bornes » (à la demande, lecture
/// seule, sans toucher au Wi-Fi du site actif ni aux appareils du Scanner).
struct FortiAPSitesBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var scopes = SiteScopeStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared

    var body: some View {
        let keys = scopes.keys(for: .wifi)
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
                        Image(systemName: "wifi.router").font(.system(size: 15)).foregroundStyle(Theme.accentStrong)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(keys.count > 1 ? "Wi-Fi de \(keys.count) sites" : "Wi-Fi de «\u{00A0}\(sites.name(forKey: keys.first ?? ""))\u{00A0}»")
                            .font(Theme.bodySemibold)
                        Text("Dernières bornes, clients, SSID et AP voisins connus de chaque site, lus par sa FortiGate. Le site actif «\u{00A0}\(sites.activeName)\u{00A0}» ne change pas.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Site actif seulement") { scopes.set(.active, for: .wifi) }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
                Divider()
                ForEach(keys, id: \.self) { key in
                    row(key)
                }
                FortiAPReadNotes(notes: store.shownOverview.notes)
            }
        }
    }

    @ViewBuilder private func row(_ key: String) -> some View {
        let site = sites.site(forKey: key)
        let reports = store.reports(forKey: key)
        let aps = reports.reduce(0) { $0 + $1.report.aps.count }
        let clients = reports.reduce(0) { $0 + $1.report.clients.count }
        let readAt = reports.map(\.report.readAt).max()
        let ids = site?.fortiGateIDs ?? []
        let reading = key == sites.activeKey ? store.busy : !store.viewReading.isDisjoint(with: ids)
        let message = site.flatMap { SiteWifiBrowse.emptyMessage(site: $0, reports: reports) }
        let errors = ids.compactMap { store.errors[$0] }
        HStack(alignment: .top, spacing: 10) {
            SiteLinkDot(state: site.map { sites.linkState($0) } ?? .noFortiGate)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sites.name(forKey: key)).font(Theme.bodySemibold).lineLimit(1)
                    if key == sites.activeKey { Chip(text: "Site actif", tone: .accent) }
                }
                if let message {
                    Text(message).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(aps) borne\(aps > 1 ? "s" : ""), \(clients) client\(clients > 1 ? "s" : "") Wi-Fi"
                         + (readAt.map { " · lu à \(WifiText.timeSeconds($0))" } ?? ""))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.small).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !ids.isEmpty {
                // Le site actif : la relecture habituelle (Wi-Fi du site actif, appareils du Scanner).
                Button { key == sites.activeKey ? store.refreshNow(state: state) : store.readForView(ids) } label: {
                    HStack(spacing: 6) {
                        if reading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        Text(reading ? "Lecture…" : "Lire les bornes")
                    }
                }
                .buttonStyle(.secondary)
                .disabled(reading || !fortigate.isEnabled)
                .fixedSize()
                .help("Relit, par l’API REST (HTTPS, lecture seule), les bornes FortiAP de la FortiGate de ce site.")
            } else if site != nil {
                Button("Réglages…") {
                    RegNavigation.shared.section = .sites
                    state.open(.reglages)
                }
                .buttonStyle(.ghost)
                .fixedSize()
            }
        }
    }
}
