import Darwin
import Foundation

/// Compteurs d'une interface de ce Mac (sysctl NET_RT_IFLIST2 : compteurs 64 bits de if_data64).
public struct LocalInterfaceCounters: Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// Nom BSD (« en0 »).
    public var name: String
    public var isUp: Bool
    /// Lien actif (IFF_RUNNING).
    public var isRunning: Bool
    public var counters: TrafficCounters
    public var inPackets: UInt64
    public var outPackets: UInt64

    public init(name: String, isUp: Bool, isRunning: Bool = true, counters: TrafficCounters, inPackets: UInt64 = 0, outPackets: UInt64 = 0) {
        self.name = name
        self.isUp = isUp
        self.isRunning = isRunning
        self.counters = counters
        self.inPackets = inPackets
        self.outPackets = outPackets
    }

    /// Interfaces montrées : Ethernet et Wi-Fi (en*) et ponts (bridge*) actifs qui ont un lien
    /// ou du trafic (les ports Thunderbolt vides sont écartés), tunnels VPN (utun*) qui reçoivent
    /// vraiment des données ; pas la boucle locale ni les interfaces internes d'Apple (awdl, llw, anpi…).
    public var isRelevant: Bool {
        guard isUp else { return false }
        let total = counters.inOctets &+ counters.outOctets
        if name.hasPrefix("en") || name.hasPrefix("bridge") { return isRunning && (total > 0 || counters.speedMbps != nil) }
        if name.hasPrefix("utun") { return counters.inOctets > 65_536 }
        return false
    }
}

/// Lecture locale des ressources de ce Mac : aucun trafic réseau (Mach, sysctl).
public enum LocalResources {
    /// Tics de chaque cœur (host_processor_info, PROCESSOR_CPU_LOAD_INFO).
    public static func cpuTicks() -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [CPUTicks] = []
        let stride = Int(CPU_STATE_MAX)
        for core in 0..<Int(count) {
            func value(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * stride + Int(state)])) }
            ticks.append(CPUTicks(user: value(CPU_STATE_USER), system: value(CPU_STATE_SYSTEM),
                                  idle: value(CPU_STATE_IDLE), nice: value(CPU_STATE_NICE)))
        }
        return ticks
    }

    /// Mémoire de ce Mac, comme le Moniteur d'activité (host_statistics64, sysctl).
    public static func memory() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let total: UInt64 = sysctlValue("hw.memsize") ?? 0
        guard total > 0 else { return nil }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64? = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : nil
        let level: Int32? = sysctlValue("kern.memorystatus_vm_pressure_level")
        let available: Int32? = sysctlValue("kern.memorystatus_level")
        return MemoryStats.mac(pageSize: UInt64(pageSize), totalBytes: total,
                               internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                               externalPages: UInt64(stats.external_page_count), wiredPages: UInt64(stats.wire_count),
                               compressorPages: UInt64(stats.compressor_page_count), swapUsedBytes: swapUsed,
                               pressureLevel: level.map(Int.init), memorystatusLevel: available.map(Int.init))
    }

    /// Nombre de cœurs de performance et d'efficacité (Apple silicon) ; nil ailleurs.
    public static func coreKinds() -> (performance: Int, efficiency: Int)? {
        let p: Int32? = sysctlValue("hw.perflevel0.logicalcpu")
        let e: Int32? = sysctlValue("hw.perflevel1.logicalcpu")
        guard let p, let e else { return nil }
        return (Int(p), Int(e))
    }

    /// Compteurs de toutes les interfaces (NET_RT_IFLIST2 : if_data64, compteurs 64 bits).
    public static func interfaces() -> [LocalInterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        // Marge : la table peut grandir entre les deux appels.
        length += 4096
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }
        var result: [LocalInterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = base.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let message = base.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let name = String(cString: nameBuffer)
                let data = message.ifm_data
                let flags = message.ifm_flags
                let speed = data.ifi_baudrate > 0 ? max(1, data.ifi_baudrate / 1_000_000) : nil
                let counters = TrafficCounters(inOctets: data.ifi_ibytes, outOctets: data.ifi_obytes, width: .bits64,
                                               inErrors: data.ifi_ierrors, outErrors: data.ifi_oerrors,
                                               inDiscards: data.ifi_iqdrops, outDiscards: nil, speedMbps: speed)
                result.append(LocalInterfaceCounters(name: name, isUp: flags & IFF_UP != 0, isRunning: flags & IFF_RUNNING != 0,
                                                     counters: counters, inPackets: data.ifi_ipackets, outPackets: data.ifi_opackets))
            }
        }
        return result
    }

    private static func sysctlValue<T: FixedWidthInteger>(_ name: String) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }
}
