import Foundation

// Note 6 (suite, 0.26.2) : état du serveur RustDesk lu par le script de collecte, et sa lecture
// (fonctions pures, testées sur des sorties fixes). Tolérant : section vide, commande absente,
// permission refusée ou hbbs ancien sans « pr » donnent un état expliqué, jamais une erreur.

// MARK: - Éléments

/// Session relayée en cours, d'après « u » de la console de hbbr :
/// « <ip>:<port>: <secondes>s <Mo>MB <max>kb/s <moyen>kb/s <actuel>kb/s » (débits en kilobits par seconde).
public struct RustDeskRelaySession: Equatable, Identifiable, Sendable {
    public var id: String { address }
    /// « 203.0.113.7:53122 » : l'un des deux bouts de la session (celui qui a rejoint le relais en second).
    public var address: String
    public var ip: String
    public var port: Int?
    public var seconds: Int
    public var megabytes: Double
    public var maxKbps: Int
    public var averageKbps: Int
    public var currentKbps: Int

    public init(address: String, seconds: Int, megabytes: Double, maxKbps: Int, averageKbps: Int, currentKbps: Int) {
        self.address = address
        let split = RustDeskRelaySession.split(address)
        ip = split.ip
        port = split.port
        self.seconds = seconds
        self.megabytes = megabytes
        self.maxKbps = maxKbps
        self.averageKbps = averageKbps
        self.currentKbps = currentKbps
    }

    /// « 1.2.3.4:5 » → (1.2.3.4, 5) ; « [2001:db8::1]:5 » → (2001:db8::1, 5) ; « ::ffff:1.2.3.4:5 »
    /// (IPv6 sans crochets) → port après le dernier « : ». Sans port : « ::ffff:1.2.3.4 » →
    /// 1.2.3.4, « 2001:db8::1234 » reste entière (le dernier groupe n'est pas un port). Le préfixe
    /// « ::ffff: » (IPv4 vue en IPv6 par un hbbs en double pile) est toujours retiré.
    public static func split(_ address: String) -> (ip: String, port: Int?) {
        let text = address
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let ip = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            return (unmapped(ip), rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        // Adresse entière valide (IPv4 ou IPv6 nue) : aucun port.
        if isIPv4(text) || isIPv6(text) { return (unmapped(text), nil) }
        // Le dernier « : » ne sépare un port que si la partie gauche est une adresse valide.
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
           (0...65_535).contains(port) {
            let left = String(text[..<colon])
            if isIPv4(left) || isIPv6(left) { return (unmapped(left), port) }
        }
        return (unmapped(text), nil)
    }

    /// « ::ffff:1.2.3.4 » → « 1.2.3.4 » (insensible à la casse) ; le reste, inchangé.
    static func unmapped(_ ip: String) -> String {
        let prefix = "::ffff:"
        guard ip.lowercased().hasPrefix(prefix) else { return ip }
        let rest = String(ip.dropFirst(prefix.count))
        return isIPv4(rest) ? rest : ip
    }

    static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return !text.isEmpty && inet_pton(AF_INET, text, &address) == 1
    }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.contains(":") && inet_pton(AF_INET6, text, &address) == 1
    }

    /// Ligne de « u » ; nil si la ligne ne suit pas le format.
    public static func parse(_ line: String) -> RustDeskRelaySession? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.range(of: ": ") else { return nil }
        let address = String(trimmed[..<separator.lowerBound])
        let fields = trimmed[separator.upperBound...].split(separator: " ")
        guard !address.isEmpty, fields.count == 5,
              fields[0].hasSuffix("s"), let seconds = Int(fields[0].dropLast()),
              fields[1].hasSuffix("MB"), let megabytes = Double(fields[1].dropLast(2)),
              let maxKbps = kbps(fields[2]), let average = kbps(fields[3]), let current = kbps(fields[4]),
              seconds >= 0, megabytes >= 0, megabytes.isFinite else { return nil }
        return RustDeskRelaySession(address: address, seconds: seconds, megabytes: megabytes,
                                    maxKbps: maxKbps, averageKbps: average, currentKbps: current)
    }

    private static func kbps(_ field: Substring) -> Int? {
        guard field.hasSuffix("kb/s"), let value = Double(field.dropLast(4)), value.isFinite, value >= 0, value < 1e12 else { return nil }
        return Int(value.rounded())
    }
}

/// Demande de connexion récente, d'après « pr » de la console de hbbs :
/// « <date ISO> <ip du technicien> -> <id visé>@<ip du poste> ».
public struct RustDeskPunchRequest: Equatable, Identifiable, Sendable {
    /// Rang dans la liste lue (unique dans une lecture).
    public var id: Int
    public var date: Date
    /// Adresse du demandeur (le technicien, vu par hbbs).
    public var fromIP: String
    /// ID RustDesk visé.
    public var targetID: String
    /// Adresse du poste visé (vue par hbbs à son dernier enregistrement).
    public var targetIP: String

    public init(id: Int, date: Date, fromIP: String, targetID: String, targetIP: String) {
        self.id = id
        self.date = date
        self.fromIP = fromIP
        self.targetID = targetID
        self.targetIP = targetIP
    }

    public static func parse(_ line: String, id: Int) -> RustDeskPunchRequest? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")
        guard words.count == 4, words[2] == "->", let date = isoDate(String(words[0])) else { return nil }
        let target = words[3]
        guard let at = target.lastIndex(of: "@") else { return nil }
        let targetID = String(target[..<at])
        let targetIP = String(target[target.index(after: at)...])
        guard !targetID.isEmpty, targetID.count <= 64, !words[1].isEmpty else { return nil }
        return RustDeskPunchRequest(id: id, date: date, fromIP: RustDeskRelaySession.split(String(words[1])).ip,
                                    targetID: targetID, targetIP: RustDeskRelaySession.split(targetIP).ip)
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// Processus hbbs ou hbbr (ps : temps écoulé, PID, nom, ligne de commande).
public struct RustDeskServerProcess: Equatable, Sendable {
    public var name: String
    public var pid: Int
    /// Depuis combien de secondes il tourne.
    public var seconds: Int
    /// Ligne de commande ; la valeur de « -k » (clé) est masquée.
    public var arguments: String

    public init(name: String, pid: Int, seconds: Int, arguments: String) {
        self.name = name
        self.pid = pid
        self.seconds = seconds
        self.arguments = arguments
    }
}

/// Conteneur Docker (docker ps) : nom, image, état (« Up 3 days »).
public struct RustDeskContainer: Equatable, Sendable {
    public var name: String
    public var image: String
    public var status: String

    public init(name: String, image: String, status: String) {
        self.name = name
        self.image = image
        self.status = status
    }

    public var isRunning: Bool { status.lowercased().hasPrefix("up") }

    /// « 1.1.16 » d'une image « rustdesk/rustdesk-server:1.1.16 » ; nil pour « latest » ou sans étiquette.
    public var imageVersion: String? {
        guard let colon = image.lastIndex(of: ":"), !image[colon...].contains("/") else { return nil }
        let tag = String(image[image.index(after: colon)...])
        return tag.first?.isNumber == true ? tag : nil
    }
}

/// Espace disque du dossier du serveur (df -Pk).
public struct RustDeskDiskUsage: Equatable, Sendable {
    public var mount: String
    public var totalKB: Int64
    public var usedKB: Int64
    public var availableKB: Int64
    /// Taille du dossier data (du -sk), si lisible.
    public var dataKB: Int64?

    public init(mount: String, totalKB: Int64, usedKB: Int64, availableKB: Int64, dataKB: Int64? = nil) {
        self.mount = mount
        self.totalKB = totalKB
        self.usedKB = usedKB
        self.availableKB = availableKB
        self.dataKB = dataKB
    }

    public var usedFraction: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) : 0 }
}

/// Fichier de sauvegarde trouvé dans /opt/rustdesk.
public struct RustDeskBackupFile: Equatable, Sendable {
    public var path: String
    public var date: Date
    public var bytes: Int64

    public init(path: String, date: Date, bytes: Int64) {
        self.path = path
        self.date = date
        self.bytes = bytes
    }
}

/// Nombre de postes enregistrés (table peer de db_v2.sqlite3).
public enum RustDeskPeerCount: Equatable, Sendable {
    case count(Int)
    /// Base absente à l'endroit attendu.
    case notFound
    /// Base lisible par root seulement (NetScope n'utilise jamais sudo).
    case unreadable
    /// sqlite3 n'est pas installé sur le serveur.
    case missingTool
    case error(String)
    /// Section absente (lecture interrompue).
    case unknown

    public var value: Int? {
        if case .count(let n) = self { return n }
        return nil
    }

    /// Raison courte (détail d'une tuile) ; l'explication complète va dans l'infobulle.
    public var shortExplanation: String {
        switch self {
        case .count: return "base de hbbs"
        case .notFound: return "base introuvable"
        case .unreadable: return "lisible par root seulement"
        case .missingTool: return "sqlite3 absent"
        case .error: return "lecture impossible"
        case .unknown: return "non lu"
        }
    }

    /// Pourquoi le nombre est inconnu.
    public var explanation: String {
        switch self {
        case .count: return "Table peer de db_v2.sqlite3"
        case .notFound: return "Base db_v2.sqlite3 introuvable dans /opt/rustdesk/data"
        case .unreadable: return "Base lisible par root seulement (jamais de sudo)"
        case .missingTool: return "sqlite3 absent du serveur (apt install sqlite3)"
        case .error(let text): return "Lecture impossible\u{00A0}: \(text)"
        case .unknown: return "Non lu"
        }
    }
}

/// État d'une console (hbbr ou hbbs).
public enum RustDeskConsoleState: Equatable, Sendable {
    case ok
    /// Connexion refusée ou sans réponse (service arrêté, autre port).
    case unreachable(code: Int)
    /// Ni nc, ni bash, ni python3 sur le serveur.
    case noClient
    /// Commande refusée par la liste blanche du script (ne devrait jamais arriver).
    case refused
    /// Section absente (lecture interrompue).
    case unknown

    public var isOK: Bool { self == .ok }

    static func from(code: Int?) -> RustDeskConsoleState {
        switch code {
        case 0?: return .ok
        case 127?: return .noClient
        case 64?: return .refused
        case let value?: return .unreachable(code: value)
        case nil: return .unknown
        }
    }
}

// MARK: - État lu

/// Tout ce que la lecture a appris du serveur.
public struct RustDeskServerStatus: Equatable, Sendable {
    /// Heure de la lecture (Mac).
    public var readAt: Date
    /// Heure du serveur au moment de la lecture (date -u +%s).
    public var serverTime: Date?
    public var hostname: String
    public var user: String
    public var system: String
    /// Client TCP utilisé pour les consoles : nc, bash, python3 ou aucun.
    public var tcpClient: String

    public var hbbs: RustDeskServerProcess?
    public var hbbr: RustDeskServerProcess?
    public var containers: [RustDeskContainer]
    /// Pourquoi les conteneurs n'ont pas été lus (« groupe-docker », « docker-absent »).
    public var dockerSkipped: String?
    /// Paquets .deb (nom, version).
    public var packages: [(name: String, version: String)]
    public var disk: RustDeskDiskUsage?
    public var backups: [RustDeskBackupFile]
    public var peers: RustDeskPeerCount

    public var relayConsole: RustDeskConsoleState
    public var relaySessions: [RustDeskRelaySession]
    /// « tb » et « sb » : débit total et par session permis par hbbr (« 1024Mb/s »).
    public var totalBandwidth: String?
    public var sessionBandwidth: String?

    public var idConsole: RustDeskConsoleState
    /// « pr » connu de ce hbbs (présent dans l'aide « h »).
    public var punchSupported: Bool
    /// Demandes gardées par hbbs (en mémoire, depuis son dernier démarrage).
    public var punchTotal: Int
    /// Les plus récentes d'abord.
    public var punchRequests: [RustDeskPunchRequest]
    /// Relais annoncés aux clients (« rs »).
    public var relayServers: [String]
    /// Marqueur de fin reçu : toutes les sections ont été lues.
    public var complete: Bool
    /// Note 87 : santé, clé publique, conteneurs inspectés et images (groupe docker seulement).
    public var health: RustDeskServerHealth?
    public var publicKey: RustDeskPublicKey = .unknown
    public var containerDetails: [RustDeskContainerDetail] = []
    public var images: [RustDeskImageDigest] = []

    public init(readAt: Date, serverTime: Date? = nil, hostname: String = "", user: String = "", system: String = "",
                tcpClient: String = "", hbbs: RustDeskServerProcess? = nil, hbbr: RustDeskServerProcess? = nil,
                containers: [RustDeskContainer] = [], dockerSkipped: String? = nil, packages: [(name: String, version: String)] = [],
                disk: RustDeskDiskUsage? = nil, backups: [RustDeskBackupFile] = [], peers: RustDeskPeerCount = .unknown,
                relayConsole: RustDeskConsoleState = .unknown, relaySessions: [RustDeskRelaySession] = [],
                totalBandwidth: String? = nil, sessionBandwidth: String? = nil, idConsole: RustDeskConsoleState = .unknown,
                punchSupported: Bool = false, punchTotal: Int = 0, punchRequests: [RustDeskPunchRequest] = [],
                relayServers: [String] = [], complete: Bool = true) {
        self.readAt = readAt
        self.serverTime = serverTime
        self.hostname = hostname
        self.user = user
        self.system = system
        self.tcpClient = tcpClient
        self.hbbs = hbbs
        self.hbbr = hbbr
        self.containers = containers
        self.dockerSkipped = dockerSkipped
        self.packages = packages
        self.disk = disk
        self.backups = backups
        self.peers = peers
        self.relayConsole = relayConsole
        self.relaySessions = relaySessions
        self.totalBandwidth = totalBandwidth
        self.sessionBandwidth = sessionBandwidth
        self.idConsole = idConsole
        self.punchSupported = punchSupported
        self.punchTotal = punchTotal
        self.punchRequests = punchRequests
        self.relayServers = relayServers
        self.complete = complete
    }

    public static func == (a: RustDeskServerStatus, b: RustDeskServerStatus) -> Bool {
        a.readAt == b.readAt && a.serverTime == b.serverTime && a.hostname == b.hostname && a.user == b.user
            && a.system == b.system && a.tcpClient == b.tcpClient && a.hbbs == b.hbbs && a.hbbr == b.hbbr
            && a.containers == b.containers && a.dockerSkipped == b.dockerSkipped
            && a.packages.map { $0.name + "\t" + $0.version } == b.packages.map { $0.name + "\t" + $0.version }
            && a.disk == b.disk && a.backups == b.backups && a.peers == b.peers && a.relayConsole == b.relayConsole
            && a.relaySessions == b.relaySessions && a.totalBandwidth == b.totalBandwidth && a.sessionBandwidth == b.sessionBandwidth
            && a.idConsole == b.idConsole && a.punchSupported == b.punchSupported && a.punchTotal == b.punchTotal
            && a.punchRequests == b.punchRequests && a.relayServers == b.relayServers && a.complete == b.complete
            && a.health == b.health && a.publicKey == b.publicKey && a.containerDetails == b.containerDetails && a.images == b.images
    }

    /// Heure de référence du serveur (son horloge si connue, sinon celle du Mac).
    public var now: Date { serverTime ?? readAt }

    /// Débit relayé actuel, toutes sessions (kbit/s).
    public var currentRelayKbps: Int { relaySessions.reduce(0) { $0 + $1.currentKbps } }

    /// Version du serveur : étiquette de l'image Docker, sinon version du paquet .deb.
    public var version: String? {
        if let tag = containers.lazy.compactMap(\.imageVersion).first { return tag }
        if let package = packages.first(where: { $0.name.contains("hbbs") || $0.name == "rustdesk-server" }) ?? packages.first {
            return package.version
        }
        return nil
    }

    /// Demandes des `hours` dernières heures ; `atLeast` : la liste lue (500 au plus) ne remonte
    /// pas assez loin, le vrai nombre peut être plus grand.
    public func punchCount(lastHours hours: Double = 24) -> (count: Int, atLeast: Bool) {
        let since = now.addingTimeInterval(-hours * 3_600)
        let count = punchRequests.filter { $0.date >= since }.count
        let truncated = punchTotal > punchRequests.count && (punchRequests.map(\.date).min() ?? .distantPast) >= since
        return (count, truncated)
    }

    /// hbbs en marche : vu par ps, conteneur en marche, ou console qui a répondu (ps peut ne pas
    /// voir le processus : /proc monté avec hidepid, processus d'un autre utilisateur).
    public var hbbsRunning: Bool {
        hbbs != nil || containers.first(where: { $0.name.contains("hbbs") })?.isRunning == true || idConsole.isOK
    }

    /// hbbr en marche (mêmes règles, console de hbbr).
    public var hbbrRunning: Bool {
        hbbr != nil || containers.first(where: { $0.name.contains("hbbr") })?.isRunning == true || relayConsole.isOK
    }

    /// Ce qui manque ou ne va pas, avec la marche à suivre (bandeaux du tableau de bord).
    public var notices: [RustDeskFinding] {
        var list: [RustDeskFinding] = []
        if !complete {
            list.append(RustDeskFinding(.warning, "Lecture incomplète", "La connexion SSH s’est terminée avant la fin du script\u{00A0}: certaines valeurs manquent."))
        }
        if !hbbsRunning {
            list.append(RustDeskFinding(.error, "hbbs n’est pas en marche", "Le serveur d’ID ne répond plus aux postes. Sur le serveur\u{00A0}: «\u{00A0}cd /opt/rustdesk && docker compose up -d\u{00A0}» (ou «\u{00A0}systemctl start rustdesk-hbbs\u{00A0}»)."))
        }
        if !hbbrRunning {
            list.append(RustDeskFinding(.error, "hbbr n’est pas en marche", "Les sessions relayées sont impossibles. Sur le serveur\u{00A0}: «\u{00A0}cd /opt/rustdesk && docker compose up -d\u{00A0}» (ou «\u{00A0}systemctl start rustdesk-hbbr\u{00A0}»)."))
        }
        switch relayConsole {
        case .noClient, .unreachable, .refused:
            list.append(RustDeskFinding(.warning, "Console hbbr non joignable", consoleAdvice(relayConsole, port: RustDeskConsoleCommand.relayPort, service: "hbbr")))
        default: break
        }
        switch idConsole {
        case .noClient, .unreachable, .refused:
            list.append(RustDeskFinding(.warning, "Console hbbs non joignable", consoleAdvice(idConsole, port: RustDeskConsoleCommand.idPort, service: "hbbs")))
        case .ok where !punchSupported:
            list.append(RustDeskFinding(.info, "hbbs ancien\u{00A0}: pas de liste des demandes",
                                        "Cette version de hbbs ne connaît pas la commande «\u{00A0}pr\u{00A0}» (punch-requests). Mettez l’image à jour («\u{00A0}docker compose pull && docker compose up -d\u{00A0}» dans /opt/rustdesk) pour voir les demandes de connexion."))
        default: break
        }
        if let disk, disk.usedFraction >= 0.9 {
            list.append(RustDeskFinding(.warning, "Disque presque plein", "\(Int((disk.usedFraction * 100).rounded()))\u{00A0}% utilisé sur \(disk.mount)\u{00A0}: la base de hbbs et les journaux Docker peuvent ne plus s’écrire."))
        }
        return list
    }

    private func consoleAdvice(_ state: RustDeskConsoleState, port: Int, service: String) -> String {
        switch state {
        case .noClient:
            return "Ni nc, ni bash, ni python3 sur le serveur pour joindre 127.0.0.1:\(port). Installez netcat-openbsd («\u{00A0}apt install netcat-openbsd\u{00A0}»)."
        case .refused:
            return "Commande refusée par la liste blanche de NetScope."
        default:
            return "127.0.0.1:\(port) ne répond pas sur le serveur\u{00A0}: \(service) arrêté, ou conteneur sans «\u{00A0}network_mode: host\u{00A0}» (la console n’écoute que sur la boucle locale du conteneur)."
        }
    }
}

// MARK: - Lecture de la sortie

public enum RustDeskServerOutput {
    /// Sections de la sortie : lignes et code de retour éventuel.
    public static func sections(_ text: String) -> [String: (lines: [String], status: Int?)] {
        var result: [String: (lines: [String], status: Int?)] = [:]
        var current: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix(RustDeskServerScript.sectionPrefix), line.hasSuffix("@@") {
                let name = String(line.dropFirst(RustDeskServerScript.sectionPrefix.count).dropLast(2))
                current = name
                if result[name] == nil { result[name] = ([], nil) }
                continue
            }
            guard let section = current else { continue }
            if line.hasPrefix(RustDeskServerScript.statusPrefix), line.hasSuffix("@@") {
                result[section]?.status = Int(line.dropFirst(RustDeskServerScript.statusPrefix.count).dropLast(2))
                continue
            }
            if !line.isEmpty { result[section]?.lines.append(line) }
        }
        return result
    }

    /// Lit toute la sortie du script.
    public static func parse(_ text: String, readAt: Date) -> RustDeskServerStatus {
        let parts = sections(text)
        var status = RustDeskServerStatus(readAt: readAt, complete: parts["FIN"] != nil)

        var meta: [String: String] = [:]
        for line in parts["META"]?.lines ?? [] {
            guard let equal = line.firstIndex(of: "=") else { continue }
            meta[String(line[..<equal])] = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
        }
        status.hostname = clean(meta["hote"] ?? "")
        status.user = clean(meta["utilisateur"] ?? "")
        status.system = clean(meta["systeme"] ?? "")
        status.tcpClient = clean(meta["client"] ?? "")
        if let epoch = meta["heure"].flatMap(TimeInterval.init), epoch > 0 { status.serverTime = Date(timeIntervalSince1970: epoch) }

        for line in parts["PROCESSUS"]?.lines ?? [] {
            guard let process = process(line) else { continue }
            if process.name == "hbbs", status.hbbs.map({ $0.seconds < process.seconds }) ?? true { status.hbbs = process }
            if process.name == "hbbr", status.hbbr.map({ $0.seconds < process.seconds }) ?? true { status.hbbr = process }
        }

        for line in parts["DOCKER"]?.lines ?? [] {
            if line.hasPrefix("IGNORE ") {
                status.dockerSkipped = String(line.dropFirst(7))
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { continue }
            status.containers.append(RustDeskContainer(name: clean(fields[0]), image: clean(fields[1]), status: clean(fields[2])))
        }

        for line in parts["PAQUETS"]?.lines ?? [] {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2, !fields[1].isEmpty else { continue }
            status.packages.append((clean(fields[0]), clean(fields[1])))
        }

        status.disk = disk(parts["DISQUE"]?.lines ?? [])

        for line in parts["SAUVEGARDE"]?.lines ?? [] {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3, let epoch = Double(fields[0]), let size = Int64(fields[1]) else { continue }
            status.backups.append(RustDeskBackupFile(path: clean(fields[2...].joined(separator: "\t")),
                                                     date: Date(timeIntervalSince1970: epoch), bytes: size))
        }

        status.peers = peers(parts["POSTES"]?.lines)

        if let usage = parts["HBBR_U"] {
            status.relayConsole = RustDeskConsoleState.from(code: usage.status)
            status.relaySessions = usage.lines.compactMap(RustDeskRelaySession.parse)
        }
        status.totalBandwidth = parts["HBBR_TB"].flatMap { $0.status == 0 ? $0.lines.first.map(clean) : nil }
        status.sessionBandwidth = parts["HBBR_SB"].flatMap { $0.status == 0 ? $0.lines.first.map(clean) : nil }

        if let help = parts["HBBS_AIDE"] {
            status.idConsole = RustDeskConsoleState.from(code: help.status)
            status.punchSupported = help.lines.contains { $0.contains("punch-requests") }
        }
        if let relays = parts["HBBS_RS"], relays.status == 0 {
            status.relayServers = relays.lines.map(clean).filter { !$0.isEmpty }
        }
        status.punchTotal = parts["HBBS_NOMBRE"]?.lines.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let requests = (parts["HBBS_PR"]?.lines ?? []).enumerated().compactMap { RustDeskPunchRequest.parse($0.element, id: $0.offset) }
        status.punchRequests = requests.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        if !status.punchRequests.isEmpty { status.punchSupported = true }
        status.health = parts["SANTE"].flatMap { RustDeskServerHealth.parse($0.lines) }
        status.publicKey = RustDeskPublicKey.parse(parts["CLE"]?.lines)
        status.containerDetails = (parts["INSPECT"]?.lines ?? []).compactMap(RustDeskContainerDetail.parse)
        status.images = (parts["IMAGES"]?.lines ?? []).compactMap(RustDeskImageDigest.parse)
        return status
    }

    /// « 259200  1234 hbbs  hbbs -r relais.exemple.ca -k _ ».
    static func process(_ line: String) -> RustDeskServerProcess? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 3, let seconds = Int(words[0]), let pid = Int(words[1]),
              words[2] == "hbbs" || words[2] == "hbbr" else { return nil }
        return RustDeskServerProcess(name: String(words[2]), pid: pid, seconds: seconds,
                                     arguments: maskKey(words.dropFirst(3).map(String.init)))
    }

    /// Valeur de « -k » ou « --key » remplacée par « … » (jamais affichée ni gardée).
    static func maskKey(_ words: [String]) -> String {
        var out: [String] = []
        var maskNext = false
        for word in words {
            if maskNext {
                out.append("…")
                maskNext = false
            } else if word == "-k" || word == "--key" {
                out.append(word)
                maskNext = true
            } else if word.hasPrefix("--key=") {
                out.append("--key=…")
            } else {
                out.append(word)
            }
        }
        return clean(out.joined(separator: " "))
    }

    /// df -Pk : en-tête, puis « système  total  utilisé  libre  pourcentage  point de montage » ; « du=<ko> ».
    static func disk(_ lines: [String]) -> RustDeskDiskUsage? {
        var usage: RustDeskDiskUsage?
        var data: Int64?
        for line in lines {
            if line.hasPrefix("du=") {
                data = Int64(line.dropFirst(3).trimmingCharacters(in: .whitespaces))
                continue
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 6, let total = Int64(words[1]), let used = Int64(words[2]), let available = Int64(words[3]),
                  words[4].hasSuffix("%") else { continue }
            usage = RustDeskDiskUsage(mount: clean(words[5...].joined(separator: " ")), totalKB: total, usedKB: used, availableKB: available)
        }
        usage?.dataKB = data
        return usage
    }

    static func peers(_ lines: [String]?) -> RustDeskPeerCount {
        guard let lines else { return .unknown }
        guard let first = lines.first, first.hasPrefix("ETAT ") else { return lines.isEmpty ? .unknown : .error(clean(lines[0])) }
        switch first.dropFirst(5) {
        case "introuvable": return .notFound
        case "illisible": return .unreadable
        case "sans-sqlite3": return .missingTool
        case "ok":
            guard let answer = lines.dropFirst().first else { return .error("aucune réponse de sqlite3") }
            if let value = Int(answer.trimmingCharacters(in: .whitespaces)), value >= 0 { return .count(value) }
            let lower = answer.lowercased()
            if lower.contains("unable to open") || lower.contains("readonly") || lower.contains("permission") { return .unreadable }
            return .error(clean(answer))
        default: return .unknown
        }
    }

    /// Texte venu du serveur : une ligne, sans caractères de contrôle, longueur bornée.
    static func clean(_ text: String) -> String {
        RemoteShell.sanitizedTitle(text, limit: 200)
    }

    /// Résultat de ssh : état lu, ou erreur expliquée.
    public static func interpret(status: Int32, stdout: String, stderr: String, timedOut: Bool, host: String,
                                 readAt: Date) -> Result<RustDeskServerStatus, RustDeskServerReadError> {
        let hasMarkers = stdout.contains(RustDeskServerScript.sectionPrefix + "META@@")
        if hasMarkers {
            var parsed = parse(stdout, readAt: readAt)
            if timedOut { parsed.complete = parsed.complete && !timedOut }
            return .success(parsed)
        }
        if timedOut {
            return .failure(RustDeskServerReadError(kind: .timeout, detail: "Aucune réponse de \(host) dans le délai."))
        }
        if status < 0 {
            return .failure(RustDeskServerReadError(kind: .launch, detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let lower = stderr.lowercased()
        // Serveur inconnu, refusé par l'askpass (« no ») : l'empreinte est à montrer et à accepter.
        if !lower.contains("remote host identification has changed"),
           lower.contains("continue connecting") || lower.contains("host key verification failed") {
            let fingerprint = SFTPOutput.fingerprint(in: stderr)
            return .failure(RustDeskServerReadError(kind: .unknownHostKey,
                                                    detail: "Empreinte présentée par \(host)\u{00A0}: \(fingerprint ?? "inconnue")",
                                                    fingerprint: fingerprint))
        }
        if status == 255 || lower.contains("permission denied") || lower.contains("host key") {
            let outcome = SSHCredentialTest.analyze(exitCode: 255, stdout: "", stderr: stderr, host: host, milliseconds: 0)
            var reason = outcome.message
            if reason.hasPrefix("Échec · ") { reason = String(reason.dropFirst("Échec · ".count)) }
            let kind: RustDeskServerReadError.Kind
            if lower.contains("permission denied") || lower.contains("too many authentication failures") {
                kind = .authentication
            } else if lower.contains("remote host identification has changed") || lower.contains("host key verification failed") {
                kind = .hostKey
            } else if lower.contains("timed out") {
                kind = .timeout
            } else {
                kind = .unreachable
            }
            return .failure(RustDeskServerReadError(kind: kind, detail: reason.prefix(1).uppercased() + reason.dropFirst()))
        }
        let detail = clean(stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "code \(status)")
        return .failure(RustDeskServerReadError(kind: .script, detail: detail.isEmpty ? "Code \(status), aucune sortie." : detail))
    }
}

// MARK: - Rapprochements

/// Liens entre les demandes « pr », les sessions relayées et le carnet des postes.
public enum RustDeskServerCorrelation {
    /// Fenêtre autour du début d'une session relayée où la demande correspondante a pu être faite :
    /// le client essaie d'abord le pair-à-pair, puis passe au relais (hbbs ignore les demandes
    /// répétées dans la minute).
    public static let before: TimeInterval = 300
    public static let after: TimeInterval = 60

    /// Demande à l'origine d'une session relayée : même adresse (technicien ou poste), faite peu
    /// avant le début de la session ; la plus proche.
    public static func request(for session: RustDeskRelaySession, in requests: [RustDeskPunchRequest], now: Date) -> RustDeskPunchRequest? {
        let start = now.addingTimeInterval(-TimeInterval(session.seconds))
        return requests
            .filter { $0.fromIP == session.ip || $0.targetIP == session.ip }
            .filter { $0.date >= start.addingTimeInterval(-before) && $0.date <= start.addingTimeInterval(after) }
            .min { abs($0.date.timeIntervalSince(start)) < abs($1.date.timeIntervalSince(start)) }
    }

    /// Demandes passées par le relais : celles qui sont à l'origine d'une session relayée en cours.
    public static func relayedRequestIDs(sessions: [RustDeskRelaySession], requests: [RustDeskPunchRequest], now: Date) -> Set<Int> {
        Set(sessions.compactMap { request(for: $0, in: requests, now: now)?.id })
    }

    /// Nom du poste d'après son ID RustDesk (carnet : ID → nom).
    public static func name(of targetID: String, book: [String: String]) -> String? {
        guard let id = RustDeskID.parse(targetID) else { return nil }
        return book[id]
    }
}

// MARK: - Mise en forme

public enum RustDeskServerFormat {
    /// « 850 kbit/s », « 3,4 Mbit/s ».
    public static func kbps(_ value: Int) -> String {
        if value < 1_000 { return "\(value)\u{00A0}kbit/s" }
        let mbps = Double(value) / 1_000
        return String(format: mbps < 100 ? "%.1f" : "%.0f", mbps).replacingOccurrences(of: ".", with: ",") + "\u{00A0}Mbit/s"
    }

    /// « 42 s », « 12 min », « 1 h 05 », « 3 j 4 h ».
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)\u{00A0}s" }
        if s < 3_600 { return "\(s / 60)\u{00A0}min" }
        if s < 86_400 { return "\(s / 3_600)\u{00A0}h\u{00A0}" + String(format: "%02d", (s % 3_600) / 60) }
        let hours = (s % 86_400) / 3_600
        return "\(s / 86_400)\u{00A0}j" + (hours > 0 ? "\u{00A0}\(hours)\u{00A0}h" : "")
    }

    /// « 182 Mo », « 1,4 Go ».
    public static func megabytes(_ value: Double) -> String {
        if value < 1 { return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") + "\u{00A0}Mo" }
        if value < 1_000 { return String(format: "%.0f", value) + "\u{00A0}Mo" }
        return String(format: "%.1f", value / 1_024).replacingOccurrences(of: ".", with: ",") + "\u{00A0}Go"
    }

    /// Octets → « 18 ko », « 2,4 Mo », « 1,2 Go ».
    public static func bytes(_ value: Int64) -> String {
        if value < 1_024 * 1_024 { return "\(max(1, Int((Double(value) / 1_024).rounded())))\u{00A0}ko" }
        let mega = Double(value) / 1_048_576
        if mega < 10 { return String(format: "%.1f", mega).replacingOccurrences(of: ".", with: ",") + "\u{00A0}Mo" }
        return megabytes(mega)
    }

    /// État de docker ps en français : « Up 3 days » → « en marche depuis 3 jours »,
    /// « Exited (0) 2 hours ago » → « arrêté (0) il y a 2 heures » ; le reste tel quel.
    public static func dockerStatus(_ status: String) -> String {
        var text = status.trimmingCharacters(in: .whitespaces)
        let units: [(String, String)] = [("About a minute", "environ une minute"), ("About an hour", "environ une heure"),
                                         ("Less than a second", "moins d’une seconde"),
                                         ("seconds", "secondes"), ("second", "seconde"), ("minutes", "minutes"), ("minute", "minute"),
                                         ("hours", "heures"), ("hour", "heure"), ("days", "jours"), ("day", "jour"),
                                         ("weeks", "semaines"), ("week", "semaine"), ("months", "mois"), ("month", "mois"),
                                         ("years", "ans"), ("year", "an"), ("(healthy)", "(sain)"), ("(unhealthy)", "(en mauvaise santé)"),
                                         ("(Paused)", "(en pause)")]
        if text.hasPrefix("Up ") {
            text = "en marche depuis " + text.dropFirst(3)
        } else if text.hasPrefix("Exited "), text.hasSuffix(" ago") {
            text = "arrêté " + text.dropFirst(7).dropLast(4).replacingOccurrences(of: ") ", with: ") il y a ")
        } else if text == "Created" {
            return "créé, jamais démarré"
        } else if text.hasPrefix("Restarting") {
            text = "redémarre en boucle" + text.dropFirst("Restarting".count)
        }
        for (english, french) in units {
            // Mot entier seulement (« second » ne touche pas « secondes ») ; parenthèses : texte exact.
            if english.hasPrefix("(") {
                text = text.replacingOccurrences(of: english, with: french)
            } else {
                text = text.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: english) + "\\b", with: french,
                                                 options: .regularExpression)
            }
        }
        return text
    }

    /// Kilo-octets → « 12,4 Go », « 820 Mo ».
    public static func kilobytes(_ value: Int64) -> String {
        megabytes(Double(value) / 1_024)
    }
}
