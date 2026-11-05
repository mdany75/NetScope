import Foundation
import NetScopeCore

/// Ressources de démonstration (note 21), cohérentes avec DemoData et SwitchDemo : ce Mac
/// (Mac mini, 10 cœurs, 32 Go, Wi-Fi en0 et Ethernet en7), SW-CORE-01, SW-ETG2-01, l'imprimante
/// de l'accueil et le contrôleur de domaine. Valeurs réalistes et reproductibles ; aucun accès réseau.
@MainActor
enum ResourceDemo {
    /// Pas des courbes de démonstration (secondes) et durée remplie.
    private static let localStep: Double = 2
    private static let snmpStep: Double = 10
    private static let window: Double = 300

    /// Bruit reproductible dans [-1, 1] (aucun hasard : captures identiques).
    static func noise(_ seed: Int, _ step: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ step &* 40_503 &+ 97)
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        return Double(x % 2001) / 1000 - 1
    }

    /// Courbe douce autour de `base`, avec bruit et éventuel pic.
    static func wave(_ seed: Int, _ step: Int, base: Double, amplitude: Double, jitter: Double,
                     spike: (at: Int, width: Int, height: Double)? = nil) -> Double {
        var value = base + amplitude * sin(Double(step) / 9 + Double(seed)) + jitter * noise(seed, step)
        if let spike, abs(step - spike.at) <= spike.width {
            value += spike.height * (1 - Double(abs(step - spike.at)) / Double(spike.width + 1))
        }
        return value
    }

    private static var localStepIndex = 0
    private static var snmpStepIndex: [String: Int] = [:]

    // MARK: Ce Mac

    private static let cores = 10
    private static let memoryTotal: UInt64 = 32 * 1_073_741_824

    private static func localValues(_ step: Int) -> (cpu: CPULoad, memory: MemoryStats, rates: [String: (Double, Double)]) {
        var perCore: [Double] = []
        for core in 0..<cores {
            // Cœurs de performance (0 à 5) plus chargés que les cœurs d'efficacité.
            let base = core < 6 ? 26.0 - Double(core) * 3 : 9.0
            perCore.append(min(100, max(1, wave(core + 3, step, base: base, amplitude: 7, jitter: 6,
                                                spike: (at: 105, width: 6, height: core < 4 ? 55 : 20)))))
        }
        let total = perCore.reduce(0, +) / Double(cores)
        let cpu = CPULoad(total: total, user: total * 0.68, system: total * 0.32, perCore: perCore)
        let gb = 1_073_741_824.0
        let app = (13.1 + 0.4 * sin(Double(step) / 20)) * gb
        let memory = MemoryStats(totalBytes: memoryTotal, usedBytes: UInt64(app + 3.9 * gb + 4.4 * gb),
                                 appBytes: UInt64(app), wiredBytes: UInt64(3.9 * gb), compressedBytes: UInt64(4.4 * gb),
                                 cachedBytes: UInt64(8.2 * gb), swapUsedBytes: UInt64(0.5 * gb), pressure: .normal,
                                 pressurePercent: 28 + 2 * sin(Double(step) / 15))
        let en0In = max(0.2e6, wave(11, step, base: 18e6, amplitude: 6e6, jitter: 4e6, spike: (at: 120, width: 8, height: 160e6)))
        let en0Out = max(0.1e6, wave(12, step, base: 2.1e6, amplitude: 0.8e6, jitter: 0.6e6))
        let en7In = max(0.05e6, wave(13, step, base: 1.2e6, amplitude: 0.4e6, jitter: 0.3e6))
        let en7Out = max(0.05e6, wave(14, step, base: 0.6e6, amplitude: 0.2e6, jitter: 0.2e6))
        let vpnIn = max(0, wave(15, step, base: 0.35e6, amplitude: 0.1e6, jitter: 0.1e6))
        let vpnOut = max(0, wave(16, step, base: 0.12e6, amplitude: 0.05e6, jitter: 0.04e6))
        return (cpu, memory, ["en0": (en0In, en0Out), "en7": (en7In, en7Out), "utun4": (vpnIn, vpnOut)])
    }

    private static func localInterfaces(_ rates: [String: (Double, Double)], seconds: Double) -> [LocalInterfaceLoad] {
        let specs: [(String, String, UInt64?, UInt64, UInt64)] = [
            ("en0", "Wi-Fi", 866, 48_200_000_000, 6_310_000_000),
            ("en7", "Ethernet", 1000, 3_950_000_000, 1_120_000_000),
            ("utun4", "VPN", nil, 412_000_000, 98_000_000),
        ]
        return specs.map { name, kind, speed, inTotal, outTotal in
            let r = rates[name] ?? (0, 0)
            let counters = TrafficCounters(inOctets: inTotal, outOctets: outTotal, width: .bits64,
                                           inErrors: name == "en0" ? 3 : 0, outErrors: 0, inDiscards: 0, speedMbps: speed)
            let rate = TrafficRate(inBitsPerSecond: r.0, outBitsPerSecond: r.1,
                                   inPercent: ResourceMath.linkPercent(bitsPerSecond: r.0, speedMbps: speed),
                                   outPercent: ResourceMath.linkPercent(bitsPerSecond: r.1, speedMbps: speed),
                                   newErrors: 0, newDiscards: 0, seconds: seconds)
            return LocalInterfaceLoad(name: name, kind: kind, counters: counters, rate: rate)
        }
    }

    private static func localSample(_ step: Int, date: Date) -> (ResourceSample, CPULoad, MemoryStats, [LocalInterfaceLoad]) {
        let values = localValues(step)
        var sample: [String: Double] = ["cpu": values.cpu.total, "mem": values.memory.usedPercent,
                                        "pression": values.memory.pressurePercent ?? 0]
        for (name, rate) in values.rates {
            sample["\(name).in"] = rate.0
            sample["\(name).out"] = rate.1
        }
        // Disques : lecture qui monte avec la pointe du processeur (compilation), écriture régulière.
        let wave = sin(Double(step) / 9)
        let read = 40_000_000 + 30_000_000 * max(0, wave) + (values.cpu.total > 40 ? 180_000_000 : 0)
        let write = 18_000_000 + 8_000_000 * cos(Double(step) / 7)
        sample["disque.lecture"] = read
        sample["disque.ecriture"] = write
        sample["disque"] = min(100, 6 + read / 4_000_000)
        return (ResourceSample(date: date, values: sample), values.cpu, values.memory, localInterfaces(values.rates, seconds: localStep))
    }

    private static var localTitles: [String: String] {
        var titles: [String: String] = [:]
        for name in ["en0", "en7", "utun4"] {
            titles["\(name).in"] = "\(name) entrée (b/s)"
            titles["\(name).out"] = "\(name) sortie (b/s)"
        }
        return titles
    }

    static func fillLocal(_ monitor: LocalResourceMonitor) {
        let now = demoNow
        let count = Int(window / localStep)
        var last: (ResourceSample, CPULoad, MemoryStats, [LocalInterfaceLoad])?
        for step in 0...count {
            let sample = localSample(step, date: now.addingTimeInterval(-Double(count - step) * localStep))
            monitor.record(sample.0, titles: localTitles)
            last = sample
        }
        localStepIndex = count
        if let last { monitor.set(cpu: last.1, memory: last.2, interfaces: last.3, coreKinds: (6, 4), disks: demoDisks) }
    }

    static func advanceLocal(_ monitor: LocalResourceMonitor) {
        localStepIndex += 1
        let sample = localSample(localStepIndex, date: Date())
        monitor.record(sample.0, titles: localTitles)
        monitor.set(cpu: sample.1, memory: sample.2, interfaces: sample.3, coreKinds: (6, 4))
    }

    /// Disques de démonstration : le SSD interne au travail, un disque externe presque au repos.
    static let demoDisks: [LocalDiskLoad] = {
        let zero = DiskIOCounters(bytesRead: 0, bytesWritten: 0, readNanoseconds: 0, writeNanoseconds: 0)
        return [LocalDiskLoad(snapshot: DiskIOSnapshot(bsdName: "disk0", name: "APPLE SSD AP1024Z", isInternal: true, counters: zero),
                              rate: DiskIORate(readBytesPerSecond: 85_200_000, writeBytesPerSecond: 22_400_000, busyPercent: 27)),
                LocalDiskLoad(snapshot: DiskIOSnapshot(bsdName: "disk4", name: "LaCie Rugged (Photos)", isInternal: false, counters: zero),
                              rate: DiskIORate(readBytesPerSecond: 1_300_000, writeBytesPerSecond: 0, busyPercent: 2))]
    }()

    /// Heure des captures : 14 h 32, comme la barre de menus du croquis ; sinon l'heure réelle.
    private static var demoNow: Date {
        guard CommandLine.arguments.contains("--snapshot") else { return Date() }
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 14, minute: 32, second: 0, of: Date()) ?? Date()
    }

    // MARK: Agents SNMP

    private struct Agent {
        var processor: SNMPProcessorReading?
        var memory: SNMPMemoryReading?
        var ports: [SNMPPortCounters]
        /// Débit moyen (entrée, sortie) en b/s par ifIndex.
        var rates: [Int: (Double, Double)]
    }

    private static func agent(_ host: String, step: Int) -> Agent? {
        let gb: UInt64 = 1_073_741_824
        if let snapshot = SwitchStore.shared.snapshots[host] {
            let isCore = snapshot.system.name == "SW-CORE-01"
            var rates: [Int: (Double, Double)] = [:]
            var ports: [SNMPPortCounters] = []
            for iface in snapshot.interfaces where iface.isPhysical {
                let i = iface.index
                let speed = Double((iface.speedMbps ?? 1000) * 1_000_000)
                var shareIn = 0.002 + 0.01 * abs(noise(i, 1))
                var shareOut = 0.004 + 0.015 * abs(noise(i, 2))
                if isCore {
                    switch i {
                    case 1: shareIn = 0.31; shareOut = 0.38          // pare-feu : Internet
                    case 47: shareIn = 0.24; shareOut = 0.62         // uplink vers l'étage 2
                    case 40: shareIn = 0.18; shareOut = 0.27         // contrôleur de domaine
                    case 12: shareIn = 0.06; shareOut = 0.11         // borne Wi-Fi
                    case 33, 34: shareIn = 0.008; shareOut = 0.009   // caméras (flux vers l'enregistreur)
                    case 18: shareIn = 0.71; shareOut = 0.22         // 100 Mb/s, erreurs : presque saturé
                    default: break
                    }
                } else {
                    switch i {
                    case 25: shareIn = 0.012; shareOut = 0.009       // uplink 10 Gb/s vers le cœur
                    case 4, 5, 6: shareIn = 0.002; shareOut = 0.009  // caméras
                    case 9: shareIn = 0.04; shareOut = 0.003         // affichage dynamique
                    default: break
                    }
                }
                let factor = 1 + 0.18 * sin(Double(step) / 7 + Double(i)) + 0.08 * noise(i, step)
                let r = iface.isUp ? (speed * shareIn * factor, speed * shareOut * factor) : (0, 0)
                rates[i] = r
                let counters = TrafficCounters(inOctets: (iface.inOctets ?? 0) &+ UInt64(r.0 / 8 * snmpStep * Double(step)),
                                               outOctets: (iface.outOctets ?? 0) &+ UInt64(r.1 / 8 * snmpStep * Double(step)),
                                               width: .bits64, inErrors: iface.inErrors, outErrors: 0,
                                               inDiscards: i == 47 && isCore ? 214 : 0, outDiscards: i == 47 && isCore ? 1_032 : 0,
                                               speedMbps: iface.isUp ? iface.speedMbps : nil)
                ports.append(SNMPPortCounters(index: i, name: iface.name, alias: iface.alias, type: iface.type, isUp: iface.isUp, counters: counters))
            }
            let cpu = isCore ? 9 + 3 * sin(Double(step) / 6) + 2 * noise(1, step) : 6 + 2 * sin(Double(step) / 5) + noise(2, step)
            let processor = SNMPProcessorReading(load: CPULoad(total: cpu, perCore: [cpu]),
                                                 source: isCore ? "CISCO-PROCESS-MIB" : "HP-SWITCH-MIB")
            let total: UInt64 = isCore ? 8 * gb : gb
            let used = Double(total) * (isCore ? 0.38 : 0.52)
            let memory = SNMPMemoryReading(memory: MemoryStats(totalBytes: total, usedBytes: UInt64(used)),
                                           source: isCore ? "CISCO-MEMORY-POOL-MIB" : "HP-SWITCH-MIB")
            return Agent(processor: processor, memory: memory, ports: ports, rates: rates)
        }
        switch host {
        case "10.182.122.111":
            // Brother DCP-L2640DW : un processeur, 256 Mo, une interface 1 Gb/s.
            let cpu = max(1, 4 + 2 * sin(Double(step) / 4) + 1.5 * noise(3, step) + (step % 18 == 6 ? 31 : 0))
            let rate = (max(2e3, 9e3 + 6e3 * noise(4, step) + (step % 18 == 6 ? 2.4e6 : 0)), max(1e3, 4e3 + 3e3 * noise(5, step)))
            let port = SNMPPortCounters(index: 1, name: "eth0", alias: "", type: 6, isUp: true,
                                        counters: TrafficCounters(inOctets: 1_284_000_000, outOctets: 312_000_000, width: .bits32,
                                                                  inErrors: 0, outErrors: 0, inDiscards: 0, outDiscards: 0, speedMbps: 1000))
            return Agent(processor: SNMPProcessorReading(load: CPULoad(total: cpu, perCore: [cpu]), source: "HOST-RESOURCES-MIB"),
                         memory: SNMPMemoryReading(memory: MemoryStats(totalBytes: 256 * 1_048_576, usedBytes: 164 * 1_048_576),
                                                   source: "HOST-RESOURCES-MIB"),
                         ports: [port], rates: [1: rate])
        case "10.10.0.10":
            // SRV-AD-01 (Windows Server) : 8 processeurs, 32 Go, deux cartes 10 Gb/s.
            let loads = (0..<8).map { core in Int(max(2, wave(core + 20, step, base: 22, amplitude: 6, jitter: 8))) }
            let processor = SNMPProcessorReading(load: CPULoad.fromPercentages(loads)!, source: "HOST-RESOURCES-MIB")
            let memory = SNMPMemoryReading(memory: MemoryStats(totalBytes: 32 * gb, usedBytes: UInt64(Double(32 * gb) * 0.71)),
                                           source: "HOST-RESOURCES-MIB")
            let ports = [
                SNMPPortCounters(index: 12, name: "Ethernet0", alias: "LAN serveurs", type: 6, isUp: true,
                                 counters: TrafficCounters(inOctets: 9_120_000_000_000, outOctets: 14_800_000_000_000,
                                                           inErrors: 0, outErrors: 0, inDiscards: 0, outDiscards: 0, speedMbps: 10_000)),
                SNMPPortCounters(index: 13, name: "Ethernet1", alias: "Sauvegarde", type: 6, isUp: true,
                                 counters: TrafficCounters(inOctets: 220_000_000_000, outOctets: 3_100_000_000_000,
                                                           inErrors: 0, outErrors: 0, inDiscards: 0, outDiscards: 0, speedMbps: 10_000)),
            ]
            return Agent(processor: processor, memory: memory, ports: ports,
                         rates: [12: (wave(30, step, base: 180e6, amplitude: 40e6, jitter: 30e6), wave(31, step, base: 270e6, amplitude: 60e6, jitter: 40e6)),
                                 13: (wave(32, step, base: 2e6, amplitude: 1e6, jitter: 1e6), wave(33, step, base: 8e6, amplitude: 3e6, jitter: 2e6))])
        default:
            return nil
        }
    }

    private static func loads(_ agent: Agent, seconds: Double) -> [PortLoad] {
        agent.ports.map { port in
            let r = agent.rates[port.index] ?? (0, 0)
            let speed = port.counters.speedMbps
            let rate = TrafficRate(inBitsPerSecond: port.isUp ? r.0 : nil, outBitsPerSecond: port.isUp ? r.1 : nil,
                                   inPercent: ResourceMath.linkPercent(bitsPerSecond: r.0, speedMbps: speed),
                                   outPercent: ResourceMath.linkPercent(bitsPerSecond: r.1, speedMbps: speed),
                                   newErrors: port.index == 18 && port.name.hasPrefix("Gi") ? 7 : 0,
                                   newDiscards: port.index == 47 && port.name.hasPrefix("Gi") ? 12 : 0, seconds: seconds)
            return PortLoad(index: port.index, name: port.name, alias: port.alias, isUp: port.isUp, speedMbps: speed,
                            rate: rate, counters: port.counters)
        }
    }

    private static func values(_ agent: Agent) -> (values: [String: Double], titles: [String: String]) {
        var values: [String: Double] = [:]
        var titles: [String: String] = [:]
        if let cpu = agent.processor?.load.total { values["cpu"] = cpu }
        if let mem = agent.memory?.memory.usedPercent { values["mem"] = mem }
        for port in agent.ports where port.isUp {
            let r = agent.rates[port.index] ?? (0, 0)
            values["if\(port.index).in"] = r.0
            values["if\(port.index).out"] = r.1
            titles["if\(port.index).in"] = "\(port.name) entrée (b/s)"
            titles["if\(port.index).out"] = "\(port.name) sortie (b/s)"
        }
        return (values, titles)
    }

    /// Remplit l'historique d'un agent connu ; faux si l'appareil ne répond pas en SNMP dans la démonstration.
    @discardableResult
    static func fillSNMP(_ monitor: SNMPResourceMonitor) -> Bool {
        let now = demoNow
        let count = Int(window / snmpStep)
        var timeline = ResourceTimeline(window: window)
        timeline.declare([ResourceColumn(id: "cpu", title: "Processeur (%)"), ResourceColumn(id: "mem", title: "Mémoire utilisée (%)")])
        var last: Agent?
        for step in 0...count {
            guard let agent = agent(monitor.host, step: step) else { return false }
            let v = values(agent)
            timeline.append(ResourceSample(date: now.addingTimeInterval(-Double(count - step) * snmpStep), values: v.values), titles: v.titles)
            last = agent
        }
        guard let last else { return false }
        snmpStepIndex[monitor.host] = count
        monitor.setDemo(processor: last.processor, memory: last.memory, ports: last.ports, loads: loads(last, seconds: snmpStep),
                        timeline: timeline, lastPoll: now, v3User: demoV3User)
        return true
    }

    /// Les agents de démonstration sont au Siège : son utilisateur SNMP v3 propre (SNMPAccessDemo).
    static var demoV3User: String? { SNMPAccessDemo.perSite[SitesDemo.siegeID]?.user }

    static func advanceSNMP(_ monitor: SNMPResourceMonitor) {
        let step = (snmpStepIndex[monitor.host] ?? 0) + 1
        snmpStepIndex[monitor.host] = step
        guard let agent = agent(monitor.host, step: step) else { return }
        var timeline = monitor.timeline
        let v = values(agent)
        timeline.append(ResourceSample(date: Date(), values: v.values), titles: v.titles)
        monitor.setDemo(processor: agent.processor, memory: agent.memory, ports: agent.ports, loads: loads(agent, seconds: snmpStep),
                        timeline: timeline, lastPoll: Date(), v3User: demoV3User)
    }
}
