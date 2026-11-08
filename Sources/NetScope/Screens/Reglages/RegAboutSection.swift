import AppKit
import NetScopeCore
import SwiftUI

/// Réglages › À propos : version, base OUI, source des mises à jour, composants.
struct RegAboutSection: View {
    @ObservedObject private var navigation = RegNavigation.shared
    @ObservedObject private var updates = UpdController.shared
    @ObservedObject private var oui = OUIController.shared

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.accentSoft)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NetScope").font(Theme.screenTitle)
                        Text("Version \(UpdController.currentVersionText) · build \(RegEnvironment.build)")
                            .foregroundStyle(Theme.textSecondary)
                        Text("L’outil du technicien réseau, pour macOS.").font(Theme.small).foregroundStyle(Theme.textTertiary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    row("macOS requis") { Text("macOS 14 ou ultérieur") }
                    row("Base OUI (IEEE)") {
                        Text(oui.source.map { "\($0.description) · \($0.place)" } ?? "Chargement…")
                            .onAppear { oui.refresh() }
                    }
                    row("Mises à jour") {
                        HStack(spacing: 0) {
                            Text("Releases GitHub · ")
                            Text("github.com/mdany75/NetScope").font(Theme.mono(12))
                        }
                    }
                    row("Signature") { Text("Developer ID, équipe \(UpdSignature.expectedTeamID)").font(Theme.mono(12)) }
                    row("Identifiant") { Text(UpdSignature.bundleIdentifier).font(Theme.mono(12)) }
                    row("Préférences") { Text("~/Library/Preferences · ~/Library/Application Support/NetScope").font(Theme.mono(12)) }
                    row("Éditeur") { Text("Dany Ménard") }
                }
                .font(Theme.small)
                .padding(.top, 16)

                RegLabel("Composants tiers").padding(.top, 16).padding(.bottom, 6)
                Text("Aucun : NetScope n’utilise que les frameworks d’Apple (SwiftUI, Network, Security). Polices système SF Pro et SF Mono.")
                    .font(Theme.small).foregroundStyle(Theme.neutralText)
                    .fixedSize(horizontal: false, vertical: true)

                ActionRow {
                    Button("Rechercher des mises à jour") {
                        navigation.section = .majs
                        Task { await updates.check(userInitiated: true) }
                    }
                    .buttonStyle(.secondary)
                    Button("Voir sur GitHub") { NSWorkspace.shared.open(UpdateChecker().releasesPage) }
                        .buttonStyle(.secondary)
                }
                .padding(.top, 16)
            }
        }
    }

    private func row<Value: View>(_ key: String, @ViewBuilder _ value: () -> Value) -> some View {
        GridRow {
            Text(key).foregroundStyle(Theme.textSecondary).frame(width: 190, alignment: .leading)
            value()
        }
    }
}
