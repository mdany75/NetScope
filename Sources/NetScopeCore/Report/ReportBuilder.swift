import Foundation

// Construction des sections d'un rapport à partir des vraies données : appareils du scan,
// fiches d'inventaire, relevés des switchs, Wi-Fi et problèmes constatés.

/// Plage scannée (« Bureau », « 10.182.122.0/24 », VLAN 1).
public struct ReportRange: Codable, Hashable, Sendable {
    public var label: String
    public var text: String
    public var vlan: Int?

    public init(label: String, text: String, vlan: Int? = nil) {
        self.label = label
        self.text = text
        self.vlan = vlan
    }
}

/// Switch relevé (SNMP), résumé pour le rapport.
public struct ReportSwitch: Codable, Hashable, Sendable {
    public var name: String
    public var model: String
    public var ip: String
    public var activePorts: Int
    public var totalPorts: Int
    /// nil : version inconnue (« [À COMPLÉTER] »).
    public var firmware: String?
    /// Version signalée comme à mettre à jour.
    public var firmwareOutdated: Bool
    public var uplink: String?

    public init(name: String, model: String, ip: String, activePorts: Int, totalPorts: Int, firmware: String? = nil,
                firmwareOutdated: Bool = false, uplink: String? = nil) {
        self.name = name
        self.model = model
        self.ip = ip
        self.activePorts = activePorts
        self.totalPorts = totalPorts
        self.firmware = firmware
        self.firmwareOutdated = firmwareOutdated
        self.uplink = uplink
    }

    /// Résumé d'un relevé SNMP : modèle et version tirés de sysDescr, ports physiques actifs, uplink.
    public init(snapshot: SNMPSwitchSnapshot, firmwareOutdated: Bool = false) {
        let descr = snapshot.system.summary
        let model = descr.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? descr
        let ports = snapshot.physicalPorts
        let uplinks = snapshot.uplinkInterfaces()
        let uplink = ports.first { uplinks.contains($0.index) && $0.isModular } ?? ports.first { uplinks.contains($0.index) }
        self.init(name: snapshot.displayName, model: model.isEmpty ? ReportText.missing : model,
                  ip: snapshot.host.description, activePorts: ports.filter(\.isUp).count, totalPorts: ports.count,
                  firmware: ReportSwitch.firmware(in: snapshot.system.descr), firmwareOutdated: firmwareOutdated,
                  uplink: uplink?.name)
    }

    /// Version du logiciel dans sysDescr : « Version 17.9.4a », « revision WC.16.11.0012 », « v7.2.8 ».
    public static func firmware(in descr: String) -> String? {
        let words = descr.replacingOccurrences(of: ",", with: " ").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        for (index, word) in words.enumerated() {
            let lower = word.lowercased()
            if (lower == "version" || lower == "revision" || lower == "release") && index + 1 < words.count {
                return words[index + 1]
            }
        }
        if let tagged = words.first(where: { $0.count > 2 && $0.lowercased().hasPrefix("v") && $0.dropFirst().first?.isNumber == true
            && $0.contains(".") }) {
            return String(tagged.dropFirst())
        }
        return nil
    }
}

/// Radios d'un point d'accès, quand elles sont connues (analyse Wi-Fi).
public struct ReportRadio: Codable, Hashable, Sendable {
    public var channel24: Int?
    public var channel5: Int?
    public var congested24: Bool

    public init(channel24: Int? = nil, channel5: Int? = nil, congested24: Bool = false) {
        self.channel24 = channel24
        self.channel5 = channel5
        self.congested24 = congested24
    }
}

/// Ligne de l'annexe brute ; la MAC éventuelle est masquée si l'option est cochée.
public struct ReportRawLine: Codable, Hashable, Sendable {
    public var prefix: String
    public var mac: MACAddress?
    public var suffix: String

    public init(_ prefix: String, mac: MACAddress? = nil, suffix: String = "") {
        self.prefix = prefix
        self.mac = mac
        self.suffix = suffix
    }

    public func render(masked: Bool) -> String {
        guard let mac else { return prefix + suffix }
        let text = masked ? ReportText.mac(mac, masked: true).lowercased() : mac.formatted(.colon)
        return prefix + text + suffix
    }

    /// Table MAC d'un switch, façon « show mac-address » (ports d'accès puis uplinks).
    public static func macTable(_ snapshot: SNMPSwitchSnapshot, limit: Int = 40) -> [ReportRawLine] {
        let uplinks = snapshot.uplinkInterfaces()
        var lines = [ReportRawLine("\(snapshot.displayName)# show mac-address"),
                     ReportRawLine(" Port        VLAN  MAC Address         Type"),
                     ReportRawLine(" ----------  ----  -----------------   -------")]
        let entries = snapshot.fdb.sorted { ($0.ifIndex ?? 0, $0.mac.value) < ($1.ifIndex ?? 0, $1.mac.value) }
        for entry in entries.prefix(limit) {
            let port = entry.ifIndex.flatMap { snapshot.interface($0)?.name } ?? "\(entry.bridgePort)"
            let vlan = entry.vlan.map(String.init) ?? "-"
            let uplink = entry.ifIndex.map { uplinks.contains($0) } ?? false
            lines.append(ReportRawLine(" " + pad(port, 10) + "  " + pad(vlan, 4) + "  ", mac: entry.mac,
                                       suffix: uplink ? "   dynamic (uplink)" : "   dynamic"))
        }
        if entries.count > limit { lines.append(ReportRawLine(" … \(entries.count - limit) autres entrées")) }
        return lines
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}

/// Toutes les données disponibles pour un rapport.
public struct ReportInput: Sendable {
    public var devices: [Device]
    /// Fiches d'inventaire (conflits IP, appareils hors ligne) ; vide si l'inventaire n'est pas chargé.
    public var records: [InvRecord]
    public var ranges: [ReportRange]
    public var switches: [ReportSwitch]
    /// « SW-CORE-01 Te1/1/1 ↔ SW-ETG2-01 1/25 (LLDP) »
    public var links: [String]
    /// Radios connues, par adresse IP de point d'accès.
    public var radios: [String: ReportRadio]
    /// Phrase de synthèse Wi-Fi (voisinage, encombrement).
    public var wifiNote: String?
    /// Problèmes constatés ailleurs (DHCP non autorisé, Wi-Fi, firmware…).
    public var extraProblems: [ReportProblem]
    public var annex: [ReportRawLine]
    public var scanDate: Date?
    /// Poste qui a fait le scan (« Macmini-de-Dany ») et son adresse.
    public var sourceName: String?
    public var sourceIP: String?
    /// « 10.182.122.1 (FortiGate-60F) »
    public var gateway: String?
    /// Bilans « Santé courriel » de la Boîte à outils (section facultative « Santé courriel »).
    public var mailHealth: [MailHealthSummary] = []
    public var now: Date

    public init(devices: [Device], records: [InvRecord] = [], ranges: [ReportRange] = [], switches: [ReportSwitch] = [],
                links: [String] = [], radios: [String: ReportRadio] = [:], wifiNote: String? = nil,
                extraProblems: [ReportProblem] = [], annex: [ReportRawLine] = [], scanDate: Date? = nil,
                sourceName: String? = nil, sourceIP: String? = nil, gateway: String? = nil, now: Date = Date()) {
        self.devices = devices
        self.records = records
        self.ranges = ranges
        self.switches = switches
        self.links = links
        self.radios = radios
        self.wifiNote = wifiNote
        self.extraProblems = extraProblems
        self.annex = annex
        self.scanDate = scanDate
        self.sourceName = sourceName
        self.sourceIP = sourceIP
        self.gateway = gateway
        self.now = now
    }
}

/// Port ouvert jugé risqué.
public struct ReportRiskyPort: Hashable, Sendable {
    public var host: String
    public var ip: IPv4Address
    public var port: UInt16
    public var service: String
    public var severity: ReportSeverity
}

public enum ReportBuilder {
    // MARK: Ports à risque

    /// Service et gravité d'un port ouvert ; nil si le port n'est pas jugé risqué.
    /// HTTP (80) ne compte que sur un équipement réseau (interface d'administration sans TLS).
    public static func risk(port: UInt16, type: DeviceType) -> (service: String, severity: ReportSeverity)? {
        let infrastructure: Set<DeviceType> = [.switch, .routeur, .pointAcces]
        switch port {
        case 23: return ("Telnet (administration)", .eleve)
        case 21: return ("FTP (mot de passe en clair)", .moyen)
        case 69: return ("TFTP", .moyen)
        case 445: return ("SMB (partage Windows)", .moyen)
        case 139: return ("NetBIOS", .faible)
        case 3389: return ("RDP (bureau à distance)", .moyen)
        case 5900: return ("VNC (partage d’écran)", .moyen)
        case 1433: return ("SQL Server", .moyen)
        case 3306: return ("MySQL", .moyen)
        case 80 where infrastructure.contains(type): return ("HTTP sans TLS (administration)", .moyen)
        case 8080: return ("HTTP (diagnostic)", .faible)
        default: return nil
        }
    }

    public static func riskyPorts(_ devices: [Device]) -> [ReportRiskyPort] {
        var result: [ReportRiskyPort] = []
        for device in devices {
            for port in device.openPorts.sorted() {
                guard let risk = risk(port: port, type: device.deviceType) else { continue }
                result.append(ReportRiskyPort(host: device.hostnameLabel ?? device.displayName, ip: device.ip, port: port,
                                              service: risk.service, severity: risk.severity))
            }
        }
        return result.sorted { ($0.severity, $0.ip, $0.port) < ($1.severity, $1.ip, $1.port) }
    }

    // MARK: Problèmes

    /// Problèmes constatés, du plus grave au moins grave : conflits IP, problèmes fournis (DHCP non
    /// autorisé, Wi-Fi, firmware), Telnet, appareils hors ligne, appareils non identifiés.
    /// `masked` : MAC masquées (« 8C:16:45:xx:xx:xx »), comme dans l'inventaire et l'annexe.
    public static func problems(_ input: ReportInput, masked: Bool = false) -> [ReportProblem] {
        var result: [ReportProblem] = []
        // Conflits IP (inventaire).
        for conflict in conflicts(input.records) {
            let macs = conflict.macs.map { ReportText.mac($0, masked: masked) }
            let who = conflict.location.map { " L’appareil connu est sur \($0)." } ?? ""
            result.append(ReportProblem(
                title: "Conflit IP sur \(conflict.ip)", severity: .critique,
                recommendation: "Deux MAC répondent (\(macs.joined(separator: " et "))).\(who) Réserver une adresse fixe pour l’appareil légitime et la sortir de l’étendue DHCP."))
        }
        result += input.extraProblems
        // Telnet.
        for device in input.devices where device.openPorts.contains(23) {
            let name = device.hostnameLabel ?? device.displayName
            let http = device.openPorts.contains(80) ? " et l’interface HTTP" : ""
            result.append(ReportProblem(title: "Telnet ouvert sur \(name)", severity: .eleve,
                                        recommendation: "Désactiver Telnet\(http), utiliser SSH et HTTPS uniquement."))
        }
        let rdp = input.devices.filter { $0.openPorts.contains(3389) }
        if !rdp.isEmpty {
            let names = rdp.prefix(4).map { $0.hostnameLabel ?? $0.displayName }.joined(separator: ", ")
            let more = rdp.count > 4 ? " et \(rdp.count - 4) autres" : ""
            result.append(ReportProblem(title: rdp.count > 1 ? "RDP ouvert sur \(rdp.count) postes" : "RDP ouvert sur \(names)",
                                        severity: .moyen,
                                        recommendation: "Limiter le bureau à distance (\(names)\(more)) au VLAN d’administration ou au VPN, avec NLA."))
        }
        // Hors ligne.
        let offline = offlineDevices(input)
        if offline.count > 3 {
            result.append(ReportProblem(title: "\(offline.count) appareils hors ligne", severity: .moyen,
                                        recommendation: "Vérifier l’alimentation et le câblage\u{00A0}: " + offline.prefix(5).map(\.name).joined(separator: ", ")
                                            + (offline.count > 5 ? " et \(offline.count - 5) autres." : ".")))
        } else {
            for item in offline {
                let place = item.location.map { "Vérifier l’alimentation et le câble sur \($0)." } ?? "Vérifier l’alimentation et le câblage."
                result.append(ReportProblem(title: "\(item.name) (\(item.ip)) hors ligne", severity: .moyen, recommendation: place))
            }
        }
        // Firmware signalé.
        for sw in input.switches where sw.firmwareOutdated {
            if !result.contains(where: { $0.title.contains("Firmware") && $0.title.contains(sw.name) }) {
                result.append(ReportProblem(title: "Firmware \(sw.name) \(sw.firmware ?? "")".trimmingCharacters(in: .whitespaces),
                                            severity: .faible, recommendation: "Mettre à jour lors d’une fenêtre de maintenance."))
            }
        }
        // Appareils non identifiés.
        let unknown = input.devices.filter { $0.deviceType == .inconnu && ($0.customName ?? "").isEmpty && $0.vendor == nil }
        if !unknown.isEmpty {
            result.append(ReportProblem(title: unknown.count > 1 ? "\(unknown.count) appareils non identifiés" : "1 appareil non identifié",
                                        severity: .faible,
                                        recommendation: "Identifier et nommer\u{00A0}: " + unknown.prefix(4).map { $0.ip.description }.joined(separator: ", ")
                                            + (unknown.count > 4 ? "…" : ".")))
        }
        return result.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }

    struct Conflict {
        var ip: IPv4Address
        /// MAC vues sur l'adresse, la fiche la plus ancienne d'abord.
        var macs: [MACAddress]
        var location: String?
    }

    /// Conflits IP de l'inventaire, un par adresse (chaque fiche en conflit porte les autres MAC).
    static func conflicts(_ records: [InvRecord]) -> [Conflict] {
        let grouped = Dictionary(grouping: records.filter(\.hasConflict), by: \.ip)
        return grouped.keys.sorted().map { ip in
            let group = grouped[ip]!.sorted { ($0.firstSeen, $0.key) < ($1.firstSeen, $1.key) }
            var macs: [MACAddress] = []
            for record in group {
                for mac in [record.mac].compactMap({ $0 }) + record.conflictWith where !macs.contains(mac) { macs.append(mac) }
            }
            return Conflict(ip: ip, macs: macs, location: group.first?.switchLocation)
        }
    }

    /// Fiches d'inventaire qui concernent le scan courant. L'inventaire est commun à tous les clients
    /// et les plages privées se répètent d'un client à l'autre : on ne garde que les fiches dont
    /// l'adresse figure parmi les appareils du scan, et dont la MAC (si les deux sont connues) est
    /// celle de l'appareil ou l'une de celles en conflit avec lui. Sans appareil, aucune fiche.
    public static func sessionRecords(_ records: [InvRecord], devices: [Device]) -> [InvRecord] {
        let byIP = Dictionary(devices.map { ($0.ip, $0) }, uniquingKeysWith: { a, _ in a })
        return records.filter { record in
            guard let device = byIP[record.ip] else { return false }
            guard let recordMAC = record.mac, let deviceMAC = device.mac else { return true }
            return recordMAC == deviceMAC || record.conflictWith.contains(deviceMAC)
        }
    }

    struct OfflineItem {
        var name: String
        var ip: String
        var location: String?
    }

    /// Appareils hors ligne : ceux du scan, et les fiches hors ligne depuis moins de 30 jours.
    static func offlineDevices(_ input: ReportInput) -> [OfflineItem] {
        var seen: Set<String> = []
        var result: [OfflineItem] = []
        for device in input.devices where !device.isOnline {
            seen.insert(device.id)
            result.append(OfflineItem(name: device.hostnameLabel ?? device.displayName, ip: device.id, location: device.switchLocation))
        }
        for record in input.records where record.status(now: input.now) == .horsLigne && !seen.contains(record.ip.description) {
            // Une fiche hors ligne dont l'adresse est occupée par un appareil en ligne n'est plus pertinente.
            if input.devices.contains(where: { $0.ip == record.ip && $0.isOnline }) { continue }
            seen.insert(record.ip.description)
            result.append(OfflineItem(name: record.displayName, ip: record.ip.description, location: record.switchLocation))
        }
        return result.sorted { (IPv4Address($0.ip) ?? IPv4Address(0)) < (IPv4Address($1.ip) ?? IPv4Address(0)) }
    }

    // MARK: Document

    public static func build(config: ReportConfig, input: ReportInput, generator: String = "NetScope") -> ReportDocument {
        let problems = problems(input, masked: config.maskMAC)
        var sections: [ReportSection] = []
        var number = 0
        for kind in ReportSectionKind.documentOrder where config.includes(kind) {
            number += 1
            let heading = "\(number). \(kind.label)"
            let blocks: [ReportBlock]
            switch kind {
            case .resume: blocks = summary(config: config, input: input, problems: problems)
            case .plan: blocks = plan(input)
            case .switchs: blocks = switches(input)
            case .wifi: blocks = wifi(input)
            case .securite: blocks = security(input)
            case .problemes: blocks = problemBlocks(problems)
            case .inventaire: blocks = inventory(input, masked: config.maskMAC)
            case .courriel: blocks = mailHealthBlocks(input.mailHealth)
            case .annexe: blocks = annex(input, masked: config.maskMAC)
            }
            sections.append(ReportSection(kind: kind, heading: heading, blocks: blocks))
        }
        return ReportDocument(title: config.documentTitle, template: config.template, client: config.client.reportTrimmed,
                              site: config.site.reportTrimmed, technician: config.technician.reportTrimmed, date: config.date,
                              dateLabel: config.dateLabel, reference: config.reference, generator: generator,
                              signature: config.signature, sections: sections, problems: problems)
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) " + (n > 1 ? many : one) }

    static func summary(config: ReportConfig, input: ReportInput, problems: [ReportProblem]) -> [ReportBlock] {
        let devices = input.devices
        let critical = problems.filter { $0.severity == .critique }
        let networks = networksOf(input)
        let vlans = Set(devices.compactMap(\.vlan))
        let segments = max(vlans.count, networks.count)
        let switchCount = input.switches.isEmpty ? devices.filter { $0.deviceType == .switch }.count : input.switches.count
        let aps = devices.filter { $0.deviceType == .pointAcces }.count

        var text = "Scan réalisé le \(config.dateLabel)"
        if let name = input.sourceName {
            text += " depuis \(name)" + (input.sourceIP.map { " (\($0))" } ?? "")
        } else if let ip = input.sourceIP {
            text += " depuis \(ip)"
        }
        let rangeTexts = input.ranges.map(\.text)
        if !rangeTexts.isEmpty {
            text += " sur " + (rangeTexts.count > 1 ? rangeTexts.dropLast().joined(separator: ", ") + " et " + rangeTexts.last! : rangeTexts[0])
        }
        text += ". "
        let online = devices.filter(\.isOnline).count
        text += online > 1 ? "\(online) appareils ont répondu" : (online == 1 ? "1 appareil a répondu" : "Aucun appareil n’a répondu")
        let offline = devices.count - online
        text += offline > 0 ? " et \(plural(offline, "autre est hors ligne", "autres sont hors ligne")). " : ". "
        if critical.isEmpty {
            text += problems.isEmpty ? "Aucun problème n’a été relevé." : "Aucun problème critique\u{00A0}; \(plural(problems.count, "point demande", "points demandent")) une attention."
        } else {
            let titles = critical.prefix(2).map { lowerFirst($0.title) }
            let intro = critical.count > 1 ? "\(spelled(critical.count)) problèmes critiques demandent" : "Un problème critique demande"
            text += "\(intro) une action immédiate\u{00A0}: " + titles.joined(separator: " et ") + (critical.count > 2 ? ", entre autres" : "") + "."
        }

        let kpis = [
            ReportKPI("\(devices.count)", devices.count > 1 ? "appareils" : "appareil"),
            ReportKPI("\(segments)", "sous-réseaux / VLAN"),
            ReportKPI("\(switchCount)", switchCount > 1 ? "switchs" : "switch"),
            ReportKPI("\(aps)", aps > 1 ? "points d’accès" : "point d’accès"),
            ReportKPI("\(problems.count)", (problems.count > 1 ? "problèmes" : "problème") + (critical.isEmpty ? "" : ", dont \(critical.count) critique" + (critical.count > 1 ? "s" : "")),
                      tone: critical.isEmpty ? .normal : .critical),
        ]

        var blocks: [ReportBlock] = [.paragraph(text), .kpis(kpis)]
        let byType = Dictionary(grouping: devices, by: \.deviceType).mapValues(\.count)
        let top = byType.values.max() ?? 0
        let bars = byType.sorted { ($1.value, $0.key.label) < ($0.value, $1.key.label) }.map { type, count in
            ReportBar(label: type.label, count: count, fraction: top > 0 ? Double(count) / Double(top) : 0,
                      share: ReportText.percent(Double(count) / Double(max(devices.count, 1))), muted: type == .inconnu)
        }
        if !bars.isEmpty { blocks.append(.bars(title: "Répartition par type d’appareil", bars)) }
        return blocks
    }

    /// « Conflit IP… » → « conflit IP… », mais « DHCP… » reste « DHCP… » (sigle).
    static func lowerFirst(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count > 1, chars[0].isUppercase, !chars[1].isUppercase else { return text }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    static func spelled(_ n: Int) -> String {
        let words = ["Zéro", "Un", "Deux", "Trois", "Quatre", "Cinq", "Six", "Sept", "Huit", "Neuf", "Dix"]
        return n < words.count ? words[n] : "\(n)"
    }

    /// /24 des appareils et des plages, triés.
    static func networksOf(_ input: ReportInput) -> [IPv4Address] {
        Set(input.devices.map { $0.ip.value & 0xFFFF_FF00 }).sorted().map(IPv4Address.init)
    }

    static func plan(_ input: ReportInput) -> [ReportBlock] {
        let networks = networksOf(input)
        guard !networks.isEmpty else { return [.paragraph("Aucun appareil\u{00A0}: lancez un scan avant de produire le plan d’adressage.")] }
        var rows: [ReportRow] = []
        func row(_ segment: String, _ net: String, _ vlan: String, _ used: Int, total: Bool = false) -> ReportRow {
            let fraction = Double(used) / 254
            return ReportRow([ReportCell(segment, bold: total), ReportCell(net), ReportCell(vlan), ReportCell("\(used) / 254"),
                              ReportCell(ReportText.percent(fraction), tone: fraction >= 0.7 ? .warning : .normal, bar: fraction)],
                             isTotal: total)
        }
        var notes: [String] = []
        for base in networks {
            let subnet = Subnet(address: base, prefix: 24)
            let here = input.devices.filter { subnet.contains($0.ip) }
            let range = input.ranges.first { range in
                guard let parsed = try? IPRange(parsing: range.text) else { return false }
                return here.contains { parsed.contains($0.ip) }
            }
            let groups = Dictionary(grouping: here, by: { $0.vlan ?? -1 })
            let keys = groups.keys.sorted()
            for vlan in keys {
                let name: String
                if let range, range.vlan == vlan || keys.count == 1 { name = range.label }
                else if vlan < 0 { name = range?.label ?? "Sans VLAN" }
                else { name = vlanName(vlan, devices: groups[vlan] ?? []) }
                rows.append(row(name, subnet.description, vlan < 0 ? "—" : "\(vlan)", groups[vlan]?.count ?? 0))
            }
            if keys.count > 1 {
                let list = keys.filter { $0 >= 0 }.map(String.init).joined(separator: ", ")
                rows.append(row("Sous-total", subnet.description, list.isEmpty ? "—" : list, here.count, total: true))
            }
        }
        // Adresses libres du /24 le plus peuplé.
        if let busiest = networks.max(by: { a, b in
            let sa = Subnet(address: a, prefix: 24), sb = Subnet(address: b, prefix: 24)
            return input.devices.filter { sa.contains($0.ip) }.count < input.devices.filter { sb.contains($0.ip) }.count
        }) {
            let subnet = Subnet(address: busiest, prefix: 24)
            notes.append("Adresses libres sur \(subnet)\u{00A0}: \(max(0, 254 - input.devices.filter { subnet.contains($0.ip) }.count))")
        }
        notes.append("Étendue DHCP\u{00A0}: \(ReportText.missing)")
        if let gateway = input.gateway { notes.append("Passerelle \(gateway)") }
        let table = ReportTable(columns: [ReportColumn("Segment", weight: 1.3), ReportColumn("Réseau", weight: 1.3, mono: true),
                                          ReportColumn("VLAN", weight: 0.8, mono: true), ReportColumn("Appareils", weight: 0.9, trailing: true, mono: true),
                                          ReportColumn("Occupation", weight: 1.6, mono: true)],
                                rows: rows)
        return [.table(table), .note(notes.joined(separator: " · "))]
    }

    /// Nom d'un VLAN d'après les appareils qui s'y trouvent (« Wi-Fi / AP », « Imprimantes »…).
    static func vlanName(_ vlan: Int, devices: [Device]) -> String {
        let counts = Dictionary(grouping: devices, by: \.deviceType).mapValues(\.count)
        // À égalité, l'équipement le plus parlant l'emporte (une borne nomme son VLAN mieux qu'un poste).
        let priority: [DeviceType] = [.pointAcces, .camera, .imprimante, .serveur, .telephone, .iot, .poste]
        func rank(_ type: DeviceType) -> Int { priority.firstIndex(of: type) ?? priority.count }
        guard let top = counts.max(by: { ($0.value, -rank($0.key)) < ($1.value, -rank($1.key)) })?.key else { return "VLAN \(vlan)" }
        switch top {
        case .pointAcces, .telephone: return "Wi-Fi / AP"
        case .imprimante, .iot, .domotique: return "Imprimantes et IoT"
        case .camera: return "Caméras"
        case .serveur: return "Serveurs"
        case .poste: return "Postes"
        default: return "VLAN \(vlan)"
        }
    }

    static func switches(_ input: ReportInput) -> [ReportBlock] {
        guard !input.switches.isEmpty else {
            let known = input.devices.filter { $0.deviceType == .switch }
            if known.isEmpty { return [.paragraph("Aucun switch relevé. Ajoutez les switchs dans «\u{00A0}Switchs et ports\u{00A0}» (SNMP) pour situer chaque appareil.")] }
            let rows = known.map { ReportRow([ReportCell($0.hostnameLabel ?? $0.displayName, bold: true), ReportCell($0.vendorLabel),
                                              ReportCell($0.ip.description), ReportCell("—"), ReportCell(ReportText.missing, tone: .muted),
                                              ReportCell($0.switchLocation ?? "—")]) }
            return [.table(switchTable(rows)), .note("Switchs vus par le scan, sans relevé SNMP\u{00A0}: ports et firmware inconnus.")]
        }
        let rows = input.switches.map { sw in
            ReportRow([ReportCell(sw.name, bold: true), ReportCell(sw.model), ReportCell(sw.ip),
                       ReportCell("\(sw.activePorts) / \(sw.totalPorts)"),
                       sw.firmware.map { ReportCell($0, tone: sw.firmwareOutdated ? .warning : .normal) } ?? ReportCell(ReportText.missing, tone: .muted),
                       ReportCell(sw.uplink ?? "—")])
        }
        var blocks: [ReportBlock] = [.table(switchTable(rows))]
        if !input.links.isEmpty { blocks.append(.note((input.links.count > 1 ? "Liens inter-switch\u{00A0}: " : "Lien inter-switch\u{00A0}: ") + input.links.joined(separator: "\u{00A0}; ") + ".")) }
        let located = input.devices.filter { $0.switchName != nil && $0.switchPort != nil }.count
        if !input.devices.isEmpty {
            blocks.append(.note("Emplacement connu (switch et port) pour \(located) appareil\(located > 1 ? "s" : "") sur \(input.devices.count)\u{00A0}; détail par appareil dans l’inventaire."))
        }
        return blocks
    }

    static func switchTable(_ rows: [ReportRow]) -> ReportTable {
        ReportTable(columns: [ReportColumn("Switch", weight: 1.5), ReportColumn("Modèle", weight: 1.4), ReportColumn("IP", weight: 1.05, mono: true),
                              ReportColumn("Ports actifs", weight: 0.85, trailing: true, mono: true), ReportColumn("Firmware", weight: 1.1, mono: true),
                              ReportColumn("Uplink", weight: 0.8, mono: true)],
                    rows: rows, wraps: true)
    }

    static func wifi(_ input: ReportInput) -> [ReportBlock] {
        let aps = input.devices.filter { $0.deviceType == .pointAcces }
        guard !aps.isEmpty else {
            return [.paragraph("Aucun point d’accès identifié par le scan.")] + (input.wifiNote.map { [.note($0)] } ?? [])
        }
        let rows = aps.map { ap -> ReportRow in
            let name = ap.hostnameLabel ?? ap.displayName
            let radio = input.radios[ap.id]
            let clients = input.devices.filter { $0.switchName == name || ($0.switchName != nil && $0.switchName == ap.hostname) }.count
            let ch24 = radio?.channel24.map { radio?.congested24 == true ? "Canal \($0) · encombré" : "Canal \($0)" } ?? "—"
            return ReportRow([ReportCell(name, bold: true), ReportCell(ap.ip.description), ReportCell(ap.switchLocation.map { $0.replacingOccurrences(of: " · ", with: " ") } ?? "—"),
                              ReportCell(ch24, tone: radio?.congested24 == true ? .warning : .normal, bold: radio?.congested24 == true),
                              ReportCell(radio?.channel5.map { "Canal \($0)" } ?? "—"), ReportCell(clients > 0 ? "\(clients)" : "—")])
        }
        let table = ReportTable(columns: [ReportColumn("Point d’accès", weight: 1.25), ReportColumn("IP", weight: 1.05, mono: true),
                                          ReportColumn("Port switch", weight: 1.45, mono: true, shrinks: true), ReportColumn("2,4 GHz", weight: 1.3),
                                          ReportColumn("5 GHz", weight: 0.8), ReportColumn("Clients", weight: 0.6, trailing: true, mono: true)],
                                rows: rows, wraps: true)
        return [.table(table)] + (input.wifiNote.map { [.note($0)] } ?? [])
    }

    static func security(_ input: ReportInput) -> [ReportBlock] {
        let ports = riskyPorts(input.devices)
        guard !ports.isEmpty else {
            return [.paragraph("Aucun port à risque (Telnet, FTP, SMB, RDP, VNC…) trouvé parmi les ports ouverts relevés.")]
        }
        let rows = ports.map { item in
            ReportRow([ReportCell(item.host, bold: true), ReportCell(item.ip.description), ReportCell("\(item.port)"),
                       ReportCell(item.service), ReportCell(item.severity.label, badge: item.severity.tone)])
        }
        let table = ReportTable(columns: [ReportColumn("Hôte", weight: 1.6), ReportColumn("IP", weight: 1.1, mono: true),
                                          ReportColumn("Port", weight: 0.5, trailing: true, mono: true), ReportColumn("Service", weight: 1.9),
                                          ReportColumn("Risque", weight: 0.7)],
                                rows: rows, wraps: true)
        return [.table(table), .note("Ports relevés par le scan (TCP). Un port ouvert n’est pas une faille en soi\u{00A0}: le risque dépend de l’exposition et du mot de passe.")]
    }

    static func problemBlocks(_ problems: [ReportProblem]) -> [ReportBlock] {
        guard !problems.isEmpty else { return [.paragraph("Aucun problème relevé lors de ce scan.")] }
        let rows = problems.enumerated().map { index, problem in
            ReportRow([ReportCell("\(index + 1)"), ReportCell(problem.title, bold: true),
                       ReportCell(problem.severity.label, badge: problem.severity.tone), ReportCell(problem.recommendation, tone: .muted)])
        }
        return [.table(ReportTable(columns: [ReportColumn("N°", weight: 0.3, mono: true), ReportColumn("Problème", weight: 1.9),
                                             ReportColumn("Gravité", weight: 0.75), ReportColumn("Recommandation", weight: 3.2)],
                                   rows: rows, wraps: true))]
    }

    static func inventory(_ input: ReportInput, masked: Bool) -> [ReportBlock] {
        guard !input.devices.isEmpty else { return [.paragraph("Aucun appareil\u{00A0}: lancez un scan avant de produire l’inventaire.")] }
        let conflicts = Set(input.records.filter(\.hasConflict).map(\.ip))
        let rows = input.devices.sorted { $0.ip < $1.ip }.map { device -> ReportRow in
            let state: ReportCell
            if conflicts.contains(device.ip) { state = ReportCell("Conflit IP", badge: .critical) }
            else if device.isOnline { state = ReportCell("En ligne", badge: .success) }
            else { state = ReportCell("Hors ligne", badge: .neutral) }
            let type = shortType(device)
            return ReportRow([ReportCell(device.ip.description), ReportCell(device.hostnameLabel ?? device.displayName, bold: true),
                              ReportCell(type, tone: .muted), ReportCell(ReportText.mac(device.mac, masked: masked), tone: .muted),
                              ReportCell(device.switchLocation.map { $0.replacingOccurrences(of: " · ", with: " ") } ?? "—", tone: .muted),
                              ReportCell(device.vlan.map(String.init) ?? "—"), state])
        }
        // Inventaire dense (croquis : MAC et port en 11 px) : sept colonnes sur la largeur d'une page lettre.
        let table = ReportTable(columns: [ReportColumn("IP", weight: 1.05, mono: true, size: 9.9), ReportColumn("Nom", weight: 1.8, size: 9.9),
                                          ReportColumn("Type", weight: 0.9, size: 9.9), ReportColumn("MAC", weight: 1.3, mono: true, size: 8.6),
                                          ReportColumn("Port", weight: 1.4, mono: true, size: 9, shrinks: true), ReportColumn("VLAN", weight: 0.45, mono: true, size: 9.9),
                                          ReportColumn("État", weight: 0.8)],
                                rows: rows, wraps: true, dense: true)
        let online = input.devices.filter(\.isOnline).count
        let count = plural(input.devices.count, "appareil vu", "appareils vus")
        return [.note("\(count) par le scan, dont \(online) en ligne, avec leur emplacement physique (switch et port) quand il est connu. Liste aussi disponible en export CSV."),
                .table(table)]
    }

    /// Type court pour l'inventaire (« Poste Dell », « Imprimante HP », « Pare-feu »), comme le croquis.
    static func shortType(_ device: Device) -> String {
        let base: String
        switch device.deviceType {
        case .poste: base = "Poste"
        case .serveur: base = "Serveur"
        case .imprimante: base = "Imprimante"
        case .camera: base = "Caméra"
        case .pointAcces: return "Point d’accès"
        case .switch: return "Switch"
        case .routeur: return "Pare-feu"
        case .telephone: return "Téléphone"
        case .console: base = "Console"
        case .domotique: base = "Domotique"
        case .iot: return "Objet connecté"
        case .inconnu: return device.vendor ?? "Inconnu"
        }
        guard let vendor = device.vendor, !vendor.isEmpty else { return base }
        return "\(base) \(vendor)"
    }

    static func annex(_ input: ReportInput, masked: Bool) -> [ReportBlock] {
        var lines = input.annex
        // Conflits : les deux MAC vues sur la même adresse.
        for conflict in conflicts(input.records) {
            if !lines.isEmpty { lines.append(ReportRawLine("")) }
            for (index, mac) in conflict.macs.enumerated() {
                lines.append(ReportRawLine("ARP \(conflict.ip) is-at ", mac: mac, suffix: index == 0 ? "" : "   (doublon)"))
            }
        }
        if lines.isEmpty {
            lines = [ReportRawLine("IP               MAC                 Ports")]
            for device in input.devices.sorted(by: { $0.ip < $1.ip }) {
                lines.append(ReportRawLine(ReportRawLine.pad(device.ip.description, 16) + " ", mac: device.mac,
                                           suffix: "   " + device.openPorts.map(String.init).joined(separator: " ")))
            }
        }
        return [.note("Extrait brut, sans retouche\u{00A0}: tables relevées sur les switchs et observations du scan."),
                .code(lines.map { $0.render(masked: masked) })]
    }
}
