import Foundation
import NetScopeCore

// Note 73 : actions sur un port (cycle PoE, redémarrage). Tout est vérifié sans réseau : garde-fous,
// requêtes FortiGate construites, SET SNMP encodés en BER octet par octet, déroulement du cycle
// et suivi du retour avec un faux switch, un faux ping et une horloge virtuelle.

/// Faux transport FortiGate : garde les requêtes, renvoie une réponse fixe.
private final class FakeFortiWriter: FortiWriteTransport, @unchecked Sendable {
    let lock = NSLock()
    var requests: [FortiWriteRequest] = []
    let response: FortiHTTPResponse

    init(status: Int, body: String) { response = FortiHTTPResponse(status: status, body: Data(body.utf8)) }

    func send(_ request: FortiWriteRequest) async throws -> FortiHTTPResponse {
        lock.withLock { requests.append(request) }
        return response
    }
}

/// Faux switch : note chaque écriture ; les `failOn` premières remises échouent.
private final class FakePoEWriter: PoEPortWriter, @unchecked Sendable {
    let lock = NSLock()
    var writes: [Bool] = []
    var failOnFirst: Int
    var failOff: Bool

    init(failOnFirst: Int = 0, failOff: Bool = false) {
        self.failOnFirst = failOnFirst
        self.failOff = failOff
    }

    func setPoE(enabled: Bool) async throws {
        try record(enabled)
    }

    private func record(_ enabled: Bool) throws {
        try lock.withLock {
            writes.append(enabled)
            if !enabled, failOff { throw PortActionError.snmpWriteRefused("accès refusé") }
            if enabled, failOnFirst > 0 {
                failOnFirst -= 1
                throw PortActionError.snmpNoResponse("10.0.0.2")
            }
        }
    }
}

/// Horloge virtuelle : l'attente fait avancer le temps, un ping prend une seconde.
private final class VirtualClock: @unchecked Sendable {
    let lock = NSLock()
    var time = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time += seconds } }
}

/// Faux ping : ne répond pas entre `silentFrom` et `silentUntil` secondes après le départ.
private struct ScriptedPinger: ScanPinging {
    let clock: VirtualClock
    let start: Date
    let silentFrom: Double
    let silentUntil: Double

    func ping(_ ip: IPv4Address, timeout: Duration) async -> Double? {
        let t = clock.now().timeIntervalSince(start)
        clock.advance(1)
        return (t >= silentFrom && t < silentUntil) ? nil : 2.5
    }
}

private func sampleTarget(uplink: Bool = false, thisMac: Bool = false, poe: SNMPPoEPort? = SNMPPoEPort(group: 1, port: 12, ifIndex: 12, adminEnabled: true, detection: .deliveringPower),
                          forti: FortiPortRef? = nil, host: String = "10.182.122.2") -> PortActionTarget {
    PortActionTarget(switchName: "SW-CORE-01", switchHost: IPv4Address(host), portName: "Gi1/0/12", ifIndex: 12, isUplink: uplink,
                     isThisMacPort: thisMac, deviceName: "FortiAP-231F", deviceIP: IPv4Address("10.182.122.20"),
                     deviceMAC: MACAddress("04:D5:90:12:34:56"), macCount: 1, poe: poe, fortiGate: forti)
}

private let sampleForti = FortiPortRef(controllerID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                                       controllerName: "Siège", switchID: "S124FFTF21001234", serial: "S124FFTF21001234")

func registerPortActionTests(_ suite: TestSuite) {
    suite.add("Actions sur les ports : désactivées par défaut, réglages bornés") {
        let settings = PortActionSettings()
        try expectEqual(settings.enabled, false, "désactivé par défaut")
        try expectEqual(settings.allowRiskyPorts, false, "uplinks refusés par défaut")
        try expectEqual(settings.poeOffSeconds, 5, "coupure de 5 s par défaut")
        try expectEqual(PortActionSettings.default.enabled, false, "réglages d'origine")
        let empty = try JSONDecoder().decode(PortActionSettings.self, from: Data("{}".utf8))
        try expectEqual(empty, PortActionSettings(), "fichier vide : réglages d'origine, jamais activé")
        let wild = try JSONDecoder().decode(PortActionSettings.self, from: Data(#"{"enabled":true,"poeOffSeconds":3600,"followUpSeconds":1}"#.utf8))
        try expectEqual(wild.poeOffSeconds, 60, "coupure bornée à 60 s")
        try expectEqual(wild.followUpSeconds, 30, "attente bornée à 30 s au moins")
        let decision = PortActionGuard.decide(.poeCycle, target: sampleTarget(), settings: PortActionSettings(),
                                              hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(!decision.isAllowed, "refusé tant que le réglage est désactivé")
        try expectEqual(decision.refusals.first, .disabled, "raison : réglage")
        try expectEqual(decision.channel, nil, "aucun moyen d'envoi")
    }

    suite.add("Actions sur les ports : uplink et port de ce Mac refusés par défaut") {
        let on = PortActionSettings(enabled: true)
        let uplink = PortActionGuard.decide(.poeCycle, target: sampleTarget(uplink: true), settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(!uplink.isAllowed, "uplink refusé")
        try expect(uplink.refusals.contains(.uplink), "raison uplink")
        let mac = PortActionGuard.decide(.poeCycle, target: sampleTarget(thisMac: true), settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(mac.refusals.contains(.thisMac), "port de ce Mac refusé")
        try expect(PortActionRefusal.uplink.message.contains("uplink"), "message en français")
        // Permis par le réglage : mise en garde à confirmer, plus de refus.
        var risky = on
        risky.allowRiskyPorts = true
        let allowed = PortActionGuard.decide(.poeCycle, target: sampleTarget(uplink: true, thisMac: true), settings: risky,
                                             hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(allowed.isAllowed, "permis avec le réglage")
        try expectEqual(allowed.warnings, [.uplink, .thisMac], "mises en garde")
    }

    suite.add("Actions sur les ports : PoE, moyen d'envoi et identifiants") {
        let on = PortActionSettings(enabled: true)
        let snmp = PortActionGuard.decide(.poeCycle, target: sampleTarget(), settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(snmp.isAllowed, "cycle SNMP permis")
        try expectEqual(snmp.channel, .snmp(host: IPv4Address("10.182.122.2")!, group: 1, port: 12), "SET groupe 1 port 12")
        let noCred = PortActionGuard.decide(.poeCycle, target: sampleTarget(), settings: on, hasWriteCredentials: false, fortiGateProblem: nil)
        try expectEqual(noCred.refusals, [.noWriteCredentials], "sans identifiant d'écriture")
        let noPoE = PortActionGuard.decide(.poeCycle, target: sampleTarget(poe: nil), settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(noPoE.refusals.contains(.noPoE), "port sans PoE")
        let off = PortActionGuard.decide(.poeCycle, target: sampleTarget(poe: SNMPPoEPort(group: 1, port: 12, adminEnabled: false, detection: .disabled)),
                                         settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(off.refusals.contains(.poeAdminDisabled), "PoE désactivé : un cycle le rallumerait")
        let placeholder = PortActionGuard.decide(.poeCycle, target: sampleTarget(host: "0.0.0.3"), settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expect(placeholder.refusals.contains(.noSwitchAddress), "adresse de remplacement jamais interrogée")
        let restart = PortActionGuard.decide(.portRestart, target: sampleTarget(), settings: on, hasWriteCredentials: true, fortiGateProblem: nil)
        try expectEqual(restart.refusals, [.restartNeedsFortiGate], "redémarrage : FortiSwitch seulement")
        let forti = PortActionGuard.decide(.portRestart, target: sampleTarget(forti: sampleForti), settings: on, hasWriteCredentials: false, fortiGateProblem: nil)
        try expectEqual(forti.channel, .fortiGate(controllerID: sampleForti.controllerID, controllerName: "Siège",
                                                  switchID: "S124FFTF21001234", portName: "Gi1/0/12"), "API de la FortiGate")
        let notReady = PortActionGuard.decide(.poeCycle, target: sampleTarget(forti: sampleForti), settings: on, hasWriteCredentials: true,
                                              fortiGateProblem: "jeton absent")
        try expectEqual(notReady.refusals, [.fortiGateNotReady("jeton absent")], "FortiGate non prête")
        let busy = PortActionGuard.decide(.poeCycle, target: sampleTarget(), settings: on, hasWriteCredentials: true, fortiGateProblem: nil, busy: true)
        try expect(busy.refusals.contains(.busy), "une action à la fois par port")
    }

    suite.add("Actions sur les ports : requêtes de la FortiGate (poe-reset, bounce-port)") {
        let reset = FortiPortActions.poeReset(switchID: "S124FFTF21001234", port: "port7")
        try expectEqual(reset.method, "POST", "méthode")
        try expectEqual(reset.path, "/api/v2/monitor/switch-controller/managed-switch/poe-reset", "adresse")
        try expectEqual(reset.bodyText, #"{"mkey":"S124FFTF21001234","port":"port7"}"#, "corps JSON")
        try expectEqual(reset.query, [], "sans VDOM")
        let bounce = FortiPortActions.bouncePort(switchID: "S124FFTF21001234", port: "port7", duration: 90, vdom: "root")
        try expectEqual(bounce.path, "/api/v2/monitor/switch-controller/managed-switch/bounce-port", "adresse du redémarrage")
        try expectEqual(bounce.bodyText, #"{"duration":30,"mkey":"S124FFTF21001234","port":"port7"}"#, "durée bornée à 30 s")
        try expectEqual(bounce.query, [URLQueryItem(name: "vdom", value: "root")], "VDOM en paramètre")
        try expect(!reset.bodyText.contains("Bearer"), "jamais de jeton dans le corps")
        let viaKind = FortiPortActions.request(.poeCycle, switchID: "S1", port: "port2", settings: PortActionSettings())
        try expectEqual(viaKind.path, FortiPortActions.poeResetPath, "cycle PoE = poe-reset")
    }

    suite.add("Actions sur les ports : réponses de la FortiGate (lecture seule, absente, réussie)") {
        let path = FortiPortActions.poeResetPath
        try expectEqual(FortiPortActions.interpret(FortiHTTPResponse(status: 200, body: Data(#"{"http_status":200,"status":"success"}"#.utf8)), path: path),
                        nil, "réussie")
        try expectEqual(FortiPortActions.interpret(FortiHTTPResponse(status: 403, body: Data()), path: path), .readOnlyToken, "403")
        try expectEqual(FortiPortActions.interpret(FortiHTTPResponse(status: 200, body: Data(#"{"status":"error","http_status":403}"#.utf8)), path: path),
                        .readOnlyToken, "403 dans le JSON")
        try expectEqual(FortiPortActions.interpret(FortiHTTPResponse(status: 401, body: Data()), path: path), .tokenRejected, "401")
        try expectEqual(FortiPortActions.interpret(FortiHTTPResponse(status: 404, body: Data()), path: path), .unsupportedByFortiOS(path: path), "404")
        try expect(PortActionError.readOnlyToken.errorDescription!.contains("le profil d’administrateur du jeton est en lecture seule"), "message demandé")
        let fake = FakeFortiWriter(status: 200, body: #"{"status":"success"}"#)
        try await FortiPortActions.perform(FortiPortActions.poeReset(switchID: "S1", port: "port3"), transport: fake)
        try expectEqual(fake.requests.count, 1, "une seule requête")
        let refused = FakeFortiWriter(status: 403, body: "")
        do {
            try await FortiPortActions.perform(FortiPortActions.poeReset(switchID: "S1", port: "port3"), transport: refused)
            throw TestFailure(message: "403 accepté", file: #fileID, line: #line)
        } catch let error as PortActionError {
            try expectEqual(error, .readOnlyToken, "erreur de jeton en lecture seule")
        }
    }

    suite.add("Actions sur les ports : FortiSwitch retrouvé dans la lecture de la FortiGate") {
        let report = FortiGateReport(system: FortiGateSystem(hostname: "FGT-SIEGE", model: "FortiGate-100F", serial: "FG100F", version: "v7.4.4"),
                                     switches: [FortiManagedSwitch(switchID: "S124FFTF21001234", serial: "S124FFTF21001234", name: "FSW-QUAI")])
        let site = FortiSiteReport(controllerID: sampleForti.controllerID, site: "Siège", report: report)
        guard let ref = FortiPortLocator.reference(switchName: "fsw-quai", site: "Siège", in: [site]) else {
            throw TestFailure(message: "FortiSwitch introuvable", file: #fileID, line: #line)
        }
        try expectEqual(ref.mkey, "S124FFTF21001234", "mkey = switch-id (numéro de série)")
        try expectEqual(ref.controllerName, "Siège", "site")
        try expectEqual(FortiPortLocator.reference(switchName: "SW-CORE-01", site: nil, in: [site]), nil, "switch SNMP : aucun")
    }

    suite.add("Actions sur les ports : SET SNMP de pethPsePortAdminEnable encodé en BER") {
        try expectEqual(SNMPPoEWrite.adminEnableOID(group: 1, port: 12).description, "1.3.6.1.2.1.105.1.1.1.3.1.12", "OID")
        let off = SNMPPoEWrite.v2cMessage(community: "rw-test", group: 1, port: 12, enabled: false, requestID: 0x1234)
        let expected: [UInt8] = [0x30, 0x2D,
                                 0x02, 0x01, 0x01,                                         // version v2c
                                 0x04, 0x07] + Array("rw-test".utf8) + [                   // communauté
                                 0xA3, 0x1F,                                               // SetRequest
                                 0x02, 0x02, 0x12, 0x34,                                   // request-id
                                 0x02, 0x01, 0x00, 0x02, 0x01, 0x00,                       // error-status, error-index
                                 0x30, 0x13, 0x30, 0x11,
                                 0x06, 0x0C, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x69, 0x01, 0x01, 0x01, 0x03, 0x01, 0x0C,
                                 0x02, 0x01, 0x02]                                         // false (TruthValue 2)
        try expectEqual(off, expected, "message v2c octet par octet")
        let on = SNMPPoEWrite.v2cMessage(community: "rw-test", group: 1, port: 12, enabled: true, requestID: 0x1234)
        try expectEqual(on.last, 0x01, "true (TruthValue 1)")
        let decoded = try SNMPMessage(decoding: off)
        try expectEqual(decoded.pdu.type, .setRequest, "relu : SetRequest")
        try expectEqual(decoded.pdu.varbinds.first?.value, .integer(2), "relu : false")
        // Erreurs du SET traduites, sans la communauté.
        try expectEqual(SNMPPoEWrite.translate(SNMPError.agent(status: SNMPErrorStatus.noAccess.rawValue, index: 1), host: "10.0.0.2"),
                        .snmpWriteRefused("accès refusé"), "noAccess")
        try expectEqual(SNMPPoEWrite.translate(SNMPError.agent(status: SNMPErrorStatus.notWritable.rawValue, index: 1), host: "10.0.0.2"),
                        .snmpWriteRefused("erreur 17"), "notWritable")
        try expectEqual(SNMPPoEWrite.translate(SNMPError.timeout("10.0.0.2"), host: "10.0.0.2"), .snmpNoResponse("10.0.0.2"), "délai")
    }

    suite.add("Actions sur les ports : identifiants d'écriture distincts de la lecture") {
        try expect(SNMPWriteCredentials(community: "public").problem() != nil, "« public » refusée")
        try expect(SNMPWriteCredentials(community: "lecture").problem(readCommunity: "lecture") != nil, "même que la lecture")
        try expectEqual(SNMPWriteCredentials(community: "rw-secret").problem(readCommunity: "lecture"), nil, "communauté RW")
        try expect(SNMPWriteCredentials(version: .v3, v3User: "netscope-rw", v3Level: .noAuthNoPriv).problem() != nil, "v3 sans authentification")
        try expectEqual(SNMPWriteCredentials(version: .v3, v3User: "netscope-rw", v3Level: .authPriv, v3AuthPassword: "motdepasse1",
                                             v3PrivPassword: "motdepasse2").problem(), nil, "v3 authPriv")
        let json = String(decoding: try JSONEncoder().encode(SNMPWriteCredentials(community: "rw-secret")), as: UTF8.self)
        try expect(json.contains("rw-secret"), "JSON du Trousseau complet")
    }

    suite.add("Actions sur les ports : cycle PoE SNMP (coupure, attente, remise, échecs)") {
        let writer = FakePoEWriter()
        let phases = PhaseLog()
        try await PortActionRunner.snmpPoECycle(writer: writer, offSeconds: 5, sleep: { _ in }, phase: { await phases.add($0) })
        try expectEqual(writer.writes, [false, true], "false puis true")
        let seen = await phases.items
        try expectEqual(seen.first, .poweringOff, "coupure d'abord")
        try expectEqual(seen.filter { if case .waitingOff = $0 { return true } else { return false } }.count, 5, "5 s d'attente")
        // Remise qui échoue deux fois : troisième essai.
        let flaky = FakePoEWriter(failOnFirst: 2)
        try await PortActionRunner.snmpPoECycle(writer: flaky, offSeconds: 2, sleep: { _ in }, phase: { _ in })
        try expectEqual(flaky.writes, [false, true, true, true], "trois essais de remise")
        // Remise impossible : erreur claire, le port est resté coupé.
        let broken = FakePoEWriter(failOnFirst: 9)
        do {
            try await PortActionRunner.snmpPoECycle(writer: broken, offSeconds: 2, sleep: { _ in }, phase: { _ in })
            throw TestFailure(message: "remise impossible acceptée", file: #fileID, line: #line)
        } catch let error as PortActionError {
            guard case .poeLeftOff = error else { throw TestFailure(message: "erreur \(error)", file: #fileID, line: #line) }
            try expect(error.errorDescription!.contains("reste sans courant"), "message explicite")
        }
        // Coupure refusée : rien d'autre n'est envoyé.
        let refused = FakePoEWriter(failOff: true)
        do {
            try await PortActionRunner.snmpPoECycle(writer: refused, offSeconds: 2, sleep: { _ in }, phase: { _ in })
            throw TestFailure(message: "coupure refusée acceptée", file: #fileID, line: #line)
        } catch is PortActionError {
            try expectEqual(refused.writes, [false], "aucune remise après un refus")
        }
    }

    suite.add("Actions sur les ports : suivi du retour (revenu en N s, toujours joignable, pas revenu)") {
        let ip = IPv4Address("10.182.122.20")!
        func run(silentFrom: Double, silentUntil: Double, limit: Int = 180) async -> PortActionReturn {
            let clock = VirtualClock()
            let start = clock.now()
            let pinger = ScriptedPinger(clock: clock, start: start, silentFrom: silentFrom, silentUntil: silentUntil)
            return await PortActionRunner.followUp(ip: ip, pinger: pinger, linkProbe: nil, start: start, limitSeconds: limit,
                                                   now: { clock.now() }, sleep: { clock.advance($0) }, progress: { _, _ in })
        }
        try expectEqual(await run(silentFrom: 0, silentUntil: 37), .returned(seconds: 40), "revenu après la coupure")
        try expectEqual(await run(silentFrom: 1000, silentUntil: 1000), .neverLost, "aucune coupure vue")
        try expectEqual(await run(silentFrom: 0, silentUntil: 10_000, limit: 60), .notBack(after: 60), "pas revenu")
        try expectEqual(PortActionReturn.returned(seconds: 38).label, "revenu en 38\u{00A0}s", "libellé")
        try expectEqual(PortActionFormat.seconds(125), "2\u{00A0}min\u{00A0}05\u{00A0}s", "minutes")
        let none = await PortActionRunner.followUp(ip: nil, pinger: nil, linkProbe: nil, start: Date(), limitSeconds: 60,
                                                   now: { Date() }, sleep: { _ in }, progress: { _, _ in })
        try expectEqual(none, .notFollowed, "sans adresse ni lien : non suivi")
    }

    suite.add("Actions sur les ports : journal et chronologie de l'inventaire") {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let record = PortActionRecord(date: date, kind: .poeCycle, target: sampleTarget(),
                                      channel: PortActionChannel.snmp(host: IPv4Address("10.182.122.2")!, group: 1, port: 12).label,
                                      success: true, returned: .returned(seconds: 38))
        try expect(record.logLine.contains("Cycle PoE · SW-CORE-01 · port Gi1/0/12 · FortiAP-231F (10.182.122.20)"), "ligne du journal")
        try expect(record.logLine.contains("revenu en 38"), "retour au journal")
        try expectEqual(record.inventoryKey, InventoryStore.key(mac: MACAddress("04:D5:90:12:34:56")!), "fiche par MAC")
        let event = record.inventoryEvent(key: record.inventoryKey!)
        try expectEqual(event.kind, .actionPort, "type")
        try expectEqual(event.kind.label, "Action sur le port", "libellé")
        try expect(!event.isAlert, "pas une alerte de l'Analyse")
        var store = InventoryStore()
        try expect(!store.recordPortAction(event), "aucune fiche créée pour une action")
        store.merge([Device(ip: IPv4Address("10.182.122.20")!, mac: MACAddress("04:D5:90:12:34:56"))], at: date)
        try expect(store.recordPortAction(event), "ajouté à la fiche")
        try expect(store.events(for: record.inventoryKey!).contains { $0.kind == .actionPort }, "dans la chronologie")
        let failed = PortActionRecord(date: date, kind: .portRestart, target: sampleTarget(forti: sampleForti), channel: "FortiGate",
                                      success: false, errorMessage: PortActionError.readOnlyToken.errorDescription)
        try expectEqual(failed.inventoryEvent(key: "k").severity, .alerte, "échec signalé")
    }

    suite.add("Actions sur les ports : port de ce Mac reconnu par sa MAC ou son adresse") {
        let mine = MACAddress("A4:83:E7:11:22:33")!
        let other = MACAddress("00:11:22:33:44:55")!
        let entries = [SNMPFDBEntry(mac: other, vlan: 1, bridgePort: 22, ifIndex: 22)]
        try expect(!PortActionGuard.isThisMacPort(entries: entries, arp: [:], localMACs: [mine], localIPs: []), "autre appareil")
        try expect(PortActionGuard.isThisMacPort(entries: entries + [SNMPFDBEntry(mac: mine, vlan: 1, bridgePort: 22, ifIndex: 22)],
                                                 arp: [:], localMACs: [mine], localIPs: []), "MAC de ce Mac")
        try expect(PortActionGuard.isThisMacPort(entries: entries, arp: [other: IPv4Address("10.182.122.135")!], localMACs: [],
                                                 localIPs: [IPv4Address("10.182.122.135")!]), "adresse de ce Mac")
    }
}

/// Journal des étapes (acteur : appelé depuis des fermetures @Sendable).
private actor PhaseLog {
    var items: [PortActionPhase] = []
    func add(_ phase: PortActionPhase) { items.append(phase) }
}
