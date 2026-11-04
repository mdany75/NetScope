import Foundation

// Note 54 : lecture tolérante des réponses FortiView et des sessions (FortiOS 6.4 à 7.6). Les
// lignes sont dans « results », « results.details », « details » ou une simple liste ; les noms
// des champs varient (« srcaddr », « source », « saddr » ; « sentbyte », « tx_bytes »…) ; les
// nombres arrivent en nombre ou en texte, parfois avec une unité (« 12.5 Mbps »). Fonctions pures.

public enum TrafficParsers {
    /// Lignes d'une réponse FortiView (liste utile, quelle que soit l'enveloppe).
    static func rows(_ json: Any?) -> [FortiObject] {
        let inner = FortiJSON.results(json)
        if let dict = inner as? [String: Any] {
            let object = FortiObject(dict)
            for name in ["details", "detail", "data", "entries", "list", "rows", "items", "sessions"] {
                if let value = object.value([name]) {
                    if let list = value as? [Any] { return FortiJSON.objects(list) }
                    if let nested = value as? [String: Any] { return rows(nested) }
                }
            }
            // Objet sans liste : « summary » seul (aucune ligne).
            if object.value(["summary"]) != nil, dict.count <= 3 { return [] }
        }
        if inner is [Any] { return FortiJSON.objects(inner) }
        return []
    }

    // MARK: Nombres

    static func bytes(_ object: FortiObject, _ names: [String]) -> UInt64? {
        guard let value = object.value(names) else { return nil }
        if let d = FortiJSON.double(value), d.isFinite, d >= 0 { return d >= 1.8e19 ? .max : UInt64(d.rounded()) }
        return nil
    }

    /// Débit en bits par seconde : nombre (b/s), ou texte avec unité (« 12.5 Mbps », « 800 kb/s »).
    static func bitsPerSecond(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !(value is Bool) {
            let d = n.doubleValue
            return d.isFinite && d >= 0 ? d : nil
        }
        guard let text = FortiJSON.string(value)?.lowercased().replacingOccurrences(of: ",", with: ".") else { return nil }
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(number), amount >= 0 else { return nil }
        let rest = text.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("g") { return amount * 1e9 }
        if rest.hasPrefix("m") { return amount * 1e6 }
        if rest.hasPrefix("k") { return amount * 1e3 }
        return amount
    }

    /// Risque d'une application, sur l'échelle FortiGuard : 1 Low, 2 Elevated, 3 Medium, 4 High,
    /// 5 Critical (le texte et le nombre donnent la même valeur, quelle que soit la version).
    static func risk(_ value: Any?) -> Int? {
        if let text = FortiJSON.string(value)?.lowercased(), Int(text) == nil {
            if text.hasPrefix("crit") { return 5 }
            // « élevé » (français) : High ; « elevated » (anglais, sans accent) : Elevated.
            if text.hasPrefix("high") || text.hasPrefix("élev") { return 4 }
            if text.hasPrefix("med") || text.hasPrefix("moy") { return 3 }
            if text.hasPrefix("elev") || text.hasPrefix("mod") { return 2 }
            if text.hasPrefix("low") || text.hasPrefix("faib") { return 1 }
            return nil
        }
        guard let n = FortiJSON.int(value), n > 0 else { return nil }
        return min(5, n)
    }

    // MARK: Vues FortiView

    /// Lignes d'une vue ; nil si le corps n'est pas du JSON.
    public static func entries(_ data: Data, view: TrafficView, site: String = "") -> [TrafficEntry]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [TrafficEntry] = []
        var seen: [String: Int] = [:]
        for row in rows(json) {
            guard var entry = entry(row, view: view, site: site) else { continue }
            // Même clé deux fois (IPv4 et nom, deux VDOM) : additionnée, jamais en double.
            if let index = seen[entry.key] {
                var existing = result[index]
                existing.sentBytes = existing.sentBytes.addingReportingOverflow(entry.sentBytes).partialValue
                existing.receivedBytes = existing.receivedBytes.addingReportingOverflow(entry.receivedBytes).partialValue
                existing.bandwidth += entry.bandwidth
                existing.sessions += entry.sessions
                existing.incidents += entry.incidents
                existing.blocked += entry.blocked
                result[index] = existing
                continue
            }
            if entry.name.isEmpty { entry.name = entry.key }
            seen[entry.key] = result.count
            result.append(entry)
        }
        return result
    }

    static func entry(_ o: FortiObject, view: TrafficView, site: String) -> TrafficEntry? {
        var sent = bytes(o, ["sentbyte", "sent_bytes", "sentbytes", "tx_bytes", "txbytes", "bytes_out", "bytes_sent", "upload", "tx"]) ?? 0
        var received = bytes(o, ["rcvdbyte", "received_bytes", "rcvdbytes", "rx_bytes", "rxbytes", "bytes_in", "bytes_received", "download", "rx"]) ?? 0
        if sent == 0, received == 0, let total = bytes(o, ["bytes", "total_bytes", "traffic", "traffic_bytes", "volume"]) {
            // Total seul : compté en réception (téléchargement), le sens le plus courant.
            received = total
            sent = 0
        }
        let tx = bitsPerSecond(o.value(["tx_bandwidth", "txbandwidth", "tx_rate", "bandwidth_out", "upload_bandwidth"]))
        let rx = bitsPerSecond(o.value(["rx_bandwidth", "rxbandwidth", "rx_rate", "bandwidth_in", "download_bandwidth"]))
        let bandwidth = bitsPerSecond(o.value(["bandwidth", "bw", "throughput", "rate"])) ?? ((tx ?? 0) + (rx ?? 0))
        let sessions = o.int("sessions", "session_count", "sessioncount", "num_sessions", "session") ?? 0
        var e = TrafficEntry(site: site, view: view, key: "", name: "", sentBytes: sent, receivedBytes: received,
                             bandwidth: bandwidth, sessions: sessions)
        e.interface = o.string("srcintf", "interface", "intf", "dstintf", "interface_name")
        e.user = o.string("user", "username", "unauthuser", "srcuser")
        e.country = o.string("country", "dstcountry", "srccountry", "country_name")
        switch view {
        case .sources:
            let src = FortiParse.ipv4(o.any("srcaddr", "source", "srcip", "saddr", "src", "ip", "address", "addr"))
            e.ip = src
            e.mac = FortiParse.mac(o.any("srcmac", "mac", "mac_address", "macaddr", "src_mac"))
            e.hostname = o.string("srcname", "hostname", "host", "device", "devname", "fortiview_name", "name", "srchost")
            e.country = o.string("srccountry", "country")
            guard let key = src?.description ?? e.mac?.formatted(.upperColon) ?? e.hostname ?? e.user else { return nil }
            e.key = key
            e.name = e.hostname ?? e.user ?? key
        case .destinations:
            let dst = FortiParse.ipv4(o.any("dstaddr", "destination", "dstip", "daddr", "dst", "ip", "address", "addr"))
            e.ip = dst
            e.hostname = o.string("hostname", "dsthost", "domain", "dstname", "fqdn", "resolved", "resolved_name", "name", "web_domain", "website")
            e.country = o.string("dstcountry", "country")
            guard let key = dst?.description ?? e.hostname else { return nil }
            e.key = key
            e.name = e.hostname ?? key
        case .applications:
            let name = o.string("app_name", "appname", "application_name", "app", "application", "name", "apps")
            let id = o.string("appid", "app_id", "application_id")
            guard let key = name ?? id else { return nil }
            e.key = key
            e.name = name ?? "Application \(key)"
            e.category = o.string("appcat", "app_cat", "app_category", "category", "catdesc")
            e.risk = risk(o.value(["apprisk", "app_risk", "risk", "risk_level"]))
        case .webCategories:
            let name = o.string("catdesc", "cat_desc", "category_name", "web_category", "webcat", "category", "name")
            let id = o.string("cat", "catid", "category_id")
            guard let key = name ?? id else { return nil }
            e.key = key
            e.name = name ?? "Catégorie \(key)"
            e.category = e.name
            e.incidents = o.int("blocked_count", "count", "hits", "requests") ?? 0
            e.blocked = o.int("blocked", "blocked_count", "block") ?? 0
            e.action = o.string("action", "utmaction")
        case .interfaces:
            guard let name = o.string("interface", "srcintf", "dstintf", "intf", "name", "interface_name") else { return nil }
            e.key = name
            e.name = name
            e.interface = name
            if let tx { e.bandwidth = max(e.bandwidth, tx + (rx ?? 0)) }
        case .policies:
            let id = o.int("policyid", "policy_id", "policy", "id", "polid")
            let name = o.string("policy_name", "policyname", "name", "comments")
            guard let key = id.map(String.init) ?? name else { return nil }
            e.key = key
            e.policyID = id
            e.name = name ?? (id.map { "Politique \($0)" } ?? key)
            e.category = o.string("policytype", "policy_type", "type")
        case .threats:
            let name = o.string("threat", "threat_name", "threatname", "attack", "attackname", "virus", "malware", "name", "catdesc")
            guard let threat = name else { return nil }
            e.ip = FortiParse.ipv4(o.any("srcaddr", "source", "srcip", "saddr", "src"))
            e.mac = FortiParse.mac(o.any("srcmac", "mac"))
            e.hostname = o.string("srcname", "hostname", "host", "device")
            // Une même menace vue sur deux appareils reste sur deux lignes.
            e.key = threat + (e.ip.map { "|" + $0.description } ?? "")
            e.name = threat
            e.threatLevel = TrafficThreatLevel.parse(o.value(["threatlevel", "threat_level", "level", "crlevel", "severity"]))
                ?? TrafficThreatLevel.parse(o.value(["threatscore", "threat_score", "crscore", "score"]))
            e.threatType = threatType(o.string("threattype", "threat_type", "type", "subtype", "eventtype", "utmevent", "logtype"))
            e.incidents = o.int("count", "incidents", "threat_count", "events", "hits", "sessions") ?? max(1, sessions)
            e.blocked = o.int("blocked", "blocked_count", "block_count") ?? 0
            e.action = o.string("action", "utmaction")
            if e.blocked == 0, let action = e.action?.lowercased(),
               ["block", "drop", "deny", "reset", "quarantine"].contains(where: { action.contains($0) }) {
                e.blocked = e.incidents
            }
        case .sessions:
            return nil
        }
        return e
    }

    /// Type de menace en français.
    static func threatType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("ips") || lower.contains("intrusion") || lower.contains("attack") { return "IPS" }
        if lower.contains("virus") || lower.contains("malware") || lower.contains("av") { return "Antivirus" }
        if lower.contains("web") || lower.contains("url") { return "Filtrage web" }
        if lower.contains("botnet") || lower.contains("c&c") || lower.contains("dns") { return "Botnet" }
        if lower.contains("app") { return "Contrôle des applications" }
        if lower.contains("dlp") { return "Fuite de données" }
        return raw
    }

    // MARK: Sessions

    /// Sessions de /monitor/firewall/session ; nil si le corps n'est pas du JSON.
    public static func sessions(_ data: Data, site: String = "") -> [TrafficSession]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [TrafficSession] = []
        for (index, o) in rows(json).enumerated() {
            let source = FortiParse.ipv4(o.any("saddr", "srcaddr", "source", "srcip", "src"))
            let destination = FortiParse.ipv4(o.any("daddr", "dstaddr", "destination", "dstip", "dst"))
            guard source != nil || destination != nil else { continue }
            let proto: String
            if let number = o.int("proto", "protocol", "protocol_number") {
                switch number {
                case 6: proto = "TCP"
                case 17: proto = "UDP"
                case 1: proto = "ICMP"
                case 50: proto = "ESP"
                default: proto = "IP \(number)"
                }
            } else {
                proto = o.string("proto", "protocol")?.uppercased() ?? "—"
            }
            var app: String?
            if let apps = o.any("apps", "applications") as? [Any] {
                app = apps.compactMap { FortiJSON.string($0) }.first
            }
            app = app ?? o.string("application", "app", "app_name", "appname")
            let duration = o.int("duration", "age", "elapsed")
            result.append(TrafficSession(
                site: site, source: source, sourcePort: o.int("sport", "srcport", "source_port"),
                destination: destination, destinationPort: o.int("dport", "dstport", "destination_port"),
                proto: proto, application: app,
                sourceInterface: o.string("srcintf", "src_intf", "orgintf"), destinationInterface: o.string("dstintf", "dst_intf"),
                policyID: o.int("policyid", "policy_id", "policy"),
                sentBytes: bytes(o, ["sentbyte", "sent_bytes", "sentbytes", "tx_bytes", "bytes_out", "orgbyte"]) ?? 0,
                receivedBytes: bytes(o, ["rcvdbyte", "rcvd_bytes", "received_bytes", "rcvdbytes", "rx_bytes", "bytes_in", "replybyte"]) ?? 0,
                duration: duration, country: o.string("country", "dstcountry"),
                user: o.string("username", "user", "unauthuser"),
                serial: o.string("serial", "session_id", "sessionid", "id") ?? "\(index)"))
        }
        return result
    }

    // MARK: Liens

    /// Liens de la FortiGate : configuration (rôle, débits déclarés, alias) et état (vitesse, lien
    /// établi) fusionnés par nom. Les deux corps sont facultatifs ; nil si aucun n'est lisible.
    public static func links(config: Data?, monitor: Data?, site: String = "") -> [TrafficLink]? {
        var byName: [String: TrafficLink] = [:]
        var order: [String] = []
        var read = false
        if let config, let json = FortiJSON.parse(config) {
            read = true
            for o in FortiJSON.objects(FortiJSON.results(json)) {
                guard let name = o.string("name", "_key") else { continue }
                var link = byName[name] ?? TrafficLink(site: site, name: name)
                link.alias = o.string("alias", "description")
                link.role = o.string("role")?.lowercased()
                link.upstreamKbps = o.int("estimated-upstream-bandwidth", "estimated_upstream_bandwidth").flatMap { $0 > 0 ? UInt64($0) : nil }
                link.downstreamKbps = o.int("estimated-downstream-bandwidth", "estimated_downstream_bandwidth").flatMap { $0 > 0 ? UInt64($0) : nil }
                if byName[name] == nil { order.append(name) }
                byName[name] = link
            }
        }
        if let monitor, let json = FortiJSON.parse(monitor) {
            read = true
            for o in FortiJSON.objects(FortiJSON.results(json)) {
                guard let name = o.string("name", "_key", "id") else { continue }
                var link = byName[name] ?? TrafficLink(site: site, name: name)
                link.alias = link.alias ?? o.string("alias")
                link.linkUp = o.bool("link", "status", "link_status") ?? link.linkUp
                link.speedMbps = FortiParse.speedMbps(o.any("speed", "link_speed")) ?? link.speedMbps
                if byName[name] == nil { order.append(name) }
                byName[name] = link
            }
        }
        return read ? order.compactMap { byName[$0] } : nil
    }

    /// Débits mesurés par la vue Interfaces reportés sur les liens.
    public static func applyRates(_ links: [TrafficLink], interfaces: [TrafficEntry]) -> [TrafficLink] {
        links.map { link in
            guard let entry = interfaces.first(where: { $0.key == link.name }) else { return link }
            var copy = link
            // Sens inconnus : moitié/moitié n'aurait pas de sens ; le total va en réception (le plus fréquent).
            if entry.sentBytes > 0 || entry.receivedBytes > 0, entry.bandwidth > 0 {
                let total = Double(entry.bytes)
                copy.txBps = entry.bandwidth * Double(entry.sentBytes) / total
                copy.rxBps = entry.bandwidth * Double(entry.receivedBytes) / total
            } else {
                copy.rxBps = entry.bandwidth
            }
            return copy
        }
    }
}
