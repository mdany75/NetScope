import AppKit
import Foundation
import NetScopeCore
import SwiftUI

// Note 72 : partages SMB d'un hôte (fiche Appareil, menu du Scanner « Partages SMB… »).
// `smbutil view` n'est lancé que sur un clic : invité, puis anonyme ; ou avec un utilisateur saisi.
// Le mot de passe va au Trousseau (service com.danymenard.netscope.smb) si l'utilisateur le
// demande, et à smbutil par son pseudo-terminal : jamais dans la ligne de commande, un fichier
// ou le journal. En démonstration et pendant les captures, smbutil n'est jamais lancé
// (SMBSharesDemo).

/// Hôte visé par la feuille « Partages SMB ».
struct SMBSharesTarget: Identifiable, Equatable {
    let id = UUID()
    var host: String
    var name: String

    @MainActor
    init(device: Device) {
        host = device.ip.description
        name = device.displayName
    }

    init(host: String, name: String) {
        self.host = host
        self.name = name
    }
}

/// État de la lecture des partages d'un hôte.
struct SMBHostState: Equatable {
    var listing: SMBShareListing?
    var error: SMBShareError?
    var isRunning = false
    /// Utilisateur de la lecture en cours ou de la dernière (« BUREAU\marc »), vide en invité.
    var user = ""
}

/// Utilisateur retenu pour un hôte (sans secret) ; le mot de passe est au Trousseau.
struct SMBRememberedLogin: Codable, Equatable {
    var user: String
    var passwordSaved: Bool
}

@MainActor
final class SMBSharesModel: ObservableObject {
    static let shared = SMBSharesModel()

    static let keychain = UpdKeychain(service: BackupKeychainScan.servicePrefix + ".smb")
    private static let memoKey = "smb.utilisateurs"
    private static let hiddenKey = "smb.afficherCaches"

    @Published private(set) var hosts: [String: SMBHostState] = [:]
    /// Feuille ouverte (menu du Scanner).
    @Published var target: SMBSharesTarget?
    /// « Partages cachés ($) » affichés.
    @Published var showHidden: Bool {
        didSet { if !RegEnvironment.isSandboxed { UserDefaults.standard.set(showHidden, forKey: Self.hiddenKey) } }
    }
    @Published private(set) var memo: [String: SMBRememberedLogin] = [:]
    /// Dernière action (« Chemin copié »), effacée après quelques secondes.
    @Published private(set) var toast: String?

    private var tasks: [String: Task<Void, Never>] = [:]
    private var toastTask: Task<Void, Never>?

    private init() {
        if RegEnvironment.isSandboxed {
            showHidden = SMBSharesDemo.showHidden
            hosts = SMBSharesDemo.initialStates()
            memo = SMBSharesDemo.memo
        } else {
            showHidden = UserDefaults.standard.bool(forKey: Self.hiddenKey)
            if let data = UserDefaults.standard.data(forKey: Self.memoKey),
               let saved = try? JSONDecoder().decode([String: SMBRememberedLogin].self, from: data) {
                memo = saved
            }
        }
    }

    func state(for host: String) -> SMBHostState { hosts[host] ?? SMBHostState() }

    /// Menu du Scanner : feuille des partages de cet appareil.
    func ask(_ device: Device) { target = SMBSharesTarget(device: device) }

    /// Lit les partages. `login` nil : invité puis anonyme. Mot de passe vide avec un mot de passe
    /// retenu : celui du Trousseau.
    func list(host: String, login: SMBLogin? = nil, password: String = "", remember: Bool = false) {
        guard !state(for: host).isRunning else { return }
        var current = state(for: host)
        current.isRunning = true
        current.error = nil
        current.user = login?.display ?? ""
        hosts[host] = current

        let saved = login.flatMap { memo[host]?.user == $0.display && memo[host]?.passwordSaved == true ? $0 : nil }
        tasks[host] = Task { [weak self] in
            var secret = password
            if let saved, secret.isEmpty {
                secret = Self.keychain.string(for: Self.account(host: host, user: saved.display)) ?? ""
            }
            let result: Result<SMBShareListing, SMBShareError>
            if RegEnvironment.isSandboxed {
                // Démonstration et captures : aucune commande, aucun trafic.
                try? await Task.sleep(nanoseconds: 700_000_000)
                result = SMBSharesDemo.result(host: host, login: login)
            } else {
                do {
                    result = .success(try await SMBShareLister().list(host: host, login: login, password: login == nil ? nil : secret))
                } catch let error as SMBShareError {
                    result = .failure(error)
                } catch {
                    result = .failure(.other(error.localizedDescription))
                }
            }
            guard !Task.isCancelled else { return }
            self?.finish(host: host, login: login, password: secret, remember: remember, result: result)
        }
    }

    func cancel(host: String) {
        tasks[host]?.cancel()
        tasks[host] = nil
        var current = state(for: host)
        current.isRunning = false
        hosts[host] = current
    }

    private func finish(host: String, login: SMBLogin?, password: String, remember: Bool,
                        result: Result<SMBShareListing, SMBShareError>) {
        tasks[host] = nil
        var current = state(for: host)
        current.isRunning = false
        switch result {
        case .success(let listing):
            current.listing = listing
            current.error = nil
            AppLog.shared.info("Partages SMB", "\(host)\u{00A0}: \(listing.summary) (accès\u{00A0}: \(listing.access.label))")
            if let login { rememberLogin(login, host: host, password: password, savePassword: remember) }
        case .failure(let error):
            current.error = error
            // Le journal ne reçoit que le titre et le message : jamais la commande avec un mot de passe (il n'y en a pas).
            AppLog.shared.warning("Partages SMB", "\(host)\u{00A0}: \(error.title) — \(error.errorDescription ?? "")")
        }
        hosts[host] = current
    }

    // MARK: Utilisateurs retenus

    static func account(host: String, user: String) -> String { "\(user)@\(host)" }

    private func rememberLogin(_ login: SMBLogin, host: String, password: String, savePassword: Bool) {
        guard !RegEnvironment.isSandboxed else { return }
        let previous = memo[host]
        var saved = previous?.passwordSaved == true && previous?.user == login.display
        if savePassword, !password.isEmpty {
            do {
                try Self.keychain.set(password, for: Self.account(host: host, user: login.display))
                saved = true
            } catch {
                AppLog.shared.error("Partages SMB", "Mot de passe non enregistré au Trousseau\u{00A0}: \(error.localizedDescription)")
            }
        }
        if let previous, previous.passwordSaved, previous.user != login.display {
            try? Self.keychain.delete(Self.account(host: host, user: previous.user))
        }
        memo[host] = SMBRememberedLogin(user: login.display, passwordSaved: saved)
        persistMemo()
    }

    /// « Oublier » : utilisateur et mot de passe de cet hôte retirés (Trousseau compris).
    func forgetLogin(host: String) {
        if let previous = memo[host], previous.passwordSaved, !RegEnvironment.isSandboxed {
            try? Self.keychain.delete(Self.account(host: host, user: previous.user))
        }
        memo[host] = nil
        persistMemo()
    }

    private func persistMemo() {
        guard !RegEnvironment.isSandboxed, let data = try? JSONEncoder().encode(memo) else { return }
        UserDefaults.standard.set(data, forKey: Self.memoKey)
    }

    // MARK: Actions sur un partage

    func openInFinder(host: String, share: SMBShare) {
        guard share.opensInFinder, let url = SMBPaths.url(host: host, share: share.name) else { return }
        if RegEnvironment.isSandboxed {
            show("Démonstration\u{00A0}: \(SMBPaths.readable(host: host, share: share.name)) non ouvert")
            return
        }
        // Le Finder monte le partage et demande lui-même l'identifiant (Trousseau de macOS).
        NSWorkspace.shared.open(url)
        show("Ouverture de \(SMBPaths.readable(host: host, share: share.name)) dans le Finder")
    }

    func copyPath(host: String, share: SMBShare, windows: Bool = false) {
        let text = windows ? SMBPaths.unc(host: host, share: share.name) : SMBPaths.readable(host: host, share: share.name)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Chemin copié\u{00A0}: \(text)")
    }

    func copyList(host: String, shares: [SMBShare]) {
        let lines = ["nom;type;commentaire;chemin"] + shares.map {
            "\($0.name);\($0.kind.label);\($0.comment.replacingOccurrences(of: ";", with: ","));\(SMBPaths.readable(host: host, share: $0.name))"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        show("Liste des partages copiée (CSV)")
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
