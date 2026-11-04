import Foundation

/// Page d'état illisible.
public enum SvcParseError: Error, LocalizedError, Equatable, Sendable {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let text): return "Page d’état illisible\u{00A0}: \(text)"
        }
    }
}

/// Analyseurs des formats publics de pages d'état (purs, testés avec des réponses fixes).
public enum SvcFeedParser {
    /// Lit la réponse de la page d'état d'un service selon son format.
    public static func parse(_ data: Data, service: SvcService, now: Date) throws -> SvcFeedReport {
        switch service.format {
        case .statuspage: return try statuspage(data)
        case .slack: return try slack(data, pageURL: service.pageURL)
        case .apple: return try apple(data, pageURL: service.pageURL)
        case .awsHealth: return try awsHealth(data, pageURL: service.pageURL)
        case .azureRSS: return try rss(data, pageURL: service.pageURL, now: now, allActive: true)
        case .googleIncidents: return try google(data, pageURL: service.pageURL, now: now)
        case .microsoft365: return try microsoft365(data, pageURL: service.pageURL)
        case .rss: return try rss(data, pageURL: service.pageURL, now: now, allActive: false)
        case .none: throw SvcParseError.unreadable("aucun format")
        }
    }

    // MARK: Atlassian Statuspage (/api/v2/summary.json)

    public static func statuspage(_ data: Data) throws -> SvcFeedReport {
        let root = try object(data)
        guard let status = root["status"] as? [String: Any] else {
            throw SvcParseError.unreadable("champ «\u{00A0}status\u{00A0}» absent (summary.json attendu)")
        }
        let page = root["page"] as? [String: Any]
        let pageURL = page?["url"] as? String
        var components: [SvcComponent] = []
        for item in root["components"] as? [[String: Any]] ?? [] {
            guard (item["group"] as? Bool) != true, let name = item["name"] as? String else { continue }
            let health = componentHealth(item["status"] as? String)
            if health != .operational { components.append(SvcComponent(name: name, health: health)) }
        }
        var incidents: [SvcIncident] = []
        for item in root["incidents"] as? [[String: Any]] ?? [] {
            if let incident = statuspageIncident(item, pageURL: pageURL, maintenance: false) { incidents.append(incident) }
        }
        for item in root["scheduled_maintenances"] as? [[String: Any]] ?? [] {
            let state = (item["status"] as? String) ?? ""
            guard state == "in_progress" || state == "verifying" else { continue }
            if let incident = statuspageIncident(item, pageURL: pageURL, maintenance: true) { incidents.append(incident) }
        }
        var health: SvcHealth
        switch (status["indicator"] as? String) ?? "none" {
        case "critical", "major": health = .outage
        case "minor": health = .degraded
        case "maintenance": health = .maintenance
        default: health = .operational
        }
        health = max(health, components.map(\.health).max() ?? .operational,
                     incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational)
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents),
                             incidents: incidents, components: components)
    }

    static func componentHealth(_ status: String?) -> SvcHealth {
        switch status {
        case "operational": return .operational
        case "degraded_performance": return .degraded
        case "partial_outage", "major_outage": return .outage
        case "under_maintenance": return .maintenance
        default: return .unknown
        }
    }

    private static func statuspageIncident(_ item: [String: Any], pageURL: String?, maintenance: Bool) -> SvcIncident? {
        guard let title = item["name"] as? String else { return nil }
        let id = (item["id"] as? String) ?? title
        let state = (item["status"] as? String) ?? ""
        let impact: SvcHealth
        if maintenance {
            impact = .maintenance
        } else {
            switch (item["impact"] as? String) ?? "" {
            case "critical", "major": impact = .outage
            case "maintenance": impact = .maintenance
            default: impact = .degraded
            }
        }
        let updates = item["incident_updates"] as? [[String: Any]] ?? []
        let affected = (item["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let link = (item["shortlink"] as? String) ?? pageURL.map { $0 + "/incidents/" + id }
        return SvcIncident(id: id, title: title, impact: impact, status: statuspageStatus(state), affected: affected,
                           started: date(item["started_at"]) ?? date(item["created_at"]) ?? date(item["scheduled_for"]),
                           updated: date(item["updated_at"]), url: link,
                           latestUpdate: (updates.first?["body"] as? String).map(plainText),
                           isResolved: ["resolved", "postmortem", "completed"].contains(state))
    }

    static func statuspageStatus(_ state: String) -> String {
        switch state {
        case "investigating": return "En cours d’analyse"
        case "identified": return "Cause identifiée"
        case "monitoring": return "Sous surveillance"
        case "resolved": return "Résolu"
        case "postmortem": return "Analyse publiée"
        case "in_progress": return "Maintenance en cours"
        case "verifying": return "Vérification"
        case "scheduled": return "Planifiée"
        case "completed": return "Terminée"
        default: return state.isEmpty ? "—" : state
        }
    }

    // MARK: Slack (slack-status.com/api/v2.0.0/current)

    public static func slack(_ data: Data, pageURL: String) throws -> SvcFeedReport {
        let root = try object(data)
        guard let state = root["status"] as? String else {
            throw SvcParseError.unreadable("champ «\u{00A0}status\u{00A0}» absent (API Slack attendue)")
        }
        var incidents: [SvcIncident] = []
        for item in root["active_incidents"] as? [[String: Any]] ?? [] {
            guard let title = item["title"] as? String else { continue }
            let id = stringValue(item["id"]) ?? title
            let impact: SvcHealth
            switch (item["type"] as? String) ?? "" {
            case "outage": impact = .outage
            case "notice": impact = .maintenance
            default: impact = .degraded
            }
            let notes = item["notes"] as? [[String: Any]] ?? []
            let itemState = (item["status"] as? String) ?? "active"
            incidents.append(SvcIncident(
                id: id, title: title, impact: impact,
                status: itemState == "resolved" ? "Résolu" : itemState == "scheduled" ? "Planifiée" : "En cours",
                affected: item["services"] as? [String] ?? [],
                started: date(item["date_created"]), updated: date(item["date_updated"]),
                url: (item["url"] as? String) ?? pageURL,
                latestUpdate: (notes.last?["body"] as? String).map(plainText),
                isResolved: itemState == "resolved"))
        }
        var health = incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational
        if state != "ok", health == .operational { health = .degraded }
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents), incidents: incidents)
    }

    // MARK: Apple System Status (system_status_*.js)

    public static func apple(_ data: Data, pageURL: String) throws -> SvcFeedReport {
        // Le fichier est parfois enveloppé : « jsonCallback({…}); ».
        var payload = data
        if let text = String(data: data, encoding: .utf8), let open = text.firstIndex(of: "{"),
           let close = text.lastIndex(of: "}"), open < close, !text.hasPrefix("{") {
            payload = Data(text[open...close].utf8)
        }
        let root = try object(payload)
        guard let services = root["services"] as? [[String: Any]] else {
            throw SvcParseError.unreadable("champ «\u{00A0}services\u{00A0}» absent (Apple System Status attendu)")
        }
        var incidents: [SvcIncident] = []
        for service in services {
            let name = (service["serviceName"] as? String) ?? "Service Apple"
            for event in service["events"] as? [[String: Any]] ?? [] {
                let state = ((event["eventStatus"] as? String) ?? "").lowercased()
                guard state == "ongoing" || state == "resolved" || state == "completed" else { continue }
                let impact: SvcHealth
                switch ((event["statusType"] as? String) ?? "").lowercased() {
                case "outage": impact = .outage
                case "maintenance": impact = .maintenance
                default: impact = .degraded
                }
                let message = (event["message"] as? String).map(plainText)
                let users = (event["usersAffected"] as? String).map(plainText)
                let id = stringValue(event["messageId"]) ?? "\(name)-\(stringValue(event["epochStartDate"]) ?? "")"
                incidents.append(SvcIncident(
                    id: id, title: "\(name)\u{00A0}: " + appleType(impact), impact: impact,
                    status: state == "ongoing" ? "En cours" : "Résolu",
                    affected: [name], started: epoch(event["epochStartDate"], milliseconds: true),
                    updated: epoch(event["epochEndDate"], milliseconds: true) ?? epoch(event["epochStartDate"], milliseconds: true),
                    url: pageURL,
                    latestUpdate: [users, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
                    isResolved: state != "ongoing"))
            }
        }
        let health = incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents), incidents: incidents)
    }

    private static func appleType(_ impact: SvcHealth) -> String {
        switch impact {
        case .outage: return "panne"
        case .maintenance: return "maintenance"
        default: return "problème"
        }
    }

    // MARK: AWS Health (public/currentevents)

    public static func awsHealth(_ data: Data, pageURL: String) throws -> SvcFeedReport {
        let payload = utf8Payload(data)
        let parsed = try json(payload)
        let events: [[String: Any]]
        if let array = parsed as? [[String: Any]] {
            events = array
        } else if let root = parsed as? [String: Any], let array = root["current"] as? [[String: Any]] {
            events = array
        } else if (parsed as? [Any])?.isEmpty == true {
            events = []
        } else {
            throw SvcParseError.unreadable("liste d’événements attendue (AWS Health)")
        }
        var incidents: [SvcIncident] = []
        for event in events {
            let summary = (event["summary"] as? String).map(plainText) ?? "Événement AWS"
            let status = stringValue(event["status"]) ?? "1"
            let resolved = status == "0" || summary.uppercased().hasPrefix("[RESOLVED]")
            let impact: SvcHealth = status == "3" ? .outage : .degraded
            let log = event["event_log"] as? [[String: Any]] ?? []
            let lastLog = log.max { (epoch($0["timestamp"]) ?? .distantPast) < (epoch($1["timestamp"]) ?? .distantPast) }
            let affected = [event["service_name"] as? String, event["region_name"] as? String].compactMap { $0 }
            let id = [stringValue(event["service"]), stringValue(event["date"])].compactMap { $0 }.joined(separator: "-")
            incidents.append(SvcIncident(
                id: id.isEmpty ? summary : id, title: summary, impact: impact,
                status: resolved ? "Résolu" : status == "1" ? "Information" : "En cours",
                affected: affected.isEmpty ? [] : [affected.joined(separator: " · ")],
                started: epoch(event["date"]), updated: lastLog.flatMap { epoch($0["timestamp"]) } ?? epoch(event["date"]),
                url: pageURL, latestUpdate: (lastLog?["message"] as? String).map(plainText), isResolved: resolved))
        }
        let health = incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents), incidents: incidents)
    }

    /// AWS sert ce fichier en UTF-16 (avec BOM) : converti en UTF-8.
    static func utf8Payload(_ data: Data) -> Data {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE], let text = String(data: data, encoding: .utf16LittleEndian) {
            return Data(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8)
        }
        if bytes == [0xFE, 0xFF], let text = String(data: data, encoding: .utf16BigEndian) {
            return Data(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return data.dropFirst(3) }
        return data
    }

    // MARK: Google Workspace et Google Cloud (incidents.json)

    /// Incidents en cours (sans fin) et résolus des 7 derniers jours (historique).
    public static func google(_ data: Data, pageURL: String, now: Date) throws -> SvcFeedReport {
        guard let items = try json(data) as? [[String: Any]] else {
            if (try? json(data) as? [Any])?.isEmpty == true {
                return SvcFeedReport(health: .operational, description: describe(health: .operational, incidents: []))
            }
            throw SvcParseError.unreadable("liste d’incidents attendue (incidents.json)")
        }
        var incidents: [SvcIncident] = []
        let base = pageURL.hasSuffix("/") ? pageURL : pageURL + "/"
        for item in items {
            let end = date(item["end"])
            if let end, now.timeIntervalSince(end) > 7 * 86_400 { continue }
            let impact: SvcHealth
            switch (item["status_impact"] as? String) ?? "" {
            case "SERVICE_OUTAGE": impact = .outage
            default: impact = .degraded
            }
            let products = (item["affected_products"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            let recent = item["most_recent_update"] as? [String: Any]
            let title = (item["external_desc"] as? String).map { plainText(firstLine($0)) } ?? "Incident Google"
            let uri = item["uri"] as? String
            let link = uri.map { $0.hasPrefix("http") ? $0 : base + $0 } ?? pageURL
            let id = stringValue(item["id"]) ?? stringValue(item["number"]) ?? title
            let recentState = ((recent?["status"] as? String) ?? "").uppercased()
            incidents.append(SvcIncident(
                id: id, title: firstLine(title), impact: impact,
                status: end != nil ? "Résolu" : googleStatus(recentState),
                affected: products.isEmpty ? [(item["service_name"] as? String) ?? "Google"] : products,
                started: date(item["begin"]) ?? date(item["created"]), updated: date(item["modified"]),
                url: link, latestUpdate: (recent?["text"] as? String).map(plainText), isResolved: end != nil))
        }
        let health = incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents), incidents: incidents)
    }

    private static func googleStatus(_ state: String) -> String {
        switch state {
        case "SERVICE_OUTAGE": return "Panne"
        case "SERVICE_DISRUPTION": return "Perturbation"
        case "SERVICE_INFORMATION": return "Information"
        case "AVAILABLE": return "Rétabli"
        default: return "En cours"
        }
    }

    // MARK: Flux RSS et Atom (Azure Status, autres)

    /// `allActive` : chaque élément est un incident en cours (Azure ne publie que ceux-là) ; sinon,
    /// éléments des dernières 24 h en cours (sauf mention de résolution), plus anciens en historique (7 jours).
    public static func rss(_ data: Data, pageURL: String, now: Date, allActive: Bool) throws -> SvcFeedReport {
        let items = try SvcRSSReader.items(data)
        var incidents: [SvcIncident] = []
        for item in items {
            let title = plainText(item.title)
            guard !title.isEmpty else { continue }
            let when = item.date.flatMap(rssDate)
            let age = when.map { now.timeIntervalSince($0) } ?? 0
            if !allActive, age > 7 * 86_400 { continue }
            let lowered = (title + " " + item.description).lowercased()
            let resolvedWords = ["resolved", "résolu", "operating normally", "mitigated", "rétabli"]
            let resolved = !allActive && (age > 86_400 || resolvedWords.contains { lowered.contains($0) })
            let outageWords = ["outage", "unavailable", "disruption", "panne", "interruption"]
            let impact: SvcHealth = outageWords.contains { lowered.contains($0) } ? .outage : .degraded
            incidents.append(SvcIncident(
                id: item.guid.isEmpty ? title + (item.date ?? "") : item.guid, title: firstLine(title), impact: impact,
                status: resolved ? "Résolu" : "En cours", affected: item.category.isEmpty ? [] : [item.category],
                started: when, updated: when, url: item.link.isEmpty ? pageURL : item.link,
                latestUpdate: item.description.isEmpty ? nil : plainText(item.description), isResolved: resolved))
        }
        let health = incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents), incidents: incidents)
    }

    // MARK: Microsoft 365 (page publique status.cloud.microsoft)

    /// Lecture tolérante : liste de publications (tableau racine, ou premier tableau d'objets du
    /// document), clés reconnues sans tenir compte de la casse.
    public static func microsoft365(_ data: Data, pageURL: String) throws -> SvcFeedReport {
        let parsed = try json(data)
        let posts: [[String: Any]]
        if let array = parsed as? [[String: Any]] {
            posts = array
        } else if let root = parsed as? [String: Any] {
            let lowered = Dictionary(root.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            let preferred = ["value", "posts", "incidents", "items", "data"].compactMap { lowered[$0] as? [[String: Any]] }.first
            posts = preferred ?? root.values.compactMap { $0 as? [[String: Any]] }.first ?? []
        } else {
            posts = []
        }
        var incidents: [SvcIncident] = []
        for raw in posts {
            let post = Dictionary(raw.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            func text(_ keys: [String]) -> String? {
                for key in keys { if let value = stringValue(post[key]), !value.isEmpty { return value } }
                return nil
            }
            guard let title = text(["title", "name", "subject", "impactdescription"]) else { continue }
            let state = text(["status", "state"]) ?? ""
            let services: [String]
            if let list = (post["impactedservices"] ?? post["services"] ?? post["workloads"]) as? [String] {
                services = list
            } else {
                services = [text(["service", "workload", "workloaddisplayname"])].compactMap { $0 }
            }
            let resolvedFlag = (post["isresolved"] as? Bool) ?? false
            let lowered = state.lowercased()
            let resolved = resolvedFlag || ["resolved", "restored", "serviceoperational", "falsepositive"].contains { lowered.contains($0) }
            let impact: SvcHealth = lowered.contains("interruption") || lowered.contains("outage") ? .outage : .degraded
            incidents.append(SvcIncident(
                id: text(["id", "incidentid", "postid"]) ?? title, title: plainText(title), impact: impact,
                status: resolved ? "Résolu" : SvcGraph.statusLabel(state), affected: services,
                started: date(post["starttime"] ?? post["startdatetime"] ?? post["publisheddate"] ?? post["created"]),
                updated: date(post["lastupdatedtime"] ?? post["lastmodifieddatetime"] ?? post["updated"]),
                url: text(["url", "link"]) ?? pageURL,
                latestUpdate: text(["message", "description", "impactdescription"]).map(plainText),
                isResolved: resolved))
        }
        let health = incidents.filter { !$0.isResolved }.map(\.impact).max() ?? .operational
        return SvcFeedReport(health: health, description: describe(health: health, incidents: incidents), incidents: incidents)
    }

    // MARK: Outils communs

    /// « Aucun incident en cours », « 1 incident en cours », « 2 incidents en cours ».
    public static func describe(health: SvcHealth, incidents: [SvcIncident]) -> String {
        let active = incidents.filter { !$0.isResolved }
        if active.isEmpty {
            return health == .operational ? "Aucun incident en cours" : health.label
        }
        let maintenance = active.allSatisfy { $0.impact == .maintenance }
        if maintenance { return active.count == 1 ? "1 maintenance en cours" : "\(active.count) maintenances en cours" }
        return active.count == 1 ? "1 incident en cours" : "\(active.count) incidents en cours"
    }

    static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let start = String(decoding: data.prefix(40), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SvcParseError.unreadable(start.hasPrefix("<") ? "page HTML au lieu du JSON attendu" : "JSON invalide")
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try json(data) as? [String: Any] else {
            throw SvcParseError.unreadable("objet JSON attendu")
        }
        return root
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Dates ISO 8601 (avec ou sans fractions de seconde), époque en secondes.
    static func date(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: trimmed) { return date }
            }
            if let seconds = Double(trimmed) { return Date(timeIntervalSince1970: seconds) }
            return nil
        }
        return epoch(value)
    }

    static func epoch(_ value: Any?, milliseconds: Bool = false) -> Date? {
        let number: Double?
        switch value {
        case let text as String: number = Double(text)
        case let value as NSNumber: number = value.doubleValue
        default: number = nil
        }
        guard let number, number > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds ? number / 1000 : number)
    }

    /// Dates RSS (RFC 822) et Atom (ISO 8601).
    static func rssDate(_ text: String) -> Date? {
        if let iso = date(text) { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz",
                       "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return date }
        }
        return nil
    }

    /// Texte brut : balises HTML retirées, entités courantes décodées, espaces resserrés, 400 caractères au plus.
    public static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                        "&rsquo;": "’", "&lsquo;": "‘", "&ndash;": "–", "&mdash;": "—"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 400 { text = String(text.prefix(399)) + "…" }
        return text
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

/// Lecteur minimal de flux RSS 2.0 et Atom (XMLParser de Foundation).
enum SvcRSSReader {
    struct Item {
        var title = ""
        var link = ""
        var date: String?
        var description = ""
        var guid = ""
        var category = ""
    }

    static func items(_ data: Data) throws -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || !delegate.items.isEmpty else {
            throw SvcParseError.unreadable("flux RSS invalide")
        }
        guard delegate.sawFeed else { throw SvcParseError.unreadable("flux RSS ou Atom attendu") }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        var sawFeed = false
        private var current: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let element = name.lowercased()
            if element == "rss" || element == "feed" || element == "rdf:rdf" { sawFeed = true }
            if element == "item" || element == "entry" { current = Item() }
            if element == "link", current != nil, let href = attributes["href"], current?.link.isEmpty == true {
                current?.link = href
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current != nil else { return }
            switch element {
            case "title": current?.title = value
            case "link": if !value.isEmpty { current?.link = value }
            case "pubdate", "updated", "published", "dc:date": if current?.date == nil { current?.date = value }
            case "description", "summary", "content": if current?.description.isEmpty == true { current?.description = value }
            case "guid", "id": current?.guid = value
            case "category": if current?.category.isEmpty == true { current?.category = value }
            case "item", "entry":
                if let item = current { items.append(item) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
