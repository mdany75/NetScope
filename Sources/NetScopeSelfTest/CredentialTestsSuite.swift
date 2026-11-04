import Darwin
import Foundation
@testable import NetScopeCore

// Tests des identifiants (note 13) : SNMP v3 (vecteurs des RFC, codec, faux agent sur 127.0.0.1),
// test SNMP v2c, analyse des sorties de ssh et du test WMI. Aucun trafic hors de 127.0.0.1.

func registerCredentialTests(_ suite: TestSuite) {
    suite.add("SNMP v3 : MD5 et HMAC (RFC 1321, 2202, 4231)") {
        try expectEqual(SNMPCryptoBytes.hex(SNMPMD5.digest([])), "d41d8cd98f00b204e9800998ecf8427e", "MD5 vide")
        try expectEqual(SNMPCryptoBytes.hex(SNMPMD5.digest(Array("abc".utf8))), "900150983cd24fb0d6963f7d28e17f72", "MD5 abc")
        try expectEqual(SNMPCryptoBytes.hex(SNMPMD5.digest(Array("The quick brown fox jumps over the lazy dog".utf8))),
                        "9e107d9d372bb6826bd81d3542a419d6", "MD5 phrase")
        let data = Array("what do ya want for nothing?".utf8)
        try expectEqual(SNMPCryptoBytes.hex(SNMPAuthProtocol.md5.hmac(key: Array("Jefe".utf8), data)),
                        "750c783e6ab0b503eaa86e310a5db738", "HMAC-MD5")
        try expectEqual(SNMPCryptoBytes.hex(SNMPAuthProtocol.sha256.hmac(key: Array("Jefe".utf8), data)),
                        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA-256")
        try expectEqual(SNMPAuthProtocol(label: "SHA-256"), .sha256, "libellé des Réglages")
        try expectEqual(SNMPPrivProtocol(label: "AES-128"), .aes128, "libellé AES")
    }

    suite.add("SNMP v3 : dérivation et localisation des clés (RFC 3414 A.3)") {
        let engine: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
        try expectEqual(SNMPCryptoBytes.hex(SNMPAuthProtocol.md5.passwordToKey("maplesyrup")), "9faf3283884e92834ebc9847d8edd963", "Ku MD5")
        try expectEqual(SNMPCryptoBytes.hex(SNMPAuthProtocol.md5.localizedKey(password: "maplesyrup", engineID: engine)),
                        "526f5eed9fcce26f8964c2930787d82b", "Kul MD5")
        try expectEqual(SNMPCryptoBytes.hex(SNMPAuthProtocol.sha1.passwordToKey("maplesyrup")),
                        "9fb5cc0381497b3793528939ff788d5d79145211", "Ku SHA-1")
        try expectEqual(SNMPCryptoBytes.hex(SNMPAuthProtocol.sha1.localizedKey(password: "maplesyrup", engineID: engine)),
                        "6695febc9288e36282235fc7151f128497b38f3f", "Kul SHA-1")
        // AES-256 avec SHA-1 : clé allongée (Blumenthal) à 32 octets, préfixe = Kul.
        let long = SNMPPrivProtocol.aes256.key(password: "maplesyrup", engineID: engine, auth: .sha1)
        try expectEqual(long.count, 32, "clé AES-256")
        try expectEqual(SNMPCryptoBytes.hex(Array(long.prefix(20))), "6695febc9288e36282235fc7151f128497b38f3f", "début = Kul")
        try expectEqual(SNMPAuthProtocol.sha512.macLength, 48, "RFC 7860 : HMAC-SHA-512 tronqué à 48 octets")
    }

    suite.add("SNMP v3 : message authentifié et chiffré, aller-retour (AES, DES)") {
        let engine: [UInt8] = [0x80, 0x00, 0x00, 0x09, 0x03, 0x00, 0x2C, 0x86, 0x1F, 0x00, 0x00, 0x01]
        let pdu = SNMPPDU(type: .getRequest, requestID: 4242, varbinds: [SNMPVarBind(oid: SNMPCredentialTest.sysName)])
        let usm = SNMPUSMParameters(engineID: engine, boots: 7, time: 123_456, user: "netscope")
        for priv in [SNMPPrivProtocol.aes128, .des, .aes256] {
            let authKey = SNMPAuthProtocol.sha256.localizedKey(password: "authpass123", engineID: engine)
            let privKey = priv.key(password: "privpass123", engineID: engine, auth: .sha256)
            let bytes = try SNMPv3Codec.encode(msgID: 4242, pdu: pdu, usm: usm, level: .authPriv, contextEngineID: engine,
                                               contextName: "", auth: .sha256, authKey: authKey, priv: priv, privKey: privKey, salt: 99)
            let decoded = try SNMPv3Codec.decode(bytes, auth: .sha256, authKey: authKey, priv: priv, privKey: privKey)
            try expectEqual(decoded.pdu, pdu, "PDU retrouvée (\(priv.rawValue))")
            try expectEqual(decoded.usm.user, "netscope", "utilisateur")
            try expect(decoded.isAuthenticated && decoded.isEncrypted, "drapeaux auth et priv")
            // Le nom de l'objet demandé n'apparaît pas en clair.
            let oidBytes = SNMPBER.encode(.oid(SNMPCredentialTest.sysName))
            try expect(!bytes.windows(oidBytes.count).contains(oidBytes), "scopedPDU chiffré (\(priv.rawValue))")
            let wrongAuth = SNMPAuthProtocol.sha256.localizedKey(password: "mauvais-mdp", engineID: engine)
            try expectThrows(SNMPv3Error.badResponseDigest, "condensé faux") {
                _ = try SNMPv3Codec.decode(bytes, auth: .sha256, authKey: wrongAuth, priv: priv, privKey: privKey)
            }
            let wrongPriv = priv.key(password: "mauvais-mdp", engineID: engine, auth: .sha256)
            do {
                let garbled = try SNMPv3Codec.decode(bytes, auth: .sha256, authKey: authKey, priv: priv, privKey: wrongPriv)
                try expect(garbled.pdu != pdu, "mauvaise clé de confidentialité : PDU illisible")
            } catch let error as SNMPv3Error {
                try expectEqual(error, .responseDecryption, "déchiffrement refusé")
            }
        }
    }

    suite.add("SNMP v3 : rapports de l'agent reconnus et expliqués") {
        let report = SNMPPDU(type: .report, requestID: 1, varbinds: [SNMPVarBind(oid: "1.3.6.1.6.3.15.1.1.3.0", value: .counter32(4))])
        try expectEqual(SNMPv3Codec.report(in: report), .unknownUserName, "usmStatsUnknownUserNames")
        let digest = SNMPPDU(type: .report, requestID: 1, varbinds: [SNMPVarBind(oid: "1.3.6.1.6.3.15.1.1.5.0", value: .counter32(1))])
        try expectEqual(SNMPv3Codec.report(in: digest), .wrongDigest, "usmStatsWrongDigests")
        try expectEqual(SNMPv3Codec.report(in: SNMPPDU(type: .response, requestID: 1, varbinds: [])), nil, "réponse ordinaire")
        let (unknown, text) = SNMPCredentialTest.explain(SNMPv3Error.report(.unknownUserName), version3: true, host: "10.0.0.2")
        try expectEqual(unknown, .unknownUser, "catégorie utilisateur inconnu")
        try expect(text.contains("utilisateur inconnu"), "message utilisateur inconnu")
        try expectEqual(SNMPCredentialTest.explain(SNMPv3Error.report(.decryptionError), version3: true, host: "x").0, .decryption, "déchiffrement")
        try expectEqual(SNMPCredentialTest.explain(SNMPv3Error.report(.wrongDigest), version3: true, host: "x").0, .authentication, "authentification")
        let (timeout, hint) = SNMPCredentialTest.explain(SNMPError.timeout("10.0.0.2"), version3: false, host: "10.0.0.2")
        try expectEqual(timeout, .timeout, "délai")
        try expect(hint.contains("Communauté refusée"), "v2c : communauté refusée évoquée")
        try expectEqual(SNMPCredentialTest.explain(SNMPError.agent(status: 16, index: 1), version3: false, host: "x").0,
                        .communityRejected, "authorizationError")
        let success = SNMPCredentialTest.success(from: [
            SNMPVarBind(oid: SNMPCredentialTest.sysDescr, value: .octetString(Array("Cisco IOS Software, C9300\nTechnical Support".utf8))),
            SNMPVarBind(oid: SNMPCredentialTest.sysName, value: .octetString(Array("SW-CORE-01".utf8))),
            SNMPVarBind(oid: SNMPCredentialTest.sysUpTime, value: .timeTicks(105_242_000)),
        ], milliseconds: 41)
        try expectEqual(success.shortDescr, "Cisco IOS Software, C9300", "première ligne de sysDescr")
        try expectEqual(success.uptimeText, "12\u{00A0}j 4\u{00A0}h 20\u{00A0}min", "uptime")
        try expect(SNMPCredentialTest.message(for: success).hasPrefix("Réussi · sysName SW-CORE-01"), "message réussi")
    }

    suite.add("SNMP v3 : test complet contre un faux agent sur 127.0.0.1") {
        let agent = try FakeSNMPv3Agent(user: "netscope", authPassword: "authpass123", privPassword: "privpass123")
        defer { agent.stop() }
        let good = SNMPv3Credentials(user: "netscope", level: .authPriv, auth: .sha256, authPassword: "authpass123",
                                     priv: .aes128, privPassword: "privpass123")
        let ok = await SNMPCredentialTest.run(host: IPv4Address(127, 0, 0, 1), credentials: good, port: agent.port, timeout: 1)
        try expectEqual(ok.success?.sysName, "AGENT-TEST", "sysName lu en authPriv")
        try expectEqual(ok.success?.uptimeTicks, 4200, "sysUpTime")
        var unknown = good
        unknown.user = "inconnu"
        let refused = await SNMPCredentialTest.run(host: IPv4Address(127, 0, 0, 1), credentials: unknown, port: agent.port, timeout: 1)
        try expectEqual(refused.failure, .unknownUser, "utilisateur inconnu")
        var wrong = good
        wrong.authPassword = "pas-le-bon-mdp"
        let digest = await SNMPCredentialTest.run(host: IPv4Address(127, 0, 0, 1), credentials: wrong, port: agent.port, timeout: 1)
        try expectEqual(digest.failure, .authentication, "mauvais mot de passe d'authentification")
        var wrongPriv = good
        wrongPriv.privPassword = "pas-le-bon-mdp"
        let decrypt = await SNMPCredentialTest.run(host: IPv4Address(127, 0, 0, 1), credentials: wrongPriv, port: agent.port, timeout: 1)
        try expectEqual(decrypt.failure, .decryption, "mauvais mot de passe de confidentialité")
    }

    suite.add("SNMP v2c : test vers un port fermé de 127.0.0.1") {
        let port = try FakeSNMPv3Agent.freeUDPPort()
        let outcome = await SNMPCredentialTest.run(host: IPv4Address(127, 0, 0, 1), community: "lecture", port: port, timeout: 0.5)
        try expect(outcome.failure == .portClosed || outcome.failure == .timeout, "port fermé ou délai : \(outcome.message)")
        try expect(outcome.message.hasPrefix("Échec"), "message d'échec")
    }

    suite.add("SSH : ligne de commande (BatchMode, known_hosts propre, port)") {
        let knownHosts = URL(fileURLWithPath: "/tmp/netscope-known_hosts")
        let key = RemoteCredential(kind: .ssh, name: "ssh-netadmin", user: "netadmin", port: 2222, sshMethod: .key, keyPath: "~/.ssh/id_ed25519")
        let invocation = SSHCredentialTest.invocation(host: "10.0.0.2", credential: key, knownHosts: knownHosts, askpass: nil)
        try expect(invocation.arguments.contains("BatchMode=yes"), "BatchMode sans secret")
        try expect(invocation.arguments.contains("UserKnownHostsFile=/tmp/netscope-known_hosts"), "known_hosts de NetScope")
        try expect(invocation.arguments.contains("StrictHostKeyChecking=accept-new"), "empreinte acceptée au premier test seulement")
        try expect(invocation.arguments.contains("2222") && invocation.arguments.contains("netadmin"), "port et utilisateur")
        try expect(invocation.arguments.contains((("~/.ssh/id_ed25519") as NSString).expandingTildeInPath), "clé choisie")
        try expectEqual(Array(invocation.arguments.suffix(2)), ["10.0.0.2", "uname -a"], "hôte et commande inoffensive")
        try expect(invocation.environment["SSH_ASKPASS"] == nil, "pas d'askpass sans secret")
        let password = RemoteCredential(kind: .ssh, name: "pw", user: "admin", sshMethod: .password)
        let withSecret = SSHCredentialTest.invocation(host: "h", credential: password, knownHosts: knownHosts,
                                                      askpass: URL(fileURLWithPath: "/tmp/askpass.sh"))
        try expect(withSecret.arguments.contains("BatchMode=no"), "mot de passe par askpass")
        try expectEqual(withSecret.environment["SSH_ASKPASS_REQUIRE"], "force", "askpass forcé")
        try expect(!withSecret.arguments.joined().contains("secret"), "aucun secret dans les arguments")
    }

    suite.add("SSH : analyse des sorties fixes de ssh") {
        let ok = SSHCredentialTest.analyze(exitCode: 0, stdout: "Linux nas 6.1.0 #1 SMP x86_64 GNU/Linux\n", stderr: "", host: "10.0.0.5", milliseconds: 180)
        try expectEqual(ok.status, .success, "réussi")
        try expect(ok.message.contains("Linux nas 6.1.0"), "sortie de uname")
        let denied = SSHCredentialTest.analyze(exitCode: 255, stdout: "", stderr: "netadmin@10.0.0.2: Permission denied (publickey,password).\n",
                                               host: "10.0.0.2", milliseconds: 90)
        try expectEqual(denied.status, .failure, "refus")
        try expect(denied.message.contains("authentification refusée"), "authentification refusée")
        let refused = SSHCredentialTest.analyze(exitCode: 255, stdout: "", stderr: "ssh: connect to host 10.0.0.9 port 22: Connection refused\n",
                                                host: "10.0.0.9", milliseconds: 3)
        try expect(refused.message.contains("connexion refusée"), "port fermé")
        let timeout = SSHCredentialTest.analyze(exitCode: 255, stdout: "", stderr: "ssh: connect to host 10.0.0.9 port 22: Operation timed out\n",
                                                host: "10.0.0.9", milliseconds: 6000)
        try expect(timeout.message.contains("délai dépassé"), "délai")
        let changed = SSHCredentialTest.analyze(exitCode: 255, stdout: "", stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.\n",
                                                host: "10.0.0.2", milliseconds: 40)
        try expect(changed.message.contains("empreinte"), "empreinte changée")
        let legacy = SSHCredentialTest.analyze(exitCode: 255, stdout: "", stderr: "Unable to negotiate with 10.0.0.3 port 22: no matching key exchange method found.\n",
                                               host: "10.0.0.3", milliseconds: 20)
        try expect(legacy.message.contains("algorithmes incompatibles"), "vieux switch")
        let noShell = SSHCredentialTest.analyze(exitCode: 1, stdout: "% Invalid input detected at '^' marker.\n", stderr: "", host: "SW", milliseconds: 300)
        try expectEqual(noShell.status, .partial, "switch sans uname : authentifié quand même")
        let killed = SSHCredentialTest.analyze(exitCode: 15, stdout: "", stderr: "", host: "x", milliseconds: 12_000, timedOut: true)
        try expect(killed.message.contains("délai dépassé"), "processus arrêté après le délai")
    }

    suite.add("SSH : vrai /usr/bin/ssh vers un port fermé de 127.0.0.1") {
        guard FileManager.default.isExecutableFile(atPath: SSHCredentialTest.executable) else {
            throw TestSkipped(reason: "/usr/bin/ssh absent")
        }
        let port = try ScanTestListener.freePort()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-ssh-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let credential = RemoteCredential(kind: .ssh, name: "local", user: "personne", port: port, sshMethod: .password)
        let temp = FileManager.default.temporaryDirectory.path
        func askpassFolders() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []).filter { $0.hasPrefix("netscope-ssh-") && !$0.contains("-test-") })
        }
        let before = askpassFolders()
        let outcome = await SSHCredentialTest.run(host: "127.0.0.1", credential: credential, secret: "pas-un-vrai-mdp",
                                                  knownHosts: folder.appendingPathComponent("known_hosts"), connectTimeout: 2)
        try expectEqual(outcome.status, .failure, "échec attendu : \(outcome.message)")
        try expect(outcome.message.contains("connexion refusée"), "port fermé reconnu : \(outcome.message)")
        try expectEqual(askpassFolders(), before, "script askpass temporaire supprimé")
    }

    suite.add("WMI : bilan honnête d'après les ports 135, 5985, 5986") {
        let ports = WMIReachabilityTest.ports
        let open = WMIReachabilityTest.analyze(host: "10.10.0.10", states: [(ports[0], .open(milliseconds: 4)), (ports[1], .refused(milliseconds: 2)),
                                                                            (ports[2], .timeout)])
        try expectEqual(open.status, .partial, "joignable, authentification non vérifiée")
        try expect(open.message.contains("135") && open.message.contains("pas de client WMI"), "message honnête")
        let closed = WMIReachabilityTest.analyze(host: "h", states: ports.map { ($0, .refused(milliseconds: 1)) })
        try expectEqual(closed.status, .failure, "tout fermé")
        try expect(closed.message.contains("fermés"), "ports fermés")
        let silent = WMIReachabilityTest.analyze(host: "h", states: ports.map { ($0, .timeout) })
        try expect(silent.message.contains("aucune réponse"), "hôte muet")
        try expect(WMIReachabilityTest.limitation.contains("macOS n’a pas de client WMI"), "limite expliquée")
    }

    suite.add("Identifiants SSH/WMI : décodage tolérant, domaine\\utilisateur") {
        let old = Data(#"{"version":1,"credentials":[{"name":"wmi-domaine","kind":"wmi","user":"svc"}]}"#.utf8)
        let store = try JSONDecoder().decode(RemoteCredentialStore.self, from: old)
        try expectEqual(store.credentials.first?.port, 135, "port WMI par défaut")
        try expectEqual(store.credentials.first?.sshMethod, .key, "méthode par défaut")
        let split = RemoteCredential.splitWindowsUser("BUREAU\\svc-ipscan")
        try expectEqual(split.domain, "BUREAU", "domaine")
        try expectEqual(split.user, "svc-ipscan", "utilisateur")
        try expectEqual(RemoteCredential.splitWindowsUser("svc@bureau.local").domain, "bureau.local", "forme UPN")
        var wmi = RemoteCredential(kind: .wmi, name: "w", user: "svc", domain: "BUREAU")
        try expectEqual(wmi.qualifiedUser, "BUREAU\\svc", "affichage")
        wmi.domain = ""
        try expectEqual(wmi.qualifiedUser, "svc", "compte local")
        let encoded = try JSONEncoder().encode(RemoteCredentialStore(credentials: [wmi]))
        try expect(!String(decoding: encoded, as: UTF8.self).lowercased().contains("password"), "aucun champ de mot de passe")
    }

    suite.add("Présence : TCP et UDP vers 127.0.0.1 (ouvert, refusé, port injoignable)") {
        let listener = try ScanTestListener()
        defer { listener.close() }
        let open = await ScanPresenceProber.tcp(IPv4Address(127, 0, 0, 1), port: listener.port, timeout: 1)
        if case .open = open {} else { throw TestFailure(message: "port d'écoute ouvert : \(open)", file: #fileID, line: #line) }
        let closedPort = try ScanTestListener.freePort()
        let closed = await ScanPresenceProber.tcp(IPv4Address(127, 0, 0, 1), port: closedPort, timeout: 1)
        if case .refused = closed {} else { throw TestFailure(message: "port fermé refusé : \(closed)", file: #fileID, line: #line) }
        try expect(closed.hostAnswered, "un refus prouve la présence de l'hôte")
        let udpPort = try FakeSNMPv3Agent.freeUDPPort()
        let udp = await ScanPresenceProber.udp(IPv4Address(127, 0, 0, 1), port: udpPort, timeout: 0.5)
        try expect(udp == .silent || udp.hostAnswered, "UDP : réponse cohérente (\(udp))")
        try expectEqual(ScanPresenceProber.payload(for: 123).count, 48, "requête NTP")
    }
}

/// Faux agent SNMP v3 sur 127.0.0.1 : découverte, utilisateur unique, authPriv SHA-256/AES-128.
final class FakeSNMPv3Agent: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let user: String
    private let authPassword: String
    private let privPassword: String
    private let engine: [UInt8] = [0x80, 0x00, 0x1F, 0x88, 0x04, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x4F, 0x50, 0x45]
    private let running = OnceFlagTest()

    init(user: String, authPassword: String, privPassword: String) throws {
        self.user = user
        self.authPassword = authPassword
        self.privPassword = privPassword
        (fd, port) = try FakeSNMPv3Agent.bindUDP()
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let thread = Thread { [self] in self.loop() }
        thread.start()
    }

    func stop() {
        running.stop()
        Thread.sleep(forTimeInterval: 0.3)
        Darwin.close(fd)
    }

    static func freeUDPPort() throws -> UInt16 {
        let (fd, port) = try bindUDP()
        Darwin.close(fd)
        return port
    }

    private static func bindUDP() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw TestSkipped(reason: "socket UDP indisponible") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = IPv4Address(127, 0, 0, 1).value.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Bool in
                Darwin.bind(fd, raw, length) == 0 && getsockname(fd, raw, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            throw TestSkipped(reason: "écoute UDP locale impossible")
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while running.isRunning {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, raw, &length) }
                }
            }
            guard count > 0, let reply = answer(Array(buffer[0..<count])) else { continue }
            _ = withUnsafePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    reply.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, raw, length) }
                }
            }
        }
    }

    private func report(_ suffix: UInt32, to request: SNMPv3Message) -> [UInt8]? {
        let pdu = SNMPPDU(type: .report, requestID: request.pdu?.requestID ?? request.msgID,
                          varbinds: [SNMPVarBind(oid: SNMPOID([1, 3, 6, 1, 6, 3, 15, 1, 1, suffix, 0]), value: .counter32(1))])
        return try? SNMPv3Codec.encode(msgID: request.msgID, pdu: pdu, usm: SNMPUSMParameters(engineID: engine, boots: 3, time: 900),
                                       level: .noAuthNoPriv, reportable: false, contextEngineID: engine, contextName: "")
    }

    private func answer(_ bytes: [UInt8]) -> [UInt8]? {
        guard let request = try? SNMPv3Codec.decode(bytes) else { return nil }
        if request.usm.engineID.isEmpty { return report(4, to: request) }      // unknownEngineID : découverte
        guard request.usm.user == user else { return report(3, to: request) }  // unknownUserName
        let authKey = SNMPAuthProtocol.sha256.localizedKey(password: authPassword, engineID: engine)
        let privKey = SNMPPrivProtocol.aes128.key(password: privPassword, engineID: engine, auth: .sha256)
        let decoded: SNMPv3Message
        do {
            decoded = try SNMPv3Codec.decode(bytes, auth: .sha256, authKey: authKey, priv: .aes128, privKey: privKey)
        } catch SNMPv3Error.badResponseDigest {
            return report(5, to: request)                                       // wrongDigest
        } catch {
            return report(6, to: request)                                       // decryptionError
        }
        guard let pdu = decoded.pdu, pdu.type == .getRequest else { return report(6, to: request) }
        let values: [SNMPOID: SNMPValue] = [
            SNMPCredentialTest.sysName: .octetString(Array("AGENT-TEST".utf8)),
            SNMPCredentialTest.sysDescr: .octetString(Array("Faux agent NetScope".utf8)),
            SNMPCredentialTest.sysUpTime: .timeTicks(4200),
        ]
        let response = SNMPPDU(type: .response, requestID: pdu.requestID,
                               varbinds: pdu.varbinds.map { SNMPVarBind(oid: $0.oid, value: values[$0.oid] ?? .noSuchObject) })
        return try? SNMPv3Codec.encode(msgID: decoded.msgID, pdu: response,
                                       usm: SNMPUSMParameters(engineID: engine, boots: 3, time: 900, user: user),
                                       level: .authPriv, reportable: false, contextEngineID: engine, contextName: "",
                                       auth: .sha256, authKey: authKey, priv: .aes128, privKey: privKey, salt: 7)
    }
}

/// Drapeau d'arrêt partagé entre fils (tests).
final class OnceFlagTest: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

extension Array where Element == UInt8 {
    /// Sous-suites contiguës de longueur `size` (recherche d'octets).
    func windows(_ size: Int) -> [[UInt8]] {
        guard size > 0, count >= size else { return [] }
        return (0...(count - size)).map { Array(self[$0..<($0 + size)]) }
    }
}
