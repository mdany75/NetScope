import Foundation

// Note 78 (Carte du réseau) : liens entre équipements d'après les voisins LLDP déjà relus par SNMP
// et ceux que donne la FortiGate (FortiLink, ISL entre FortiSwitch). Chaque lien relie deux nœuds
// d'infrastructure de la carte (passerelle, switchs, points d'accès) avec le port de chaque bout ;
// la hiérarchie de la carte en est déduite, et les liens en trop (redondance, anneau, MCLAG) sont
// gardés à part pour être dessinés comme liens redondants. Aucun accès réseau : seulement les
// relevés déjà en mémoire.

/// Nature d'un lien entre deux équipements.
public enum TopoLinkKind: String, Sendable, Codable {
    /// FortiSwitch géré par la FortiGate (lien FortiLink).
    case fortiLink
    /// Lien vers la passerelle ou un routeur (hors FortiLink).
    case uplink
    /// Lien inter-switch (ISL).
    case isl
    /// Point d'accès branché sur un switch.
    case accessPoint

    public var label: String {
        switch self {
        case .fortiLink: return "FortiLink"
        case .uplink: return "Uplink"
        case .isl: return "Lien inter-switch (ISL)"
        case .accessPoint: return "Point d’accès"
        }
    }

    /// Libellé court (pastille).
    public var shortLabel: String {
        switch self {
        case .fortiLink: return "FortiLink"
        case .uplink: return "Uplink"
        case .isl: return "ISL"
        case .accessPoint: return "AP"
        }
    }
}

/// Lien entre deux nœuds d'infrastructure, vu par LLDP ou par la FortiGate.
public struct TopoInfraLink: Identifiable, Hashable, Sendable {
    /// Bout du haut (parent dans la carte quand le lien sert à la hiérarchie).
    public var aID: String
    public var bID: String
    /// Port de chaque bout (« Gi1/0/47 », « 1/25 ») ; nil s'il n'est pas connu.
    public var aPort: String?
    public var bPort: String?
    public var kind: TopoLinkKind
    /// Vitesse du port, en Mb/s (la plus grande des deux bouts).
    public var speedMbps: Int?
    /// VLAN vus sur le lien : VLAN natif et VLAN des adresses MAC apprises sur le port.
    public var vlans: [Int]
    public var isUp: Bool
    /// Vrai si le lien vient de la FortiGate (FortiLink, ISL) et non de LLDP relu par SNMP.
    public var viaController: Bool
    /// Vrai si le lien porte la hiérarchie de la carte (parent → enfant) ; faux pour un lien
    /// redondant (deuxième chemin entre deux équipements déjà reliés).
    public var isTree: Bool

    /// Identifiant du câble : la paire d'équipements et les ports (deux câbles entre les mêmes
    /// switchs restent distincts).
    public var id: String {
        let ends = [(aID, aPort ?? ""), (bID, bPort ?? "")].sorted { $0.0 < $1.0 }
        return ends.map { "\($0.0)#\($0.1)" }.joined(separator: "↔")
    }

    public func touches(_ nodeID: String) -> Bool { aID == nodeID || bID == nodeID }

    /// L'autre bout du lien.
    public func other(_ nodeID: String) -> String { aID == nodeID ? bID : aID }

    /// Port du lien du côté de `nodeID`.
    public func port(at nodeID: String) -> String? { aID == nodeID ? aPort : bPort }

    /// Ports des deux bouts : « Gi1/0/47 ↔ 1/25 » ; un bout inconnu est omis.
    public var portsLabel: String? {
        switch (aPort, bPort) {
        case let (a?, b?): return "\(a) ↔ \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// Source en mots.
    public var sourceLabel: String { viaController ? "FortiGate" : "LLDP (SNMP)" }

    /// Vitesse en mots (« 10 Gb/s », « 100 Mb/s »).
    public var speedLabel: String? {
        guard let speedMbps, speedMbps > 0 else { return nil }
        if speedMbps >= 1000 {
            let value = Double(speedMbps) / 1000
            return value == value.rounded() ? "\(Int(value)) Gb/s" : String(format: "%.1f Gb/s", value).replacingOccurrences(of: ".", with: ",")
        }
        return "\(speedMbps) Mb/s"
    }
}

/// Nœud que les relevés font connaître sans que le scan l'ait vu (FortiSwitch derrière FortiLink,
/// switch annoncé par LLDP).
struct TopoLearnedNode {
    var id: String
    var title: String
    var subtitle: String
    var note: String
    var kind: TopoNodeKind
}

/// Résolution des voisins en liens entre nœuds.
enum TopoLinkResolver {
    /// Clé de nom : minuscules, sans le domaine (« sw-core-01.siege.local » → « sw-core-01 »).
    static func nameKeys(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        if IPv4Address(trimmed) != nil { return [trimmed] }
        if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
            return [trimmed, String(trimmed[..<dot])]
        }
        return [trimmed]
    }

    /// Port distant annoncé : un identifiant qui n'est pas un nom de port (adresse MAC, ou
    /// « FortiLink » / « ISL » ajoutés par la conversion FortiGate) est remplacé par la
    /// description, sinon omis.
    static func remotePort(_ neighbor: SNMPLLDPNeighbor) -> String? {
        func usable(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            if ["fortilink", "isl"].contains(value.lowercased()) { return nil }
            if MACAddress(value) != nil { return nil }
            return value
        }
        return usable(neighbor.portID) ?? usable(neighbor.portDescr)
    }

    struct Result {
        var links: [TopoInfraLink]
        var learned: [TopoLearnedNode]
    }

    /// `resolve` : nœud d'infrastructure d'après un nom (nil : inconnu) ; `nodeForHost` : nœud
    /// d'après l'adresse d'un relevé ; `kindOf` : nature d'un nœud connu.
    static func resolve(_ snapshots: [SNMPSwitchSnapshot], gatewayID: String,
                        nodeForHost: (IPv4Address) -> String?, resolve: (String) -> String?,
                        kindOf: (String) -> TopoNodeKind?) -> Result {
        var learned: [TopoLearnedNode] = []
        var learnedIndex: [String: String] = [:]   // clé de nom → id
        func find(_ name: String) -> String? {
            for key in nameKeys(name) {
                if let id = resolve(key) ?? learnedIndex[key] { return id }
            }
            return nil
        }
        func learn(_ name: String, subtitle: String, note: String, kind: TopoNodeKind = .switch) -> String {
            let keys = nameKeys(name)
            let id = "sw:" + (keys.first ?? name.lowercased())
            if !learned.contains(where: { $0.id == id }) {
                learned.append(TopoLearnedNode(id: id, title: name.trimmingCharacters(in: .whitespaces), subtitle: subtitle, note: note, kind: kind))
            }
            for key in keys where learnedIndex[key] == nil { learnedIndex[key] = id }
            return id
        }

        // Nœud de chaque relevé : l'appareil scanné à son adresse, sinon le nom, sinon un nœud appris.
        var snapshotNode: [String: String] = [:]   // id du relevé → nœud
        for snapshot in snapshots.sorted(by: { $0.host < $1.host }) {
            let host = snapshot.fortiLinkIP ?? snapshot.host
            if let id = nodeForHost(snapshot.host) ?? nodeForHost(host) ?? find(snapshot.displayName) {
                snapshotNode[snapshot.id] = id
            } else {
                let subtitle: String
                let note: String
                if let controller = snapshot.controllerName {
                    subtitle = "FortiSwitch · \(controller)"
                    note = "FortiSwitch relevé par la FortiGate \(controller) (FortiLink)\u{00A0}; son adresse n’a pas été vue par le scan."
                } else {
                    subtitle = snapshot.host.description
                    note = "Switch relevé par SNMP (\(snapshot.host))\u{00A0}; son adresse n’est pas dans les plages du dernier scan."
                }
                snapshotNode[snapshot.id] = learn(snapshot.displayName, subtitle: subtitle, note: note)
            }
        }

        // Un lien par câble : deux câbles entre les mêmes switchs (redondance) restent deux liens ;
        // ce que chaque bout annonce est rapproché d'après les ports connus.
        struct Edge {
            var a: String
            var b: String
            var ports: [String: String] = [:]
            /// Ports donnés par le relevé du nœud lui-même (plus sûrs que le port annoncé par le voisin).
            var ownPorts: Set<String> = []
            var speed: Int?
            var vlans: Set<Int> = []
            var up = false
            var fortiLink = false
            var viaController = true
        }
        var edges: [Edge] = []
        /// Lien déjà connu pour ce câble : même paire, ports compatibles (le plus de ports égaux).
        func matchingEdge(_ local: String, _ remote: String, localPort: String?, remotePort: String?) -> Int? {
            var best: (index: Int, score: Int)?
            for (index, edge) in edges.enumerated() where Set([edge.a, edge.b]) == Set([local, remote]) {
                var score = 0
                var compatible = true
                for (node, port) in [(local, localPort), (remote, remotePort)] {
                    guard let port, let known = edge.ports[node] else { continue }
                    if known.lowercased() == port.lowercased() { score += 1 } else { compatible = false }
                }
                if compatible, score > (best?.score ?? -1) { best = (index, score) }
            }
            return best?.index
        }

        for snapshot in snapshots.sorted(by: { $0.host < $1.host }) {
            guard let local = snapshotNode[snapshot.id] else { continue }
            let byIfIndex = Dictionary(snapshot.interfaces.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
            var fdbVLANs: [Int: Set<Int>] = [:]
            for entry in snapshot.fdb {
                guard let i = entry.ifIndex, let vlan = entry.vlan else { continue }
                fdbVLANs[i, default: []].insert(vlan)
            }
            for neighbor in snapshot.neighbors {
                let name = neighbor.sysName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let isFortiLink = neighbor.portID.lowercased() == "fortilink"
                    || (snapshot.controllerName.map { nameKeys($0).first == nameKeys(name).first } ?? false)
                var remote = find(name)
                if remote == nil, isFortiLink { remote = gatewayID }
                if remote == nil {
                    // Voisin inconnu de la carte : seul un switch (pont sans téléphone, AP ni station)
                    // devient un nœud ; un poste ou un téléphone reste un appareil final.
                    let caps = neighbor.capabilities ?? []
                    let isSwitch = caps.contains(.bridge) && !caps.contains(.telephone) && !caps.contains(.accessPoint)
                        && !caps.contains(.station) && !caps.contains(.router)
                    guard isSwitch else { continue }
                    let port = neighbor.ifIndex.flatMap { byIfIndex[$0]?.name }
                    let seenOn = snapshot.displayName + (port.map { " \($0)" } ?? "")
                    remote = learn(name, subtitle: "Annoncé par LLDP",
                                   note: "Switch annoncé par LLDP sur \(seenOn)\u{00A0}; son adresse n’a pas été vue par le scan.")
                }
                guard let remote, remote != local else { continue }
                let interface = neighbor.ifIndex.flatMap { byIfIndex[$0] }
                let localPort = interface.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
                let announced = remotePort(neighbor)
                let index: Int
                if let found = matchingEdge(local, remote, localPort: localPort, remotePort: announced) {
                    index = found
                } else {
                    edges.append(Edge(a: min(local, remote), b: max(local, remote)))
                    index = edges.count - 1
                }
                var edge = edges[index]
                if let localPort {
                    edge.ports[local] = localPort
                    edge.ownPorts.insert(local)
                }
                if !edge.ownPorts.contains(remote), let announced { edge.ports[remote] = announced }
                if let speed = interface?.speedMbps, speed <= UInt64(Int32.max) { edge.speed = max(edge.speed ?? 0, Int(speed)) }
                if let i = neighbor.ifIndex {
                    if let pvid = snapshot.pvid[i] { edge.vlans.insert(pvid) }
                    edge.vlans.formUnion(fdbVLANs[i] ?? [])
                }
                if interface.map({ $0.operStatus != .down }) ?? true { edge.up = true }
                if isFortiLink { edge.fortiLink = true }
                if !snapshot.isViaController { edge.viaController = false }
                edges[index] = edge
            }
        }

        let links = edges.map { edge -> TopoInfraLink in
            let (a, b) = (edge.a, edge.b)
            let kinds = [kindOf(a), kindOf(b)]
            let kind: TopoLinkKind
            if edge.fortiLink {
                kind = .fortiLink
            } else if a == gatewayID || b == gatewayID {
                kind = .uplink
            } else if kinds.contains(.pointAcces) {
                kind = .accessPoint
            } else {
                kind = .isl
            }
            return TopoInfraLink(aID: a, bID: b, aPort: edge.ports[a], bPort: edge.ports[b], kind: kind,
                                 speedMbps: edge.speed, vlans: edge.vlans.sorted(), isUp: edge.up,
                                 viaController: edge.viaController, isTree: false)
        }
        return Result(links: links, learned: learned)
    }

    /// Hiérarchie déduite des liens : parcours en largeur depuis la passerelle (liens actifs, les
    /// plus rapides d'abord) ; un groupe d'équipements reliés entre eux mais pas à la passerelle
    /// part de celui dont le parent par nom est hors du groupe. Rend le parent de chaque nœud
    /// atteint et le lien qui l'y rattache (orienté parent → enfant).
    static func tree(_ links: [TopoInfraLink], gatewayID: String, nameParent: [String: String])
        -> (parent: [String: String], links: [TopoInfraLink]) {
        var adjacency: [String: [Int]] = [:]
        for (index, link) in links.enumerated() where link.isUp {
            adjacency[link.aID, default: []].append(index)
            adjacency[link.bID, default: []].append(index)
        }
        for key in adjacency.keys {
            adjacency[key]?.sort { lhs, rhs in
                let (l, r) = (links[lhs], links[rhs])
                if (l.speedMbps ?? 0) != (r.speedMbps ?? 0) { return (l.speedMbps ?? 0) > (r.speedMbps ?? 0) }
                return l.id < r.id
            }
        }
        var parent: [String: String] = [:]
        var reached: Set<String> = []
        var result = links
        func walk(from root: String) {
            reached.insert(root)
            var queue = [root]
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                for index in adjacency[current] ?? [] {
                    let next = links[index].other(current)
                    guard !reached.contains(next) else { continue }
                    reached.insert(next)
                    parent[next] = current
                    var link = links[index]
                    if link.aID != current { swap(&link.aID, &link.bID); swap(&link.aPort, &link.bPort) }
                    link.isTree = true
                    result[index] = link
                    queue.append(next)
                }
            }
        }
        walk(from: gatewayID)
        // Groupes isolés de la passerelle.
        var remaining = Set(adjacency.keys).subtracting(reached)
        while !remaining.isEmpty {
            // Composante : tous les nœuds reliés au premier restant.
            let seed = remaining.min()!
            var component: Set<String> = [seed]
            var stack = [seed]
            while let current = stack.popLast() {
                for index in adjacency[current] ?? [] {
                    let next = links[index].other(current)
                    if component.insert(next).inserted { stack.append(next) }
                }
            }
            let root = component.sorted().first { id in nameParent[id].map { !component.contains($0) } ?? false }
                ?? component.sorted().first!
            walk(from: root)
            remaining.subtract(component)
        }
        return (parent, result)
    }
}
