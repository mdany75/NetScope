import AppKit
import Combine
import NetScopeCore
import SwiftUI

// Note 67 (0.34.0) : extraits personnalisés du terminal intégré et envoi d'une même commande à
// plusieurs sessions ouvertes (choix des sessions, puis confirmation). Les extraits sont des
// commandes, jamais des secrets : ils vont dans les réglages (UserDefaults), pas au Trousseau.
// Note 95 : la préférence voyage avec la synchronisation (partie « Accès distant ») et les
// sauvegardes, et elle est relue à chaud quand un autre Mac la change.

/// Extraits enregistrés par l'utilisateur.
@MainActor
final class TerminalSnippetStore: ObservableObject {
    static let shared = TerminalSnippetStore()
    static let key = TerminalSnippet.preferenceKey

    private let defaults: UserDefaults?
    @Published private(set) var snippets: [TerminalSnippet]

    private init() {
        defaults = RegEnvironment.isSandboxed ? nil : UserDefaults.standard
        if let defaults {
            snippets = TerminalSnippet.decodeList(defaults.data(forKey: Self.key))
        } else {
            snippets = RegEnvironment.isDemo ? Self.demo : []
        }
    }

    /// Démonstration : trois extraits de technicien (aucun n'est envoyé).
    static let demo: [TerminalSnippet] = [
        TerminalSnippet(name: "Sauvegarder la config", command: "copy running-config startup-config", brand: .cisco, sendsReturn: true),
        TerminalSnippet(name: "Ports en erreur", command: "show interfaces counters errors", brand: .cisco, sendsReturn: true),
        TerminalSnippet(name: "Sans pagination", command: "terminal length 0", brand: .cisco, sendsReturn: true),
    ]

    func snippet(_ id: UUID) -> TerminalSnippet? { snippets.first { $0.id == id } }

    /// Synchronisation (note 86) : extraits changés sur un autre Mac.
    func reloadFromDisk() {
        guard let defaults else { return }
        let list = TerminalSnippet.decodeList(defaults.data(forKey: Self.key))
        if list != snippets { snippets = list }
    }

    func save(_ snippet: TerminalSnippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        persist()
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        defaults?.set(TerminalSnippet.encodeList(snippets), forKey: Self.key)
    }
}

/// Extrait en cours de création ou de modification.
struct TerminalSnippetDraft: Identifiable {
    let id = UUID()
    var snippet: TerminalSnippet
    let isNew: Bool
}

/// Feuille « Nouvel extrait » ou « Modifier l'extrait ».
struct TerminalSnippetEditor: View {
    let draft: TerminalSnippetDraft
    let dismiss: () -> Void

    @ObservedObject private var store = TerminalSnippetStore.shared
    @State private var name: String
    @State private var command: String
    @State private var brand: TerminalSnippetBrand?
    @State private var sendsReturn: Bool
    @State private var error: String?
    @State private var confirmingDelete = false

    init(draft: TerminalSnippetDraft, dismiss: @escaping () -> Void) {
        self.draft = draft
        self.dismiss = dismiss
        _name = State(initialValue: draft.snippet.name)
        _command = State(initialValue: draft.snippet.command)
        _brand = State(initialValue: draft.snippet.brand)
        _sendsReturn = State(initialValue: draft.snippet.sendsReturn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.plus").foregroundStyle(Theme.accentStrong)
                    Text(draft.isNew ? "Nouvel extrait" : "Modifier l’extrait").font(Theme.panelTitle)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ToolFieldLabel("Nom")
                    TextField("Sauvegarder la config", text: $name).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ToolFieldLabel("Commande")
                    TextEditor(text: $command)
                        .font(Theme.mono(12))
                        .frame(height: 74)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
                    Text("Une commande par ligne\u{00A0}; chaque ligne est suivie d’Entrée, sauf la dernière si la case ci-dessous est décochée.")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Sessions", selection: $brand) {
                    Text("Toutes les sessions").tag(TerminalSnippetBrand?.none)
                    Divider()
                    ForEach(TerminalSnippetBrand.ordered, id: \.self) { Text($0.label).tag(TerminalSnippetBrand?.some($0)) }
                }
                .fixedSize()
                Toggle("Terminer par Entrée (la commande s’exécute aussitôt)", isOn: $sendsReturn)
                    .toggleStyle(.checkbox)
                if let error { ToolNotice(tone: .critical, message: error) }
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                if !draft.isNew {
                    Button("Supprimer…", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.secondary)
                }
                Spacer()
                // Retour passe à la ligne dans la commande : l'enregistrement se fait par ⌘Retour.
                Text("⌘↩ pour enregistrer").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save).buttonStyle(.primary).keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .background(Theme.panel)
        .confirmationDialog("Supprimer l’extrait «\u{00A0}\(draft.snippet.name)\u{00A0}»\u{00A0}?", isPresented: $confirmingDelete) {
            Button("Supprimer", role: .destructive) {
                store.delete(draft.snippet.id)
                dismiss()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La commande enregistrée sera perdue.")
        }
    }

    private func save() {
        if let message = TerminalSnippet.validationError(name: name, command: command, existing: store.snippets,
                                                         editing: draft.isNew ? nil : draft.snippet.id) {
            error = message
            return
        }
        var snippet = draft.snippet
        snippet.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.command = command
        snippet.brand = brand
        snippet.sendsReturn = sendsReturn
        store.save(snippet)
        dismiss()
    }
}

/// Demande d'envoi à plusieurs sessions (commande de départ et sessions cochées).
struct TerminalBroadcastRequest: Identifiable {
    let id = UUID()
    var command: String
    var sendsReturn: Bool
    var selected: Set<UUID>
}

/// Feuille « Envoyer à plusieurs sessions ».
struct TerminalBroadcastSheet: View {
    @ObservedObject var store: RemoteSessionStore
    /// Dessinée dans la page (captures) plutôt que dans une feuille.
    var inline = false
    let dismiss: () -> Void

    @ObservedObject private var snippetStore = TerminalSnippetStore.shared
    @State private var command: String
    @State private var sendsReturn: Bool
    @State private var selected: Set<UUID>
    /// Plan figé à l'ouverture de la confirmation : seules les sessions qu'elle nomme recevront la commande.
    @State private var confirmedPlan: TerminalBroadcast.Plan?
    @State private var refresh = 0

    init(store: RemoteSessionStore, request: TerminalBroadcastRequest, inline: Bool = false, dismiss: @escaping () -> Void) {
        self.store = store
        self.inline = inline
        self.dismiss = dismiss
        _command = State(initialValue: request.command)
        _sendsReturn = State(initialValue: request.sendsReturn)
        _selected = State(initialValue: request.selected)
    }

    /// Sessions de terminal ouvertes dans les onglets, en ordre alphabétique.
    private var sessions: [TerminalSession] {
        store.tabs.compactMap(\.session).sortedFrench(by: { $0.connection.name })
    }

    private var targets: [TerminalBroadcast.Target] {
        sessions.map { TerminalBroadcast.Target(id: $0.id, name: $0.connection.name, address: $0.addressLabel,
                                                site: $0.connection.folder, isConnected: $0.phase == .connected) }
    }

    private var plan: TerminalBroadcast.Plan {
        TerminalBroadcast.plan(command: command, sendsReturn: sendsReturn, targets: targets, selected: selected)
    }

    var body: some View {
        let _ = refresh
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack").foregroundStyle(Theme.accentStrong)
                    Text("Envoyer à plusieurs sessions").font(Theme.panelTitle)
                    Spacer()
                    snippetMenu
                }
                VStack(alignment: .leading, spacing: 4) {
                    ToolFieldLabel("Commande")
                    TextEditor(text: $command)
                        .font(Theme.mono(12))
                        .frame(height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
                    Toggle("Terminer par Entrée (la commande s’exécute aussitôt dans chaque session)", isOn: $sendsReturn)
                        .toggleStyle(.checkbox)
                        .font(Theme.small)
                }
                sessionList
                Text("Chaque session est choisie par son onglet, jamais par son adresse\u{00A0}: deux sites aux mêmes plages IP ne sont pas confondus.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: inline ? 580 : nil)
        .frame(minWidth: 540, idealWidth: 580)
        .background(Theme.panel)
        // Seul le passage d'une session à ouverte ou fermée compte ici (pas le texte reçu, le titre ou la
        // taille) ; dropFirst : la valeur actuelle, renvoyée à chaque abonnement, ne redessine rien.
        .onReceive(Publishers.MergeMany(sessions.map { $0.$phase.dropFirst().map { _ in () } }).receive(on: RunLoop.main)) { _ in
            refresh &+= 1
        }
        .alert(confirmedPlan.map(TerminalBroadcast.confirmationTitle) ?? "",
               isPresented: Binding(get: { confirmedPlan != nil }, set: { if !$0 { confirmedPlan = nil } }),
               presenting: confirmedPlan) { frozen in
            Button("Annuler", role: .cancel) {}
            Button("Envoyer") { send(frozen) }
        } message: { frozen in
            Text(TerminalBroadcast.confirmationMessage(frozen, command: command, sendsReturn: sendsReturn))
        }
    }

    /// Noms portés par plusieurs onglets : leur site (dossier) est affiché pour les distinguer.
    private var duplicateNames: Set<String> {
        var seen = Set<String>(), twice = Set<String>()
        for session in sessions {
            let key = session.connection.name.lowercased()
            if !seen.insert(key).inserted { twice.insert(key) }
        }
        return twice
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ToolFieldLabel("Sessions (\(plan.recipients.count) sur \(targets.filter(\.isConnected).count) ouvertes)")
                Spacer()
                Button("Tout cocher") { selected = Set(targets.filter(\.isConnected).map(\.id)) }
                    .buttonStyle(.link).font(Theme.small)
                Button("Tout décocher") { selected = [] }
                    .buttonStyle(.link).font(Theme.small)
            }
            VStack(spacing: 0) {
                if sessions.isEmpty {
                    Text("Aucune session de terminal ouverte.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                let twins = duplicateNames
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    row(session, showsSite: twins.contains(session.connection.name.lowercased()))
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        }
    }

    private func row(_ session: TerminalSession, showsSite: Bool) -> some View {
        let connected = session.phase == .connected
        let binding = Binding<Bool>(
            get: { selected.contains(session.id) },
            set: { if $0 { selected.insert(session.id) } else { selected.remove(session.id) } })
        return HStack(spacing: 8) {
            Toggle(isOn: binding) {
                Text(session.connection.name).font(Theme.bodyMedium).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(!connected)
            Text(session.addressLabel).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            if showsSite {
                Text(session.connection.folder.isEmpty ? "Non classé" : session.connection.folder)
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Chip(text: kindLabel(session), tone: session.kind == .telnet ? .warning : .neutral)
            Chip(text: connected ? "Ouverte" : "Fermée", tone: connected ? .success : .neutral)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func kindLabel(_ session: TerminalSession) -> String {
        switch session.kind {
        case .ssh: return "SSH"
        case .telnet: return "Telnet"
        case .serial: return "Série"
        }
    }

    /// Menu « Extraits » : ceux de l'utilisateur, puis ceux de chaque marque (ordre alphabétique).
    private var snippetMenu: some View {
        Menu {
            let mine = snippetStore.snippets.sortedFrench(by: \.name)
            if !mine.isEmpty {
                Section("Mes extraits") {
                    ForEach(mine) { snippet in
                        Button(snippet.name) {
                            command = snippet.command
                            sendsReturn = snippet.sendsReturn
                        }
                    }
                }
            }
            ForEach(TerminalSnippetBrand.ordered, id: \.self) { brand in
                Menu(brand.label) {
                    ForEach(brand.builtInCommands, id: \.self) { item in
                        Button(item) { command = item }
                    }
                }
            }
        } label: {
            Label("Extraits", systemImage: "text.append")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !plan.skipped.isEmpty {
                Text(plan.skipped.count > 1 ? "\(plan.skipped.count)\u{00A0}sessions cochées sont fermées\u{00A0}: elles seront ignorées."
                                            : "1\u{00A0}session cochée est fermée\u{00A0}: elle sera ignorée.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            // Retour passe à la ligne dans la commande : l'envoi se fait par ⌘Retour.
            Text("⌘↩ pour envoyer").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button(plan.recipients.count > 1 ? "Envoyer aux \(plan.recipients.count)\u{00A0}sessions…" : "Envoyer…") {
                let current = plan
                if current.canSend { confirmedPlan = current }
            }
                .buttonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!plan.canSend)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// N'envoie qu'aux sessions nommées dans la confirmation et encore ouvertes : une session cochée
    /// puis rouverte entre-temps ne reçoit rien.
    private func send(_ frozen: TerminalBroadcast.Plan) {
        guard frozen.canSend else { return }
        let ids = Set(frozen.recipients.map(\.id))
        for session in sessions where ids.contains(session.id) && session.phase == .connected {
            session.sendText(frozen.payload)
        }
        dismiss()
    }
}
