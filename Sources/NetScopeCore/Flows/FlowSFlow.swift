import Foundation

// Note 75 : décodeur sFlow v5 (sflow.org, « sFlow Version 5 », 2004). Un datagramme porte des
// échantillons :
// - échantillons de flux (format 1, ou 3 « étendu ») : taux d'échantillonnage, interfaces d'entrée et
//   de sortie, et des enregistrements, dont l'en-tête brut du paquet (Ethernet, VLAN, IPv4, TCP/UDP)
//   ou un résumé IPv4 ;
// - échantillons de compteurs (format 2, ou 4 « étendu ») : compteurs génériques d'interface
//   (vitesse, octets entrants et sortants, erreurs, rejets, état).
// Les enregistrements d'une autre entreprise que sFlow (0) ou d'un format inconnu sont sautés.

enum FlowSFlow {
    static func decode(_ bytes: [UInt8], from exporter: IPv4Address) throws -> FlowDecodeResult {
        var r = FlowByteReader(bytes)
        _ = try r.u32() // version 5
        let addressType = try r.u32()
        switch addressType {
        case 1: _ = try r.ipv4()
        case 2: try r.skip(16)
        default: throw FlowDecodeError("sFlow : type d'adresse d'agent \(addressType) inconnu")
        }
        let subAgent = try r.u32()
        try r.skip(8) // séquence, uptime
        let count = Int(try r.u32())
        guard count <= 1000 else { throw FlowDecodeError("sFlow : \(count) échantillons annoncés") }
        var result = FlowDecodeResult(kind: .sflow, domain: subAgent)
        for _ in 0..<count {
            let format = try r.u32()
            let length = Int(try r.u32())
            var sample = try r.sub(length)
            guard format >> 12 == 0 else { continue }
            switch format & 0xFFF {
            case 1: try flowSample(&sample, expanded: false, exporter: exporter, domain: subAgent, into: &result)
            case 3: try flowSample(&sample, expanded: true, exporter: exporter, domain: subAgent, into: &result)
            case 2: try counterSample(&sample, expanded: false, exporter: exporter, into: &result)
            case 4: try counterSample(&sample, expanded: true, exporter: exporter, into: &result)
            default: continue
            }
        }
        return result
    }

    // MARK: Échantillons de flux

    private static func flowSample(_ r: inout FlowByteReader, expanded: Bool, exporter: IPv4Address, domain: UInt32,
                                   into result: inout FlowDecodeResult) throws {
        _ = try r.u32() // séquence
        try r.skip(expanded ? 8 : 4) // source
        let rate = try r.u32()
        try r.skip(8) // sample_pool, drops
        var input: UInt32
        var output: UInt32
        if expanded {
            _ = try r.u32()
            input = try r.u32()
            _ = try r.u32()
            output = try r.u32()
        } else {
            // Deux bits de format, 30 bits de valeur (format 0 : ifIndex).
            let rawIn = try r.u32()
            let rawOut = try r.u32()
            input = rawIn >> 30 == 0 ? rawIn & 0x3FFF_FFFF : 0
            output = rawOut >> 30 == 0 ? rawOut & 0x3FFF_FFFF : 0
        }
        if input == 0x3FFF_FFFF { input = 0 }
        if output == 0x3FFF_FFFF { output = 0 }
        let records = Int(try r.u32())
        guard records <= 64 else { throw FlowDecodeError("sFlow : \(records) enregistrements dans un échantillon") }
        result.samplingRate = max(result.samplingRate ?? 0, rate)
        var packet: FlowPacketSummary?
        for _ in 0..<records {
            let format = try r.u32()
            let length = Int(try r.u32())
            var record = try r.sub(length)
            guard format >> 12 == 0 else { continue }
            switch format & 0xFFF {
            case 1:
                // En-tête brut : protocole, longueur de trame, octets retirés, longueur de l'en-tête.
                let headerProtocol = try record.u32()
                let frameLength = try record.u32()
                _ = try record.u32()
                let headerLength = Int(try record.u32())
                let header = Array(try record.take(min(headerLength, record.remaining)))
                if packet == nil, var summary = FlowPacketSummary.parse(header, headerProtocol: headerProtocol) {
                    summary.length = frameLength
                    packet = summary
                }
            case 3:
                // Résumé IPv4 (sampled_ipv4) : longueur, protocole, adresses, ports, drapeaux TCP.
                let length = try record.u32()
                let proto = try record.u32()
                let src = try record.ipv4()
                let dst = try record.ipv4()
                let srcPort = try record.u32()
                let dstPort = try record.u32()
                let flags = try record.u32()
                if packet == nil {
                    packet = FlowPacketSummary(length: length, src: src, dst: dst, ipv6: false, proto: UInt8(truncatingIfNeeded: proto),
                                               srcPort: UInt16(truncatingIfNeeded: srcPort), dstPort: UInt16(truncatingIfNeeded: dstPort),
                                               tcpFlags: UInt8(truncatingIfNeeded: flags))
                }
            default:
                continue
            }
        }
        guard let packet else { return }
        result.records.append(FlowRecord(kind: .sflow, exporter: exporter, domain: domain, source: packet.src, destination: packet.dst,
                                         isIPv6: packet.ipv6, sourcePort: packet.srcPort, destinationPort: packet.dstPort,
                                         proto: packet.proto, bytes: UInt64(packet.length), packets: 1,
                                         inputInterface: input == 0 ? nil : input, outputInterface: output == 0 ? nil : output,
                                         tcpFlags: packet.tcpFlags, samplingRate: max(1, rate)))
    }

    // MARK: Échantillons de compteurs

    private static func counterSample(_ r: inout FlowByteReader, expanded: Bool, exporter: IPv4Address,
                                      into result: inout FlowDecodeResult) throws {
        _ = try r.u32() // séquence
        try r.skip(expanded ? 8 : 4)
        let records = Int(try r.u32())
        guard records <= 64 else { throw FlowDecodeError("sFlow : \(records) enregistrements de compteurs") }
        for _ in 0..<records {
            let format = try r.u32()
            let length = Int(try r.u32())
            var record = try r.sub(length)
            // Compteurs génériques d'interface (0:1), 88 octets.
            guard format == 1, length >= 88 else { continue }
            let ifIndex = try record.u32()
            _ = try record.u32() // ifType
            let speed = try record.u64()
            _ = try record.u32() // ifDirection
            let status = try record.u32()
            let inOctets = try record.u64()
            try record.skip(12) // unicast, multicast, broadcast
            let inDiscards = try record.u32()
            let inErrors = try record.u32()
            try record.skip(4) // protocoles inconnus
            let outOctets = try record.u64()
            try record.skip(12)
            let outDiscards = try record.u32()
            let outErrors = try record.u32()
            // ifStatus : bit 0 ifAdminStatus, bit 1 ifOperStatus.
            result.counters.append(FlowInterfaceCounters(exporter: exporter, ifIndex: ifIndex, speed: speed, isUp: status & 0x2 != 0,
                                                         inOctets: inOctets, outOctets: outOctets, inErrors: inErrors, outErrors: outErrors,
                                                         inDiscards: inDiscards, outDiscards: outDiscards))
        }
    }
}

/// Ce que NetScope retient d'un paquet échantillonné.
struct FlowPacketSummary: Hashable {
    var length: UInt32
    var src: IPv4Address?
    var dst: IPv4Address?
    var ipv6: Bool
    var proto: UInt8
    var srcPort: UInt16
    var dstPort: UInt16
    var tcpFlags: UInt8

    /// En-tête Ethernet (1), IPv4 (11) ou IPv6 (12) ; VLAN 802.1Q et QinQ sautés.
    static func parse(_ header: [UInt8], headerProtocol: UInt32) -> FlowPacketSummary? {
        var offset = 0
        var etherType: UInt16
        switch headerProtocol {
        case 1:
            guard header.count >= 14 else { return nil }
            etherType = UInt16(header[12]) << 8 | UInt16(header[13])
            offset = 14
            while etherType == 0x8100 || etherType == 0x88A8 {
                guard header.count >= offset + 4 else { return nil }
                etherType = UInt16(header[offset + 2]) << 8 | UInt16(header[offset + 3])
                offset += 4
            }
        case 11: etherType = 0x0800
        case 12: etherType = 0x86DD
        default: return nil
        }
        switch etherType {
        case 0x0800:
            guard header.count >= offset + 20, header[offset] >> 4 == 4 else { return nil }
            let ihl = Int(header[offset] & 0x0F) * 4
            let total = UInt32(header[offset + 2]) << 8 | UInt32(header[offset + 3])
            let proto = header[offset + 9]
            let fragment = (UInt16(header[offset + 6]) << 8 | UInt16(header[offset + 7])) & 0x1FFF
            let src = IPv4Address(UInt32(flowUInt(header[(offset + 12)..<(offset + 16)])))
            let dst = IPv4Address(UInt32(flowUInt(header[(offset + 16)..<(offset + 20)])))
            var summary = FlowPacketSummary(length: total, src: src, dst: dst, ipv6: false, proto: proto, srcPort: 0, dstPort: 0, tcpFlags: 0)
            let l4 = offset + ihl
            // IHL inférieur à 5 (en-tête forgé ou corrompu) : pas de ports, ils seraient lus dans l'en-tête IP.
            if ihl >= 20, fragment == 0, proto == 6 || proto == 17, header.count >= l4 + 4 {
                summary.srcPort = UInt16(header[l4]) << 8 | UInt16(header[l4 + 1])
                summary.dstPort = UInt16(header[l4 + 2]) << 8 | UInt16(header[l4 + 3])
                if proto == 6, header.count >= l4 + 14 { summary.tcpFlags = header[l4 + 13] }
            }
            return summary
        case 0x86DD:
            guard header.count >= offset + 40 else { return nil }
            let proto = header[offset + 6]
            var summary = FlowPacketSummary(length: 0, src: nil, dst: nil, ipv6: true, proto: proto, srcPort: 0, dstPort: 0, tcpFlags: 0)
            let l4 = offset + 40
            if proto == 6 || proto == 17, header.count >= l4 + 4 {
                summary.srcPort = UInt16(header[l4]) << 8 | UInt16(header[l4 + 1])
                summary.dstPort = UInt16(header[l4 + 2]) << 8 | UInt16(header[l4 + 3])
            }
            return summary
        default:
            return nil
        }
    }
}
