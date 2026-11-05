import Foundation

// Note 75 : décodeurs purs des datagrammes de flux. Le format est reconnu au premier mot (5 et 9 :
// NetFlow, 10 : IPFIX, 0x00000005 sur quatre octets : sFlow v5), quel que soit le port d'arrivée.
//
// - NetFlow v5 : en-tête de 24 octets, enregistrements fixes de 48 octets.
// - NetFlow v9 (RFC 3954) et IPFIX (RFC 7011) : gabarits appris par exportateur, domaine
//   d'observation et numéro de gabarit ; un ensemble de données arrivé avant son gabarit est mis de
//   côté (mémoire bornée) puis décodé quand le gabarit arrive. Gabarits d'options : seul
//   l'échantillonnage est retenu.
// - sFlow v5 : voir FlowSFlow.swift.

/// Décodeur avec mémoire des gabarits (un par collecteur ; pas partagé entre fils).
public struct FlowDecoder: Sendable {
    /// Limites de la mémoire des gabarits et des ensembles mis de côté.
    public struct Limits: Sendable {
        public var maxTemplates = 1024
        public var maxWaitingSets = 256
        public var maxWaitingBytes = 1 << 20
        public var maxWaitingPerTemplate = 32
        public init() {}
    }

    struct TemplateKey: Hashable, Sendable {
        var exporter: IPv4Address
        var domain: UInt32
        var id: UInt16
        var ipfix: Bool
    }

    struct Field: Hashable, Sendable {
        var type: UInt16
        var enterprise: UInt32?
        /// 65535 : longueur variable (IPFIX).
        var length: UInt16
    }

    struct Template: Sendable {
        var fields: [Field]
        var isOptions: Bool
        var learned: UInt64
    }

    struct Waiting: Sendable {
        var key: TemplateKey
        var bytes: [UInt8]
        var order: UInt64
    }

    public var limits: Limits
    var templates: [TemplateKey: Template] = [:]
    var waiting: [Waiting] = []
    var waitingBytes = 0
    /// Échantillonnage annoncé par options (exportateur, domaine).
    var sampling: [FlowExporterDomain: UInt32] = [:]
    private var counter: UInt64 = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Nombre de gabarits connus pour un exportateur (tous si nil).
    public func templateCount(exporter: IPv4Address? = nil) -> Int {
        guard let exporter else { return templates.count }
        return templates.keys.filter { $0.exporter == exporter }.count
    }

    /// Ensembles en attente de gabarit pour un exportateur (tous si nil).
    public func waitingCount(exporter: IPv4Address? = nil) -> Int {
        guard let exporter else { return waiting.count }
        return waiting.filter { $0.key.exporter == exporter }.count
    }

    /// Échantillonnage annoncé par un exportateur (options v9/IPFIX), le plus grand des domaines.
    public func announcedSampling(exporter: IPv4Address) -> UInt32? {
        sampling.filter { $0.key.exporter == exporter }.values.max()
    }

    /// Oublie tout ce qui concerne un exportateur.
    public mutating func forget(exporter: IPv4Address) {
        templates = templates.filter { $0.key.exporter != exporter }
        waiting.removeAll { $0.key.exporter == exporter }
        waitingBytes = waiting.reduce(0) { $0 + $1.bytes.count }
        sampling = sampling.filter { $0.key.exporter != exporter }
    }

    // MARK: Aiguillage

    /// Format d'un datagramme d'après ses premiers octets (nil : inconnu).
    public static func kind(of bytes: [UInt8]) -> FlowProtocolKind? {
        guard bytes.count >= 4 else { return nil }
        let first = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        switch first {
        case 5: return .netflow5
        case 9: return .netflow9
        case 10: return .ipfix
        case 0 where bytes[2] == 0 && bytes[3] == 5: return .sflow
        default: return nil
        }
    }

    /// Décode un datagramme reçu de `exporter`.
    public mutating func decode(_ bytes: [UInt8], from exporter: IPv4Address) throws -> FlowDecodeResult {
        guard let kind = Self.kind(of: bytes) else {
            if bytes.count < 4 { throw FlowDecodeError("datagramme trop court (\(bytes.count) octets)") }
            let first = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            throw FlowDecodeError("format inconnu (version \(first)) : ni NetFlow, ni IPFIX, ni sFlow")
        }
        switch kind {
        case .netflow5: return try Self.decodeV5(bytes, from: exporter)
        case .netflow9: return try decodeV9(bytes, from: exporter)
        case .ipfix: return try decodeIPFIX(bytes, from: exporter)
        case .sflow: return try FlowSFlow.decode(bytes, from: exporter)
        }
    }

    // MARK: NetFlow v5

    static func decodeV5(_ bytes: [UInt8], from exporter: IPv4Address) throws -> FlowDecodeResult {
        var r = FlowByteReader(bytes)
        _ = try r.u16()
        let count = Int(try r.u16())
        guard bytes.count >= 24 else { throw FlowDecodeError("en-tête NetFlow v5 tronqué") }
        guard count <= 30 else { throw FlowDecodeError("NetFlow v5 : \(count) enregistrements annoncés (30 au plus)") }
        guard bytes.count >= 24 + count * 48 else {
            throw FlowDecodeError("NetFlow v5 : \(count) enregistrements annoncés, \((bytes.count - 24) / 48) présents")
        }
        try r.skip(12) // sysUptime, unix_secs, unix_nsecs
        _ = try r.u32() // flow_sequence
        let engineType = try r.u8()
        let engineID = try r.u8()
        let samplingField = try r.u16()
        // Deux bits de mode, 14 bits d'intervalle (0 : pas d'échantillonnage).
        let interval = UInt32(samplingField & 0x3FFF)
        let rate = max(1, interval)
        let domain = UInt32(engineType) << 8 | UInt32(engineID)
        var records: [FlowRecord] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            let src = try r.ipv4()
            let dst = try r.ipv4()
            try r.skip(4) // nexthop
            let input = try r.u16()
            let output = try r.u16()
            let packets = try r.u32()
            let octets = try r.u32()
            let first = try r.u32()
            let last = try r.u32()
            let srcPort = try r.u16()
            let dstPort = try r.u16()
            try r.skip(1)
            let flags = try r.u8()
            let proto = try r.u8()
            try r.skip(1 + 2 + 2 + 1 + 1 + 2) // tos, src_as, dst_as, masques, pad2
            records.append(FlowRecord(kind: .netflow5, exporter: exporter, domain: domain, source: src, destination: dst,
                                      sourcePort: srcPort, destinationPort: dstPort, proto: proto, bytes: UInt64(octets),
                                      packets: UInt64(packets), inputInterface: UInt32(input), outputInterface: UInt32(output),
                                      tcpFlags: flags, durationMs: last >= first ? last - first : nil, samplingRate: rate))
        }
        return FlowDecodeResult(kind: .netflow5, domain: domain, records: records, samplingRate: interval > 1 ? interval : nil)
    }

    // MARK: NetFlow v9

    mutating func decodeV9(_ bytes: [UInt8], from exporter: IPv4Address) throws -> FlowDecodeResult {
        guard bytes.count >= 20 else { throw FlowDecodeError("en-tête NetFlow v9 tronqué") }
        var r = FlowByteReader(bytes)
        try r.skip(16) // version, count, sysUptime, unix_secs, sequence
        let domain = try r.u32()
        var result = FlowDecodeResult(kind: .netflow9, domain: domain)
        try readSets(&r, ipfix: false, exporter: exporter, domain: domain, into: &result)
        return result
    }

    // MARK: IPFIX

    mutating func decodeIPFIX(_ bytes: [UInt8], from exporter: IPv4Address) throws -> FlowDecodeResult {
        guard bytes.count >= 16 else { throw FlowDecodeError("en-tête IPFIX tronqué") }
        var r = FlowByteReader(bytes)
        _ = try r.u16()
        let length = Int(try r.u16())
        guard length >= 16, length <= bytes.count else {
            throw FlowDecodeError("IPFIX : longueur annoncée \(length) octets, \(bytes.count) reçus")
        }
        try r.skip(8) // export time, sequence
        let domain = try r.u32()
        var body = FlowByteReader(bytes, offset: 16, end: length)
        var result = FlowDecodeResult(kind: .ipfix, domain: domain)
        try readSets(&body, ipfix: true, exporter: exporter, domain: domain, into: &result)
        return result
    }

    // MARK: Ensembles

    private mutating func readSets(_ r: inout FlowByteReader, ipfix: Bool, exporter: IPv4Address, domain: UInt32,
                                   into result: inout FlowDecodeResult) throws {
        let templateSet: UInt16 = ipfix ? 2 : 0
        let optionsSet: UInt16 = ipfix ? 3 : 1
        while r.remaining >= 4 {
            let setID = try r.u16()
            let length = Int(try r.u16())
            guard length >= 4 else { throw FlowDecodeError("ensemble \(setID) de longueur \(length) : datagramme corrompu") }
            guard length - 4 <= r.remaining else { throw FlowDecodeError("ensemble \(setID) tronqué (\(length) octets annoncés)") }
            var set = try r.sub(length - 4)
            switch setID {
            case templateSet:
                try readTemplates(&set, ipfix: ipfix, exporter: exporter, domain: domain, into: &result)
            case optionsSet:
                try readOptionTemplates(&set, ipfix: ipfix, exporter: exporter, domain: domain, into: &result)
            case 256...:
                let key = TemplateKey(exporter: exporter, domain: domain, id: setID, ipfix: ipfix)
                let body = Array(set.bytes[set.offset..<set.end])
                if let template = templates[key] {
                    // Un ensemble mal formé (bourrage final d'un gabarit variable, par exemple) ne
                    // fait pas perdre le reste du datagramme : ses enregistrements lus sont gardés.
                    try? readData(body, template: template, key: key, into: &result)
                } else {
                    keepWaiting(key, body)
                    result.setsWaiting += 1
                }
            default:
                break // ensembles réservés : ignorés
            }
        }
    }

    private mutating func readTemplates(_ r: inout FlowByteReader, ipfix: Bool, exporter: IPv4Address, domain: UInt32,
                                        into result: inout FlowDecodeResult) throws {
        while r.remaining >= 4 {
            let id = try r.u16()
            let count = Int(try r.u16())
            if id == 0 { break } // bourrage
            let key = TemplateKey(exporter: exporter, domain: domain, id: id, ipfix: ipfix)
            if count == 0 {
                // IPFIX : retrait du gabarit.
                templates[key] = nil
                continue
            }
            var fields: [Field] = []
            for _ in 0..<count {
                fields.append(try readField(&r, ipfix: ipfix))
            }
            learn(key, Template(fields: fields, isOptions: false, learned: next()), into: &result)
        }
    }

    private mutating func readOptionTemplates(_ r: inout FlowByteReader, ipfix: Bool, exporter: IPv4Address, domain: UInt32,
                                              into result: inout FlowDecodeResult) throws {
        while r.remaining >= 6 {
            let id = try r.u16()
            if id == 0 { break }
            var fields: [Field] = []
            if ipfix {
                let count = Int(try r.u16())
                _ = try r.u16() // champs de portée
                for _ in 0..<count { fields.append(try readField(&r, ipfix: true)) }
            } else {
                let scopeLength = Int(try r.u16())
                let optionLength = Int(try r.u16())
                for _ in 0..<((scopeLength + optionLength) / 4) { fields.append(try readField(&r, ipfix: false)) }
            }
            let key = TemplateKey(exporter: exporter, domain: domain, id: id, ipfix: ipfix)
            learn(key, Template(fields: fields, isOptions: true, learned: next()), into: &result)
        }
    }

    private func readField(_ r: inout FlowByteReader, ipfix: Bool) throws -> Field {
        var type = try r.u16()
        let length = try r.u16()
        var enterprise: UInt32?
        if ipfix, type & 0x8000 != 0 {
            type &= 0x7FFF
            enterprise = try r.u32()
        }
        return Field(type: type, enterprise: enterprise, length: length)
    }

    private mutating func next() -> UInt64 {
        counter &+= 1
        return counter
    }

    private mutating func learn(_ key: TemplateKey, _ template: Template, into result: inout FlowDecodeResult) {
        templates[key] = template
        result.templatesLearned += 1
        if templates.count > limits.maxTemplates, let oldest = templates.min(by: { $0.value.learned < $1.value.learned })?.key {
            templates[oldest] = nil
        }
        // Ensembles arrivés avant ce gabarit : décodés maintenant.
        let ready = waiting.filter { $0.key == key }
        guard !ready.isEmpty else { return }
        waiting.removeAll { $0.key == key }
        waitingBytes = waiting.reduce(0) { $0 + $1.bytes.count }
        for item in ready.sorted(by: { $0.order < $1.order }) {
            let before = result.records.count
            try? readData(item.bytes, template: template, key: key, into: &result)
            result.recoveredRecords += result.records.count - before
        }
    }

    private mutating func keepWaiting(_ key: TemplateKey, _ bytes: [UInt8]) {
        waiting.append(Waiting(key: key, bytes: bytes, order: next()))
        waitingBytes += bytes.count
        // Bornes : par gabarit, en nombre et en octets ; les plus anciens partent d'abord.
        let mine = waiting.filter { $0.key == key }
        if mine.count > limits.maxWaitingPerTemplate, let oldest = mine.first {
            waiting.removeAll { $0.order == oldest.order }
        }
        while waiting.count > limits.maxWaitingSets || waitingBytes > limits.maxWaitingBytes, !waiting.isEmpty {
            waiting.removeFirst()
        }
        waitingBytes = waiting.reduce(0) { $0 + $1.bytes.count }
    }

    // MARK: Données

    private mutating func readData(_ body: [UInt8], template: Template, key: TemplateKey, into result: inout FlowDecodeResult) throws {
        var r = FlowByteReader(body)
        let fixed = template.fields.allSatisfy { $0.length != 65535 }
        let minimum = template.fields.reduce(0) { $0 + ($1.length == 65535 ? 1 : Int($1.length)) }
        guard minimum > 0 else { return }
        let exporterDomain = FlowExporterDomain(exporter: key.exporter, domain: key.domain)
        while r.remaining >= minimum {
            var values = FlowFieldValues()
            for field in template.fields {
                var length = Int(field.length)
                if length == 65535 {
                    length = Int(try r.u8())
                    if length == 255 { length = Int(try r.u16()) }
                }
                let value = try r.take(length)
                guard field.enterprise == nil else { continue }
                values.set(field.type, value)
            }
            if template.isOptions {
                if let rate = values.samplingInterval, rate > 0,
                   sampling[exporterDomain] != nil || sampling.count < limits.maxTemplates {
                    sampling[exporterDomain] = rate
                    result.samplingRate = rate
                }
                continue
            }
            let rate = values.samplingInterval ?? sampling[exporterDomain] ?? 1
            if let record = values.record(kind: key.ipfix ? .ipfix : .netflow9, exporter: key.exporter, domain: key.domain, sampling: rate) {
                result.records.append(record)
            }
            // Bourrage final (gabarit à longueur fixe) : moins qu'un enregistrement entier.
            if fixed, r.remaining < minimum { break }
        }
    }
}

/// Exportateur et domaine d'observation.
public struct FlowExporterDomain: Hashable, Sendable {
    public var exporter: IPv4Address
    public var domain: UInt32
}

/// Valeurs des champs courants d'un enregistrement v9/IPFIX (numéros communs aux deux).
struct FlowFieldValues {
    var bytes: UInt64?
    var totalBytes: UInt64?
    var outBytes: UInt64?
    var packets: UInt64?
    var totalPackets: UInt64?
    var initiatorBytes: UInt64?
    var responderBytes: UInt64?
    var initiatorPackets: UInt64?
    var proto: UInt8?
    var tcpFlags: UInt8 = 0
    var srcPort: UInt16 = 0
    var dstPort: UInt16 = 0
    var src: IPv4Address?
    var dst: IPv4Address?
    var ipv6 = false
    var input: UInt32?
    var output: UInt32?
    var firstUptime: UInt64?
    var lastUptime: UInt64?
    var startSeconds: UInt64?
    var endSeconds: UInt64?
    var startMs: UInt64?
    var endMs: UInt64?
    var samplingInterval: UInt32?

    mutating func set(_ type: UInt16, _ value: ArraySlice<UInt8>) {
        let number = flowUInt(value)
        switch type {
        case 1: bytes = number                       // IN_BYTES, octetDeltaCount
        case 2: packets = number                     // IN_PKTS, packetDeltaCount
        case 4: proto = UInt8(truncatingIfNeeded: number)
        case 6: tcpFlags = UInt8(truncatingIfNeeded: number)
        case 7: srcPort = UInt16(truncatingIfNeeded: number)
        case 8: if value.count == 4 { src = IPv4Address(UInt32(number)) }
        case 10: input = UInt32(truncatingIfNeeded: number)
        case 11: dstPort = UInt16(truncatingIfNeeded: number)
        case 12: if value.count == 4 { dst = IPv4Address(UInt32(number)) }
        case 14: output = UInt32(truncatingIfNeeded: number)
        case 21: lastUptime = number
        case 22: firstUptime = number
        case 23: outBytes = number                   // OUT_BYTES
        case 27, 28: if value.count == 16 { ipv6 = true }
        case 34, 50, 305: if number > 0 { samplingInterval = UInt32(truncatingIfNeeded: number) }
        case 85: totalBytes = number
        case 86: totalPackets = number
        case 150: startSeconds = number
        case 151: endSeconds = number
        case 152: startMs = number
        case 153: endMs = number
        case 231: initiatorBytes = number            // initiatorOctets (Cisco ASA NSEL)
        case 232: responderBytes = number            // responderOctets
        case 298: initiatorPackets = number
        default: break
        }
    }

    func record(kind: FlowProtocolKind, exporter: IPv4Address, domain: UInt32, sampling: UInt32) -> FlowRecord? {
        guard src != nil || dst != nil || ipv6 else { return nil }
        let volume = bytes ?? initiatorBytes ?? totalBytes ?? outBytes ?? 0
        let count = packets ?? initiatorPackets ?? totalPackets ?? 0
        var duration: UInt64?
        if let first = firstUptime, let last = lastUptime, last >= first { duration = last - first }
        else if let start = startMs, let end = endMs, end >= start { duration = end - start }
        else if let start = startSeconds, let end = endSeconds, end >= start { duration = (end - start) * 1000 }
        return FlowRecord(kind: kind, exporter: exporter, domain: domain, source: ipv6 ? nil : src, destination: ipv6 ? nil : dst,
                          isIPv6: ipv6, sourcePort: srcPort, destinationPort: dstPort, proto: proto ?? 0, bytes: volume,
                          packets: max(count, volume > 0 ? 1 : 0), reverseBytes: responderBytes ?? 0, inputInterface: input,
                          outputInterface: output, tcpFlags: tcpFlags,
                          durationMs: duration.map { UInt32(clamping: $0) }, samplingRate: sampling)
    }
}
