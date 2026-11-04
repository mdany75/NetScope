import Foundation

// Note 37 : lecture des étendues DHCP d'une FortiGate (GET seulement), avec le même transport et
// le même jeton que les FortiSwitch. Trois adresses : la configuration des serveurs DHCP (plages,
// exclusions, réservations, bail), leurs baux, puis les VLAN des interfaces. Analyseurs tolérants
// (FortiOS 6.4 à 7.6) : noms en « - » ou « _ », réponse enveloppée ou non, plage seule des vieilles
// versions (« start-ip » sur le serveur), champs absents.

/// Adresses de l'API utilisées pour les étendues DHCP (toutes en lecture).
public enum DHCPScopePaths {
    /// Configuration des serveurs DHCP (une entrée par interface).
    public static let servers = "/api/v2/cmdb/system.dhcp/server"
    /// Baux distribués (déjà lus avec les switchs depuis la 0.9.0).
    public static let leases = FortiPaths.dhcp
    /// Interfaces : seulement le nom, le VLAN et l'alias.
    public static let interfaces = FortiPaths.interfacesConfig
    public static let interfaceFields = "name|vlanid|alias|interface|description"

    public static let all = [servers, leases, interfaces]
}

public enum DHCPScopeParsers {
    /// cmdb system.dhcp/server : serveurs DHCP ; nil si le corps n'est pas du JSON.
    public static func servers(_ data: Data) -> [DHCPServerConfig]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [DHCPServerConfig] = []
        for (index, item) in FortiJSON.objects(FortiJSON.results(json)).enumerated() {
            guard let interface = item.string("interface", "intf", "interface-name") else { continue }
            let id = item.int("id", "q_origin_key", "mkey", "server-id", "_key") ?? index + 1
            var ranges = item.list("ip-range", "ip_range", "iprange", "ranges").compactMap(range)
            // FortiOS 5.x et certaines exportations : « start-ip » / « end-ip » sur le serveur lui-même.
            if ranges.isEmpty, let single = range(item) { ranges = [single] }
            let exclusions = item.list("exclude-range", "exclude_range", "excluderange", "exclusions").compactMap(range)
            let reservations = item.list("reserved-address", "reserved_address", "reservedaddress", "reservations").compactMap { r -> DHCPReservation? in
                guard let ip = FortiParse.ipv4(r.any("ip", "address", "ipv4")) else { return nil }
                return DHCPReservation(ip: ip, mac: FortiParse.mac(r.any("mac", "mac-address", "mac_address")),
                                       description: r.string("description", "comment", "name"),
                                       action: r.string("action", "type-action"))
            }
            let status = item.string("status")?.lowercased()
            let enabled = status.map { $0 != "disable" && $0 != "disabled" } ?? (item.bool("enabled", "enable") ?? true)
            result.append(DHCPServerConfig(id: id, interface: interface, enabled: enabled, ranges: ranges, exclusions: exclusions,
                                           reservations: reservations,
                                           leaseTime: item.int("lease-time", "lease_time", "leasetime"),
                                           gateway: FortiParse.ipv4(item.any("default-gateway", "default_gateway", "gateway", "router")),
                                           netmask: FortiParse.ipv4(item.any("netmask", "mask", "subnet-mask")),
                                           serverType: item.string("server-type", "server_type", "type")?.lowercased()))
        }
        return result
    }

    /// Plage « start-ip » / « end-ip » (ou « start » / « end », ou une adresse seule).
    static func range(_ item: FortiObject) -> DHCPAddressRange? {
        let start = FortiParse.ipv4(item.any("start-ip", "start_ip", "startip", "start", "from", "begin-ip"))
        let end = FortiParse.ipv4(item.any("end-ip", "end_ip", "endip", "end", "to", "stop-ip"))
        switch (start, end) {
        case let (s?, e?): return DHCPAddressRange(start: s, end: e)
        case let (s?, nil): return DHCPAddressRange(start: s, end: s)
        default: return nil
        }
    }

    /// monitor/system/dhcp : baux IPv4 (liste, ou dictionnaire de listes par interface), avec le
    /// serveur d'origine (« server_mkey ») et l'état quand la version les donne.
    public static func leases(_ data: Data, now: Date = Date()) -> [DHCPLeaseEntry]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item in
            if let type = item.string("type")?.lowercased(), type.contains("6") { return nil }
            guard let ip = FortiParse.ipv4(item.any("ip", "address", "ipv4", "ip_address")) else { return nil }
            var expires: Date?
            if let t = item.double("expire_time", "expire", "expiry", "lease_expires", "expires") {
                // Horodatage Unix, sinon nombre de secondes restantes (certaines versions).
                if t > 1_000_000_000 { expires = Date(timeIntervalSince1970: t) } else if t > 0 { expires = now.addingTimeInterval(t) }
            } else if let text = item.string("expire_time", "expire", "expires"), let date = ISO8601DateFormatter().date(from: text) {
                expires = date
            }
            return DHCPLeaseEntry(ip: ip, mac: FortiParse.mac(item.any("mac", "mac_address", "hwaddr", "client_mac")),
                                  hostname: item.string("hostname", "host", "client_name", "name"),
                                  interface: item.string("interface", "intf", "_key"), expires: expires,
                                  reserved: item.bool("reserved", "is_reserved") ?? false,
                                  serverID: item.int("server_mkey", "server-mkey", "server_id", "serverid", "server"),
                                  status: item.string("status", "state"))
        }
    }

    /// cmdb system/interface : VLAN et alias de chaque interface (vlanid 0 : pas un VLAN).
    public static func interfaces(_ data: Data) -> [String: DHCPInterfaceInfo]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: DHCPInterfaceInfo] = [:]
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            guard let name = item.string("name", "_key") else { continue }
            let vlan = item.int("vlanid", "vlan-id", "vlan_id", "vlan").flatMap { (1...4094).contains($0) ? $0 : nil }
            let alias = item.string("alias") ?? item.string("description")
            result[name] = DHCPInterfaceInfo(vlan: vlan, alias: alias)
        }
        return result
    }
}

extension FortiGateReader {
    /// Lit les serveurs DHCP, leurs baux et les VLAN des interfaces. Seule la configuration des
    /// serveurs est indispensable : 403 lève l'erreur (droit manquant, expliqué par
    /// `dhcpScopeDescription`) ; 404 rend une lecture « serveur DHCP absent » ; baux ou interfaces
    /// absents ou refusés sont notés (l'occupation compte alors seulement les réservations).
    public func readDHCPScopes(now: Date = Date()) async throws -> DHCPScopeReadReport {
        do {
            return try await readDHCPScopesKeepingCalls(now: now)
        } catch let failure as FortiReadFailure {
            throw failure.error
        }
    }

    /// Comme `readDHCPScopes`, mais une erreur emporte les appels déjà faits (`FortiReadFailure`).
    public func readDHCPScopesKeepingCalls(now: Date = Date()) async throws -> DHCPScopeReadReport {
        var calls: [FortiCallRecord] = []
        do {
            return try await readDHCPScopesAll(now: now, calls: &calls)
        } catch let error as FortiGateError {
            throw FortiReadFailure(error: error, calls: calls)
        }
    }

    private func readDHCPScopesAll(now: Date, calls: inout [FortiCallRecord]) async throws -> DHCPScopeReadReport {
        var report = DHCPScopeReadReport(readAt: now)

        let servers = try await fetch(DHCPScopePaths.servers)
        calls.append(servers.record)
        switch servers.error {
        case .notFound?:
            report.available = false
            report.notes.append("Serveur DHCP de la FortiGate introuvable (HTTP 404 sur cmdb/system.dhcp/server)\u{00A0}: version de FortiOS sans cette adresse, ou VDOM à vérifier dans Réglages › Switchs.")
            report.calls = calls
            return report
        case .some(let error):
            throw error
        case nil:
            break
        }
        guard let body = servers.response?.body, let parsed = DHCPScopeParsers.servers(body) else {
            throw FortiGateError.invalidResponse(path: DHCPScopePaths.servers)
        }
        report.servers = parsed

        let leases = try await fetch(DHCPScopePaths.leases)
        calls.append(leases.record)
        if let body = leases.response?.body, leases.error == nil, let list = DHCPScopeParsers.leases(body, now: now) {
            report.leases = list
        } else {
            report.leasesRead = false
            report.notes.append(Self.dhcpNote("Baux DHCP", leases.error)
                                ?? "Baux DHCP\u{00A0}: réponse illisible, seules les réservations sont comptées.")
        }

        let interfaces = try await fetch(DHCPScopePaths.interfaces, query: [URLQueryItem(name: "format", value: DHCPScopePaths.interfaceFields)])
        calls.append(interfaces.record)
        if let body = interfaces.response?.body, interfaces.error == nil, let map = DHCPScopeParsers.interfaces(body) {
            report.interfaces = map
        } else if let note = Self.dhcpNote("VLAN des interfaces", interfaces.error) {
            // Sans les interfaces, le VLAN est déduit du nom (« vlan20 » → 20).
            report.notes.append(note + " Le VLAN est déduit du nom de l’interface.")
        }

        report.calls = calls
        return report
    }

    /// Explication d'une partie facultative absente (404) ou refusée (403).
    static func dhcpNote(_ part: String, _ error: FortiGateError?) -> String? {
        switch error {
        case .notFound?: return "\(part)\u{00A0}: adresse absente de cette version de FortiOS."
        case .forbidden?: return "\(part)\u{00A0}: accès refusé (HTTP 403), ajoutez le droit «\u{00A0}Network\u{00A0}» (ou «\u{00A0}System\u{00A0}») en lecture au profil de l’administrateur API."
        case .some(let other): return "\(part)\u{00A0}: \(other.errorDescription ?? "lecture impossible.")"
        case nil: return nil
        }
    }
}

extension FortiGateError {
    /// Message propre aux étendues DHCP pour un 403 sur la configuration des serveurs.
    public var dhcpScopeDescription: String {
        if case .forbidden = self {
            return "Accès refusé (HTTP 403) aux serveurs DHCP de la FortiGate\u{00A0}: ajoutez le droit «\u{00A0}Network\u{00A0}» en lecture (Configuration réseau) au profil de l’administrateur API (System › Admin Profiles), ou vérifiez que ce Mac est dans ses hôtes de confiance."
        }
        return errorDescription ?? "Lecture impossible."
    }
}
