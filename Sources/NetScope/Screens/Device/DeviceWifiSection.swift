import NetScopeCore
import SwiftUI

/// Fiche Appareil, notes 27 et 46 : l'appareil est un client Wi-Fi vu par la FortiGate de son site.
/// Tout ce qui sert au diagnostic : signal (RSSI, SNR, bruit, historique), borne et radio, SSID,
/// bande, canal et largeur, standard, sécurité et authentification, VLAN, débits, octets, durée
/// de connexion, itinérances, déconnexions, charge et utilisation du canal de la borne, problèmes
/// repérés et « Diagnostiquer » (note 47). Pleine largeur, sous les cartes de l'Aperçu.
struct DeviceWifiSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    let device: Device
    let client: FortiWifiClient

    var body: some View {
        let ap = store.ap(for: client)
        let facts = WifiClientFacts(client: client, ap: ap,
                                    ssid: store.overview.ssids.first { $0.site == client.site && $0.ssid == client.ssid },
                                    history: store.signalHistory(for: client), device: device, thresholds: store.thresholds)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ToolFieldLabel("Wi-Fi (FortiAP)")
                if facts.isWeak {
                    WifiPill(text: "Signal faible", foreground: Theme.critical, background: Theme.criticalSoft)
                }
                if facts.trend == .falling {
                    WifiPill(text: "Signal en baisse", foreground: Theme.warning, background: Theme.warningSoft)
                }
                Spacer(minLength: 0)
                Text("FortiGate · \(client.site) (clients Wi-Fi, lecture seule)").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            AdaptiveStack(breakpoint: 760, spacing: 10) {
                path(ap: ap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions(ap: ap)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 18, alignment: .top)], alignment: .leading, spacing: 12) {
                group(facts.signal)
                group(facts.connection)
                group(facts.traffic)
                group(facts.accessPoint)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Historique du signal" + (facts.samples.isEmpty ? "" : " · \(facts.samples.count) relevés"))
                        .font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    WifiSignalHistoryChart(samples: facts.samples, roams: facts.roams, readings: store.signalHistory(for: client).readings,
                                           threshold: store.thresholds.weakRSSI, height: 130)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Problèmes repérés").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    WifiClientIssuesList(issues: facts.issues)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func path(ap: FortiManagedAP?) -> some View {
        HStack(spacing: 4) {
            node(ap?.name ?? client.apName ?? "Borne", [ap?.model, client.radioID.map { "radio \($0)" }].compactMap { $0 }.joined(separator: " · "),
                 highlighted: false)
            Text("─").foregroundStyle(Theme.textSecondary)
            node(client.ssid ?? "SSID", [client.band?.label, client.channel.map { "canal \($0)" }].compactMap { $0 }.joined(separator: " · "),
                 highlighted: true)
            Text("─").foregroundStyle(Theme.textSecondary)
            node(device.hostname ?? device.displayName, ".\(device.ip.octets.3)", highlighted: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actions(ap: FortiManagedAP?) -> some View {
        HStack(spacing: 8) {
            Button("Fiche du client Wi-Fi") { state.navigate(store.clientDestination(client)) }
                .buttonStyle(.secondary)
                .help("Fiche complète du client dans Wi-Fi › FortiAP")
            Button(ap == nil ? "Ouvrir Wi-Fi › FortiAP" : "Voir la borne") {
                if let ap {
                    FortiAPStore.shared.focusBand = client.band
                    state.navigate(NavDestination(.wifi, focus: .accessPoint(ap.id)))
                } else {
                    UserDefaults.standard.set(WifiScreenPart.fortiap.rawValue, forKey: "NetScope.wifi.partie")
                    FortiAPStore.shared.closeClient()
                    state.open(.wifi)
                }
            }
            .buttonStyle(.secondary)
            WifiDiagnoseSlot(client: client, site: store.siteKey(for: client))
        }
        .fixedSize()
    }

    private func group(_ section: WifiClientFacts.Section) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(section.rows) { row in
                    DeviceKVRow(key: row.key, value: row.value, mono: row.mono, valueColor: row.value == "—" ? Theme.textTertiary : row.color,
                                detail: row.detail)
                        .help(row.help ?? "")
                }
            }
        }
    }

    private func node(_ title: String, _ detail: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail.isEmpty ? "Wi-Fi" : detail).font(Theme.mono(11)).foregroundStyle(highlighted ? Theme.accentStrong : Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(highlighted ? Theme.accent : Theme.border))
    }
}
