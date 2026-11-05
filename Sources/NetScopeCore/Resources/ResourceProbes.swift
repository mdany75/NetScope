import Foundation

/// Sondes de Surveillance « Processeur > X % », « Mémoire > X % » et « Port saturé > X % »
/// (notes 3 et 21) : ce Mac par lecture locale, sinon l'agent SNMP de la cible.
public enum MonResourceChecks {
    /// Délai entre les deux relevés d'un compteur (processeur de ce Mac, octets d'un port).
    public static let sampleDelay: TimeInterval = 3

    /// Vrai si la cible désigne ce Mac (« ce Mac », « localhost », 127.0.0.1). « mac » seul n'en
    /// fait pas partie : ce peut être le nom d'un autre hôte.
    public static func isLocal(_ target: String) -> Bool {
        let text = target.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
        return ["ce mac", "localhost", "127.0.0.1", "ce-mac"].contains(text)
    }

    public static func run(_ probe: MonProbe, target: String, context: MonRunContext) async -> MonResult {
        let now = context.now
        let local = isLocal(target)
        switch probe.kind {
        case .cpu:
            if local {
                let first = LocalResources.cpuTicks()
                try? await Task.sleep(nanoseconds: UInt64(sampleDelay * 1_000_000_000))
                guard let load = CPUMath.load(previous: first, current: LocalResources.cpuTicks()) else {
                    return .failure(now, error: "Lecture du processeur impossible")
                }
                return evaluateCPU(probe, load: load, source: nil, now: now)
            }
            return await withAgent(probe, host: target, context: context) { poller in
                guard let reading = try await poller.processor() else {
                    return .failure(now, error: "l’agent ne donne pas la charge du processeur (HOST-RESOURCES-MIB absente)")
                }
                return evaluateCPU(probe, load: reading.load, source: reading.source, now: now)
            }
        case .memory:
            if local {
                guard let memory = LocalResources.memory() else { return .failure(now, error: "Lecture de la mémoire impossible") }
                return evaluateMemory(probe, memory: memory, now: now)
            }
            return await withAgent(probe, host: target, context: context) { poller in
                guard let reading = try await poller.memory() else {
                    return .failure(now, error: "l’agent ne donne pas la mémoire (hrStorageRam absente)")
                }
                return evaluateMemory(probe, memory: reading.memory, now: now)
            }
        case .portLoad:
            guard let portName = probe.resourcePort?.trimmingCharacters(in: .whitespaces), !portName.isEmpty else {
                return .failure(now, error: "Port à choisir")
            }
            if local {
                func read() -> LocalInterfaceCounters? {
                    LocalResources.interfaces().first { $0.name.lowercased() == portName.lowercased() }
                }
                guard let first = read() else { return .failure(now, error: "Interface \(portName) introuvable sur ce Mac") }
                let start = Date()
                try? await Task.sleep(nanoseconds: UInt64(sampleDelay * 1_000_000_000))
                guard let second = read() else { return .failure(now, error: "Interface \(portName) disparue") }
                let rate = ResourceMath.rate(from: first.counters, to: second.counters, seconds: Date().timeIntervalSince(start))
                return evaluatePort(probe, port: portName, rate: rate, speedMbps: second.counters.speedMbps, now: now)
            }
            return await withAgent(probe, host: target, context: context) { poller in
                guard let index = try await poller.findPort(portName) else {
                    return .failure(now, error: "port «\u{00A0}\(portName)\u{00A0}» introuvable sur l’agent")
                }
                guard let first = try await poller.port(index) else { return .failure(now, error: "compteurs du port absents") }
                let start = Date()
                try? await Task.sleep(nanoseconds: UInt64(sampleDelay * 1_000_000_000))
                guard let second = try await poller.port(index) else { return .failure(now, error: "compteurs du port absents") }
                let rate = ResourceMath.rate(from: first.counters, to: second.counters, seconds: Date().timeIntervalSince(start))
                return evaluatePort(probe, port: second.name, rate: rate, speedMbps: second.counters.speedMbps,
                                    isUp: second.isUp, now: now)
            }
        default:
            return .failure(now, error: "Type de sonde inattendu")
        }
    }

    private static func withAgent(_ probe: MonProbe, host: String, context: MonRunContext,
                                  _ body: (SNMPResourcePoller) async throws -> MonResult) async -> MonResult {
        guard !(context.snmpCommunity ?? "").isEmpty || context.snmpV3 != nil else {
            return .failure(context.now, error: MonRunContext.missingSNMPCredentials)
        }
        guard let address = try? await PingResolver.resolveAsync(host) else {
            return .failure(context.now, error: "Nom introuvable\u{00A0}: \(host)")
        }
        guard let target = context.snmpTarget(address) else {
            return .failure(context.now, error: MonRunContext.missingSNMPCredentials)
        }
        let poller = SNMPResourcePoller(target: target)
        do {
            return try await body(poller)
        } catch {
            return .failure(context.now, error: error.localizedDescription)
        }
    }

    // MARK: Évaluation (pure, testée)

    public static func evaluateCPU(_ probe: MonProbe, load: CPULoad, source: String?, now: Date) -> MonResult {
        let limit = probe.resourceLimit ?? MonProbe.defaultResourceLimit(.cpu)
        let value = "Processeur \(ResourceFormat.percent(load.total))"
            + (load.perCore.count > 1 ? " · \(load.perCore.count) cœurs" : "")
        let problem = load.total > limit
            ? "Processeur à \(ResourceFormat.percent(load.total)) > \(MonFormat.percent(limit))" : nil
        return MonResult(date: now, reachable: true, value: value, problem: problem)
    }

    public static func evaluateMemory(_ probe: MonProbe, memory: MemoryStats, now: Date) -> MonResult {
        let limit = probe.resourceLimit ?? MonProbe.defaultResourceLimit(.memory)
        var value = "Mémoire \(ResourceFormat.percent(memory.usedPercent)) · \(ResourceFormat.memory(memory.usedBytes)) / \(ResourceFormat.memory(memory.totalBytes))"
        if let pressure = memory.pressure, pressure != .normal { value += " · pression \(pressure.label.lowercased())" }
        var problem: String?
        if memory.usedPercent > limit {
            problem = "Mémoire utilisée à \(ResourceFormat.percent(memory.usedPercent)) > \(MonFormat.percent(limit))"
        } else if memory.pressure == .critical {
            problem = "Pression mémoire critique"
        }
        return MonResult(date: now, reachable: true, value: value, problem: problem)
    }

    public static func evaluatePort(_ probe: MonProbe, port: String, rate: TrafficRate, speedMbps: UInt64?,
                                    isUp: Bool = true, now: Date) -> MonResult {
        let limit = probe.resourceLimit ?? MonProbe.defaultResourceLimit(.portLoad)
        guard isUp else {
            return MonResult(date: now, reachable: false, value: "\(port) inactif", error: "port \(port) inactif")
        }
        guard rate.inBitsPerSecond != nil || rate.outBitsPerSecond != nil else {
            return MonResult(date: now, reachable: true, value: "\(port) · compteur remis à zéro, mesure suivante")
        }
        var value = "\(port) ↓\u{00A0}\(ResourceFormat.bitsPerSecond(rate.inBitsPerSecond)) ↑\u{00A0}\(ResourceFormat.bitsPerSecond(rate.outBitsPerSecond))"
        guard let peak = rate.peakPercent else {
            return MonResult(date: now, reachable: true, value: value + " · vitesse du lien inconnue")
        }
        value += " · \(ResourceFormat.percent(peak)) de \(SNMPFormat.speed(mbps: speedMbps))"
        var problem: String?
        if peak > limit {
            let direction = (rate.inPercent ?? 0) >= (rate.outPercent ?? 0) ? "en entrée" : "en sortie"
            problem = "\(port) saturé \(direction)\u{00A0}: \(ResourceFormat.percent(peak)) du lien > \(MonFormat.percent(limit))"
        }
        if let errors = rate.newErrors, errors > 0 {
            let text = "\(errors) nouvelle\(errors > 1 ? "s" : "") erreur\(errors > 1 ? "s" : "") sur \(port)"
            problem = problem.map { $0 + " · " + text } ?? text
        }
        return MonResult(date: now, reachable: true, value: value, problem: problem)
    }
}
