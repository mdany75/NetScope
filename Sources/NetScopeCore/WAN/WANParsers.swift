import Foundation

// Note 39 : lecture tolérante des réponses WAN de FortiOS (6.4 à 7.6). Mêmes principes que
// FortiParsers : enveloppe « results » ou réponse nue, noms en « - » ou « _ », champs absents,
// liste ou dictionnaire indexé par nom.
//
// Noms relevés dans la documentation publique (FNDN, guide SD-WAN de FortiOS), le module Ansible
// fortios_monitor_fact et l'exportateur Prometheus « fortigate_exporter » :
// - monitor/system/interface : dictionnaire par nom { name, alias, link, speed, duplex, ip, mask,
//   tx_bytes, rx_bytes, tx_errors, rx_errors, vlanid } ;
// - monitor/virtual-wan/health-check : { <sonde>: { <membre>: { status (up, down, error, disable),
//   latency, jitter, packet_loss (%), packet_sent, packet_received, sla_targets_met, session,
//   tx_bandwidth, rx_bandwidth (b/s), state_changed } } } ;
// - monitor/virtual-wan/members (7.0 et plus) : par interface { status, link, gateway, zone,
//   tx_bandwidth, rx_bandwidth, session, state_changed } ;
// - cmdb/system/sdwan (7.x) ou cmdb/system/virtual-wan-link (6.4) : members[{ seq-num,
//   interface, gateway, zone }], health-check[{ name, server, protocol, members[{ seq-num }],
//   sla[{ id, latency-threshold, jitter-threshold, packetloss-threshold }] }] ;
// - monitor/vpn/ipsec : [{ name, rgwy, type, parent, comments, connection_count, creation_time,
//   incoming_bytes, outgoing_bytes, proxyid[{ p2name, status, proxy_src, proxy_dst,
//   incoming_bytes, outgoing_bytes, expire }] }] ;
// - monitor/vpn/ssl : [{ user_name, remote_host, last_login_time }].
// Ce qui n'est pas documenté est lu de façon défensive et gardé dans la réponse brute.

public enum WANParsers {
    // MARK: Interfaces

    /// cmdb system/interface : configuration utile au WAN, par nom ; nil si ce n'est pas du JSON.
    public static func interfaceConfig(_ data: Data) -> [String: WANInterfaceStatus]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: WANInterfaceStatus] = [:]
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            guard let name = item.string("name", "_key") else { continue }
            let address = FortiParse.addressAndPrefix(item.any("ip"), mask: item.any("mask", "netmask"))
            result[name] = WANInterfaceStatus(
                name: name, alias: item.string("alias"), role: item.string("role")?.lowercased(),
                type: item.string("type")?.lowercased(), mode: item.string("mode", "addressing-mode")?.lowercased(),
                adminUp: item.bool("status"),
                ip: address.map(\.0).flatMap { $0.value == 0 ? nil : $0 }, prefix: address.map(\.1),
                estimatedDownKbps: item.int("estimated-downstream-bandwidth", "estimated_downstream_bandwidth").flatMap { $0 > 0 ? $0 : nil },
                estimatedUpKbps: item.int("estimated-upstream-bandwidth", "estimated_upstream_bandwidth").flatMap { $0 > 0 ? $0 : nil })
        }
        return result
    }

    /// monitor/system/interface : état et compteurs, par nom ; nil si ce n'est pas du JSON.
    public static func interfaceStatus(_ data: Data) -> [String: WANInterfaceStatus]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        var result: [String: WANInterfaceStatus] = [:]
        for item in FortiJSON.objects(FortiJSON.results(json)) {
            guard let name = item.string("name", "id", "_key", "interface") else { continue }
            let address = FortiParse.addressAndPrefix(item.any("ip", "ipv4"), mask: item.any("mask", "netmask", "cidr_netmask"))
            var link = item.bool("link", "link_status", "linkup")
            if link == nil, let status = item.string("status")?.lowercased() { link = status == "up" ? true : (status == "down" ? false : nil) }
            result[name] = WANInterfaceStatus(
                name: name, alias: item.string("alias"), linkUp: link,
                speedMbps: FortiParse.speedMbps(item.any("speed")),
                ip: address.map(\.0).flatMap { $0.value == 0 ? nil : $0 }, prefix: address.map(\.1),
                rxBytes: counter(item.any("rx_bytes", "rx-bytes", "in_bytes")), txBytes: counter(item.any("tx_bytes", "tx-bytes", "out_bytes")),
                rxErrors: counter(item.any("rx_errors", "rx-errors")), txErrors: counter(item.any("tx_errors", "tx-errors")))
        }
        return result
    }

    // MARK: SD-WAN

    /// monitor/virtual-wan/health-check : mesures par sonde et par membre ; nil si ce n'est pas du
    /// JSON. Accepte le dictionnaire { sonde: { membre: … } } et une liste [{ name, members }].
    public static func health(_ data: Data, now: Date = Date()) -> [WANHealthMeasure]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let content = FortiJSON.results(json)
        var result: [WANHealthMeasure] = []
        func members(_ check: String, _ value: Any?) {
            if let dict = value as? [String: Any] {
                for key in dict.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    guard let member = dict[key] as? [String: Any] else { continue }
                    result.append(measure(check: check, interface: key, FortiObject(member), now: now))
                }
            } else if let list = value as? [Any] {
                for case let member as [String: Any] in list {
                    let object = FortiObject(member)
                    guard let name = object.string("interface", "name", "member") else { continue }
                    result.append(measure(check: check, interface: name, object, now: now))
                }
            }
        }
        if let dict = content as? [String: Any] {
            for check in dict.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                members(check, dict[check])
            }
        } else if let list = content as? [Any] {
            for case let item as [String: Any] in list {
                let object = FortiObject(item)
                guard let name = object.string("name", "health-check", "health_check") else { continue }
                members(name, object.any("members", "results", "member"))
            }
        }
        return result
    }

    static func measure(check: String, interface: String, _ m: FortiObject, now: Date) -> WANHealthMeasure {
        let met: [Int]? = (m.any("sla_targets_met", "sla-targets-met") as? [Any]).map { $0.compactMap(FortiJSON.int) }
        return WANHealthMeasure(checkName: check, interface: interface, status: m.string("status", "state")?.lowercased(),
                                latencyMs: nonNegative(m.double("latency")), jitterMs: nonNegative(m.double("jitter")),
                                lossPercent: nonNegative(m.double("packet_loss", "packetloss", "packet-loss")).map { min($0, 100) },
                                packetsSent: m.int("packet_sent", "packets_sent"), packetsReceived: m.int("packet_received", "packets_received"),
                                slaTargetsMet: met, stateChanged: timestamp(m.any("state_changed", "state-changed")),
                                rxBps: nonNegative(m.double("rx_bandwidth", "rx-bandwidth")), txBps: nonNegative(m.double("tx_bandwidth", "tx-bandwidth")),
                                sessions: m.int("session", "sessions"))
    }

    /// monitor/virtual-wan/members : membres SD-WAN par interface ; nil si ce n'est pas du JSON.
    public static func members(_ data: Data) -> [WANInterfaceStatus]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item -> WANInterfaceStatus? in
            guard let name = item.string("interface", "name", "_key") else { return nil }
            var link = item.bool("link")
            if link == nil, let status = item.string("link", "status")?.lowercased() { link = status == "up" ? true : (status == "down" ? false : nil) }
            return WANInterfaceStatus(name: name, linkUp: link,
                                      rxBps: nonNegative(item.double("rx_bandwidth", "rx-bandwidth")),
                                      txBps: nonNegative(item.double("tx_bandwidth", "tx-bandwidth")),
                                      gateway: FortiParse.ipv4(item.any("gateway")),
                                      sdwanZone: item.string("zone", "sdwan_zone"), isSDWANMember: true,
                                      sessions: item.int("session", "sessions"),
                                      stateChanged: timestamp(item.any("state_changed", "state-changed")))
        }
    }

    /// cmdb system/sdwan ou system/virtual-wan-link : membres (interface, passerelle, zone) et
    /// sondes avec leurs SLA ; nil si ce n'est pas du JSON.
    public static func sdwanConfig(_ data: Data) -> (members: [WANInterfaceStatus], checks: [WANHealthCheckConfig], enabled: Bool?)? {
        guard let json = FortiJSON.parse(data) else { return nil }
        guard let root = FortiJSON.objects(FortiJSON.results(json)).first else { return ([], [], nil) }
        var bySeq: [Int: String] = [:]
        var members: [WANInterfaceStatus] = []
        for m in root.list("members", "member") {
            guard let name = m.string("interface", "name") else { continue }
            if let seq = m.int("seq-num", "seq_num", "id") { bySeq[seq] = name }
            members.append(WANInterfaceStatus(name: name, adminUp: m.bool("status"), gateway: FortiParse.ipv4(m.any("gateway")),
                                              sdwanZone: m.string("zone"), isSDWANMember: true))
        }
        let checks = root.list("health-check", "health_check", "healthcheck").compactMap { c -> WANHealthCheckConfig? in
            guard let name = c.string("name") else { return nil }
            let servers = serverList(c.any("server", "servers"))
            let interfaces = c.list("members", "member").compactMap { m -> String? in
                if let seq = m.int("seq-num", "seq_num"), let name = bySeq[seq] { return name }
                return m.string("interface", "name")
            }
            let sla = c.list("sla").compactMap { s -> WANSLATarget? in
                guard let id = s.int("id") else { return nil }
                return WANSLATarget(id: id, latencyMs: nonNegative(s.double("latency-threshold", "latency_threshold")),
                                    jitterMs: nonNegative(s.double("jitter-threshold", "jitter_threshold")),
                                    lossPercent: nonNegative(s.double("packetloss-threshold", "packetloss_threshold", "packet-loss-threshold")))
            }
            return WANHealthCheckConfig(name: name, servers: servers, proto: c.string("protocol")?.lowercased(), members: interfaces, sla: sla)
        }
        return (members, checks, root.bool("status"))
    }

    /// « "8.8.8.8" "8.8.4.4" », « 8.8.8.8 », [{ "address": … }] → adresses.
    static func serverList(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.compactMap { item in
                if let dict = item as? [String: Any] { return FortiObject(dict).string("address", "name", "server") }
                return FortiJSON.string(item)
            }
        }
        guard let text = FortiJSON.string(value) else { return [] }
        return text.replacingOccurrences(of: "\"", with: " ").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }

    // MARK: VPN

    /// monitor/vpn/ipsec : tunnels et leurs phases 2 ; nil si ce n'est pas du JSON.
    public static func tunnels(_ data: Data, now: Date = Date()) -> [WANTunnel]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item -> WANTunnel? in
            guard let name = item.string("name", "p1name", "_key") else { return nil }
            let phase2 = item.list("proxyid", "proxy_id", "phase2").map { p -> WANPhase2 in
                WANPhase2(name: p.string("p2name", "name") ?? name, status: p.string("status")?.lowercased(),
                          source: selectors(p.any("proxy_src", "src", "source")), destination: selectors(p.any("proxy_dst", "dst", "destination")),
                          incomingBytes: counter(p.any("incoming_bytes", "rx_bytes")), outgoingBytes: counter(p.any("outgoing_bytes", "tx_bytes")),
                          expiresIn: p.int("expire", "expire_time"))
            }
            var upSince: Date?
            if let created = item.any("creation_time", "creation-time", "uptime"), let n = FortiJSON.double(created), n > 0 {
                upSince = FortiParse.lastSeen(created, now: now)
            }
            let gateway = item.string("rgwy", "remote_gateway", "remote-gw", "rgwy_ip")
            return WANTunnel(name: name, remoteGateway: gateway == "0.0.0.0" ? nil : gateway, type: item.string("type")?.lowercased(),
                             parent: item.string("parent").flatMap { $0.isEmpty ? nil : $0 }, comments: item.string("comments", "comment"),
                             status: item.string("status", "tun_status")?.lowercased(), connectionCount: item.int("connection_count"),
                             incomingBytes: counter(item.any("incoming_bytes", "rx_bytes")), outgoingBytes: counter(item.any("outgoing_bytes", "tx_bytes")),
                             upSince: upSince, phase2: phase2)
        }
    }

    /// « 10.0.0.0/255.255.255.0 » → « 10.0.0.0/24 » ; plusieurs sélecteurs séparés par une virgule.
    static func selectors(_ value: Any?) -> String? {
        let items: [String]
        if let list = value as? [Any] {
            items = list.compactMap { item in
                if let dict = item as? [String: Any] { return FortiObject(dict).string("subnet", "address", "name") }
                return FortiJSON.string(item)
            }
        } else if let text = FortiJSON.string(value) {
            items = [text]
        } else {
            return nil
        }
        let cleaned = items.map { text -> String in
            if let (ip, prefix) = FortiParse.addressAndPrefix(text, mask: nil) { return "\(ip)/\(prefix)" }
            return text
        }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }

    /// monitor/vpn/ssl : utilisateurs connectés ; nil si ce n'est pas du JSON.
    public static func sslUsers(_ data: Data, now: Date = Date()) -> [WANSSLUser]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        return FortiJSON.objects(FortiJSON.results(json)).compactMap { item -> WANSSLUser? in
            guard let user = item.string("user_name", "username", "user") else { return nil }
            return WANSSLUser(user: user, remoteHost: item.string("remote_host", "remote_ip", "src_ip"),
                              loginAt: timestamp(item.any("last_login_time", "login_time")))
        }
    }

    // MARK: Petites conversions

    static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func counter(_ value: Any?) -> UInt64? {
        guard let d = FortiJSON.double(value), d.isFinite, d >= 0, d < 1.8e19 else { return nil }
        return UInt64(d)
    }

    /// Horodatage Unix (secondes ou millisecondes), ou texte ISO 8601 ; 0 : inconnu.
    static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String, Double(text) == nil { return ISO8601DateFormatter().date(from: text) }
        guard let d = FortiJSON.double(value), d.isFinite, d > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
    }
}
