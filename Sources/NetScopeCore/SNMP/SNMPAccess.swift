import Foundation

// Note 59 : quel identifiant SNMP v3 utiliser pour un agent. Chaque site peut avoir son propre
// utilisateur v3 (Réglages › Identifiants) ; à défaut, l'utilisateur « Tous les sites » sert. Les
// secrets restent au Trousseau : l'application lit les identifiants et donne ici une simple table.

/// Identifiant v3 d'un agent donné (nil : pas de v3, la communauté seule sert).
public typealias SNMPv3Lookup = @Sendable (IPv4Address) -> SNMPv3Credentials?

public enum SNMPv3SiteResolver {
    /// Site qui fournit l'identifiant v3 de `host`, ou nil (identifiant « Tous les sites »).
    /// Ordre : le site qui déclare ce switch (le site actif d'abord), puis le site actif s'il contient
    /// l'adresse, puis le seul autre site qui la contient. Deux sites qui ont la même plage (cas
    /// courant chez des clients différents) ne choisissent jamais au hasard : l'identifiant commun sert.
    public static func site(for host: IPv4Address, sites: [Site], activeID: UUID?, configured: Set<UUID>) -> UUID? {
        let candidates = sites.filter { configured.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        let text = host.description
        let declaring = candidates.filter { $0.switchHosts.contains(text) }
        if let active = declaring.first(where: { $0.id == activeID }) { return active.id }
        if declaring.count == 1 { return declaring[0].id }
        if let active = candidates.first(where: { $0.id == activeID }), active.contains(host) { return active.id }
        let containing = candidates.filter { $0.contains(host) }
        return containing.count == 1 ? containing[0].id : nil
    }

    /// Identifiant v3 de `host` : celui de son site, sinon `fallback`.
    public static func credentials(for host: IPv4Address, sites: [Site], activeID: UUID?,
                                   perSite: [UUID: SNMPv3Credentials], fallback: SNMPv3Credentials?) -> SNMPv3Credentials? {
        if let id = site(for: host, sites: sites, activeID: activeID, configured: Set(perSite.keys)), let found = perSite[id] {
            return found
        }
        return fallback
    }

    /// Table figée (utilisable hors du fil principal) pour les sondes, la découverte et les relevés.
    public static func lookup(sites: [Site], activeID: UUID?, perSite: [UUID: SNMPv3Credentials],
                              fallback: SNMPv3Credentials?) -> SNMPv3Lookup {
        { host in credentials(for: host, sites: sites, activeID: activeID, perSite: perSite, fallback: fallback) }
    }
}
