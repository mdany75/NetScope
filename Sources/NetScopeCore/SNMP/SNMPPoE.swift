import Foundation

// PoE par port, relevé par SNMP sur le switch : POWER-ETHERNET-MIB (RFC 3621), complété au besoin
// par les watts des MIB propriétaires (CISCO-POWER-ETHERNET-EXT-MIB, HP-ICF-POE-MIB).
// L'analyse est séparée du relevé : elle se teste sur des réponses fixes, sans réseau.

extension SNMPOIDs {
    // POWER-ETHERNET-MIB, pethPsePortTable (index : groupe.port)
    public static let pethPsePortAdminEnable: SNMPOID = "1.3.6.1.2.1.105.1.1.1.3"
    public static let pethPsePortPowerPriority: SNMPOID = "1.3.6.1.2.1.105.1.1.1.7"
    public static let pethPsePortPowerClassifications: SNMPOID = "1.3.6.1.2.1.105.1.1.1.10"
    // POWER-ETHERNET-MIB, pethMainPseTable (index : groupe)
    public static let pethMainPseOperStatus: SNMPOID = "1.3.6.1.2.1.105.1.3.1.1.3"
    // CISCO-POWER-ETHERNET-EXT-MIB, cpeExtPsePortTable (même index que pethPsePortTable), en mW
    public static let cpeExtPsePortPwrAllocated: SNMPOID = "1.3.6.1.4.1.9.9.402.1.2.1.7"
    public static let cpeExtPsePortPwrConsumption: SNMPOID = "1.3.6.1.4.1.9.9.402.1.2.1.9"
    // HP-ICF-POE-MIB, hpicfPoePethPsePortTable (même index), en mW
    public static let hpicfPoePethPsePortPower: SNMPOID = "1.3.6.1.4.1.11.2.14.11.1.9.1.1.1.3"
}

/// État de détection d'un port PSE (pethPsePortDetectionStatus).
public enum PoEDetectionStatus: Int, Codable, Hashable, Sendable {
    case disabled = 1, searching, deliveringPower, fault, test, otherFault

    public var label: String {
        switch self {
        case .disabled: return "PoE désactivé"
        case .searching: return "Aucune charge PoE"
        case .deliveringPower: return "Délivre du courant"
        case .fault: return "Défaut PoE"
        case .test: return "En test"
        case .otherFault: return "Défaut PoE (autre)"
        }
    }

    public var isFault: Bool { self == .fault || self == .otherFault }
}

/// PoE d'un port du switch, d'après SNMP.
public struct SNMPPoEPort: Codable, Hashable, Sendable {
    public var group: Int
    public var port: Int
    /// Interface correspondante (ifIndex), si elle a été trouvée.
    public var ifIndex: Int?
    /// pethPsePortAdminEnable : PoE autorisé sur le port.
    public var adminEnabled: Bool?
    public var detection: PoEDetectionStatus?
    /// Classe 0 à 4 (pethPsePortPowerClassifications).
    public var powerClass: Int?
    public var priority: PoEPowerInfo.Priority?
    /// Consommation réelle (Cisco, HPE), en mW.
    public var consumptionMW: Int?
    /// Puissance allouée (Cisco), en mW.
    public var allocatedMW: Int?
    /// MIB qui a donné les watts (« Cisco », « HPE »).
    public var wattsSource: String?

    public init(group: Int, port: Int, ifIndex: Int? = nil, adminEnabled: Bool? = nil, detection: PoEDetectionStatus? = nil,
                powerClass: Int? = nil, priority: PoEPowerInfo.Priority? = nil, consumptionMW: Int? = nil,
                allocatedMW: Int? = nil, wattsSource: String? = nil) {
        self.group = group
        self.port = port
        self.ifIndex = ifIndex
        self.adminEnabled = adminEnabled
        self.detection = detection
        self.powerClass = powerClass
        self.priority = priority
        self.consumptionMW = consumptionMW
        self.allocatedMW = allocatedMW
        self.wattsSource = wattsSource
    }

    /// Le port sait fournir du PoE (il figure dans pethPsePortTable).
    public var isPoEPort: Bool { true }
    /// PoE activé par l'administrateur (sauf indication contraire).
    public var isEnabled: Bool { adminEnabled != false && detection != .disabled }
    /// Le port fournit du courant en ce moment.
    public var isDelivering: Bool { detection == .deliveringPower }

    public var consumptionW: Double? { consumptionMW.map { Double($0) / 1000 } }
    public var allocatedW: Double? { allocatedMW.map { Double($0) / 1000 } }

    /// « Délivre du courant », « Aucune charge PoE », « PoE désactivé »…
    public var stateLabel: String {
        if adminEnabled == false { return "PoE désactivé" }
        return detection?.label ?? "PoE (état inconnu)"
    }

    /// « Classe 4 · 18,4 W » ; « Aucune charge PoE » ; « PoE désactivé ».
    public var summary: String {
        guard isDelivering else { return stateLabel }
        var parts: [String] = []
        if let powerClass { parts.append("Classe \(powerClass)") }
        if let consumptionW { parts.append(PoEPowerInfo.watts(consumptionW)) }
        else if let allocatedW { parts.append("\(PoEPowerInfo.watts(allocatedW)) alloués") }
        return parts.isEmpty ? stateLabel : parts.joined(separator: " · ")
    }

    /// Texte court pour une colonne : « Oui · 18,4 W », « Oui », « Non (port PoE) », « PoE désactivé ».
    public var shortLabel: String {
        if isDelivering { return consumptionW.map { "Oui · \(PoEPowerInfo.watts($0))" } ?? "Oui" }
        if adminEnabled == false || detection == .disabled { return "PoE désactivé" }
        if detection?.isFault == true { return "Défaut PoE" }
        return "Non (port PoE)"
    }
}

/// Bloc d'alimentation principal (pethMainPseTable).
public struct SNMPPoEMain: Codable, Hashable, Sendable {
    public var group: Int
    public var budgetW: Int?
    public var usedW: Int?
    /// pethMainPseOperStatus : 1 on, 2 off, 3 faulty.
    public var operStatus: Int?

    public init(group: Int, budgetW: Int? = nil, usedW: Int? = nil, operStatus: Int? = nil) {
        self.group = group
        self.budgetW = budgetW
        self.usedW = usedW
        self.operStatus = operStatus
    }
}

/// Analyse des colonnes PoE lues par SNMP.
public enum SNMPPoEParser {
    /// Colonnes brutes (réponses d'un walk) : chacune est facultative.
    public struct Columns: Sendable {
        public var adminEnable: [SNMPVarBind] = []
        public var detection: [SNMPVarBind] = []
        public var classification: [SNMPVarBind] = []
        public var priority: [SNMPVarBind] = []
        public var ciscoConsumption: [SNMPVarBind] = []
        public var ciscoAllocated: [SNMPVarBind] = []
        public var hpePower: [SNMPVarBind] = []
        public var mainPower: [SNMPVarBind] = []
        public var mainConsumption: [SNMPVarBind] = []
        public var mainOperStatus: [SNMPVarBind] = []

        public init() {}
    }

    struct Key: Hashable { var group: Int; var port: Int }

    /// Ports PoE, rattachés aux interfaces (ifIndex), triés par groupe puis port.
    public static func ports(_ columns: Columns, interfaces: [SNMPInterface]) -> [SNMPPoEPort] {
        var rows: [Key: SNMPPoEPort] = [:]
        func visit(_ binds: [SNMPVarBind], under root: SNMPOID, _ apply: (inout SNMPPoEPort, Int64) -> Void) {
            for bind in binds {
                guard let suffix = bind.oid.suffix(after: root), suffix.count == 2, let value = bind.value.intValue else { continue }
                let key = Key(group: Int(suffix[0]), port: Int(suffix[1]))
                var row = rows[key] ?? SNMPPoEPort(group: key.group, port: key.port)
                apply(&row, value)
                rows[key] = row
            }
        }
        visit(columns.adminEnable, under: SNMPOIDs.pethPsePortAdminEnable) { row, v in row.adminEnabled = v == 1 ? true : (v == 2 ? false : nil) }
        visit(columns.detection, under: SNMPOIDs.pethPsePortDetectionStatus) { row, v in row.detection = PoEDetectionStatus(rawValue: Int(v)) }
        visit(columns.classification, under: SNMPOIDs.pethPsePortPowerClassifications) { row, v in
            if (1...5).contains(v) { row.powerClass = Int(v) - 1 }
        }
        visit(columns.priority, under: SNMPOIDs.pethPsePortPowerPriority) { row, v in
            switch v {
            case 1: row.priority = .critical
            case 2: row.priority = .high
            case 3: row.priority = .low
            default: break
            }
        }
        // Watts : Cisco d'abord, sinon HPE. Les lignes inconnues de la MIB standard sont ignorées.
        func watts(_ binds: [SNMPVarBind], under root: SNMPOID, source: String, _ apply: (inout SNMPPoEPort, Int) -> Void) {
            for bind in binds {
                guard let suffix = bind.oid.suffix(after: root), suffix.count == 2, let value = bind.value.intValue, value >= 0 else { continue }
                let key = Key(group: Int(suffix[0]), port: Int(suffix[1]))
                guard var row = rows[key] else { continue }
                apply(&row, Int(value))
                row.wattsSource = row.wattsSource ?? source
                rows[key] = row
            }
        }
        watts(columns.ciscoConsumption, under: SNMPOIDs.cpeExtPsePortPwrConsumption, source: "Cisco") { $0.consumptionMW = $1 }
        watts(columns.ciscoAllocated, under: SNMPOIDs.cpeExtPsePortPwrAllocated, source: "Cisco") { $0.allocatedMW = $1 }
        watts(columns.hpePower, under: SNMPOIDs.hpicfPoePethPsePortPower, source: "HPE") { row, mw in
            if row.consumptionMW == nil { row.consumptionMW = mw }
        }
        // Un port qui ne délivre rien ne consomme rien, quoi qu'en dise la MIB propriétaire.
        let physical = interfaces.filter { $0.isPhysical && !$0.isModular }.sorted { $0.index < $1.index }
        return rows.values.map { row in
            var port = row
            if !port.isDelivering, port.consumptionMW != nil { port.consumptionMW = 0 }
            port.ifIndex = ifIndex(group: row.group, port: row.port, physical: physical)
            return port
        }
        .sorted { ($0.group, $0.port) < ($1.group, $1.port) }
    }

    /// Bloc d'alimentation principal (le premier groupe qui répond).
    public static func main(_ columns: Columns) -> SNMPPoEMain? {
        var groups: [Int: SNMPPoEMain] = [:]
        func visit(_ binds: [SNMPVarBind], under root: SNMPOID, _ apply: (inout SNMPPoEMain, Int) -> Void) {
            for bind in binds {
                guard let suffix = bind.oid.suffix(after: root), suffix.count == 1, let value = bind.value.intValue else { continue }
                let group = Int(suffix[0])
                var row = groups[group] ?? SNMPPoEMain(group: group)
                apply(&row, Int(value))
                groups[group] = row
            }
        }
        visit(columns.mainPower, under: SNMPOIDs.pethMainPsePower) { $0.budgetW = $1 }
        visit(columns.mainConsumption, under: SNMPOIDs.pethMainPseConsumptionPower) { $0.usedW = $1 }
        visit(columns.mainOperStatus, under: SNMPOIDs.pethMainPseOperStatus) { $0.operStatus = $1 }
        return groups.keys.min().flatMap { groups[$0] }
    }

    /// Port PSE (groupe, port) → ifIndex : nom « g/0/p » ou « g/p » d'abord, sinon le p-ième port
    /// physique du groupe 1 (pethPsePortIndex suit l'ordre des ports en façade sur la plupart des switchs).
    public static func ifIndex(group: Int, port: Int, physical: [SNMPInterface]) -> Int? {
        let byName = physical.first { iface in
            let parts = iface.name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return parts.count >= 2 && parts.first == group && parts.last == port
        }
        if let byName { return byName.index }
        if group == 1, port >= 1, port <= physical.count { return physical[port - 1].index }
        return nil
    }
}

extension SNMPSwitchSnapshot {
    /// PoE du port (ifIndex), d'après le relevé détaillé ; à défaut, d'après la liste des ports qui
    /// délivrent du courant (anciens relevés).
    public func poePort(_ ifIndex: Int) -> SNMPPoEPort? {
        if let detail = poeDetails?.first(where: { $0.ifIndex == ifIndex }) { return detail }
        guard poeDetails == nil, poePorts.contains(ifIndex) else { return nil }
        return SNMPPoEPort(group: 1, port: ifIndex, ifIndex: ifIndex, adminEnabled: true, detection: .deliveringPower)
    }

    /// Vrai si le switch a répondu à POWER-ETHERNET-MIB (au moins un port PSE).
    public var hasPoE: Bool { !(poeDetails ?? []).isEmpty || !poePorts.isEmpty || (poeBudgetW ?? 0) > 0 }

    /// Interface d'après son nom tel qu'il est noté sur un appareil (« Gi1/0/12 », « 1/14 »,
    /// « GigabitEthernet1/0/12 ») : ifName, ifDescr, puis l'abréviation Cisco.
    public func interface(named name: String) -> SNMPInterface? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let match = interfaces.first(where: { $0.name.lowercased() == wanted || $0.descr.lowercased() == wanted }) { return match }
        return interfaces.first { SNMPPoELookup.abbreviated($0.descr) == SNMPPoELookup.abbreviated(wanted) && !wanted.isEmpty }
    }
}

/// Réponse « Est-il sur un port PoE ? » pour un appareil localisé (switch, port).
public struct DevicePoEStatus: Hashable, Sendable {
    public var switchName: String
    public var portName: String
    /// nil : le switch n'a pas été relevé, ou il ne répond pas à POWER-ETHERNET-MIB.
    public var port: SNMPPoEPort?
    /// Le switch a été relevé et répond à POWER-ETHERNET-MIB.
    public var switchHasPoE: Bool
    /// Des ports PSE du switch n'ont pas pu être rattachés à une interface : un port absent de la
    /// liste n'est donc pas forcément sans PoE.
    public var hasUnmatchedPorts: Bool

    public init(switchName: String, portName: String, port: SNMPPoEPort?, switchHasPoE: Bool, hasUnmatchedPorts: Bool = false) {
        self.switchName = switchName
        self.portName = portName
        self.port = port
        self.switchHasPoE = switchHasPoE && !hasUnmatchedPorts
        self.hasUnmatchedPorts = hasUnmatchedPorts
    }

    /// Port PoE ? (nil : impossible à dire.)
    public var isPoEPort: Bool? {
        if port != nil { return true }
        return switchHasPoE ? false : nil
    }

    /// Alimenté par PoE en ce moment ?
    public var isPowered: Bool? {
        if let port { return port.isDelivering }
        return switchHasPoE ? false : nil
    }

    /// Texte de colonne : « Oui · 18,4 W », « Non (port PoE) », « Non (sans PoE) », « Inconnu ».
    public var shortLabel: String {
        if let port { return port.shortLabel }
        return switchHasPoE ? "Non (sans PoE)" : "Inconnu"
    }

    /// Phrase de la fiche : « Alimenté par PoE · classe 4 · 18,4 W (Cisco) ».
    public var detailLabel: String {
        guard let port else {
            if hasUnmatchedPorts { return "Inconnu · ports PoE de \(switchName) non rattachés aux interfaces" }
            return switchHasPoE ? "Non · le port \(portName) ne fournit pas de PoE"
                : "Inconnu · \(switchName) ne répond pas à POWER-ETHERNET-MIB"
        }
        guard port.isDelivering else {
            if port.adminEnabled == false || port.detection == .disabled { return "Non · PoE désactivé sur ce port" }
            if port.detection?.isFault == true { return "Non · défaut PoE sur ce port" }
            return "Non · port PoE, aucune charge détectée"
        }
        var parts = ["Alimenté par PoE"]
        if let powerClass = port.powerClass { parts.append("classe \(powerClass)") }
        if let watts = port.consumptionW { parts.append(PoEPowerInfo.watts(watts) + (port.wattsSource.map { " (\($0))" } ?? "")) }
        else if let watts = port.allocatedW { parts.append("\(PoEPowerInfo.watts(watts)) alloués") }
        return parts.joined(separator: " · ")
    }
}

public enum SNMPPoELookup {
    /// « GigabitEthernet1/0/12 » → « gi1/0/12 » ; « TenGigabitEthernet1/1/2 » → « te1/1/2 ».
    static func abbreviated(_ name: String) -> String {
        let lower = name.lowercased()
        let prefixes: [(String, String)] = [("tengigabitethernet", "te"), ("twentyfivegige", "twe"), ("fortygigabitethernet", "fo"),
                                            ("gigabitethernet", "gi"), ("fastethernet", "fa"), ("ethernet", "eth")]
        for (long, short) in prefixes where lower.hasPrefix(long) { return short + lower.dropFirst(long.count) }
        return lower
    }

    /// PoE du port où l'appareil est localisé ; nil si l'emplacement est inconnu, Wi-Fi ou que le
    /// switch n'a pas été relevé.
    public static func status(switchName: String?, portName: String?, in snapshots: [SNMPSwitchSnapshot]) -> DevicePoEStatus? {
        guard let switchName, let portName, portName != "Wi-Fi" else { return nil }
        func key(_ value: String) -> String { value.lowercased().split(separator: ".").first.map(String.init) ?? value.lowercased() }
        guard let snapshot = snapshots.first(where: { key($0.displayName) == key(switchName) }),
              let iface = snapshot.interface(named: portName), iface.isPhysical else { return nil }
        return DevicePoEStatus(switchName: snapshot.displayName, portName: iface.name, port: snapshot.poePort(iface.index),
                               switchHasPoE: snapshot.poeDetails?.isEmpty == false,
                               hasUnmatchedPorts: snapshot.poeDetails?.contains { $0.ifIndex == nil } == true)
    }
}
