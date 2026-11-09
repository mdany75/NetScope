import NetScopeCore
import SwiftUI

// Boîte à outils › « Où était cet appareil ? » (note 99, inspiré de Netdisco) : recherche dans
// l'historique des adresses MAC du site actif, par MAC, IP ou nom, et par date ; chronologie de
// chaque MAC trouvée (IP, noms, ports de switch, VLAN, bornes Wi-Fi), export CSV et durée de
// conservation. Lecture des relevés déjà faits : rien n'est envoyé.
struct MACHistoryView: View {
    @ObservedObject private var store = MACHistoryStore.shared
    @State private var query = (Launcher.isDemo || RegEnvironment.isSnapshot)
        ? (ProcessInfo.processInfo.environment["NETSCOPE_MAC_RECHERCHE"] ?? MACHistoryDemo.defaultQuery) : MACHistoryStore.shared.lastQuery
    @ObservedObject private var sites = SiteModel.shared
    /// Observé : le bouton s'active dès que les jetons de la FortiGate sont lus au Trousseau.
    @ObservedObject private var fortigate = FortiGateStore.shared
    /// Jetons lus : avant, « jeton absent » serait faux.
    @State private var tokensLoaded = false
    /// Note 110 : montrer seulement ce que la dernière relecture a vu, sans l'historique.
    @State private var currentOnly = (Launcher.isDemo || RegEnvironment.isSnapshot)
        ? ProcessInfo.processInfo.environment["NETSCOPE_MAC_VUE"] == "relecture"
        : UserDefaults.standard.bool(forKey: "macHistoryCurrentOnly")
    @State private var useDate = false
    @State private var day = Date()
    @State private var toast: String?

    var body: some View {
        let _ = store.revision
        let history = store.activeHistory
        // Fiche vierge à la première ouverture, puis la dernière recherche : jamais toute la liste.
        let isBlank = query.trimmingCharacters(in: .whitespaces).isEmpty && !useDate
        let matches = isBlank ? [] : history.search(query, on: useDate ? day : nil)
        let shown = Array(matches.prefix(50))
        let target = isBlank ? nil : FortiDeviceTarget.of(query: query, found: matches.map(\.mac))
        let reason = readBlocked(target, isBlank: isBlank, found: matches.count)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                ToolStatTile(label: "Adresses MAC", value: "\(history.macCount)", detail: "suivies sur ce site")
                ToolStatTile(label: "Observations", value: "\(history.sightings.count)", detail: "IP, noms, ports, VLAN, bornes")
                ToolStatTile(label: "Résultats", value: "\(matches.count)", detail: isBlank ? "aucune recherche" : (query.isEmpty ? "ce jour-là" : "pour «\u{00A0}\(query)\u{00A0}»"))
            }
            HStack(spacing: 10) {
                TextField("MAC, adresse IP ou nom", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 320)
                    // Entrée : relit l'appareil cherché quand seule la relecture est montrée.
                    .onSubmit { if currentOnly, let target { store.readDevice(target, query: query) } }
                Toggle("Ce jour-là", isOn: $useDate).toggleStyle(.checkbox).fixedSize()
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden().disabled(!useDate).fixedSize()
                Spacer(minLength: 0)
            }
            ActionRow {
                Picker("Afficher", selection: $currentOnly) {
                    Text("Historique").tag(false)
                    Text("Dernière relecture").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Historique\u{00A0}: tout ce qui a été vu, avec les dates. Dernière relecture\u{00A0}: seulement ce que la FortiGate voit maintenant.")
                Picker("Conserver", selection: $store.retentionDays) {
                    ForEach(MACHistory.retentionChoices, id: \.self) { days in
                        Text(Self.retentionLabel(days)).tag(days)
                    }
                }
                .fixedSize()
                .help("Les valeurs plus vues depuis cette durée sont retirées de l’historique (tous les sites)")
                Button { if let target { store.readDevice(target, query: query) } } label: {
                    Label("Relire cet appareil", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
                .fixedSize()
                .disabled(target == nil || !store.canReadDevice)
                .help(reason ?? "Relit seulement cet appareil sur la FortiGate de ce site (lecture seule)")
                Button("Exporter en CSV") {
                    toast = store.exportCSV(matches.flatMap(\.sightings), suggestedName: "historique-mac")
                }
                .fixedSize()
                .disabled(matches.isEmpty || currentOnly)
            }
            // La raison est écrite, pas seulement dans la bulle du bouton grisé.
            if !isBlank, let reason {
                Label(reason, systemImage: "info.circle")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Site «\u{00A0}\(SiteModel.shared.activeName)\u{00A0}» · scans, relevés des switchs et clients Wi-Fi de la FortiGate\u{00A0}· \(readStatus)")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                if store.isReadingDevice { ProgressView().controlSize(.small) }
            }
            if let toast { Text(toast).font(Theme.small).foregroundStyle(Theme.textSecondary) }
            if currentOnly {
                currentSection(isBlank: isBlank)
            } else if history.isEmpty {
                Text("Aucun relevé pour l’instant\u{00A0}: l’historique se remplit à chaque scan, relevé de switch et lecture des FortiAP.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).padding(24)
            } else if isBlank {
                Text("Entrez une adresse MAC, une adresse IP ou un nom pour retrouver où cet appareil a été vu.")
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
        // Une faute de frappe sans résultat ne remplace pas la dernière recherche utile.
        .onChange(of: query) { _, text in
            let blank = text.trimmingCharacters(in: .whitespaces).isEmpty
            if blank || !store.activeHistory.search(text, on: nil).isEmpty { store.rememberQuery(text) }
        }
        // Dernière recherche rouverte : seul cet appareil est relu, une fois les jetons lus.
        .task {
            await FortiGateStore.shared.loadTokens()
            tokensLoaded = true
            let found = store.activeHistory.search(query, on: nil).map(\.mac)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty, let target = FortiDeviceTarget.of(query: query, found: found) {
                store.readDevice(target, query: query, allowCLI: false)
            }
        }
        .onAppear { if currentOnly, !query.isEmpty { store.loadDemoDeviceRead(query: query) } }
        .onChange(of: currentOnly) { _, on in
            if !store.isDemo { UserDefaults.standard.set(on, forKey: "macHistoryCurrentOnly") }
            if on, !query.isEmpty { store.loadDemoDeviceRead(query: query) }
        }
        .onChange(of: sites.activeKey) { _, _ in
            query = store.lastQuery
            useDate = false
        }
    }

    // MARK: Dernière relecture (note 110)

    @ViewBuilder private func currentSection(isBlank: Bool) -> some View {
        let current = store.currentDeviceRead(for: query)
        if isBlank {
            emptyMessage("Entrez une adresse MAC, une adresse IP ou un nom, puis relisez cet appareil.")
        } else if !current.isEmpty {
            ForEach(current) { currentPanel($0) }
        } else if store.isReadingDevice {
            emptyMessage("Relecture de cet appareil…")
        } else if store.hasDeviceRead(for: query), let message = store.deviceReadMessage {
            emptyMessage(message)
        } else {
            emptyMessage("Cliquez sur «\u{00A0}Relire cet appareil\u{00A0}» pour voir ce que la FortiGate voit maintenant.")
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text).font(Theme.body).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).padding(24)
    }

    private func currentPanel(_ view: MACCurrentView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(view.mac.formatted(.upperColon)).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                if let name = view.name { Text(name).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                if let vendor = PirateStore.vendor(view.mac) {
                    Text(vendor).font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ForEach(view.items, id: \.self) { item in
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: MACSightingRow.symbol(item.kind)).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 16)
                    Text(item.kind.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(width: 104, alignment: .leading)
                    Text(item.value)
                        .font(item.kind == .ip ? Theme.mono(12) : Theme.small)
                        .foregroundStyle(Theme.text).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(item.source.label).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var readStatus: String {
        if store.isReadingDevice { return "relecture de cet appareil" }
        if let message = store.deviceReadMessage { return message }
        let read = store.deviceReadAt.map { "appareil relu \(ToolText.relative($0))" } ?? "historique enregistré"
        // La note ne vaut que pour la recherche relue, sur ce site.
        guard store.hasDeviceRead(for: query), let note = store.deviceReadNote else { return read }
        return read + " · " + note
    }

    /// Pourquoi « Relire cet appareil » est grisé ; nil s'il est actif ou si la lecture est en cours.
    private func readBlocked(_ target: FortiDeviceTarget?, isBlank: Bool, found: Int) -> String? {
        if isBlank { return "Cherchez d’abord une MAC, une IP ou un nom." }
        if target == nil {
            return found == 0 ? "Appareil absent de l’historique\u{00A0}: tapez son IP ou sa MAC au complet pour le relire."
                : "Trop d’appareils trouvés (\(found))\u{00A0}: précisez la recherche pour en relire un."
        }
        guard tokensLoaded else { return nil }
        return store.deviceReadBlocker
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
            Image(systemName: Self.symbol(sighting.kind)).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 16)
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

    static func symbol(_ kind: MACSightingKind) -> String {
        switch kind {
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
