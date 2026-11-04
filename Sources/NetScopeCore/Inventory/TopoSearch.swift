import Foundation

// Note 32 : recherche dans la Carte du réseau. La recherche multiple (note 26 : IP, nom, MAC,
// `switch:`, `port:`, `vlan:`, `type:`, `borne:`…) trouve les appareils du site dessiné et dit
// où ils sont : le nœud qui les montre (le leur, ou le groupe qui les contient, « Téléphones ×11 »),
// le chemin depuis Internet, et les autres sites où la recherche trouve aussi quelque chose.
// Logique pure, sans interface ni réseau.

public extension SearchSchema {
    /// Carte du réseau : appareils dessinés.
    static let carte = SearchSchema([
        .ip, .name, .mac, .switchName, .port, .vlan, .type,
        .accessPoint.with(example: "FortiAP-231F"), .vendor, .status, .range, .openPort, .note,
    ], example: "switch:SW-ETG2 type:imprimante")
}

/// Appareil de la carte, avec la borne Wi-Fi où il est associé et les notes de sa fiche.
public struct TopoSearchItem: SearchableRecord {
    public static var searchSchema: SearchSchema { .carte }

    public var device: Device
    /// Noms de la borne Wi-Fi (champ « switch » d'un client Wi-Fi, titre du nœud de la borne).
    public var accessPoints: [String]
    public var notes: [String]

    public init(_ device: Device, accessPoints: [String] = [], notes: [String] = []) {
        self.device = device
        self.accessPoints = accessPoints
        self.notes = notes
    }

    public func searchValues(for field: SearchAttribute) -> [String] {
        if field.key == "borne" { return accessPoints }
        return DeviceSearchItem(device, notes: notes).searchValues(for: field)
    }

    /// Colonnes du Scanner (un mot sans préfixe trouve la même chose) et la borne Wi-Fi.
    public var searchFreeText: [String] {
        DeviceSearchItem(device, notes: notes).searchFreeText + accessPoints
    }
}

/// Un appareil trouvé et le nœud de la carte qui le montre.
public struct TopoSearchHit: Hashable, Sendable {
    public let deviceID: String
    /// Nœud de l'appareil (« dev:… », « passerelle ») ou groupe qui le contient (« grp:… »).
    public let nodeID: String
    /// Vrai si le nœud est un groupe : l'appareil est désigné dans son détail.
    public let isInGroup: Bool
    /// La recherche désigne exactement cet appareil (IP complète, nom ou MAC entiers).
    public let isExact: Bool

    public init(deviceID: String, nodeID: String, isInGroup: Bool, isExact: Bool) {
        self.deviceID = deviceID
        self.nodeID = nodeID
        self.isInGroup = isInGroup
        self.isExact = isExact
    }
}

/// Appareils d'un autre site, pour « Aussi sur : … ».
public struct TopoSiteDevices: Sendable {
    public let key: String
    public let name: String
    public let devices: [Device]

    public init(key: String, name: String, devices: [Device]) {
        self.key = key
        self.name = name
        self.devices = devices
    }
}

/// Autre site où la recherche trouve des appareils.
public struct TopoSiteMatch: Hashable, Sendable {
    public let key: String
    public let name: String
    public let count: Int

    public init(key: String, name: String, count: Int) {
        self.key = key
        self.name = name
        self.count = count
    }

    /// « Entrepôt Laval (4) », ou le nom seul pour un appareil.
    public var label: String { count > 1 ? "\(name) (\(count))" : name }
}

public enum TopoSearch {
    // MARK: Éléments cherchés

    /// Noms de la borne d'un client Wi-Fi : le champ « switch » relevé (« FortiAP-231F ») et, sur la
    /// carte, le titre du nœud de la borne (« Borne Wi-Fi accueil »). Vide pour un appareil filaire.
    public static func accessPoints(of device: Device, graph: TopoGraph?) -> [String] {
        guard (device.switchPort ?? "").lowercased() == "wi-fi" else { return [] }
        var names = [device.switchName].compactMap { $0 }
        if let graph, let node = graph.nodeID(showing: device.id).flatMap(graph.node),
           let parent = node.parentID.flatMap(graph.node), parent.kind == .pointAcces || parent.kind == .switch,
           !parent.isInferred, !names.contains(parent.title) {
            names.append(parent.title)
        }
        return names
    }

    /// Éléments de recherche des appareils de la carte (un par Device.id, le premier gardé).
    public static func items(_ devices: [Device], graph: TopoGraph?, notes: (Device) -> [String] = { _ in [] }) -> [TopoSearchItem] {
        var seen: Set<String> = []
        return devices.compactMap { device in
            guard seen.insert(device.id).inserted else { return nil }
            return TopoSearchItem(device, accessPoints: accessPoints(of: device, graph: graph), notes: notes(device))
        }
    }

    // MARK: Résultats

    /// Appareils trouvés sur la carte, dans l'ordre de lecture : d'abord ceux que la recherche
    /// désigne exactement (une IP complète tapée trouve cet appareil avant .140 à .149), puis dans
    /// l'ordre de la carte (de haut en bas, branche par branche, de gauche à droite), et par IP
    /// dans un même groupe. Requête vide : aucun résultat. Un appareil absent du dessin est ignoré.
    public static func hits(_ query: SearchQuery, graph: TopoGraph, items: [TopoSearchItem]) -> [TopoSearchHit] {
        guard !query.isEmpty else { return [] }
        let order = mapOrder(graph)
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() { rank[id] = index }
        var found: [(hit: TopoSearchHit, rank: Int, ip: IPv4Address)] = []
        var seen: Set<String> = []
        for item in items where seen.insert(item.device.id).inserted && query.matches(item) {
            guard let nodeID = graph.nodeID(showing: item.device.id), let node = graph.node(nodeID) else { continue }
            let hit = TopoSearchHit(deviceID: item.device.id, nodeID: nodeID, isInGroup: node.kind == .groupe,
                                    isExact: isExact(query, item.device))
            found.append((hit, rank[nodeID] ?? Int.max, item.device.ip))
        }
        found.sort { a, b in
            if a.hit.isExact != b.hit.isExact { return a.hit.isExact }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.ip < b.ip
        }
        return found.map(\.hit)
    }

    /// Nœuds qui contiennent au moins un résultat.
    public static func matchedNodeIDs(_ hits: [TopoSearchHit]) -> Set<String> {
        Set(hits.map(\.nodeID))
    }

    /// Nombre d'appareils trouvés dans chaque nœud (« 2 trouvés » sur un groupe).
    public static func countsByNode(_ hits: [TopoSearchHit]) -> [String: Int] {
        hits.reduce(into: [:]) { counts, hit in counts[hit.nodeID, default: 0] += 1 }
    }

    /// Résultat suivant (`delta` 1) ou précédent (−1), en boucle ; 0 sans résultat.
    public static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Rang affiché, ramené dans la liste : « 2 sur 5 ».
    public static func position(_ index: Int, count: Int) -> String {
        guard count > 0 else { return "0 sur 0" }
        return "\(min(max(index, 0), count - 1) + 1) sur \(count)"
    }

    /// Chemin d'Internet jusqu'au nœud (compris), pour montrer la branche.
    public static func path(to nodeID: String, in graph: TopoGraph) -> [String] {
        var path: [String] = []
        var seen: Set<String> = []
        var current: String? = nodeID
        while let id = current, seen.insert(id).inserted, let node = graph.node(id) {
            path.append(id)
            current = node.parentID
        }
        return path.reversed()
    }

    /// Où est l'appareil, en mots : « Imprimantes ×2 · SW-ETG2-01 » pour un groupe, « SW-ETG2-01 »
    /// (l'équipement au-dessus) pour un nœud seul, « Wi-Fi · Borne Wi-Fi accueil » pour un client sans fil.
    public static func location(of hit: TopoSearchHit, in graph: TopoGraph) -> String {
        guard let node = graph.node(hit.nodeID) else { return "" }
        let parent = node.parentID.flatMap(graph.node)
        var parts: [String] = []
        if node.kind == .groupe { parts.append(node.title) }
        if let parent, parent.kind != .internet {
            if node.isWireless && node.kind != .groupe { parts.append("Wi-Fi") }
            parts.append(parent.title)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Autres sites

    /// Sites (autres que celui dessiné) où la recherche trouve des appareils, dans l'ordre donné.
    public static func otherSites(_ query: SearchQuery, sites: [TopoSiteDevices], excluding drawnKey: String) -> [TopoSiteMatch] {
        guard !query.isEmpty else { return [] }
        return sites.compactMap { site in
            guard site.key != drawnKey else { return nil }
            let count = items(site.devices, graph: nil).filter(query.matches).count
            return count > 0 ? TopoSiteMatch(key: site.key, name: site.name, count: count) : nil
        }
    }

    // MARK: Détails

    /// Ordre de lecture de la carte : un parent avant ses enfants ; sous un nœud, les branches
    /// (switchs relevés, déduits, bornes) puis les feuilles, comme la disposition de `TopoGraph.layout`.
    static func mapOrder(_ graph: TopoGraph) -> [String] {
        func rank(_ node: TopoNode) -> Int {
            switch node.kind {
            case .switch: return node.isInferred ? 1 : 0
            case .pointAcces: return 2
            default: return 3
            }
        }
        var childrenOf: [String: [TopoNode]] = [:]
        for node in graph.nodes { if let parent = node.parentID { childrenOf[parent, default: []].append(node) } }
        var order: [String] = []
        var visited: Set<String> = []
        func walk(_ id: String) {
            guard visited.insert(id).inserted else { return }
            order.append(id)
            let kids = (childrenOf[id] ?? []).enumerated().sorted { a, b in
                rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
            }.map(\.element)
            let branches = kids.filter { !(childrenOf[$0.id] ?? []).isEmpty }
            let leaves = kids.filter { (childrenOf[$0.id] ?? []).isEmpty }
            for child in branches + leaves { walk(child.id) }
        }
        walk(graph.rootID)
        // Nœuds sans parent connu (ne devrait pas arriver) : à la fin, dans l'ordre du graphe.
        for node in graph.nodes where !visited.contains(node.id) { order.append(node.id) }
        return order
    }

    /// Vrai si un critère positif désigne cet appareil tout entier : IP complète, nom ou MAC.
    static func isExact(_ query: SearchQuery, _ device: Device) -> Bool {
        let names = [device.displayName, device.hostname, device.customName].compactMap { $0 }.map(SearchText.fold)
        let macHex = device.mac.map { SearchText.hexDigits($0.formatted(.colon)) }
        for term in query.terms where term.isComplete && !term.isNegated {
            let key = term.field?.key
            guard key == nil || key == "ip" || key == "nom" || key == "mac" else { continue }
            let needle = term.folded.trimmingCharacters(in: .whitespaces)
            if key == nil || key == "ip", let address = IPv4Address(needle), address == device.ip { return true }
            if key == nil || key == "nom", names.contains(needle) { return true }
            if key == nil || key == "mac", let macHex, macHex.count == 12, SearchText.hexDigits(needle) == macHex,
               needle.count >= 12 { return true }
        }
        return false
    }
}
