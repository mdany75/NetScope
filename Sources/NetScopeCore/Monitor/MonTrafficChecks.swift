import Foundation

/// Sondes de trafic (note 54) : elles lisent la dernière lecture FortiView des FortiGate (aucun
/// trafic propre ; l'application relit quand la lecture est plus vieille que l'intervalle).
/// - « Lien saturé » : charge d'un lien WAN au-delà du seuil (%) ;
/// - « Appareil qui consomme trop » : débit d'un appareil au-delà du seuil (Mb/s) ;
/// - « Nouvelle menace » : menace jamais vue (base apprise au premier passage).
public enum MonTrafficChecks {
    public static func run(_ probe: MonProbe, target: String, traffic: TrafficOverview?, error: String?, now: Date) -> MonRunOutcome {
        guard let traffic, traffic.readAt != nil, !traffic.isEmpty else {
            if let error {
                return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Lecture impossible", error: error))
            }
            return .noData(now, "En attente d’une lecture FortiView de la FortiGate")
        }
        let limit = probe.resourceLimit ?? MonProbe.defaultResourceLimit(probe.kind)
        switch probe.kind {
        case .linkSaturated: return linkSaturated(target: target, traffic: traffic, limit: limit, now: now)
        case .heavyDevice: return heavyDevice(target: target, traffic: traffic, limitMbps: limit, now: now)
        case .newThreat:
            return newThreat(target: target, traffic: traffic, known: probe.knownThreats, now: now)
        default: return MonRunOutcome(result: .failure(now, error: "Type de sonde inattendu"))
        }
    }

    static func isAll(_ target: String) -> Bool {
        let t = target.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "*" || t == "tous" || t == "toutes" || t.isEmpty
    }

    /// « Siège / wan1 » → (« siège », « wan1 ») ; « wan1 » → (nil, « wan1 »).
    static func split(_ target: String) -> (site: String?, name: String) {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let slash = t.firstIndex(of: "/") {
            return (SearchText.fold(t[..<slash].trimmingCharacters(in: .whitespaces)),
                    t[t.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        }
        return (nil, t)
    }

    // MARK: Lien saturé

    static func linkSaturated(target: String, traffic: TrafficOverview, limit: Double, now: Date) -> MonRunOutcome {
        let thresholds = TrafficThresholds(linkWarningPercent: limit, linkCriticalPercent: max(limit, 95))
        var usages = TrafficAnalysis.linkUsage(traffic, thresholds: thresholds)
        if !isAll(target) {
            let (site, name) = split(target)
            let wanted = SearchText.fold(name)
            usages = usages.filter { usage in
                (site == nil || SearchText.fold(usage.link.site) == site)
                    && (SearchText.fold(usage.link.name) == wanted || SearchText.fold(usage.link.alias ?? "") == wanted)
            }
            guard !usages.isEmpty else {
                return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Lien introuvable",
                                                       problem: "Aucun lien WAN «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
            }
        }
        let measured = usages.filter { $0.percent != nil }
        guard let worst = measured.first else {
            return .noData(now, usages.isEmpty ? "Aucun lien WAN lu" : "Capacité du lien inconnue")
        }
        let multi = traffic.isMultiSite
        let value = "\(worst.link.name)\(multi ? " (\(worst.link.site))" : "") · \(ResourceFormat.percent(worst.percent ?? 0))"
        guard (worst.percent ?? 0) >= limit else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
        }
        let verdict = TrafficAnalysis.whoSaturates(traffic, thresholds: thresholds)
        var problem = "Lien \(worst.link.label)\(multi ? " (\(worst.link.site))" : "") chargé à \(ResourceFormat.percent(worst.percent ?? 0))"
        if let top = verdict.consumers.first, verdict.link?.id == worst.id {
            problem += "\u{00A0}: \(TrafficAnalysis.describe(top))" + (top.mainApplication.map { ", \($0)" } ?? "")
        }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: problem))
    }

    // MARK: Appareil qui consomme trop

    /// Débit d'une source : mesuré en temps réel, sinon moyenne sur la période.
    static func rate(_ entry: TrafficEntry, period: TrafficPeriod) -> Double {
        if entry.bandwidth > 0 { return entry.bandwidth }
        guard let seconds = period.seconds, seconds > 0 else { return 0 }
        return Double(entry.bytes) * 8 / seconds
    }

    static func heavyDevice(target: String, traffic: TrafficOverview, limitMbps: Double, now: Date) -> MonRunOutcome {
        var sources = traffic.entries(.sources)
        if !isAll(target) {
            let (site, name) = split(target)
            let wanted = SearchText.fold(name)
            sources = sources.filter { entry in
                (site == nil || SearchText.fold(entry.site) == site)
                    && (entry.ip?.description == name || SearchText.fold(entry.name) == wanted
                        || entry.mac.map { $0.formatted(.upperColon).lowercased() == name.lowercased() } == true)
            }
            guard !sources.isEmpty else {
                return .noData(now, "Appareil absent du trafic lu")
            }
        }
        guard let top = sources.max(by: { rate($0, period: traffic.period) < rate($1, period: traffic.period) }) else {
            return .noData(now, "Aucune source de trafic lue")
        }
        let measured = rate(top, period: traffic.period)
        let label = top.ip.map { top.name == $0.description ? $0.description : "\(top.name) (\($0))" } ?? top.name
        let value = (isAll(target) ? label + " · " : "") + ResourceFormat.bitsPerSecond(measured)
        guard measured / 1_000_000 >= limitMbps else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
        }
        let (app, _) = TrafficAnalysis.mainActivity(of: top, in: traffic)
        let problem = "\(label)\(traffic.isMultiSite ? " (\(top.site))" : "") consomme \(ResourceFormat.bitsPerSecond(measured))"
            + (app.map { " (\($0))" } ?? "") + ", au-delà de \(MonFormat.number(limitMbps))\u{00A0}Mb/s"
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: problem))
    }

    // MARK: Nouvelle menace

    /// Clé stable d'une menace : site, nom et appareil.
    public static func threatKey(_ entry: TrafficEntry) -> String {
        "\(entry.site)|\(entry.name)|\(entry.ip?.description ?? "")"
    }

    static func newThreat(target: String, traffic: TrafficOverview, known: [String]?, now: Date) -> MonRunOutcome {
        var threats = TrafficAnalysis.threats(traffic)
        if !isAll(target) {
            let wanted = SearchText.fold(target.trimmingCharacters(in: .whitespaces))
            threats = threats.filter { SearchText.fold($0.site) == wanted }
        }
        let keys = Set(threats.map(threatKey))
        guard let known else {
            var outcome = MonRunOutcome(result: MonResult(date: now, reachable: true,
                                                          value: "Base\u{00A0}: \(keys.count) menace\(keys.count > 1 ? "s" : "") connue\(keys.count > 1 ? "s" : "")"))
            outcome.knownThreats = keys.sorted()
            return outcome
        }
        let knownSet = Set(known)
        let fresh = threats.filter { !knownSet.contains(threatKey($0)) }
        let blocked = threats.filter(\.isBlocked).count
        let value = "\(threats.count) menace\(threats.count > 1 ? "s" : "") · \(blocked) bloquée\(blocked > 1 ? "s" : "")"
        guard let first = fresh.first else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
        }
        let device = first.ip.map { ip in first.hostname.map { "\($0) (\(ip))" } ?? ip.description }
        var problem = "Nouvelle menace\u{00A0}: \(first.name)"
        let details = [first.threatType, first.threatLevel?.label.lowercased()].compactMap { $0 }
        if !details.isEmpty { problem += " (" + details.joined(separator: ", ") + ")" }
        if let device { problem += " sur \(device)" }
        if traffic.isMultiSite { problem += " · \(first.site)" }
        problem += first.isBlocked ? ", bloquée" : ", NON bloquée"
        if fresh.count > 1 { problem += " (et \(fresh.count - 1) autre\(fresh.count > 2 ? "s" : ""))" }
        var outcome = MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: problem))
        outcome.knownThreats = Array(knownSet.union(keys)).sorted()
        return outcome
    }
}
