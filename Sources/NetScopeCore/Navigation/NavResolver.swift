import Foundation

/// Ce que l'app sait au moment du double-clic : appareils du Scanner (site actif), inventaires,
/// switchs relevés, bornes, sondes, connexions. Rempli par l'app, données fixes dans les tests.
public struct NavContext: Sendable {
    public var activeSiteKey: String
    /// Appareils du Scanner (site actif), par Device.id.
    public var scanner: [String: NavDeviceRef]
    /// Fiches d'inventaire par site.
    public var inventories: [String: [InvRecord]]
    /// Relevés des switchs (SNMP ou FortiGate), par adresse de gestion.
    public var switches: [String: SNMPSwitchSnapshot]
    /// Bornes FortiAP connues : identifiant, nom, IP.
    public var accessPoints: [(id: String, name: String, ip: String?)]
    /// Clients Wi-Fi : MAC normalisée → identifiant de leur borne.
    public var wifiClients: [String: String]
    public var probes: [NavProbeRef]
    /// Connexions enregistrées de l'Accès distant : hôte (minuscules) → identifiant.
    public var remoteHosts: [String: String]

    public init(activeSiteKey: String, scanner: [NavDeviceRef] = [], inventories: [String: [InvRecord]] = [:],
                switches: [SNMPSwitchSnapshot] = [], accessPoints: [(id: String, name: String, ip: String?)] = [],
                wifiClients: [String: String] = [:], probes: [NavProbeRef] = [], remoteHosts: [String: String] = [:]) {
        self.activeSiteKey = activeSiteKey
        self.scanner = Dictionary(scanner.map { ($0.ip, $0) }, uniquingKeysWith: { first, _ in first })
        self.inventories = inventories
        self.switches = Dictionary(switches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.accessPoints = accessPoints
        self.wifiClients = wifiClients
        self.probes = probes
        self.remoteHosts = Dictionary(remoteHosts.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Recherches

    func scannerDevice(mac: String) -> NavDeviceRef? {
        scanner.values.first { $0.mac == mac }
    }

    /// Appareil du Scanner : par MAC si on la connaît, sinon par IP.
    func scannerDevice(_ ref: NavDeviceRef) -> NavDeviceRef? {
        if let mac = ref.mac, let found = scannerDevice(mac: mac) { return found }
        guard let found = scanner[ref.ip] else { return nil }
        // Même IP mais autre MAC : un autre appareil a pris l'adresse.
        if let mac = ref.mac, let other = found.mac, mac != other { return nil }
        return found
    }

    /// Fiche d'inventaire du site : par MAC, sinon par IP actuelle.
    func record(_ ref: NavDeviceRef, site: String) -> InvRecord? {
        let records = inventories[site] ?? []
        if let mac = ref.mac, let found = records.first(where: { $0.mac?.formatted(.upperColon) == mac }) { return found }
        return records.first { $0.ip.description == ref.ip && (ref.mac == nil || $0.mac == nil) }
    }

    /// Switch relevé par son nom ou son adresse (sans casse).
    public func switchSnapshot(named name: String?) -> SNMPSwitchSnapshot? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let direct = switches[name] { return direct }
        let lower = name.lowercased()
        return switches.values.sorted { $0.id < $1.id }.first {
            $0.displayName.lowercased() == lower || $0.system.name.lowercased() == lower
        }
    }

    func probe(targeting host: String) -> NavProbeRef? {
        probes.first { $0.host?.lowercased() == host.lowercased() }
    }

    func accessPoint(ip: String) -> (id: String, name: String, ip: String?)? {
        accessPoints.first { $0.ip == ip }
    }
}

/// Résolution d'un double-clic (suite logique, note 34) et du menu « Ouvrir dans › ».
public enum NavResolver {

    // MARK: Double-clic

    public static func primary(_ object: NavObject, in context: NavContext) -> NavOutcome {
        switch object {
        case .device(let ref):
            return device(ref, in: context)
        case .switchUnit(let host, let name):
            if let snapshot = host.flatMap({ context.switches[$0] }) ?? context.switchSnapshot(named: name) {
                return .go(NavDestination(.switchs, focus: .switchPort(host: snapshot.id, port: nil)))
            }
            return .message(title: "Switch pas encore relevé",
                            text: "«\u{00A0}\(name)\u{00A0}» n’a pas encore été interrogé (SNMP ou FortiGate)\u{00A0}: ses ports ne sont pas connus.",
                            suggestion: NavOption(id: "switchs", title: "Ouvrir Switchs et ports", detail: "Ajouter ou interroger le switch",
                                                  destination: NavDestination(.switchs)))
        case .port(let ref):
            return NavPortResolver.resolve(ref, in: context)
        case .accessPoint(let id, _, _):
            return .go(NavDestination(.wifi, focus: .accessPoint(id)))
        case .wifiClient(let mac, let ip, let name, let apID):
            let ref = NavDeviceRef(ip: ip ?? "", mac: mac, name: name)
            if let found = context.scannerDevice(ref) ?? (ip == nil ? nil : context.scanner[ip!]) {
                return .go(NavDestination(.appareil, focus: .device(found.ip)))
            }
            if ip != nil || mac != nil, let record = context.record(ref, site: context.activeSiteKey) {
                return .go(NavDestination(.inventaire, focus: .record(site: context.activeSiteKey, key: record.key)))
            }
            return .message(title: "Client Wi-Fi pas encore vu par le scan",
                            text: "«\u{00A0}\(name)\u{00A0}» est associé à une borne, mais n’est ni dans le dernier scan ni dans l’inventaire du site. Lancez un scan de sa plage pour ouvrir sa fiche.",
                            suggestion: apID.map { NavOption(id: "borne", title: "Voir sa borne", detail: "Wi-Fi › FortiAP",
                                                             destination: NavDestination(.wifi, focus: .accessPoint($0))) })
        case .group(let group):
            return .go(groupDestination(group, module: .inventaire))
        case .range(let text, let label):
            return .go(NavDestination(.scanner, search: rangeSearch(text: text, label: label)))
        case .vlan(let vlan):
            return .go(NavDestination(.scanner, search: "vlan:\(vlan)"))
        case .site(let key, _):
            return .go(NavDestination(.inventaire, sites: .only([key])))
        case .probe(let probe):
            return probeTarget(probe, in: context)
        case .alert(let probeID):
            guard let probeID, context.probes.contains(where: { $0.id == probeID }) else {
                return .message(title: "Sonde supprimée", text: "La sonde de cette alerte n’existe plus.", suggestion: nil)
            }
            return .go(NavDestination(.surveillance, focus: .probe(probeID)))
        case .analysisEvent(let site, let key, _):
            return .go(NavDestination(.inventaire, focus: .record(site: site, key: key), sites: .include(site)))
        case .service(let id, _):
            return .go(NavDestination(.outils, focus: .service(id)))
        case .toolResult(let tool):
            return .go(NavDestination(.outils, focus: .tool(tool)))
        case .backup(let name):
            return .go(NavDestination(.reglages, focus: .backup(name)))
        case .remoteConnection(let id, _):
            return .go(NavDestination(.acces, focus: .remote(id)))
        }
    }

    /// Appareil : sa fiche Appareil s'il est dans le Scanner (site actif), sinon sa fiche
    /// d'inventaire dans son site, sinon un message.
    static func device(_ ref: NavDeviceRef, in context: NavContext) -> NavOutcome {
        let site = ref.siteKey ?? context.activeSiteKey
        if site == context.activeSiteKey, let found = context.scannerDevice(ref) {
            return .go(NavDestination(.appareil, focus: .device(found.ip)))
        }
        if let record = context.record(ref, site: site) {
            return .go(NavDestination(.inventaire, focus: .record(site: site, key: record.key),
                                      sites: site == context.activeSiteKey ? nil : .include(site)))
        }
        return .message(title: "Appareil pas encore vu",
                        text: "«\u{00A0}\(ref.name)\u{00A0}» n’est ni dans le dernier scan ni dans l’inventaire du site. Lancez un scan de sa plage pour ouvrir sa fiche.",
                        suggestion: NavOption(id: "scanner", title: "Ouvrir le Scanner", detail: "Lancer un scan",
                                              destination: NavDestination(.scanner)))
    }

    /// Groupe de la Carte vers l'Inventaire (ou le Scanner) : exactement ces appareils, dans le site dessiné.
    public static func groupDestination(_ group: NavGroupRef, module: NavModule) -> NavDestination {
        let filter = NavFilter(origin: .carte, label: group.filterLabel, members: group.members.map(\.member),
                               siteKey: group.siteKey)
        return NavDestination(module, filter: filter, search: "", sites: module == .scanner ? nil : .include(group.siteKey))
    }

    /// Recherche d'une plage : son nom (`plage:"Bureau"`), sinon son bloc CIDR (`ip:10.0.0.0/24`).
    static func rangeSearch(text: String, label: String?) -> String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label.contains(" ") ? "plage:\"\(label)\"" : "plage:\(label)"
        }
        return "ip:" + text.trimmingCharacters(in: .whitespaces)
    }

    /// Sonde : l'appareil ou le service qu'elle surveille ; à défaut, la sonde elle-même.
    static func probeTarget(_ probe: NavProbeRef, in context: NavContext) -> NavOutcome {
        let itself = NavOption(id: "sonde", title: "Voir la sonde", detail: probe.name,
                               destination: NavDestination(.surveillance, focus: .probe(probe.id)))
        switch probe.kind {
        case .onlineService:
            return .go(NavDestination(.outils, focus: .service(probe.target)))
        case .fortiAPOffline, .fortiAPOverload:
            let wanted = probe.target.lowercased()
            if wanted != "*", let ap = context.accessPoints.first(where: { $0.name.lowercased() == wanted || $0.id.lowercased().hasSuffix("|" + wanted) }) {
                return .go(NavDestination(.wifi, focus: .accessPoint(ap.id)))
            }
            return .go(NavDestination(.wifi))
        case .switchPort:
            let ref = NavDeviceRef(ip: "", mac: probe.target)
            if let mac = ref.mac, let found = context.scannerDevice(mac: mac) {
                return .go(NavDestination(.appareil, focus: .device(found.ip)))
            }
        case .newDevices:
            return .go(NavDestination(.scanner, search: rangeSearch(text: probe.target, label: nil)))
        default:
            if let host = probe.host {
                if let found = context.scanner[host] ?? context.scanner.values.first(where: { $0.name.lowercased() == host.lowercased() }) {
                    return .go(NavDestination(.appareil, focus: .device(found.ip)))
                }
                if let record = context.record(NavDeviceRef(ip: host), site: context.activeSiteKey) {
                    return .go(NavDestination(.inventaire, focus: .record(site: context.activeSiteKey, key: record.key)))
                }
            } else if probe.target.trimmingCharacters(in: .whitespaces).isEmpty || probe.target.lowercased() == "ce mac" {
                return .go(NavDestination(.appareil))
            }
        }
        return .message(title: "Cible absente du scan",
                        text: "«\u{00A0}\(probe.target)\u{00A0}», cible de la sonde «\u{00A0}\(probe.name)\u{00A0}», n’est ni dans le dernier scan ni dans l’inventaire du site.",
                        suggestion: itself)
    }

    // MARK: Ouvrir dans ›

    /// Modules pertinents pour l'objet, dans l'ordre de la barre latérale ; la suite logique du
    /// double-clic en fait partie.
    public static func openIn(_ object: NavObject, in context: NavContext) -> [NavMenuItem] {
        var items: [NavMenuItem] = []
        func add(_ title: String, _ destination: NavDestination) {
            guard !items.contains(where: { $0.destination == destination }) else { return }
            items.append(NavMenuItem(title, destination))
        }
        switch object {
        case .device(let ref):
            deviceItems(ref, in: context, add: add)
        case .wifiClient(let mac, let ip, let name, let apID):
            deviceItems(NavDeviceRef(ip: ip ?? "", mac: mac, name: name), in: context, add: add)
            if let apID { add("Wi-Fi (sa borne)", NavDestination(.wifi, focus: .accessPoint(apID))) }
        case .accessPoint(let id, let name, let ip):
            add("Wi-Fi › FortiAP", NavDestination(.wifi, focus: .accessPoint(id)))
            if let ip { deviceItems(NavDeviceRef(ip: ip, name: name), in: context, add: add) }
        case .switchUnit(let host, let name):
            if let snapshot = host.flatMap({ context.switches[$0] }) ?? context.switchSnapshot(named: name) {
                add("Switchs et ports", NavDestination(.switchs, focus: .switchPort(host: snapshot.id, port: nil)))
            }
            add("Scanner (appareils branchés)", NavDestination(.scanner, search: switchSearch(name)))
            add("Inventaire (appareils branchés)", NavDestination(.inventaire, search: switchSearch(name)))
            if let host { deviceItems(NavDeviceRef(ip: host, name: name), in: context, add: add) }
        case .port(let ref):
            if case .go(let destination) = NavPortResolver.resolve(ref, in: context) { add("Appareil branché", destination) }
            if let filter = NavPortResolver.filter(ref, in: context) {
                add("Inventaire (appareils du port)", NavDestination(.inventaire, filter: filter, search: ""))
                add("Scanner (appareils du port)", NavDestination(.scanner, filter: filter, search: ""))
            }
            add("Switchs et ports", NavDestination(.switchs, focus: .switchPort(host: ref.host,
                                                                                   port: context.switches[ref.host]?.interface(ref.ifIndex)?.name)))
        case .group(let group):
            add("Inventaire", groupDestination(group, module: .inventaire))
            if group.siteKey == context.activeSiteKey { add("Scanner", groupDestination(group, module: .scanner)) }
            if let parent = group.parentTitle,
               let snapshot = group.parentHost.flatMap({ context.switches[$0] }) ?? context.switchSnapshot(named: parent) {
                add("Switchs et ports (\(parent))", NavDestination(.switchs, focus: .switchPort(host: snapshot.id, port: nil)))
            }
        case .range(let text, let label):
            let search = rangeSearch(text: text, label: label)
            add("Scanner", NavDestination(.scanner, search: search))
            add("Inventaire", NavDestination(.inventaire, search: search))
            add("Analyse", NavDestination(.analyse, search: search.hasPrefix("ip:") ? search : "ip:" + text))
        case .vlan(let vlan):
            add("Scanner", NavDestination(.scanner, search: "vlan:\(vlan)"))
            add("Inventaire", NavDestination(.inventaire, search: "vlan:\(vlan)"))
            add("Switchs et ports (table MAC)", NavDestination(.switchs, search: "vlan:\(vlan)"))
        case .site(let key, _):
            add("Inventaire", NavDestination(.inventaire, sites: .only([key])))
            add("Carte du réseau", NavDestination(.carte, sites: .only([key])))
            add("Analyse", NavDestination(.analyse, sites: .only([key])))
            add("Rapports", NavDestination(.rapports, sites: .only([key])))
        case .probe(let probe):
            if case .go(let destination) = probeTarget(probe, in: context) { add("Cible de la sonde", destination) }
            add("Surveillance (la sonde)", NavDestination(.surveillance, focus: .probe(probe.id)))
            if let host = probe.host {
                add("Ping continu", NavDestination(.ping, focus: .pingTarget(host)))
                if let found = context.scanner[host] { deviceItems(found, in: context, add: add) }
            }
        case .alert(let probeID):
            if let probeID, let probe = context.probes.first(where: { $0.id == probeID }) {
                add("Surveillance (la sonde)", NavDestination(.surveillance, focus: .probe(probeID)))
                for item in openIn(.probe(probe), in: context) { add(item.title, item.destination) }
            }
        case .analysisEvent(let site, let key, let ip):
            add("Inventaire (fiche et chronologie)", NavDestination(.inventaire, focus: .record(site: site, key: key), sites: .include(site)))
            if let ip { deviceItems(NavDeviceRef(ip: ip, siteKey: site), in: context, add: add) }
        case .service(let id, _):
            add("Outils › État des services", NavDestination(.outils, focus: .service(id)))
            add("Surveillance", NavDestination(.surveillance, search: "type:service"))
        case .toolResult(let tool):
            add("Outils", NavDestination(.outils, focus: .tool(tool)))
        case .backup(let name):
            add("Réglages › Export et sauvegarde", NavDestination(.reglages, focus: .backup(name)))
        case .remoteConnection(let id, let host):
            add("Accès distant", NavDestination(.acces, focus: .remote(id)))
            deviceItems(NavDeviceRef(ip: host), in: context, add: add)
        }
        return items.sorted { lhs, rhs in
            let a = NavModule.allCases.firstIndex(of: lhs.destination.module) ?? 0
            let b = NavModule.allCases.firstIndex(of: rhs.destination.module) ?? 0
            return a < b
        }
    }

    private static func switchSearch(_ name: String) -> String {
        name.contains(" ") ? "switch:\"\(name)\"" : "switch:\(name)"
    }

    /// Modules d'un appareil : fiche, inventaire, Scanner, Carte, Switchs et ports, Wi-Fi, Ping,
    /// Surveillance, Analyse, Accès distant (ceux qui ont quelque chose à montrer).
    static func deviceItems(_ ref: NavDeviceRef, in context: NavContext, add: (String, NavDestination) -> Void) {
        let site = ref.siteKey ?? context.activeSiteKey
        let inScanner = site == context.activeSiteKey ? context.scannerDevice(ref) : nil
        let record = context.record(ref, site: site)
        let ip = inScanner?.ip ?? record?.ip.description ?? ref.ip
        guard !ip.isEmpty else { return }
        if let inScanner {
            add("Fiche de l’appareil", NavDestination(.appareil, focus: .device(inScanner.ip)))
            add("Scanner", NavDestination(.scanner, focus: .device(inScanner.ip)))
            add("Carte du réseau", NavDestination(.carte, focus: .device(inScanner.ip), sites: .include(site)))
        } else if record != nil {
            add("Carte du réseau", NavDestination(.carte, focus: .device(ip), sites: .include(site)))
        }
        if let record {
            add("Inventaire", NavDestination(.inventaire, focus: .record(site: site, key: record.key),
                                             sites: site == context.activeSiteKey ? nil : .include(site)))
        }
        let switchName = inScanner?.switchName ?? record?.switchName ?? ref.switchName
        if let snapshot = context.switchSnapshot(named: switchName) {
            let port = inScanner?.switchPort ?? record?.switchPort ?? ref.switchPort
            add("Switchs et ports", NavDestination(.switchs, focus: .switchPort(host: snapshot.id, port: port)))
        } else if let snapshot = context.switches[ip] {
            add("Switchs et ports", NavDestination(.switchs, focus: .switchPort(host: snapshot.id, port: nil)))
        }
        let mac = inScanner?.mac ?? record?.mac?.formatted(.upperColon) ?? ref.mac
        if let mac, let apID = context.wifiClients[mac] {
            add("Wi-Fi (sa borne)", NavDestination(.wifi, focus: .accessPoint(apID)))
        } else if let ap = context.accessPoint(ip: ip) {
            add("Wi-Fi › FortiAP", NavDestination(.wifi, focus: .accessPoint(ap.id)))
        }
        add("Ping continu", NavDestination(.ping, focus: .pingTarget(ip)))
        if let probe = context.probe(targeting: ip) {
            add("Surveillance", NavDestination(.surveillance, focus: .probe(probe.id)))
        }
        add("Analyse", NavDestination(.analyse, search: "ip:\(ip)", sites: .include(site)))
        if let remote = context.remoteHosts[ip.lowercased()] {
            add("Accès distant", NavDestination(.acces, focus: .remote(remote)))
        }
    }
}
