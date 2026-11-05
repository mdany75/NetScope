import NetScopeCore
import SwiftUI

/// Réglages › Sites et plages › Inventaire du site (note 10) : « Ajouter automatiquement les
/// appareils scannés », liste d'exclusion (« Ne plus réajouter ») modifiable, archives.
struct RegSiteInventoryBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var inventory = InvModel.shared
    let site: Site
    @State private var newMAC = ""
    @State private var newName = ""
    @State private var error: String?

    private var key: String { SiteFiles.key(for: site.id) }

    var body: some View {
        let store = inventory.inventory(for: key)
        let excluded = store.excluded
        RegSiteBox(title: "Inventaire du site") {
            Toggle(isOn: Binding(get: { store.autoAdd }, set: { inventory.setAutoAdd($0, site: key) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ajouter automatiquement les appareils scannés").font(Theme.small)
                    Text(store.autoAdd ? "Chaque scan de ce site ajoute les nouveaux appareils à son inventaire."
                         : "Un scan met à jour les fiches existantes sans en créer\u{00A0}: «\u{00A0}Ajouter à l’inventaire\u{00A0}» depuis le Scanner (clic droit).")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Text("Ne plus réajouter (\(excluded.count))").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
            if excluded.isEmpty {
                Text("Aucun appareil exclu. Retirez un appareil avec «\u{00A0}Ne plus réajouter\u{00A0}», ou ajoutez sa MAC ci-dessous.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(excluded) { exclusion in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(exclusion.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text([exclusion.mac?.formatted(.upperColon) ?? "sans MAC",
                              exclusion.ip.value == 0 ? nil : exclusion.ip.description,
                              "depuis le " + InvFormat.day(exclusion.date)].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Retirer de la liste") {
                        guard inventory.include(exclusion.key, site: key) else { return }
                        inventory.show("\(exclusion.name) sera ajouté au prochain scan de «\u{00A0}\(site.displayName)\u{00A0}»")
                    }
                    .controlSize(.small)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("MAC", text: $newMAC, prompt: Text("MAC à exclure (ex. 3A:1F:C7:02:9B:E4)"))
                    .textFieldStyle(.roundedBorder).font(Theme.mono(12))
                TextField("Nom", text: $newName, prompt: Text("Nom (facultatif)"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Button("Exclure") { add() }
                    .controlSize(.regular)
                    .disabled(newMAC.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.critical)
            }
            HStack(spacing: 6) {
                Text("\(store.archivedCount) appareil\(store.archivedCount > 1 ? "s" : "") archivé\(store.archivedCount > 1 ? "s" : "")")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Button("Ouvrir l’Inventaire") {
                    SiteScopeStore.shared.include(key, in: .inventaire)
                    state.open(.inventaire)
                }
                .buttonStyle(.ghost)
            }
        }
    }

    private func add() {
        error = nil
        guard let mac = MACAddress(newMAC.trimmingCharacters(in: .whitespaces)) else {
            error = "Adresse MAC illisible."
            return
        }
        guard inventory.exclude(mac: mac, name: newName, site: key) else {
            error = "Cette MAC est déjà exclue, ou un appareil suivi l’a (retirez-le de l’inventaire avec «\u{00A0}Ne plus réajouter\u{00A0}»)."
            return
        }
        newMAC = ""
        newName = ""
    }
}
