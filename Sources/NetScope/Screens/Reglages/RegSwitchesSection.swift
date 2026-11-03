import NetScopeCore
import SwiftUI

/// Réglages › Switchs : découverte automatique des switchs en SNMP à la fin de chaque scan,
/// communautés à essayer (gardées au Trousseau) et switchs connus.
struct RegSwitchesSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var prefs = RegPrefs.shared
    @ObservedObject private var store = SwitchStore.shared
    @ObservedObject private var navigation = RegNavigation.shared
    @State private var communitiesText = ""
    @State private var savedText = ""
    @State private var loaded = false
    @State private var message: (text: String, tone: Tone)?

    var body: some View {
        RegPanel(title: "Switchs interrogés",
                 subtitle: "Tables MAC, voisins LLDP/CDP et état des ports servent à localiser chaque appareil (switch, port, VLAN).") {
            RegToggleRow(title: "Découvrir les switchs automatiquement (SNMP)",
                         detail: "À la fin de chaque scan, NetScope envoie des requêtes SNMP v2c en lecture seule (GET, UDP 161) à chaque appareil en ligne des plages scannées, avec la communauté des Identifiants puis celles ci-dessous. Les switchs qui répondent sont ajoutés et relevés, puis chaque appareil reçoit son switch, son port et son VLAN. Rien n’est jamais modifié sur les appareils.",
                         isOn: $prefs.autoDiscoverSwitches)
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
            RegField(label: "Communautés, dans l’ordre d’essai (séparées par des virgules)") {
                RegTextField(placeholder: "public", text: $communitiesText, mono: true)
            }
            Text("Ordre d’essai\u{00A0}: communauté enregistrée dans Réglages › Identifiants, puis cette liste («\u{00A0}public\u{00A0}» par défaut). La liste et la communauté qui a répondu pour chaque switch sont gardées dans le Trousseau macOS, jamais dans les préférences. Attention\u{00A0}: en v2c, la communauté circule en clair sur le réseau.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let message {
                    Text(message.text).font(Theme.small).foregroundStyle(message.tone.foreground)
                } else if communitiesText != savedText {
                    Text("Modifications non enregistrées").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warning)
                }
                Spacer()
                Button("Annuler") { communitiesText = savedText; message = nil }
                    .buttonStyle(.secondary)
                    .regDisabled(communitiesText == savedText)
                Button(action: save) { Label("Enregistrer dans le Trousseau", systemImage: "lock") }
                    .buttonStyle(.primary)
                    .regDisabled(communitiesText == savedText)
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
            if store.hosts.isEmpty {
                Text("Aucun switch pour l’instant\u{00A0}: lancez un scan, les switchs qui répondent en SNMP s’ajouteront ici.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(store.hosts, id: \.self) { host in
                    row(host)
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
        let text = RegSNMPDiscoveryVault.tryList().joined(separator: ", ")
        communitiesText = text
        savedText = text
    }

    private func save() {
        let list = RegSNMPDiscoveryVault.parse(communitiesText)
        do {
            try RegSNMPDiscoveryVault.saveTryList(list)
            let text = list.joined(separator: ", ")
            communitiesText = text
            savedText = text
            message = list.isEmpty
                ? ("Liste vide enregistrée\u{00A0}: seule la communauté des Identifiants sera essayée.", .warning)
                : ("Enregistré dans le Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }
}
