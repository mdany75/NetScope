import NetScopeCore
import SwiftUI

// Note 80 : partie FortiAP de l'écran Wi-Fi en onglets, sous le bandeau de la FortiGate et les
// tuiles : Bornes, Clients, SSID, Canaux, Voisins, Conseils. Un clic sur une borne (Clients, Canaux,
// Conseils) ouvre l'onglet Bornes sur elle ; la fiche d'un client s'ouvre dans l'onglet Clients ;
// l'onglet choisi est retenu (FortiAPStore.tab). Captures : NETSCOPE_WIFI_ONGLET=bornes|clients|ssid|
// canaux|voisins|conseils.

/// Onglet de la partie FortiAP.
enum FortiAPTab: String, CaseIterable, Identifiable {
    case bornes, clients, ssid, canaux, voisins, pirates, conseils

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bornes: return "Bornes"
        case .clients: return "Clients"
        case .ssid: return "SSID"
        case .canaux: return "Canaux"
        case .voisins: return "Voisins"
        case .pirates: return "Pirates"
        case .conseils: return "Conseils"
        }
    }

    /// Onglet d'une valeur de NETSCOPE_WIFI_ONGLET (« conseils », « Clients »…).
    static func named(_ text: String) -> FortiAPTab? {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return allCases.first { $0.rawValue == folded || $0.label.lowercased() == folded }
    }
}

/// Barre d'onglets : contrôle segmenté natif, avec le nombre d'éléments de chaque onglet.
struct FortiAPTabBar: View {
    @ObservedObject private var store = FortiAPStore.shared

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("Onglet", selection: Binding(get: { store.tab }, set: { select($0) })) {
                ForEach(FortiAPTab.allCases) { tab in Text(title(tab)).tag(tab) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Bornes, clients, SSID, carte des canaux, AP voisins et conseils")
            Spacer(minLength: 0)
        }
    }

    private func select(_ tab: FortiAPTab) {
        // Quitter l'onglet Clients ferme la fiche ouverte (l'onglet Clients revient à la liste).
        if tab != .clients || store.tab == .clients { store.closeClient() }
        store.tab = tab
    }

    private func title(_ tab: FortiAPTab) -> String {
        let o = store.shownOverview
        switch tab {
        case .bornes: return "Bornes (\(o.aps.count))"
        case .clients: return "Clients (\(o.clients.count))"
        case .ssid: return "SSID (\(o.distinctSSIDs.count))"
        case .canaux: return "Canaux"
        case .voisins: return "Voisins (\(o.rogues.count))"
        case .pirates: return "Pirates"
        case .conseils: return "Conseils (\(store.shownDiagnosis.advice.count))"
        }
    }
}

/// Contenu de l'onglet choisi.
struct FortiAPTabContent: View {
    @ObservedObject private var store = FortiAPStore.shared
    @Binding var selectedAP: FortiManagedAP.ID?
    @Binding var band: WifiBand

    var body: some View {
        switch store.tab {
        case .bornes:
            SidePanelSplit(sideWidth: 320, collapse: .below) {
                VStack(spacing: 14) {
                    FortiAPTable(selection: $selectedAP)
                    // Note 46 : clients de la borne choisie, par radio et par SSID.
                    FortiAPClientsOfAP(apID: selectedAP)
                }
            } side: {
                FortiAPDetailPanel(apID: selectedAP)
            }
        case .clients:
            if let client = store.openClient {
                // Note 46 : fiche complète du client (‹ ramène à la borne ou au SSID d'origine).
                FortiAPClientDetailView(client: client)
            } else {
                FortiAPClientTable()
            }
        case .ssid:
            VStack(spacing: 14) {
                FortiAPSSIDTable()
                FortiAPSSIDGroupsPanel()
            }
        case .canaux:
            FortiAPChannelMap(band: $band, selectedAP: $selectedAP)
        case .voisins:
            FortiAPRogueTable()
        case .pirates:
            FortiAPPirateTable()
        case .conseils:
            FortiAPAdvicePanel(selectedAP: $selectedAP, band: $band)
        }
    }
}

/// Onglet SSID : clients et bornes de chaque SSID (site par site), avec un lien vers ses clients.
struct FortiAPSSIDGroupsPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = FortiAPStore.shared

    var body: some View {
        let o = store.shownOverview
        let groups = FortiWifiClientGroups.bySSID(o)
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WifiHeading("Clients et bornes par SSID")
                    Spacer(minLength: 0)
                    Text("\(o.clients.count) client\(o.clients.count > 1 ? "s" : "")").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                if groups.isEmpty {
                    Text("Aucun client Wi-Fi associé.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in row(group, multiSite: o.isMultiSite, total: max(1, o.clients.count)) }
                    }
                }
            }
        }
    }

    private func row(_ group: FortiWifiSSIDGroup, multiSite: Bool, total: Int) -> some View {
        let weak = group.clients.filter(store.isWeak).count
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                    Text(group.ssid).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if multiSite { WifiPill(text: group.site, size: 10) }
                    if let config = group.config { WifiPill(text: config.securityLabel, size: 10) }
                    if let vlan = group.config?.vlan { Text("VLAN \(vlan)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary) }
                }
                Text(group.apNames.isEmpty ? "Aucune borne ne sert de client" : "Bornes\u{00A0}: " + group.apNames.joined(separator: ", "))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(group.count) client\(group.count > 1 ? "s" : "")").font(Theme.mono(12, weight: .semibold))
                Text(group.bandsLabel + (weak > 0 ? " · \(weak) faible\(weak > 1 ? "s" : "")" : ""))
                    .font(Theme.caption).foregroundStyle(weak > 0 ? Theme.warning : Theme.textSecondary).lineLimit(1)
            }
            .fixedSize()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(group.count) / CGFloat(total))
                }
            }
            .frame(width: 80, height: 5)
            Button("Voir les clients") {
                state.navigate(NavDestination(.wifi, focus: .wifiSSID(group.id), sites: .include(store.siteKey(forLabel: group.site))))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(group.count == 0)
            .help("Ouvre l’onglet Clients, regroupé par SSID, sur «\u{00A0}\(group.ssid)\u{00A0}»")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
