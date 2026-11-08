import Foundation

// Note 111 : CLI de la FortiGate par SSH, en complément de l'API. Deux commandes de lecture, jamais
// d'autres : elles tranchent quand l'API laisse un doute sur l'appareil qui a une adresse. Les
// formats viennent de FortiOS tel que documenté ; l'analyse garde seulement les lignes reconnues.

/// Bail DHCP lu par « execute dhcp lease-list ».
public struct FortiCLILease: Hashable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress

    public init(ip: IPv4Address, mac: MACAddress) {
        self.ip = ip
        self.mac = mac
    }
}

/// Entrée ARP lue par « diagnose ip arp list ».
public struct FortiCLIARPEntry: Hashable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress
    /// Voisin joignable d'après le noyau (état REACHABLE ou PERMANENT).
    public var isReachable: Bool

    public init(ip: IPv4Address, mac: MACAddress, isReachable: Bool) {
        self.ip = ip
        self.mac = mac
        self.isReachable = isReachable
    }
}

/// Ce que les deux commandes ont rendu.
public struct FortiCLISnapshot: Equatable, Sendable {
    public var leases: [FortiCLILease]
    public var arp: [FortiCLIARPEntry]
    /// Une seule des deux commandes a répondu : le refus de l'autre.
    public var partialError: ConfigBackupError?

    public init(leases: [FortiCLILease] = [], arp: [FortiCLIARPEntry] = [], partialError: ConfigBackupError? = nil) {
        self.leases = leases
        self.arp = arp
        self.partialError = partialError
    }

    /// IP joignable d'une MAC, s'il y en a.
    func reachableIPs(of mac: MACAddress) -> [IPv4Address] { arp.filter { $0.mac == mac && $0.isReachable }.map(\.ip) }

    /// IP actuelle d'une MAC : bail joignable, IP joignable, IP cherchée, puis un bail s'il est unique.
    /// Plusieurs baux sans preuve : nil, l'API répondra plutôt qu'un choix au hasard.
    public func currentIP(of mac: MACAddress, preferring wanted: IPv4Address?) -> IPv4Address? {
        let leased = leases.filter { $0.mac == mac }.map(\.ip)
        let reachable = reachableIPs(of: mac)
        return leased.first { reachable.contains($0) } ?? reachable.first ?? leased.first { $0 == wanted } ?? (leased.count == 1 ? leased[0] : nil)
    }

    /// Appareil qui a cette IP : celui qui répond (ARP joignable), sinon le bail. Un bail peut survivre
    /// à un appareil parti ; une entrée joignable dit qui utilise l'adresse maintenant.
    public func holder(of ip: IPv4Address) -> MACAddress? {
        arp.first { $0.ip == ip && $0.isReachable }?.mac ?? leases.first { $0.ip == ip }?.mac
    }
}

public enum FortiCLI {
    public static let leaseList = "execute dhcp lease-list"
    public static let arpList = "diagnose ip arp list"
    /// Seules commandes que NetScope envoie par la CLI.
    public static let commands = [leaseList, arpList]

    public static func isAllowed(_ command: String) -> Bool { commands.contains(command) }

    /// Nom de VDOM sûr à écrire dans une commande ; vide : aucun contexte à ouvrir.
    public static func isValidVDOM(_ vdom: String) -> Bool {
        !vdom.isEmpty && vdom.count <= 31 && vdom.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
    }

    /// Textes à essayer dans l'ordre : la commande, préfixée par « sudo <vdom> » au besoin. Jamais
    /// « config vdom / edit » : sur FortiOS, cette suite crée le VDOM s'il n'existe pas.
    /// Le champ VDOM sert à l'API : selon le mode de la FortiGate, « root » peut y être refusé par la
    /// CLI, ou y être nécessaire alors que le champ est vide. Vide si la commande est refusée.
    public static func remoteCommands(_ command: String, vdom: String) -> [String] {
        guard isAllowed(command) else { return [] }
        let clean = vdom.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { return [command, "sudo root \(command)"] }
        guard isValidVDOM(clean) else { return [] }
        return clean == "root" ? ["sudo root \(command)", command] : ["sudo \(clean) \(command)"]
    }

    /// Réunit les deux commandes : une seule qui répond suffit, l'autre refus est gardé à part.
    public static func merge(leases: Result<String, ConfigBackupError>, arp: Result<String, ConfigBackupError>) -> Result<FortiCLISnapshot, ConfigBackupError> {
        switch (leases, arp) {
        case (.failure(let error), .failure): return .failure(error)
        case (.success(let text), .failure(let error)): return .success(FortiCLISnapshot(leases: parseLeases(text), partialError: error))
        case (.failure(let error), .success(let text)): return .success(FortiCLISnapshot(arp: parseARP(text), partialError: error))
        case (.success(let first), .success(let second)): return .success(FortiCLISnapshot(leases: parseLeases(first), arp: parseARP(second)))
        }
    }

    private static func tokens(_ line: Substring) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func usable(_ mac: MACAddress) -> Bool {
        mac.formatted(.upperColon) != "00:00:00:00:00:00"
    }

    /// Lignes « IP  MAC  nom… » ; les en-têtes et les noms d'interface sont ignorés.
    public static func parseLeases(_ text: String) -> [FortiCLILease] {
        var seen = Set<FortiCLILease>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = tokens(line)
            guard parts.count >= 2, let ip = IPv4Address(parts[0]), parts[1].contains(":"), let mac = MACAddress(parts[1]), usable(mac) else { return nil }
            let lease = FortiCLILease(ip: ip, mac: mac)
            return seen.insert(lease).inserted ? lease : nil
        }
    }

    /// Lignes « index=5 ifname=lan 10.0.0.1 00:09:0f:… state=00000002 … » ; MAC absente ou état en échec ignorés.
    public static func parseARP(_ text: String) -> [FortiCLIARPEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = tokens(line)
            guard parts.contains(where: { $0.hasPrefix("ifname=") }),
                  let ip = parts.lazy.compactMap({ IPv4Address($0) }).first,
                  let mac = parts.lazy.filter({ $0.contains(":") && !$0.contains("=") }).compactMap({ MACAddress($0) }).first,
                  usable(mac) else { return nil }
            let state = parts.first { $0.hasPrefix("state=") }.flatMap { UInt32($0.dropFirst(6), radix: 16) } ?? 0
            if state & 0x21 != 0 { return nil }                 // NUD_INCOMPLETE, NUD_FAILED
            return FortiCLIARPEntry(ip: ip, mac: mac, isReachable: state & 0x82 != 0)
        }
    }
}

/// Lancement par /usr/bin/ssh, avec les options et le mot de passe protégé des sauvegardes.
public enum FortiCLISSH {
    public static let timeout: TimeInterval = 20

    public static func arguments(_ target: ConfigSSHTarget, remoteCommand: String) -> [String] {
        // .cisco : la seule sorte qui n'ajoute aucune commande ; on ajoute ici la commande autorisée.
        ConfigBackupSSH.arguments(target, kind: .cisco) + [remoteCommand]
    }

    /// Lit les deux listes. Une liste vide n'est pas une erreur ; si la connexion échoue, la seconde
    /// commande n'est pas tentée (aucun essai de mot de passe de plus).
    public static func read(_ target: ConfigSSHTarget, vdom: String, secret: String?) async -> Result<FortiCLISnapshot, ConfigBackupError> {
        let leases = await runFirstAccepted(FortiCLI.leaseList, target: target, vdom: vdom, secret: secret)
        if case .failure(let error) = leases, error.kind != .commandRejected { return .failure(error) }
        let arp = await runFirstAccepted(FortiCLI.arpList, target: target, vdom: vdom, secret: secret)
        return FortiCLI.merge(leases: leases, arp: arp)
    }

    private static func runFirstAccepted(_ command: String, target: ConfigSSHTarget, vdom: String, secret: String?) async -> Result<String, ConfigBackupError> {
        let candidates = FortiCLI.remoteCommands(command, vdom: vdom)
        guard !candidates.isEmpty else {
            return .failure(ConfigBackupError(kind: .notReadOnly, detail: "Commande ou VDOM refusé\u{00A0}: rien n’a été envoyé."))
        }
        var last: Result<String, ConfigBackupError> = .failure(ConfigBackupError(kind: .commandRejected, detail: command))
        for remote in candidates {
            last = await run(remote, target: target, secret: secret)
            guard case .failure(let error) = last, error.kind == .commandRejected else { return last }
        }
        return last
    }

    private static func run(_ remote: String, target: ConfigSSHTarget, secret: String?) async -> Result<String, ConfigBackupError> {
        guard target.isValid else {
            return .failure(ConfigBackupError(kind: .account, detail: "Utilisateur ou adresse SSH invalide."))
        }
        guard FileManager.default.isExecutableFile(atPath: ConfigBackupSSH.executable) else {
            return .failure(ConfigBackupError(kind: .launch, detail: "/usr/bin/ssh introuvable sur ce Mac."))
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nsfcli-" + UUID().uuidString.prefix(8), isDirectory: true)
        let askpass: URL
        let channel: SSHSecretChannel?
        do {
            askpass = try RustDeskServerSSH.writeAskpass(in: folder)
            channel = try secret.flatMap { $0.isEmpty ? nil : try SSHSecretChannel(directory: folder, secret: $0) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .failure(ConfigBackupError(kind: .launch, detail: "Préparation impossible\u{00A0}: \(error.localizedDescription)"))
        }
        defer {
            channel?.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
        let env = RustDeskServerSSH.environment(askpass: askpass, secretPipe: channel?.path,
                                                expect: SSHTerminalCommand.expectedPrompt(user: target.user, host: target.host),
                                                flag: folder.appendingPathComponent("drapeau").path)
        let result = await ProcessRunner.run(ConfigBackupSSH.executable, arguments(target, remoteCommand: remote), environment: env,
                                             timeout: timeout, input: nil, outputLimit: 4_000_000)
        return interpret(status: result.status, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut, host: target.host)
    }

    /// Erreurs de connexion comme les sauvegardes ; une sortie vide reste une réponse valable.
    public static func interpret(status: Int32, stdout: String, stderr: String, timedOut: Bool, host: String) -> Result<String, ConfigBackupError> {
        if status == 255 || (stdout.isEmpty && !stderr.isEmpty && !timedOut) {
            if case .failure(let error) = ConfigBackupSSH.interpret(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut, host: host, kind: .cisco) {
                return .failure(error)
            }
        }
        // Sortie coupée par le délai : une liste partielle ne doit pas passer pour complète.
        if timedOut { return .failure(ConfigBackupError(kind: .timeout, detail: "Aucune réponse complète de \(host) dans le délai.")) }
        if let line = stdout.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().contains("command fail") || $0.lowercased().contains("unknown action") }) {
            return .failure(ConfigBackupError(kind: .commandRejected, detail: String(line.prefix(200))))
        }
        return .success(stdout)
    }
}
