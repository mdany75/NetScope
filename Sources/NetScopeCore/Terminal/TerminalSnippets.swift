import Foundation

// Note 67 (0.34.0) : extraits de commandes du terminal intégré (ceux de chaque marque, livrés
// dans la 0.22.0, et ceux que l'utilisateur enregistre) et envoi d'une même commande à plusieurs
// sessions ouvertes. Moteur pur : rien n'est envoyé ici, l'application tape le texte calculé dans
// les sessions choisies, après confirmation.

/// Famille d'appareils reconnue d'après le nom et la description d'une connexion.
public enum TerminalSnippetBrand: String, Codable, CaseIterable, Sendable {
    case aruba, cisco, fortinet, linux

    public var label: String {
        switch self {
        case .aruba: return "Aruba et HPE"
        case .cisco: return "Cisco"
        case .fortinet: return "FortiGate"
        case .linux: return "Linux (SSH)"
        }
    }

    /// Marques en ordre alphabétique (sélecteurs).
    public static var ordered: [TerminalSnippetBrand] { allCases.sortedFrench(by: \.label) }

    /// Marque d'une connexion : mots de sa description et de son nom ; un SSH sans marque connue
    /// est traité comme Linux. Telnet et console série sans marque : aucune.
    public static func detect(description: String, isSSH: Bool) -> TerminalSnippetBrand? {
        let text = description.lowercased()
        if text.contains("cisco") { return .cisco }
        if text.contains("forti") { return .fortinet }
        if text.contains("aruba") || text.contains("hpe") { return .aruba }
        return isSSH ? .linux : nil
    }

    /// Commandes courantes de la marque (livrées dans la 0.22.0), en ordre alphabétique.
    public var builtInCommands: [String] {
        let commands: [String]
        switch self {
        case .cisco:
            commands = ["show interfaces status", "show vlan brief", "show mac address-table", "show lldp neighbors",
                        "show version", "show running-config"]
        case .fortinet:
            commands = ["get system status", "get router info routing-table all", "diagnose sys top", "show system interface"]
        case .aruba:
            commands = ["show interfaces brief", "show vlans", "show lldp info remote-device", "show running-config"]
        case .linux:
            commands = ["uptime", "df -h", "uname -a", "ip addr"]
        }
        return commands.sortedFrench()
    }
}

/// Extrait enregistré par l'utilisateur.
public struct TerminalSnippet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Nom affiché sur le bouton (« Sauvegarder la config »).
    public var name: String
    /// Commande tapée ; plusieurs lignes possibles.
    public var command: String
    /// Marque visée ; nil : toutes les sessions.
    public var brand: TerminalSnippetBrand?
    /// Termine par Entrée (sinon la commande est seulement tapée, à valider à la main).
    public var sendsReturn: Bool

    public init(id: UUID = UUID(), name: String, command: String, brand: TerminalSnippetBrand? = nil, sendsReturn: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.brand = brand
        self.sendsReturn = sendsReturn
    }

    /// Erreur de saisie, ou nil si l'extrait peut être enregistré.
    public static func validationError(name: String, command: String, existing: [TerminalSnippet], editing: UUID? = nil) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Donnez un nom à l’extrait." }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "La commande est vide." }
        if trimmedName.count > 60 { return "Le nom dépasse 60 caractères." }
        // Même nom à la casse et aux accents près (« Sauvegarde » et « sauvegarde ») : refusé.
        if existing.contains(where: {
            $0.id != editing && $0.name.compare(trimmedName, options: FrenchOrder.options, locale: FrenchOrder.locale) == .orderedSame
        }) {
            return "Un extrait porte déjà ce nom."
        }
        return nil
    }

    /// Préférence des extraits personnalisés (synchronisée et sauvegardée avec « Accès distant »).
    public static let preferenceKey = "acces.terminal.extraits"

    /// Extraits enregistrés (JSON des réglages) ; une donnée illisible donne une liste vide.
    public static func decodeList(_ data: Data?) -> [TerminalSnippet] {
        guard let data, let list = try? JSONDecoder().decode([TerminalSnippet].self, from: data) else { return [] }
        return list
    }

    public static func encodeList(_ list: [TerminalSnippet]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(list)) ?? Data("[]".utf8)
    }
}

/// Bouton de la barre « Extraits » d'une session.
public struct TerminalSnippetItem: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    public var sendsReturn: Bool
    /// Extrait enregistré par l'utilisateur (modifiable et supprimable).
    public var customID: UUID?

    public var isCustom: Bool { customID != nil }
}

public enum TerminalSnippetLibrary {
    /// Extraits d'une session : d'abord ceux de l'utilisateur (de sa marque ou pour toutes),
    /// puis ceux de la marque, chaque groupe en ordre alphabétique. Session sans marque connue
    /// (console série, Telnet ; note 95) : tous les extraits de l'utilisateur.
    public static func items(brand: TerminalSnippetBrand?, custom: [TerminalSnippet]) -> [TerminalSnippetItem] {
        let mine = custom.filter { brand == nil || $0.brand == nil || $0.brand == brand }
            .sortedFrench(by: \.name)
            .map { TerminalSnippetItem(id: "perso-" + $0.id.uuidString, title: $0.name, command: $0.command,
                                       sendsReturn: $0.sendsReturn, customID: $0.id) }
        let builtIn = (brand?.builtInCommands ?? []).map {
            TerminalSnippetItem(id: "marque-" + $0, title: $0, command: $0, sendsReturn: false, customID: nil)
        }
        return mine + builtIn
    }
}

/// Envoi d'une même commande à plusieurs sessions ouvertes.
public enum TerminalBroadcast {
    /// Session proposée dans la liste.
    public struct Target: Hashable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var address: String
        /// Dossier ou site de la connexion (vide : non classé).
        public var site: String
        public var isConnected: Bool

        public init(id: UUID, name: String, address: String, site: String = "", isConnected: Bool) {
            self.id = id
            self.name = name
            self.address = address
            self.site = site
            self.isConnected = isConnected
        }

        /// Nom suivi de l'adresse et du site : deux onglets du même nom restent distincts.
        public var label: String {
            let details = [address, site].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
        }
    }

    /// Ce qui sera fait : sessions qui recevront la commande et sessions cochées mais fermées.
    public struct Plan: Equatable, Sendable {
        public var recipients: [Target]
        public var skipped: [Target]
        public var payload: String
        public var lineCount: Int

        public var canSend: Bool { !recipients.isEmpty && !payload.isEmpty }
    }

    /// Texte tapé : fins de ligne ramenées à un retour chariot (Entrée d'un terminal), lignes vides
    /// de fin retirées, Entrée finale si demandé (toujours entre deux lignes).
    public static func payload(command: String, sendsReturn: Bool) -> String {
        var lines = command.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\r") + (sendsReturn ? "\r" : "")
    }

    public static func lineCount(_ command: String) -> Int {
        let payload = payload(command: command, sendsReturn: false)
        return payload.isEmpty ? 0 : payload.components(separatedBy: "\r").count
    }

    /// Sessions qui recevront la commande, dans l'ordre alphabétique de leur nom.
    public static func plan(command: String, sendsReturn: Bool, targets: [Target], selected: Set<UUID>) -> Plan {
        let chosen = targets.filter { selected.contains($0.id) }.sortedFrench(by: \.name)
        return Plan(recipients: chosen.filter(\.isConnected), skipped: chosen.filter { !$0.isConnected },
                    payload: payload(command: command, sendsReturn: sendsReturn), lineCount: lineCount(command))
    }

    /// Question de la confirmation.
    public static func confirmationTitle(_ plan: Plan) -> String {
        let count = plan.recipients.count
        return count == 1 ? "Envoyer la commande à 1\u{00A0}session\u{00A0}?" : "Envoyer la commande à \(count)\u{00A0}sessions\u{00A0}?"
    }

    /// Ce que fait l'envoi selon le nombre de lignes et l'Entrée finale. Sans Entrée finale, les lignes
    /// sont tout de même séparées par Entrée : toutes sauf la dernière s'exécutent.
    public static func executionNote(lineCount: Int, sendsReturn: Bool) -> String {
        if sendsReturn {
            return lineCount > 1 ? "Les \(lineCount)\u{00A0}lignes seront exécutées (Entrée après chacune)."
                                 : "Elle sera validée par Entrée."
        }
        if lineCount > 2 {
            return "Les \(lineCount - 1)\u{00A0}premières lignes seront exécutées\u{00A0}; la dernière restera à valider."
        }
        if lineCount == 2 { return "La première ligne sera exécutée\u{00A0}; la dernière restera à valider." }
        return "Elle ne sera pas validée (sans Entrée)."
    }

    /// Détail de la confirmation : commande (première ligne), sessions, Entrée ou non.
    public static func confirmationMessage(_ plan: Plan, command: String, sendsReturn: Bool) -> String {
        let first = payload(command: command, sendsReturn: false).components(separatedBy: "\r").first ?? ""
        let more = plan.lineCount > 1 ? " (et \(plan.lineCount - 1)\u{00A0}autre\(plan.lineCount > 2 ? "s" : "") ligne\(plan.lineCount > 2 ? "s" : ""))" : ""
        var text = "«\u{00A0}\(first)\u{00A0}»\(more) sera tapée dans\u{00A0}: " + plan.recipients.map(\.label).joined(separator: ", ") + "."
        text += " " + executionNote(lineCount: plan.lineCount, sendsReturn: sendsReturn)
        if !plan.skipped.isEmpty {
            text += " Session\(plan.skipped.count > 1 ? "s" : "") fermée\(plan.skipped.count > 1 ? "s" : ""), ignorée\(plan.skipped.count > 1 ? "s" : "")\u{00A0}: "
                + plan.skipped.map(\.label).joined(separator: ", ") + "."
        }
        return text
    }
}
