import Foundation

// Ressources d'un appareil du réseau par SNMP v2c, en lecture seule : processeur et mémoire
// (HOST-RESOURCES-MIB, puis MIB Cisco, Fortinet et HPE courantes) et compteurs de trafic par
// port (IF-MIB : ifHCInOctets/ifHCOutOctets 64 bits, sinon ifInOctets/ifOutOctets 32 bits).

public enum SNMPResourceOIDs {
    // HOST-RESOURCES-MIB (RFC 2790)
    public static let hrProcessorLoad: SNMPOID = "1.3.6.1.2.1.25.3.3.1.2"
    public static let hrStorageType: SNMPOID = "1.3.6.1.2.1.25.2.3.1.2"
    public static let hrStorageDescr: SNMPOID = "1.3.6.1.2.1.25.2.3.1.3"
    public static let hrStorageAllocationUnits: SNMPOID = "1.3.6.1.2.1.25.2.3.1.4"
    public static let hrStorageSize: SNMPOID = "1.3.6.1.2.1.25.2.3.1.5"
    public static let hrStorageUsed: SNMPOID = "1.3.6.1.2.1.25.2.3.1.6"
    /// hrStorageRam (type d'un stockage).
    public static let hrStorageRam: SNMPOID = "1.3.6.1.2.1.25.2.1.2"

    // CISCO-PROCESS-MIB et CISCO-MEMORY-POOL-MIB
    public static let cpmCPUTotal1minRev: SNMPOID = "1.3.6.1.4.1.9.9.109.1.1.1.1.7"
    public static let ciscoMemoryPoolName: SNMPOID = "1.3.6.1.4.1.9.9.48.1.1.1.2"
    public static let ciscoMemoryPoolUsed: SNMPOID = "1.3.6.1.4.1.9.9.48.1.1.1.5"
    public static let ciscoMemoryPoolFree: SNMPOID = "1.3.6.1.4.1.9.9.48.1.1.1.6"

    // FORTINET-FORTIGATE-MIB
    public static let fgSysCpuUsage: SNMPOID = "1.3.6.1.4.1.12356.101.4.1.3.0"
    public static let fgSysMemUsage: SNMPOID = "1.3.6.1.4.1.12356.101.4.1.4.0"
    public static let fgSysMemCapacity: SNMPOID = "1.3.6.1.4.1.12356.101.4.1.5.0"

    // HP-SWITCH-MIB / NETSWITCH-MIB (ProCurve, Aruba OS-Switch)
    public static let hpSwitchCpuStat: SNMPOID = "1.3.6.1.4.1.11.2.14.11.5.1.9.6.1.0"
    public static let hpLocalMemTotalBytes: SNMPOID = "1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.5"
    public static let hpLocalMemAllocBytes: SNMPOID = "1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.7"

    // IF-MIB
    public static let ifDescr: SNMPOID = "1.3.6.1.2.1.2.2.1.2"
    public static let ifSpeed: SNMPOID = "1.3.6.1.2.1.2.2.1.5"
    public static let ifOperStatus: SNMPOID = "1.3.6.1.2.1.2.2.1.8"
    public static let ifInOctets: SNMPOID = "1.3.6.1.2.1.2.2.1.10"
    public static let ifInDiscards: SNMPOID = "1.3.6.1.2.1.2.2.1.13"
    public static let ifInErrors: SNMPOID = "1.3.6.1.2.1.2.2.1.14"
    public static let ifOutOctets: SNMPOID = "1.3.6.1.2.1.2.2.1.16"
    public static let ifOutDiscards: SNMPOID = "1.3.6.1.2.1.2.2.1.19"
    public static let ifOutErrors: SNMPOID = "1.3.6.1.2.1.2.2.1.20"
    public static let ifName: SNMPOID = "1.3.6.1.2.1.31.1.1.1.1"
    public static let ifHCInOctets: SNMPOID = "1.3.6.1.2.1.31.1.1.1.6"
    public static let ifHCOutOctets: SNMPOID = "1.3.6.1.2.1.31.1.1.1.10"
    public static let ifHighSpeed: SNMPOID = "1.3.6.1.2.1.31.1.1.1.15"
    public static let ifAlias: SNMPOID = "1.3.6.1.2.1.31.1.1.1.18"
}

/// Un stockage de hrStorageTable (mémoire vive, disque, cache…).
public struct SNMPStorage: Hashable, Sendable {
    public var index: Int
    public var type: SNMPOID?
    public var descr: String
    public var unitBytes: UInt64
    public var size: UInt64
    public var used: UInt64

    public init(index: Int, type: SNMPOID?, descr: String, unitBytes: UInt64, size: UInt64, used: UInt64) {
        self.index = index
        self.type = type
        self.descr = descr
        self.unitBytes = unitBytes
        self.size = size
        self.used = used
    }

    public var sizeBytes: UInt64 { size.multipliedReportingOverflow(by: unitBytes).partialValue }
    public var usedBytes: UInt64 { used.multipliedReportingOverflow(by: unitBytes).partialValue }
    public var isRAM: Bool { type == SNMPResourceOIDs.hrStorageRam }
}

/// Lecture du processeur : charge et MIB qui l'a donnée.
public struct SNMPProcessorReading: Hashable, Sendable {
    public var load: CPULoad
    /// « HOST-RESOURCES-MIB », « CISCO-PROCESS-MIB »…
    public var source: String

    public init(load: CPULoad, source: String) {
        self.load = load
        self.source = source
    }
}

/// Lecture de la mémoire et MIB qui l'a donnée.
public struct SNMPMemoryReading: Hashable, Sendable {
    public var memory: MemoryStats
    public var source: String

    public init(memory: MemoryStats, source: String) {
        self.memory = memory
        self.source = source
    }
}

/// Compteurs d'un port (IF-MIB) à un instant.
public struct SNMPPortCounters: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var alias: String
    public var type: Int?
    public var isUp: Bool
    public var counters: TrafficCounters

    public init(index: Int, name: String, alias: String = "", type: Int? = nil, isUp: Bool, counters: TrafficCounters) {
        self.index = index
        self.name = name
        self.alias = alias
        self.type = type
        self.isUp = isUp
        self.counters = counters
    }
}

/// Analyse des réponses SNMP (pure, testée sur des réponses fixes).
public enum SNMPResourceParse {
    /// Valeur entière d'une colonne, indexée par le dernier composant de l'OID.
    public static func column(_ binds: [SNMPVarBind], under root: SNMPOID) -> [Int: SNMPValue] {
        var result: [Int: SNMPValue] = [:]
        for bind in binds where !bind.value.isException {
            guard let suffix = bind.oid.suffix(after: root), let last = suffix.last, suffix.count == 1 else { continue }
            result[Int(last)] = bind.value
        }
        return result
    }

    /// hrProcessorLoad : un pourcentage par processeur (moyenne de la dernière minute).
    public static func processorLoads(_ binds: [SNMPVarBind]) -> [Int] {
        column(binds, under: SNMPResourceOIDs.hrProcessorLoad).sorted { $0.key < $1.key }
            .compactMap { $0.value.intValue.map(Int.init) }
    }

    /// hrStorageTable reconstituée à partir de ses colonnes.
    public static func storages(type: [Int: SNMPValue], descr: [Int: SNMPValue], units: [Int: SNMPValue],
                                size: [Int: SNMPValue], used: [Int: SNMPValue]) -> [SNMPStorage] {
        // hrStorageSize et hrStorageUsed sont des Integer32 : un agent qui déborde donne un négatif,
        // relu comme non signé.
        func unsigned(_ value: SNMPValue?) -> UInt64 {
            guard let v = value?.intValue else { return 0 }
            return v >= 0 ? UInt64(v) : UInt64(UInt32(truncatingIfNeeded: v))
        }
        return Set(size.keys).union(descr.keys).sorted().map { index in
            var oid: SNMPOID?
            if case .oid(let value)? = type[index] { oid = value }
            return SNMPStorage(index: index, type: oid, descr: descr[index]?.stringValue ?? "",
                               unitBytes: max(1, unsigned(units[index])), size: unsigned(size[index]), used: unsigned(used[index]))
        }
    }

    /// Mémoire vive d'après hrStorageTable : le stockage hrStorageRam (« Physical memory »,
    /// « Real Memory »…). Sous Linux (net-snmp), la mémoire « utilisée » compte les tampons et le
    /// cache : on les retire quand l'agent les donne, comme `free`.
    public static func memory(from storages: [SNMPStorage]) -> MemoryStats? {
        let rams = storages.filter { $0.isRAM && $0.size > 0 }
        let ram = rams.first { ["physical", "real", "ram"].contains(where: $0.descr.lowercased().contains) } ?? rams.first
        guard let ram else { return nil }
        var used = ram.usedBytes
        var cached: UInt64 = 0
        for storage in storages where !storage.isRAM {
            let name = storage.descr.lowercased()
            if name == "cached memory" || name == "memory buffers" { cached += storage.usedBytes }
        }
        if cached > 0, cached < used { used -= cached } else { cached = 0 }
        return MemoryStats(totalBytes: ram.sizeBytes, usedBytes: used, cachedBytes: cached > 0 ? cached : nil)
    }

    /// CISCO-MEMORY-POOL-MIB : pool « Processor » (sinon le premier) ; utilisée + libre = total.
    public static func ciscoMemory(names: [Int: SNMPValue], used: [Int: SNMPValue], free: [Int: SNMPValue]) -> MemoryStats? {
        let pool = names.first { $0.value.stringValue?.lowercased() == "processor" }?.key ?? used.keys.sorted().first
        guard let pool, let u = used[pool]?.uint64Value, let f = free[pool]?.uint64Value, u + f > 0 else { return nil }
        return MemoryStats(totalBytes: u + f, usedBytes: u)
    }

    /// Compteurs par port. Les compteurs 64 bits (ifXTable) sont préférés ; sinon les 32 bits.
    /// La vitesse vient de ifHighSpeed (Mb/s), sinon de ifSpeed (b/s, plafonné à 4,29 Gb/s).
    public static func portCounters(descr: [Int: SNMPValue], name: [Int: SNMPValue], alias: [Int: SNMPValue],
                                    oper: [Int: SNMPValue], hcIn: [Int: SNMPValue], hcOut: [Int: SNMPValue],
                                    in32: [Int: SNMPValue], out32: [Int: SNMPValue], highSpeed: [Int: SNMPValue],
                                    speed: [Int: SNMPValue], inErrors: [Int: SNMPValue], outErrors: [Int: SNMPValue],
                                    inDiscards: [Int: SNMPValue], outDiscards: [Int: SNMPValue],
                                    type: [Int: SNMPValue] = [:]) -> [SNMPPortCounters] {
        let indexes = Set(descr.keys).union(name.keys).union(hcIn.keys).union(in32.keys)
        return indexes.sorted().compactMap { i in
            let counters: TrafficCounters
            if let a = hcIn[i]?.uint64Value, let b = hcOut[i]?.uint64Value {
                counters = TrafficCounters(inOctets: a, outOctets: b, width: .bits64)
            } else if let a = in32[i]?.uint64Value, let b = out32[i]?.uint64Value {
                counters = TrafficCounters(inOctets: a, outOctets: b, width: .bits32)
            } else {
                return nil
            }
            var withDetails = counters
            withDetails.inErrors = inErrors[i]?.uint64Value
            withDetails.outErrors = outErrors[i]?.uint64Value
            withDetails.inDiscards = inDiscards[i]?.uint64Value
            withDetails.outDiscards = outDiscards[i]?.uint64Value
            withDetails.speedMbps = linkSpeed(highSpeed: highSpeed[i], speed: speed[i])
            let d = descr[i]?.stringValue ?? ""
            let n = name[i]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? d
            return SNMPPortCounters(index: i, name: n.isEmpty ? "if\(i)" : n, alias: alias[i]?.stringValue ?? "",
                                    type: type[i]?.intValue.map(Int.init),
                                    isUp: (oper[i]?.intValue ?? 1) == 1, counters: withDetails)
        }
    }

    /// Vitesse du lien en Mb/s : ifHighSpeed s'il est non nul, sinon ifSpeed (b/s).
    public static func linkSpeed(highSpeed: SNMPValue?, speed: SNMPValue?) -> UInt64? {
        if let high = highSpeed?.uint64Value, high > 0 { return high }
        if let bps = speed?.uint64Value, bps > 0, bps < UInt64(UInt32.max) { return max(1, bps / 1_000_000) }
        return nil
    }

    /// Port cherché par son nom (ifName, ifDescr ou ifAlias), sans tenir compte de la casse.
    public static func findPort(_ text: String, in ports: [(index: Int, name: String, descr: String, alias: String)]) -> Int? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = ports.first(where: { $0.name.lowercased() == wanted || $0.descr.lowercased() == wanted }) { return exact.index }
        if let alias = ports.first(where: { !$0.alias.isEmpty && $0.alias.lowercased() == wanted }) { return alias.index }
        if let number = Int(wanted), ports.contains(where: { $0.index == number }) { return number }
        return nil
    }
}

// MARK: - Relevé

/// Interroge un agent SNMP pour ses ressources. Chaque MIB absente donne simplement « rien ».
public struct SNMPResourcePoller: Sendable {
    public let client: SNMPClient

    public init(target: SNMPTarget) {
        client = SNMPClient(target: target)
    }

    private func walk(_ root: SNMPOID) async throws -> [SNMPVarBind] {
        do {
            return try await client.walk(root)
        } catch SNMPError.agent {
            return []
        }
    }

    private func column(_ root: SNMPOID) async throws -> [Int: SNMPValue] {
        SNMPResourceParse.column(try await walk(root), under: root)
    }

    /// Valeurs scalaires présentes parmi `oids` (une seule requête GET ; erreur de l'agent : aucune).
    private func scalars(_ oids: [SNMPOID]) async throws -> [SNMPOID: SNMPValue] {
        let binds: [SNMPVarBind]
        do { binds = try await client.get(oids) } catch SNMPError.agent { return [:] }
        var result: [SNMPOID: SNMPValue] = [:]
        for bind in binds where !bind.value.isException { result[bind.oid] = bind.value }
        return result
    }

    /// Charge du processeur : HOST-RESOURCES-MIB, puis Cisco, Fortinet, HPE.
    public func processor() async throws -> SNMPProcessorReading? {
        let loads = SNMPResourceParse.processorLoads(try await walk(SNMPResourceOIDs.hrProcessorLoad))
        if let load = CPULoad.fromPercentages(loads) { return SNMPProcessorReading(load: load, source: "HOST-RESOURCES-MIB") }
        let cisco = try await column(SNMPResourceOIDs.cpmCPUTotal1minRev).sorted { $0.key < $1.key }.compactMap { $0.value.intValue.map(Int.init) }
        if let load = CPULoad.fromPercentages(cisco) { return SNMPProcessorReading(load: load, source: "CISCO-PROCESS-MIB") }
        let values = try await scalars([SNMPResourceOIDs.fgSysCpuUsage, SNMPResourceOIDs.hpSwitchCpuStat])
        if let v = values[SNMPResourceOIDs.fgSysCpuUsage]?.intValue, let load = CPULoad.fromPercentages([Int(v)]) {
            return SNMPProcessorReading(load: load, source: "FORTINET-FORTIGATE-MIB")
        }
        if let v = values[SNMPResourceOIDs.hpSwitchCpuStat]?.intValue, let load = CPULoad.fromPercentages([Int(v)]) {
            return SNMPProcessorReading(load: load, source: "HP-SWITCH-MIB")
        }
        return nil
    }

    /// Mémoire vive : HOST-RESOURCES-MIB, puis Cisco, Fortinet, HPE.
    public func memory() async throws -> SNMPMemoryReading? {
        let size = try await column(SNMPResourceOIDs.hrStorageSize)
        if !size.isEmpty {
            let storages = SNMPResourceParse.storages(type: try await column(SNMPResourceOIDs.hrStorageType),
                                                      descr: try await column(SNMPResourceOIDs.hrStorageDescr),
                                                      units: try await column(SNMPResourceOIDs.hrStorageAllocationUnits),
                                                      size: size, used: try await column(SNMPResourceOIDs.hrStorageUsed))
            if let memory = SNMPResourceParse.memory(from: storages) {
                return SNMPMemoryReading(memory: memory, source: "HOST-RESOURCES-MIB")
            }
        }
        let used = try await column(SNMPResourceOIDs.ciscoMemoryPoolUsed)
        if !used.isEmpty, let memory = SNMPResourceParse.ciscoMemory(names: try await column(SNMPResourceOIDs.ciscoMemoryPoolName),
                                                                     used: used, free: try await column(SNMPResourceOIDs.ciscoMemoryPoolFree)) {
            return SNMPMemoryReading(memory: memory, source: "CISCO-MEMORY-POOL-MIB")
        }
        let values = try await scalars([SNMPResourceOIDs.fgSysMemUsage, SNMPResourceOIDs.fgSysMemCapacity,
                                        SNMPResourceOIDs.hpLocalMemTotalBytes, SNMPResourceOIDs.hpLocalMemAllocBytes])
        if let percent = values[SNMPResourceOIDs.fgSysMemUsage]?.intValue,
           let capacityKB = values[SNMPResourceOIDs.fgSysMemCapacity]?.uint64Value, capacityKB > 0 {
            let total = capacityKB * 1024
            return SNMPMemoryReading(memory: MemoryStats(totalBytes: total, usedBytes: UInt64(Double(total) * Double(max(0, min(100, percent))) / 100)),
                                     source: "FORTINET-FORTIGATE-MIB")
        }
        if let total = values[SNMPResourceOIDs.hpLocalMemTotalBytes]?.uint64Value, total > 0,
           let alloc = values[SNMPResourceOIDs.hpLocalMemAllocBytes]?.uint64Value {
            return SNMPMemoryReading(memory: MemoryStats(totalBytes: total, usedBytes: alloc), source: "HP-SWITCH-MIB")
        }
        return nil
    }

    /// Compteurs de toutes les interfaces (IF-MIB).
    public func ports() async throws -> [SNMPPortCounters] {
        let hcIn = try await column(SNMPResourceOIDs.ifHCInOctets)
        let hcOut = hcIn.isEmpty ? [:] : try await column(SNMPResourceOIDs.ifHCOutOctets)
        let in32 = hcIn.isEmpty ? try await column(SNMPResourceOIDs.ifInOctets) : [:]
        let out32 = hcIn.isEmpty ? try await column(SNMPResourceOIDs.ifOutOctets) : [:]
        return SNMPResourceParse.portCounters(
            descr: try await column(SNMPResourceOIDs.ifDescr), name: try await column(SNMPResourceOIDs.ifName),
            alias: try await column(SNMPResourceOIDs.ifAlias), oper: try await column(SNMPResourceOIDs.ifOperStatus),
            hcIn: hcIn, hcOut: hcOut, in32: in32, out32: out32,
            highSpeed: try await column(SNMPResourceOIDs.ifHighSpeed), speed: try await column(SNMPResourceOIDs.ifSpeed),
            inErrors: try await column(SNMPResourceOIDs.ifInErrors), outErrors: try await column(SNMPResourceOIDs.ifOutErrors),
            inDiscards: try await column(SNMPResourceOIDs.ifInDiscards), outDiscards: try await column(SNMPResourceOIDs.ifOutDiscards))
    }

    /// Compteurs d'un seul port (une requête GET), pour suivre un port choisi sans relire tout le switch.
    public func port(_ index: Int) async throws -> SNMPPortCounters? {
        let i = UInt32(index)
        let roots = [SNMPResourceOIDs.ifDescr, SNMPResourceOIDs.ifName, SNMPResourceOIDs.ifAlias, SNMPResourceOIDs.ifOperStatus,
                     SNMPResourceOIDs.ifHCInOctets, SNMPResourceOIDs.ifHCOutOctets, SNMPResourceOIDs.ifInOctets,
                     SNMPResourceOIDs.ifOutOctets, SNMPResourceOIDs.ifHighSpeed, SNMPResourceOIDs.ifSpeed,
                     SNMPResourceOIDs.ifInErrors, SNMPResourceOIDs.ifOutErrors, SNMPResourceOIDs.ifInDiscards,
                     SNMPResourceOIDs.ifOutDiscards]
        let values = try await scalars(roots.map { $0.appending(i) })
        func col(_ root: SNMPOID) -> [Int: SNMPValue] {
            values[root.appending(i)].map { [index: $0] } ?? [:]
        }
        return SNMPResourceParse.portCounters(
            descr: col(SNMPResourceOIDs.ifDescr), name: col(SNMPResourceOIDs.ifName), alias: col(SNMPResourceOIDs.ifAlias),
            oper: col(SNMPResourceOIDs.ifOperStatus), hcIn: col(SNMPResourceOIDs.ifHCInOctets), hcOut: col(SNMPResourceOIDs.ifHCOutOctets),
            in32: col(SNMPResourceOIDs.ifInOctets), out32: col(SNMPResourceOIDs.ifOutOctets),
            highSpeed: col(SNMPResourceOIDs.ifHighSpeed), speed: col(SNMPResourceOIDs.ifSpeed),
            inErrors: col(SNMPResourceOIDs.ifInErrors), outErrors: col(SNMPResourceOIDs.ifOutErrors),
            inDiscards: col(SNMPResourceOIDs.ifInDiscards), outDiscards: col(SNMPResourceOIDs.ifOutDiscards)).first
    }

    /// Index d'un port d'après son nom (ifName, ifDescr ou ifAlias).
    public func findPort(_ text: String) async throws -> Int? {
        let names = try await column(SNMPResourceOIDs.ifName)
        let descr = try await column(SNMPResourceOIDs.ifDescr)
        let alias = try await column(SNMPResourceOIDs.ifAlias)
        let list = Set(names.keys).union(descr.keys).sorted().map {
            (index: $0, name: names[$0]?.stringValue ?? "", descr: descr[$0]?.stringValue ?? "", alias: alias[$0]?.stringValue ?? "")
        }
        return SNMPResourceParse.findPort(text, in: list)
    }
}
