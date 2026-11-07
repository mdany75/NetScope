import Foundation

/// Un appareil, tel qu'un écran le connaît (ligne du Scanner, fiche d'inventaire, membre d'un groupe).
public struct NavDeviceRef: Hashable, Sendable {
    public var ip: String
    public var mac: String?
    public var name: String
    /// Site de l'appareil (clé `SiteFiles.key`) ; nil : le site actif.
    public var siteKey: String?
    public var switchName: String?
    public var switchPort: String?

    public init(ip: String, mac: String? = nil, name: String = "", siteKey: String? = nil,
                switchName: String? = nil, switchPort: String? = nil) {
        self.ip = ip
        self.mac = mac.flatMap(MACAddress.init).map { $0.formatted(.upperColon) } ?? mac?.uppercased()
        self.name = name.isEmpty ? ip : name
        self.siteKey = siteKey
        self.switchName = switchName
        self.switchPort = switchPort
    }

    public init(_ device: Device, siteKey: String? = nil) {
        self.init(ip: device.ip.description, mac: device.mac?.formatted(.upperColon), name: device.displayName,
                  siteKey: siteKey, switchName: device.switchName, switchPort: device.switchPort)
    }

    public init(_ record: InvRecord, siteKey: String?) {
        self.init(ip: record.ip.description, mac: record.mac?.formatted(.upperColon), name: record.displayName,
                  siteKey: siteKey, switchName: record.switchName, switchPort: record.switchPort)
    }

    public var member: NavMember { NavMember(ip: ip, mac: mac) }
}

/// Un port de switch (façade, tableau des ports SNMP ou FortiSwitch).
public struct NavPortRef: Hashable, Sendable {
    /// Adresse de gestion du switch (`SNMPSwitchSnapshot.id`).
    public var host: String
    public var ifIndex: Int

    public init(host: String, ifIndex: Int) {
        self.host = host
        self.ifIndex = ifIndex
    }
}

/// Groupe ou branche de la Carte : ses appareils et le site dessiné.
public struct NavGroupRef: Hashable, Sendable {
    /// « Téléphones ×11 », « SW-ETG2-01 ».
    public var title: String
    /// Équipement au-dessus (« SW-ETG2-01 ») ; nil pour une branche entière.
    public var parentTitle: String?
    /// Adresse de l'équipement au-dessus, s'il a été vu par le scan (pour ouvrir ses ports).
    public var parentHost: String?
    public var members: [NavDeviceRef]
    public var siteKey: String

    public init(title: String, parentTitle: String? = nil, parentHost: String? = nil, members: [NavDeviceRef], siteKey: String) {
        self.title = title
        self.parentTitle = parentTitle
        self.parentHost = parentHost
        self.members = members
        self.siteKey = siteKey
    }

    /// Étiquette du filtre transmis : « Carte : Téléphones ×11 · SW-ETG2-01 ».
    public var filterLabel: String {
        "Carte\u{00A0}: " + title + (parentTitle.map { " · " + $0 } ?? "")
    }
}

/// Sonde de surveillance : sa cible, telle que saisie.
public struct NavProbeRef: Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: MonProbeKind
    public var target: String

    public init(id: String, name: String, kind: MonProbeKind, target: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.target = target
    }

    public init(_ probe: MonProbe) {
        self.init(id: probe.id.uuidString, name: probe.name, kind: probe.kind, target: probe.target)
    }

    /// Adresse ou nom d'hôte visé (« 10.0.0.1:443 » → « 10.0.0.1 », « https://nas.local/x » → « nas.local ») ;
    /// nil pour une sonde qui ne vise pas un hôte (nouveaux appareils, service, borne, ce Mac).
    public var host: String? {
        let text = target.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .ping, .snmp, .dns, .cpu, .memory, .portLoad:
            guard !text.isEmpty, text.lowercased() != "ce mac" else { return nil }
            return text
        case .tcp:
            if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 {
                return String(text[..<colon])
            }
            return text.isEmpty ? nil : text
        case .http:
            let withScheme = text.contains("://") ? text : "http://" + text
            return URLComponents(string: withScheme)?.host
        case .switchPort, .newDevices, .onlineService, .fortiAPOffline, .fortiAPOverload, .dhcpScope, .vpnTunnel, .wanLink,
             .linkSaturated, .heavyDevice, .newThreat, .licenseExpiring, .firmwareOutdated, .rogueDHCP, .ipConflict, .rogueAP:
            return nil
        case .syslogSeverity, .trapReceived:
            return MonTrafficChecks.isAll(text) ? nil : text
        case .tlsCertificate:
            return MonTLSChecks.target(text)?.host
        case .printerSupply, .upsStatus:
            return text
        case .rustdeskServer, .wireguardServer:
            return (try? RustDeskServerAccount.parse(text))?.host
        }
    }
}

/// Objet sur lequel on double-clique (ou qu'on ouvre par « Ouvrir dans › »).
public enum NavObject: Hashable, Sendable {
    case device(NavDeviceRef)
    /// Switch (carte de Switchs et ports, nœud switch de la Carte) : adresse et nom.
    case switchUnit(host: String?, name: String)
    case port(NavPortRef)
    /// Borne FortiAP : identifiant `FortiManagedAP.id`, nom, adresse IP et MAC si connues.
    case accessPoint(id: String, name: String, ip: String?)
    /// Client Wi-Fi vu par une FortiGate.
    case wifiClient(mac: String?, ip: String?, name: String, apID: String?)
    case group(NavGroupRef)
    /// Plage du Scanner : son texte (« 10.182.122.0/24 ») et son nom (« Bureau »).
    case range(text: String, label: String?)
    case vlan(Int)
    case site(key: String, name: String)
    case probe(NavProbeRef)
    /// Alerte du journal de la surveillance : sa sonde.
    case alert(probeID: String?)
    /// Alerte ou changement de l'Analyse : la fiche d'inventaire concernée.
    case analysisEvent(siteKey: String, recordKey: String, ip: String?)
    case service(id: String, name: String)
    case toolResult(tool: String)
    case backup(name: String)
    case remoteConnection(id: String, host: String)
}
