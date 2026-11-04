import Foundation

// Note 37 : calcul de l'occupation des étendues DHCP (fonctions pures, testées sans réseau).
//
// - adresses distribuables : union des plages, moins les exclusions, moins la passerelle si une
//   plage la contient ;
// - adresses utilisées : réservations dont l'adresse est dans la plage (bail ou non, l'adresse est
//   gardée) plus baux dynamiques actifs dans la plage, chaque adresse comptée une fois ;
// - réservations hors plage et baux hors plage : montrés, jamais comptés ;
// - niveau : critique au-delà du seuil critique (ou plus aucune adresse libre), avertissement
//   au-delà du seuil d'avertissement ;
// - sans FortiGate : estimation par le Test DHCP (sous-réseau offert) et le scan (appareils vus en
//   ligne), clairement marquée.

public enum DHCPScopeAnalysis {
    /// Étendues d'une lecture de FortiGate.
    public static func usages(site: String, report: DHCPScopeReadReport, thresholds: DHCPScopeThresholds = .standard,
                              now: Date = Date()) -> [DHCPScopeUsage] {
        let servers = report.servers
        // Rattachement des baux : par serveur (« server_mkey »), sinon par interface, sinon par adresse.
        var byServer: [Int: [DHCPLeaseEntry]] = [:]
        let ids = Set(servers.map(\.id))
        let interfaceOwners = Dictionary(grouping: servers, by: { $0.interface.lowercased() })
        let pools = Dictionary(servers.map { ($0.id, pool(of: $0)) }, uniquingKeysWith: { first, _ in first })
        for lease in report.leases where lease.isActive(at: now) {
            if let id = lease.serverID, ids.contains(id) {
                byServer[id, default: []].append(lease)
                continue
            }
            if let name = lease.interface?.lowercased(), let owners = interfaceOwners[name] {
                // Plusieurs serveurs sur la même interface : celui dont la plage contient l'adresse.
                let owner = owners.first { pools[$0.id]?.contains(lease.ip) == true } ?? owners[0]
                byServer[owner.id, default: []].append(lease)
                continue
            }
            if let owner = servers.first(where: { pools[$0.id]?.contains(lease.ip) == true }) {
                byServer[owner.id, default: []].append(lease)
            }
        }
        return servers.map { server in
            let info = report.interfaces[server.interface]
            return usage(server, site: site, leases: byServer[server.id] ?? [], vlan: info?.vlan ?? FortiParse.vlanID(fromName: server.interface),
                         alias: info?.alias, leasesKnown: report.leasesRead, thresholds: thresholds, now: now)
        }
        .sorted { ($0.vlan ?? 0, $0.interface) < ($1.vlan ?? 0, $1.interface) }
    }

    /// Adresses distribuables d'un serveur.
    public static func pool(of server: DHCPServerConfig) -> DHCPAddressPool {
        var pool = DHCPAddressPool(server.ranges)
        for exclusion in server.exclusions { pool.subtract(exclusion) }
        // La passerelle n'est jamais distribuée, même si une plage la contient.
        if let gateway = server.gateway { pool.subtract(DHCPAddressRange(start: gateway, end: gateway)) }
        return pool
    }

    /// Occupation d'une étendue.
    public static func usage(_ server: DHCPServerConfig, site: String, leases: [DHCPLeaseEntry], vlan: Int?, alias: String?,
                             leasesKnown: Bool = true, thresholds: DHCPScopeThresholds = .standard, now: Date = Date()) -> DHCPScopeUsage {
        let pool = pool(of: server)
        let soon = now.addingTimeInterval(TimeInterval(thresholds.expiringMinutes * 60))
        var entries: [DHCPScopeEntry] = []
        var usedIPs = Set<UInt32>()
        var reservedIPs = Set<UInt32>()
        var reservationsOutside = 0
        var outsideReserved = Set<UInt32>()
        let reservations = server.reservations.filter(\.holdsAddress)
        let active = leases.filter { $0.isActive(at: now) }
        // Bail actif de chaque adresse (le premier lu).
        var leaseByIP: [UInt32: DHCPLeaseEntry] = [:]
        for lease in active where leaseByIP[lease.ip.value] == nil { leaseByIP[lease.ip.value] = lease }

        var reservationsInUse = 0
        for reservation in reservations {
            guard pool.contains(reservation.ip) else {
                // Réservation hors plage recopiée : montrée et comptée une seule fois.
                guard outsideReserved.insert(reservation.ip.value).inserted else { continue }
                reservationsOutside += 1
                entries.append(DHCPScopeEntry(ip: reservation.ip, mac: reservation.mac, hostname: reservation.description, kind: .reservationOutside))
                continue
            }
            guard reservedIPs.insert(reservation.ip.value).inserted else { continue }
            usedIPs.insert(reservation.ip.value)
            if let lease = leaseByIP[reservation.ip.value] {
                reservationsInUse += 1
                entries.append(DHCPScopeEntry(ip: reservation.ip, mac: lease.mac ?? reservation.mac,
                                              hostname: lease.hostname ?? reservation.description, kind: .reservationInUse,
                                              expires: lease.expires))
            } else {
                entries.append(DHCPScopeEntry(ip: reservation.ip, mac: reservation.mac, hostname: reservation.description, kind: .reservationIdle))
            }
        }

        var dynamic = 0
        var outside = 0
        var expiring = 0
        var seen = Set<UInt32>()
        for lease in active {
            guard seen.insert(lease.ip.value).inserted else { continue }
            if reservedIPs.contains(lease.ip.value) { continue }
            guard pool.contains(lease.ip) else {
                outside += 1
                entries.append(DHCPScopeEntry(ip: lease.ip, mac: lease.mac, hostname: lease.hostname, kind: .outsideLease, expires: lease.expires))
                continue
            }
            usedIPs.insert(lease.ip.value)
            if lease.reserved {
                // Bail marqué réservé par la FortiGate sans réservation dans la configuration lue.
                reservationsInUse += 1
                entries.append(DHCPScopeEntry(ip: lease.ip, mac: lease.mac, hostname: lease.hostname, kind: .reservationInUse, expires: lease.expires))
                continue
            }
            dynamic += 1
            let isSoon = lease.expires.map { $0 <= soon } ?? false
            if isSoon { expiring += 1 }
            entries.append(DHCPScopeEntry(ip: lease.ip, mac: lease.mac, hostname: lease.hostname, kind: .lease, expires: lease.expires,
                                          expiringSoon: isSoon))
        }
        entries.sort { $0.ip < $1.ip }

        let subnet = subnetOf(server)
        var notes: [String] = []
        if !leasesKnown { notes.append("Baux non lus\u{00A0}: seules les réservations sont comptées, l’occupation réelle est plus haute.") }
        if outside > 0 { notes.append("\(outside) bail\(outside > 1 ? "s" : "") actif\(outside > 1 ? "s" : "") hors de la plage actuelle (plage réduite depuis, ou adresse distribuée avant un changement)\u{00A0}: non compté\(outside > 1 ? "s" : "").") }
        if server.ranges.isEmpty { notes.append("Aucune plage d’adresses lue pour ce serveur.") }
        var usage = DHCPScopeUsage(id: "\(site)|\(server.id)|\(server.interface)", site: site, serverID: server.id, interface: server.interface,
                                   alias: alias, vlan: vlan, subnet: subnet, ranges: server.ranges, exclusions: server.exclusions,
                                   gateway: server.gateway, leaseTime: server.leaseTime, enabled: server.enabled, poolSize: pool.count,
                                   activeLeases: dynamic, reservationsInPool: reservedIPs.count, reservationsOutside: reservationsOutside,
                                   reservationsInUse: reservationsInUse, outsideLeases: outside, used: usedIPs.count,
                                   expiringSoon: expiring, isEstimate: false, leasesUnknown: !leasesKnown, level: .ok,
                                   entries: entries, notes: notes)
        usage.level = level(usage, thresholds: thresholds)
        return usage
    }

    /// Sous-réseau de l'étendue : passerelle (ou première plage) et masque.
    static func subnetOf(_ server: DHCPServerConfig) -> Subnet? {
        guard let mask = server.netmask, let prefix = mask.prefixLength, prefix > 0 else { return nil }
        guard let base = server.gateway ?? server.ranges.first?.start else { return nil }
        return Subnet(address: base, prefix: prefix)
    }

    /// Niveau d'une étendue d'après les seuils.
    public static func level(_ usage: DHCPScopeUsage, thresholds: DHCPScopeThresholds) -> DHCPScopeLevel {
        guard usage.enabled, usage.poolSize > 0 else { return .inactive }
        if usage.free == 0 || usage.percent >= thresholds.criticalPercent { return .critical }
        if usage.percent >= thresholds.warningPercent { return .warning }
        return .ok
    }

    /// Niveaux recalculés avec d'autres seuils (sonde aux seuils propres).
    public static func relevel(_ scopes: [DHCPScopeUsage], thresholds: DHCPScopeThresholds) -> [DHCPScopeUsage] {
        scopes.map { scope in
            var copy = scope
            copy.level = level(scope, thresholds: thresholds)
            return copy
        }
    }

    /// Ensemble de plusieurs sites.
    public static func overview(_ sites: [DHCPScopeSiteReport], thresholds: DHCPScopeThresholds = .standard,
                                now: Date = Date()) -> DHCPScopeOverview {
        let scopes = sites.flatMap { usages(site: $0.site, report: $0.report, thresholds: thresholds, now: now) }
        let multi = sites.count > 1
        let notes = sites.flatMap { site in site.report.notes.map { multi ? "\(site.site)\u{00A0}: \($0)" : $0 } }
        return DHCPScopeOverview(scopes: scopes, sites: sites.map(\.site), readAt: sites.map(\.report.readAt).min(),
                                 isEstimate: false, notes: notes)
    }

    // MARK: Phrases

    /// Alerte en clair : « Étendue VLAN 20 pleine à 96 % : 4 adresses libres ; des postes risquent
    /// de tomber en 169.254 ». nil pour une étendue sous les seuils.
    public static func alertText(_ usage: DHCPScopeUsage) -> String? {
        let name = usage.alertName
        let free = usage.free
        let freeText = free == 0 ? "plus aucune adresse libre" : "\(free) adresse\(free > 1 ? "s" : "") libre\(free > 1 ? "s" : "")"
        let estimate = usage.isEstimate ? " (estimation)" : ""
        switch usage.level {
        case .critical:
            if free == 0 {
                return "Étendue \(name) pleine\(estimate)\u{00A0}: \(freeText)\u{00A0}; les nouveaux postes tombent en 169.254"
            }
            return "Étendue \(name) pleine à \(usage.percentLabel)\(estimate)\u{00A0}: \(freeText)\u{00A0}; des postes risquent de tomber en 169.254"
        case .warning:
            return "Étendue \(name) occupée à \(usage.percentLabel)\(estimate)\u{00A0}: \(freeText) sur \(usage.poolSize)"
        case .ok, .inactive:
            return nil
        }
    }

    /// Conseil pour une étendue au-delà d'un seuil.
    public static func advice(_ usage: DHCPScopeUsage) -> String {
        guard usage.level >= .warning else {
            if usage.level == .inactive { return usage.enabled ? "Plage vide\u{00A0}: aucune adresse à distribuer." : "Serveur DHCP désactivé sur la FortiGate." }
            return "Assez d’adresses libres."
        }
        var parts: [String] = []
        if let lease = usage.leaseTime, lease > 4 * 3600 {
            parts.append("si des appareils de passage gardent leur adresse, raccourcir le bail (\(leaseText(lease)) aujourd’hui)")
        }
        if !usage.exclusions.isEmpty { parts.append("revoir les exclusions (\(usage.exclusions.count))") }
        parts.append("agrandir la plage (ip-range) si le sous-réseau le permet")
        if let subnet = usage.subnet, subnet.prefix >= 24 { parts.append("ou passer le VLAN en /\(subnet.prefix - 1)") }
        if usage.reservationsInPool > 0, usage.reservationsInUse < usage.reservationsInPool {
            let idle = usage.reservationsInPool - usage.reservationsInUse
            parts.append("supprimer les réservations inutilisées (\(idle))")
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    /// « 7 j », « 8 h », « 30 min », « illimité ».
    public static func leaseText(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds == 0 { return "illimité" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)\u{00A0}j" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)\u{00A0}h" }
        if seconds >= 60 { return "\(seconds / 60)\u{00A0}min" }
        return "\(seconds)\u{00A0}s"
    }

    // MARK: Estimation sans FortiGate

    /// Estimation à partir des offres du Test DHCP (serveur, adresse offerte, masque) et des
    /// appareils du scan : la plage est supposée couvrir tout le sous-réseau offert (sans la
    /// passerelle ni le serveur), les adresses utilisées sont les appareils vus en ligne. Les
    /// appareils à adresse fixe sont comptés aussi : le taux est indicatif.
    public static func estimate(offers: [DHCPOffer], devices: [Device], site: String = "",
                                thresholds: DHCPScopeThresholds = .standard, now: Date = Date()) -> [DHCPScopeUsage] {
        var seen = Set<Subnet>()
        var result: [DHCPScopeUsage] = []
        for offer in offers {
            guard let subnet = offer.subnet, subnet.prefix <= 30, seen.insert(subnet).inserted else { continue }
            var pool = DHCPAddressPool([DHCPAddressRange(start: subnet.firstHost, end: subnet.lastHost)])
            var reserved: [IPv4Address] = offer.routers.filter(subnet.contains)
            if let server = offer.server, subnet.contains(server) { reserved.append(server) }
            for ip in reserved { pool.subtract(DHCPAddressRange(start: ip, end: ip)) }
            var entries: [DHCPScopeEntry] = []
            var used = Set<UInt32>()
            for device in devices where device.isOnline && pool.contains(device.ip) {
                guard used.insert(device.ip.value).inserted else { continue }
                entries.append(DHCPScopeEntry(ip: device.ip, mac: device.mac, hostname: device.hostnameLabel ?? device.displayName, kind: .seenOnline))
            }
            entries.sort { $0.ip < $1.ip }
            let server = offer.server?.description ?? "?"
            var usage = DHCPScopeUsage(
                id: "estimation|\(subnet)", site: site, serverID: nil, interface: "Serveur \(server)", alias: nil, vlan: nil,
                subnet: subnet, ranges: [DHCPAddressRange(start: subnet.firstHost, end: subnet.lastHost)], exclusions: [],
                gateway: offer.routers.first, leaseTime: offer.leaseTime.map { Int($0) }, enabled: true, poolSize: pool.count,
                activeLeases: used.count, reservationsInPool: 0, reservationsOutside: 0, reservationsInUse: 0, outsideLeases: 0,
                used: used.count, expiringSoon: 0, isEstimate: true, leasesUnknown: true, level: .ok, entries: entries,
                notes: ["Estimation sans FortiGate\u{00A0}: plage supposée = tout le sous-réseau \(subnet) offert par \(server)\u{00A0}; adresses utilisées = appareils vus en ligne par le scan (adresses fixes comprises). La vraie plage est souvent plus petite\u{00A0}: l’occupation réelle peut être plus haute."])
            usage.level = level(usage, thresholds: thresholds)
            result.append(usage)
        }
        return result
    }

    /// Ensemble estimé (sans FortiGate).
    public static func estimatedOverview(offers: [DHCPOffer], devices: [Device], site: String = "",
                                         thresholds: DHCPScopeThresholds = .standard, now: Date = Date()) -> DHCPScopeOverview {
        let scopes = estimate(offers: offers, devices: devices, site: site, thresholds: thresholds, now: now)
        return DHCPScopeOverview(scopes: scopes, sites: site.isEmpty ? [] : [site], readAt: scopes.isEmpty ? nil : now, isEstimate: true)
    }
}
