import Foundation

// Note 63 : scan d'un site sans interface, pour les scans planifiés d'un site qui n'est pas le site
// actif de l'app, et pour l'agent sans fenêtre (note 64). Il sonde les plages ENREGISTRÉES du site
// (jamais ses plages exclues), puis écrit ses résultats (sites/<id>/resultats.json) et son inventaire
// (sites/<id>/inventory.json : historique, adressage, nouveaux appareils). Pas de découverte SNMP des
// switchs ni de lecture des FortiGate : ces lectures demandent les secrets et l'interface de l'app.

/// Ce qu'il faut pour scanner un site.
public struct SiteScanRequest: Sendable {
    public var site: Site
    public var profile: ScanProfile
    public var methods: ScanMethods
    public var customPorts: [UInt16]

    public init(site: Site, profile: ScanProfile, methods: ScanMethods? = nil, customPorts: [UInt16] = []) {
        self.site = site
        self.profile = profile
        self.methods = methods ?? ScanMethods.defaults(for: profile)
        self.customPorts = customPorts
    }

    public var key: String { SiteFiles.key(for: site.id) }
}

/// Bilan d'un scan de site.
public struct SiteScanReport: Sendable {
    public var outcome: ScanRunOutcome
    public var online: Int
    public var newDevices: [Device]
    public var duration: TimeInterval
    public var message: String
    public var finishedAt: Date

    public init(outcome: ScanRunOutcome, online: Int = 0, newDevices: [Device] = [], duration: TimeInterval = 0,
                message: String, finishedAt: Date = Date()) {
        self.outcome = outcome
        self.online = online
        self.newDevices = newDevices
        self.duration = duration
        self.message = message
        self.finishedAt = finishedAt
    }
}

/// Fusion d'un scan dans les résultats enregistrés d'un site (fonction pure, testée) : mêmes règles
/// que le Scanner (MAC, fabricant et nom gardés si le scan ne les redonne pas ; emplacement et VLAN
/// connus gardés ; appareils des plages sondées qui n'ont pas répondu : hors ligne).
public enum SiteScanMerge {
    public static func merge(previous: SiteResults, found: [Device], ranges: [IPRange], exclusions: AddressExclusions,
                             startedAt: Date, finishedAt: Date) -> (results: SiteResults, newDevices: [Device]) {
        var results = previous
        var byID: [Device.ID: Device] = [:]
        var order: [Device.ID] = []
        for device in previous.devices {
            if byID[device.id] == nil { order.append(device.id) }
            byID[device.id] = device
        }
        let known = Set(byID.keys)
        var foundIDs = Set<Device.ID>()
        for incoming in found {
            foundIDs.insert(incoming.id)
            var device = incoming
            if let old = byID[incoming.id] {
                device.mac = incoming.mac ?? old.mac
                device.vendor = incoming.vendor ?? old.vendor
                if incoming.hostname == nil, old.hostname != nil {
                    device.hostname = old.hostname
                    device.nameSource = old.nameSource
                    device.nameDomain = old.nameDomain
                }
                device.snmpKind = incoming.snmpKind ?? old.snmpKind
                device.voipSignals = incoming.voipSignals ?? old.voipSignals
                device.switchName = old.switchName
                device.switchPort = old.switchPort
                device.vlan = old.vlan ?? incoming.vlan
                device.rangeLabel = incoming.rangeLabel ?? old.rangeLabel
                if incoming.openPorts.isEmpty { device.openPorts = old.openPorts }
                device.fingerprint = FPEvidence.merged(old.fingerprint, incoming.fingerprint)
                let guessed = ScanDeviceClassifier.guess(device)
                device.deviceType = guessed == .inconnu ? old.deviceType : guessed
            } else {
                order.append(incoming.id)
            }
            byID[incoming.id] = device
        }
        // Appareils connus des plages sondées qui n'ont pas répondu : hors ligne (sauf plages exclues).
        for id in known where !foundIDs.contains(id) {
            guard var device = byID[id], device.isOnline, ranges.contains(where: { $0.contains(device.ip) }),
                  !exclusions.contains(device.ip) else { continue }
            device.isOnline = false
            device.latencyMs = nil
            byID[id] = device
        }
        // Premier scan du site : rien n'est « nouveau » (comme le Scanner).
        let newIDs = previous.devices.isEmpty ? [] : found.map(\.id).filter { !known.contains($0) }
        results.devices = order.compactMap { byID[$0] }
        results.newIDs = newIDs
        results.lastScanRanges = ranges.map(\.description)
        results.startedAt = startedAt
        results.finishedAt = finishedAt
        let fresh = Set(newIDs)
        return (results, results.devices.filter { fresh.contains($0.id) })
    }
}

/// Résultat brut d'un scan de site, avant l'écriture des fichiers.
public struct SiteScanCapture: Sendable {
    public var key: String
    public var devices: [Device]
    public var ranges: [IPRange]
    public var exclusions: AddressExclusions
    public var begin: Date
    public var end: Date
    public var cancelled: Bool
    /// Scan impossible (aucune plage, tout exclu) : la raison.
    public var failure: String?

    public init(key: String, devices: [Device], ranges: [IPRange], exclusions: AddressExclusions, begin: Date, end: Date,
                cancelled: Bool, failure: String? = nil) {
        self.key = key
        self.devices = devices
        self.ranges = ranges
        self.exclusions = exclusions
        self.begin = begin
        self.end = end
        self.cancelled = cancelled
        self.failure = failure
    }
}

/// Scan d'un site, sans interface : `scan` (réseau) puis `commit` (fichiers du site). L'agent fait
/// `commit` sous le verrou partagé avec l'app ; l'app appelle `run`.
public enum SiteScanRunner {
    public static func run(_ request: SiteScanRequest, files: SiteFiles, pinger: (any ScanPinging)?,
                           now: @escaping @Sendable () -> Date = { Date() }) async -> SiteScanReport {
        commit(await scan(request, pinger: pinger, now: now), files: files)
    }

    public static func scan(_ request: SiteScanRequest, pinger: (any ScanPinging)?,
                            now: @escaping @Sendable () -> Date = { Date() }) async -> SiteScanCapture {
        let begin = now()
        let site = request.site
        var capture = SiteScanCapture(key: request.key, devices: [], ranges: [], exclusions: site.excludedAddresses,
                                      begin: begin, end: begin, cancelled: false)
        var targets: [ScanTarget] = []
        for config in site.ranges where config.isEnabled {
            if let target = try? ScanTarget(config: config) { targets.append(target) }
        }
        guard !targets.isEmpty else {
            capture.failure = "Aucune plage active enregistrée pour ce site."
            return capture
        }
        guard capture.exclusions.probeCount(in: targets.map(\.range)) > 0 else {
            capture.failure = "Toutes les adresses du site sont dans ses plages exclues."
            return capture
        }
        capture.ranges = targets.map(\.range)
        var options = ScanOptions(profile: request.profile, customPorts: request.customPorts)
        options.exclusions = capture.exclusions
        options.methods = request.methods
        let engine = ScanEngine(pinger: pinger ?? ScanNullPinger(), names: request.methods.nameResolver() ?? ScanNoNames())
        var found: [Device.ID: Device] = [:]
        var order: [Device.ID] = []
        for await event in engine.scan(targets, options: options) {
            switch event {
            case .deviceFound(let device, _), .deviceUpdated(let device, _):
                if found[device.id] == nil { order.append(device.id) }
                found[device.id] = device
            case .portsProbed(let ip, let open, _):
                found[ip.description]?.openPorts = open
            default:
                break
            }
        }
        capture.cancelled = Task.isCancelled
        capture.end = now()
        capture.devices = order.compactMap { found[$0] }
        return capture
    }

    /// Écrit les résultats et l'inventaire du site, et renvoie le bilan.
    public static func commit(_ capture: SiteScanCapture, files: SiteFiles) -> SiteScanReport {
        if let failure = capture.failure {
            return SiteScanReport(outcome: .failed, message: failure, finishedAt: capture.end)
        }
        let key = capture.key
        let previous = files.loadResults(for: key) ?? SiteResults()
        // Scan interrompu : rien n'est marqué hors ligne (seuls les appareils vus sont fusionnés).
        let merged = SiteScanMerge.merge(previous: previous, found: capture.devices, ranges: capture.cancelled ? [] : capture.ranges,
                                         exclusions: capture.exclusions, startedAt: capture.begin, finishedAt: capture.end)
        files.saveResults(merged.results, for: key)
        var outcome: ScanRunOutcome = capture.cancelled ? .partial : .ok
        var note = ""
        do {
            var inventory = try files.loadInventory(for: key)
            inventory.merge(merged.results.devices, at: capture.end)
            try files.saveInventory(inventory, for: key)
        } catch {
            // Inventaire illisible : on n'écrit rien par-dessus.
            outcome = .partial
            note = " Inventaire non mis à jour\u{00A0}: \(error.localizedDescription)"
        }
        let online = merged.results.devices.filter { device in device.isOnline && capture.ranges.contains { $0.contains(device.ip) } }.count
        let duration = capture.end.timeIntervalSince(capture.begin)
        let summary = ScanScheduler.summary(online: online, new: merged.newDevices.count, duration: duration)
        return SiteScanReport(outcome: outcome, online: online, newDevices: merged.newDevices, duration: duration,
                              message: (capture.cancelled ? "Scan interrompu\u{00A0}: " : "") + summary + "." + note,
                              finishedAt: capture.end)
    }

    /// Date du dernier scan notée dans la liste des sites (sites.json).
    public static func noteLastScan(_ date: Date, siteID: UUID, files: SiteFiles) {
        guard var list = files.loadList(), let index = list.index(of: siteID) else { return }
        list.sites[index].lastScan = date
        try? files.saveList(list)
    }
}
