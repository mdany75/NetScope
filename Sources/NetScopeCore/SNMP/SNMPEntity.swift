import Foundation

// Note 60 : fiche matériel lue par SNMP. ENTITY-MIB (entPhysicalTable) donne le modèle, le numéro
// de série et la version du logiciel du châssis ; sysDescr complète ce qui manque. La lecture ne se
// fait qu'avec un relevé déjà demandé (switchs, Ressources) ou le bouton « Lire la fiche matériel » :
// jamais de balayage. L'analyse des réponses (rows, principal, combine) n'accède pas au réseau.

public enum SNMPEntityOIDs {
    /// entPhysicalEntry (ENTITY-MIB) ; colonne puis entPhysicalIndex.
    public static let entry: SNMPOID = "1.3.6.1.2.1.47.1.1.1.1"
    public static let descr: UInt32 = 2
    public static let physicalClass: UInt32 = 5
    public static let firmwareRev: UInt32 = 9
    public static let softwareRev: UInt32 = 10
    public static let serialNum: UInt32 = 11
    public static let mfgName: UInt32 = 12
    public static let modelName: UInt32 = 13

    /// Colonnes lues pour une entité choisie (la classe est lue à part).
    public static let detailColumns: [UInt32] = [descr, firmwareRev, softwareRev, serialNum, mfgName, modelName]

    public static func column(_ column: UInt32) -> SNMPOID { entry.appending(column) }
    public static func cell(_ column: UInt32, index: Int) -> SNMPOID { entry.appending(column, UInt32(clamping: index)) }
}

/// Une ligne de entPhysicalTable.
public struct SNMPEntityRow: Hashable, Sendable {
    public var index: Int
    /// entPhysicalClass : 3 châssis, 9 module, 11 pile (stack)…
    public var physicalClass: Int?
    public var descr: String?
    public var firmwareRev: String?
    public var softwareRev: String?
    public var serial: String?
    public var mfgName: String?
    public var modelName: String?

    public init(index: Int, physicalClass: Int? = nil, descr: String? = nil, firmwareRev: String? = nil, softwareRev: String? = nil,
                serial: String? = nil, mfgName: String? = nil, modelName: String? = nil) {
        self.index = index
        self.physicalClass = physicalClass
        self.descr = descr
        self.firmwareRev = firmwareRev
        self.softwareRev = softwareRev
        self.serial = serial
        self.mfgName = mfgName
        self.modelName = modelName
    }

    /// Porte un modèle ou un numéro de série (une entité vide ne sert à rien).
    public var isUseful: Bool { serial != nil || modelName != nil }

    public static let chassis = 3
    public static let module = 9
}

public enum SNMPEntity {
    /// Lignes lues dans des varbinds de entPhysicalTable (GET ou parcours), triées par index.
    /// Les valeurs vides ou de remplissage (« N/A », « Unknown », « 0 ») sont écartées.
    public static func rows(_ binds: [SNMPVarBind]) -> [SNMPEntityRow] {
        var rows: [Int: SNMPEntityRow] = [:]
        for bind in binds where !bind.value.isException {
            guard let suffix = bind.oid.suffix(after: SNMPEntityOIDs.entry), suffix.count == 2 else { continue }
            let column = suffix[0]
            let index = Int(suffix[1])
            var row = rows[index] ?? SNMPEntityRow(index: index)
            switch column {
            case SNMPEntityOIDs.physicalClass: row.physicalClass = bind.value.intValue.map { Int($0) }
            case SNMPEntityOIDs.descr: row.descr = value(bind.value)
            case SNMPEntityOIDs.firmwareRev: row.firmwareRev = value(bind.value)
            case SNMPEntityOIDs.softwareRev: row.softwareRev = value(bind.value)
            case SNMPEntityOIDs.serialNum: row.serial = value(bind.value, serial: true)
            case SNMPEntityOIDs.mfgName: row.mfgName = value(bind.value)
            case SNMPEntityOIDs.modelName: row.modelName = value(bind.value)
            default: continue
            }
            rows[index] = row
        }
        return rows.values.sorted { $0.index < $1.index }
    }

    /// Entité qui décrit l'appareil : le premier châssis (classe 3) qui porte un modèle ou un numéro
    /// de série, sinon le premier module (classe 9), sinon la première entité utile.
    public static func principal(_ rows: [SNMPEntityRow]) -> SNMPEntityRow? {
        let sorted = rows.sorted { $0.index < $1.index }
        if let chassis = sorted.first(where: { $0.physicalClass == SNMPEntityRow.chassis && $0.isUseful }) { return chassis }
        if let module = sorted.first(where: { $0.physicalClass == SNMPEntityRow.module && $0.isUseful }) { return module }
        return sorted.first(where: \.isUseful)
    }

    /// Index à détailler d'après la colonne entPhysicalClass : premier châssis et premier module.
    public static func candidateIndexes(classes binds: [SNMPVarBind]) -> [Int] {
        var chassis: Int?
        var module: Int?
        var first: Int?
        for bind in binds {
            guard let suffix = bind.oid.suffix(after: SNMPEntityOIDs.column(SNMPEntityOIDs.physicalClass)), suffix.count == 1,
                  let cls = bind.value.intValue else { continue }
            let index = Int(suffix[0])
            if first == nil { first = index }
            if cls == Int64(SNMPEntityRow.chassis), chassis == nil { chassis = index }
            if cls == Int64(SNMPEntityRow.module), module == nil { module = index }
        }
        var result: [Int] = []
        for index in [chassis, module, first].compactMap({ $0 }) where !result.contains(index) { result.append(index) }
        return Array(result.prefix(2))
    }

    /// Texte rogné ; nil pour une valeur vide ou de remplissage.
    static func value(_ value: SNMPValue, serial: Bool = false) -> String? {
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let placeholders: Set<String> = ["n/a", "na", "none", "unknown", "not available", "not specified", "-", "--", "null", "default string"]
        if placeholders.contains(lower) { return nil }
        if serial, text.allSatisfy({ $0 == "0" || $0 == " " }) { return nil }
        return text
    }
}

/// Fiche matériel lue par SNMP (ENTITY-MIB, complétée par sysDescr).
public struct SNMPHardwareInfo: Codable, Hashable, Sendable {
    public var model: String?
    public var serial: String?
    public var firmware: String?
    public var vendor: String?
    /// « ENTITY-MIB », « sysDescr » ou « ENTITY-MIB et sysDescr ».
    public var origin: String

    public init(model: String? = nil, serial: String? = nil, firmware: String? = nil, vendor: String? = nil, origin: String) {
        self.model = model
        self.serial = serial
        self.firmware = firmware
        self.vendor = vendor
        self.origin = origin
    }

    public var isEmpty: Bool { model == nil && serial == nil && firmware == nil }

    /// Réunit l'entité principale et sysDescr : ENTITY-MIB d'abord, sysDescr pour ce qui manque.
    /// nil si ni l'un ni l'autre ne donne de modèle, de numéro de série ni de version.
    public static func combine(descr: String, objectID: String? = nil, entity: SNMPEntityRow?) -> SNMPHardwareInfo? {
        let parsed = SNMPSysDescr.parse(descr, objectID: objectID)
        var fromEntity = false
        var fromDescr = false
        func pick(_ entityValue: String?, _ descrValue: String?) -> String? {
            if let entityValue { fromEntity = true; return entityValue }
            if let descrValue { fromDescr = true; return descrValue }
            return nil
        }
        // Un entPhysicalDescr court sert de modèle s'il n'y a ni modelName ni modèle dans sysDescr.
        let shortDescr = entity?.descr.flatMap { $0.count <= 48 && !$0.contains("\n") ? $0 : nil }
        let model = pick(entity?.modelName, parsed.model ?? (entity?.serial != nil ? shortDescr : nil))
        let serial = pick(entity?.serial, parsed.serial)
        let firmware = pick(entity?.softwareRev ?? entity?.firmwareRev, parsed.version)
        let vendor = entity?.mfgName ?? parsed.vendor
        guard model != nil || serial != nil || firmware != nil else { return nil }
        let origin = fromEntity && fromDescr ? "ENTITY-MIB et sysDescr" : (fromEntity ? "ENTITY-MIB" : "sysDescr")
        return SNMPHardwareInfo(model: model, serial: serial, firmware: firmware, vendor: vendor, origin: origin)
    }
}

/// Lecture de la fiche matériel d'un agent, en v2c comme en v3 : parcours de la colonne
/// entPhysicalClass (les vrais index de l'agent, sans rien deviner), puis GET des colonnes utiles du
/// châssis et du premier module.
public enum SNMPHardwareReader {
    /// Entité principale ; nil si l'agent n'a pas ENTITY-MIB. Annulation propagée, toute autre
    /// erreur donne nil (table facultative).
    public static func entity(client: SNMPClient) async throws -> SNMPEntityRow? {
        try await entity { pdu in try await client.request(pdu, checkStatus: false) }
    }

    /// Même lecture avec une requête fournie (client UDP, agent en mémoire des tests).
    public static func entity(fetch: (SNMPPDU) async throws -> SNMPPDU) async throws -> SNMPEntityRow? {
        do {
            let classes = try await SNMPWalker.walk(SNMPEntityOIDs.column(SNMPEntityOIDs.physicalClass),
                                                    mode: .bulk(maxRepetitions: 20), limit: 600, fetch: fetch).binds
            let indexes = SNMPEntity.candidateIndexes(classes: classes)
            guard !indexes.isEmpty else { return nil }
            let oids = indexes.flatMap { index in SNMPEntityOIDs.detailColumns.map { SNMPEntityOIDs.cell($0, index: index) } }
            let response = try await fetch(SNMPPDU(type: .getRequest, requestID: SNMPClient.newRequestID(),
                                                   varbinds: oids.map { SNMPVarBind(oid: $0) }))
            guard response.errorStatus == 0 else { return nil }
            return SNMPEntity.principal(SNMPEntity.rows(classes + response.varbinds))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Fiche complète ; `system` déjà lu (relevé d'un switch) évite une requête.
    public static func read(client: SNMPClient, system: SNMPSystemInfo? = nil) async throws -> SNMPHardwareInfo? {
        let info: SNMPSystemInfo
        if let system {
            info = system
        } else {
            info = try await SNMPSwitchPoller(client: client).system()
        }
        let entity = try await entity(client: client)
        return SNMPHardwareInfo.combine(descr: info.descr, objectID: info.objectID, entity: entity)
    }

    /// Fiche complète par SNMP v3 seulement (même parcours qu'en v2c).
    public static func read(v3 client: SNMPv3Client) async throws -> SNMPHardwareInfo? {
        try client.credentials.validate()
        return try await read(client: client.client)
    }
}
