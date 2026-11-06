import CryptoKit
import Foundation

// Note 87 (0.33.0) : suivi du serveur RustDesk gardé par NetScope — versions publiées, noms et
// notes par ID, historique des demandes jour après jour et rapport mensuel, tentatives suspectes,
// site probable, association d'un ID à une fiche (proposée, jamais tranchée par l'IP seule),
// règles d'alerte et copie chiffrée du dossier de données. Tout est pur ici (textes fixes en test).

// MARK: - Versions

public enum RustDeskVersionCheck {
    public static let serverRepository = "rustdesk/rustdesk-server"
    /// Une vérification en ligne par jour au plus (sinon au clic).
    public static let interval: TimeInterval = 86_400
    public static let dockerHubURL = URL(string: "https://hub.docker.com/v2/repositories/rustdesk/rustdesk-server/tags/latest")!
    public static let serverReleaseURL = URL(string: "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest")!
    public static let clientReleaseURL = URL(string: "https://api.github.com/repos/rustdesk/rustdesk/releases/latest")!

    /// Premier numéro de version d'un texte (« hbbs 1.1.14 », « v1.4.3 ») ; nil sans chiffres.
    public static func versionNumber(_ text: String) -> String? {
        guard let range = text.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Compare deux versions numériques (« 1.1.9 » < « 1.1.14 ») ; nil si l'une est illisible.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = versionNumber(a), let y = versionNumber(b) else { return nil }
        let left = x.split(separator: ".").map { Int($0) ?? 0 }, right = y.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// « tag_name » d'une version publiée sur GitHub.
    public static func gitHubTag(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        return versionNumber(tag)
    }

    /// Empreinte (« sha256:… ») de l'étiquette « latest » sur Docker Hub.
    public static func dockerHubDigest(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let digest = object["digest"] as? String, digest.hasPrefix("sha256:") { return digest }
        return nil
    }

    /// Une vérification en ligne est due (jamais faite, ou faite il y a plus d'un jour).
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now.addingTimeInterval(300)
    }
}

/// Dernières versions publiées, lues en ligne (au clic ou une fois par jour).
public struct RustDeskPublishedVersions: Codable, Equatable, Sendable {
    public var checkedAt: Date?
    public var server: String?
    public var hubDigest: String?
    public var client: String?
    public var error: String?

    public init(checkedAt: Date? = nil, server: String? = nil, hubDigest: String? = nil, client: String? = nil, error: String? = nil) {
        self.checkedAt = checkedAt
        self.server = server
        self.hubDigest = hubDigest
        self.client = client
        self.error = error
    }
}

/// Ce qu'il y a à mettre à jour (rien n'est installé : note 88).
public enum RustDeskUpdateAssessment {
    /// - `installed` : version de hbbs (« hbbs --version », sinon étiquette de l'image ou paquet) ;
    /// - `localDigests` : empreintes de l'image locale ; `clientVersion` : client RustDesk de ce Mac.
    public static func findings(installed: String?, localDigests: [String], published: RustDeskPublishedVersions,
                                updates: RustDeskSystemUpdates?, clientVersion: String?) -> [RustDeskFinding] {
        var list: [RustDeskFinding] = []
        if let latest = published.server, let installed, RustDeskVersionCheck.compare(installed, latest) == .orderedAscending {
            list.append(RustDeskFinding(.warning, "RustDesk Server \(latest) disponible",
                                        "Installé\u{00A0}: \(installed). Image «\u{00A0}:latest\u{00A0}»\u{00A0}: «\u{00A0}docker compose pull\u{00A0}» puis «\u{00A0}docker compose up -d\u{00A0}» dans le dossier du serveur (note 88 pour le faire depuis NetScope)."))
        } else if let hub = published.hubDigest, !localDigests.isEmpty, !localDigests.contains(hub) {
            list.append(RustDeskFinding(.warning, "Nouvelle image «\u{00A0}latest\u{00A0}» sur Docker Hub",
                                        "L’empreinte de l’image locale ne correspond plus à celle de Docker Hub (\(short(hub)))."))
        }
        if let updates {
            if !updates.security.isEmpty {
                list.append(RustDeskFinding(.warning, "\(updates.security.count) correctif\(updates.security.count > 1 ? "s" : "") de sécurité à installer",
                                            updates.security.prefix(8).joined(separator: ", ") + (updates.security.count > 8 ? "…" : "")))
            } else if !updates.packages.isEmpty {
                list.append(RustDeskFinding(.info, "\(updates.packages.count) mise\(updates.packages.count > 1 ? "s" : "") à jour du système",
                                            updates.packages.prefix(8).joined(separator: ", ") + (updates.packages.count > 8 ? "…" : "")))
            }
            if updates.rebootRequired {
                list.append(RustDeskFinding(.warning, "Redémarrage requis",
                                            updates.rebootPackages.isEmpty ? "Le système demande un redémarrage." : "Demandé par " + updates.rebootPackages.prefix(5).joined(separator: ", ") + "."))
            }
        }
        if let latest = published.client, let clientVersion, RustDeskVersionCheck.compare(clientVersion, latest) == .orderedAscending {
            list.append(RustDeskFinding(.info, "Client RustDesk \(latest) disponible",
                                        "Ce Mac a la \(clientVersion). Remplacez aussi le client portable proposé sur la page d’assistance."))
        }
        return list
    }

    /// « sha256:1a2b3c4d5e6f… » → « 1a2b3c4d5e6f ».
    public static func short(_ digest: String) -> String {
        String(digest.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }
}

// MARK: - Noms et notes par ID

/// Nom et note libres d'un ID RustDesk (gardés dans NetScope, synchronisés par la note 86).
public struct RustDeskIDNote: Codable, Equatable, Sendable {
    public var name: String
    public var note: String
    public var updatedAt: Date

    public init(name: String = "", note: String = "", updatedAt: Date = Date()) {
        self.name = name
        self.note = note
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty && note.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Nom affiché d'un ID : nom donné ici, sinon carnet, sinon fiche d'inventaire.
public enum RustDeskNames {
    public enum Source: String, Sendable { case note, book, inventory }

    public static func key(_ id: String) -> String {
        RustDeskID.parse(id) ?? id.trimmingCharacters(in: .whitespaces)
    }

    public static func resolve(_ id: String, notes: [String: RustDeskIDNote], book: [String: String],
                               inventory: [String: String]) -> (name: String, source: Source)? {
        let key = key(id)
        guard !key.isEmpty else { return nil }
        if let name = notes[key]?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty { return (name, .note) }
        if let name = book[key], !name.isEmpty { return (name, .book) }
        if let name = inventory[key], !name.isEmpty { return (name, .inventory) }
        return nil
    }

    /// Carnet complet : ID → nom (notes, carnet, fiches).
    public static func merged(notes: [String: RustDeskIDNote], book: [String: String], inventory: [String: String]) -> [String: String] {
        var result = inventory
        for (id, name) in book where !name.isEmpty { result[id] = name }
        for (id, note) in notes {
            let name = note.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[id] = name }
        }
        return result
    }
}

// MARK: - Historique des demandes

/// Demande de connexion gardée jour après jour (hbbs la perd à son redémarrage).
public struct RustDeskArchivedRequest: Codable, Hashable, Sendable {
    public var date: Date
    public var fromIP: String
    public var targetID: String
    public var targetIP: String

    public init(date: Date, fromIP: String, targetID: String, targetIP: String) {
        self.date = date
        self.fromIP = fromIP
        self.targetID = targetID
        self.targetIP = targetIP
    }

    public init(_ request: RustDeskPunchRequest) {
        self.init(date: request.date, fromIP: request.fromIP, targetID: request.targetID, targetIP: request.targetIP)
    }

    var dedupeKey: String { "\(Int(date.timeIntervalSince1970))|\(fromIP)|\(targetID)" }
}

public enum RustDeskRequestArchive {
    /// Gardées 400 jours (rapport de l'année et du mois précédent), 100 000 au plus.
    public static let retention: TimeInterval = 400 * 86_400
    public static let limit = 100_000

    /// Ajoute les demandes lues (sans doublon), retire les trop vieilles ; ordre chronologique.
    public static func merge(_ existing: [RustDeskArchivedRequest], adding new: [RustDeskPunchRequest], now: Date) -> [RustDeskArchivedRequest] {
        var seen = Set(existing.map(\.dedupeKey))
        var result = existing
        for request in new.map(RustDeskArchivedRequest.init) where seen.insert(request.dedupeKey).inserted {
            result.append(request)
        }
        return trimmed(result, now: now)
    }

    /// Union de deux historiques (sans doublon), même rétention.
    public static func union(_ a: [RustDeskArchivedRequest], _ b: [RustDeskArchivedRequest], now: Date) -> [RustDeskArchivedRequest] {
        var seen = Set(a.map(\.dedupeKey))
        var result = a
        for request in b where seen.insert(request.dedupeKey).inserted { result.append(request) }
        return trimmed(result, now: now)
    }

    static func trimmed(_ list: [RustDeskArchivedRequest], now: Date) -> [RustDeskArchivedRequest] {
        var result = list
        let since = now.addingTimeInterval(-retention)
        result = result.filter { $0.date >= since && $0.date <= now.addingTimeInterval(86_400) }.sorted { $0.date < $1.date }
        return Array(result.suffix(limit))
    }
}

/// Rapport mensuel : demandes par poste et par technicien.
public struct RustDeskMonthlyReport: Equatable, Sendable {
    public struct StationRow: Equatable, Identifiable, Sendable {
        public var id: String { targetID }
        public var targetID: String
        public var name: String
        public var count: Int
        public var technicians: Int
        public var last: Date
    }

    public struct TechnicianRow: Equatable, Identifiable, Sendable {
        public var id: String { ip }
        public var ip: String
        public var label: String
        public var count: Int
        public var stations: Int
        public var last: Date
    }

    public var year: Int
    public var month: Int
    public var total: Int
    public var stations: [StationRow]
    public var technicians: [TechnicianRow]

    /// « novembre 2026 ».
    public var title: String { Self.title(year: year, month: month) }

    public static func title(year: Int, month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "LLLL yyyy"
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components).map(formatter.string) ?? "\(month)/\(year)"
    }

    /// `name` : nom de l'ID ; `technician` : nom de l'IP du technicien (sinon l'IP).
    public static func build(_ requests: [RustDeskArchivedRequest], year: Int, month: Int, calendar: Calendar = .current,
                             name: (String) -> String?, technician: (String) -> String?) -> RustDeskMonthlyReport {
        let inMonth = requests.filter {
            let parts = calendar.dateComponents([.year, .month], from: $0.date)
            return parts.year == year && parts.month == month
        }
        let byStation = Dictionary(grouping: inMonth, by: \.targetID)
        let stations = byStation.map { id, list in
            StationRow(targetID: id, name: name(id) ?? "", count: list.count, technicians: Set(list.map(\.fromIP)).count,
                       last: list.map(\.date).max() ?? .distantPast)
        }.sorted { ($0.count, $1.name.isEmpty ? $1.targetID : $1.name) > ($1.count, $0.name.isEmpty ? $0.targetID : $0.name) }
        let byTech = Dictionary(grouping: inMonth, by: \.fromIP)
        let technicians = byTech.map { ip, list in
            TechnicianRow(ip: ip, label: technician(ip) ?? ip, count: list.count, stations: Set(list.map(\.targetID)).count,
                          last: list.map(\.date).max() ?? .distantPast)
        }.sorted { ($0.count, $1.ip) > ($1.count, $0.ip) }
        return RustDeskMonthlyReport(year: year, month: month, total: inMonth.count, stations: stations, technicians: technicians)
    }

    /// Mois présents dans l'historique, le plus récent d'abord : (année, mois).
    public static func months(_ requests: [RustDeskArchivedRequest], calendar: Calendar = .current) -> [(year: Int, month: Int)] {
        var seen = Set<Int>()
        var result: [(Int, Int)] = []
        for request in requests.sorted(by: { $0.date > $1.date }) {
            let parts = calendar.dateComponents([.year, .month], from: request.date)
            guard let year = parts.year, let month = parts.month, seen.insert(year * 100 + month).inserted else { continue }
            result.append((year, month))
        }
        return result
    }

    /// CSV (séparateur « ; », UTF-8) : une section par poste, une par technicien.
    public func csv() -> String {
        func cell(_ text: String) -> String {
            text.contains(";") || text.contains("\"") || text.contains("\n") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let iso = ISO8601DateFormatter()
        var lines = ["Rapport RustDesk;\(cell(title));\(total) demandes", "", "Poste;ID;Demandes;Techniciens;Dernière"]
        for row in stations {
            lines.append([cell(row.name), row.targetID, String(row.count), String(row.technicians), iso.string(from: row.last)].joined(separator: ";"))
        }
        lines += ["", "Technicien;IP;Demandes;Postes;Dernière"]
        for row in technicians {
            lines.append([cell(row.label), row.ip, String(row.count), String(row.stations), iso.string(from: row.last)].joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Tentatives suspectes

public struct RustDeskSuspiciousEvent: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case unknownID, burst, firewallDenied }

    public var id: String { kind.rawValue + "|" + key }
    public var kind: Kind
    /// ID visé (unknownID) ou IP d'origine (burst, firewallDenied).
    public var key: String
    public var count: Int
    public var last: Date
    public var detail: String

    public init(kind: Kind, key: String, count: Int, last: Date, detail: String) {
        self.kind = kind
        self.key = key
        self.count = count
        self.last = last
        self.detail = detail
    }

    public var title: String {
        switch kind {
        case .unknownID: return "ID hors carnet\u{00A0}: \(RustDeskID.grouped(key))"
        case .burst: return "Rafale depuis \(key)"
        case .firewallDenied: return "Refusé par la FortiGate\u{00A0}: \(key)"
        }
    }
}

/// Tentative refusée par une FortiGate (journal de trafic vers les ports RustDesk).
public struct RustDeskDeniedAttempt: Equatable, Sendable {
    public var date: Date
    public var sourceIP: String
    public var port: Int
    public var country: String?
    public var site: String

    public init(date: Date, sourceIP: String, port: Int, country: String? = nil, site: String) {
        self.date = date
        self.sourceIP = sourceIP
        self.port = port
        self.country = country
        self.site = site
    }

    /// Message de trafic FortiOS refusé (« action=deny », « dstport=21116 ») vers un port RustDesk.
    public static func from(_ message: LogMessage, ports: ClosedRange<Int> = 21_114...21_119) -> RustDeskDeniedAttempt? {
        let fields = message.fields
        guard let port = fields["dstport"].flatMap(Int.init), ports.contains(port),
              let action = fields["action"]?.lowercased(), ["deny", "blocked", "block", "drop", "dropped"].contains(action),
              let source = fields["srcip"], !source.isEmpty else { return nil }
        let country = fields["srccountry"].flatMap { $0.isEmpty || $0 == "Reserved" ? nil : $0 }
        return RustDeskDeniedAttempt(date: message.date, sourceIP: source, port: port, country: country, site: message.siteName)
    }
}

public enum RustDeskSuspicion {
    /// Rafale : `burstCount` demandes ou plus depuis une même IP en `burstWindow` secondes.
    public static let burstCount = 8
    public static let burstWindow: TimeInterval = 300

    public static func evaluate(requests: [RustDeskArchivedRequest], known: Set<String>, denied: [RustDeskDeniedAttempt],
                                since: Date, burstCount: Int = burstCount, burstWindow: TimeInterval = burstWindow) -> [RustDeskSuspiciousEvent] {
        let recent = requests.filter { $0.date >= since }
        var events: [RustDeskSuspiciousEvent] = []
        var burstIPs = Set<String>()
        for (ip, list) in Dictionary(grouping: recent, by: \.fromIP) {
            let dates = list.map(\.date).sorted()
            var best = 0, start = 0
            for end in dates.indices {
                while dates[end].timeIntervalSince(dates[start]) > burstWindow { start += 1 }
                best = max(best, end - start + 1)
            }
            guard best >= burstCount else { continue }
            burstIPs.insert(ip)
            let ids = Set(list.map(\.targetID))
            let unknown = ids.filter { !known.contains(RustDeskNames.key($0)) }.count
            events.append(RustDeskSuspiciousEvent(kind: .burst, key: ip, count: best, last: dates.last ?? since,
                                                  detail: "\(best) demandes en \(Int(burstWindow / 60))\u{00A0}min, \(ids.count) ID visé\(ids.count > 1 ? "s" : "")"
                                                      + (unknown > 0 ? " dont \(unknown) hors carnet" : "")))
        }
        // ID hors carnet : seulement ceux demandés hors d'une rafale (déjà signalée en une ligne).
        for (id, list) in Dictionary(grouping: recent.filter { !burstIPs.contains($0.fromIP) }, by: \.targetID)
        where !known.contains(RustDeskNames.key(id)) {
            let ips = Set(list.map(\.fromIP)).sorted()
            events.append(RustDeskSuspiciousEvent(kind: .unknownID, key: id, count: list.count, last: list.map(\.date).max() ?? since,
                                                  detail: "\(list.count) demande\(list.count > 1 ? "s" : "") depuis " + ips.prefix(3).joined(separator: ", ")))
        }
        for (ip, list) in Dictionary(grouping: denied.filter { $0.date >= since }, by: \.sourceIP) {
            let ports = Set(list.map(\.port)).sorted().map(String.init).joined(separator: ", ")
            let country = list.compactMap(\.country).first.map { " · \($0)" } ?? ""
            let sites = Set(list.map(\.site)).sorted().joined(separator: ", ")
            events.append(RustDeskSuspiciousEvent(kind: .firewallDenied, key: ip, count: list.count, last: list.map(\.date).max() ?? since,
                                                  detail: "\(list.count) refus · port\(ports.contains(",") ? "s" : "") \(ports)\(country) · \(sites)"))
        }
        let order: [RustDeskSuspiciousEvent.Kind: Int] = [.burst: 0, .firewallDenied: 1, .unknownID: 2]
        return events.sorted { (order[$0.kind] ?? 9, $1.last) < (order[$1.kind] ?? 9, $0.last) }
    }
}

// MARK: - Site probable et association à une fiche

public enum RustDeskSiteHint {
    /// Site dont une FortiGate a cette adresse WAN (indice seulement : plusieurs sites peuvent
    /// partager une IP ; dans ce cas, aucun site n'est proposé).
    public static func site(for ip: String, wan: [(site: String, ip: String)]) -> String? {
        let sites = Set(wan.filter { $0.ip == ip }.map(\.site))
        return sites.count == 1 ? sites.first : nil
    }

    /// Adresse privée (RFC 1918, CGNAT) : le poste est sur un réseau local.
    public static func isPrivate(_ ip: String) -> Bool {
        guard let address = IPv4Address(ip) else { return false }
        let b = address.octets
        return b.0 == 10 || (b.0 == 172 && (16...31).contains(b.1)) || (b.0 == 192 && b.1 == 168) || (b.0 == 100 && (64...127).contains(b.1))
    }
}

/// Poste proposé pour un ID : jamais associé sans confirmation.
public struct RustDeskAssociationCandidate: Equatable, Identifiable, Sendable {
    public var id: String { ip + "|" + (mac ?? "") }
    public var ip: String
    public var mac: String?
    public var name: String
    public var reason: String
    /// Session relayée en cours (21117) : indice plus fort qu'une simple inscription (21116).
    public var relay: Bool
    /// Site déduit par le WAN de la FortiGate (IP publique) ; nil : site actif (IP privée).
    public var site: String?

    public init(ip: String, mac: String?, name: String, reason: String, relay: Bool = false, site: String? = nil) {
        self.ip = ip
        self.mac = mac
        self.name = name
        self.reason = reason
        self.relay = relay
        self.site = site
    }

    /// Association permise seulement avec une MAC (la fiche est retrouvée par elle, jamais par
    /// l'IP) et dans le site ouvert ; sinon, simple indice.
    public func canAssociate(activeSite: String?) -> Bool {
        guard let mac, MACAddress(mac) != nil else { return false }
        return site == nil || site == activeSite
    }
}

public enum RustDeskAssociation {
    /// Ports parlés par les postes au serveur : 21116 (hbbs, inscription) et 21117 (hbbr, relais).
    public static let ports: Set<Int> = [21_116, 21_117]

    /// Postes proposés pour l'IP vue par hbbs (`targetIP`) :
    /// - IP privée : le poste du dernier scan qui a cette IP (même réseau que le serveur) ;
    /// - IP publique : site probable par le WAN, puis postes internes de ce site qui parlent au
    ///   serveur (`serverIPs`) dans la table des sessions de sa FortiGate ; MAC par `lookup`.
    public static func candidates(targetIP: String, serverIPs: Set<String>, wan: [(site: String, ip: String)],
                                  sessions: [TrafficSession], lookup: (String, String?) -> (mac: String?, name: String)?) -> [RustDeskAssociationCandidate] {
        if RustDeskSiteHint.isPrivate(targetIP) {
            guard let found = lookup(targetIP, nil) else { return [] }
            return [RustDeskAssociationCandidate(ip: targetIP, mac: found.mac, name: found.name, reason: "même IP au dernier scan")]
        }
        guard let site = RustDeskSiteHint.site(for: targetIP, wan: wan) else { return [] }
        var seen: [String: RustDeskAssociationCandidate] = [:]
        for session in sessions where session.site == site {
            guard let source = session.source?.description, let destination = session.destination?.description,
                  let port = session.destinationPort, ports.contains(port), serverIPs.contains(destination),
                  RustDeskSiteHint.isPrivate(source) else { continue }
            let found = lookup(source, site)
            let relay = port == 21_117
            var candidate = seen[source] ?? RustDeskAssociationCandidate(
                ip: source, mac: found?.mac, name: found?.name ?? source,
                reason: "session FortiGate de \(site) vers le serveur", relay: relay, site: site)
            if relay {
                candidate.relay = true
                candidate.reason = "session relayée (21117) sur la FortiGate de \(site)"
            }
            seen[source] = candidate
        }
        return seen.values.sorted { ($0.relay ? 0 : 1, $0.ip) < ($1.relay ? 0 : 1, $1.ip) }
    }
}

// MARK: - Alertes

public enum RustDeskServerAlerts {
    /// Ports surveillés par défaut (21118 et 21119, WebSocket, souvent fermés : pas d'alerte).
    public static let defaultPorts = [21_115, 21_116, 21_117]
    /// Sauvegarde jugée récente : 7 jours.
    public static let backupMaxAge: TimeInterval = 7 * 86_400

    /// « 21115, 21116 21117 » → ports valides, triés, sans doublon.
    public static func ports(_ text: String) -> [Int] {
        Array(Set(text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { Int($0) }
            .filter { (1...65_535).contains($0) })).sorted()
    }

    /// Problèmes d'une lecture : hbbs ou hbbr arrêté, disque plein, clé changée.
    public static func problems(_ status: RustDeskServerStatus, knownKey: String?, diskLimitPercent: Double = 90) -> [String] {
        var list: [String] = []
        if !status.hbbsRunning { list.append("hbbs arrêté") }
        if !status.hbbrRunning { list.append("hbbr arrêté") }
        if let disk = status.disk, disk.usedFraction * 100 > diskLimitPercent {
            list.append("disque à \(Int((disk.usedFraction * 100).rounded()))\u{00A0}%")
        }
        if let key = status.publicKey.value, let knownKey, !knownKey.isEmpty, key != knownKey {
            list.append("clé publique changée")
        }
        return list
    }

    /// Sauvegarde à faire : aucune, ou la dernière a plus de `backupMaxAge`.
    public static func backupDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) > backupMaxAge
    }
}

// MARK: - Copie chiffrée

/// Copie du dossier de données chiffrée (AES-GCM 256 bits, clé au Trousseau du Mac).
public enum RustDeskBackupCrypto {
    static let magic = Data("NSRDB1\n".utf8)

    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func seal(_ data: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw CocoaError(.coderInvalidValue) }
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key))
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return magic + combined
    }

    public static func open(_ data: Data, key: Data) throws -> Data {
        guard key.count == 32, data.starts(with: magic) else { throw CocoaError(.coderReadCorrupt) }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    /// « rustdesk-serveur-2026-11-06-1405.tar.gz.chiffre ».
    public static func fileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "rustdesk-serveur-\(formatter.string(from: date)).tar.gz.chiffre"
    }
}

// MARK: - Fichier du suivi

/// Fichier « rustdesk-serveur-suivi.json » (synchronisé, note 86) : noms et notes, historique,
/// clé connue, sauvegardes, versions publiées, ports surveillés, noms des techniciens. Aucun secret.
public struct RustDeskWatchStore: Sendable {
    public struct Contents: Codable, Equatable, Sendable {
        public var version = 1
        public var notes: [String: RustDeskIDNote] = [:]
        /// IP du technicien → nom.
        public var technicians: [String: String] = [:]
        public var history: [RustDeskArchivedRequest] = []
        public var knownKey: String?
        public var keyChangedAt: Date?
        public var backups: [Date] = []
        public var published = RustDeskPublishedVersions()
        public var monitoredPorts: [Int] = RustDeskServerAlerts.defaultPorts
        /// Note 88 (0.33.1) : actions faites sur le serveur (à la main ou planifiées), récentes d'abord.
        public var actions: [RustDeskActionRecord] = []
        /// Note 88 (0.33.1) : mise à jour planifiée (un seul Mac l'exécute).
        public var schedule = RustDeskUpdateSchedule()

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case version, notes, technicians, history, knownKey, keyChangedAt, backups, published, monitoredPorts, actions, schedule
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            notes = ((try? c.decodeIfPresent([String: RustDeskIDNote].self, forKey: .notes)) ?? nil) ?? [:]
            technicians = ((try? c.decodeIfPresent([String: String].self, forKey: .technicians)) ?? nil) ?? [:]
            history = ((try? c.decodeIfPresent([RustDeskArchivedRequest].self, forKey: .history)) ?? nil) ?? []
            knownKey = (try? c.decodeIfPresent(String.self, forKey: .knownKey)) ?? nil
            keyChangedAt = (try? c.decodeIfPresent(Date.self, forKey: .keyChangedAt)) ?? nil
            backups = ((try? c.decodeIfPresent([Date].self, forKey: .backups)) ?? nil) ?? []
            published = ((try? c.decodeIfPresent(RustDeskPublishedVersions.self, forKey: .published)) ?? nil) ?? RustDeskPublishedVersions()
            let ports = ((try? c.decodeIfPresent([Int].self, forKey: .monitoredPorts)) ?? nil) ?? RustDeskServerAlerts.defaultPorts
            monitoredPorts = ports.filter { (1...65_535).contains($0) }
            actions = ((try? c.decodeIfPresent([RustDeskActionRecord].self, forKey: .actions)) ?? nil) ?? []
            schedule = ((try? c.decodeIfPresent(RustDeskUpdateSchedule.self, forKey: .schedule)) ?? nil) ?? RustDeskUpdateSchedule()
        }

        /// Clé lue : la première devient la clé connue ; une autre marque le changement (alerte
        /// jusqu'à ce que l'utilisateur accepte la nouvelle).
        public mutating func observeKey(_ key: String?, now: Date) {
            guard let key, !key.isEmpty else { return }
            if knownKey == nil {
                knownKey = key
            } else if knownKey != key, keyChangedAt == nil {
                keyChangedAt = now
            }
        }
    }

    /// Note 86 : fusion à trois (fichier synchronisé par plusieurs Mac). `base` : contenu lu ou
    /// écrit en dernier par ce Mac ; `local` : contenu en mémoire ; `disk` : fichier actuel (peut-être
    /// écrit par un autre Mac). Ce qui a changé ici depuis `base` l'emporte ; le reste vient du
    /// disque. Historique et sauvegardes : union. Note changée des deux côtés : la plus récente.
    public static func merge(local: Contents, base: Contents, disk: Contents, now: Date) -> Contents {
        func threeWay<V: Equatable>(_ l: [String: V], _ b: [String: V], _ d: [String: V],
                                    both: (V?, V?) -> V? = { l, _ in l }) -> [String: V] {
            var result: [String: V] = [:]
            for key in Set(l.keys).union(b.keys).union(d.keys) {
                let localChanged = l[key] != b[key], diskChanged = d[key] != b[key]
                result[key] = localChanged ? (diskChanged ? both(l[key], d[key]) : l[key]) : d[key]
            }
            return result
        }
        var merged = disk
        merged.notes = threeWay(local.notes, base.notes, disk.notes) { l, d in
            guard let l, let d else { return l ?? d }
            return l.updatedAt >= d.updatedAt ? l : d
        }
        merged.technicians = threeWay(local.technicians, base.technicians, disk.technicians)
        merged.history = RustDeskRequestArchive.union(local.history, disk.history, now: now)
        merged.backups = Array(Set(local.backups).union(disk.backups).sorted().suffix(50))
        if local.knownKey != base.knownKey || local.keyChangedAt != base.keyChangedAt {
            merged.knownKey = local.knownKey
            merged.keyChangedAt = local.keyChangedAt
        }
        if (local.published.checkedAt ?? .distantPast) > (disk.published.checkedAt ?? .distantPast) {
            merged.published = local.published
        }
        if local.monitoredPorts != base.monitoredPorts { merged.monitoredPorts = local.monitoredPorts }
        merged.actions = RustDeskActionRecord.union(local.actions, disk.actions)
        if local.schedule != base.schedule { merged.schedule = local.schedule }
        return merged
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static let fileName = "rustdesk-serveur-suivi.json"

    public static var standard: RustDeskWatchStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return RustDeskWatchStore(url: base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent(fileName))
    }

    public func load() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Contents.self, from: data)
    }

    public func save(_ contents: Contents) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
