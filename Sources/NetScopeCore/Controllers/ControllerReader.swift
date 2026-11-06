import Foundation

// Note 77 : lecture complète d'un contrôleur (UniFi Network, TP-Link Omada, Cisco Meraki), par un
// transport injectable. Chaque marque a son lecteur ; tous rendent le même `ControllerReport`.
// Le « Tester » des Réglages fait la même lecture (elle donne le nombre de switchs, de bornes et de
// clients, et les sites disponibles quand le site demandé est introuvable).

/// Lecteur d'un contrôleur.
public struct ControllerReader: Sendable {
    public let controller: SiteController
    let secret: String
    public let transport: ControllerTransport
    /// Taille maximale gardée de chaque réponse brute (diagnostic).
    public static let rawLimit = 48_000

    public init(controller: SiteController, secret: String, transport: ControllerTransport) {
        self.controller = controller
        self.secret = secret
        self.transport = transport
    }

    /// Lit tout ; une erreur bloquante emporte les appels déjà faits (`ControllerReadFailure`).
    public func read(now: Date = Date()) async throws -> ControllerReport {
        guard controller.hasValidAddress else { throw ControllerReadFailure(error: .invalidAddress, calls: []) }
        guard !secret.isEmpty else { throw ControllerReadFailure(error: .missingSecret, calls: []) }
        if controller.authMode.accountLabel != nil, controller.account.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ControllerReadFailure(error: .missingAccount, calls: [])
        }
        var fetcher = ControllerFetcher(transport: transport, kind: controller.kind, secrets: [secret])
        do {
            var report: ControllerReport
            switch controller.kind {
            case .unifi: report = try await UniFiReader(controller: controller, secret: secret).read(&fetcher, now: now)
            case .omada: report = try await OmadaReader(controller: controller, secret: secret).read(&fetcher, now: now)
            case .meraki: report = try await MerakiReader(controller: controller, secret: secret).read(&fetcher, now: now)
            }
            report.calls = fetcher.calls
            ControllerLinker.link(&report)
            return report
        } catch let error as ControllerError {
            throw ControllerReadFailure(error: error, calls: fetcher.calls)
        }
    }
}

/// Lecture interrompue : l'erreur et les appels faits avant elle (pour le diagnostic).
public struct ControllerReadFailure: Error, Sendable {
    public var error: ControllerError
    public var calls: [ControllerCallRecord]

    public init(error: ControllerError, calls: [ControllerCallRecord]) {
        self.error = error
        self.calls = calls
    }
}

// MARK: - Appels et diagnostic

/// Envoie une requête, garde son enregistrement (corps tronqué, sans secret) et traduit l'erreur.
struct ControllerFetcher {
    let transport: ControllerTransport
    let kind: ControllerKind
    var secrets: [String]
    var calls: [ControllerCallRecord] = []

    init(transport: ControllerTransport, kind: ControllerKind, secrets: [String]) {
        self.transport = transport
        self.kind = kind
        self.secrets = secrets
    }

    /// Réponse (nil si aucune) et erreur non bloquante ; une erreur bloquante est levée.
    mutating func fetch(_ request: ControllerRequest, label: String? = nil) async throws -> (response: ControllerResponse?, error: ControllerError?) {
        let shown = (request.method == "GET" ? "" : request.method + " ") + request.shownPath
        do {
            let response = try await transport.send(request)
            let body = String(decoding: response.body.prefix(ControllerReader.rawLimit), as: UTF8.self)
                + (response.body.count > ControllerReader.rawLimit ? "\n… (réponse tronquée à \(ControllerReader.rawLimit) octets)" : "")
            // Corps d'une ouverture de session : jamais gardé (il peut contenir un jeton).
            let clean = request.method == "POST" ? "(corps de la réponse non gardé\u{00A0}: ouverture de session)"
                                                  : ControllerRedact.clean(body, secrets: secrets)
            if let error = ControllerError.from(status: response.status, path: request.path, kind: kind) {
                if case .authRejected = error {
                    calls.append(ControllerCallRecord(path: shown, status: response.status, outcome: .refused,
                                                      message: error.errorDescription ?? "", body: clean))
                    throw error
                }
                let outcome: ControllerCallRecord.Outcome = (response.status == 404 || response.status == 405) ? .absent
                    : (response.status == 403 ? .refused : .failed)
                calls.append(ControllerCallRecord(path: shown, status: response.status, outcome: outcome,
                                                  message: error.errorDescription ?? "", body: clean))
                return (response, error)
            }
            calls.append(ControllerCallRecord(path: shown, status: response.status, outcome: .ok, message: label ?? "", body: clean,
                                              items: FortiParsers.itemCount(response.body)))
            return (response, nil)
        } catch let error as ControllerError {
            if !calls.contains(where: { $0.path == shown && $0.outcome == .refused }) {
                calls.append(ControllerCallRecord(path: shown, status: nil, outcome: .failed,
                                                  message: ControllerRedact.clean(error.errorDescription ?? "", secrets: secrets)))
            }
            if error.isBlocking { throw error }
            return (nil, error)
        }
    }

    /// Marque le dernier appel en échec avec un message (réponse lisible mais erreur de l'API).
    mutating func markLast(_ message: String) {
        guard !calls.isEmpty else { return }
        calls[calls.count - 1].outcome = .failed
        calls[calls.count - 1].message = message
    }

    /// Note expliquée pour une partie facultative absente ou refusée.
    static func note(_ part: String, _ error: ControllerError?) -> String? {
        guard let error else { return nil }
        switch error {
        case .forbidden: return "\(part)\u{00A0}: accès refusé (HTTP 403), droit de lecture manquant."
        case .notFound: return "\(part)\u{00A0}: adresse absente sur ce contrôleur (version différente)."
        default: return "\(part)\u{00A0}: " + (error.errorDescription ?? "lecture impossible.")
        }
    }
}

/// Réponses brutes de la dernière lecture, à copier pour le diagnostic (sans secret).
public enum ControllerDiagnostic {
    public static func text(calls: [ControllerCallRecord], controller: SiteController, report: ControllerReport?,
                            secrets: [String], date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("NetScope · réponses brutes du contrôleur \(controller.kind.label) (diagnostic, secrets retirés)")
        lines.append("Date\u{00A0}: \(formatter.string(from: date))")
        lines.append("Contrôleur\u{00A0}: \(controller.addressLabel) · \(controller.authMode.label) · \(controller.scopeLabel)"
                     + (controller.kind == .unifi ? (controller.unifiOS ? " · UniFi OS" : " · contrôleur classique") : ""))
        if let report {
            lines.append("Lu\u{00A0}: \(report.controllerName)" + (report.version.map { " · version \($0)" } ?? "")
                         + " · \(report.switches.count) switchs, \(report.aps.count) bornes, \(report.clients.count) clients")
            for note in report.notes { lines.append("# " + note) }
        }
        for call in calls {
            lines.append("")
            lines.append("=== \(call.path) → " + (call.status.map { "HTTP \($0)" } ?? "pas de réponse") + " (\(call.outcome.rawValue))")
            if !call.message.isEmpty { lines.append("# " + call.message) }
            if !call.body.isEmpty { lines.append(call.body) }
        }
        return ControllerRedact.clean(lines.joined(separator: "\n"), secrets: secrets)
    }
}

// MARK: - Corps JSON

enum ControllerJSONBody {
    static func make(_ fields: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }
}

// MARK: - UniFi Network

struct UniFiReader {
    let controller: SiteController
    let secret: String

    var prefix: String { controller.unifiOS ? "/proxy/network" : "" }

    func read(_ fetcher: inout ControllerFetcher, now: Date) async throws -> ControllerReport {
        var headers: [String: String] = [:]
        var loggedIn = false
        if controller.authMode == .unifiAPIKey {
            headers["X-API-KEY"] = secret
        } else {
            let path = controller.unifiOS ? "/api/auth/login" : "/api/login"
            let body = ControllerJSONBody.make(["username": controller.account.trimmingCharacters(in: .whitespaces), "password": secret])
            let (response, error) = try await fetcher.fetch(ControllerRequest(method: "POST", path: path, body: body), label: "Session ouverte.")
            // 400 : identifiants refusés par un contrôleur classique ; 403 : compte sans accès.
            guard error == nil, let response else {
                if case .notFound? = error { throw ControllerError.notFound(path: path) }
                throw ControllerError.authRejected(.unifi)
            }
            if let csrf = response.headers["x-csrf-token"] ?? response.headers["x-updated-csrf-token"] { headers["X-CSRF-Token"] = csrf }
            loggedIn = true
        }
        do {
            let report = try await readAll(&fetcher, headers: headers, now: now)
            if loggedIn { await logout(&fetcher, headers: headers) }
            return report
        } catch {
            if loggedIn { await logout(&fetcher, headers: headers) }
            throw error
        }
    }

    private func logout(_ fetcher: inout ControllerFetcher, headers: [String: String]) async {
        let path = controller.unifiOS ? "/api/auth/logout" : "/api/logout"
        _ = try? await fetcher.fetch(ControllerRequest(method: "POST", path: path, headers: headers), label: "Session fermée.")
    }

    private func readAll(_ fetcher: inout ControllerFetcher, headers: [String: String], now: Date) async throws -> ControllerReport {
        var notes: [String] = []
        // Sites : le nom court ou la description saisis (« default », « Clinique »).
        var site = controller.siteRef.trimmingCharacters(in: .whitespaces)
        var siteDesc: String?
        let sitesFetched = try await fetcher.fetch(ControllerRequest(path: prefix + "/api/self/sites", headers: headers))
        if let body = sitesFetched.response?.body, sitesFetched.error == nil {
            let list = UniFiParsers.sites(body)
            if !list.isEmpty {
                guard let resolved = UniFiParsers.resolveSite(site, in: list) else {
                    throw ControllerError.scopeNotFound(wanted: site, available: list.map { $0.desc == $0.name ? $0.name : "\($0.desc) (\($0.name))" })
                }
                site = resolved
                siteDesc = list.first { $0.name == resolved }?.desc
            }
        }
        if site.isEmpty { site = "default" }
        let base = prefix + "/api/s/\(site)"

        var version: String?
        var name: String?
        let sys = try await fetcher.fetch(ControllerRequest(path: base + "/stat/sysinfo", headers: headers))
        if let body = sys.response?.body {
            if let error = UniFiParsers.envelope(body)?.error, error.lowercased().contains("nosite") {
                throw ControllerError.scopeNotFound(wanted: site, available: [])
            }
            if sys.error == nil, let info = UniFiParsers.sysinfo(body) { version = info.version; name = info.name }
        }

        var networks: [String: Int] = [:]
        let nets = try await fetcher.fetch(ControllerRequest(path: base + "/rest/networkconf", headers: headers))
        if let body = nets.response?.body, nets.error == nil { networks = UniFiParsers.networks(body) }
        else if let note = ControllerFetcher.note("Réseaux (VLAN natif des ports)", nets.error) { notes.append(note) }

        let devicesFetched = try await fetcher.fetch(ControllerRequest(path: base + "/stat/device", headers: headers))
        if let error = devicesFetched.error { throw error }
        guard let devicesBody = devicesFetched.response?.body, let devices = UniFiParsers.devices(devicesBody, networks: networks) else {
            throw ControllerError.invalidResponse(path: base + "/stat/device")
        }
        if let error = UniFiParsers.envelope(devicesBody)?.error {
            fetcher.markLast(error)
            if error.lowercased().contains("nosite") { throw ControllerError.scopeNotFound(wanted: site, available: []) }
            throw ControllerError.apiError(path: base + "/stat/device", message: error)
        }

        var clients: [ControllerClient] = []
        let sta = try await fetcher.fetch(ControllerRequest(path: base + "/stat/sta", headers: headers))
        if let body = sta.response?.body, sta.error == nil, let list = UniFiParsers.clients(body, now: now) { clients = list }
        else if let note = ControllerFetcher.note("Clients", sta.error) { notes.append(note) }

        return ControllerReport(kind: .unifi, controllerName: name ?? "UniFi Network", version: version, siteName: siteDesc ?? site,
                                switches: devices.switches, aps: devices.aps, clients: clients, notes: notes, readAt: now)
    }
}

// MARK: - TP-Link Omada

struct OmadaReader {
    let controller: SiteController
    let secret: String

    var openAPI: Bool { controller.authMode == .omadaOpenAPI }

    func read(_ fetcher: inout ControllerFetcher, now: Date) async throws -> ControllerReport {
        var notes: [String] = []
        // Identifiant du contrôleur (omadacId) et version : /api/info, sans authentification.
        var cid = controller.orgRef.trimmingCharacters(in: .whitespaces)
        var version: String?
        let info = try await fetcher.fetch(ControllerRequest(path: "/api/info"))
        if let body = info.response?.body, info.error == nil, let parsed = OmadaParsers.info(body) {
            version = parsed.version
            if cid.isEmpty { cid = parsed.omadacID ?? "" }
        }
        guard !cid.isEmpty else {
            throw ControllerError.apiError(path: "/api/info", message: "identifiant du contrôleur (omadacId) introuvable\u{00A0}: saisissez-le dans le champ «\u{00A0}ID du contrôleur\u{00A0}».")
        }

        var headers: [String: String] = [:]
        let base: String
        if openAPI {
            let body = ControllerJSONBody.make(["omadacId": cid, "client_id": controller.account.trimmingCharacters(in: .whitespaces),
                                                "client_secret": secret])
            let (response, error) = try await fetcher.fetch(ControllerRequest(method: "POST", path: "/openapi/authorize/token",
                                                                              query: [URLQueryItem(name: "grant_type", value: "client_credentials")],
                                                                              body: body), label: "Jeton d’accès obtenu.")
            guard error == nil, let data = response?.body, let token = OmadaParsers.token(data) else {
                if case .notFound? = error { throw ControllerError.notFound(path: "/openapi/authorize/token") }
                throw ControllerError.authRejected(.omada)
            }
            fetcher.secrets.append(token)
            headers["Authorization"] = "AccessToken=\(token)"
            base = "/openapi/v1/\(cid)"
        } else {
            let body = ControllerJSONBody.make(["username": controller.account.trimmingCharacters(in: .whitespaces), "password": secret])
            let (response, error) = try await fetcher.fetch(ControllerRequest(method: "POST", path: "/\(cid)/api/v2/login", body: body),
                                                            label: "Session ouverte.")
            guard error == nil, let data = response?.body, let token = OmadaParsers.token(data) else { throw ControllerError.authRejected(.omada) }
            fetcher.secrets.append(token)
            headers["Csrf-Token"] = token
            base = "/\(cid)/api/v2"
        }
        do {
            let report = try await readAll(&fetcher, base: base, headers: headers, version: version, notes: &notes, now: now)
            await logout(&fetcher, cid: cid, headers: headers)
            return report
        } catch {
            await logout(&fetcher, cid: cid, headers: headers)
            throw error
        }
    }

    private func logout(_ fetcher: inout ControllerFetcher, cid: String, headers: [String: String]) async {
        guard !openAPI else { return }
        _ = try? await fetcher.fetch(ControllerRequest(method: "POST", path: "/\(cid)/api/v2/logout", headers: headers), label: "Session fermée.")
    }

    private func page(_ size: Int) -> [URLQueryItem] {
        openAPI ? [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(size))]
                : [URLQueryItem(name: "currentPage", value: "1"), URLQueryItem(name: "currentPageSize", value: String(size))]
    }

    /// Erreur d'une enveloppe lisible (errorCode ≠ 0) ; nil si tout va bien.
    private func apiError(_ data: Data?, path: String) -> ControllerError? {
        guard let data, let envelope = OmadaParsers.envelope(data), envelope.code != 0 else { return nil }
        // -44112, -44113, -44106 : jeton expiré ou invalide ; -1600 : accès refusé.
        if [-44112, -44113, -44106, -44111].contains(envelope.code) { return .authRejected(.omada) }
        return .apiError(path: path, message: "\(envelope.message ?? "erreur") (code \(envelope.code))")
    }

    private func readAll(_ fetcher: inout ControllerFetcher, base: String, headers: [String: String], version: String?,
                         notes: inout [String], now: Date) async throws -> ControllerReport {
        let sitesPath = base + "/sites"
        let sitesFetched = try await fetcher.fetch(ControllerRequest(path: sitesPath, query: page(100), headers: headers))
        if let error = sitesFetched.error { throw error }
        if let error = apiError(sitesFetched.response?.body, path: sitesPath) { fetcher.markLast(error.errorDescription ?? ""); throw error }
        guard let body = sitesFetched.response?.body, let sites = OmadaParsers.sites(body) else { throw ControllerError.invalidResponse(path: sitesPath) }
        guard let site = OmadaParsers.resolveSite(controller.siteRef, in: sites) else {
            throw ControllerError.scopeNotFound(wanted: controller.siteRef.isEmpty ? "site" : controller.siteRef, available: sites.map(\.name))
        }
        let siteBase = base + "/sites/\(site.id)"

        let devicesPath = siteBase + "/devices"
        let devicesFetched = try await fetcher.fetch(ControllerRequest(path: devicesPath, query: openAPI ? page(1000) : [], headers: headers))
        if let error = devicesFetched.error { throw error }
        if let error = apiError(devicesFetched.response?.body, path: devicesPath) { fetcher.markLast(error.errorDescription ?? ""); throw error }
        guard let devicesBody = devicesFetched.response?.body, var devices = OmadaParsers.devices(devicesBody) else {
            throw ControllerError.invalidResponse(path: devicesPath)
        }

        // Ports de chaque switch (facultatif : sans eux, le switch est montré sans façade).
        var portNote = false
        for index in devices.switches.indices {
            guard let mac = devices.switches[index].mac else { continue }
            let path = siteBase + "/switches/\(mac.formatted(.hyphen).uppercased())/ports"
            let fetched = try await fetcher.fetch(ControllerRequest(path: path, query: openAPI ? page(100) : [], headers: headers))
            if let body = fetched.response?.body, fetched.error == nil, apiError(body, path: path) == nil, let ports = OmadaParsers.ports(body) {
                devices.switches[index].ports = ports
            } else if !portNote, let note = ControllerFetcher.note("Ports des switchs", fetched.error ?? apiError(fetched.response?.body, path: path)) {
                notes.append(note)
                portNote = true
            }
        }
        // Radios de chaque borne (canaux, largeur, puissance).
        for index in devices.aps.indices {
            guard let mac = devices.aps[index].mac else { continue }
            let path = siteBase + (openAPI ? "/aps/" : "/eaps/") + mac.formatted(.hyphen).uppercased()
            let fetched = try await fetcher.fetch(ControllerRequest(path: path, headers: headers))
            if let body = fetched.response?.body, fetched.error == nil {
                devices.aps[index] = OmadaParsers.apDetail(body, into: devices.aps[index])
            }
        }

        var clients: [ControllerClient] = []
        let clientsPath = siteBase + "/clients"
        var query = page(1000)
        if !openAPI { query.append(URLQueryItem(name: "filters.active", value: "true")) }
        let clientsFetched = try await fetcher.fetch(ControllerRequest(path: clientsPath, query: query, headers: headers))
        if let body = clientsFetched.response?.body, clientsFetched.error == nil, apiError(body, path: clientsPath) == nil,
           let list = OmadaParsers.clients(body, now: now) {
            clients = list
        } else if let note = ControllerFetcher.note("Clients", clientsFetched.error ?? apiError(clientsFetched.response?.body, path: clientsPath)) {
            notes.append(note)
        }

        return ControllerReport(kind: .omada, controllerName: "Omada · \(site.name)", version: version, siteName: site.name,
                                switches: devices.switches, aps: devices.aps, clients: clients, notes: notes, readAt: now)
    }
}

// MARK: - Cisco Meraki

struct MerakiReader {
    let controller: SiteController
    let secret: String
    /// Fenêtre des états des ports (la puissance PoE en découle).
    static let portTimespan = 300.0
    /// Pages de clients au plus (1 000 par page).
    static let maxClientPages = 5

    func read(_ fetcher: inout ControllerFetcher, now: Date) async throws -> ControllerReport {
        let headers = ["Authorization": "Bearer \(secret)"]
        var notes: [String] = []

        let orgsPath = "/api/v1/organizations"
        let orgsFetched = try await fetcher.fetch(ControllerRequest(path: orgsPath, headers: headers))
        if let error = orgsFetched.error { throw error }
        guard let orgsBody = orgsFetched.response?.body, let orgs = MerakiParsers.named(orgsBody) else { throw ControllerError.invalidResponse(path: orgsPath) }
        guard let org = MerakiParsers.resolve(controller.orgRef, in: orgs) else {
            throw ControllerError.scopeNotFound(wanted: controller.orgRef.isEmpty ? "organisation" : controller.orgRef, available: orgs.map(\.name))
        }

        let netsPath = "/api/v1/organizations/\(org.id)/networks"
        let netsFetched = try await fetcher.fetch(ControllerRequest(path: netsPath, headers: headers))
        if let error = netsFetched.error { throw error }
        guard let netsBody = netsFetched.response?.body, let networks = MerakiParsers.named(netsBody) else { throw ControllerError.invalidResponse(path: netsPath) }
        guard let network = MerakiParsers.resolve(controller.siteRef, in: networks) else {
            throw ControllerError.scopeNotFound(wanted: controller.siteRef.isEmpty ? "réseau" : controller.siteRef, available: networks.map(\.name))
        }

        let devicesPath = "/api/v1/networks/\(network.id)/devices"
        let devicesFetched = try await fetcher.fetch(ControllerRequest(path: devicesPath, headers: headers))
        if let error = devicesFetched.error { throw error }
        guard let devicesBody = devicesFetched.response?.body, let devices = MerakiParsers.devices(devicesBody) else {
            throw ControllerError.invalidResponse(path: devicesPath)
        }

        var online: [String: Bool] = [:]
        let statusFetched = try await fetcher.fetch(ControllerRequest(path: "/api/v1/organizations/\(org.id)/devices/statuses",
                                                                      query: [URLQueryItem(name: "networkIds[]", value: network.id)], headers: headers))
        if let body = statusFetched.response?.body, statusFetched.error == nil { online = MerakiParsers.statuses(body) }
        else if let note = ControllerFetcher.note("États des équipements", statusFetched.error) { notes.append(note) }

        var switches: [ControllerSwitch] = []
        var aps: [ControllerAP] = []
        var portNote = false
        for device in devices {
            switch device.family {
            case .switchDevice:
                var ports: [ControllerPort] = []
                let configFetched = try await fetcher.fetch(ControllerRequest(path: "/api/v1/devices/\(device.serial)/switch/ports", headers: headers))
                let configs = configFetched.response.flatMap { configFetched.error == nil ? MerakiParsers.portConfigs($0.body) : nil } ?? [:]
                let statusPath = "/api/v1/devices/\(device.serial)/switch/ports/statuses"
                let portsFetched = try await fetcher.fetch(ControllerRequest(path: statusPath,
                                                                             query: [URLQueryItem(name: "timespan", value: String(Int(Self.portTimespan)))],
                                                                             headers: headers))
                if let body = portsFetched.response?.body, portsFetched.error == nil,
                   let list = MerakiParsers.ports(body, configs: configs, timespan: Self.portTimespan) {
                    ports = list
                } else if !portNote, let note = ControllerFetcher.note("Ports des switchs", portsFetched.error) {
                    notes.append(note)
                    portNote = true
                }
                switches.append(ControllerSwitch(mac: device.mac, name: device.name, model: device.model, firmware: device.firmware,
                                                 serial: device.serial, ip: device.ip, online: online[device.serial], ports: ports))
            case .accessPoint:
                var ap = ControllerAP(mac: device.mac, name: device.name, model: device.model, firmware: device.firmware,
                                      serial: device.serial, ip: device.ip, online: online[device.serial])
                let statusFetched = try await fetcher.fetch(ControllerRequest(path: "/api/v1/devices/\(device.serial)/wireless/status", headers: headers))
                if let body = statusFetched.response?.body, statusFetched.error == nil, let status = MerakiParsers.wirelessStatus(body) {
                    ap.radios = status.radios
                    ap.ssids = status.ssids
                }
                aps.append(ap)
            case .other:
                break
            }
        }

        // Clients de la dernière heure, page par page (en-tête Link).
        var clients: [ControllerClient] = []
        var query = [URLQueryItem(name: "timespan", value: "3600"), URLQueryItem(name: "perPage", value: "1000")]
        var path = "/api/v1/networks/\(network.id)/clients"
        for pageIndex in 0..<Self.maxClientPages {
            let fetched = try await fetcher.fetch(ControllerRequest(path: path, query: query, headers: headers))
            guard let response = fetched.response, fetched.error == nil, let list = MerakiParsers.clients(response.body, devices: devices, now: now) else {
                if pageIndex == 0, let note = ControllerFetcher.note("Clients", fetched.error) { notes.append(note) }
                break
            }
            clients.append(contentsOf: list)
            guard let next = MerakiParsers.nextPage(link: response.headers["link"]), let host = next.host,
                  ControllerURLSessionTransport.redirectAllowed(from: ControllerKind.merakiHost, to: host, kind: .meraki),
                  let components = URLComponents(url: next, resolvingAgainstBaseURL: false) else { break }
            path = components.path
            query = components.queryItems ?? []
            if pageIndex == Self.maxClientPages - 1 { notes.append("Clients\u{00A0}: plus de \(clients.count) clients, seuls les premiers sont lus.") }
        }
        // Les clients sont déjà uniques par MAC dans la réponse ; une MAC en double garde la première.
        var seen = Set<MACAddress>()
        clients = clients.filter { seen.insert($0.mac).inserted }
        notes.append("Signal des clients Wi-Fi\u{00A0}: non fourni par la liste des clients de l’API Meraki.")

        return ControllerReport(kind: .meraki, controllerName: "\(org.name) · \(network.name)", siteName: network.name,
                                switches: switches, aps: aps, clients: clients, notes: notes, readAt: now)
    }
}

// MARK: - Liens entre équipements

/// Rattache les bornes aux ports des switchs (voisin LLDP ou rattachement donné par le
/// contrôleur), dans les deux sens, et complète le nom du switch de chaque client filaire.
public enum ControllerLinker {
    public static func link(_ report: inout ControllerReport) {
        // 1. Voisin d'un port qui est une borne connue (MAC, IP ou nom).
        for s in report.switches.indices {
            for p in report.switches[s].ports.indices {
                guard var neighbor = report.switches[s].ports[p].neighbor else { continue }
                if let a = report.aps.firstIndex(where: { ap in
                    (neighbor.mac != nil && ap.mac == neighbor.mac) || (neighbor.ip != nil && ap.ip == neighbor.ip)
                        || ap.name.lowercased() == neighbor.name.lowercased()
                }) {
                    neighbor.isAccessPoint = true
                    neighbor.isInfrastructure = false
                    neighbor.name = report.aps[a].name
                    if report.aps[a].uplinkSwitchMAC == nil, report.aps[a].uplinkSwitchName == nil {
                        report.aps[a].uplinkSwitchMAC = report.switches[s].mac
                        report.aps[a].uplinkSwitchName = report.switches[s].name
                        report.aps[a].uplinkPort = report.switches[s].ports[p].number
                    }
                } else if report.switches.contains(where: { other in
                    other.id != report.switches[s].id && ((neighbor.mac != nil && other.mac == neighbor.mac) || other.name.lowercased() == neighbor.name.lowercased()
                        || (neighbor.ip != nil && other.ip == neighbor.ip))
                }) {
                    neighbor.isInfrastructure = true
                }
                report.switches[s].ports[p].neighbor = neighbor
            }
        }
        // 2. Borne qui connaît son port : le port reçoit la borne en voisin.
        for ap in report.aps {
            guard let port = ap.uplinkPort,
                  let s = report.switches.firstIndex(where: { sw in
                      (ap.uplinkSwitchMAC != nil && sw.mac == ap.uplinkSwitchMAC)
                          || (ap.uplinkSwitchName.map { sw.name.lowercased() == $0.lowercased() } ?? false)
                  }),
                  let p = report.switches[s].ports.firstIndex(where: { $0.number == port }) else { continue }
            if report.switches[s].ports[p].neighbor?.isAccessPoint != true {
                report.switches[s].ports[p].neighbor = ControllerNeighbor(name: ap.name, mac: ap.mac, ip: ap.ip, isAccessPoint: true)
            }
        }
        // 3. Nom du switch des clients filaires (donné par la MAC seule chez UniFi).
        for c in report.clients.indices where report.clients[c].isWired && report.clients[c].switchName == nil {
            if let sw = report.switchFor(mac: report.clients[c].switchMAC, name: nil) { report.clients[c].switchName = sw.name }
        }
        // 4. Nom de la borne des clients Wi-Fi.
        for c in report.clients.indices where !report.clients[c].isWired && report.clients[c].apName == nil {
            if let ap = report.ap(for: report.clients[c]) { report.clients[c].apName = ap.name }
        }
    }
}
