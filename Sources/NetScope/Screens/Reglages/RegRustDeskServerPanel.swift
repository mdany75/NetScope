import NetScopeCore
import SwiftUI

/// Réglages › RustDesk › « Tableau de bord du serveur » (note 6, 0.26.2) : compte SSH du serveur
/// (connexion du carnet ou « utilisateur@hôte[:port] »), rafraîchissement, lien vers le tableau de
/// bord. Lecture seule : aucune commande ne modifie le serveur, jamais de sudo.
struct RegRustDeskServerPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var server = RustDeskServerModel.shared
    @State private var password = ""
    @State private var passwordSaved = false
    /// Compte saisi, validé dans les réglages seulement à Retour ou à la sortie du champ (pas à
    /// chaque frappe : chaque changement de compte oublie l'état, les échantillons et relance une lecture).
    @State private var manualText: String?
    @FocusState private var manualFocused: Bool

    /// Choix du compte : une connexion du carnet, ou « saisi » (nil).
    private var accountChoice: Binding<UUID?> {
        Binding(get: { server.settings.connectionID }, set: { server.settings.connectionID = $0 })
    }

    var body: some View {
        RegPanel(title: "Tableau de bord du serveur",
                 subtitle: "Sessions relayées en cours, demandes de connexion, hbbs et hbbr, disque et postes enregistrés, lus par SSH en lecture seule. Le script ne lit que les consoles locales de hbbs et hbbr (127.0.0.1), ps, df et, s’ils sont permis sans sudo, docker ps et la base des postes.",
                 accessory: {
                     RegPill(text: server.settings.hasAccount ? "Compte choisi" : "À configurer",
                             tone: server.settings.hasAccount ? .success : .neutral)
                 }, content: {
                     VStack(alignment: .leading, spacing: 12) {
                         LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                             RegField(label: "Compte SSH du serveur") {
                                 Picker("", selection: accountChoice) {
                                     Text("Saisir utilisateur@hôte…").tag(UUID?.none)
                                     if !server.sshConnections.isEmpty {
                                         Divider()
                                         ForEach(server.sshConnections) { connection in
                                             Text("\(connection.name) · \(connection.username.isEmpty ? "" : connection.username + "@")\(connection.host)")
                                                 .tag(UUID?.some(connection.id))
                                         }
                                     }
                                 }
                                 .labelsHidden()
                                 .pickerStyle(.menu)
                                 .frame(maxWidth: .infinity, alignment: .leading)
                             }
                             if server.settings.connectionID == nil {
                                 RegField(label: "Utilisateur et hôte") {
                                     RegTextField(placeholder: "admin@assistance.exemple.ca[:22]",
                                                  text: Binding(get: { manualText ?? server.settings.manualAccount },
                                                                set: { manualText = $0 }),
                                                  mono: true, invalid: manualInvalid)
                                         .focused($manualFocused)
                                         .onSubmit(commitManualAccount)
                                         .onChange(of: manualFocused) { _, focused in
                                             if !focused { commitManualAccount() }
                                         }
                                         .onDisappear(perform: commitManualAccount)
                                 }
                             }
                         }
                         if let problem = accountProblem {
                             RegNotice(problem, tone: .critical)
                         }
                         if server.settings.connectionID == nil {
                             VStack(alignment: .leading, spacing: 4) {
                                 RegLabel("Mot de passe SSH (facultatif)")
                                 HStack(spacing: 8) {
                                     RegTextField(placeholder: server.hasManualPassword ? "Enregistré au Trousseau (inchangé)" : "Aucun\u{00A0}: clés de ~/.ssh et agent",
                                                  text: $password, secure: true)
                                         // Retour dans le champ vide n'efface rien : seul « Oublier » le fait.
                                         .onSubmit { if !password.isEmpty { savePassword() } }
                                         .disabled(!passwordAccountValid)
                                     Button(password.isEmpty && server.hasManualPassword ? "Oublier" : "Enregistrer", action: savePassword)
                                         .buttonStyle(.secondary)
                                         .disabled(!passwordAccountValid || (password.isEmpty && !server.hasManualPassword))
                                 }
                                 Text(passwordSaved ? "Trousseau mis à jour." : passwordAccountValid
                                      ? "Au Trousseau macOS seulement, lié à ce compte\u{00A0}: remis par SSH_ASKPASS à la seule invite de «\u{00A0}\(server.accountLabel ?? "")\u{00A0}» (jamais à un autre hôte, ni dans la ligne de commande, ni sur le disque)."
                                      : "Indiquez d’abord l’utilisateur et l’hôte (validés par Retour)\u{00A0}: le mot de passe est lié à ce compte.")
                                     .font(Theme.caption).foregroundStyle(passwordSaved ? Theme.success : Theme.textSecondary)
                                     .fixedSize(horizontal: false, vertical: true)
                             }
                         } else {
                             Text("Clé, rebond et mot de passe de la connexion du carnet (Trousseau) sont repris tels quels.")
                                 .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                         }
                         VStack(alignment: .leading, spacing: 6) {
                             RegLabel("Rafraîchissement")
                             HStack(spacing: 10) {
                                 RegSegmented(selection: Binding(get: { server.settings.refreshSeconds },
                                                                 set: { server.settings.refreshSeconds = $0 }),
                                              options: RustDeskDashboardSettings.refreshChoices.map {
                                                  .init(value: $0, label: RustDeskDashboardSettings.refreshLabel($0))
                                              })
                                 Text("seulement quand le tableau de bord est affiché")
                                     .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                     .fixedSize(horizontal: false, vertical: true)
                             }
                         }
                         HStack(spacing: 8) {
                             Button {
                                 server.open(in: state)
                             } label: { Label("Ouvrir le tableau de bord", systemImage: "server.rack") }
                                 .buttonStyle(.primary)
                                 .disabled(!server.settings.hasAccount)
                             Button {
                                 server.copyCommand()
                             } label: { Label("Copier la commande", systemImage: "doc.on.doc") }
                                 .buttonStyle(.secondary)
                                 .disabled(server.accountLabel == nil)
                                 .help("La commande ssh équivalente avec le script de lecture, à essayer dans Terminal (aucun secret)")
                             if let copied = server.copied {
                                 Label(copied, systemImage: "checkmark").font(Theme.small).foregroundStyle(Theme.success)
                             }
                         }
                         Text("Conseil\u{00A0}: un compte du groupe docker voit les conteneurs\u{00A0}; sans sqlite3 ou sans droit de lecture sur /opt/rustdesk/data, le nombre de postes reste inconnu. NetScope n’envoie jamais de commande qui modifie hbbs ou hbbr.")
                             .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                             .fixedSize(horizontal: false, vertical: true)
                     }
                 })
    }

    private var manualInvalid: Bool {
        let text = (manualText ?? server.settings.manualAccount).trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && (try? RustDeskServerAccount.parse(text)) == nil
    }

    /// Le compte saisi validé est utilisable : le mot de passe peut lui être lié.
    private var passwordAccountValid: Bool {
        manualText == nil && RustDeskServerModel.manualPasswordAccount(for: server.settings.manualAccount) != nil
    }

    private func commitManualAccount() {
        guard let text = manualText else { return }
        manualText = nil
        if text != server.settings.manualAccount { server.settings.manualAccount = text }
    }

    private var accountProblem: String? {
        if server.settings.connectionID != nil, server.chosenConnection == nil {
            return "La connexion SSH choisie n’existe plus dans le carnet."
        }
        if server.settings.connectionID != nil, let connection = server.chosenConnection, RustDeskServerAccount(connection: connection) == nil {
            return "La connexion «\u{00A0}\(connection.name)\u{00A0}» n’a pas d’utilisateur SSH."
        }
        if manualInvalid { return "Format attendu\u{00A0}: utilisateur@hôte ou utilisateur@hôte:port." }
        return nil
    }

    private func savePassword() {
        server.setManualPassword(password)
        password = ""
        passwordSaved = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            passwordSaved = false
        }
    }
}
