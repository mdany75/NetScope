import AppKit
import NetScopeCore
import SwiftUI

/// Réglages › Identifiants, partie SSH et WMI (croquis : tableau des identifiants et fiche de
/// l'identifiant choisi). Les secrets vont au Trousseau et ne sont jamais réaffichés.
struct RegRemoteCredentialsPanel: View {
    @ObservedObject private var store = RegRemoteCredentialStore.shared
    @StateObject private var table = RegRemoteCredentialTable.makeModel()
    @State private var selection: UUID?
    @State private var secretDraft = ""
    @State private var hostDraft = ""
    /// Identifiant dont la suppression attend confirmation.
    @State private var removing: RemoteCredential?

    private var selected: RemoteCredential? {
        store.credentials.first { $0.id == selection } ?? store.credentials.first
    }

    var body: some View {
        RegPanel(title: "Identifiants SSH et WMI",
                 subtitle: "Pour se connecter aux switchs, serveurs et postes (relevé de l’Inventaire, plus tard). Mots de passe et phrases secrètes restent au Trousseau.",
                 accessory: {
                     Menu {
                         Button("Identifiant SSH") { select(store.add(.ssh)) }
                         Button("Identifiant WMI (Windows)") { select(store.add(.wmi)) }
                     } label: {
                         Label("Nouvel identifiant", systemImage: "plus")
                     }
                     .menuStyle(.button)
                     .fixedSize()
                 }, content: {
                     if store.credentials.isEmpty {
                         RegNotice("Aucun identifiant SSH ni WMI. « Nouvel identifiant » en ajoute un.", tone: .neutral)
                     } else {
                         RegRemoteCredentialTable(rows: store.credentials, table: table, selection: $selection, onTest: test)
                             .regTableFrame()
                         if let selected {
                             detail(selected).padding(.top, 12)
                         }
                     }
                     if let message = store.message {
                         RegNotice(message.text, tone: message.tone).padding(.top, 10)
                     }
                 })
        .onAppear {
            if selection == nil { select(store.credentials.first(where: { $0.kind == .ssh }) ?? store.credentials.first) }
        }
        .confirmationDialog("Supprimer cet identifiant\u{00A0}?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { credential in
            Button("Supprimer «\u{00A0}\(credential.name)\u{00A0}»", role: .destructive) {
                store.remove(credential.id)
                select(store.credentials.first)
                removing = nil
            }
            Button("Annuler", role: .cancel) { removing = nil }
        } message: { _ in
            Text("Le mot de passe ou la phrase secrète seront effacés du Trousseau.")
        }
    }

    private func select(_ credential: RemoteCredential?) {
        selection = credential?.id
        secretDraft = ""
        hostDraft = credential?.lastHost ?? ""
    }

    private func test(_ credential: RemoteCredential) {
        let host = credential.id == selected?.id && !hostDraft.isEmpty ? hostDraft : credential.lastHost
        store.test(credential.id, host: host)
    }

    /// Liaison vers un champ de l'identifiant (enregistré à chaque modification).
    private func field<T>(_ credential: RemoteCredential, _ keyPath: WritableKeyPath<RemoteCredential, T>) -> Binding<T> {
        Binding(get: { store.credentials.first { $0.id == credential.id }?[keyPath: keyPath] ?? credential[keyPath: keyPath] },
                set: { value in
                    guard var current = store.credentials.first(where: { $0.id == credential.id }) else { return }
                    current[keyPath: keyPath] = value
                    store.update(current)
                })
    }

    // MARK: Fiche

    private func detail(_ credential: RemoteCredential) -> some View {
        RegColumns(minColumnWidth: 340) {
            fields(credential)
            testColumn(credential)
        }
        .onChange(of: selection) { _, _ in
            secretDraft = ""
            hostDraft = selected?.lastHost ?? ""
        }
    }

    private func fields(_ credential: RemoteCredential) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(credential.name.isEmpty ? "Sans nom" : credential.name).font(Theme.bodySemibold)
                Chip(text: credential.kind.label, tone: credential.kind == .ssh ? .accent : .neutral)
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                RegField(label: "Nom") { RegTextField(placeholder: "ex. ssh-netadmin", text: field(credential, \.name), mono: true) }
                RegField(label: "Port TCP") {
                    RegTextField(placeholder: String(credential.kind.defaultPort),
                                 text: Binding(get: { String(field(credential, \.port).wrappedValue) },
                                               set: { if let port = UInt16($0.filter(\.isNumber)), port > 0 { field(credential, \.port).wrappedValue = port } }),
                                 mono: true)
                    .frame(width: 80)
                }
            }
            if credential.kind == .ssh {
                sshFields(credential)
            } else {
                wmiFields(credential)
            }
            RegField(label: "Portée (facultatif)") {
                RegTextField(placeholder: "ex. Switchs du cœur, plage 10.10.0.0/24", text: field(credential, \.scope))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func secretPlaceholder(_ credential: RemoteCredential, optional: Bool = false) -> String {
        if store.secretsSet.contains(credential.id) { return "•••••••• (enregistré)" }
        return optional ? "Aucune (clé sans phrase secrète)" : "Non renseigné"
    }

    @ViewBuilder private func sshFields(_ credential: RemoteCredential) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RegField(label: "Utilisateur") { RegTextField(placeholder: "ex. netadmin", text: field(credential, \.user), mono: true) }
            RegField(label: "Méthode") {
                RegSegmented(selection: field(credential, \.sshMethod),
                             options: RemoteCredential.SSHMethod.allCases.map { .init(value: $0, label: $0.label) })
            }
        }
        if credential.sshMethod == .key {
            RegField(label: "Clé privée") {
                HStack(spacing: 6) {
                    RegTextField(placeholder: "~/.ssh/id_ed25519", text: field(credential, \.keyPath), mono: true)
                    Button("Choisir…") { chooseKey(credential) }.buttonStyle(RegSmallButtonStyle())
                }
            }
        }
        secretField(credential, label: credential.sshMethod == .key ? "Phrase secrète de la clé (facultative)" : "Mot de passe",
                    optional: credential.sshMethod == .key)
    }

    @ViewBuilder private func wmiFields(_ credential: RemoteCredential) -> some View {
        RegField(label: "Utilisateur (DOMAINE\\utilisateur)") {
            RegTextField(placeholder: "ex. BUREAU\\svc-inventaire",
                         text: Binding(get: { store.credentials.first { $0.id == credential.id }?.qualifiedUser ?? credential.qualifiedUser },
                                       set: { text in
                                           guard var current = store.credentials.first(where: { $0.id == credential.id }) else { return }
                                           let parts = RemoteCredential.splitWindowsUser(text)
                                           current.domain = parts.domain
                                           current.user = parts.user
                                           store.update(current)
                                       }),
                         mono: true)
        }
        secretField(credential, label: "Mot de passe", optional: false)
    }

    private func secretField(_ credential: RemoteCredential, label: String, optional: Bool) -> some View {
        RegField(label: label) {
            HStack(spacing: 6) {
                RegTextField(placeholder: secretPlaceholder(credential, optional: optional), text: $secretDraft, mono: true, secure: true)
                Button {
                    store.setSecret(secretDraft, for: credential)
                    secretDraft = ""
                } label: { Label("Trousseau", systemImage: "lock") }
                    .buttonStyle(RegSmallButtonStyle())
                    .regDisabled(secretDraft.isEmpty)
                    .help("Enregistrer dans le Trousseau macOS (service \(credential.keychainService))")
                if store.secretsSet.contains(credential.id) {
                    Button("Effacer") { store.setSecret("", for: credential) }
                        .buttonStyle(RegSmallButtonStyle())
                        .help("Effacer ce secret du Trousseau")
                }
            }
        }
    }

    private func chooseKey(_ credential: RemoteCredential) {
        guard !RegEnvironment.isSandboxed else { return }
        let panel = NSOpenPanel()
        panel.title = "Clé privée SSH"
        panel.prompt = "Choisir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        field(credential, \.keyPath).wrappedValue = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func testColumn(_ credential: RemoteCredential) -> some View {
        let isRunning = store.running.contains(credential.id)
        return VStack(alignment: .leading, spacing: 10) {
            RegField(label: "Adresse à tester") {
                HStack(spacing: 6) {
                    RegTextField(placeholder: "ex. 10.182.122.2", text: $hostDraft, mono: true)
                    Button {
                        store.test(credential.id, host: hostDraft)
                    } label: {
                        if isRunning {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Test…") }
                        } else {
                            Label("Tester", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.primary)
                    .regDisabled(isRunning || hostDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Résultat du test").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(resultText(credential, running: isRunning))
                    .font(Theme.small)
                    .foregroundStyle(resultTone(credential, running: isRunning).foregroundIfNotNeutral)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(resultTone(credential, running: isRunning).backgroundIfNotNeutral))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border.opacity(resultTone(credential, running: isRunning) == .neutral ? 1 : 0)))
            }
            Text(credential.kind == .ssh
                 ? "Test par /usr/bin/ssh (BatchMode, délai 6\u{00A0}s) avec la commande inoffensive « uname -a ». L’empreinte de l’hôte est retenue par NetScope au premier test, sans toucher à ~/.ssh/known_hosts."
                 : WMIReachabilityTest.limitation)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Supprimer", role: .destructive) { removing = credential }
                .buttonStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func resultText(_ credential: RemoteCredential, running: Bool) -> String {
        if running { return "Test en cours…" }
        guard let date = credential.lastTestAt, !credential.lastTestMessage.isEmpty else { return "Jamais testé." }
        return credential.lastTestMessage + " (\(RegFormat.moment(date)))"
    }

    private func resultTone(_ credential: RemoteCredential, running: Bool) -> Tone {
        if running { return .accent }
        return RegRemoteCredentialTable.tone(credential.lastTestStatus)
    }
}

private extension Tone {
    var foregroundIfNotNeutral: Color { self == .neutral ? Theme.textSecondary : foreground }
    var backgroundIfNotNeutral: Color { self == .neutral ? Theme.panelMuted : background }
}

// MARK: - Tableau standard « reglages.identifiants »

struct RegRemoteCredentialTable: View {
    let rows: [RemoteCredential]
    @ObservedObject var table: StandardTableModel<RemoteCredential>
    @Binding var selection: UUID?
    let onTest: (RemoteCredential) -> Void
    @ObservedObject private var store = RegRemoteCredentialStore.shared

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "type", title: "Type"),
        StandardColumn(id: "utilisateur", title: "Utilisateur"),
        StandardColumn(id: "methode", title: "Méthode"),
        StandardColumn(id: "portee", title: "Portée"),
        StandardColumn(id: "test", title: "Dernier test"),
        StandardColumn(id: "action", title: "Tester"),
        StandardColumn(id: "port", title: "Port", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RemoteCredential>] = [
        "nom": KeyPathComparator(\RemoteCredential.name),
        "type": KeyPathComparator(\RemoteCredential.kind.rawValue),
        "utilisateur": KeyPathComparator(\RemoteCredential.qualifiedUser),
        "methode": KeyPathComparator(\RemoteCredential.methodSummary),
        "portee": KeyPathComparator(\RemoteCredential.scope),
        "test": KeyPathComparator(\RemoteCredential.sortTestDate),
        "action": KeyPathComparator(\RemoteCredential.name),
        "port": KeyPathComparator(\RemoteCredential.port),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RemoteCredential> {
        StandardTableModel(id: "reglages.identifiants", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    static func tone(_ status: CredentialTestOutcome.Status?) -> Tone {
        switch status {
        case .success?: return .success
        case .partial?: return .warning
        case .failure?: return .critical
        case nil: return .neutral
        }
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.kind == .ssh ? "terminal" : "pc").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(row.name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .frame(height: RegSwitchTableMetrics.rowHeight - 8)
            }
            .width(min: 110, ideal: 140)
            .customizationID("nom")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("TYPE", sortUsing: table.sort("type")) { row in
                Chip(text: row.kind.label, tone: row.kind == .ssh ? .accent : .neutral)
            }
            .width(min: 50, ideal: 60)
            .customizationID("type")

            TableColumn("UTILISATEUR", sortUsing: table.sort("utilisateur")) { row in
                Text(row.qualifiedUser.isEmpty ? "—" : row.qualifiedUser).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            .customizationID("utilisateur")

            TableColumn("MÉTHODE", sortUsing: table.sort("methode")) { row in
                HStack(spacing: 4) {
                    Text(row.methodSummary).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    if store.secretsSet.contains(row.id) {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.success)
                            .help("Secret enregistré au Trousseau")
                    }
                }
            }
            .width(min: 90, ideal: 140)
            .customizationID("methode")

            TableColumn("PORTÉE", sortUsing: table.sort("portee")) { row in
                Text(row.scope.isEmpty ? "—" : row.scope).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .help(row.scope)
            }
            .width(min: 80, ideal: 130)
            .customizationID("portee")

            TableColumn("DERNIER TEST", sortUsing: table.sort("test")) { row in
                if store.running.contains(row.id) {
                    Text("Test en cours…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                } else if let date = row.lastTestAt {
                    let tone = Self.tone(row.lastTestStatus)
                    Text(RegFormat.moment(date)).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.foreground)
                        .help(row.lastTestMessage)
                } else {
                    Text("Jamais").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            .width(min: 90, ideal: 130)
            .customizationID("test")

            TableColumn("TESTER", sortUsing: table.sort("action")) { row in
                Button("Tester") { onTest(row) }
                    .buttonStyle(RegSmallButtonStyle())
                    .regDisabled(store.running.contains(row.id) || row.lastHost.isEmpty && row.id != selection)
                    .help(row.lastHost.isEmpty ? "Choisissez l’identifiant et saisissez l’adresse à tester" : "Tester sur \(row.lastHost)")
            }
            .width(min: 60, ideal: 70)
            .customizationID("action")

            TableColumn("PORT", sortUsing: table.sort("port")) { row in
                Text("TCP \(row.port)").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            .width(min: 50, ideal: 70)
            .customizationID("port")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .frame(height: RegSwitchTableMetrics.height(rows: min(rows.count, 8)))
    }
}

extension RemoteCredential {
    var sortTestDate: Date { lastTestAt ?? .distantPast }
}
