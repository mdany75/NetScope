import Foundation

// Note 89 : historique des tests de câble d'un site et envoi par SSH.
//
//   ~/Library/Application Support/NetScope/sites/<clé du site>/tests-cable.json
//
// Aucun secret : switch, port, date et état des paires. Fichier illisible : ignoré.

/// Historique des tests de câble d'un site (les plus récents d'abord).
public struct CableTestHistory: Codable, Equatable, Sendable {
    public static let fileName = "tests-cable.json"
    public static let perPort = 10
    public static let total = 1_000

    public var version: Int
    public var results: [CableTestResult]

    public init(results: [CableTestResult] = []) {
        self.version = 1
        self.results = results
    }

    static func key(_ switchName: String, _ port: String) -> String {
        switchName.lowercased() + "|" + port.lowercased()
    }

    /// Ajoute un résultat (10 au plus par port, 1 000 au total).
    public mutating func add(_ result: CableTestResult) {
        results.insert(result, at: 0)
        results.sort { $0.date > $1.date }
        var counts: [String: Int] = [:]
        results = results.filter { item in
            let k = Self.key(item.switchName, item.portName)
            counts[k, default: 0] += 1
            return counts[k]! <= Self.perPort
        }
        if results.count > Self.total { results = Array(results.prefix(Self.total)) }
    }

    /// Tests d'un port, les plus récents d'abord.
    public func results(switchName: String, port: String) -> [CableTestResult] {
        let k = Self.key(switchName, port)
        return results.filter { Self.key($0.switchName, $0.portName) == k }
    }

    /// Dernier test d'un port dans les `maxAge` secondes (bilan de raccordement).
    public func latest(switchName: String, port: String, since date: Date) -> CableTestResult? {
        results(switchName: switchName, port: port).first { $0.date >= date }
    }

    public static func url(in files: SiteFiles, siteKey: String) -> URL {
        files.folder(for: siteKey).appendingPathComponent(fileName)
    }

    public static func load(from url: URL) -> CableTestHistory {
        guard let data = try? Data(contentsOf: url) else { return CableTestHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let history = try? decoder.decode(CableTestHistory.self, from: data), history.version <= 1 else { return CableTestHistory() }
        return history
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Envoi du test par SSH (/usr/bin/ssh, mot de passe remis par SSH_ASKPASS comme les sauvegardes).
public enum CableTestSSH {
    public static let stepTimeout: TimeInterval = 60

    /// Exécute le plan et rend la sortie de la dernière étape. `sleep` : attente entre deux étapes.
    public static func run(_ target: ConfigSSHTarget, vendor: CableTestVendor, port: String, secret: String?,
                           sleep: @Sendable (Int) async -> Void) async -> Result<String, ConfigBackupError> {
        guard let plan = CableTestCommands.plan(vendor: vendor, port: port), CableTestCommands.isAllowed(plan) else {
            return .failure(ConfigBackupError(kind: .notReadOnly, detail: "Port «\u{00A0}\(port)\u{00A0}» refusé\u{00A0}: aucune commande envoyée."))
        }
        guard target.isValid else {
            return .failure(ConfigBackupError(kind: .account, detail: "Utilisateur ou adresse SSH invalide."))
        }
        guard FileManager.default.isExecutableFile(atPath: ConfigBackupSSH.executable) else {
            return .failure(ConfigBackupError(kind: .launch, detail: "/usr/bin/ssh introuvable sur ce Mac."))
        }
        var last = ""
        for (index, step) in plan.steps.enumerated() {
            if index > 0 { await sleep(plan.waitSeconds) }
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nstdr-" + UUID().uuidString.prefix(8), isDirectory: true)
            let askpass: URL
            let channel: SSHSecretChannel?
            do {
                askpass = try RustDeskServerSSH.writeAskpass(in: folder)
                channel = try secret.flatMap { $0.isEmpty ? nil : try SSHSecretChannel(directory: folder, secret: $0) }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return .failure(ConfigBackupError(kind: .launch, detail: "Préparation impossible\u{00A0}: \(error.localizedDescription)"))
            }
            let env = RustDeskServerSSH.environment(askpass: askpass, secretPipe: channel?.path,
                                                    expect: SSHTerminalCommand.expectedPrompt(user: target.user, host: target.host),
                                                    flag: folder.appendingPathComponent("drapeau").path)
            // Arguments des sauvegardes de Cisco : aucune commande en argument, tout passe par l'entrée.
            let result = await ProcessRunner.run(ConfigBackupSSH.executable, ConfigBackupSSH.arguments(target, kind: .cisco),
                                                 environment: env, timeout: stepTimeout,
                                                 input: Data(step.map { $0 + "\n" }.joined().utf8), outputLimit: 1_000_000)
            channel?.cancel()
            try? FileManager.default.removeItem(at: folder)
            if result.status == 255 || (result.stdout.isEmpty && !result.stderr.isEmpty) {
                if case .failure(let error) = ConfigBackupSSH.interpret(status: result.status, stdout: result.stdout, stderr: result.stderr,
                                                                       timedOut: result.timedOut, host: target.host, kind: .cisco) {
                    return .failure(error)
                }
            }
            if result.timedOut, result.stdout.isEmpty {
                return .failure(ConfigBackupError(kind: .timeout, detail: "Aucune réponse de \(target.host) dans le délai."))
            }
            last = result.stdout
        }
        return .success(last)
    }
}
