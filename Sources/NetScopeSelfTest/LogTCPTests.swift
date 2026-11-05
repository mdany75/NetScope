import Darwin
import Foundation
import NetScopeCore

// Tests de la note 78 (Journaux) : cadrage Syslog en TCP (RFC 6587, par longueur et par saut de
// ligne), récepteur TCP, transfert vers un autre serveur Syslog et guide de configuration par
// marque. Le réseau se limite à 127.0.0.1 (récepteurs et transfert vers ce Mac).

/// Messages reçus par un récepteur d'essai (fil d'écoute → test).
private final class DatagramBox: @unchecked Sendable {
    let lock = NSLock()
    var items: [LogDatagram] = []
    func add(_ item: LogDatagram) { lock.lock(); items.append(item); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return items.map { String(decoding: $0.bytes, as: UTF8.self) } }
}

private func waitFor(_ box: DatagramBox, count: Int) async throws {
    for _ in 0..<100 where box.count < count { try await Task.sleep(nanoseconds: 20_000_000) }
}

func registerLogTCPTests(_ suite: TestSuite) {
    // MARK: Cadrage RFC 6587

    suite.add("Journaux TCP : cadrage par longueur (octet-counting), messages coupés entre deux lectures") {
        var decoder = SyslogFrameDecoder()
        let first = "<189>1 2026-11-04T14:02:07Z FGT-SIEGE - - - logid=0100032001 msg=\"Admin login\""
        let second = "<14>Nov  4 14:02:08 SW1 essai"
        let stream = Array("\(first.utf8.count) \(first)\(second.utf8.count) \(second)".utf8)
        // Livré en trois morceaux, dont un coupé au milieu de la longueur.
        var out = decoder.feed(Array(stream[0..<2]))
        try expectEqual(out.count, 0, "longueur incomplète : rien")
        out = decoder.feed(Array(stream[2..<40]))
        try expectEqual(out.count, 0, "message incomplet : rien")
        out += decoder.feed(Array(stream[40...]))
        try expectEqual(out.map { String(decoding: $0, as: UTF8.self) }, [first, second], "deux messages exacts")
        try expectEqual(decoder.pending, 0, "tampon vide")
        // Un message cadré par longueur peut contenir un saut de ligne.
        var multi = SyslogFrameDecoder()
        let body = "<13>pile\nd’appels"
        try expectEqual(multi.feed(Array("\(body.utf8.count) \(body)".utf8)).map { String(decoding: $0, as: UTF8.self) }, [body], "LF dans le message")
    }

    suite.add("Journaux TCP : cadrage par saut de ligne (CR LF, NUL), mélange avec la longueur et fin de connexion") {
        var decoder = SyslogFrameDecoder()
        let text = "<187>Nov  4 10:21:40 SW-ETG2-01 %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down\r\n<190>message 2\n\n<13>troisième\u{0}"
        let out = decoder.feed(Array(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
        try expectEqual(out, ["<187>Nov  4 10:21:40 SW-ETG2-01 %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down", "<190>message 2", "<13>troisième"], "trois messages")
        // Un émetteur qui change de cadrage entre deux messages.
        let mixed = decoder.feed(Array("12 <13>bonjour!<14>ligne\n".utf8)).map { String(decoding: $0, as: UTF8.self) }
        try expectEqual(mixed, ["<13>bonjour!", "<14>ligne"], "longueur puis saut de ligne")
        // Un message en texte qui commence par un chiffre n'est pas une longueur.
        let digits = decoder.feed(Array("2026-11-04 coupure secteur\n".utf8)).map { String(decoding: $0, as: UTF8.self) }
        try expectEqual(digits, ["2026-11-04 coupure secteur"], "chiffre sans espace : saut de ligne")
        // Fin de connexion : le reste devient un dernier message.
        _ = decoder.feed(Array("<13>sans fin de ligne".utf8))
        try expectEqual(decoder.finish().map { String(decoding: $0, as: UTF8.self) }, ["<13>sans fin de ligne"], "reste à la fermeture")
        try expectEqual(decoder.finish().count, 0, "plus rien ensuite")
    }

    suite.add("Journaux TCP : message sans fin de ligne plus long que la limite, longueur énorme") {
        var decoder = SyslogFrameDecoder()
        let huge = [UInt8](repeating: 0x41, count: SyslogFrameDecoder.maxMessage + 10)
        let out = decoder.feed([0x3C, 0x31, 0x33, 0x3E] + huge)
        try expectEqual(out.count, 1, "message coupé à la limite")
        try expectEqual(out.first?.count, SyslogFrameDecoder.maxMessage, "taille bornée")
        try expect(decoder.problems > 0, "problème compté")
        var other = SyslogFrameDecoder()
        let bogus = other.feed(Array("999999 <13>x\n".utf8)).map { String(decoding: $0, as: UTF8.self) }
        try expectEqual(bogus, ["999999 <13>x"], "longueur hors limite : lue comme une ligne")
        try expectEqual(SyslogFrameDecoder.octetCounted(Array("<13>a\n".utf8)), Array("5 <13>a".utf8), "cadrage à l’envoi")
    }

    // MARK: Récepteur TCP sur 127.0.0.1

    suite.add("Journaux TCP : récepteur sur 127.0.0.1 (deux connexions, deux cadrages, analyse Syslog)") {
        let box = DatagramBox()
        let loopback = IPv4Address(127, 0, 0, 1)
        let listener = LogTCPListener(port: 0, address: loopback, name: "Syslog TCP essai", handler: { box.add($0) })
        try listener.start()
        defer { listener.stop() }
        try expect(listener.boundPort > 0, "port choisi par macOS")
        let fortigate = "<189>date=2026-11-04 time=14:02:07 devname=\"FGT-SIEGE\" logid=\"0100032001\" type=\"event\" subtype=\"system\" level=\"notice\" msg=\"Administrateur connecté\""
        try expect(LogTCPListener.sendToSelf(SyslogFrameDecoder.octetCounted(Array(fortigate.utf8)), port: listener.boundPort), "envoi par longueur")
        try expect(LogTCPListener.sendToSelf(Array("<187>Nov  4 10:21:40 SW-ETG2-01 %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down\n".utf8),
                                             port: listener.boundPort), "envoi par saut de ligne")
        try await waitFor(box, count: 2)
        try expectEqual(box.count, 2, "deux messages reçus")
        let messages = box.items.map { LogDecoder.syslog($0) }.compactMap { outcome -> LogMessage? in
            if case .message(let message, _) = outcome { return message }
            return nil
        }
        try expect(messages.contains { $0.hostname == "FGT-SIEGE" && $0.eventID == "0100032001" }, "FortiGate en TCP analysée")
        try expect(messages.contains { $0.eventID == "LINK-3-UPDOWN" && $0.severity == .error }, "Cisco en TCP analysé")
        try expect(box.items.allSatisfy { $0.from == loopback }, "émetteur 127.0.0.1")

        // Port déjà pris en TCP : erreur claire, avec le bon transport.
        do {
            let busy = LogTCPListener(port: listener.boundPort, address: loopback, handler: { _ in })
            try busy.start()
            busy.stop()
            throw TestFailure(message: "port occupé : erreur attendue", file: #fileID, line: #line)
        } catch let error as LogBindError {
            try expect(error.isInUse, "EADDRINUSE")
            try expect(error.errorDescription?.contains("TCP") == true, "« port TCP » dans l’explication")
        }
    }

    // MARK: Transfert

    suite.add("Journaux : transfert vers un autre serveur (réglages, filtre, boucle refusée)") {
        var settings = SyslogForwardSettings()
        try expect(!settings.enabled, "désactivé par défaut")
        settings.enabled = true
        try expect(settings.problem(listening: []) != nil, "adresse manquante")
        settings.host = "127.0.0.1"
        settings.port = 5514
        try expect(settings.problem(listening: [(.udp, 5514)])?.contains("boucle") == true, "boucle vers soi-même refusée")
        try expectEqual(settings.problem(listening: [(.tcp, 5514)]), nil, "autre transport : permis")
        settings.host = "10.10.0.40"
        settings.port = 514
        try expectEqual(settings.problem(listening: [(.udp, 5514)]), nil, "serveur distant")
        try expectEqual(settings.destinationLabel, "10.10.0.40:514 (UDP)", "libellé")
        let received = Date(timeIntervalSince1970: 1_793_805_693)
        let message = SyslogParser.parse("<187>Nov  4 10:21:40 SW1 %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down", from: "10.0.0.2", received: received)
        let debug = SyslogParser.parse("<191>Nov  4 10:21:40 SW1 debug", from: "10.0.0.2", received: received)
        settings.minimumSeverity = .warning
        try expect(settings.accepts(message), "erreur transférée")
        try expect(!settings.accepts(debug), "débogage écarté")
        var trap = message
        trap.source = .trap
        try expect(!settings.accepts(trap), "traps non transférées par défaut")
        settings.includeTraps = true
        try expect(settings.accepts(trap), "traps sur demande")
        var forti = message
        forti.source = .fortigate
        try expect(!settings.accepts(forti), "journal lu sur la FortiGate : jamais renvoyé")
        // Octets relayés tels quels en UDP, cadrés par longueur en TCP.
        let raw = Array("<187>Nov  4 10:21:40 SW1 %LINK-3-UPDOWN: x\n".utf8)
        try expectEqual(settings.payload(for: message, original: raw), Array(raw.dropLast()), "UDP : octets reçus")
        settings.transport = .tcp
        let framed = settings.payload(for: message, original: raw)
        try expect(String(decoding: framed, as: UTF8.self).hasPrefix("\(raw.count - 1) <187>"), "TCP : longueur en tête")
        let encodedTrap = String(decoding: settings.payload(for: trap, original: nil), as: UTF8.self)
        try expect(encodedTrap.contains("<187>1 "), "trap convertie en 5424")
        // Lecture tolérante des réglages enregistrés.
        let decoded = try JSONDecoder().decode(SyslogForwardSettings.self, from: Data("{\"enabled\":true,\"host\":\"siem\"}".utf8))
        try expectEqual(decoded.port, 514, "port par défaut")
        try expectEqual(decoded.transport, .udp, "UDP par défaut")
    }

    suite.add("Journaux : transfert vers 127.0.0.1 en UDP et en TCP, serveur injoignable compté") {
        let loopback = IPv4Address(127, 0, 0, 1)
        let udpBox = DatagramBox()
        let udp = LogUDPListener(port: 0, address: loopback, name: "Relais UDP essai", handler: { udpBox.add($0) })
        try udp.start()
        defer { udp.stop() }
        let tcpBox = DatagramBox()
        let tcp = LogTCPListener(port: 0, address: loopback, name: "Relais TCP essai", handler: { tcpBox.add($0) })
        try tcp.start()
        defer { tcp.stop() }
        let lines = ["<187>Nov  4 10:21:40 SW1 %LINK-3-UPDOWN: Interface Gi1/0/14, changed state to down", "<13>Nov  4 10:21:41 SW1 deuxième"]
        let received = Date()
        let messages = lines.map { SyslogParser.parse($0, from: "10.0.0.2", received: received) }

        let viaUDP = SyslogForwarder(settings: SyslogForwardSettings(enabled: true, host: "127.0.0.1", port: udp.boundPort, transport: .udp))
        viaUDP.enqueue(zip(messages, lines).map { viaUDP.settings.payload(for: $0, original: Array($1.utf8)) })
        viaUDP.drain()
        try await waitFor(udpBox, count: 2)
        try expectEqual(udpBox.texts, lines, "UDP : messages relayés tels quels")
        try expectEqual(viaUDP.currentStatus.sent, 2, "deux envoyés")
        viaUDP.stop()

        let viaTCP = SyslogForwarder(settings: SyslogForwardSettings(enabled: true, host: "127.0.0.1", port: tcp.boundPort, transport: .tcp))
        viaTCP.enqueue(zip(messages, lines).map { viaTCP.settings.payload(for: $0, original: Array($1.utf8)) })
        viaTCP.drain()
        try await waitFor(tcpBox, count: 2)
        try expectEqual(tcpBox.texts, lines, "TCP : cadrage par longueur relu par le récepteur")
        try expect(viaTCP.currentStatus.connected, "connexion gardée ouverte")
        viaTCP.stop()

        // Port fermé sur 127.0.0.1 : connexion refusée, message compté comme perdu, pas de blocage.
        let closedPort: UInt16 = {
            let probe = LogTCPListener(port: 0, address: loopback, handler: { _ in })
            try? probe.start()
            let port = probe.boundPort
            probe.stop()
            return port
        }()
        let refused = SyslogForwarder(settings: SyslogForwardSettings(enabled: true, host: "127.0.0.1", port: closedPort, transport: .tcp))
        refused.enqueue([Array("1 a".utf8), Array("1 b".utf8)])
        refused.drain()
        let status = refused.currentStatus
        try expectEqual(status.sent, 0, "rien d’envoyé")
        try expectEqual(status.dropped, 2, "deux perdus (le second sans nouvel essai immédiat)")
        try expect(status.lastError?.contains("injoignable") == true, "raison lisible")
        refused.stop()
    }

    // MARK: Guide de configuration

    suite.add("Journaux : guide de configuration par marque (UDP, TCP, repli UDP)") {
        let mac = "10.182.122.142"
        let fgt = LogDeviceGuide.syslog(.fortigate, mac: mac, port: 5514, transport: .tcp)
        try expect(fgt.commands.contains("set mode reliable"), "FortiGate en TCP : mode reliable")
        try expect(fgt.commands.contains("set port 5514") && fgt.commands.contains("set server \"\(mac)\""), "port et adresse")
        try expectEqual(fgt.verify, "diagnose log test", "vérification FortiGate")
        try expect(LogDeviceGuide.syslog(.fortigate, mac: mac, port: 5514, transport: .udp).commands.contains("set mode udp"), "FortiGate en UDP")
        try expect(LogDeviceGuide.syslog(.cisco, mac: mac, port: 5514, transport: .tcp).commands.contains("logging host \(mac) transport tcp port 5514"), "Cisco TCP")
        try expect(LogDeviceGuide.syslog(.arubaOS, mac: mac, port: 5514, transport: .udp).commands.contains("logging \(mac) udp 5514"), "AOS-S UDP")
        try expect(LogDeviceGuide.syslog(.arubaCX, mac: mac, port: 5514, transport: .tcp).commands.contains("logging \(mac) tcp 5514"), "AOS-CX TCP")
        try expect(LogDeviceGuide.syslog(.linux, mac: mac, port: 5514, transport: .tcp).commands.contains("@@\(mac):5514"), "rsyslog TCP")
        let unifi = LogDeviceGuide.syslog(.unifi, mac: mac, port: 5514, transport: .tcp)
        try expectEqual(unifi.transport, .udp, "UniFi : repli sur UDP")
        try expect(unifi.isInterfacePath, "UniFi : chemin dans l’interface")
        try expectEqual(LogDeviceGuide.syslog(.edgeOS, mac: mac, port: 5514, transport: .tcp).transport, .udp, "EdgeOS : UDP")
        try expect(Set(LogDeviceGuide.Brand.allCases.map(\.family)).isSuperset(of: ["Fortinet", "Cisco", "HP/Aruba", "Ubiquiti"]), "cinq marques demandées")
        for brand in LogDeviceGuide.Brand.allCases {
            let step = LogDeviceGuide.syslog(brand, mac: mac, port: 5514, transport: .udp)
            try expect(step.commands.contains(mac) && step.commands.contains("5514"), "\(brand.label) : adresse et port")
        }
        try expectEqual(LogDeviceCommands.syslog(mac: mac, port: 5514).count, LogDeviceGuide.Brand.allCases.count, "anciens exemples tirés du guide")
    }
}
