import Foundation

// Note 42 : rapport de suivi. Chaque rapport produit laisse un instantané léger de son site
// (appareils et problèmes relevés), gardé par site dans rapports/suivi/<clé du site>.json. La
// section « Depuis le dernier rapport » compare l'état actuel au dernier rapport du même site (ou
// au dernier rapport produit au plus tard à une date choisie) : appareils nouveaux, disparus,
// changés (IP, nom, type, port), problèmes réglés et nouveaux (alertes de la Surveillance, ports en
// erreur, WAN, Wi-Fi, DHCP). La comparaison des appareils réutilise celle de l'Analyse
// (`InventoryStore.compare`). Rien ici n'accède au réseau.

// MARK: - Problèmes suivis

/// Famille d'un problème suivi d'un rapport à l'autre.
public enum ReportIssueCategory: String, Codable, CaseIterable, Sendable {
    case surveillance, port, wan, wifi, dhcp, securite, appareil, reseau

    public var label: String {
        switch self {
        case .surveillance: return "Surveillance"
        case .port: return "Port de switch"
        case .wan: return "WAN et VPN"
        case .wifi: return "Wi-Fi"
        case .dhcp: return "DHCP"
        case .securite: return "Sécurité"
        case .appareil: return "Appareil"
        case .reseau: return "Réseau"
        }
    }
}

/// Problème relevé au moment d'un rapport. `key` est stable d'un rapport à l'autre (« wan|lien|Siège|wan2 »)
/// pour reconnaître le même problème même si ses chiffres changent.
public struct ReportIssue: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var category: ReportIssueCategory
    public var title: String
    public var severity: ReportSeverity

    public var id: String { key }

    public init(key: String, category: ReportIssueCategory, title: String, severity: ReportSeverity) {
        self.key = key
        self.category = category
        self.title = title
        self.severity = severity
    }

    enum CodingKeys: String, CodingKey { case key, category, title, severity }

    /// Lecture tolérante : une catégorie ou une gravité inconnue (autre version) devient « Réseau » / « Moyen ».
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? key
        category = (try? c.decodeIfPresent(String.self, forKey: .category)).flatMap(ReportIssueCategory.init(rawValue:)) ?? .reseau
        severity = (try? c.decodeIfPresent(String.self, forKey: .severity)).flatMap(ReportSeverity.init(rawValue:)) ?? .moyen
    }
}

// MARK: - Instantané d'un rapport

/// Appareil tel qu'il était au moment d'un rapport (assez pour comparer deux rapports).
public struct ReportSnapshotDevice: Codable, Hashable, Sendable {
    /// « mac:… » si la MAC est connue, sinon « ip:… » (mêmes clés que l'inventaire).
    public var key: String
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var name: String
    public var type: DeviceType
    public var isOnline: Bool
    public var switchLocation: String?
    public var vlan: Int?
    public var openPorts: [UInt16]

    public init(key: String, ip: IPv4Address, mac: MACAddress?, name: String, type: DeviceType, isOnline: Bool,
                switchLocation: String?, vlan: Int?, openPorts: [UInt16]) {
        self.key = key
        self.ip = ip
        self.mac = mac
        self.name = name
        self.type = type
        self.isOnline = isOnline
        self.switchLocation = switchLocation
        self.vlan = vlan
        self.openPorts = openPorts
    }

    public init(_ device: Device) {
        self.init(key: device.mac.map(InventoryStore.key(mac:)) ?? InventoryStore.key(ip: device.ip), ip: device.ip,
                  mac: device.mac, name: device.displayName, type: device.deviceType, isOnline: device.isOnline,
                  switchLocation: device.switchLocation, vlan: device.vlan, openPorts: device.openPorts.sorted())
    }

    enum CodingKeys: String, CodingKey { case key, ip, mac, name, type, isOnline, switchLocation, vlan, openPorts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        ip = try c.decode(IPv4Address.self, forKey: .ip)
        mac = try? c.decodeIfPresent(MACAddress.self, forKey: .mac)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ip.description
        type = (try? c.decodeIfPresent(String.self, forKey: .type)).flatMap(DeviceType.init(rawValue:)) ?? .inconnu
        isOnline = (try? c.decodeIfPresent(Bool.self, forKey: .isOnline)) ?? true
        switchLocation = try? c.decodeIfPresent(String.self, forKey: .switchLocation)
        vlan = try? c.decodeIfPresent(Int.self, forKey: .vlan)
        openPorts = (try? c.decodeIfPresent([UInt16].self, forKey: .openPorts)) ?? []
    }

    var inventoryEntry: InvSnapshotEntry {
        InvSnapshotEntry(key: key, ip: ip, mac: mac, name: name, isOnline: isOnline, switchLocation: switchLocation,
                         vlan: vlan, openPorts: openPorts)
    }
}

/// Instantané léger d'un rapport produit, pour un site.
public struct ReportSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Clé du site (`SiteFiles.key`).
    public var siteKey: String
    public var siteName: String
    /// Moment où le rapport a été produit.
    public var created: Date
    /// Date du rapport (« 2026-11-03 »).
    public var reportDate: String
    /// « Audit réseau — Siège »
    public var title: String
    public var fileName: String
    /// Dossier du fichier ; nil : dossier des rapports de NetScope.
    public var folder: String?
    public var format: ReportFormat
    /// Nom du rapport planifié qui l'a produit ; nil : produit à la main.
    public var scheduleName: String?
    /// Date du scan décrit par le rapport.
    public var scanDate: Date?
    public var devices: [ReportSnapshotDevice]
    public var issues: [ReportIssue]

    public init(id: UUID = UUID(), siteKey: String, siteName: String, created: Date, reportDate: String, title: String,
                fileName: String, folder: String? = nil, format: ReportFormat = .pdf, scheduleName: String? = nil,
                scanDate: Date? = nil, devices: [ReportSnapshotDevice], issues: [ReportIssue]) {
        self.id = id
        self.siteKey = siteKey
        self.siteName = siteName
        self.created = created
        self.reportDate = reportDate
        self.title = title
        self.fileName = fileName
        self.folder = folder
        self.format = format
        self.scheduleName = scheduleName
        self.scanDate = scanDate
        self.devices = devices
        self.issues = issues
    }

    enum CodingKeys: String, CodingKey {
        case id, siteKey, siteName, created, reportDate, title, fileName, folder, format, scheduleName, scanDate, devices, issues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        siteKey = (try? c.decodeIfPresent(String.self, forKey: .siteKey)) ?? ""
        siteName = (try? c.decodeIfPresent(String.self, forKey: .siteName)) ?? ""
        created = try c.decode(Date.self, forKey: .created)
        reportDate = (try? c.decodeIfPresent(String.self, forKey: .reportDate)) ?? ReportText.isoDay(created)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Rapport"
        fileName = (try? c.decodeIfPresent(String.self, forKey: .fileName)) ?? ""
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        format = (try? c.decodeIfPresent(String.self, forKey: .format)).flatMap(ReportFormat.init(rawValue:)) ?? .pdf
        scheduleName = try? c.decodeIfPresent(String.self, forKey: .scheduleName)
        scanDate = try? c.decodeIfPresent(Date.self, forKey: .scanDate)
        devices = ((try? c.decodeIfPresent([ReportHistory.Lossy<ReportSnapshotDevice>].self, forKey: .devices)) ?? []).compactMap(\.value)
        issues = ((try? c.decodeIfPresent([ReportHistory.Lossy<ReportIssue>].self, forKey: .issues)) ?? []).compactMap(\.value)
    }

    public var onlineCount: Int { devices.filter(\.isOnline).count }

    /// « 2026-10-06 · 182 app. · 7 problèmes · planifié »
    public var meta: String {
        var parts = [reportDate, "\(onlineCount)\u{00A0}app.", issues.count > 1 ? "\(issues.count) problèmes" : "\(issues.count) problème"]
        if scheduleName != nil { parts.append("planifié") }
        return parts.joined(separator: " · ")
    }

    /// Instantané de l'état décrit par `input` (appareils du scan et problèmes relevés).
    public static func make(input: ReportInput, siteKey: String, siteName: String, created: Date, reportDate: String,
                            title: String, fileName: String, folder: String? = nil, format: ReportFormat = .pdf,
                            scheduleName: String? = nil) -> ReportSnapshot {
        ReportSnapshot(siteKey: siteKey, siteName: siteName, created: created, reportDate: reportDate, title: title,
                       fileName: fileName, folder: folder, format: format, scheduleName: scheduleName, scanDate: input.scanDate,
                       devices: ReportFollowUp.devices(input.devices), issues: ReportFollowUp.issues(input))
    }
}

// MARK: - Base de comparaison

/// Rapport auquel on compare : le dernier du site, un rapport précis, ou le dernier produit au plus
/// tard à une date (« 2026-10-01 »).
public enum ReportFollowUpBase: Hashable, Sendable {
    case last
    case report(UUID)
    case date(String)
}

// MARK: - Résultat de la comparaison

/// Un écart d'appareil entre deux rapports.
public struct ReportDeviceChange: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case added, removed, changed

        public var label: String {
            switch self {
            case .added: return "Nouveau"
            case .removed: return "Disparu"
            case .changed: return "Changé"
            }
        }
    }

    public var kind: Kind
    public var key: String
    public var ip: IPv4Address
    public var name: String
    public var before: String
    public var after: String

    public var id: String { kind.rawValue + "|" + key + "|" + before + "|" + after }
}

/// Comparaison entre le dernier rapport (base) et l'état actuel.
public struct ReportFollowUpDiff: Hashable, Sendable {
    /// Rapport de base.
    public var baseID: UUID
    public var baseTitle: String
    public var baseDate: String
    public var baseCreated: Date
    public var baseFileName: String
    public var added: [ReportDeviceChange]
    public var removed: [ReportDeviceChange]
    public var changed: [ReportDeviceChange]
    public var resolved: [ReportIssue]
    public var newIssues: [ReportIssue]
    public var persisting: [ReportIssue]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && resolved.isEmpty && newIssues.isEmpty }
    /// Appareils changés, comptés une fois même s'ils ont plusieurs écarts (IP et port).
    public var changedDeviceCount: Int { Set(changed.map(\.key)).count }
}

/// Ce que la section « Depuis le dernier rapport » doit montrer.
public enum ReportFollowUpResult: Hashable, Sendable {
    case compared(ReportFollowUpDiff)
    /// Rien à comparer (premier rapport du site, aucun rapport avant la date choisie) : la raison.
    case noBase(String)

    public var diff: ReportFollowUpDiff? {
        if case .compared(let diff) = self { return diff }
        return nil
    }
}

// MARK: - Moteur

public enum ReportFollowUp {
    /// Un port physique actif compte comme « en erreur » à partir de ce nombre d'erreurs en entrée
    /// (même seuil que la face avant de Switchs et ports).
    public static let portErrorThreshold: UInt64 = 100
    /// Lignes au plus par tableau de la section (le reste est résumé).
    public static let maxRows = 40

    /// Appareils d'un scan, triés par clé.
    public static func devices(_ devices: [Device]) -> [ReportSnapshotDevice] {
        var seen: Set<String> = []
        var result: [ReportSnapshotDevice] = []
        for device in devices.sorted(by: { $0.ip < $1.ip }) {
            var entry = ReportSnapshotDevice(device)
            // Deux adresses pour une même MAC (conflit, double carte) : la seconde est gardée par son IP.
            if seen.contains(entry.key) { entry.key = InventoryStore.key(ip: device.ip) }
            guard !seen.contains(entry.key) else { continue }
            seen.insert(entry.key)
            result.append(entry)
        }
        return result.sorted { $0.key < $1.key }
    }

    // MARK: Problèmes

    /// Problèmes relevés pour un site : ceux du rapport (conflits IP, DHCP non autorisé, Telnet, hors
    /// ligne…), liens WAN et tunnels en alerte, étendues DHCP presque pleines, bornes FortiAP hors
    /// ligne, et ceux fournis par l'application (alertes de la Surveillance, ports en erreur).
    /// Une même clé n'apparaît qu'une fois.
    public static func issues(_ input: ReportInput) -> [ReportIssue] {
        var result: [ReportIssue] = []
        var seen: Set<String> = []
        func add(_ issue: ReportIssue) {
            guard !seen.contains(issue.key) else { return }
            seen.insert(issue.key)
            result.append(issue)
        }
        let problems = ReportBuilder.problems(input)
        // Hors ligne : un seul problème suivi, qu'ils soient listés un par un ou comptés.
        let offline = problems.filter { $0.key == ReportBuilder.offlineKey }
        let offlineCount = offline.reduce(0) { total, problem in
            total + (problem.title.first?.isNumber == true ? (Int(problem.title.prefix { $0.isNumber }) ?? 1) : 1)
        }
        for problem in problems {
            if problem.key == ReportBuilder.offlineKey {
                guard let first = offline.first else { continue }
                add(ReportIssue(key: "pb|" + ReportBuilder.offlineKey, category: .appareil,
                                title: offlineCount > 1 ? "\(offlineCount) appareils hors ligne" : first.title,
                                severity: first.severity))
                continue
            }
            add(ReportIssue(key: "pb|" + (problem.key ?? normalizedKey(problem.title)), category: category(of: problem.title),
                            title: problem.title, severity: problem.severity))
        }
        if let wan = input.wan {
            for link in wan.alertingLinks {
                guard WANAnalysis.alertText(link) != nil else { continue }
                add(ReportIssue(key: "wan|lien|\(link.site)|\(link.interface.name)", category: .wan,
                                title: link.state == .down ? "Lien WAN \(link.interface.displayName) tombé" : "Lien WAN \(link.interface.displayName) dégradé",
                                severity: link.state == .down ? .critique : .moyen))
            }
            for tunnel in wan.alertingTunnels {
                guard WANAnalysis.alertText(tunnel) != nil else { continue }
                add(ReportIssue(key: "wan|tunnel|\(tunnel.site)|\(tunnel.tunnel.name)", category: .wan,
                                title: tunnel.state == .down ? "Tunnel \(tunnel.tunnel.name) tombé" : "Tunnel \(tunnel.tunnel.name) partiel",
                                severity: tunnel.state == .down ? .critique : .moyen))
            }
        }
        if let scopes = input.dhcpScopes {
            for scope in DHCPScopeAnalysis.relevel(scopes.scopes, thresholds: input.dhcpThresholds) where scope.level >= .warning {
                add(ReportIssue(key: "dhcp|etendue|\(scope.site)|\(scope.shortName)", category: .dhcp,
                                title: scope.level == .critical ? "Étendue DHCP \(scope.alertName) pleine" : "Étendue DHCP \(scope.alertName) presque pleine",
                                severity: scope.level == .critical ? .eleve : .moyen))
            }
        }
        if let wifi = input.fortiWifi {
            for ap in wifi.offlineAPs {
                add(ReportIssue(key: "wifi|borne|\(ap.site)|\(ap.name)", category: .wifi, title: "Borne \(ap.name) hors ligne",
                                severity: .eleve))
            }
        }
        for issue in input.followUpIssues { add(issue) }
        return result.sorted { ($0.severity, $0.category.rawValue, $0.title) < ($1.severity, $1.category.rawValue, $1.title) }
    }

    /// Clé de secours d'un titre (problème sans clé fournie par le moteur) : sans le nombre de tête (« 4 appareils hors ligne » et « 5 appareils
    /// hors ligne » sont le même problème), en minuscules.
    public static func normalizedKey(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if let first = text.first, first.isNumber {
            text = String(text.drop { $0.isNumber }).trimmingCharacters(in: .whitespaces)
            text = "# " + text
        }
        return text.lowercased()
    }

    /// Famille d'un problème du rapport, d'après son titre.
    public static func category(of title: String) -> ReportIssueCategory {
        let lower = title.lowercased()
        if lower.hasPrefix("dhcp") || lower.contains("étendue") { return .dhcp }
        if lower.contains("wi-fi") || lower.contains("canal") || lower.contains("borne") || lower.contains("ssid") { return .wifi }
        if lower.contains("telnet") || lower.contains("rdp") || lower.contains("smb") || lower.contains("vnc") { return .securite }
        if lower.contains("wan") || lower.contains("tunnel") || lower.contains("vpn") { return .wan }
        if lower.contains("hors ligne") || lower.contains("non identifié") { return .appareil }
        if lower.contains("port ") || lower.contains("firmware") { return .port }
        return .reseau
    }

    /// Ports physiques actifs dont les erreurs en entrée dépassent le seuil : un problème par port.
    public static func portErrorIssues(_ snapshots: [SNMPSwitchSnapshot], threshold: UInt64 = portErrorThreshold) -> [ReportIssue] {
        var result: [ReportIssue] = []
        for snapshot in snapshots {
            for port in snapshot.physicalPorts where port.isUp && (port.inErrors ?? 0) >= threshold {
                result.append(ReportIssue(key: "port|\(snapshot.displayName)|\(port.name)", category: .port,
                                          title: "Port \(port.name) de \(snapshot.displayName) en erreur (\(port.inErrors ?? 0) erreurs)",
                                          severity: .moyen))
            }
        }
        return result
    }

    /// Alerte d'une sonde de la Surveillance (en panne ou en alerte) comme problème suivi.
    public static func monitorIssue(probeID: UUID, name: String, down: Bool, value: String? = nil) -> ReportIssue {
        var title = down ? "\(name) hors ligne" : "\(name) en alerte"
        if let value, !value.isEmpty { title += "\u{00A0}: " + value }
        return ReportIssue(key: "sonde|" + probeID.uuidString, category: .surveillance, title: title, severity: down ? .eleve : .moyen)
    }

    /// Adresse IPv4 visée par une cible de sonde (« 10.0.0.5 », « 10.0.0.5:443 », « https://10.0.0.5/x ») ;
    /// nil pour un nom d'hôte, une URL nommée ou une MAC.
    public static func targetAddress(_ target: String) -> IPv4Address? {
        var text = target.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return IPv4Address(text)
    }

    /// Une sonde concerne-t-elle ce site ? Cible IP : seulement si elle tombe dans ses plages.
    /// Cible nommée (DNS, URL, MAC, catalogue) : seulement pour le site actif (le Mac la voit d'ici).
    public static func probeBelongs(target: String, ranges: [IPRange], isActiveSite: Bool) -> Bool {
        guard let address = targetAddress(target) else { return isActiveSite }
        return ranges.contains { $0.contains(address) }
    }

    // MARK: Base et comparaison

    /// Rapport de base parmi l'historique d'un site (dans n'importe quel ordre).
    public static func base(in history: [ReportSnapshot], choice: ReportFollowUpBase) -> ReportSnapshot? {
        let sorted = history.sorted { $0.created > $1.created }
        switch choice {
        case .last:
            return sorted.first
        case .report(let id):
            return sorted.first { $0.id == id } ?? sorted.first
        case .date(let day):
            guard ReportText.longDate(day) != nil else { return sorted.first }
            return sorted.first { $0.reportDate <= day }
        }
    }

    /// Comparaison complète, ou la raison de son absence.
    public static func result(history: [ReportSnapshot], choice: ReportFollowUpBase, current: ReportSnapshot) -> ReportFollowUpResult {
        guard let base = base(in: history, choice: choice) else {
            if case .date(let day) = choice, let label = ReportText.longDate(day), !history.isEmpty {
                return .noBase("Aucun rapport de ce site produit au plus tard le \(label)\u{00A0}: choisir une date plus récente ou le dernier rapport.")
            }
            return .noBase("Premier rapport de ce site\u{00A0}: rien à comparer pour l’instant. Les prochains rapports montreront ce qui a changé depuis celui-ci.")
        }
        return .compared(compare(base: base, current: current))
    }

    /// Nouveaux, disparus et changés (IP, nom, port de switch, ports ouverts : comparaison de l'Analyse ;
    /// type d'appareil en plus), problèmes réglés, nouveaux et toujours présents.
    public static func compare(base: ReportSnapshot, current: ReportSnapshot) -> ReportFollowUpDiff {
        let before = InvSnapshot(date: base.created, entries: base.devices.map(\.inventoryEntry))
        let after = InvSnapshot(date: current.created, entries: current.devices.map(\.inventoryEntry))
        let inv = InventoryStore.compare(before, after)
        func change(_ kind: ReportDeviceChange.Kind, _ row: InvDiffRow) -> ReportDeviceChange {
            ReportDeviceChange(kind: kind, key: row.key, ip: row.ip, name: row.name, before: row.before, after: row.after)
        }
        var changed = inv.modified.map { change(.changed, $0) }
        let old = Dictionary(base.devices.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for device in current.devices where device.isOnline {
            guard let previous = old[device.key], previous.isOnline, previous.type != device.type else { continue }
            changed.append(ReportDeviceChange(kind: .changed, key: device.key, ip: device.ip, name: device.name,
                                              before: "Type \(previous.type.label)", after: "Type \(device.type.label)"))
        }
        changed.sort { ($0.ip, $0.before) < ($1.ip, $1.before) }

        let baseKeys = Set(base.issues.map(\.key))
        let currentKeys = Set(current.issues.map(\.key))
        return ReportFollowUpDiff(
            baseID: base.id, baseTitle: base.title, baseDate: base.reportDate, baseCreated: base.created, baseFileName: base.fileName,
            added: inv.added.map { change(.added, $0) },
            removed: inv.removed.map { change(.removed, $0) },
            changed: changed,
            resolved: base.issues.filter { !currentKeys.contains($0.key) },
            newIssues: current.issues.filter { !baseKeys.contains($0.key) },
            persisting: current.issues.filter { baseKeys.contains($0.key) })
    }

    // MARK: Section du rapport

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) " + (n > 1 ? many : one) }

    /// Blocs de la section « Depuis le dernier rapport ».
    public static func blocks(_ result: ReportFollowUpResult?, now: Date) -> [ReportBlock] {
        guard let result else {
            return [.note("Comparaison indisponible\u{00A0}: l’historique des rapports de ce site n’a pas pu être lu.")]
        }
        guard case .compared(let diff) = result else {
            if case .noBase(let reason) = result { return [.note(reason)] }
            return []
        }
        let label = ReportText.longDate(diff.baseDate) ?? diff.baseDate
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: diff.baseCreated, to: now).day ?? 0
        var text = "Comparaison avec le rapport «\u{00A0}\(diff.baseTitle)\u{00A0}» du \(label)"
        if days >= 1 { text += " (il y a \(plural(days, "jour", "jours")))" }
        text += ". "
        if diff.isEmpty {
            text += "Aucun changement depuis\u{00A0}: mêmes appareils, mêmes problèmes."
        } else {
            var parts: [String] = []
            if !diff.added.isEmpty { parts.append(plural(diff.added.count, "appareil nouveau", "appareils nouveaux")) }
            if !diff.removed.isEmpty { parts.append(plural(diff.removed.count, "appareil disparu", "appareils disparus")) }
            if diff.changedDeviceCount > 0 { parts.append(plural(diff.changedDeviceCount, "appareil changé", "appareils changés")) }
            if !diff.resolved.isEmpty { parts.append(plural(diff.resolved.count, "problème réglé", "problèmes réglés")) }
            if !diff.newIssues.isEmpty { parts.append(plural(diff.newIssues.count, "nouveau problème", "nouveaux problèmes")) }
            text += "Depuis\u{00A0}: " + (parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " et " + parts.last! : parts[0]) + "."
        }
        var blocks: [ReportBlock] = [.paragraph(text)]
        let critical = diff.newIssues.contains { $0.severity == .critique }
        blocks.append(.kpis([
            ReportKPI("+\(diff.added.count)", diff.added.count > 1 ? "nouveaux appareils" : "nouvel appareil"),
            ReportKPI("−\(diff.removed.count)", diff.removed.count > 1 ? "appareils disparus" : "appareil disparu",
                      tone: diff.removed.isEmpty ? .normal : .warning),
            ReportKPI("\(diff.changedDeviceCount)", diff.changedDeviceCount > 1 ? "appareils changés" : "appareil changé"),
            ReportKPI("\(diff.resolved.count)", diff.resolved.count > 1 ? "problèmes réglés" : "problème réglé",
                      tone: diff.resolved.isEmpty ? .normal : .success),
            ReportKPI("\(diff.newIssues.count)", diff.newIssues.count > 1 ? "nouveaux problèmes" : "nouveau problème",
                      tone: diff.newIssues.isEmpty ? .normal : (critical ? .critical : .warning)),
        ]))

        let deviceChanges = diff.added + diff.removed + diff.changed
        if !deviceChanges.isEmpty {
            let rows = deviceChanges.prefix(maxRows).map { c -> ReportRow in
                let badge: ReportTone = c.kind == .added ? .success : (c.kind == .removed ? .critical : .warning)
                return ReportRow([ReportCell(c.kind.label, badge: badge), ReportCell(c.name, bold: true), ReportCell(c.ip.description),
                                  ReportCell(c.before, tone: .muted), ReportCell(c.after)])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("Écart", weight: 0.8), ReportColumn("Appareil", weight: 1.6),
                                                       ReportColumn("Adresse IP", weight: 1.1, mono: true), ReportColumn("Avant", weight: 1.6),
                                                       ReportColumn("Après", weight: 1.6)],
                                             rows: Array(rows), wraps: true)))
            if deviceChanges.count > maxRows {
                blocks.append(.note("Et \(deviceChanges.count - maxRows) autres écarts (exporter l’écart complet depuis Analyse › Comparer deux scans)."))
            }
        } else {
            blocks.append(.note("Aucun appareil nouveau, disparu ou changé."))
        }

        let issueRows = diff.resolved.map { ($0, true) } + diff.newIssues.map { ($0, false) }
        if !issueRows.isEmpty {
            let rows = issueRows.prefix(maxRows).map { issue, resolved -> ReportRow in
                ReportRow([ReportCell(resolved ? "Réglé" : "Nouveau", badge: resolved ? .success : issue.severity.tone),
                           ReportCell(issue.category.label, tone: .muted),
                           ReportCell(issue.title, bold: !resolved),
                           ReportCell(issue.severity.label, badge: resolved ? nil : issue.severity.tone, tone: resolved ? .muted : .normal)])
            }
            blocks.append(.table(ReportTable(columns: [ReportColumn("État", weight: 0.8), ReportColumn("Catégorie", weight: 1.1),
                                                       ReportColumn("Problème", weight: 3.6), ReportColumn("Gravité", weight: 0.8)],
                                             rows: Array(rows), wraps: true)))
        }
        if !diff.persisting.isEmpty {
            blocks.append(.note(plural(diff.persisting.count, "problème déjà signalé reste", "problèmes déjà signalés restent")
                + " à traiter (voir «\u{00A0}Problèmes et recommandations\u{00A0}»)."))
        } else if issueRows.isEmpty {
            blocks.append(.note("Aucun problème réglé ni nouveau."))
        }
        return blocks
    }
}

// MARK: - Historique par site

/// Historique des rapports d'un site : instantanés, le plus récent d'abord.
public struct ReportHistory: Codable, Hashable, Sendable {
    /// Instantanés gardés par site (les plus anciens sont oubliés).
    public static let maxSnapshots = 40
    public var version = 1
    public private(set) var snapshots: [ReportSnapshot] = []

    public init(snapshots: [ReportSnapshot] = []) {
        self.snapshots = snapshots.sorted { $0.created > $1.created }
    }

    enum CodingKeys: String, CodingKey { case version, snapshots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        let raw = (try? c.decodeIfPresent([Lossy<ReportSnapshot>].self, forKey: .snapshots)) ?? []
        snapshots = raw.compactMap(\.value).sorted { $0.created > $1.created }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(snapshots, forKey: .snapshots)
    }

    struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Ajoute un instantané en tête ; un même fichier (même dossier) n'apparaît qu'une fois.
    public mutating func add(_ snapshot: ReportSnapshot) {
        snapshots.removeAll { $0.fileName == snapshot.fileName && $0.folder == snapshot.folder && !snapshot.fileName.isEmpty }
        snapshots.append(snapshot)
        snapshots.sort { $0.created > $1.created }
        if snapshots.count > Self.maxSnapshots { snapshots.removeLast(snapshots.count - Self.maxSnapshots) }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ReportSnapshot? {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return nil }
        return snapshots.remove(at: index)
    }

    public func snapshot(_ id: UUID) -> ReportSnapshot? { snapshots.first { $0.id == id } }

    /// rapports/suivi/
    public static func directory(in reports: URL) -> URL { reports.appendingPathComponent("suivi", isDirectory: true) }

    /// Fichier d'un site : la clé (UUID ou « aucun-site ») rendue sûre pour un nom de fichier.
    public static func url(forSite key: String, in reports: URL) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory(in: reports).appendingPathComponent((safe.isEmpty ? "site" : safe) + ".json")
    }

    public static func load(forSite key: String, in reports: URL) -> ReportHistory {
        guard let data = try? Data(contentsOf: url(forSite: key, in: reports)) else { return ReportHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReportHistory.self, from: data)) ?? ReportHistory()
    }

    public func save(forSite key: String, in reports: URL) throws {
        try FileManager.default.createDirectory(at: Self.directory(in: reports), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(forSite: key, in: reports), options: .atomic)
    }
}
