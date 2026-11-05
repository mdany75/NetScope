import Foundation

/// Ce dont une vérification a besoin, fourni par l'application.
public struct MonRunContext: Sendable {
    /// Socket ICMP partagé (nil : ping impossible, la sonde échoue avec un message clair).
    public var pinger: ScanPinging?
    /// Communauté SNMP v2c (Réglages › Identifiants), jamais « public » par défaut.
    public var snmpCommunity: String?
    /// Appareils connus (inventaire du Scanner), pour le port de switch et les nouveaux appareils.
    public var devices: [Device]
    /// Faux pendant un scan : l'inventaire est vidé puis rempli peu à peu, il ne dit rien de fiable.
    public var inventoryReady: Bool
    public var now: Date
    /// Catalogue des services en ligne (sonde « Service en ligne ») ; vide : catalogue intégré.
    public var onlineServices: [SvcService] = []
    /// Accès Microsoft Graph pour Microsoft 365 (secret lu au Trousseau par l'application).
    public var onlineServiceGraph: SvcGraphCredentials?
    /// Dernière lecture Wi-Fi des FortiGate (sondes FortiAP) ; nil : aucune lecture.
    public var fortiWifi: FortiWifiOverview?
    /// Lecture Wi-Fi tentée sans aucune FortiGate lue : son erreur (403, jeton absent, injoignable).
    public var fortiWifiError: String?
    /// Dernière lecture des étendues DHCP (ou estimation sans FortiGate) ; nil : aucune.
    public var dhcpScopes: DHCPScopeOverview?
    /// Lecture des étendues tentée sans aucune FortiGate lue : son erreur.
    public var dhcpScopesError: String?
    /// Dernière lecture du WAN des FortiGate (sondes VPN et WAN, note 39) ; nil : aucune.
    public var wan: WANOverview?
    /// Lecture du WAN tentée sans aucune FortiGate lue : son erreur.
    public var wanError: String?
    /// Lecture du WAN en échec pour certaines FortiGate seulement : erreur par site (nom du site).
    public var wanSiteErrors: [String: String] = [:]
    /// Dernière lecture du firmware et des licences des FortiGate (note 41) ; nil : aucune.
    public var firmware: FirmwareOverview?
    /// Lecture du firmware tentée sans aucune FortiGate lue : son erreur.
    public var firmwareError: String?
    /// Lecture du firmware en échec pour certaines FortiGate seulement : erreur par site.
    public var firmwareSiteErrors: [String: String] = [:]
    /// Dernière lecture du trafic des FortiGate (sondes de trafic, note 54) ; nil : aucune.
    public var traffic: TrafficOverview?
    /// Lecture du trafic tentée sans aucune FortiGate lue : son erreur.
    public var trafficError: String?

    public init(pinger: ScanPinging?, snmpCommunity: String?, devices: [Device], inventoryReady: Bool = true,
                now: Date = Date()) {
        self.pinger = pinger
        self.snmpCommunity = snmpCommunity
        self.devices = devices
        self.inventoryReady = inventoryReady
        self.now = now
    }
}

/// Résultat d'une exécution, avec ce que la sonde a appris (emplacement, MAC connues).
public struct MonRunOutcome: Sendable {
    public var result: MonResult
    public var learnedLocation: String?
    public var knownMACs: [String]?
    /// Nouvelle menace (note 54) : menaces connues après ce passage.
    public var knownThreats: [String]?
    /// Rien à évaluer (inventaire vide, appareil absent, scan en cours) : ni réussite ni échec.
    /// Le suivi reste tel quel, sans événement ni case d'historique.
    public var noData: Bool

    public init(result: MonResult, learnedLocation: String? = nil, knownMACs: [String]? = nil, noData: Bool = false) {
        self.result = result
        self.learnedLocation = learnedLocation
        self.knownMACs = knownMACs
        self.noData = noData
    }

    /// Aucune donnée à évaluer, avec la raison affichée (« En attente d’un scan »).
    public static func noData(_ now: Date, _ reason: String) -> MonRunOutcome {
        MonRunOutcome(result: MonResult(date: now, reachable: true, value: reason), noData: true)
    }
}

/// Exécuteurs des sondes : ils réutilisent le moteur existant (ICMPPinger, PortScanner,
/// HTTPProbe, DNSLookup, SNMPClient) et l'inventaire déjà découvert.
public enum MonRunner {
    /// Pings envoyés par vérification (latence moyenne et perte).
    public static let pingCount = 3

    public static func run(_ probe: MonProbe, context: MonRunContext) async -> MonRunOutcome {
        let target = probe.target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            return MonRunOutcome(result: .failure(context.now, error: "Cible à compléter"))
        }
        if !probe.kind.usesNetwork, !context.inventoryReady {
            return .noData(context.now, "Scan en cours")
        }
        switch probe.kind {
        case .ping: return MonRunOutcome(result: await ping(probe, host: target, context: context))
        case .tcp: return MonRunOutcome(result: await tcp(host: target, context: context))
        case .http: return MonRunOutcome(result: await http(probe, url: target, context: context))
        case .dns: return MonRunOutcome(result: await dns(probe, name: target, context: context))
        case .snmp: return MonRunOutcome(result: await snmp(probe, host: target, context: context))
        case .switchPort:
            return MonInventoryChecks.switchPort(mac: target, expected: probe.expectedLocation,
                                                 devices: context.devices, now: context.now)
        case .newDevices:
            return MonInventoryChecks.newDevices(range: target, known: probe.knownMACs,
                                                 devices: context.devices, now: context.now)
        case .cpu, .memory, .portLoad:
            return MonRunOutcome(result: await MonResourceChecks.run(probe, target: target, context: context))
        case .onlineService:
            return MonRunOutcome(result: await SvcMonitorCheck.run(probe, target: target, context: context))
        case .fortiAPOffline:
            return MonFortiAPChecks.offline(target: target, overview: context.fortiWifi, error: context.fortiWifiError, now: context.now)
        case .fortiAPOverload:
            return MonFortiAPChecks.overload(target: target, overview: context.fortiWifi, error: context.fortiWifiError,
                                             thresholds: probe.wifiThresholds ?? .standard, now: context.now)
        case .dhcpScope:
            return MonDHCPScopeChecks.check(target: target, overview: context.dhcpScopes, error: context.dhcpScopesError,
                                            thresholds: probe.dhcpThresholds ?? .standard, now: context.now)
        case .vpnTunnel:
            return MonWANChecks.tunnelDown(target: target, overview: context.wan, error: context.wanError,
                                           siteErrors: context.wanSiteErrors, now: context.now)
        case .wanLink:
            return MonWANChecks.wanDegraded(target: target, overview: context.wan, error: context.wanError,
                                            siteErrors: context.wanSiteErrors,
                                            thresholds: probe.wanThresholds ?? .standard, now: context.now)
        case .linkSaturated, .heavyDevice, .newThreat:
            return MonTrafficChecks.run(probe, target: target, traffic: context.traffic, error: context.trafficError, now: context.now)
        case .licenseExpiring:
            return MonFirmwareChecks.licenseExpiring(target: target, overview: context.firmware, error: context.firmwareError,
                                                     siteErrors: context.firmwareSiteErrors,
                                                     days: Int(probe.resourceLimit ?? MonProbe.defaultResourceLimit(.licenseExpiring)),
                                                     now: context.now)
        case .firmwareOutdated:
            return MonFirmwareChecks.firmwareOutdated(target: target, overview: context.firmware, error: context.firmwareError,
                                                      siteErrors: context.firmwareSiteErrors, now: context.now)
        }
    }

    // MARK: Ping

    static func ping(_ probe: MonProbe, host: String, context: MonRunContext) async -> MonResult {
        let start = context.now
        guard let address = try? await PingResolver.resolveAsync(host) else {
            return .failure(start, error: "Nom introuvable\u{00A0}: \(host)")
        }
        var rtts: [Double] = []
        if let pinger = context.pinger {
            for index in 0..<pingCount {
                if index > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
                if let rtt = await pinger.ping(address, timeout: .seconds(1)) { rtts.append(rtt) }
            }
        }
        if !rtts.isEmpty {
            let average = rtts.reduce(0, +) / Double(rtts.count)
            let loss = Double(pingCount - rtts.count) / Double(pingCount) * 100
            return MonResult(date: start, reachable: true, latencyMs: average, lossPercent: loss,
                             value: "\(ToolFormat.milliseconds(average)) · perte \(MonFormat.percent(loss))")
        }
        // ICMP muet : port TCP de repli (caméra, serveur qui bloque le ping).
        if let port = probe.fallbackPort {
            let result = await PortScanner.probe(host: address.description, port: port,
                                                 options: PortScanOptions(timeout: 2, concurrency: 1, grabBanners: false))
            if result.state != .filtered {
                let rtt = result.rttMs ?? 0
                return MonResult(date: start, reachable: true, latencyMs: rtt, lossPercent: nil,
                                 value: "ICMP muet · TCP \(port) \(result.state == .open ? "ouvert" : "fermé") · \(ToolFormat.milliseconds(rtt))")
            }
            let error = context.pinger == nil ? "ping indisponible, TCP \(port) sans réponse" : "ICMP et TCP \(port) sans réponse"
            return .failure(start, error: error)
        }
        return .failure(start, error: context.pinger == nil ? "Ping indisponible sur ce Mac" : "Aucune réponse ICMP")
    }

    // MARK: TCP

    static func tcp(host target: String, context: MonRunContext) async -> MonResult {
        guard let (host, port) = MonProbe.hostAndPort(target) else {
            return .failure(context.now, error: "Cible attendue\u{00A0}: adresse:port")
        }
        let result = await PortScanner.probe(host: host, port: port,
                                             options: PortScanOptions(timeout: 3, concurrency: 1, grabBanners: false))
        switch result.state {
        case .open:
            let rtt = result.rttMs ?? 0
            return MonResult(date: context.now, reachable: true, latencyMs: rtt, value: "Ouvert · \(ToolFormat.milliseconds(rtt))")
        case .closed:
            return .failure(context.now, error: "Port \(port) fermé")
        default:
            return .failure(context.now, error: "Port \(port) sans réponse")
        }
    }

    // MARK: HTTP(S)

    static func http(_ probe: MonProbe, url text: String, context: MonRunContext) async -> MonResult {
        let normalized = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: normalized) else {
            return .failure(context.now, error: "Adresse web invalide")
        }
        do {
            let response = try await HTTPProbe.probe(url, timeout: 8)
            return evaluateHTTP(probe, status: response.statusCode, durationMs: response.durationMs,
                                body: response.bodyText, certificateExpiry: response.certificate?.validUntil, now: context.now)
        } catch {
            return .failure(context.now, error: error.localizedDescription)
        }
    }

    /// Analyse d'une réponse HTTP (pure, testée) : code, mot-clé, certificat.
    public static func evaluateHTTP(_ probe: MonProbe, status: Int, durationMs: Double, body: String,
                                    certificateExpiry: Date?, now: Date) -> MonResult {
        let expected = probe.expectedStatus ?? 200
        let statusLabel = status == 200 ? "200 OK" : "\(status)"
        var value = "\(statusLabel) · \(ToolFormat.milliseconds(durationMs))"
        guard status == expected else {
            return MonResult(date: now, reachable: false, latencyMs: durationMs, value: value,
                             error: "code \(status) au lieu de \(expected)")
        }
        if let keyword = probe.keyword?.trimmingCharacters(in: .whitespaces), !keyword.isEmpty,
           body.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return MonResult(date: now, reachable: false, latencyMs: durationMs, value: value,
                             error: "mot-clé «\u{00A0}\(keyword)\u{00A0}» absent de la page")
        }
        var problem: String?
        if let days = probe.certificateDays, let expiry = certificateExpiry {
            let left = Int((expiry.timeIntervalSince(now) / 86_400).rounded(.down))
            let when = "\(MonJournal.longDate(expiry))"
            if left < 0 {
                value = "Certificat expiré (\(when))"
                problem = "Le certificat de \(probe.target) a expiré le \(when)"
            } else {
                value = "Expire dans \(left)\u{00A0}j (\(when))"
                if left < days { problem = "Le certificat de \(probe.target) expire le \(when) (dans \(left)\u{00A0}jours)" }
            }
        }
        return MonResult(date: now, reachable: true, latencyMs: durationMs, value: value, problem: problem)
    }

    // MARK: DNS

    static func dns(_ probe: MonProbe, name: String, context: MonRunContext) async -> MonResult {
        let server = probe.dnsServer.flatMap { IPv4Address($0.trimmingCharacters(in: .whitespaces)) }
        do {
            let lookup = try await DNSLookup.resolve(name, type: .a, server: server, timeout: 3)
            let addresses = lookup.records.filter { $0.type == .a }.map(\.value)
            return evaluateDNS(probe, rcode: lookup.rcode, addresses: addresses, durationMs: lookup.durationMs, now: context.now)
        } catch {
            return .failure(context.now, error: error.localizedDescription)
        }
    }

    /// Analyse d'une réponse DNS (pure, testée).
    public static func evaluateDNS(_ probe: MonProbe, rcode: String, addresses: [String], durationMs: Double, now: Date) -> MonResult {
        guard rcode == "NOERROR", let first = addresses.first else {
            return MonResult(date: now, reachable: false, latencyMs: durationMs, value: rcode,
                             error: rcode == "NOERROR" ? "aucune adresse A" : rcode)
        }
        let value = "A \(first)\(addresses.count > 1 ? " +\(addresses.count - 1)" : "") · \(ToolFormat.milliseconds(durationMs))"
        var problem: String?
        if let expected = probe.dnsExpected?.trimmingCharacters(in: .whitespaces), !expected.isEmpty, !addresses.contains(expected) {
            problem = "\(probe.target) résout en \(addresses.joined(separator: ", ")) au lieu de \(expected)"
        }
        return MonResult(date: now, reachable: true, latencyMs: durationMs, value: value, problem: problem)
    }

    // MARK: SNMP

    static func snmp(_ probe: MonProbe, host: String, context: MonRunContext) async -> MonResult {
        guard let community = context.snmpCommunity, !community.isEmpty else {
            return .failure(context.now, error: "aucune communauté SNMP (Réglages › Identifiants)")
        }
        guard let text = probe.snmpOID, let oid = SNMPOID(text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) else {
            return .failure(context.now, error: "OID à compléter")
        }
        guard let address = try? await PingResolver.resolveAsync(host) else {
            return .failure(context.now, error: "Nom introuvable\u{00A0}: \(host)")
        }
        let client = SNMPClient(target: SNMPTarget(host: address, community: community, timeout: 2, retries: 1))
        do {
            let binds = try await client.get([oid])
            guard let value = binds.first?.value, !value.isException else {
                return .failure(context.now, error: "OID \(oid) absent de l’agent")
            }
            return evaluateSNMP(probe, value: value, now: context.now)
        } catch {
            return .failure(context.now, error: error.localizedDescription)
        }
    }

    /// Analyse d'une valeur SNMP (pure, testée) : comparaison numérique avec la limite.
    public static func evaluateSNMP(_ probe: MonProbe, value: SNMPValue, now: Date) -> MonResult {
        let unit = probe.snmpUnit.map { "\u{00A0}" + $0 } ?? ""
        let number = value.intValue.map(Double.init) ?? value.stringValue.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let label = number.map(MonFormat.number) ?? value.stringValue ?? "?"
        var problem: String?
        if let comparison = probe.snmpComparison, let limit = probe.snmpLimit {
            if let number {
                if comparison.matches(number, limit) {
                    problem = "Valeur \(label)\(unit) \(comparison.symbol) \(MonFormat.number(limit))\(unit)"
                }
            } else {
                problem = "Valeur non numérique\u{00A0}: \(label)"
            }
        }
        return MonResult(date: now, reachable: true, value: label + unit, problem: problem)
    }
}

/// Vérifications qui lisent l'inventaire déjà découvert (aucun trafic).
public enum MonInventoryChecks {
    /// Port de switch : où est vu l'appareil de cette MAC ? Premier passage : l'emplacement est appris.
    public static func switchPort(mac text: String, expected: String?, devices: [Device], now: Date) -> MonRunOutcome {
        guard let mac = MACAddress(text) else {
            return MonRunOutcome(result: .failure(now, error: "Adresse MAC invalide"))
        }
        guard let device = devices.first(where: { $0.mac == mac }) else {
            // Inventaire vide (aucun scan depuis le lancement) ou appareil éteint : rien à évaluer,
            // ce n'est ni une panne ni un retour à la normale.
            return .noData(now, devices.isEmpty ? "En attente d’un scan" : "Absent du dernier scan")
        }
        guard let location = device.switchLocation else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Port inconnu",
                                                   problem: "Port de switch inconnu pour \(device.displayName)"))
        }
        let value = location.replacingOccurrences(of: " · ", with: " ")
        guard let expected, !expected.isEmpty else {
            return MonRunOutcome(result: MonResult(date: now, reachable: device.isOnline, value: value,
                                                   error: device.isOnline ? nil : "appareil hors ligne"),
                                 learnedLocation: location)
        }
        var problem: String?
        if location != expected {
            problem = "\(device.displayName) vu sur \(value) au lieu de \(expected.replacingOccurrences(of: " · ", with: " "))"
        }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: problem))
    }

    /// Nouveaux appareils sur une plage : MAC jamais vues. Premier passage : la plage connue sert de base.
    public static func newDevices(range text: String, known: [String]?, devices: [Device], now: Date) -> MonRunOutcome {
        guard let range = try? IPRange(parsing: text) else {
            return MonRunOutcome(result: .failure(now, error: "Plage invalide"))
        }
        let inRange = devices.filter { range.contains($0.ip) }
        let online = inRange.filter(\.isOnline).count
        let macs = inRange.compactMap { $0.mac?.description }
        // Aucun appareil connu sur la plage (pas encore de scan) : on attend avant d'apprendre la base.
        guard !inRange.isEmpty else {
            return .noData(now, "En attente d’un scan")
        }
        guard let known else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Base\u{00A0}: \(macs.count) appareils · \(online) en ligne"),
                                 knownMACs: Array(Set(macs)).sorted())
        }
        let knownSet = Set(known)
        let fresh = inRange.filter { device in device.mac.map { !knownSet.contains($0.description) } ?? false }
        let value = "\(fresh.count) nouveau\(fresh.count > 1 ? "x" : "") · \(online) en ligne"
        guard !fresh.isEmpty else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
        }
        let list = fresh.prefix(3).map { "\($0.ip) \($0.displayName) (MAC \($0.mac?.description ?? "?"))" }.joined(separator: ", ")
        let more = fresh.count > 3 ? " et \(fresh.count - 3) autres" : ""
        let problem = (fresh.count == 1 ? "Nouvel appareil " : "Nouveaux appareils\u{00A0}: ") + list + more
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: problem),
                             knownMACs: Array(knownSet.union(macs)).sorted())
    }
}
