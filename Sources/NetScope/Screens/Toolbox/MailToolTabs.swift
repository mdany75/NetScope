import NetScopeCore
import SwiftUI

/// Note 79 : onglets de l'outil « Courriel » (Super outil, Diagnostic SMTP, En-têtes, Santé,
/// SPF/DKIM/DMARC, MX, Listes noires). Chaque onglet garde l'identifiant de l'ancien outil
/// (`ToolKind`), si bien que l'historique, « Ouvrir dans › » et NETSCOPE_OUTIL_DEMO mènent tout
/// droit au bon onglet. Contrôle segmenté natif ; menu déroulant quand la largeur manque.
struct MailToolTabs: View {
    @ObservedObject var store: ToolStore

    var body: some View {
        let selection = Binding(get: { store.selectedTool }, set: { store.selectedTool = $0 })
        ViewThatFits(in: .horizontal) {
            Picker("Onglet", selection: selection) {
                ForEach(ToolKind.mailTabs) { tool in
                    Text(tool.mailTab?.tabLabel ?? tool.label).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Plus étroit : le même contrôle en petite taille.
            Picker("Onglet", selection: selection) {
                ForEach(ToolKind.mailTabs) { tool in
                    Text(tool.mailTab?.tabLabel ?? tool.label).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            HStack(spacing: 8) {
                Text("Onglet").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("Onglet", selection: selection) {
                    ForEach(ToolKind.mailTabs) { tool in
                        Label(tool.mailTab?.tabLabel ?? tool.label, systemImage: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
        .accessibilityLabel("Onglets de l’outil Courriel")
    }
}
