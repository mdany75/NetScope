import Foundation

// Appareils dessinés par la Carte du réseau. Le Scanner garde les résultats d'un scan à l'autre
// (pour marquer les « nouveaux ») ; la carte, elle, montre par défaut le dernier scan seulement :
// sinon un scan d'un autre site laisse les appareils et les switchs du précédent sur la carte.

public enum TopoScope {
    /// Appareils du dernier scan : vus depuis son début, dans une de ses plages. Sans scan connu
    /// (`since` nil, démonstration, résultats importés), tous les appareils sont gardés.
    public static func lastScan(_ devices: [Device], since: Date?, ranges: [IPRange]) -> [Device] {
        guard let since else { return devices }
        return devices.filter { device in
            device.lastSeen >= since && (ranges.isEmpty || ranges.contains { $0.contains(device.ip) })
        }
    }
}
