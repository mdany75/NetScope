import Foundation

/// Sonde « Étendue DHCP presque pleine » (note 37) : elle lit la dernière lecture des étendues de
/// la FortiGate (aucun trafic propre ; l'application relit quand la lecture est plus vieille que
/// l'intervalle), ou à défaut l'estimation faite par le Test DHCP et le scan.
public enum MonDHCPScopeChecks {
    /// Étendues visées : « * » (ou « toutes ») pour toutes, sinon par interface (« vlan20 »), VLAN
    /// (« VLAN 20 », « 20 »), alias (« Invités ») ou nom affiché, éventuellement précédé du site
    /// (« Siège / vlan20 »).
    public static func targets(_ text: String, in overview: DHCPScopeOverview) -> [DHCPScopeUsage] {
        let t = text.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if t == "*" || lower == "toutes" || lower == "tous" { return overview.scopes }
        var site: String?
        var key = SearchText.fold(t)
        if let slash = t.firstIndex(of: "/"), !t.contains(".") {
            site = SearchText.fold(t[..<slash].trimmingCharacters(in: .whitespaces))
            key = SearchText.fold(t[t.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        }
        return overview.scopes.filter { scope in
            guard site == nil || SearchText.fold(scope.site) == site else { return false }
            var keys = [scope.interface, scope.displayName, scope.shortName].map(SearchText.fold)
            if let alias = scope.alias { keys.append(SearchText.fold(alias)) }
            if let vlan = scope.vlan { keys += ["\(vlan)", "vlan \(vlan)", "vlan\(vlan)"] }
            if let subnet = scope.subnet { keys.append(subnet.description) }
            return keys.contains(key)
        }
    }

    public static func check(target: String, overview: DHCPScopeOverview?, error: String? = nil,
                             thresholds: DHCPScopeThresholds, now: Date) -> MonRunOutcome {
        guard let overview, overview.readAt != nil, !overview.scopes.isEmpty else {
            if let error {
                return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Lecture impossible", error: error))
            }
            return .noData(now, "En attente d’une lecture de la FortiGate ou d’un Test DHCP")
        }
        let chosen = DHCPScopeAnalysis.relevel(targets(target, in: overview), thresholds: thresholds)
        guard !chosen.isEmpty else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Étendue introuvable",
                                                   problem: "Aucune étendue DHCP «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let active = chosen.filter { $0.level != .inactive }
        guard !active.isEmpty else { return .noData(now, chosen.count == 1 ? "Étendue désactivée" : "Étendues désactivées") }
        let prefix = overview.isEstimate ? "Estimation · " : ""
        let worst = active.max { ($0.level, $0.percent) < ($1.level, $1.percent) }!
        let value: String
        if active.count == 1 {
            value = prefix + "\(worst.percentLabel) · \(worst.free) libre\(worst.free > 1 ? "s" : "") sur \(worst.poolSize)"
        } else {
            value = prefix + "\(active.count) étendues · max \(worst.percentLabel) (\(worst.alertName))"
        }
        let alerting = active.filter { $0.level >= .warning }.sorted { ($0.level, $0.percent) > ($1.level, $1.percent) }
        guard let first = alerting.first, let text = DHCPScopeAnalysis.alertText(first) else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
        }
        let site = overview.isMultiSite ? " (\(first.site))" : ""
        let more = alerting.count > 1 ? " (et \(alerting.count - 1) autre\(alerting.count > 2 ? "s" : ""))" : ""
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: text + site + more))
    }
}
