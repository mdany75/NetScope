import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 57 : onglets de session d'Accès distant. « Connecter » ouvre un onglet de terminal intégré
// pour SSH, Telnet et la console série (le menu de « Connecter » garde « Ouvrir dans Terminal ») ;
// RDP reste dans Windows App. VNC : un onglet de session VNC intégrée (VNCSessionView), dans la
// même barre que les terminaux ; Partage d'écran reste au menu de « Connecter ».
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
        /// Session VNC intégrée (une par connexion, gardée par `VNCSessionStore`).
        case vnc(VNCSession)
    }

    @MainActor
    struct Tab: Identifiable {
        let id: UUID
        let content: Content

        var connection: RemoteConnection {
            switch content {
            case .terminal(let session): return session.connection
            case .vnc(let session): return session.connection
            }
        }

        var session: TerminalSession? {
            if case .terminal(let session) = content { return session }
            return nil
        }

        var vncSession: VNCSession? {
            if case .vnc(let session) = content { return session }
            return nil
        }

        /// Session encore ouverte (terminal connecté, VNC connecté ou en cours de connexion).
        var isActive: Bool {
            switch content {
            case .terminal(let session): return session.isActive
            case .vnc(let session): return session.isActive
            }
        }
    }

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
        case .ssh, .telnet, .serie, .vnc: return true
        default: return false
        }
    }

    // MARK: Onglets

    /// Ouvre la connexion dans un onglet (ou revient à son onglet encore actif).
    /// VNC : un seul onglet par connexion ; la session est relancée si elle était fermée.
    @discardableResult
    func open(_ connection: RemoteConnection, newTab: Bool = false) -> Tab? {
        if connection.proto == .vnc {
            let session = VNCSessionStore.shared.open(connection)
            if let existing = tabs.first(where: { $0.vncSession === session }) {
                activeID = existing.id
                return existing
            }
            let tab = Tab(id: UUID(), content: .vnc(session))
            tabs.append(tab)
            activeID = tab.id
            return tab
        }
        if !newTab, let existing = tabs.first(where: { $0.connection.id == connection.id && $0.isActive }) {
            activeID = existing.id
            return existing
        }
        guard TerminalSession.Kind(connection.proto) != nil else { return nil }
        let session = TerminalSession(connection: connection)
        if isSandboxed { session.demoTransport = TerminalDemo.transportFactory(for: connection) }
        let tab = Tab(id: UUID(), content: .terminal(session))
        // « Connecter » est la demande de l'utilisateur : la liaison (ou le port série) s'ouvre
        // maintenant, jamais avant ; « Fermer le port » la referme sans fermer l'onglet.
        session.start()
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
    func requestClose(_ tab: Tab) {
        if tab.isActive {
            pendingClose = tab
        } else {
            close(tab.id)
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].session?.shutdown()
        if let vnc = tabs[index].vncSession { VNCSessionStore.shared.close(vnc.id) }
        tabs.remove(at: index)
        if pendingClose?.id == id { pendingClose = nil }
        if activeID == id {
            activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Connexion supprimée du carnet : ses onglets (terminal ou VNC, plein écran compris) sont
    /// fermés et ses mots de passe oubliés (SSH ou Telnet, et VNC).
    func forget(_ connectionID: UUID) {
        for tab in tabs where tab.connection.id == connectionID { close(tab.id) }
        VNCSessionStore.shared.close(connectionID)
        try? setPassword("", for: connectionID)
        try? VNCPasswordStore.setPassword(nil, for: connectionID)
    }

    /// Onglet de la connexion, s'il y en a un.
    func tab(for connectionID: UUID) -> Tab? {
        tabs.first { $0.connection.id == connectionID }
    }

    func select(_ id: UUID?) {
        activeID = id
    }

    var activeSessionCount: Int { tabs.filter(\.isActive).count }

    // MARK: Trousseau

    /// Lecture seule (appelée pendant le rendu) : `savedPasswords` est rempli au lancement et par
    /// `setPassword`, jamais ici, et le Trousseau n'est pas relu à chaque rendu.
    func hasPassword(_ id: UUID) -> Bool {
        savedPasswords.contains(id)
    }

    /// Relit au Trousseau quelles connexions ont un mot de passe (au lancement, hors du rendu).
    func loadSavedPasswords(for ids: [UUID]) {
        guard !isSandboxed else { return }
        let found = Set(ids.filter { Self.keychain.string(for: $0.uuidString) != nil })
        if found != savedPasswords { savedPasswords = found }
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
