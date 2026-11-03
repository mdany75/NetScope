import NetScopeCore
import SwiftUI

/// Réglages › Général : langue, thème, ouverture de session, barre de menus.
struct RegGeneralSection: View {
    @ObservedObject private var prefs = RegPrefs.shared
    @State private var language = "fr"
    @State private var theme = "light"
    @State private var menuBar = false

    var body: some View {
        RegPanel(title: "Général", subtitle: "Langue, apparence et comportement de l’application au démarrage.") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    RegLabel("Langue de l’interface")
                    Picker("", selection: $language) {
                        Text("Français").tag("fr")
                        Text("English (bientôt)").tag("en").disabled(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 260)
                    Text("NetScope est entièrement en français ; d’autres langues viendront plus tard.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    RegLabel("Thème")
                    RegSegmented(selection: $theme, options: [
                        .init(value: "light", label: "Clair"),
                        .init(value: "dark", label: "Sombre", enabled: false),
                        .init(value: "auto", label: "Auto", enabled: false),
                    ])
                    Text("Thème sombre : bientôt.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                .padding(.leading, 20)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                RegToggleRow(title: "Démarrer à l’ouverture de session",
                             detail: prefs.launchAtLoginMessage ?? "NetScope s’ouvre automatiquement quand vous ouvrez votre session macOS.",
                             isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
                RegToggleRow(title: "Icône dans la barre de menus",
                             detail: "Accès rapide : scan du réseau courant, ping, état des alertes.",
                             isOn: $menuBar, soon: true)
                RegToggleRow(title: "Confirmer avant de scanner une plage publique",
                             detail: "Évite de sonder par erreur des adresses hors RFC 1918.",
                             isOn: $prefs.confirmPublicRanges)
            }
            .padding(.top, 16)
        }
        .onAppear { prefs.refreshLaunchAtLogin() }
    }
}
