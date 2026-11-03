import NetScopeCore
import SwiftUI

/// Réglages › Switchs : découverte automatique des switchs en SNMP à la fin de chaque scan,
/// communautés à essayer (gardées au Trousseau) et switchs connus.
struct RegSwitchesSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var prefs = RegPrefs.shared
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject private var navigation = RegNavigation.shared
    /// Une communauté par ligne (« , » et « ; » sont permis dans une communauté).
    @State private var rows: [String] = []
    @State private var savedRows: [String] = []
    @State private var reveal = false
    @State private var loaded = false
    @State private var message: (text: String, tone: Tone)?

    var body: some View {
        RegPanel(title: "Switchs interrogés",
                 subtitle: "Tables MAC, voisins LLDP/CDP et état des ports servent à localiser chaque appareil (switch, port, VLAN).") {
            RegToggleRow(title: "Découvrir les switchs automatiquement (SNMP)",
                         detail: "Pendant chaque scan, NetScope envoie des requêtes SNMP v2c en lecture seule (GET, UDP 161) à chaque appareil en ligne des plages scannées aux adresses privées (jamais vers Internet), avec la communauté des Identifiants puis celles ci-dessous. Les switchs qui répondent sont ajoutés et relevés, puis chaque appareil reçoit son switch, son port et son VLAN. Rien n’est jamais modifié sur les appareils. macOS peut demander l’autorisation de lire le Trousseau au premier scan.",
                         isOn: $prefs.autoDiscoverSwitches)
            RegToggleRow(title: "Lire la table ARP de la passerelle",
                         detail: "Lit en SNMP la table ARP de la passerelle et des routeurs découverts\u{00A0}: elle donne la MAC des appareils des autres VLAN, indispensable pour les localiser.",
                         isOn: $prefs.readGatewayARP)
            if !prefs.autoDiscoverSwitches {
                RegNotice("Découverte coupée\u{00A0}: elle reste faite avec le profil Complet. Sinon, ajoutez vos switchs à la main dans «\u{00A0}Switchs et ports\u{00A0}».", tone: .neutral)
                    .padding(.bottom, 10)
            }
            communitiesBox
                .padding(.top, 4)
            knownSwitches
                .padding(.top, 14)
        }
        .onAppear(perform: load)
    }

    // MARK: Communautés

    private var communitiesBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Communautés à essayer").font(Theme.bodySemibold)
                Chip(text: "SNMP v2c", tone: .warning)
                Spacer()
                Button("Identifiants…") { navigation.section = .identifiants }
                    .buttonStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    RegLabel("Communautés, dans l’ordre d’essai (une par ligne)")
                    Spacer()
                    Button(reveal ? "Masquer" : "Afficher") { reveal.toggle() }
                        .buttonStyle(.secondary)
                }
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        RegTextField(placeholder: "public", text: Binding(get: { index < rows.count ? rows[index] : "" },
                                                                         set: { if index < rows.count { rows[index] = $0 } }),
                                     mono: true, secure: !reveal)
                        Button { rows.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textSecondary)
                            .help("Retirer cette communauté")
                    }
                }
                Button { rows.append("") } label: { Label("Ajouter une communauté", systemImage: "plus") }
                    .buttonStyle(.secondary)
            }
            Text("Ordre d’essai\u{00A0}: communauté enregistrée dans Réglages › Identifiants, puis cette liste («\u{00A0}public\u{00A0}» par défaut). La liste et la communauté qui a répondu pour chaque switch sont gardées dans le Trousseau macOS, jamais dans les préférences. Attention\u{00A0}: en v2c, la communauté circule en clair sur le réseau.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let message {
                    Text(message.text).font(Theme.small).foregroundStyle(message.tone.foreground)
                } else if rows != savedRows {
                    Text("Modifications non enregistrées").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warning)
                }
                Spacer()
                Button("Annuler") { rows = savedRows; message = nil }
                    .buttonStyle(.secondary)
                    .regDisabled(rows == savedRows)
                Button(action: save) { Label("Enregistrer dans le Trousseau", systemImage: "lock") }
                    .buttonStyle(.primary)
                    .regDisabled(rows == savedRows)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Switchs connus

    @ViewBuilder private var knownSwitches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RegLabel("Switchs connus")
                Spacer()
                if let result = store.autoResult {
                    Text("Dernière découverte\u{00A0}: \(SwitchText.dateTime(result.date))")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            if store.rememberedCommunities > 0 {
                HStack(spacing: 8) {
                    Text("\(store.rememberedCommunities) communauté\(store.rememberedCommunities > 1 ? "s" : "") retenue\(store.rememberedCommunities > 1 ? "s" : "") au Trousseau pour les switchs découverts.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Oublier les communautés retenues") { store.forgetCommunities() }
                        .buttonStyle(.secondary)
                }
            }
            if store.hosts.isEmpty {
                Text("Aucun switch pour l’instant\u{00A0}: lancez un scan, les switchs qui répondent en SNMP s’ajouteront ici.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(store.hosts, id: \.self) { host in
                    row(host)
                }
            }
            if !store.ignoredHosts.isEmpty {
                RegLabel("Switchs écartés (jamais interrogés par la découverte)")
                    .padding(.top, 8)
                ForEach(store.ignoredHosts.sorted(), id: \.self) { host in
                    HStack(spacing: 10) {
                        Image(systemName: "nosign").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        Text(host).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Button("Ne plus ignorer") { store.unignore(host) }
                            .buttonStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                }
            }
        }
    }

    private func row(_ host: String) -> some View {
        let snapshot = store.snapshots[host]
        return HStack(spacing: 10) {
            Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Text(snapshot?.displayName ?? host).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
            Text(host).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            if let snapshot { Text(SwitchText.model(snapshot)).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            Spacer(minLength: 8)
            if store.isAutoDiscovered(host) {
                Chip(text: "Découvert automatiquement", tone: .accent)
            } else {
                Chip(text: "Ajouté à la main", tone: .neutral)
            }
            if store.errors[host] != nil {
                Chip(text: "Sans réponse", tone: .critical)
            } else if snapshot != nil {
                Chip(text: "Relevé", tone: .success)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }

    // MARK: Trousseau

    private func load() {
        guard !loaded else { return }
        loaded = true
        let list = RegSNMPDiscoveryVault.tryList()
        rows = list
        savedRows = list
    }

    private func save() {
        let list = RegSNMPDiscoveryVault.parse(rows.joined(separator: "\n"))
        do {
            try RegSNMPDiscoveryVault.saveTryList(list)
            rows = list
            savedRows = list
            message = list.isEmpty
                ? ("Liste vide enregistrée\u{00A0}: seule la communauté des Identifiants sera essayée.", .warning)
                : ("Enregistré dans le Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }
}
