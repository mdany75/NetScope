import Foundation

/// Double-clic sur un port de switch (note 33) : l'appareil branché, une petite liste quand il y
/// en a plusieurs (téléphone et poste, petit switch, borne), ou un message clair (port vide,
/// uplink / trunk / ISL, appareil pas encore vu).
public enum NavPortResolver {

    /// Ce que le relevé dit du port.
    public enum Kind: Equatable, Sendable {
        /// Aucun lien sur le port.
        case empty
        /// Lien actif, mais aucune MAC apprise au dernier relevé.
        case silent
        /// Lien vers un autre équipement réseau (voisin LLDP, FortiLink, ISL, ou beaucoup de MAC).
        case uplink(neighbor: String?)
        /// Des MAC apprises : appareils du Scanner, de l'inventaire, ou pas encore vus.
        case devices(known: [NavDeviceRef], unknownMACs: [String])
    }

    /// Analyse le port d'après le relevé du switch, les appareils du Scanner et l'inventaire du site actif.
    public static func kind(_ ref: NavPortRef, in context: NavContext) -> Kind? {
        guard let snapshot = context.switches[ref.host] else { return nil }
        let entries = snapshot.entries(on: ref.ifIndex)
        let neighbor = snapshot.neighbor(on: ref.ifIndex)
        if snapshot.locatedUplinks.contains(ref.ifIndex) || isInfrastructure(neighbor) {
            return .uplink(neighbor: neighbor.map(\.sysName).flatMap { $0.isEmpty ? nil : $0 })
        }
        if entries.isEmpty {
            return snapshot.interface(ref.ifIndex)?.isUp == true ? .silent : .empty
        }
        var known: [NavDeviceRef] = []
        var unknown: [String] = []
        var seen: Set<String> = []
        for entry in entries {
            let mac = entry.mac.formatted(.upperColon)
            guard seen.insert(mac).inserted else { continue }
            if let device = context.scannerDevice(mac: mac) {
                known.append(device)
            } else if let ip = snapshot.arp[entry.mac], let device = context.scanner[ip.description], device.mac == nil {
                known.append(device)
            } else if let record = context.record(NavDeviceRef(ip: "", mac: mac), site: context.activeSiteKey) {
                known.append(NavDeviceRef(record, siteKey: context.activeSiteKey))
            } else {
                unknown.append(mac)
            }
        }
        return .devices(known: known, unknownMACs: unknown)
    }

    /// Voisin LLDP qui n'est pas un simple poste : switch, routeur, pont, FortiLink, ISL.
    static func isInfrastructure(_ neighbor: SNMPLLDPNeighbor?) -> Bool {
        guard let neighbor else { return false }
        if neighbor.portID == "FortiLink" { return true }
        guard let capabilities = neighbor.capabilities else { return false }
        // Téléphone IP « Bridge, Telephone » (note 30) : un appareil, pas un switch.
        return capabilities.contains(.router) || (capabilities.contains(.bridge) && !capabilities.contains(.telephone))
    }

    /// Filtre « Port : SW-ETG2-01 · 1/14 » : les appareils connus derrière ce port (nil s'il n'y en a pas).
    public static func filter(_ ref: NavPortRef, in context: NavContext) -> NavFilter? {
        guard let snapshot = context.switches[ref.host],
              case .devices(let known, _)? = kind(ref, in: context), !known.isEmpty else { return nil }
        let port = snapshot.interface(ref.ifIndex)?.name ?? "\(ref.ifIndex)"
        return NavFilter(origin: .port, label: "Port\u{00A0}: \(snapshot.displayName) · \(port)",
                         members: known.map(\.member), siteKey: context.activeSiteKey)
    }

    public static func resolve(_ ref: NavPortRef, in context: NavContext) -> NavOutcome {
        guard let snapshot = context.switches[ref.host], let kind = kind(ref, in: context) else {
            return .message(title: "Relevé du switch absent",
                            text: "Le switch \(ref.host) n’a pas encore été interrogé\u{00A0}: ses ports ne sont pas connus.",
                            suggestion: nil)
        }
        let port = snapshot.interface(ref.ifIndex)?.name ?? "\(ref.ifIndex)"
        let where_ = "\(snapshot.displayName) · \(port)"
        switch kind {
        case .empty:
            return .message(title: "Port vide",
                            text: "Aucun lien sur \(where_)\u{00A0}: rien n’est branché, ou l’appareil est éteint.",
                            suggestion: nil)
        case .silent:
            return .message(title: "Aucun appareil appris",
                            text: "\(where_) est actif, mais aucune adresse MAC n’y a été apprise au dernier relevé. Interrogez de nouveau le switch dans un moment.",
                            suggestion: nil)
        case .uplink(let neighbor):
            let target = neighbor.flatMap { context.switchSnapshot(named: $0) }
            let text = neighbor.map { "\(where_) relie ce switch à «\u{00A0}\($0)\u{00A0}» (uplink, trunk ou ISL)\u{00A0}: les adresses apprises ici viennent d’autres équipements, pas d’un appareil branché." }
                ?? "\(where_) est un uplink ou un trunk\u{00A0}: les nombreuses adresses apprises ici viennent d’autres équipements, pas d’un appareil branché."
            return .message(title: "Uplink / trunk", text: text,
                            suggestion: target.map { NavOption(id: "voisin", title: "Ouvrir «\u{00A0}\($0.displayName)\u{00A0}»",
                                                               detail: "Switchs et ports",
                                                               destination: NavDestination(.switchs, focus: .switchPort(host: $0.id, port: nil))) })
        case .devices(let known, let unknown):
            if known.isEmpty {
                let list = unknown.prefix(3).joined(separator: ", ") + (unknown.count > 3 ? "…" : "")
                return .message(title: "Appareil pas encore vu",
                                text: "\(unknown.count > 1 ? "Les adresses" : "L’adresse") \(list) \(unknown.count > 1 ? "apprises" : "apprise") sur \(where_) \(unknown.count > 1 ? "ne sont" : "n’est") ni dans le dernier scan ni dans l’inventaire. Lancez un scan de sa plage pour ouvrir sa fiche.",
                                suggestion: NavOption(id: "scanner", title: "Ouvrir le Scanner", detail: "Lancer un scan",
                                                      destination: NavDestination(.scanner)))
            }
            if known.count == 1, unknown.isEmpty, case .go(let destination) = NavResolver.device(known[0], in: context) {
                return .go(destination)
            }
            var options = known.map { device -> NavOption in
                let destination = NavResolver.device(device, in: context).destination
                let detail = [device.ip, device.mac].compactMap { $0 }.joined(separator: " · ")
                    + (destination?.module == .inventaire ? " · inventaire" : "")
                return NavOption(id: device.mac ?? device.ip, title: device.name, detail: detail, destination: destination)
            }
            options += unknown.map { NavOption(id: $0, title: "Pas encore vu", detail: $0, destination: nil) }
            let all = filter(ref, in: context).map { filter in
                NavOption(id: "inventaire", title: "Voir les \(known.count) dans l’Inventaire",
                          detail: filter.label, destination: NavDestination(.inventaire, filter: filter, search: ""))
            }
            return .choose(title: "Plusieurs appareils sur \(where_)",
                           message: "\(known.count + unknown.count) adresses apprises sur ce port. Choisissez l’appareil à ouvrir.",
                           options: options, all: all)
        }
    }
}
