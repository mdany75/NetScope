import Foundation

// Notes 96 et 97 : sondes « Serveur DHCP pirate », « Conflit d’adresse IP » et « Borne Wi-Fi
// pirate ». Le DHCPDISCOVER est fourni par l'application (jamais en démonstration) ; les conflits et
// les bornes sont calculés par l'application à partir des relevés déjà faits.

public enum MonPirateChecks {
    static func run(_ probe: MonProbe, target: String, context: MonRunContext) async -> MonRunOutcome {
        switch probe.kind {
        case .rogueDHCP:
            guard let discover = context.rogueDHCPDiscover else { return .noData(context.now, "Envoi DHCP indisponible") }
            switch await discover(target) {
            case .failure(let error) where error.isUnavailable:
                return .noData(context.now, error.message)
            case .failure(let error):
                return MonRunOutcome(result: .failure(context.now, error: error.message))
            case .success(let offers):
                let vendor = context.vendorOf ?? { _ in nil }
                let findings = RogueDHCPAnalyzer.findings(offers, policy: context.rogueDHCPPolicy, vendor: vendor)
                return MonRunOutcome(result: RogueDHCPAnalyzer.monitorResult(findings, now: context.now))
            }
        case .ipConflict:
            // Les relevés (ARP de ce Mac, scan, Inventaire) sont ceux du site actif : un autre site
            // n'est pas vérifiable ici, ce n'est pas « Aucun conflit ».
            if let active = context.activeSiteName, !isAllSites(target),
               active.compare(target.trimmingCharacters(in: .whitespaces), options: FrenchOrder.options, range: nil,
                              locale: FrenchOrder.locale) != .orderedSame {
                return .noData(context.now, "Site non actif")
            }
            guard let conflicts = context.ipConflicts else { return .noData(context.now, "En attente d’un scan") }
            return MonRunOutcome(result: conflictResult(filter(conflicts, target: target), now: context.now))
        case .rogueAP:
            guard let findings = context.rogueAPs else { return .noData(context.now, "En attente d’une lecture de la FortiGate") }
            return MonRunOutcome(result: RogueAPAnalyzer.monitorResult(RogueAPAnalyzer.filter(findings, target: target), now: context.now))
        default:
            return .noData(context.now, "Type de sonde inattendu")
        }
    }

    static func isAllSites(_ target: String) -> Bool {
        let t = target.trimmingCharacters(in: .whitespaces)
        return t == "*" || t.isEmpty || t.lowercased() == "tous"
    }

    static func filter(_ conflicts: [IPConflict], target: String) -> [IPConflict] {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !isAllSites(t) else { return conflicts }
        return conflicts.filter { $0.site.compare(t, options: FrenchOrder.options, range: nil, locale: FrenchOrder.locale) == .orderedSame }
    }

    /// Panne pour une IP à deux MAC ou des réponses contradictoires, alerte pour une MAC instable.
    public static func conflictResult(_ conflicts: [IPConflict], now: Date) -> MonResult {
        let critical = conflicts.filter(\.isCritical)
        let unstable = conflicts.count - critical.count
        guard !conflicts.isEmpty else { return MonResult(date: now, reachable: true, value: "Aucun conflit") }
        let value = "\(critical.count) conflit\(critical.count > 1 ? "s" : "")" + (unstable > 0 ? " · \(unstable) MAC instable\(unstable > 1 ? "s" : "")" : "")
        if !critical.isEmpty {
            let names = critical.prefix(3).compactMap { $0.ip?.description }.joined(separator: ", ")
            return MonResult(date: now, reachable: false, value: value, error: "Conflit d’adresse IP\u{00A0}: \(names)")
        }
        let macs = conflicts.prefix(3).compactMap { $0.macs.first?.formatted(.upperColon) }.joined(separator: ", ")
        let ips = conflicts.prefix(3).compactMap { $0.ip?.description }.joined(separator: ", ")
        let text = conflicts.contains { $0.kind == .macInstable } ? "MAC qui change souvent d’IP\u{00A0}: \(macs)"
            : "IP partagée par des appareils Apple (proxy de veille Bonjour probable)\u{00A0}: \(ips)"
        return MonResult(date: now, reachable: true, value: value, problem: text)
    }
}
