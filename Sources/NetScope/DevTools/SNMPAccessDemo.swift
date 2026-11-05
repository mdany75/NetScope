import Foundation
import NetScopeCore

/// Démonstration (--demo) : utilisateurs SNMP v3 fictifs, jamais envoyés (aucun réseau en démo).
/// Le Siège et l'Entrepôt Laval ont leur propre utilisateur ; les autres sites prennent celui de
/// tous les sites.
@MainActor
enum SNMPAccessDemo {
    static let global = SNMPv3Credentials(user: "ipscan-ro", level: .authPriv, auth: .sha256, authPassword: "demo-auth-0000",
                                          priv: .aes128, privPassword: "demo-priv-0000")

    static let perSite: [UUID: SNMPv3Credentials] = [
        SitesDemo.siegeID: SNMPv3Credentials(user: "netscope-siege", level: .authPriv, auth: .sha256, authPassword: "demo-auth-0001",
                                             priv: .aes256, privPassword: "demo-priv-0001"),
        SitesDemo.lavalID: SNMPv3Credentials(user: "lecture-laval", level: .authNoPriv, auth: .sha1, authPassword: "demo-auth-0002"),
    ]
}
