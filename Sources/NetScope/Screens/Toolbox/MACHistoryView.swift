import NetScopeCore
import SwiftUI

// Boîte à outils › « Où était cet appareil ? » (note 99, inspiré de Netdisco) : recherche dans
// l'historique des adresses MAC du site actif, par MAC, IP ou nom, et par date ; chronologie de
// chaque MAC trouvée (IP, noms, ports de switch, VLAN, bornes Wi-Fi), export CSV et durée de
// conservation. Lecture des relevés déjà faits : rien n'est envoyé.
struct MACHistoryView: View {
    @ObservedObject private var store = MACHistoryStore.shared
    @State private var query = (Launcher.isDemo || RegEnvironment.isSnapshot)
        ? (ProcessInfo.processInfo.environment["NETSCOPE_MAC_RECHERCHE"] ?? MACHistoryDemo.defaultQuery) : ""
    @State private var useDate = false
    @State private var day = Date()
    @State private var toast: String?

    var body: some View {
        let _ = store.revision
        let history = store.activeHistory
        let matches = history.search(query, on: useDate ? day : nil)
        let shown = Array(matches.prefix(50))
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ToolStatTile(label: "Adresses MAC", value: "\(history.macCount)", detail: "suivies sur ce site")
                ToolStatTile(label: "Observations", value: "\(history.sightings.count)", detail: "IP, noms, ports, VLAN, bornes")
                ToolStatTile(label: "Résultats", value: "\(matches.count)", detail: query.isEmpty ? "tous les appareils" : "pour «\u{00A0}\(query)\u{00A0}»")
            }
            HStack(spacing: 10) {
                TextField("MAC, adresse IP ou nom", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 320)
                Toggle("Ce jour-là", isOn: $useDate).toggleStyle(.checkbox).fixedSize()
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden().disabled(!useDate).fixedSize()
                Spacer(minLength: 8)
                Picker("Conserver", selection: $store.retentionDays) {
                    ForEach(MACHistory.retentionChoices, id: \.self) { days in
                        Text(Self.retentionLabel(days)).tag(days)
                    }
                }
                .fixedSize()
                .help("Les valeurs plus vues depuis cette durée sont retirées de l’historique (tous les sites)")
                Button("Exporter en CSV") {
                    toast = store.exportCSV(matches.flatMap(\.sightings), suggestedName: "historique-mac")
                }
                .fixedSize()
                .disabled(matches.isEmpty)
            }
            Text("Site «\u{00A0}\(SiteModel.shared.activeName)\u{00A0}» · scans, relevés des switchs et clients Wi-Fi de la FortiGate déjà faits, rien n’est envoyé.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            if let toast { Text(toast).font(Theme.small).foregroundStyle(Theme.textSecondary) }
            if history.isEmpty {
                Text("Aucun relevé pour l’instant\u{00A0}: l’historique se remplit à chaque scan, relevé de switch et lecture des FortiAP.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).padding(24)
            } else if matches.isEmpty {
                Text("Aucun appareil trouvé" + (useDate ? " ce jour-là." : "."))
                    .font(Theme.body).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).padding(24)
            } else {
                ForEach(shown) { match in matchPanel(match) }
                if matches.count > shown.count {
                    Text("\(matches.count - shown.count) autres résultats\u{00A0}: précisez la recherche.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 365: return "1\u{00A0}an"
        case 730: return "2\u{00A0}ans"
        default: return "\(days)\u{00A0}jours"
        }
    }

    private func matchPanel(_ match: MACHistoryMatch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(match.mac.formatted(.upperColon)).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                if let name = match.latestName { Text(name).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                if let vendor = PirateStore.vendor(match.mac) {
                    Text(vendor).font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(match.sightings.count) observation" + (match.sightings.count > 1 ? "s" : ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ForEach(match.sightings) { sighting in
                Rectangle().fill(Theme.border).frame(height: 1)
                MACSightingRow(sighting: sighting)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Une ligne de chronologie : nature, valeur, période, sources.
struct MACSightingRow: View {
    let sighting: MACSighting

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 16)
            Text(sighting.kind.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(sighting.value)
                .font(sighting.kind == .ip ? Theme.mono(12) : Theme.small)
                .foregroundStyle(Theme.text).lineLimit(1).textSelection(.enabled)
            Spacer(minLength: 8)
            Text(MACHistoryStore.period(sighting)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(sighting.sources.map(\.label).joined(separator: ", "))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var symbol: String {
        switch sighting.kind {
        case .ip: return "number"
        case .name: return "tag"
        case .switchPort: return "rectangle.connected.to.line.below"
        case .vlan: return "square.stack.3d.up"
        case .accessPoint: return "wifi"
        }
    }
}

/// Note 99 : carte « Historique de l’adresse MAC » de la fiche Appareil : chronologie de la MAC
/// sur le site actif (les huit observations les plus récentes), export CSV de toute la chronologie.
struct DeviceMACHistoryCard: View {
    @ObservedObject private var store = MACHistoryStore.shared
    let device: Device
    @State private var toast: String?

    var body: some View {
        _ = store.revision
        let timeline = store.timeline(for: device)
        return DeviceCard(title: "Historique de l’adresse MAC") {
            VStack(alignment: .leading, spacing: 6) {
                if timeline.isEmpty {
                    Text(device.mac == nil
                         ? "MAC inconnue\u{00A0}: l’historique est rangé par adresse MAC."
                         : "Pas encore d’historique\u{00A0}: il se remplit à chaque scan, relevé de switch et lecture des FortiAP (conservé \(MACHistoryView.retentionLabel(store.retentionDays))).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(timeline.prefix(8)) { sighting in
                        HStack(spacing: 8) {
                            Text(sighting.kind.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .frame(width: 96, alignment: .leading)
                            Text(sighting.value).font(sighting.kind == .ip ? Theme.mono(11) : Theme.small)
                                .foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(MACHistoryStore.period(sighting)).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    if timeline.count > 8 {
                        Text("\(timeline.count - 8) autres observations\u{00A0}: Boîte à outils › Où était cet appareil\u{00A0}?")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        Button("Exporter en CSV") {
                            toast = store.exportCSV(timeline, suggestedName: "historique-" + (device.mac?.formatted(.bare) ?? "mac"))
                        }
                        .buttonStyle(.secondary)
                        if let toast { Text(toast).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}
