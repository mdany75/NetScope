import Foundation
import NetScopeCore
import SwiftUI

// État des tests d'identifiants (Réglages › Identifiants) : test SNMP v2c/v3 vers une adresse
// choisie, identifiants SSH et WMI (liste en JSON, secrets au Trousseau seulement).

/// Résultat affiché d'un test.
struct RegTestResult: Equatable {
    enum Status: Equatable { case running, success, partial, failure }
    var status: Status
    var text: String
    var date = Date()

    var tone: Tone {
        switch status {
        case .running: return .accent
        case .success: return .success
        case .partial: return .warning
        case .failure: return .critical
        }
    }

    static let running = RegTestResult(status: .running, text: "Test en cours…")
}

/// Tests SNMP des identifiants enregistrés (v2c et v3).
@MainActor
final class RegSNMPTester: ObservableObject {
    static let shared = RegSNMPTester()
    private static let hostKey = "reglages.identifiants.adresseTest"

    @Published var host: String { didSet { if !RegEnvironment.isSandboxed { UserDefaults.standard.set(host, forKey: Self.hostKey) } } }
    @Published private(set) var v2: RegTestResult?
    @Published private(set) var v3: RegTestResult?

    private init() {
        if RegEnvironment.isDemo {
            host = "10.182.122.2"
            v2 = RegTestResult(status: .success, text: ReglagesDemo.snmpV2Result.displayText, date: ReglagesDemo.reference)
            v3 = RegTestResult(status: .success, text: ReglagesDemo.snmpV3Result.displayText, date: ReglagesDemo.reference)
        } else {
            host = RegEnvironment.isSandboxed ? "" : (UserDefaults.standard.string(forKey: Self.hostKey) ?? "")
        }
    }

    var hostAddress: IPv4Address? { IPv4Address(host.trimmingCharacters(in: .whitespaces)) }

    /// Adresse proposée : premier switch connu, sinon la passerelle.
    func suggest(_ state: AppState) {
        guard host.isEmpty else { return }
        if let first = SwitchStore.shared.hosts.first {
            host = first
        } else if let gateway = state.activeInterface?.gateway {
            host = gateway.description
        }
    }

    func testV2(community: String) {
        guard let ip = hostAddress else { v2 = RegTestResult(status: .failure, text: "Saisissez une adresse IPv4 à tester."); return }
        guard !community.isEmpty else { v2 = RegTestResult(status: .failure, text: "Aucune communauté v2c enregistrée ni saisie."); return }
        guard !RegEnvironment.isDemo else { v2 = RegTestResult(status: .success, text: ReglagesDemo.snmpV2Result.displayText); return }
        v2 = .running
        Task {
            let outcome = await SNMPCredentialTest.run(host: ip, community: community)
            v2 = RegTestResult(status: outcome.success == nil ? .failure : .success, text: outcome.displayText)
        }
    }

    func testV3(_ credentials: SNMPv3Credentials) {
        guard let ip = hostAddress else { v3 = RegTestResult(status: .failure, text: "Saisissez une adresse IPv4 à tester."); return }
        guard !RegEnvironment.isDemo else { v3 = RegTestResult(status: .success, text: ReglagesDemo.snmpV3Result.displayText); return }
        v3 = .running
        Task {
            let outcome = await SNMPCredentialTest.run(host: ip, credentials: credentials)
            v3 = RegTestResult(status: outcome.success == nil ? .failure : .success, text: outcome.displayText)
        }
    }
}

extension RegSNMPCredentials {
    /// Identifiant v3 pour le moteur (protocoles lus d'après les libellés des Réglages).
    var v3Credentials: SNMPv3Credentials {
        SNMPv3Credentials(user: v3User, level: SNMPv3Level(rawValue: v3Level.rawValue) ?? .authPriv,
                          auth: SNMPAuthProtocol(label: v3AuthProtocol) ?? .sha256, authPassword: v3AuthPassword,
                          priv: SNMPPrivProtocol(label: v3PrivProtocol) ?? .aes128, privPassword: v3PrivPassword, context: v3Context)
    }
}

/// Identifiants SSH et WMI : liste dans ~/Library/Application Support/NetScope/identifiants.json
/// (sans secret), mots de passe et phrases secrètes au Trousseau (un compte par identifiant).
@MainActor
final class RegRemoteCredentialStore: ObservableObject {
    static let shared = RegRemoteCredentialStore()

    @Published private(set) var credentials: [RemoteCredential] = []
    /// Identifiants dont le secret est enregistré au Trousseau.
    @Published private(set) var secretsSet: Set<UUID> = []
    @Published private(set) var running: Set<UUID> = []
    @Published var message: (text: String, tone: Tone)?

    private let url: URL?

    static var fileURL: URL { RegBackupController.dataDirectory.appendingPathComponent("identifiants.json") }
    /// Empreintes SSH acceptées par les tests de NetScope (jamais ~/.ssh/known_hosts).
    static var knownHostsURL: URL { RegBackupController.dataDirectory.appendingPathComponent("ssh_known_hosts") }

    private init() {
        if RegEnvironment.isDemo {
            url = nil
            credentials = ReglagesDemo.remoteCredentials()
            secretsSet = Set(credentials.filter { $0.kind == .wmi || $0.name == "ssh-netadmin" }.map(\.id))
        } else if RegEnvironment.isSandboxed {
            url = nil
        } else {
            url = Self.fileURL
            credentials = RemoteCredentialStore.load(from: Self.fileURL).credentials
            secretsSet = Set(credentials.filter { Self.keychain($0.kind).string(for: $0.keychainAccount) != nil }.map(\.id))
        }
    }

    static func keychain(_ kind: RemoteCredential.Kind) -> UpdKeychain { UpdKeychain(service: RemoteCredential.keychainService(kind)) }

    private func persist() {
        guard let url else { return }
        do {
            try RemoteCredentialStore(credentials: credentials).save(to: url)
        } catch {
            message = ("Enregistrement impossible\u{00A0}: \(error.localizedDescription)", .critical)
        }
    }

    @discardableResult
    func add(_ kind: RemoteCredential.Kind) -> RemoteCredential {
        let base = kind == .ssh ? "ssh" : "wmi"
        var name = "\(base)-nouveau"
        var counter = 2
        while credentials.contains(where: { $0.name == name }) { name = "\(base)-nouveau-\(counter)"; counter += 1 }
        let credential = RemoteCredential(kind: kind, name: name, sshMethod: .key,
                                          keyPath: kind == .ssh ? Self.defaultKeyPath() : "")
        credentials.append(credential)
        persist()
        return credential
    }

    func update(_ credential: RemoteCredential) {
        guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else { return }
        credentials[index] = credential
        persist()
    }

    func remove(_ id: UUID) {
        guard let credential = credentials.first(where: { $0.id == id }) else { return }
        if !RegEnvironment.isSandboxed { try? Self.keychain(credential.kind).delete(credential.keychainAccount) }
        credentials.removeAll { $0.id == id }
        secretsSet.remove(id)
        persist()
    }

    /// Enregistre le secret au Trousseau (vide : efface).
    func setSecret(_ secret: String, for credential: RemoteCredential) {
        guard !RegEnvironment.isSandboxed else {
            secretsSet.insert(credential.id)
            return
        }
        do {
            try Self.keychain(credential.kind).set(secret.isEmpty ? nil : secret, for: credential.keychainAccount)
            if secret.isEmpty { secretsSet.remove(credential.id) } else { secretsSet.insert(credential.id) }
            message = (secret.isEmpty ? "Secret effacé du Trousseau." : "Secret enregistré dans le Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }

    /// Première clé privée courante de ~/.ssh (id_ed25519, id_ecdsa, id_rsa).
    static func defaultKeyPath() -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        for name in ["id_ed25519", "id_ecdsa", "id_rsa"] where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            return "~/.ssh/\(name)"
        }
        return "~/.ssh/id_ed25519"
    }

    func test(_ id: UUID, host: String) {
        guard var credential = credentials.first(where: { $0.id == id }) else { return }
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            message = ("Saisissez l’adresse à tester.", .warning)
            return
        }
        credential.lastHost = target
        update(credential)
        guard !RegEnvironment.isSandboxed else {
            message = ("Démonstration\u{00A0}: aucun test réel n’est lancé.", .neutral)
            return
        }
        running.insert(id)
        let secret = Self.keychain(credential.kind).string(for: credential.keychainAccount)
        Task {
            let outcome: CredentialTestOutcome
            switch credential.kind {
            case .ssh:
                outcome = await SSHCredentialTest.run(host: target, credential: credential, secret: secret, knownHosts: Self.knownHostsURL)
            case .wmi:
                if let ip = IPv4Address(target) {
                    outcome = await WMIReachabilityTest.run(host: ip)
                } else {
                    outcome = CredentialTestOutcome(status: .failure, message: "Échec · saisissez une adresse IPv4 (le test WMI vérifie les ports 135, 5985 et 5986).")
                }
            }
            running.remove(id)
            guard var latest = credentials.first(where: { $0.id == id }) else { return }
            latest.lastTestAt = Date()
            latest.lastTestStatus = outcome.status
            latest.lastTestMessage = outcome.message
            update(latest)
        }
    }
}
