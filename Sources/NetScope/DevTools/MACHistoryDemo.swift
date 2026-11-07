import Foundation
import NetScopeCore

/// Note 99 : historique de démonstration (`--demo`) des adresses MAC du site Siège, sur cinq mois,
/// passé par la même fusion que les vrais relevés (aucun réseau). L'imprimante de l'accueil a
/// changé d'IP et de port en août ; le portable de Marc passe du filaire au Wi-Fi.
/// Captures : NETSCOPE_OUTIL_DEMO=historiqueMAC (recherche NETSCOPE_MAC_RECHERCHE, défaut
/// « Imprimante accueil ») ; NETSCOPE_DEVICE=10.182.122.111 montre la chronologie de la fiche.
enum MACHistoryDemo {
    static let defaultQuery = "Imprimante accueil"

    static func history(now: Date = Date()) -> MACHistory {
        var history = MACHistory()
        func at(_ daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }
        func obs(_ mac: String, _ kind: MACSightingKind, _ value: String, _ source: MACSightingSource) -> MACObservation? {
            MACAddress(mac).map { MACObservation(mac: $0, kind: kind, value: value, source: source) }
        }
        let brother = "94:DD:F8:18:15:7D", hp = "00:1A:2B:44:10:EE", marc = "8C:16:45:2B:9E:03"
        let mac = "3C:22:FB:7E:05:B1", ups = "00:C0:B7:5E:21:A0", accueil = "80:5E:C0:3A:61:21"
        // Relevés tous les 7 jours sur 150 jours.
        for daysAgo in stride(from: 150.0, through: 0, by: -7) {
            let before = daysAgo > 88
            var list: [MACObservation?] = [
                obs(brother, .ip, before ? "10.182.122.108" : "10.182.122.111", .scan),
                obs(brother, .name, "Imprimante accueil", .scan),
                obs(brother, .switchPort, before ? "SW-ETG2-01 · 1/12" : "SW-ETG2-01 · 1/14", .switchTable),
                obs(brother, .vlan, before ? "1" : "30", .switchTable),
                obs(hp, .ip, "10.182.122.140", .scan),
                obs(hp, .name, "NPI7A4410", .scan),
                obs(hp, .switchPort, "SW-ETG2-01 · 1/18", .switchTable),
                obs(hp, .vlan, "30", .switchTable),
                obs(marc, .name, "Portable Marc", .scan),
                obs(accueil, .ip, "10.182.122.121", .scan),
                obs(accueil, .switchPort, "SW-ETG2-01 · 1/10", .switchTable),
                obs(accueil, .vlan, "20", .switchTable),
                obs(mac, .ip, "10.182.122.135", .fortigate),
                obs(mac, .accessPoint, daysAgo > 40 ? "FAP-ETG2-NORD (Bureau)" : "FortiAP-231F (Bureau)", .wifi),
            ]
            // Portable de Marc : filaire jusqu'en juillet, puis Wi-Fi (deux bornes).
            if daysAgo > 100 {
                list += [obs(marc, .ip, "10.182.122.113", .scan), obs(marc, .switchPort, "SW-ETG2-01 · 1/3", .switchTable),
                         obs(marc, .vlan, "1", .switchTable)]
            } else {
                list += [obs(marc, .ip, "10.182.122.131", .fortigate), obs(marc, .vlan, "20", .fortigate),
                         obs(marc, .accessPoint, Int(daysAgo) % 14 == 0 ? "FortiAP-231F (Bureau)" : "FAP-ETG2-NORD (Bureau)", .wifi)]
            }
            // Onduleur posé en septembre.
            if daysAgo < 60 {
                list += [obs(ups, .ip, "10.182.122.160", .scan), obs(ups, .name, "Onduleur baie réseau", .scan),
                         obs(ups, .switchPort, "SW-CORE-01 · Gi1/0/46", .switchTable)]
            }
            history.record(list.compactMap { $0 }, at: at(daysAgo))
        }
        return history
    }
}
