import Foundation
import NetScopeCore

/// Note 6 : données de démonstration de RustDesk (valeurs fictives : serveur, clé, ID et usagers
/// inventés). Aucun réseau : le test du serveur et la lecture des VIP renvoient ces résultats.
enum RustDeskDemo {
    /// Clé publique fictive (32 octets en base64, 44 caractères, sans « / »).
    static let publicKey = "TmV0U2NvcGUgZGVtbyA6IGNsZSBmaWN0aXZlIDIwMjY="

    static let settings = RustDeskServerSettings(idServer: "assistance.exemple.ca", publicKey: publicKey,
                                                 supportPageURL: "https://assistance.exemple.ca/rustdesk",
                                                 internalAddress: "192.168.10.20")

    /// Client de bureau de ce Mac : même serveur, même clé.
    static let clientConfig = RustDeskClientConfig(rendezvousServer: "assistance.exemple.ca", key: publicKey)

    /// Postes du carnet (ajoutés aux connexions de la démonstration).
    static func connections(now: Date) -> [RemoteConnection] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        return [
            RemoteConnection(name: "WKS-ACCUEIL-02", proto: .rustdesk, host: "184352907", folder: "Siège › Postes", isFavorite: true,
                             note: "Dell OptiPlex 7010 · Windows 11 Pro", lastConnected: ago(0.4), endUser: "Julie Gagnon (réception)"),
            RemoteConnection(name: "PORT-COMPTA-07", proto: .rustdesk, host: "263418095", folder: "Siège › Postes",
                             note: "Lenovo ThinkPad T14 · Windows 11 Pro · client portable", lastConnected: ago(26), endUser: "Marc Tremblay (comptabilité)"),
            RemoteConnection(name: "LAVAL-POSTE-11", proto: .rustdesk, host: "1027554318", folder: "Laval › Postes",
                             note: "HP EliteDesk 800 · Windows 10 Pro", lastConnected: ago(75), endUser: "Sophie Roy"),
            RemoteConnection(name: "SALLE-CONF-TV", proto: .rustdesk, host: "10.182.122.160", folder: "Siège › Postes",
                             note: "Mini PC de la salle de conférence · accès IP direct", lastConnected: ago(190), endUser: "Salle Saint-Laurent"),
        ]
    }

    /// ID RustDesk saisis dans l'inventaire (mêmes postes que le carnet).
    static func seed(_ store: inout InventoryStore, now: Date) {
        for (ip, id) in [("10.182.122.146", "184352907"), ("10.182.122.117", "263418095")] {
            guard let record = store.records.values.first(where: { $0.ip.description == ip && $0.hostname != "MacBook-Air-Accueil" }) else { continue }
            var annotations = record.annotations
            annotations.rustdeskID = id
            store.setAnnotations(annotations, for: record.key, at: now.addingTimeInterval(-40 * 86_400), recordEvent: false)
        }
    }

    /// Mot de passe permanent « au Trousseau » (démonstration : rien n'est lu ni écrit).
    static func hasSavedPassword(_ connection: RemoteConnection) -> Bool {
        connection.name == "WKS-ACCUEIL-02" || connection.name == "SALLE-CONF-TV"
    }

    /// Lancements récents, dont un ID collé sans l'enregistrer.
    static func history(connections: [RemoteConnection], now: Date = Date()) -> [RustDeskLaunch] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        func launch(_ name: String, _ hours: Double) -> RustDeskLaunch? {
            guard let c = connections.first(where: { $0.name == name }) else { return nil }
            return RustDeskLaunch(date: ago(hours), connectionID: c.id, name: c.name, target: c.host, endUser: c.endUser, site: c.folder)
        }
        let items: [RustDeskLaunch?] = [
            launch("WKS-ACCUEIL-02", 0.4),
            RustDeskLaunch(date: ago(3.2), name: "ID collé", target: "731905246"),
            launch("PORT-COMPTA-07", 26),
            launch("WKS-ACCUEIL-02", 49),
            launch("LAVAL-POSTE-11", 75),
            launch("SALLE-CONF-TV", 190),
        ]
        return items.compactMap { $0 }
    }

    /// Résultat du test du serveur : tout passe sauf l'UDP (VIP mappé sur l'IP publique).
    static func probes(_ settings: RustDeskServerSettings) -> [RustDeskProbe] {
        RustDeskServerTest.plan(settings).map { kind, endpoint in
            switch kind {
            case .natTest: return RustDeskProbe(kind: kind, endpoint: endpoint, ok: true, millis: 21, protocolAnswer: true, observedPort: 53_122)
            case .idServer: return RustDeskProbe(kind: kind, endpoint: endpoint, ok: true, millis: 23)
            case .udp: return RustDeskProbe(kind: kind, endpoint: endpoint, ok: false)
            case .relay: return RustDeskProbe(kind: kind, endpoint: endpoint, ok: true, millis: 24)
            }
        }
    }

    /// VIP de la FortiGate du siège : celui de l'UDP pointe sur l'IP publique (piège courant).
    static let vips: [RustDeskVIP] = [
        RustDeskVIP(name: "RustDesk-TCP-21115", externalIP: "203.0.113.45", mappedIP: "192.168.10.20", portForward: true,
                    proto: "tcp", externalPorts: 21115...21115, mappedPorts: 21115...21115),
        RustDeskVIP(name: "RustDesk-TCP-21116", externalIP: "203.0.113.45", mappedIP: "192.168.10.20", portForward: true,
                    proto: "tcp", externalPorts: 21116...21116, mappedPorts: 21116...21116),
        RustDeskVIP(name: "RustDesk-UDP-21116", externalIP: "203.0.113.45", mappedIP: "203.0.113.45", portForward: true,
                    proto: "udp", externalPorts: 21116...21116, mappedPorts: 21116...21116),
        RustDeskVIP(name: "RustDesk-TCP-21117", externalIP: "203.0.113.45", mappedIP: "192.168.10.20", portForward: true,
                    proto: "tcp", externalPorts: 21117...21117, mappedPorts: 21117...21117),
    ]
}
