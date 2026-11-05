import Foundation
import NetScopeCore

// Tests des journaux (note 43) : Syslog RFC 3164, RFC 5424, FortiOS clé=valeur, Cisco et HPE Aruba ;
// traps SNMP v1 et v2c décodées à partir d'octets fixes ; journal borné, filtres, recherche,
// regroupement, « Comprendre une coupure » ; journaux de la FortiGate (réponses fixes) ; sondes de
// la Surveillance ; enfin un vrai récepteur sur 127.0.0.1 seulement.

func registerLogTests(_ suite: TestSuite) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
    let received = date(2026, 11, 4, 14, 12, 30)

    // MARK: Syslog

    suite.add("Journaux : Syslog RFC 3164 (exemple de la RFC, PID, sans nom d'hôte, sans PRI, année)") {
        let m = SyslogParser.parse("<34>Oct 11 22:14:15 mymachine su: 'su root' failed for lonvick on /dev/pts/8",
                                   from: "10.0.0.5", received: received, calendar: calendar)
        try expectEqual(m.severity, .critical, "34 % 8 = 2 : critique")
        try expectEqual(m.facility, 4, "34 / 8 = 4 : auth")
        try expectEqual(m.hostname, "mymachine", "nom d'hôte")
        try expectEqual(m.app, "su", "étiquette")
        try expectEqual(m.message, "'su root' failed for lonvick on /dev/pts/8", "message")
        try expectEqual(m.date, date(2026, 10, 11, 22, 14, 15), "date (année de la réception)")
        try expectEqual(m.host, "10.0.0.5", "émetteur")
        try expectEqual(m.source, .syslog, "source")

        let pid = SyslogParser.parse("<13>Nov  4 14:02:07 SRV-AD-01 sshd[812]: Accepted publickey for dany", from: "10.10.0.10",
                                     received: received, calendar: calendar)
        try expectEqual(pid.app, "sshd", "programme sans le PID")
        try expectEqual(pid.fields["procid"], "812", "PID")
        try expectEqual(pid.date, date(2026, 11, 4, 14, 2, 7), "jour à un chiffre (deux espaces)")

        let noHost = SyslogParser.parse("<13>Nov  4 14:02:07 sshd[812]: Accepted", from: "10.0.0.9", received: received, calendar: calendar)
        try expectEqual(noHost.hostname, nil, "pas de nom d'hôte")
        try expectEqual(noHost.deviceLabel, "10.0.0.9", "l'appareil est l'adresse")

        let bare = SyslogParser.parse("Hello world", from: "10.0.0.9", received: received, calendar: calendar)
        try expectEqual(bare.severity, .notice, "sans PRI : user.notice")
        try expectEqual(bare.facility, 1, "user")
        try expectEqual(bare.message, "Hello world", "texte gardé")

        // Reçu le 1er janvier, daté du 31 décembre : de l'année précédente.
        let newYear = SyslogParser.parse("<14>Dec 31 23:59:58 host app: fin d'année", from: "10.0.0.9",
                                         received: date(2027, 1, 1, 0, 0, 10), calendar: calendar)
        try expectEqual(newYear.date, date(2026, 12, 31, 23, 59, 58), "année précédente")

        let invalidPRI = SyslogParser.parse("<999>texte", from: "10.0.0.9", received: received, calendar: calendar)
        try expectEqual(invalidPRI.message, "<999>texte", "PRI hors limites : texte gardé")
        try expectEqual(SyslogParser.parse("<13>", from: "x", received: received).message, "(message vide)", "message vide")
    }

    suite.add("Journaux : Syslog RFC 5424 (exemples de la RFC, données structurées, BOM, échappements)") {
        let line = "<165>1 2003-10-11T22:14:15.003Z mymachine.example.com evntslog - ID47 [exampleSDID@32473 iut=\"3\" eventSource=\"Application\" eventID=\"1011\"] \u{FEFF}An application event log entry..."
        let m = SyslogParser.parse(line, from: "192.0.2.1", received: received)
        try expectEqual(m.severity, .notice, "165 % 8 = 5")
        try expectEqual(m.facility, 20, "local4")
        try expectEqual(LogFacility.name(m.facility ?? 0), "local4", "nom de la facilité")
        try expectEqual(m.hostname, "mymachine.example.com", "HOSTNAME")
        try expectEqual(m.app, "evntslog", "APP-NAME")
        try expectEqual(m.eventID, "ID47", "MSGID")
        try expectEqual(m.fields["exampleSDID@32473.eventSource"], "Application", "paramètre SD")
        try expectEqual(m.message, "An application event log entry...", "MSG sans BOM")
        try expectEqual(m.date, Date(timeIntervalSince1970: 1_065_910_455.003), "horodatage avec millisecondes")

        let escaped = SyslogParser.parse("<34>1 2026-11-04T14:02:07-05:00 h app 42 - [x@1 a=\"un \\\"b\\\" \\]c\"][y@2 z=\"1\"] fin",
                                         from: "10.0.0.1", received: received)
        try expectEqual(escaped.fields["x@1.a"], "un \"b\" ]c", "guillemet et crochet échappés")
        try expectEqual(escaped.fields["y@2.z"], "1", "deuxième élément")
        try expectEqual(escaped.fields["procid"], "42", "PROCID")
        try expectEqual(escaped.message, "fin", "MSG après plusieurs éléments")
        try expectEqual(escaped.date, date(2026, 11, 4, 14, 2, 7), "fuseau -05:00")

        let nil5424 = SyslogParser.parse("<14>1 - - - - - - juste un message", from: "10.0.0.1", received: received)
        try expectEqual(nil5424.date, received, "sans horodatage : heure de réception")
        try expectEqual(nil5424.hostname, nil, "« - » : absent")
        try expectEqual(nil5424.message, "juste un message", "MSG")

        // Encodage de l'essai, relu.
        let test = SyslogParser.encode5424(severity: .warning, date: received, hostname: "NetScope", app: "NetScope", msgID: "ESSAI", message: "Essai é")
        let relu = SyslogParser.parse(test, from: "127.0.0.1", received: received)
        try expectEqual(relu.severity, .warning, "gravité relue")
        try expectEqual(relu.message, "Essai é", "message relu (UTF-8, BOM retiré)")
        try expectEqual(relu.eventID, "ESSAI", "MSGID relu")
    }

    suite.add("Journaux : format FortiOS clé=valeur (défaut et dans un 5424), Cisco et HPE Aruba") {
        let forti = "<185>date=2026-11-04 time=14:05:10 devname=\"FGT-SIEGE\" devid=\"FGT60FTK2209A1B2\" eventtime=1793819110123456789 tz=\"-0500\" logid=\"0100032002\" type=\"event\" subtype=\"system\" level=\"alert\" vd=\"root\" logdesc=\"Admin login failed\" user=\"admin\" ui=\"ssh(10.182.122.113)\" srcip=10.182.122.113 action=\"login\" status=\"failed\" msg=\"Administrator admin login failed from ssh(10.182.122.113) because of invalid password\""
        let m = SyslogParser.parse(forti, from: "10.182.122.1", received: received, calendar: calendar)
        try expectEqual(m.severity, .alert, "gravité du champ level")
        try expectEqual(m.hostname, "FGT-SIEGE", "devname")
        try expectEqual(m.eventID, "0100032002", "logid")
        try expectEqual(m.app, "FortiOS · event · system", "type et sous-type")
        try expectEqual(m.message, "Administrator admin login failed from ssh(10.182.122.113) because of invalid password", "msg")
        try expectEqual(m.fields["srcip"], "10.182.122.113", "champ sans guillemets")
        try expectEqual(m.date, Date(timeIntervalSince1970: 1_793_819_110.123456789), "eventtime en nanosecondes")

        // Sans eventtime : date + time + tz.
        let noEvent = SyslogParser.parse("<190>date=2026-11-04 time=09:00:00 tz=\"+0100\" devname=\"FGT\" logid=\"1\" level=\"information\" msg=\"x\"",
                                         from: "10.0.0.1", received: received, calendar: calendar)
        try expectEqual(noEvent.date, Date(timeIntervalSince1970: 1_793_779_200), "fuseau +0100 (08:00 UTC)")
        try expectEqual(noEvent.severity, .info, "information")

        // FortiOS au format RFC 5424 : les paires sont dans le MSG.
        let in5424 = SyslogParser.parse("<189>1 2026-11-04T14:05:10-05:00 FGT-SIEGE - - - - logid=\"0101037131\" type=\"event\" subtype=\"vpn\" level=\"error\" devname=\"FGT-SIEGE\" logdesc=\"IPsec phase 2 status changed\" msg=\"IPsec phase 2 status change\"",
                                        from: "10.182.122.1", received: received)
        try expectEqual(in5424.severity, .error, "level dans le MSG")
        try expectEqual(in5424.message, "IPsec phase 2 status changed\u{00A0}: IPsec phase 2 status change", "logdesc + msg")

        let cisco = SyslogParser.parse("Nov  4 13:41:22 SW-CORE-01 412: %LINK-3-UPDOWN: Interface GigabitEthernet1/0/14, changed state to down",
                                       from: "10.182.122.2", received: received, calendar: calendar)
        try expectEqual(cisco.eventID, "LINK-3-UPDOWN", "mnémonique")
        try expectEqual(cisco.severity, .error, "gravité du mnémonique (sans PRI)")
        try expectEqual(cisco.app, "LINK", "facilité Cisco")
        try expectEqual(cisco.hostname, "SW-CORE-01", "nom d'hôte")
        try expectEqual(cisco.fields["seq"], "412", "numéro de séquence")
        try expectEqual(cisco.message, "Interface GigabitEthernet1/0/14, changed state to down", "message")

        let aruba = SyslogParser.parse("<188>Nov  4 14:02:05 SW-ETG2-01 00076 ports: port 14 is now off-line", from: "10.182.122.3",
                                       received: received, calendar: calendar)
        try expectEqual(aruba.eventID, "00076", "numéro d'événement Aruba")
        try expectEqual(aruba.app, "ports", "sous-système")
        try expectEqual(aruba.message, "port 14 is now off-line", "message")
        try expectEqual(aruba.severity, .warning, "PRI 188")

        try expectEqual(LogSeverity(text: "notification"), .notice, "niveau FortiOS")
        try expectEqual(LogSeverity(text: "Erreur"), .error, "libellé français")
        try expectEqual(LogSeverity(text: "7"), .debug, "chiffre")
        try expect(LogSeverity.error.isAtLeast(.warning), "erreur ≥ avertissement")
        try expect(!LogSeverity.info.isAtLeast(.warning), "information < avertissement")
    }

    // MARK: Traps SNMP

    suite.add("Journaux : trap SNMPv2c linkDown décodée depuis des octets fixes (et encodeur identique)") {
        let bytes: [UInt8] = [
            0x30, 0x6D, 0x02, 0x01, 0x01, 0x04, 0x06] + Array("public".utf8) + [
            0xA7, 0x60, 0x02, 0x02, 0x30, 0x39, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00, 0x30, 0x54,
            // sysUpTime.0 = 123456
            0x30, 0x0F, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x03, 0x00, 0x43, 0x03, 0x01, 0xE2, 0x40,
            // snmpTrapOID.0 = linkDown
            0x30, 0x17, 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x06, 0x03, 0x01, 0x01, 0x04, 0x01, 0x00,
            0x06, 0x09, 0x2B, 0x06, 0x01, 0x06, 0x03, 0x01, 0x01, 0x05, 0x03,
            // ifIndex.14 = 14
            0x30, 0x0F, 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x02, 0x02, 0x01, 0x01, 0x0E, 0x02, 0x01, 0x0E,
            // ifName.14 = "Gi1/0/14"
            0x30, 0x17, 0x06, 0x0B, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x1F, 0x01, 0x01, 0x01, 0x01, 0x0E,
            0x04, 0x08] + Array("Gi1/0/14".utf8)
        let trap = try SNMPTrapDecoder.decode(bytes)
        try expectEqual(trap.version, 1, "v2c")
        try expectEqual(trap.community, "public", "communauté")
        try expectEqual(trap.trapOID.description, SNMPTrapCatalog.linkDown, "OID linkDown")
        try expectEqual(trap.uptime, 123_456, "sysUpTime")
        try expectEqual(trap.varbinds.count, 2, "données sans sysUpTime ni snmpTrapOID")
        try expect(!trap.isInform, "trap, pas inform")
        try expectEqual(trap.requestID, 12_345, "request-id")
        let message = SNMPTrapCatalog.message(for: trap, from: "10.182.122.3", received: received)
        try expectEqual(message.source, .trap, "source")
        try expectEqual(message.severity, .error, "linkDown : erreur")
        try expectEqual(message.eventID, "linkDown", "nom MIB")
        try expectEqual(message.message, "Lien tombé\u{00A0}: port Gi1/0/14 (ifIndex 14)", "message lisible")
        try expect(!message.raw.contains("public") && message.fields.values.allSatisfy { $0 != "public" }, "communauté jamais gardée")
        // L'encodeur produit exactement les mêmes octets.
        let encoded = SNMPTrapDecoder.encodeV2(community: "public", trapOID: trap.trapOID, uptime: 123_456, varbinds: trap.varbinds, requestID: 12_345)
        try expectEqual(encoded, bytes, "encodeur v2c")
    }

    suite.add("Journaux : trap SNMPv1 coldStart (octets fixes), entreprise Fortinet, inform, v3 et octets tronqués") {
        let v1: [UInt8] = [0x30, 0x27, 0x02, 0x01, 0x00, 0x04, 0x06] + Array("public".utf8) + [
            0xA4, 0x1A, 0x06, 0x06, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x09, 0x40, 0x04, 0x0A, 0xB6, 0x7A, 0x02,
            0x02, 0x01, 0x00, 0x02, 0x01, 0x00, 0x43, 0x02, 0x11, 0x94, 0x30, 0x00]
        let cold = try SNMPTrapDecoder.decode(v1)
        try expectEqual(cold.version, 0, "v1")
        try expectEqual(cold.trapOID.description, SNMPTrapCatalog.coldStart, "generic 0 → coldStart (RFC 3584)")
        try expectEqual(cold.agentAddress, IPv4Address(10, 182, 122, 2), "agent-addr")
        try expectEqual(cold.enterprise?.description, "1.3.6.1.4.1.9", "entreprise")
        try expectEqual(cold.uptime, 4_500, "time-stamp")
        let coldMessage = SNMPTrapCatalog.message(for: cold, from: "10.182.122.2", received: received)
        try expectEqual(coldMessage.message, "Démarrage à froid (redémarrage) (en marche depuis 00:00:45)", "message")
        try expectEqual(coldMessage.severity, .warning, "gravité")
        try expectEqual(SNMPTrapDecoder.encodeV1(community: "public", enterprise: cold.enterprise!, agent: cold.agentAddress!, generic: 0,
                                                 specific: 0, uptime: 4_500, varbinds: []), v1, "encodeur v1")

        // v1, generic 6 : entreprise.0.specific → fgTrapVpnTunDown.
        let vpn = try SNMPTrapDecoder.decode(SNMPTrapDecoder.encodeV1(
            community: "c", enterprise: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.101.2"), agent: IPv4Address(10, 0, 0, 1), generic: 6, specific: 302,
            uptime: 1, varbinds: [SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.4.1.12356.101.12.3.4"), value: .octetString(Array("VPN-QUEBEC".utf8)))]))
        try expectEqual(vpn.trapOID.description, "1.3.6.1.4.1.12356.101.2.0.302", "OID d'entreprise")
        let vpnMessage = SNMPTrapCatalog.message(for: vpn, from: "10.0.0.1", received: received)
        try expectEqual(vpnMessage.eventID, "fgTrapVpnTunDown", "trap Fortinet connue")
        try expectEqual(vpnMessage.message, "Tunnel VPN tombé\u{00A0}: VPN-QUEBEC", "données textuelles ajoutées")

        // Inform : accusé de réception (Response, même request-id).
        let inform = try SNMPTrapDecoder.decode(SNMPTrapDecoder.encodeV2(community: "c", trapOID: SNMPOID(stringLiteral: SNMPTrapCatalog.linkUp),
                                                                         uptime: 9, varbinds: [], requestID: 77, inform: true))
        try expect(inform.isInform, "inform reconnu")
        let reply = try SNMPMessage(decoding: try logValue(SNMPTrapDecoder.informResponse(to: inform), "réponse"))
        try expectEqual(reply.pdu.type, .response, "Response")
        try expectEqual(reply.pdu.requestID, 77, "même request-id")
        try expect(SNMPTrapDecoder.informResponse(to: cold) == nil, "pas de réponse à une trap")

        // Trap inconnue : OID affiché, gravité information.
        let unknown = SNMPTrapCatalog.message(for: try SNMPTrapDecoder.decode(SNMPTrapDecoder.encodeV2(
            community: "c", trapOID: SNMPOID(stringLiteral: "1.3.6.1.4.1.99999.1.2"), uptime: 1, varbinds: [])), from: "10.0.0.1", received: received)
        try expectEqual(unknown.severity, .info, "inconnue : information")
        try expectEqual(unknown.message, "Trap 1.3.6.1.4.1.99999.1.2", "OID numérique")

        // SNMPv3, octets tronqués, simple requête : refusés avec la raison.
        let v3: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x03]
        do {
            _ = try SNMPTrapDecoder.decode(v3)
            throw TestFailure(message: "v3 aurait dû être refusée", file: #fileID, line: #line)
        } catch let error as SNMPDecodingError {
            try expect(error.message.contains("v3"), "raison v3 : \(error.message)")
        }
        try expect((try? SNMPTrapDecoder.decode(Array(v1.prefix(20)))) == nil, "octets tronqués")
        let get = SNMPMessage(community: "c", pdu: SNMPPDU(type: .getRequest, requestID: 1, varbinds: [])).encoded()
        try expect((try? SNMPTrapDecoder.decode(get)) == nil, "GetRequest refusée")
        guard case .rejected(let reason) = LogDecoder.trap(LogDatagram(bytes: v1, from: IPv4Address(10, 0, 0, 2), fromPort: 1, date: received),
                                                           community: "secret") else {
            throw TestFailure(message: "communauté différente : écartée", file: #fileID, line: #line)
        }
        try expect(reason.contains("communauté") && !reason.contains("public") && !reason.contains("secret"), "raison sans la communauté")
    }

    // MARK: Journal

    func message(_ minutesAgo: Double, _ host: String, _ severity: LogSeverity, _ text: String, source: LogSource = .syslog,
                 site: String = "siege", event: String? = nil, fields: [String: String] = [:]) -> LogMessage {
        LogMessage(date: received.addingTimeInterval(-minutesAgo * 60), source: source, severity: severity, host: host,
                   eventID: event, message: text, siteKey: site, siteName: site == "siege" ? "Siège" : "Laval", fields: fields)
    }

    suite.add("Journaux : conservation bornée (nombre et âge), ordre, doublons FortiGate") {
        var journal = LogJournal()
        let retention = LogRetention(maxMessages: 1_000, maxDays: 1)
        var list = (0..<1_200).map { message(Double($0) / 10, "10.0.0.1", .info, "m\($0)") }
        list.append(message(60 * 30, "10.0.0.1", .info, "trop vieux"))
        try expectEqual(journal.append(list, retention: retention, now: received), 1_201, "tous ajoutés")
        try expectEqual(journal.count, 1_000, "au plus 1 000 gardés")
        try expect(!journal.messages.contains { $0.message == "trop vieux" }, "plus d'un jour : retiré")
        try expect(zip(journal.messages, journal.messages.dropFirst()).allSatisfy { $0.date <= $1.date }, "trié par date")
        try expectEqual(journal.messages.last?.message, "m0", "le plus récent à la fin")
        // Un message plus ancien arrive après : remis à sa place.
        journal.append([message(5, "10.0.0.2", .info, "en retard")], retention: retention, now: received)
        try expect(zip(journal.messages, journal.messages.dropFirst()).allSatisfy { $0.date <= $1.date }, "toujours trié")
        // Journaux de la FortiGate relus : pas de doublon.
        let forti = [message(3, "10.0.0.1", .error, "IPsec down", source: .fortigate, event: "0101037131")]
        try expectEqual(journal.append(forti, retention: .standard, now: received), 1, "ajouté")
        var again = forti
        again[0].id = UUID()
        try expectEqual(journal.append(again, retention: .standard, now: received), 0, "relu : ignoré")
        try expectEqual(LogRetention.standard.maxMessages, 50_000, "50 000 par défaut")
        try expectEqual(LogRetention.standard.label, "50\u{202F}000\u{00A0}messages ou 7\u{00A0}jours", "libellé")
    }

    suite.add("Journaux : filtres (heure, gravité, source, site), recherche multiple et regroupement") {
        let messages = [
            message(120, "10.182.122.3", .warning, "port 14 is now off-line"),
            message(50, "10.182.122.3", .error, "Lien tombé", source: .trap, event: "linkDown"),
            message(40, "10.182.122.1", .alert, "admin login failed"),
            message(30, "10.182.122.1", .alert, "admin login failed"),
            message(20, "10.182.122.1", .alert, "admin login failed"),
            message(10, "10.20.0.2", .error, "port7 link down", site: "laval"),
            message(5, "10.182.122.106", .debug, "debug"),
        ]
        let hour = LogFilter(from: received.addingTimeInterval(-3600), minimumSeverity: .info)
        try expectEqual(hour.apply(messages).count, 5, "dernière heure, sans débogage")
        let siege = LogFilter(minimumSeverity: .error, siteKeys: ["siege"])
        try expectEqual(siege.apply(messages).count, 4, "Siège, ≥ erreur")
        let traps = LogFilter(sources: [.trap])
        try expectEqual(traps.apply(messages).map(\.eventID), ["linkDown"], "traps seulement")

        let names = ["10.182.122.3": "Switch étage 2", "10.182.122.1": "Passerelle"]
        func search(_ text: String) -> Int {
            LogFilter().apply(messages, search: SearchQuery(text, schema: .journaux), names: names).count
        }
        try expectEqual(search("appareil:\"switch étage\""), 2, "appareil: par le nom NetScope")
        try expectEqual(search("appareil:10.182.122.1"), 4, "appareil: par l'adresse (contient)")
        try expectEqual(search("gravite:alerte"), 3, "gravite:")
        try expectEqual(search("source:trap"), 1, "source:trap")
        try expectEqual(search("-source:trap appareil:switch"), 1, "exclusion")
        try expectEqual(search("site:laval"), 1, "site:")
        try expectEqual(search("evenement:linkdown"), 1, "evenement:")
        try expectEqual(search("login"), 3, "mot libre")
        try expectEqual(SearchSchema.journaux.field(forPrefix: "device")?.key, "appareil", "alias anglais")

        let groups = LogAnalysis.group(messages)
        try expectEqual(groups.count, 5, "trois refus réunis")
        let login = try logValue(groups.first { $0.latest.message == "admin login failed" }, "groupe")
        try expectEqual(login.count, 3, "trois fois")
        try expectEqual(login.firstDate, messages[2].date, "première fois")
        try expectEqual(login.latest.date, messages[4].date, "placé à la dernière fois")
        // Même texte, autre site : jamais réunis.
        let twoSites = LogAnalysis.group([message(1, "10.0.0.1", .info, "x"), message(1, "10.0.0.1", .info, "x", site: "laval")])
        try expectEqual(twoSites.count, 2, "sites séparés")

        let csv = LogAnalysis.csv([messages[1]], names: names, counts: [messages[1].id: 2])
        try expect(csv.hasPrefix("Date;Appareil;Adresse;Site;Source;Gravité;Programme;Événement;Message;Répétitions\r\n"), "en-tête CSV")
        try expect(csv.contains(";Switch étage 2;10.182.122.3;Siège;Trap SNMP;Erreur;;linkDown;Lien tombé;2\r\n"), "ligne CSV : \(csv)")
    }

    suite.add("Journaux : charge sans réseau (50 000 messages : ajout, filtre, recherche, regroupement, coupure)") {
        let hosts = (1...60).map { "10.182.122.\($0)" }
        let texts = ["port 14 is now off-line", "port 14 is now on-line", "admin login failed", "unable to reach time server",
                     "DHCP lease renewed", "Lien tombé"]
        let list = (0..<50_000).map { index in
            message(Double(index) * 0.15 / 60, hosts[index % hosts.count], LogSeverity(rawValue: index % 8)!, texts[index % texts.count] + " \(index % 97)")
        }
        let start = Date()
        var journal = LogJournal()
        journal.append(list, retention: .standard, now: received)
        let filtered = LogFilter(from: received.addingTimeInterval(-86_400), minimumSeverity: .info)
            .apply(journal.messages, search: SearchQuery("appareil:10.182.122.1 gravite:erreur", schema: .journaux))
        let groups = LogAnalysis.group(journal.messages)
        let outage = LogAnalysis.outage(around: received.addingTimeInterval(-3600), span: 600, messages: journal.messages)
        let elapsed = Date().timeIntervalSince(start)
        try expectEqual(journal.count, 50_000, "tout gardé")
        try expect(!filtered.isEmpty && !groups.isEmpty && !outage.messages.isEmpty, "résultats")
        try expect(elapsed < 6, "moins de 6 s en version de débogage (\(String(format: "%.2f", elapsed)) s)")
    }

    suite.add("Journaux : « Comprendre une coupure » (port qui rebondit, redémarrage, refus, silence)") {
        let down = message(10, "10.182.122.3", .error, "Lien tombé", source: .trap, event: "linkDown",
                           fields: ["1.3.6.1.2.1.31.1.1.1.1.14": "14"])
        let up = message(9.5, "10.182.122.3", .notice, "Lien rétabli", source: .trap, event: "linkUp",
                         fields: ["1.3.6.1.2.1.31.1.1.1.1.14": "14"])
        let arubaDown = message(10, "10.182.122.3", .warning, "port 14 is now off-line")
        let arubaUp = message(9.5, "10.182.122.3", .info, "port 14 is now on-line")
        let cisco = message(8, "10.182.122.2", .error, "Interface GigabitEthernet1/0/14, changed state to down")
        let auth = [7.3, 7.2, 7.1].map { message($0, "10.182.122.1", .alert, "Administrator admin login failed from ssh(10.0.0.5)") }
        let cold = message(2, "10.182.122.102", .warning, "Démarrage à froid", source: .trap, event: "coldStart")
        let far = message(120, "10.0.0.9", .error, "hors fenêtre")
        let all = ([far, down, arubaDown, up, arubaUp, cisco, cold] + auth).sorted { $0.date < $1.date }
        let report = LogAnalysis.outage(around: received.addingTimeInterval(-6 * 60), span: 600, messages: all,
                                        names: ["10.182.122.3": "Switch étage 2", "10.182.122.1": "Passerelle"])
        try expectEqual(report.messages.count, 9, "fenêtre ± 10 min, sans le message lointain")
        try expect(zip(report.messages, report.messages.dropFirst()).allSatisfy { $0.date <= $1.date }, "ordre chronologique")
        try expectEqual(report.devices.first?.name, "Switch étage 2", "le plus bavard d'abord")
        let kinds = report.findings.map(\.kind)
        try expectEqual(kinds.filter { $0 == .linkFlap }.count, 1, "un seul rebond (trap et Syslog du même port)")
        let flap = try logValue(report.findings.first { $0.kind == .linkFlap }, "rebond")
        try expectEqual(flap.title, "Port 14 de Switch étage 2 tombé puis remonté", "titre du rebond")
        try expect(flap.detail.hasPrefix("Coupé pendant 30\u{00A0}s"), "durée : \(flap.detail)")
        try expect(kinds.contains(.linkDown), "port Cisco resté tombé")
        try expect(kinds.contains(.reboot), "redémarrage")
        let refusals = report.findings.filter { $0.kind == .authFailure }
        try expectEqual(refusals.count, 1, "refus réunis")
        try expect(refusals[0].detail.hasPrefix("3 fois"), "nombre de refus")
        try expect(!kinds.contains(.firstSevere), "premier message grave déjà expliqué")
        try expect(zip(report.findings, report.findings.dropFirst()).allSatisfy { $0.date <= $1.date }, "constats dans l'ordre")
        let quiet = LogAnalysis.outage(around: received.addingTimeInterval(-86_400), span: 300, messages: all)
        try expectEqual(quiet.findings.map(\.kind), [.quiet], "fenêtre sans message")
        try expectEqual(LogFormat.offset(-130), "−2\u{00A0}min\u{00A0}10\u{00A0}s", "écart négatif")
        try expectEqual(LogFormat.offset(45), "+45\u{00A0}s", "écart positif")
    }

    // MARK: FortiGate (API REST, réponses fixes)

    suite.add("Journaux : lecture des journaux de la FortiGate (mémoire, disque, filtre de temps, gravité, refus)") {
        let body = """
        {"http_method":"GET","results":[
         {"date":"2026-11-04","time":"03:14:30","eventtime":1793780070000000000,"tz":"-0500","logid":"0101037131","type":"event","subtype":"vpn",
          "level":"error","devname":"FGT-SIEGE","logdesc":"IPsec phase 2 status changed","msg":"IPsec phase 2 status change","vpntunnel":"VPN-QUEBEC",
          "_metadata":{"timestamp":1793780070000}},
         {"date":"2026-11-04","time":"03:15:00","logid":"0100032001","type":"event","subtype":"system","level":"information",
          "logdesc":"Admin login successful","msg":"Administrator dany logged in successfully","devname":"FGT-SIEGE"},
         {"date":"2026-11-04","time":"03:16:00","level":"debug","msg":"débogage","devname":"FGT-SIEGE"},
         {"date":"2026-11-04","level":"error"}
        ],"vdom":"root","path":"log","name":"event","status":"success","serial":"FGT60F","version":"v7.4.4","build":2662}
        """
        let since = date(2026, 11, 4, 0, 0, 0)
        let memory = FortiFakeTransport(["/api/v2/log/memory/event/vpn": (200, body)])
        let reader = FortiGateReader(transport: memory, tokenForRedaction: FortiFixtures.token)
        let report = try await reader.readLogsKeepingCalls(FortiLogReadOptions(since: since, minimumSeverity: .info), host: "10.182.122.1")
        try expectEqual(report.storage, "memory", "mémoire d'abord")
        try expectEqual(report.messages.count, 2, "débogage et ligne illisible écartés")
        let vpn = report.messages[0]
        try expectEqual(vpn.source, .fortigate, "source FortiGate")
        try expectEqual(vpn.severity, .error, "level")
        try expectEqual(vpn.eventID, "0101037131", "logid")
        try expectEqual(vpn.hostname, "FGT-SIEGE", "devname")
        try expectEqual(vpn.message, "IPsec phase 2 status changed\u{00A0}: IPsec phase 2 status change", "logdesc + msg")
        try expectEqual(vpn.date, Date(timeIntervalSince1970: 1_793_780_070), "eventtime")
        try expectEqual(vpn.app, "FortiOS · vpn", "sous-type")
        try expect(memory.requested.allSatisfy { FortiLogPaths.all.contains($0) }, "seulement les adresses des journaux")
        let query = try logValue(memory.queries["/api/v2/log/memory/event/vpn"], "paramètres")
        let filters = query.filter { $0.name == "filter" }.compactMap(\.value)
        try expectEqual(filters, ["_metadata.timestamp>=\(Int64(since.timeIntervalSince1970 * 1000))"], "filtre de temps en millisecondes")
        try expectEqual(query.first { $0.name == "rows" }?.value, "500", "lignes demandées")
        try expect(!memory.requested.contains { $0.contains("/disk/") }, "disque pas lu : la mémoire a répondu")

        // Gravité minimale et plage fermée.
        let until = date(2026, 11, 4, 3, 14, 50)
        let strict = try await FortiGateReader(transport: FortiFakeTransport(["/api/v2/log/memory/event/vpn": (200, body)]))
            .readLogsKeepingCalls(FortiLogReadOptions(since: since, until: until, minimumSeverity: .error), host: "x")
        try expectEqual(strict.messages.map(\.eventID), ["0101037131"], "≥ erreur et avant la fin")
        try expectEqual(FortiLogReadOptions(since: since, until: until).query.filter { $0.name == "filter" }.count, 2, "plage : deux filtres")

        // Mémoire absente (404) : le disque répond.
        let disk = FortiFakeTransport(["/api/v2/log/disk/event/system": (200, body)])
        let diskReport = try await FortiGateReader(transport: disk).readLogsKeepingCalls(FortiLogReadOptions(since: since), host: "x")
        try expectEqual(diskReport.storage, "disk", "repli sur le disque")
        try expectEqual(diskReport.messages.count, 2, "messages du disque")

        // Aucun journal : note, pas d'erreur.
        let none = try await FortiGateReader(transport: FortiFakeTransport([:])).readLogsKeepingCalls(FortiLogReadOptions(since: since), host: "x")
        try expect(none.messages.isEmpty && !none.notes.isEmpty, "note « aucun journal »")

        // Droit « Log & Report » manquant partout : erreur 403 expliquée, appels gardés.
        var forbidden: [String: (Int, String)] = [:]
        for path in FortiLogPaths.all { forbidden[path] = (403, #"{"status":"error","http_status":403}"#) }
        do {
            _ = try await FortiGateReader(transport: FortiFakeTransport(forbidden)).readLogsKeepingCalls(FortiLogReadOptions(since: since), host: "x")
            throw TestFailure(message: "403 attendu", file: #fileID, line: #line)
        } catch let failure as FortiReadFailure {
            try expect(failure.error.logDescription.contains("Log & Report"), "droit nommé")
            try expectEqual(failure.calls.count, 8, "appels gardés pour le diagnostic (mémoire et disque)")
        }
    }

    // MARK: Sondes de la Surveillance

    suite.add("Journaux : sondes « Message Syslog de gravité ≥ X » et « Trap SNMP reçue »") {
        var probe = MonProbe(name: "Erreurs Syslog", kind: .syslogSeverity, target: "*", interval: 60)
        let logs = [
            message(0.5, "10.182.122.3", .warning, "port 14 is now off-line"),
            message(0.4, "10.182.122.1", .alert, "admin login failed"),
            message(5, "10.182.122.2", .critical, "trop ancien"),
            message(0.3, "10.182.122.3", .error, "Lien tombé", source: .trap, event: "linkDown"),
        ]
        var outcome = MonLogChecks.run(probe, target: "*", logs: logs, listening: [.syslog, .trap], now: received)
        try expect(outcome.result.problem?.hasPrefix("Alerte de 10.182.122.1") == true, "le plus grave : \(outcome.result.problem ?? "")")
        try expectEqual(outcome.result.value, "1\u{00A0}message ≥\u{00A0}Erreur", "seulement l'intervalle, sans les traps")
        probe.logSeverity = .warning
        outcome = MonLogChecks.run(probe, target: "*", logs: logs, listening: [.syslog], now: received)
        try expect(outcome.result.problem?.contains("(2 messages ≥\u{00A0}Avertissement)") == true, "deux messages")
        outcome = MonLogChecks.run(probe, target: "10.182.122.3", logs: logs, listening: [.syslog], now: received)
        try expect(outcome.result.problem?.contains("off-line") == true, "appareil visé")
        outcome = MonLogChecks.run(probe, target: "10.9.9.9", logs: logs, listening: [.syslog], now: received)
        try expectEqual(outcome.result.problem, nil, "autre appareil : rien")
        outcome = MonLogChecks.run(probe, target: "*", logs: logs, listening: [], now: received)
        try expect(outcome.noData, "récepteur arrêté : sans donnée")

        var trapProbe = MonProbe(name: "Ports", kind: .trapReceived, target: "*", interval: 60)
        trapProbe.trapFilter = "linkdown"
        outcome = MonLogChecks.run(trapProbe, target: "*", logs: logs, listening: [.trap], now: received)
        try expect(outcome.result.problem?.hasPrefix("Trap linkDown de 10.182.122.3") == true, "trap filtrée : \(outcome.result.problem ?? "")")
        trapProbe.trapFilter = "coldStart"
        outcome = MonLogChecks.run(trapProbe, target: "*", logs: logs, listening: [.trap], now: received)
        try expectEqual(outcome.result.problem, nil, "autre trap : rien")
        try expectEqual(outcome.result.value, "Aucune trap", "valeur")

        // Réglages relus (surveillance.json) et suite d'un double-clic.
        trapProbe.trapFilter = "linkDown"
        let data = try JSONEncoder().encode([probe, trapProbe])
        let decoded = try JSONDecoder().decode([MonProbe].self, from: data)
        try expectEqual(decoded[0].logSeverity, .warning, "gravité relue")
        try expectEqual(decoded[1].trapFilter, "linkDown", "filtre relu")
        let nav = NavResolver.primary(.probe(NavProbeRef(id: "p", name: "Ports", kind: .trapReceived, target: "10.182.122.3")),
                                      in: NavContext(activeSiteKey: "siege"))
        try expectEqual(nav.destination, NavDestination(.journaux, search: "source:trap appareil:10.182.122.3"), "sonde → Journaux filtré")
    }

    // MARK: Réseau : 127.0.0.1 seulement

    suite.add("Journaux : récepteurs Syslog et traps sur 127.0.0.1 (message et trap envoyés à soi-même, inform acquitté)") {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var outcomes: [LogDecoder.Outcome] = []
            func add(_ o: LogDecoder.Outcome) { lock.lock(); outcomes.append(o); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return outcomes.count }
            var first: LogDecoder.Outcome? { lock.lock(); defer { lock.unlock() }; return outcomes.first }
        }
        let loopback = IPv4Address(127, 0, 0, 1)
        let syslogBox = Box()
        let syslog = LogUDPListener(port: 0, address: loopback, name: "Syslog essai", handler: { syslogBox.add(LogDecoder.syslog($0)) })
        try syslog.start()
        defer { syslog.stop() }
        try expect(syslog.boundPort > 0, "port choisi par macOS")
        let line = SyslogParser.encode5424(severity: .error, date: Date(), hostname: "essai", app: "NetScope", msgID: "T1", message: "Bonjour 127.0.0.1")
        try expect(LogUDPListener.sendToSelf(line, port: syslog.boundPort), "envoi Syslog")
        for _ in 0..<50 where syslogBox.count == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .message(let received, _)? = syslogBox.first else {
            throw TestFailure(message: "message Syslog non reçu", file: #fileID, line: #line)
        }
        try expectEqual(received.message, "Bonjour 127.0.0.1", "message reçu")
        try expectEqual(received.host, "127.0.0.1", "émetteur")
        try expectEqual(received.severity, .error, "gravité")

        // Trap inform : le récepteur répond depuis son port, l'émetteur reçoit l'accusé.
        let trapBox = Box()
        final class ListenerRef: @unchecked Sendable { var value: LogUDPListener? }
        let trapListener = ListenerRef()
        let listener = LogUDPListener(port: 0, address: loopback, name: "Traps essai", handler: { datagram in
            let outcome = LogDecoder.trap(datagram, community: nil)
            trapBox.add(outcome)
            if case .message(_, let reply?) = outcome { trapListener.value?.reply(reply, to: datagram.from, port: datagram.fromPort) }
        })
        trapListener.value = listener
        try listener.start()
        defer { listener.stop() }
        let inform = SNMPTrapDecoder.encodeV2(community: "essai", trapOID: SNMPOID(stringLiteral: SNMPTrapCatalog.linkDown), uptime: 10,
                                              varbinds: [SNMPVarBind(oid: SNMPOID(stringLiteral: "1.3.6.1.2.1.2.2.1.1.3"), value: .integer(3))],
                                              requestID: 4242, inform: true)
        let answer = try logValue(LogUDPListener.exchangeWithSelf(inform, port: listener.boundPort, timeout: 2), "accusé de l'inform")
        let response = try SNMPMessage(decoding: answer)
        try expectEqual(response.pdu.type, .response, "Response")
        try expectEqual(response.pdu.requestID, 4242, "même request-id")
        guard case .message(let trapMessage, _)? = trapBox.first else {
            throw TestFailure(message: "trap non reçue", file: #fileID, line: #line)
        }
        try expectEqual(trapMessage.eventID, "linkDown", "trap reçue")
        try expectEqual(trapMessage.message, "Lien tombé\u{00A0}: ifIndex 3", "port par son ifIndex")

        // Port déjà pris : erreur claire.
        do {
            let busy = LogUDPListener(port: syslog.boundPort, address: loopback, handler: { _ in })
            try busy.start()
            busy.stop()
            throw TestFailure(message: "port occupé : erreur attendue", file: #fileID, line: #line)
        } catch let error as LogBindError {
            try expect(error.isInUse, "EADDRINUSE")
            try expect(error.errorDescription?.contains("déjà utilisé") == true, "explication")
        }
        try expect(LogBindError(code: EACCES, port: 514).errorDescription?.contains("5514") == true, "port 514 refusé : 5514 proposé")
    }

    // MARK: Robustesse (datagrammes hostiles, horloges décalées)

    suite.add("Journaux : datagrammes hostiles (mois sans heure, eventtime infini, horodatage énorme)") {
        // Commence par un nom de mois anglais sans heure : aucune lecture hors limites.
        for text in ["<13>Marking interface down now", "<13>Mar  x", "<14>May the force be with you",
                     "<13>Nov 4 hello world", "Dec .xxxxxxxxxxxx", "<14>Decoding failed on port 3"] {
            let m = SyslogParser.parse(text, from: "10.0.0.9", received: received, calendar: calendar)
            try expect(!m.message.isEmpty, "« \(text) » : message rendu")
            try expectEqual(m.date, received, "« \(text) » : heure de réception")
        }
        // eventtime infini ou démesuré : pas de boucle sans fin.
        for value in ["inf", "infinity", "1e400", "-inf", "nan", "1e300"] {
            let m = SyslogParser.parse("<13>logid=1 eventtime=\(value) msg=essai", from: "10.0.0.9", received: received, calendar: calendar)
            try expect(m.date.timeIntervalSince1970.isFinite, "eventtime=\(value) : date finie")
        }
        try expectEqual(SyslogParser.fortinetDate(["eventtime": "inf"], calendar: calendar), nil, "eventtime infini : écarté")
        // Réponse de la FortiGate avec un _metadata.timestamp hors de Int64 : pas de plantage.
        let json = #"{"results":[{"msg":"x","logid":"1","eventtime":"1e19","_metadata":{"timestamp":1e19}},{"msg":"y","date":"2026-11-04","time":"14:00:00","_metadata":{"timestamp":1.0e30}}]}"#
        let rows = FortiLogParser.messages(Data(json.utf8), host: "10.0.0.1", subtype: "system", calendar: calendar)
        try expect(rows.allSatisfy { $0.fields["_metadata.timestamp"] == nil }, "horodatage hors plage : ignoré")
        try expect(rows.contains { $0.message == "y" }, "date et heure lues à la place")
    }

    suite.add("Journaux : horloge de l'équipement décalée (2001) : gardé, daté de sa réception, sonde déclenchée") {
        var old = LogMessage(date: date(2001, 1, 1, 0, 0, 5), received: received, source: .syslog, severity: .error,
                             host: "10.0.0.7", message: "port 3 down", siteKey: "siege", siteName: "Siège")
        old.fields["x"] = "1"
        var journal = LogJournal()
        try expectEqual(journal.append([old], retention: .standard, now: received), 1, "ajouté")
        try expectEqual(journal.count, 1, "pas élagué")
        let kept = try logValue(journal.messages.first, "message gardé")
        try expectEqual(kept.date, received, "daté de la réception")
        try expect(kept.fields[LogMessage.declaredDateField]?.hasPrefix("2001-01-01") == true, "heure déclarée gardée")
        // Heure proche (moins d'un jour d'écart) : gardée telle quelle.
        let close = LogMessage(date: received.addingTimeInterval(-3_600), received: received, source: .syslog, severity: .info,
                               host: "10.0.0.7", message: "ok")
        try expectEqual(close.withTrustedClock().date, close.date, "écart d'une heure : heure déclarée")
        // La sonde voit le message même si l'heure déclarée était fausse (filtre sur la réception).
        let probe = MonProbe(name: "Erreurs", kind: .syslogSeverity, target: "*", interval: 60)
        let outcome = MonLogChecks.run(probe, target: "*", logs: [old], listening: [.syslog], now: received)
        try expect(outcome.result.problem != nil, "sonde déclenchée")
        try expectEqual(journal.messages(since: received.addingTimeInterval(-60)).count, 1, "messages récents : par la réception")
    }

    suite.add("Journaux : journal enregistré par une autre version (champs absents ou inconnus)") {
        let json = #"{"messages":[{"date":800000000,"source":"syslog","host":"10.0.0.1","message":"a"},{"date":800000001,"source":"inconnue","host":"x"},{"date":800000002,"source":"trap","host":"10.0.0.2","severity":99,"nouveau":true}]}"#
        let journal = try JSONDecoder().decode(LogJournal.self, from: Data(json.utf8))
        try expectEqual(journal.count, 2, "message illisible écarté, les autres gardés")
        try expectEqual(journal.messages.last?.severity, .info, "gravité inconnue : Info")
        try expectEqual(journal.messages.last?.message, "", "texte absent : vide")
    }

    suite.add("Journaux : doublons FortiGate au-delà de 20 000 messages récents") {
        var journal = LogJournal()
        let forti = message(600, "10.0.0.1", .error, "IPsec down", source: .fortigate, event: "0101037131")
        journal.append([forti], retention: .standard, now: received)
        journal.append((0..<21_000).map { message(Double($0) / 100, "10.0.0.2", .info, "m\($0)") }, retention: .standard, now: received)
        var again = forti
        again.id = UUID()
        try expectEqual(journal.append([again], retention: .standard, now: received), 0, "relu : toujours ignoré")
    }
}

/// Valeur présente, sinon échec du test.
private func logValue<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(message) — valeur absente", file: file, line: line) }
    return value
}
