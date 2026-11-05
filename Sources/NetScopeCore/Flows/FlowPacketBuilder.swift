import Foundation

// Note 75 : fabrique de datagrammes NetFlow v5, NetFlow v9, IPFIX et sFlow v5, octet par octet,
// selon les formats publiés. Sert aux essais (paquets fixes, aller-retour sur 127.0.0.1) et à la
// démonstration, qui passe ainsi par les vrais décodeurs sans rien écouter ni envoyer.

public enum FlowPacketBuilder {
    /// Un flux à écrire.
    public struct Flow: Sendable {
        public var source: IPv4Address
        public var destination: IPv4Address
        public var sourcePort: UInt16
        public var destinationPort: UInt16
        public var proto: UInt8
        public var bytes: UInt32
        public var packets: UInt32
        public var input: UInt16
        public var output: UInt16
        public var durationMs: UInt32

        public init(source: IPv4Address, destination: IPv4Address, sourcePort: UInt16 = 0, destinationPort: UInt16 = 0, proto: UInt8 = 6,
                    bytes: UInt32, packets: UInt32 = 1, input: UInt16 = 0, output: UInt16 = 0, durationMs: UInt32 = 1000) {
            self.source = source
            self.destination = destination
            self.sourcePort = sourcePort
            self.destinationPort = destinationPort
            self.proto = proto
            self.bytes = bytes
            self.packets = packets
            self.input = input
            self.output = output
            self.durationMs = durationMs
        }
    }

    // MARK: Écriture

    struct Writer {
        var bytes: [UInt8] = []
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
        mutating func u32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
        mutating func ip(_ a: IPv4Address) { u32(a.value) }
        mutating func pad4() { while bytes.count % 4 != 0 { bytes.append(0) } }
        mutating func set16(_ v: UInt16, at offset: Int) {
            bytes[offset] = UInt8(v >> 8)
            bytes[offset + 1] = UInt8(v & 0xFF)
        }
    }

    // MARK: NetFlow v5

    /// Datagramme NetFlow v5 (30 flux au plus). `sampling` : 1 paquet sur N (0 ou 1 : aucun).
    public static func netflowV5(_ flows: [Flow], uptimeMs: UInt32 = 3_600_000, unixSeconds: UInt32 = 1_790_000_000,
                                 sequence: UInt32 = 1, engineID: UInt8 = 0, sampling: UInt16 = 0) -> [UInt8] {
        var w = Writer()
        let list = Array(flows.prefix(30))
        w.u16(5); w.u16(UInt16(list.count)); w.u32(uptimeMs); w.u32(unixSeconds); w.u32(0); w.u32(sequence)
        w.u8(0); w.u8(engineID); w.u16(sampling > 1 ? (0x4000 | (sampling & 0x3FFF)) : 0)
        for f in list {
            w.ip(f.source); w.ip(f.destination); w.u32(0)
            w.u16(f.input); w.u16(f.output); w.u32(f.packets); w.u32(f.bytes)
            let first = uptimeMs &- f.durationMs
            w.u32(first); w.u32(uptimeMs)
            w.u16(f.sourcePort); w.u16(f.destinationPort); w.u8(0); w.u8(f.proto == 6 ? 0x18 : 0); w.u8(f.proto); w.u8(0)
            w.u16(0); w.u16(0); w.u8(24); w.u8(24); w.u16(0)
        }
        return w.bytes
    }

    // MARK: NetFlow v9 et IPFIX

    /// Champs du gabarit écrit : (type, longueur).
    static let templateFields: [(UInt16, UInt16)] = [
        (8, 4), (12, 4), (7, 2), (11, 2), (4, 1), (6, 1), (10, 2), (14, 2), (1, 4), (2, 4), (22, 4), (21, 4),
    ]

    private static func writeRecord(_ w: inout Writer, _ f: Flow, uptimeMs: UInt32) {
        w.ip(f.source); w.ip(f.destination); w.u16(f.sourcePort); w.u16(f.destinationPort); w.u8(f.proto)
        w.u8(f.proto == 6 ? 0x18 : 0); w.u16(f.input); w.u16(f.output); w.u32(f.bytes); w.u32(f.packets)
        w.u32(uptimeMs &- f.durationMs); w.u32(uptimeMs)
    }

    /// Datagramme NetFlow v9 : gabarit (si `withTemplate`), options d'échantillonnage (si
    /// `sampling` > 1) et données.
    public static func netflowV9(_ flows: [Flow], templateID: UInt16 = 256, sourceID: UInt32 = 0, withTemplate: Bool = true,
                                 withData: Bool = true, sampling: UInt32 = 0, uptimeMs: UInt32 = 3_600_000,
                                 unixSeconds: UInt32 = 1_790_000_000, sequence: UInt32 = 1) -> [UInt8] {
        var w = Writer()
        w.u16(9); w.u16(0); w.u32(uptimeMs); w.u32(unixSeconds); w.u32(sequence); w.u32(sourceID)
        var count: UInt16 = 0
        if withTemplate {
            let start = w.bytes.count
            w.u16(0); w.u16(0)
            w.u16(templateID); w.u16(UInt16(templateFields.count))
            for (type, length) in templateFields { w.u16(type); w.u16(length) }
            w.set16(UInt16(w.bytes.count - start), at: start + 2)
            count += 1
        }
        if sampling > 1 {
            // Gabarit d'options (portée : système) puis ses données : SAMPLING_INTERVAL (34).
            let optionsID = templateID &+ 1
            var start = w.bytes.count
            w.u16(1); w.u16(0)
            w.u16(optionsID); w.u16(4); w.u16(4)
            w.u16(1); w.u16(4)    // portée : système (4 octets)
            w.u16(34); w.u16(4)   // SAMPLING_INTERVAL
            w.pad4()
            w.set16(UInt16(w.bytes.count - start), at: start + 2)
            start = w.bytes.count
            w.u16(optionsID); w.u16(0)
            w.u32(0); w.u32(sampling)
            w.set16(UInt16(w.bytes.count - start), at: start + 2)
            count += 2
        }
        if withData, !flows.isEmpty {
            let start = w.bytes.count
            w.u16(templateID); w.u16(0)
            for f in flows { writeRecord(&w, f, uptimeMs: uptimeMs) }
            w.pad4()
            w.set16(UInt16(w.bytes.count - start), at: start + 2)
            count += UInt16(flows.count)
        }
        w.set16(count, at: 2)
        return w.bytes
    }

    /// Datagramme IPFIX : gabarit (si `withTemplate`) et données. Le gabarit ajoute un champ
    /// d'entreprise (sauté par le décodeur) et un nom d'application à longueur variable.
    public static func ipfix(_ flows: [Flow], templateID: UInt16 = 300, domain: UInt32 = 1, withTemplate: Bool = true,
                             withData: Bool = true, exportTime: UInt32 = 1_790_000_000, sequence: UInt32 = 0) -> [UInt8] {
        var w = Writer()
        w.u16(10); w.u16(0); w.u32(exportTime); w.u32(sequence); w.u32(domain)
        if withTemplate {
            let start = w.bytes.count
            w.u16(2); w.u16(0)
            w.u16(templateID); w.u16(UInt16(templateFields.count - 2 + 2 + 2))
            for (type, length) in templateFields where type != 21 && type != 22 { w.u16(type); w.u16(length) }
            w.u16(152); w.u16(8)                 // flowStartMilliseconds
            w.u16(153); w.u16(8)                 // flowEndMilliseconds
            w.u16(0x8000 | 100); w.u16(4); w.u32(12356) // champ d'entreprise (Fortinet), sauté
            w.u16(96); w.u16(65535)              // applicationName, longueur variable
            w.set16(UInt16(w.bytes.count - start), at: start + 2)
        }
        if withData, !flows.isEmpty {
            let start = w.bytes.count
            w.u16(templateID); w.u16(0)
            let base = UInt64(exportTime) * 1000
            for f in flows {
                w.ip(f.source); w.ip(f.destination); w.u16(f.sourcePort); w.u16(f.destinationPort); w.u8(f.proto)
                w.u8(f.proto == 6 ? 0x18 : 0); w.u16(f.input); w.u16(f.output); w.u32(f.bytes); w.u32(f.packets)
                w.u64(base - UInt64(f.durationMs)); w.u64(base)
                w.u32(0xDEAD_BEEF)
                let name = Array("app".utf8)
                w.u8(UInt8(name.count)); w.bytes += name
            }
            w.set16(UInt16(w.bytes.count - start), at: start + 2)
        }
        w.set16(UInt16(w.bytes.count), at: 2)
        return w.bytes
    }

    // MARK: sFlow v5

    /// Compteurs d'interface à écrire dans un échantillon sFlow.
    public struct Counters: Sendable {
        public var ifIndex: UInt32
        public var speed: UInt64
        public var inOctets: UInt64
        public var outOctets: UInt64
        public var up: Bool
        public var inErrors: UInt32

        public init(ifIndex: UInt32, speed: UInt64, inOctets: UInt64, outOctets: UInt64, up: Bool = true, inErrors: UInt32 = 0) {
            self.ifIndex = ifIndex
            self.speed = speed
            self.inOctets = inOctets
            self.outOctets = outOctets
            self.up = up
            self.inErrors = inErrors
        }
    }

    /// Datagramme sFlow v5 : un échantillon de flux par flux (en-tête Ethernet, VLAN optionnel,
    /// IPv4 et TCP/UDP ; `bytes` = longueur de trame) et un échantillon de compteurs par interface.
    public static func sflow(agent: IPv4Address, flows: [Flow], samplingRate: UInt32, counters: [Counters] = [],
                             vlan: UInt16? = nil, subAgent: UInt32 = 0, sequence: UInt32 = 1) -> [UInt8] {
        var w = Writer()
        w.u32(5); w.u32(1); w.ip(agent); w.u32(subAgent); w.u32(sequence); w.u32(3_600_000)
        w.u32(UInt32(flows.count + counters.count))
        for (index, f) in flows.enumerated() {
            let header = ethernetFrame(f, vlan: vlan)
            var sample = Writer()
            sample.u32(UInt32(index + 1)); sample.u32(UInt32(f.input))
            sample.u32(samplingRate); sample.u32(samplingRate * 100); sample.u32(0)
            sample.u32(UInt32(f.input)); sample.u32(UInt32(f.output)); sample.u32(1)
            var record = Writer()
            record.u32(1); record.u32(f.bytes); record.u32(4); record.u32(UInt32(header.count))
            record.bytes += header
            record.pad4()
            sample.u32(1); sample.u32(UInt32(record.bytes.count)); sample.bytes += record.bytes
            w.u32(1); w.u32(UInt32(sample.bytes.count)); w.bytes += sample.bytes
        }
        for c in counters {
            var sample = Writer()
            sample.u32(1); sample.u32(c.ifIndex); sample.u32(1)
            var record = Writer()
            record.u32(c.ifIndex); record.u32(6); record.u64(c.speed); record.u32(1); record.u32(c.up ? 3 : 1)
            record.u64(c.inOctets); record.u32(0); record.u32(0); record.u32(0); record.u32(0); record.u32(c.inErrors); record.u32(0)
            record.u64(c.outOctets); record.u32(0); record.u32(0); record.u32(0); record.u32(0); record.u32(0); record.u32(0)
            sample.u32(1); sample.u32(UInt32(record.bytes.count)); sample.bytes += record.bytes
            w.u32(2); w.u32(UInt32(sample.bytes.count)); w.bytes += sample.bytes
        }
        return w.bytes
    }

    /// Début d'une trame Ethernet (en-têtes seulement, comme les 128 premiers octets de sFlow).
    static func ethernetFrame(_ f: Flow, vlan: UInt16?) -> [UInt8] {
        var w = Writer()
        w.bytes += [0x00, 0x09, 0x0F, 0x09, 0x00, 0x01, 0x90, 0x6C, 0xAC, 0x12, 0x34, 0x56]
        if let vlan { w.u16(0x8100); w.u16(vlan & 0x0FFF) }
        w.u16(0x0800)
        // IPv4 sans options.
        w.u8(0x45); w.u8(0); w.u16(UInt16(clamping: max(Int(f.bytes) - 18, 20))); w.u16(0); w.u16(0x4000)
        w.u8(64); w.u8(f.proto); w.u16(0); w.ip(f.source); w.ip(f.destination)
        if f.proto == 6 {
            w.u16(f.sourcePort); w.u16(f.destinationPort); w.u32(1); w.u32(0); w.u8(0x50); w.u8(0x18); w.u16(64_240); w.u16(0); w.u16(0)
        } else if f.proto == 17 {
            w.u16(f.sourcePort); w.u16(f.destinationPort); w.u16(8); w.u16(0)
        }
        return w.bytes
    }
}
