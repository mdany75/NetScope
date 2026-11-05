import Foundation

// Note 41 : état du firmware de chaque équipement (à jour, mise à jour disponible, inconnu),
// jours restants et niveau de chaque licence, vue d'un site ou de tous les sites. Pur et testé.

public enum FirmwareAnalysis {
    // MARK: Firmware

    /// État d'une FortiGate d'après les images FortiOS disponibles : une mise à jour de la même
    /// branche (« 7.2.8 » → « 7.2.10 ») est proposée ; une branche plus récente (« 7.4 ») est
    /// seulement signalée, car changer de branche se planifie (nouvelles fonctions, chemin).
    public static func evaluateFortiOS(current: FortiVersion?, available: [FirmwareImage]?, edges: [FirmwareUpgradeEdge] = [])
        -> (status: FirmwareStatus, target: FirmwareImage?, newerBranch: FortiVersion?, path: [FortiVersion]) {
        guard let current, let available else { return (.unknown, nil, nil, []) }
        let newer = available.filter { $0.version > current && !$0.version.sameRelease(current) }
        let inBranch = newer.filter { $0.version.sameBranch(current) }.max { $0.version < $1.version }
        let otherBranch = newer.filter { !$0.version.sameBranch(current) }.map(\.version).max()
        guard let target = inBranch else { return (.upToDate, nil, otherBranch, []) }
        return (.updateAvailable, target, otherBranch, path(from: current, to: target.version, edges: edges))
    }

    /// État d'un FortiSwitch ou d'une FortiAP d'après la liste recommandée par la FortiGate
    /// (toute version plus récente compte) ; nil sans liste pour ce modèle.
    public static func evaluateRecommended(current: FortiVersion?, images: [FirmwareImage]?) -> (status: FirmwareStatus, target: FirmwareImage?)? {
        guard let images, !images.isEmpty else { return nil }
        guard let current else { return (.unknown, nil) }
        let best = images.filter(\.recommended).max { $0.version < $1.version } ?? images.max { $0.version < $1.version }
        guard let best, best.version > current, !best.version.sameRelease(current) else { return (.upToDate, nil) }
        return (.updateAvailable, best)
    }

    /// Étapes publiées entre deux versions (parcours en largeur) ; vide si FortiOS n'en publie pas
    /// ou si la mise à jour est directe.
    public static func path(from: FortiVersion, to: FortiVersion, edges: [FirmwareUpgradeEdge]) -> [FortiVersion] {
        guard !edges.isEmpty else { return [] }
        func key(_ v: FortiVersion) -> String { v.short }
        var previous: [String: FortiVersion] = [:]
        var queue = [from]
        var visited: Set<String> = [key(from)]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if key(node) == key(to) {
                var steps: [FortiVersion] = [node]
                var cursor = node
                while let back = previous[key(cursor)], key(back) != key(from) {
                    steps.insert(back, at: 0)
                    cursor = back
                }
                return steps
            }
            for edge in edges where key(edge.from) == key(node) && visited.insert(key(edge.to)).inserted {
                previous[key(edge.to)] = node
                queue.append(edge.to)
            }
        }
        return []
    }

    /// Images recommandées pour un équipement : par numéro de série, puis par code de plateforme.
    static func images(for device: FirmwareDevice, in catalog: [String: [FirmwareImage]]?) -> [FirmwareImage]? {
        guard let catalog else { return nil }
        if !device.serial.isEmpty, let list = catalog[FirmwareDevice.platformKey(device.serial)] { return list }
        for key in device.platformKeys.sorted() { if let list = catalog[key] { return list } }
        return nil
    }

    /// Équipements d'une lecture, avant la comparaison au parc.
    static func devices(_ site: FirmwareSiteReport) -> [FirmwareDevice] {
        let r = site.report
        var result: [FirmwareDevice] = []
        if let system = r.system {
            let e = evaluateFortiOS(current: r.currentFortiOS, available: r.availableFortiOS, edges: r.upgradeEdges)
            result.append(FirmwareDevice(controllerID: site.controllerID, site: site.site, kind: .fortigate,
                                         name: system.hostname.isEmpty ? site.site : system.hostname, model: system.model,
                                         serial: system.serial, versionText: system.version, version: r.currentFortiOS,
                                         available: e.target?.version, availableMaturity: e.target?.maturity,
                                         source: e.target == nil ? nil : .fortiguard, newerBranch: e.newerBranch, upgradePath: e.path,
                                         status: e.status, connected: true))
        }
        for sw in r.switches {
            var device = FirmwareDevice(controllerID: site.controllerID, site: site.site, kind: .fortiswitch, name: sw.name, model: sw.model,
                                        serial: sw.serial, versionText: sw.osVersion, connected: sw.connected)
            if let e = evaluateRecommended(current: device.version, images: images(for: device, in: r.switchCatalog)) {
                device.status = e.status
                device.available = e.target?.version
                device.availableMaturity = e.target?.maturity
                device.source = e.target == nil ? nil : .recommended
            }
            result.append(device)
        }
        for ap in r.accessPoints {
            var device = FirmwareDevice(controllerID: site.controllerID, site: site.site, kind: .fortiap, name: ap.name, model: ap.model,
                                        serial: ap.serial, versionText: ap.firmware, connected: ap.connected)
            if let e = evaluateRecommended(current: device.version, images: images(for: device, in: r.apCatalog)) {
                device.status = e.status
                device.available = e.target?.version
                device.availableMaturity = e.target?.maturity
                device.source = e.target == nil ? nil : .recommended
            }
            result.append(device)
        }
        return result
    }

    /// FortiSwitch et FortiAP sans liste recommandée : comparés à la version la plus récente vue sur
    /// le même modèle dans le parc lu (tous les sites donnés). Seul « en retard sur le parc » est
    /// affirmé ; un équipement déjà à la version la plus récente du parc reste « inconnu ».
    static func compareToFleet(_ devices: [FirmwareDevice]) -> [FirmwareDevice] {
        var newest: [String: FortiVersion] = [:]
        for d in devices where d.kind != .fortigate {
            guard let v = d.version else { continue }
            let key = d.kind.rawValue + "|" + FirmwareDevice.platformKey(d.model)
            if newest[key].map({ v > $0 }) ?? true { newest[key] = v }
        }
        return devices.map { d in
            guard d.kind != .fortigate, d.status == .unknown, d.source == nil, let v = d.version,
                  let best = newest[d.kind.rawValue + "|" + FirmwareDevice.platformKey(d.model)],
                  best > v, !best.sameRelease(v) else { return d }
            var copy = d
            copy.status = .updateAvailable
            copy.available = best
            copy.source = .parc
            return copy
        }
    }

    // MARK: Licences

    /// Jours entiers restants avant l'expiration (négatif : expirée).
    public static func daysLeft(_ expires: Date, now: Date) -> Int {
        let seconds = expires.timeIntervalSince(now)
        return Int((seconds / 86_400).rounded(.down))
    }

    /// Niveau d'une licence : sans licence, expirée, sous 30 jours (rouge), sous 60 jours
    /// (orange), valide ; l'état « expires_soon » sans date compte comme orange.
    public static func level(_ license: FirmwareLicense, now: Date, thresholds: FirmwareThresholds = .standard) -> (days: Int?, level: LicenseLevel) {
        let status = license.status ?? ""
        let days = license.expires.map { daysLeft($0, now: now) }
        if FirmwareParsers.absentStates.contains(status) { return (days, .notLicensed) }
        if FirmwareParsers.expiredStates.contains(status) { return (days, .expired) }
        if let days {
            if days < 0 { return (days, .expired) }
            if days <= thresholds.criticalDays { return (days, .critical) }
            if days <= thresholds.warningDays { return (days, .warning) }
            if FirmwareParsers.soonStates.contains(status) { return (days, .warning) }
            return (days, .ok)
        }
        if FirmwareParsers.soonStates.contains(status) { return (nil, .warning) }
        if FirmwareParsers.activeStates.contains(status) { return (nil, .ok) }
        return (nil, .unknown)
    }

    // MARK: Vue

    /// Vue d'une ou plusieurs FortiGate (dans l'ordre donné).
    public static func overview(_ reports: [FirmwareSiteReport], thresholds: FirmwareThresholds = .standard, now: Date = Date()) -> FirmwareOverview {
        let devices = compareToFleet(reports.flatMap(devices))
        var licenses: [FirmwareLicenseUsage] = []
        var sites: [FirmwareSiteSummary] = []
        var notes: [String] = []
        for site in reports {
            let mine = (site.report.licenses ?? []).map { license -> FirmwareLicenseUsage in
                let l = level(license, now: now, thresholds: thresholds)
                return FirmwareLicenseUsage(controllerID: site.controllerID, site: site.site, license: license, daysLeft: l.days, level: l.level)
            }
            licenses += mine
            let own = devices.filter { $0.controllerID == site.controllerID }
            let counted = mine.filter { $0.level != .notLicensed && $0.daysLeft != nil }
            let nearest = counted.min { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
            let worst = mine.filter { $0.level != .notLicensed }.map(\.level).max()
            let system = site.report.system
            sites.append(FirmwareSiteSummary(controllerID: site.controllerID, site: site.site, hostname: system?.hostname ?? "",
                                             model: system?.model ?? "", version: site.report.currentFortiOS?.short ?? system?.version ?? "",
                                             deviceCount: own.count, updates: own.filter { $0.status == .updateAvailable }.count,
                                             unknown: own.filter { $0.status == .unknown }.count,
                                             nearestDays: nearest?.daysLeft, nearestLicense: nearest?.license.label,
                                             licenseLevel: worst, readAt: site.report.readAt))
            let prefix = reports.count > 1 ? "\(site.site)\u{00A0}: " : ""
            notes += site.report.notes.map { prefix + $0 }
        }
        let order: [FirmwareDeviceKind] = [.fortigate, .fortiswitch, .fortiap]
        let sorted = devices.sorted { a, b in
            let ia = reports.firstIndex { $0.controllerID == a.controllerID } ?? 0
            let ib = reports.firstIndex { $0.controllerID == b.controllerID } ?? 0
            let ka = order.firstIndex(of: a.kind) ?? 0
            let kb = order.firstIndex(of: b.kind) ?? 0
            return (ia, ka, a.name.lowercased()) < (ib, kb, b.name.lowercased())
        }
        let sortedLicenses = licenses.sorted { a, b in
            (a.level == .notLicensed ? 1 : 0, a.daysLeft ?? Int.max, a.site, a.license.label)
                < (b.level == .notLicensed ? 1 : 0, b.daysLeft ?? Int.max, b.site, b.license.label)
        }
        return FirmwareOverview(sites: sites, devices: sorted, licenses: sortedLicenses, notes: notes,
                                readAt: reports.map(\.report.readAt).min(), thresholds: thresholds)
    }

    // MARK: Textes

    /// « FGT-SIEGE (FortiGate) : v7.2.8 → v7.2.10 ».
    public static func alertText(_ device: FirmwareDevice) -> String? {
        guard device.status == .updateAvailable, let target = device.available else { return nil }
        return "\(device.name) (\(device.kind.label))\u{00A0}: \(device.versionLabel) → \(target.short)"
    }

    /// « Licence IPS (prévention d’intrusion) : expire dans 21 j », « … expirée ».
    public static func alertText(_ usage: FirmwareLicenseUsage) -> String? {
        switch usage.level {
        case .expired:
            if let d = usage.daysLeft, d < 0 { return "Licence \(usage.license.label) expirée depuis \(-d)\u{00A0}j" }
            return "Licence \(usage.license.label) expirée"
        case .critical, .warning:
            if let d = usage.daysLeft { return d == 0 ? "Licence \(usage.license.label)\u{00A0}: expire aujourd’hui" : "Licence \(usage.license.label)\u{00A0}: expire dans \(d)\u{00A0}j" }
            return "Licence \(usage.license.label)\u{00A0}: expire bientôt"
        default:
            return nil
        }
    }

    /// Conseil pour une licence en alerte.
    public static func advice(_ usage: FirmwareLicenseUsage) -> String {
        let base = usage.license.key.split(separator: ".").first.map(String.init) ?? usage.license.key
        if base == "forticare" {
            return "Renouveler le contrat FortiCare (assistance et accès aux mises à jour du firmware) auprès du revendeur, puis l’enregistrer sur support.fortinet.com."
        }
        if usage.level == .expired {
            return "Les signatures ne sont plus mises à jour\u{00A0}: renouveler le contrat FortiGuard auprès du revendeur, puis forcer la mise à jour (System › FortiGuard › Update Licenses & Definitions Now)."
        }
        return "Commander le renouvellement maintenant (délai du revendeur et de l’enregistrement), puis vérifier la nouvelle date dans System › FortiGuard."
    }

    /// Conseil pour un équipement à mettre à jour (NetScope ne lance jamais la mise à jour).
    public static func advice(_ device: FirmwareDevice) -> String {
        var text: String
        switch device.kind {
        case .fortigate:
            text = "Planifier la mise à jour de FortiOS dans une fenêtre de maintenance (System › Firmware & Registration), après une sauvegarde de la configuration et la lecture des notes de version."
        case .fortiswitch:
            text = "Mettre à jour le FortiSwitch depuis la FortiGate (WiFi & Switch Controller › Managed FortiSwitches › Upgrade), en dehors des heures ouvrables\u{00A0}: le switch redémarre."
        case .fortiap:
            text = "Mettre à jour la borne depuis la FortiGate (WiFi & Switch Controller › Managed FortiAPs › Upgrade)\u{00A0}: ses clients Wi-Fi seront coupés pendant le redémarrage."
        }
        if device.upgradePath.count > 1 {
            text += " Chemin publié par FortiOS\u{00A0}: " + ([device.version].compactMap { $0 } + device.upgradePath).map(\.short).joined(separator: " → ") + "."
        }
        if device.source == .parc { text += " Aucune liste recommandée lue\u{00A0}: version comparée au même modèle ailleurs dans le parc." }
        return text
    }
}
