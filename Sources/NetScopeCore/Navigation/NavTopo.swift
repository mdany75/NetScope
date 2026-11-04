import Foundation

// Carte du réseau → autres modules (note 31) : un groupe (« Téléphones ×11 ») ou une branche
// (un switch et tout ce qui est branché dessous) devient un ensemble exact d'appareils.

public extension TopoGraph {
    /// Appareils d'une branche : ceux du nœud et de tous les nœuds en dessous (sans doublon, dans
    /// l'ordre de la carte).
    func branchDeviceIDs(_ id: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var visited: Set<String> = []
        func walk(_ nodeID: String) {
            guard visited.insert(nodeID).inserted, let node = node(nodeID) else { return }
            for device in node.deviceIDs where seen.insert(device).inserted { result.append(device) }
            for child in children(of: nodeID) { walk(child.id) }
        }
        walk(id)
        return result
    }

    /// Nœud qui montre un appareil : le sien (« dev:… », passerelle) ou le groupe qui le contient.
    func nodeID(showing deviceID: String) -> String? {
        if node("dev:" + deviceID) != nil { return "dev:" + deviceID }
        return nodes.first { $0.deviceIDs.contains(deviceID) }?.id
    }

    /// Groupe ou branche d'un nœud, prêt à transmettre : un groupe garde son titre et l'équipement
    /// au-dessus (« Téléphones ×11 · SW-ETG2-01 ») ; un switch, une borne ou la passerelle donnent
    /// leur branche (« Branche SW-ETG2-01 ×6 »). nil : aucun appareil (Internet, nœud vide).
    func navGroup(_ id: String, devices: [Device], siteKey: String) -> NavGroupRef? {
        guard let node = node(id), node.kind != .internet else { return nil }
        let index = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = node.kind == .groupe ? node.deviceIDs : branchDeviceIDs(id)
        let members = ids.compactMap { index[$0] }.map { NavDeviceRef($0, siteKey: siteKey) }
        guard !members.isEmpty else { return nil }
        if node.kind == .groupe {
            let parent = node.parentID.flatMap { self.node($0) }
            let parentHost = parent?.id.hasPrefix("dev:") == true ? parent?.deviceIDs.first : nil
            return NavGroupRef(title: node.title, parentTitle: parent?.title, parentHost: parentHost,
                               members: members, siteKey: siteKey)
        }
        return NavGroupRef(title: "Branche \(node.title) ×\(members.count)", members: members, siteKey: siteKey)
    }
}
