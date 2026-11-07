import Foundation

// Carte hiérarchique déduite d'un scan : Internet → passerelle → switchs → points d'accès et groupes d'appareils.
// Les rattachements viennent des champs « switch / port » des appareils (tables MAC, LLDP) quand ils sont connus.

public enum TopoNodeKind: String, Sendable {
    case internet, passerelle, `switch`, pointAcces, groupe, appareil

    public var label: String {
        switch self {
        case .internet: return "Internet / WAN"
        case .passerelle: return "Passerelle"
        case .switch: return "Switch"
        case .pointAcces: return "Point d’accès"
        case .groupe: return "Groupe d’appareils"
        case .appareil: return "Appareil"
        }
    }
}

public enum TopoStatus: String, Sendable {
    case ok, horsLigne, critique
}

public struct TopoNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: TopoNodeKind
    public var title: String
    public var subtitle: String
    public var parentID: String?
    /// Port par lequel le nœud est branché sur son parent (« Gi1/0/47 », « 12 ports », « Wi-Fi »).
    public var uplinkLabel: String?
    /// Appareils représentés (Device.id) : un seul pour un appareil, plusieurs pour un groupe.
    public var deviceIDs: [String]
    public var deviceType: DeviceType?
    public var onlineCount: Int
    public var status: TopoStatus
    /// Nœud déduit (switch connu seulement par son nom, ou regroupement par défaut).
    public var isInferred: Bool
    /// Note 78 : nature du lien vers le parent quand il vient de LLDP ou de la FortiGate (nil :
    /// rattachement déduit du champ « switch » des appareils, ou par défaut).
    public var uplinkKind: TopoLinkKind? = nil
    /// Comment un nœud déduit est connu (relevé de la FortiGate, voisin LLDP), pour le détail.
    public var note: String? = nil

    public var isWireless: Bool { uplinkLabel == "Wi-Fi" }
}

public struct TopoGraph: Sendable {
    public private(set) var nodes: [TopoNode]
    public let rootID: String
    /// Note 78 : liens entre équipements vus par LLDP ou la FortiGate (ceux de la hiérarchie et
    /// les liens redondants), orientés parent → enfant pour ceux de la hiérarchie.
    public private(set) var infraLinks: [TopoInfraLink] = []

    /// Liens redondants : vus par LLDP mais hors de la hiérarchie (deuxième chemin, anneau).
    public var redundantLinks: [TopoInfraLink] { infraLinks.filter { !$0.isTree } }
    /// Liens dessinés sur la carte : ceux de l'arbre et les liens redondants (LLDP hors arbre).
    /// Même chiffre pour la tuile « Liens affichés » et la Vue d'ensemble.
    public var drawnLinkCount: Int { links.count + redundantLinks.count }

    /// Lien LLDP entre deux nœuds, dans un sens ou dans l'autre (celui de la hiérarchie d'abord).
    public func infraLink(_ a: String, _ b: String) -> TopoInfraLink? {
        let pair = infraLinks.filter { ($0.aID == a && $0.bID == b) || ($0.aID == b && $0.bID == a) }
        return pair.first(where: \.isTree) ?? pair.first
    }

    /// Liens LLDP d'un nœud.
    public func infraLinks(of id: String) -> [TopoInfraLink] { infraLinks.filter { $0.touches(id) } }

    public func node(_ id: String) -> TopoNode? { nodes.first { $0.id == id } }

    public func children(of id: String) -> [TopoNode] {
        nodes.filter { $0.parentID == id }
    }

    /// Liens parent → enfant.
    public var links: [(parent: TopoNode, child: TopoNode)] {
        let index = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return nodes.compactMap { node in
            guard let parent = node.parentID.flatMap({ index[$0] }) else { return nil }
            return (parent, node)
        }
    }

    /// Libellé pluriel d'un groupe (« Postes », « Imprimantes »).
    public static func pluralLabel(_ type: DeviceType) -> String {
        switch type {
        case .poste: return "Postes"
        case .serveur: return "Serveurs"
        case .imprimante: return "Imprimantes"
        case .onduleur: return "Onduleurs"
        case .camera: return "Caméras"
        case .pointAcces: return "Points d’accès"
        case .switch: return "Switchs"
        case .routeur: return "Routeurs"
        case .telephone: return "Téléphones"
        case .telephoneIP: return "Téléphones IP"
        case .console: return "Consoles de jeu"
        case .domotique: return "Domotique"
        case .iot: return "IoT"
        case .inconnu: return "Inconnus"
        }
    }

    private static let typeOrder: [DeviceType] = [.serveur, .poste, .telephoneIP, .telephone, .console, .imprimante, .onduleur, .camera, .domotique, .iot, .routeur, .inconnu, .switch, .pointAcces]

    /// Construit la carte. `gateway` : passerelle de l'interface active, si connue.
    /// `switches` (note 78) : relevés des switchs du site (SNMP et FortiGate) ; leurs voisins LLDP
    /// donnent les liens entre équipements et la hiérarchie des switchs.
    public static func build(devices input: [Device], gateway: IPv4Address?, conflictIPs: Set<IPv4Address> = [],
                             switches: [SNMPSwitchSnapshot] = []) -> TopoGraph {
        // Un nœud par Device.id (l'IP) : en cas de doublon, on garde la vue en ligne la plus récente.
        var devices: [Device] = []
        var position: [String: Int] = [:]
        for device in input {
            if let index = position[device.id] {
                let other = devices[index]
                if (device.isOnline && !other.isOnline) || (device.isOnline == other.isOnline && device.lastSeen > other.lastSeen) {
                    devices[index] = device
                }
            } else {
                position[device.id] = devices.count
                devices.append(device)
            }
        }
        var nodes: [TopoNode] = []
        let internet = TopoNode(id: "internet", kind: .internet, title: "Internet", subtitle: "WAN · FAI", parentID: nil,
                                uplinkLabel: nil, deviceIDs: [], deviceType: nil, onlineCount: 0, status: .ok, isInferred: false)
        nodes.append(internet)

        // Passerelle : l'appareil à l'adresse de la passerelle, sinon le premier routeur vu.
        let gatewayDevice = devices.first { $0.ip == gateway }
            ?? devices.filter { $0.deviceType == .routeur }.min { $0.ip < $1.ip }
        let gatewayID = "passerelle"
        nodes.append(TopoNode(id: gatewayID, kind: .passerelle,
                              title: gatewayDevice?.displayName ?? "Passerelle",
                              subtitle: (gatewayDevice?.ip ?? gateway)?.description ?? "Non détectée",
                              parentID: internet.id, uplinkLabel: "WAN", deviceIDs: gatewayDevice.map { [$0.id] } ?? [],
                              deviceType: .routeur, onlineCount: gatewayDevice?.isOnline == true ? 1 : 0,
                              status: gatewayDevice.map { status(of: $0, conflicts: conflictIPs) } ?? .ok,
                              isInferred: gatewayDevice == nil))

        // Équipements réseau : switchs et points d'accès vus par le scan.
        let infra = devices.filter { ($0.deviceType == .switch || $0.deviceType == .pointAcces) && $0.id != gatewayDevice?.id }
            .sorted { $0.ip < $1.ip }
        var nameIndex: [String: String] = [:]   // nom en minuscules → id de nœud
        func register(_ names: [String?], as id: String) {
            for name in names.compactMap({ $0?.lowercased() }) where !name.isEmpty && nameIndex[name] == nil {
                nameIndex[name] = id
            }
            // Nom sans domaine (« sw-core-01.siege.local » répond aussi à « sw-core-01 »).
            for name in names.compactMap({ $0 }) {
                for key in TopoLinkResolver.nameKeys(name).dropFirst() where nameIndex[key] == nil { nameIndex[key] = id }
            }
        }
        if let gatewayDevice { register([gatewayDevice.hostname, gatewayDevice.customName], as: gatewayID) }
        for device in infra { register([device.hostname, device.customName], as: "dev:" + device.id) }

        // Switchs connus seulement par leur nom (champ « switch » d'un appareil).
        var inferred: [String] = []
        for device in devices {
            guard let name = device.switchName, !name.isEmpty, nameIndex[name.lowercased()] == nil else { continue }
            guard name != "?" else { continue }   // « sw:? » est réservé au nœud « Switchs » des ports inconnus
            let id = "sw:" + name.lowercased()
            nameIndex[name.lowercased()] = id
            inferred.append(name)
        }

        // Note 78 : liens LLDP et FortiGate entre équipements, et switchs connus seulement par un relevé.
        var learned: [TopoLearnedNode] = []
        var infraLinks: [TopoInfraLink] = []
        var snapshotByName: [String: SNMPSwitchSnapshot] = [:]
        if !switches.isEmpty {
            let infraIDs = Set(infra.map { "dev:" + $0.id })
            var kinds: [String: TopoNodeKind] = [gatewayID: .passerelle]
            for device in infra { kinds["dev:" + device.id] = device.deviceType == .switch ? .switch : .pointAcces }
            let gatewayIP = gatewayDevice?.ip
            let index = nameIndex
            let resolved = TopoLinkResolver.resolve(
                switches, gatewayID: gatewayID,
                nodeForHost: { ip in
                    if ip == gatewayIP { return gatewayID }
                    return infraIDs.contains("dev:" + ip.description) ? "dev:" + ip.description : nil
                },
                resolve: { index[$0] },
                kindOf: { kinds[$0] ?? .switch })
            learned = resolved.learned
            infraLinks = resolved.links
            for node in learned {
                for key in TopoLinkResolver.nameKeys(node.title) where nameIndex[key] == nil { nameIndex[key] = node.id }
            }
            for snapshot in switches {
                for key in TopoLinkResolver.nameKeys(snapshot.displayName) where snapshotByName[key] == nil { snapshotByName[key] = snapshot }
            }
        }

        var parentOf: [String: String] = [:]
        for device in infra {
            let id = "dev:" + device.id
            if let name = device.switchName?.lowercased(), let parent = nameIndex[name], parent != id {
                parentOf[id] = parent
            } else {
                parentOf[id] = gatewayID
            }
        }
        for name in inferred { parentOf["sw:" + name.lowercased()] = gatewayID }
        for node in learned { parentOf[node.id] = gatewayID }
        // La hiérarchie vue par LLDP l'emporte sur celle déduite des noms.
        let tree = TopoLinkResolver.tree(infraLinks, gatewayID: gatewayID, nameParent: parentOf)
        infraLinks = tree.links
        for (child, parent) in tree.parent where child != gatewayID && parentOf[child] != nil {
            parentOf[child] = parent
        }
        // Pas de boucle : un équipement qui remonterait jusqu'à lui-même est rattaché à la passerelle.
        for id in parentOf.keys {
            var seen: Set<String> = [id]
            var current = parentOf[id]
            while let step = current, step != gatewayID {
                if seen.contains(step) { parentOf[id] = gatewayID; break }
                seen.insert(step)
                current = parentOf[step]
            }
        }

        // Lien de la hiérarchie vers chaque nœud (après le contrôle des boucles).
        var treeLink: [String: TopoInfraLink] = [:]
        for index in infraLinks.indices {
            let link = infraLinks[index]
            let isTree = link.isTree && parentOf[link.bID] == link.aID
            infraLinks[index].isTree = isTree
            if isTree { treeLink[link.bID] = link }
        }
        /// Ports du lien sur la descente : « Gi1/0/47 ↔ 1/25 », « FortiLink ↔ port49 ».
        func uplinkLabel(_ link: TopoInfraLink) -> String? {
            let top = link.aPort ?? (link.kind == .fortiLink ? "FortiLink" : nil)
            switch (top, link.bPort) {
            case let (a?, b?): return "\(a) ↔ \(b)"
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }

        for device in infra {
            let id = "dev:" + device.id
            var node = TopoNode(id: id, kind: device.deviceType == .switch ? .switch : .pointAcces,
                                title: device.displayName, subtitle: device.ip.description, parentID: parentOf[id],
                                uplinkLabel: parentOf[id] == gatewayID && device.switchName == nil ? nil : device.switchPort,
                                deviceIDs: [device.id], deviceType: device.deviceType,
                                onlineCount: device.isOnline ? 1 : 0, status: status(of: device, conflicts: conflictIPs),
                                isInferred: false)
            if let link = treeLink[id] {
                node.uplinkLabel = uplinkLabel(link)
                node.uplinkKind = link.kind
            }
            nodes.append(node)
        }
        func knownBy(_ id: String, title: String, subtitle: String, note: String?) -> TopoNode {
            var node = TopoNode(id: id, kind: .switch, title: title, subtitle: subtitle,
                                parentID: parentOf[id] ?? gatewayID, uplinkLabel: nil, deviceIDs: [], deviceType: .switch,
                                onlineCount: 0, status: .ok, isInferred: true)
            node.note = note
            if let link = treeLink[id] {
                node.uplinkLabel = uplinkLabel(link)
                node.uplinkKind = link.kind
            }
            return node
        }
        for name in inferred {
            // Switch nommé par les appareils et relevé (FortiGate, SNMP) : le relevé le décrit mieux.
            let snapshot = TopoLinkResolver.nameKeys(name).lazy.compactMap { snapshotByName[$0] }.first
            let subtitle = snapshot.map { $0.controllerName.map { "FortiSwitch · \($0)" } ?? $0.host.description } ?? "Connu par son nom"
            let note = snapshot.map { snapshot in
                snapshot.controllerName.map { "FortiSwitch relevé par la FortiGate \($0) (FortiLink)\u{00A0}; son adresse n’a pas été vue par le scan." }
                    ?? "Switch relevé par SNMP (\(snapshot.host))\u{00A0}; son adresse n’a pas été vue par le scan."
            }
            nodes.append(knownBy("sw:" + name.lowercased(), title: name, subtitle: subtitle, note: note))
        }
        for item in learned {
            nodes.append(knownBy(item.id, title: item.title, subtitle: item.subtitle, note: item.note))
        }

        // Appareils finaux : regroupés par type sous leur switch (ou sous « Switchs » si le port est inconnu).
        let endDevices = devices.filter { device in
            device.id != gatewayDevice?.id && !infra.contains { $0.id == device.id }
        }
        let unknownID = "sw:?"
        var groups: [String: [Device]] = [:]
        var needsUnknown = false
        for device in endDevices {
            var parent = device.switchName.flatMap { nameIndex[$0.lowercased()] }
            if parent == nil { parent = unknownID; needsUnknown = true }
            groups["\(parent!)|\(device.deviceType.rawValue)", default: []].append(device)
        }
        if needsUnknown {
            nodes.append(TopoNode(id: unknownID, kind: .switch, title: "Switchs", subtitle: "Port non découvert",
                                  parentID: gatewayID, uplinkLabel: nil, deviceIDs: [], deviceType: .switch,
                                  onlineCount: 0, status: .ok, isInferred: true))
        }
        let sortedGroups = groups.sorted { a, b in
            let (pa, ta) = split(a.key), (pb, tb) = split(b.key)
            if pa != pb { return pa < pb }
            return (typeOrder.firstIndex(of: ta) ?? 99) < (typeOrder.firstIndex(of: tb) ?? 99)
        }
        for (groupKey, members) in sortedGroups {
            let (parent, type) = split(groupKey)
            let sorted = members.sorted { $0.ip < $1.ip }
            let online = sorted.filter(\.isOnline).count
            let conflicted = sorted.filter { conflictIPs.contains($0.ip) }.count
            let wireless = sorted.allSatisfy { ($0.switchPort ?? "").lowercased() == "wi-fi" }
            if sorted.count == 1, let device = sorted.first {
                nodes.append(TopoNode(id: "dev:" + device.id, kind: .appareil, title: device.displayName,
                                      subtitle: device.ip.description, parentID: parent,
                                      uplinkLabel: device.switchPort, deviceIDs: [device.id], deviceType: type,
                                      onlineCount: online, status: status(of: device, conflicts: conflictIPs),
                                      isInferred: false))
            } else {
                var subtitle = "\(online) en ligne"
                let vlans = Set(sorted.compactMap(\.vlan))
                if vlans.count == 1, let vlan = vlans.first {
                    subtitle = "VLAN \(vlan) · " + subtitle
                }
                if conflicted > 0 { subtitle += " · \(conflicted) conflit" + (conflicted > 1 ? "s" : "") }
                let ports = Set(sorted.compactMap(\.switchPort)).count
                nodes.append(TopoNode(id: "grp:\(groupKey)", kind: .groupe, title: "\(pluralLabel(type)) ×\(sorted.count)",
                                      subtitle: subtitle, parentID: parent,
                                      uplinkLabel: wireless ? "Wi-Fi" : (ports > 0 ? "\(ports) port" + (ports > 1 ? "s" : "") : nil),
                                      deviceIDs: sorted.map(\.id), deviceType: type, onlineCount: online,
                                      status: conflicted > 0 ? .critique : .ok, isInferred: false))
            }
        }
        // Nœud « Switchs » vide (tous les switchs déduits sans enfant) : rien à retirer, il n'existe que s'il sert.
        var graph = TopoGraph(nodes: nodes, rootID: internet.id)
        graph.infraLinks = infraLinks
        return graph
    }

    private static func split(_ groupKey: String) -> (String, DeviceType) {
        // Le type est après le dernier « | » (un nom de switch peut en contenir un).
        guard let bar = groupKey.lastIndex(of: "|") else { return (groupKey, .inconnu) }
        return (String(groupKey[..<bar]), DeviceType(rawValue: String(groupKey[groupKey.index(after: bar)...])) ?? .inconnu)
    }

    private static func status(of device: Device, conflicts: Set<IPv4Address>) -> TopoStatus {
        if conflicts.contains(device.ip) { return .critique }
        return device.isOnline ? .ok : .horsLigne
    }

    // MARK: Disposition

    public struct Point: Hashable, Sendable, Codable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Layout: Sendable {
        /// Centre de chaque nœud.
        public var positions: [String: Point]
        /// Feuilles empilées en colonne sous leur parent (reliées par un rail latéral).
        public var stacked: Set<String>
        public var width: Double
        public var height: Double
        public var nodeWidth: Double
        public var nodeHeight: Double
        /// Note 78 : nœuds placés à la main (position retenue pour le site).
        public var moved: Set<String> = []
    }

    /// Arbre rangé : un parent se centre sur ses enfants ; les feuilles d'un même parent sont empilées
    /// en colonnes de `maxStack` lignes, pour garder la carte lisible quand un switch dessert beaucoup de groupes.
    /// `hidden` : nœuds masqués (avec leurs descendants).
    public func layout(nodeWidth: Double = 150, nodeHeight: Double = 46, columnGap: Double = 26,
                       levelGap: Double = 58, stackGap: Double = 24, maxStack: Int = 4, margin: Double = 28,
                       hidden: (TopoNode) -> Bool = { _ in false }) -> Layout {
        var columnOf: [String: Double] = [:]
        var topOf: [String: Double] = [:]      // ordonnée du haut du nœud
        var stacked: Set<String> = []
        var nextColumn = 0.0
        var bottom = 0.0
        let step = nodeWidth + columnGap

        func children(_ id: String) -> [TopoNode] {
            nodes.filter { $0.parentID == id && !hidden($0) }.sorted { rank($0) < rank($1) }
        }
        func rank(_ node: TopoNode) -> Int {
            switch node.kind {
            case .switch: return node.isInferred ? 1 : 0
            case .pointAcces: return 2
            default: return 3
            }
        }
        @discardableResult
        func place(_ id: String, top: Double) -> Double {
            topOf[id] = top
            bottom = max(bottom, top + nodeHeight)
            let kids = children(id)
            let branches = kids.filter { !children($0.id).isEmpty }
            let leaves = kids.filter { children($0.id).isEmpty }
            var xs: [Double] = []
            let childTop = top + nodeHeight + levelGap
            for branch in branches { xs.append(place(branch.id, top: childTop)) }
            if leaves.count >= 2 {
                var index = 0
                while index < leaves.count {
                    let column = nextColumn
                    nextColumn += 1
                    for (row, leaf) in leaves[index..<min(index + maxStack, leaves.count)].enumerated() {
                        columnOf[leaf.id] = column
                        let leafTop = childTop + Double(row) * (nodeHeight + stackGap)
                        topOf[leaf.id] = leafTop
                        bottom = max(bottom, leafTop + nodeHeight)
                        stacked.insert(leaf.id)
                    }
                    xs.append(column)
                    index += maxStack
                }
            } else {
                for leaf in leaves { xs.append(place(leaf.id, top: childTop)) }
            }
            let x: Double
            if xs.isEmpty {
                x = nextColumn
                nextColumn += 1
            } else {
                x = ((xs.first ?? 0) + (xs.last ?? 0)) / 2
            }
            columnOf[id] = x
            return x
        }
        place(rootID, top: margin)
        let columns = max(nextColumn, 1)
        var positions: [String: Point] = [:]
        // Les rails des colonnes empilées passent à gauche des nœuds : on décale tout d'autant.
        let rail = stacked.isEmpty ? 0 : 14.0
        for (id, column) in columnOf {
            positions[id] = Point(x: margin + rail + nodeWidth / 2 + column * step, y: (topOf[id] ?? margin) + nodeHeight / 2)
        }
        return Layout(positions: positions, stacked: stacked,
                      width: margin * 2 + rail + nodeWidth + (columns - 1) * step,
                      height: bottom + margin, nodeWidth: nodeWidth, nodeHeight: nodeHeight)
    }
}
