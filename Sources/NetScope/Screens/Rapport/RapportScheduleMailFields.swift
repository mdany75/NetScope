import NetScopeCore
import SwiftUI

/// Note 78 : réglages de l'envoi automatique d'un rapport planifié (« Envoyer par courriel ») :
/// destinataires de chaque site, serveur SMTP des Alertes utilisé, ce qui manque encore, et
/// « Envoyer un essai… ». Rien ne part tant que ce choix n'est pas enregistré pour CE rapport.
struct RapportScheduleMailFields: View {
    @ObservedObject var store: RapportScheduleStore
    let draft: Binding<ReportSchedule>
    @ObservedObject private var alerts = AlertDispatcher.shared
    @ObservedObject private var sites = SiteModel.shared
    /// Texte saisi par site (gardé tel quel pendant la frappe ; la liste est relue à chaque changement).
    @State private var texts: [String: String] = [:]
    @State private var confirmTest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.wrappedValue.siteKeys.isEmpty {
                Text("Choisissez au moins un site pour indiquer ses destinataires.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(draft.wrappedValue.siteKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Destinataires · " + sites.name(forKey: key))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    TextField("Destinataires", text: binding(key), prompt: Text("direction@client.ca, ti@client.ca"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(Theme.mono(12))
                        .help("Adresses séparées par des virgules\u{00A0}: chaque site reçoit son propre rapport.")
                }
            }
            server
            let problems = draft.wrappedValue.siteKeys.flatMap {
                alerts.reportProblems(draft.wrappedValue, siteKey: $0, siteName: sites.name(forKey: $0))
            }
            if !problems.isEmpty {
                Text(problems.joined(separator: "\n"))
                    .font(Theme.caption)
                    .foregroundStyle(Tone.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Tone.warning.background))
            }
            HStack(spacing: 6) {
                Button("Envoyer un essai…") { confirmTest = true }
                    .buttonStyle(RapportSmallButtonStyle())
                    .disabled(store.isNewDraft || !problems.isEmpty || store.producing != nil || store.sending != nil)
                    .help(store.isNewDraft ? "Planifiez d’abord ce rapport, puis envoyez un essai."
                          : "Produit le rapport maintenant et l’envoie aux destinataires ci-dessus (rapport enregistré).")
                Spacer(minLength: 0)
            }
            Text("Après chaque production, le fichier part en pièce jointe par le serveur SMTP des Alertes. Désactivé par défaut\u{00A0}: rien ne part sans ce choix, enregistré pour ce rapport. Chaque envoi est inscrit au journal des Alertes.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            alerts.refreshSecrets()
            for key in draft.wrappedValue.siteKeys where texts[key] == nil {
                texts[key] = (draft.wrappedValue.mailRecipients[key] ?? []).joined(separator: ", ")
            }
        }
        .confirmationDialog("Envoyer un essai de ce rapport\u{00A0}?", isPresented: $confirmTest) {
            Button("Envoyer l’essai") { store.sendTest(draft.wrappedValue.id) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le rapport enregistré est produit maintenant, puis envoyé à\u{00A0}: \(store.testRecipients(saved ?? draft.wrappedValue)). Les changements non enregistrés ne comptent pas.")
        }
    }

    private var saved: ReportSchedule? { store.schedules.first { $0.id == draft.wrappedValue.id } }

    @ViewBuilder private var server: some View {
        if let label = alerts.reportServerLabel {
            VStack(alignment: .leading, spacing: 2) {
                Label("Serveur des Alertes\u{00A0}: \(label)", systemImage: "server.rack")
                Text("Expéditeur\u{00A0}: " + (alerts.settings.smtp.from.isEmpty ? "à renseigner" : alerts.settings.smtp.from))
                    .padding(.leading, 22)
            }
            .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            .help("Réglages › Alertes › Courriel\u{00A0}: même serveur, même compte et même mot de passe (Trousseau).")
        } else {
            Label("Aucun serveur SMTP\u{00A0}: configurez Réglages › Alertes › Courriel.", systemImage: "exclamationmark.triangle")
                .font(Theme.caption).foregroundStyle(Theme.warning)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { texts[key] ?? (draft.wrappedValue.mailRecipients[key] ?? []).joined(separator: ", ") },
                set: { text in
                    texts[key] = text
                    let list = AlertAddress.parseList(text)
                    draft.wrappedValue.mailRecipients[key] = list.isEmpty ? nil : list
                })
    }
}
