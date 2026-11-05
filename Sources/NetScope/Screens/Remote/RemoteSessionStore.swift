import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 57 : onglets de session d'Accès distant. « Connecter » ouvre un onglet de terminal intégré
// pour SSH, Telnet et la console série (le menu de « Connecter » garde « Ouvrir dans Terminal ») ;
// RDP reste dans Windows App. VNC : un onglet intégré si la vue VNC est fournie
// (`RemoteSessionStore.vncView`), sinon Partage d'écran comme avant.
//
// Mots de passe SSH et Telnet : Trousseau macOS seulement (service com.danymenard.netscope.acces,
// un compte par connexion), jamais dans le carnet ni dans une sauvegarde en clair.

@MainActor
final class RemoteSessionStore: ObservableObject {
    static let shared = RemoteSessionStore()
    nonisolated static let keychainService = "com.danymenard.netscope.acces"
    nonisolated static let keychain = UpdKeychain(service: keychainService)

    /// Contenu d'un onglet.
    enum Content {
        case terminal(TerminalSession)
        /// Point d'accroche du client VNC intégré (vue autonome fournie par `vncView`).
        case vnc(RemoteConnection)
    }

    @MainActor
    struct Tab: Identifiable {
        let id: UUID
        let content: Content

        var connection: RemoteConnection {
            switch content {
            case .terminal(let session): return session.connection
            case .vnc(let connection): return connection
            }
        }

        var session: TerminalSession? {
            if case .terminal(let session) = content { return session }
            return nil
        }
    }

    /// Vue VNC intégrée : `RemoteSessionStore.vncView = { AnyView(VNCSessionView(connection: $0)) }`.
    /// Absente : VNC s'ouvre dans Partage d'écran.
    static var vncView: ((RemoteConnection) -> AnyView)?

    @Published private(set) var tabs: [Tab] = []
    /// Onglet affiché ; nil : l'accueil « Sessions » (aperçu et connexions récentes).
    @Published var activeID: UUID?
    /// Onglet dont la fermeture attend une confirmation (session active).
    @Published var pendingClose: Tab?
    @Published private(set) var savedPasswords: Set<UUID> = []

    private let isSandboxed = RegEnvironment.isSandboxed

    private init() {
        if isSandboxed {
            savedPasswords = Set(RemoteDemo.connections.filter { $0.proto == .ssh && $0.name.hasPrefix("FortiGate") }.map(\.id))
        }
        if RegEnvironment.isDemo { TerminalDemo.openDemoTabs(in: self) }
    }

    var activeTab: Tab? {
        guard let activeID else { return nil }
        return tabs.first { $0.id == activeID }
    }

    /// Protocoles ouverts dans un onglet par « Connecter ».
    static func opensInTab(_ proto: RemoteProtocol) -> Bool {
        switch proto {
        case .ssh, .telnet, .serie: return true
        case .vnc: return vncView != nil
        default: return false
        }
    }

    // MARK: Onglets

    /// Ouvre la connexion dans un onglet (ou revient à son onglet encore actif).
    @discardableResult
    func open(_ connection: RemoteConnection, newTab: Bool = false) -> Tab? {
        if !newTab, let existing = tabs.first(where: { $0.connection.id == connection.id && ($0.session?.isActive ?? true) }) {
            activeID = existing.id
            return existing
        }
        let tab: Tab
        if connection.proto == .vnc {
            guard Self.vncView != nil else { return nil }
            tab = Tab(id: UUID(), content: .vnc(connection))
        } else {
            guard TerminalSession.Kind(connection.proto) != nil else { return nil }
            let session = TerminalSession(connection: connection)
            if isSandboxed { session.demoTransport = TerminalDemo.transportFactory(for: connection) }
            tab = Tab(id: UUID(), content: .terminal(session))
            // Console série : le port n'est ouvert que par « Ouvrir le port » (réglages à vérifier d'abord).
            if session.kind != .serial { session.start() }
        }
        tabs.append(tab)
        activeID = tab.id
        return tab
    }

    /// Ajoute un onglet déjà préparé (démonstration).
    func add(_ session: TerminalSession, activate: Bool) {
        let tab = Tab(id: session.id, content: .terminal(session))
        tabs.append(tab)
        if activate { activeID = tab.id }
    }

    /// Fermeture demandée : confirmation si la session est encore active.
    /// Un onglet VNC (état inconnu de NetScope) est toujours confirmé.
    func requestClose(_ tab: Tab) {
        if tab.session.map(\.isActive) ?? true {
            pendingClose = tab
        } else {
            close(tab.id)
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].session?.shutdown()
        tabs.remove(at: index)
        if pendingClose?.id == id { pendingClose = nil }
        if activeID == id {
            activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Connexion supprimée du carnet : ses onglets sont fermés et son mot de passe oublié.
    func forget(_ connectionID: UUID) {
        for tab in tabs where tab.connection.id == connectionID { close(tab.id) }
        try? setPassword("", for: connectionID)
    }

    func select(_ id: UUID?) {
        activeID = id
    }

    var activeSessionCount: Int { tabs.filter { $0.session?.isActive == true }.count }

    // MARK: Trousseau

    func hasPassword(_ id: UUID) -> Bool {
        if savedPasswords.contains(id) { return true }
        guard !isSandboxed else { return false }
        if Self.keychain.string(for: id.uuidString) != nil {
            savedPasswords.insert(id)
            return true
        }
        return false
    }

    func password(for id: UUID) -> String? {
        guard !isSandboxed else { return nil }
        return Self.keychain.string(for: id.uuidString)
    }

    /// Enregistre (ou efface, si vide) le mot de passe de la connexion.
    func setPassword(_ value: String, for id: UUID) throws {
        if value.isEmpty { savedPasswords.remove(id) } else { savedPasswords.insert(id) }
        guard !isSandboxed else { return }
        try Self.keychain.set(value.isEmpty ? nil : value, for: id.uuidString)
    }
}
