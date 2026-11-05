import Foundation
import NetScopeCore

/// Journal fictif de l'écran Journaux (note 43), cohérent avec les appareils de démonstration
/// (DemoData) : le port 14 de SW-ETG2-01 (imprimante de l'accueil) tombe et remonte deux fois,
/// l'accès SSH à la FortiGate est refusé trois fois depuis le portable de Marc, une trap
/// authenticationFailure arrive du switch cœur, et la borne FortiAP-231F redémarre. Les messages
/// passent par les vrais analyseurs (SyslogParser, SNMPTrapDecoder, FortiLogParser) : la
/// démonstration éprouve le moteur. Aucun port ouvert, rien d'envoyé.
///
/// Captures : NETSCOPE_JOURNAUX=coupure dessine « Comprendre une coupure » dans la page ;
/// NETSCOPE_JOURNAUX=arrete montre les récepteurs arrêtés ; NETSCOPE_JOURNAUX=vide, un journal vide.
@MainActor
enum JournauxDemo {
    struct Result {
        var now: Date
        var messages: [LogMessage]
        var listening: Bool
        var fortiRead: [UUID: Date]
    }

    static var requested: String? { ProcessInfo.processInfo.environment["NETSCOPE_JOURNAUX"]?.lowercased() }

    /// Heure de la démonstration : aujourd'hui, 14 h 12 min 30 s.
    static var now: Date {
        Calendar.current.date(bySettingHour: 14, minute: 12, second: 30, of: Date()) ?? Date()
    }

    /// Message choisi à l'ouverture (la dernière trap linkDown), pour montrer son détail.
    static var selectedID: UUID? { selected }
    private static var selected: UUID?

    static func make() -> Result {
        let now = self.now
        guard requested != "vide" else { return Result(now: now, messages: [], listening: false, fortiRead: [:]) }
        let site = SiteModel.shared.activeKey
        let siteName = SiteModel.shared.activeName
        var list: [LogMessage] = []
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func add(_ message: LogMessage) { list.append(message.attached(siteKey: site, siteName: siteName)) }
        func syslog(_ line: String, from host: String, minutesAgo: Double) {
            add(SyslogParser.parse(line, from: host, received: at(minutesAgo)))
        }
        func trap(_ bytes: [UInt8], from host: String, minutesAgo: Double) -> LogMessage? {
            guard let decoded = try? SNMPTrapDecoder.decode(bytes) else { return nil }
            let message = SNMPTrapCatalog.message(for: decoded, from: host, received: at(minutesAgo)).attached(siteKey: site, siteName: siteName)
            list.append(message)
            return message
        }

        // Bruit de fond des dernières heures : l'affichage du hall ne joint pas son serveur de temps
        // (répété, regroupé à l'écran), sauvegarde nocturne, connexion d'administration réussie.
        for step in 0..<14 {
            let minutes = 12.0 + Double(step) * 15
            syslog("<28>\(bsd(at(minutes))) BrightSign-D1E876001191 ntpd[214]: unable to reach time server pool.ntp.org", from: "10.182.122.106", minutesAgo: minutes)
        }
        syslog("<30>1 \(iso(at(431))) SRV-BACKUP veeam 2210 JOB - backup job 'Nuit' finished: 412 GB, 0 errors", from: "10.10.0.31", minutesAgo: 431)
        syslog("<27>1 \(iso(at(388))) SRV-BACKUP smartd 731 - - Device /dev/sdb: 8 Currently unreadable (pending) sectors", from: "10.10.0.31", minutesAgo: 388)
        syslog(fortigate(at(95), logid: "0100032001", subtype: "system", level: "information", desc: "Admin login successful",
                         extra: "user=\"dany\" ui=\"https(10.182.122.135)\" method=\"https\" srcip=10.182.122.135 action=\"login\" status=\"success\"",
                         msg: "Administrator dany logged in successfully from https(10.182.122.135)"), from: "10.182.122.1", minutesAgo: 95)
        syslog("<189>\(bsd(at(31))) SW-CORE-01 412: %SYS-5-CONFIG_I: Configured from console by dany on vty0 (10.182.122.135)", from: "10.182.122.2", minutesAgo: 31)
        syslog("<191>\(bsd(at(19))) SW-ETG2-01 00435 lldp: port 10 neighbor SIP-T54W refreshed", from: "10.182.122.3", minutesAgo: 19)

        // Le port 14 de SW-ETG2-01 (imprimante de l'accueil) tombe et remonte, deux fois.
        let ifIndex = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.1.14")
        let ifAdmin = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.7.14")
        let ifOper = SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.8.14")
        let ifName = SNMPOID(stringLiteral: "1.3.6.1.2.1.31.1.1.1.1.14")
        func link(_ down: Bool, minutesAgo: Double) -> LogMessage? {
            syslog("<\(down ? 188 : 190)>\(bsd(at(minutesAgo))) SW-ETG2-01 00076 ports: port 14 is now \(down ? "off-line" : "on-line")",
                   from: "10.182.122.3", minutesAgo: minutesAgo)
            return trap(SNMPTrapDecoder.encodeV2(community: "demo", trapOID: SNMPOID(stringLiteral: down ? SNMPTrapCatalog.linkDown : SNMPTrapCatalog.linkUp),
                                                 uptime: 81_234_500, varbinds: [
                                                    SNMPVarBind(oid: ifIndex, value: .integer(14)), SNMPVarBind(oid: ifAdmin, value: .integer(1)),
                                                    SNMPVarBind(oid: ifOper, value: .integer(down ? 2 : 1)),
                                                    SNMPVarBind(oid: ifName, value: .octetString(Array("14".utf8))),
                                                 ]), from: "10.182.122.3", minutesAgo: minutesAgo - 0.01)
        }
        _ = link(true, minutesAgo: 10.42)
        _ = link(false, minutesAgo: 9.8)
        // Dernière chute : ligne choisie à l'ouverture (avec « Regrouper », elle porte le groupe ×2).
        let lastDown = link(true, minutesAgo: 6.3)
        _ = link(false, minutesAgo: 6.17)
        selected = lastDown?.id

        // Accès SSH refusé trois fois à la FortiGate depuis le portable de Marc.
        for (index, minutes) in [7.33, 7.23, 7.12].enumerated() {
            syslog(fortigate(at(minutes), logid: "0100032002", subtype: "system", level: "alert", desc: "Admin login failed",
                             extra: "user=\"admin\" ui=\"ssh(10.182.122.113)\" method=\"ssh\" srcip=10.182.122.113 dstip=10.182.122.1 action=\"login\" status=\"failed\" reason=\"passwd_invalid\" sn=\"\(index)\"",
                             msg: "Administrator admin login failed from ssh(10.182.122.113) because of invalid password"),
                   from: "10.182.122.1", minutesAgo: minutes)
        }
        _ = trap(SNMPTrapDecoder.encodeV1(community: "demo", enterprise: SNMPOID(stringLiteral: "1.3.6.1.4.1.9.1.2134"), agent: IPv4Address(10, 182, 122, 2),
                                          generic: 4, specific: 0, uptime: 412_200_000, varbinds: []),
                 from: "10.182.122.2", minutesAgo: 7.0)

        // La borne FortiAP-231F redémarre : la FortiGate la perd, la borne envoie coldStart, puis revient.
        syslog(fortigate(at(3.83), logid: "0104043544", subtype: "wireless", level: "warning", desc: "Physical AP leave",
                         extra: "sn=\"FP231FTF21004512\" ap=\"FortiAP-231F\" ip=10.182.122.102 action=\"leave\"",
                         msg: "AP FortiAP-231F left: echo timeout (no response from AP)"), from: "10.182.122.1", minutesAgo: 3.83)
        _ = trap(SNMPTrapDecoder.encodeV2(community: "demo", trapOID: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.101.2.0.802"), uptime: 412_250_000,
                                          varbinds: [SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.2.1.1.5.0"), value: .octetString(Array("FortiGate-60F".utf8))),
                                                     SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.101.14.4.4.1.3"), value: .octetString(Array("FortiAP-231F".utf8)))]),
                 from: "10.182.122.1", minutesAgo: 3.82)
        _ = trap(SNMPTrapDecoder.encodeV2(community: "demo", trapOID: SNMPOID(stringLiteral: SNMPTrapCatalog.coldStart), uptime: 4_500,
                                          varbinds: [SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.2.1.1.5.0"), value: .octetString(Array("FortiAP-231F".utf8)))]),
                 from: "10.182.122.102", minutesAgo: 1.95)
        syslog(fortigate(at(1.75), logid: "0104043545", subtype: "wireless", level: "notice", desc: "Physical AP join",
                         extra: "sn=\"FP231FTF21004512\" ap=\"FortiAP-231F\" ip=10.182.122.102 action=\"join\"",
                         msg: "AP FortiAP-231F joined the controller"), from: "10.182.122.1", minutesAgo: 1.75)
        _ = trap(SNMPTrapDecoder.encodeV2(community: "demo", trapOID: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.101.2.0.801"), uptime: 412_265_000,
                                          varbinds: [SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.2.1.1.5.0"), value: .octetString(Array("FortiGate-60F".utf8))),
                                                     SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.101.14.4.4.1.3"), value: .octetString(Array("FortiAP-231F".utf8)))]),
                 from: "10.182.122.1", minutesAgo: 1.74)
        syslog("<191>\(bsd(at(0.6))) SW-ETG2-01 00435 lldp: port 9 neighbor BrightSign refreshed", from: "10.182.122.3", minutesAgo: 0.6)

        // Journaux lus sur la FortiGate (API) : tunnel VPN-QUEBEC tombé cette nuit.
        list += fortiGateLogs(siteKey: site, siteName: siteName, now: now)

        // Un autre site (visible avec « Tous les sites »).
        if let laval = SiteModel.shared.sites.first(where: { $0.name.contains("Laval") }) {
            let key = SiteFiles.key(for: laval.id)
            let name = laval.displayName
            for (line, host, minutes) in [
                ("<28>\(bsd(at(48))) FSW-LAVAL-01 swd: port7 link down", "10.20.0.2", 48.0),
                ("<30>\(bsd(at(47))) FSW-LAVAL-01 swd: port7 link up", "10.20.0.2", 47.0),
            ] {
                list.append(SyslogParser.parse(line, from: host, received: at(minutes)).attached(siteKey: key, siteName: name))
            }
        }

        let read = SiteModel.shared.site(forKey: site)?.fortiGateIDs.first.map { [$0: now.addingTimeInterval(-300)] } ?? [:]
        return Result(now: now, messages: list.sorted { $0.date < $1.date }, listening: requested != "arrete", fortiRead: read)
    }

    /// Journaux d'événements de la FortiGate du site (réponse fictive de /api/v2/log/memory/event/vpn).
    static func fortiGateLogs(siteKey: String, siteName: String, now: Date) -> [LogMessage] {
        let calendar = Calendar.current
        func stamp(_ minutesAgo: Double) -> (String, String) {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return (String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!))
        }
        let (d1, t1) = stamp(658)
        let (d2, t2) = stamp(655)
        let json = """
        {"http_method":"GET","results":[
         {"date":"\(d1)","time":"\(t1)","logid":"0101037131","type":"event","subtype":"vpn","level":"error","vd":"root","devname":"FortiGate-60F",
          "logdesc":"IPsec phase 2 status changed","msg":"IPsec phase 2 status change","action":"phase2-down","remip":"203.0.113.24",
          "vpntunnel":"VPN-QUEBEC","status":"down"},
         {"date":"\(d2)","time":"\(t2)","logid":"0101037138","type":"event","subtype":"vpn","level":"notice","vd":"root","devname":"FortiGate-60F",
          "logdesc":"IPsec connection status changed","msg":"IPsec connection status change","action":"tunnel-up","remip":"203.0.113.24",
          "vpntunnel":"VPN-QUEBEC","status":"success"}
        ],"vdom":"root","path":"log","name":"event","status":"success","serial":"FGT60FTK2209A1B2","version":"v7.4.4","build":2662}
        """
        return FortiLogParser.messages(Data(json.utf8), host: "10.182.122.1", subtype: "vpn")
            .map { $0.attached(siteKey: siteKey, siteName: siteName) }
    }

    // MARK: Mise en forme des lignes

    /// « Nov  4 14:02:05 » (RFC 3164).
    static func bsd(_ date: Date) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        let day = c.day ?? 1
        return "\(months[(c.month ?? 1) - 1]) \(day < 10 ? " " : "")\(day) " + String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// Ligne Syslog de FortiOS (format par défaut, clé=valeur).
    static func fortigate(_ date: Date, logid: String, subtype: String, level: String, desc: String, extra: String, msg: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let pri = 23 * 8 + (LogSeverity(text: level)?.rawValue ?? 6)
        return "<\(pri)>date=" + String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            + " time=" + String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            + " devname=\"FortiGate-60F\" devid=\"FGT60FTK2209A1B2\" logid=\"\(logid)\" type=\"event\" subtype=\"\(subtype)\" level=\"\(level)\" vd=\"root\""
            + " logdesc=\"\(desc)\" \(extra) msg=\"\(msg)\""
    }
}
