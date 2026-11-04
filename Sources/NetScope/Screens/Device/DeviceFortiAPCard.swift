import NetScopeCore
import SwiftUI

/// Fiche Appareil, note 27 : appareil vu comme client Wi-Fi par la FortiGate de son site. Borne
/// FortiAP, SSID, bande et signal, comme « Switch / port » pour un appareil filaire.
struct DeviceFortiAPCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared
    let device: Device
    let client: FortiWifiClient

    var body: some View {
        let ap = store.ap(for: client)
        let weak = store.isWeak(client)
        DeviceCard(title: "Wi-Fi (FortiAP)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    node(ap?.name ?? client.apName ?? "Borne", ap?.model ?? "FortiAP", highlighted: false)
                    Text("─").foregroundStyle(Theme.textSecondary)
                    node(client.ssid ?? "SSID", [client.band?.label, client.channel.map { "canal \($0)" }].compactMap { $0 }.joined(separator: " · "),
                         highlighted: true)
                    Text("─").foregroundStyle(Theme.textSecondary)
                    node(device.hostname ?? device.displayName, ".\(device.ip.octets.3)", highlighted: false)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    DeviceKVRow(key: "Borne", value: (ap?.name ?? client.apName ?? "—") + (ap.map { " · \($0.model)" } ?? ""))
                    DeviceKVRow(key: "SSID", value: client.ssid ?? "—", mono: false)
                    DeviceKVRow(key: "Bande / canal", value: bandLabel)
                    DeviceKVRow(key: "Signal", value: FortiAPText.dbm(client.rssi) + (client.snr.map { " · SNR \($0)\u{00A0}dB" } ?? ""),
                                valueColor: weak ? Theme.critical : (client.rssi.map { WifiText.qualityColor($0).foreground } ?? Theme.text),
                                detail: weak ? "signal faible" : nil)
                    DeviceKVRow(key: "Débit", value: FortiAPText.rate(client.rateMbps))
                    if let duration = client.associatedFor {
                        DeviceKVRow(key: "Associé depuis", value: FortiAPText.duration(duration), mono: false)
                    }
                    DeviceKVRow(key: "Source", value: "FortiGate · \(client.site) (clients Wi-Fi, lecture seule)", mono: false)
                }
                Button("Voir la borne dans Wi-Fi › FortiAP →") {
                    UserDefaults.standard.set(WifiScreenPart.fortiap.rawValue, forKey: "NetScope.wifi.partie")
                    state.open(.wifi)
                }
                    .buttonStyle(.ghost)
                    .padding(.leading, -8)
            }
        }
    }

    private var bandLabel: String {
        let text = [client.band?.label, client.channel.map { "canal \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? "—" : text
    }

    private func node(_ title: String, _ detail: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail).font(Theme.mono(11)).foregroundStyle(highlighted ? Theme.accentStrong : Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(highlighted ? Theme.accent : Theme.border))
    }
}
