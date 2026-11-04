import Foundation

/// Sondes WAN de la note 39 : « Tunnel VPN tombé » et « Lien WAN dégradé ». Elles lisent la
/// dernière lecture du WAN des FortiGate (aucun trafic propre ; l'application relit quand la
/// lecture est plus vieille que l'intervalle).
public enum MonWANChecks {
    /// Cible : « * » (ou « tous ») pour tout, sinon un nom (tunnel, interface, alias), précédé ou
    /// non du site (« Siège / VPN-QUEBEC », « Siège / * »). Renvoie le site voulu (replié) et la clé.
    static func parse(_ text: String) -> (site: String?, key: String?) {
        let t = text.trimmingCharacters(in: .whitespaces)
        var site: String?
        var key = t
        if let slash = t.firstIndex(of: "/"), !t.contains(".") {
            site = SearchText.fold(t[..<slash].trimmingCharacters(in: .whitespaces))
            key = t[t.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        }
        let folded = SearchText.fold(key)
        let all = folded.isEmpty || folded == "*" || ["tous", "toutes", "tout"].contains(folded)
        return (site, all ? nil : folded)
    }

    /// Tunnels visés (les serveurs d'accès distant sans client ne comptent pas pour « * »).
    public static func tunnels(_ text: String, in overview: WANOverview) -> [WANTunnelUsage] {
        let (site, key) = parse(text)
        return overview.tunnels.filter { usage in
            guard site == nil || SearchText.fold(usage.site) == site else { return false }
            guard let key else { return usage.state != .idle && usage.tunnel.parent == nil }
            var keys = [usage.tunnel.name].map(SearchText.fold)
            if let c = usage.tunnel.comments { keys.append(SearchText.fold(c)) }
            if let gw = usage.tunnel.remoteGateway { keys.append(gw) }
            return keys.contains(key)
        }
    }

    /// Liens visés (les liens désactivés ne comptent pas pour « * »).
    public static func links(_ text: String, in overview: WANOverview) -> [WANLinkUsage] {
        let (site, key) = parse(text)
        return overview.links.filter { usage in
            guard site == nil || SearchText.fold(usage.site) == site else { return false }
            guard let key else { return usage.state != .disabled }
            var keys = [usage.interface.name, usage.interface.displayName].map(SearchText.fold)
            if let alias = usage.interface.alias { keys.append(SearchText.fold(alias)) }
            return keys.contains(key)
        }
    }

    static func unread(_ overview: WANOverview?, error: String?, now: Date) -> MonRunOutcome? {
        if let overview, overview.readAt != nil, !overview.sites.isEmpty { return nil }
        if let error {
            return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Lecture impossible", error: error))
        }
        return .noData(now, "En attente d’une lecture de la FortiGate")
    }

    /// Sites visés par la cible dont la lecture a échoué (« Siège / wan1 » : Siège seulement ;
    /// « * » ou un nom sans site : tous).
    static func failedSites(_ target: String, siteErrors: [String: String]) -> [(site: String, message: String)] {
        let site = parse(target).site
        return siteErrors.filter { site == nil || SearchText.fold($0.key) == site }
            .map { (site: $0.key, message: $0.value) }
            .sorted { $0.site < $1.site }
    }

    /// Lecture impossible pour un site visé : la sonde le dit au lieu de rester verte sur les autres
    /// sites ou de répondre « introuvable ». Une panne constatée ailleurs garde la priorité.
    static func withSiteErrors(_ outcome: MonRunOutcome, target: String, siteErrors: [String: String], now: Date) -> MonRunOutcome {
        let failed = failedSites(target, siteErrors: siteErrors)
        guard !failed.isEmpty else { return outcome }
        if !outcome.noData && !outcome.result.reachable { return outcome }
        let (site, key) = parse(target)
        // Nom sans site trouvé dans une lecture réussie : le site en erreur n'est pas en cause.
        if site == nil, key != nil, !outcome.noData, !["Tunnel introuvable", "Lien introuvable"].contains(outcome.result.value) {
            return outcome
        }
        let message = failed.map { failed.count > 1 || site == nil ? "\($0.site)\u{00A0}: \($0.message)" : $0.message }
            .joined(separator: " ")
        return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Lecture impossible", error: message))
    }

    static func siteSuffix(_ site: String, _ overview: WANOverview) -> String {
        overview.isMultiSite ? " (\(site))" : ""
    }

    public static func tunnelDown(target: String, overview: WANOverview?, error: String? = nil,
                                  siteErrors: [String: String] = [:], now: Date) -> MonRunOutcome {
        withSiteErrors(tunnelState(target: target, overview: overview, error: error, now: now),
                       target: target, siteErrors: siteErrors, now: now)
    }

    static func tunnelState(target: String, overview: WANOverview?, error: String?, now: Date) -> MonRunOutcome {
        if let pending = unread(overview, error: error, now: now) { return pending }
        guard let overview else { return .noData(now, "En attente d’une lecture de la FortiGate") }
        let chosen = tunnels(target, in: overview)
        guard !chosen.isEmpty else {
            if parse(target).key == nil { return .noData(now, "Aucun tunnel IPsec configuré") }
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Tunnel introuvable",
                                                   problem: "Aucun tunnel «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let down = chosen.filter { $0.state == .down }.sorted { $0.tunnel.name < $1.tunnel.name }
        let partial = chosen.filter { $0.state == .partial }
        let up = chosen.filter { $0.state == .up }.count
        let counted = chosen.filter { $0.state != .idle }.count
        let value = counted == 1 ? (chosen.first { $0.state != .idle }?.state.label ?? "En attente")
            : "\(up) monté\(up > 1 ? "s" : "") sur \(counted)"
        if let first = down.first, let text = WANAnalysis.alertText(first) {
            let more = down.count > 1 ? " (et \(down.count - 1) autre\(down.count > 2 ? "s" : ""))" : ""
            return MonRunOutcome(result: MonResult(date: now, reachable: false, value: value,
                                                   error: text + siteSuffix(first.site, overview) + more))
        }
        if let first = partial.first, let text = WANAnalysis.alertText(first) {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: text + siteSuffix(first.site, overview)))
        }
        if counted == 0 { return .noData(now, "Serveur d’accès distant sans client") }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
    }

    public static func wanDegraded(target: String, overview: WANOverview?, error: String? = nil,
                                   siteErrors: [String: String] = [:], thresholds: WANThresholds, now: Date) -> MonRunOutcome {
        withSiteErrors(linkState(target: target, overview: overview, error: error, thresholds: thresholds, now: now),
                       target: target, siteErrors: siteErrors, now: now)
    }

    static func linkState(target: String, overview: WANOverview?, error: String?,
                          thresholds: WANThresholds, now: Date) -> MonRunOutcome {
        if let pending = unread(overview, error: error, now: now) { return pending }
        guard var overview else { return .noData(now, "En attente d’une lecture de la FortiGate") }
        // Seuils propres à la sonde : les liens sont réévalués avec eux.
        overview.links = overview.links.map { link in
            var next = link
            let e = WANAnalysis.evaluate(link.interface, health: link.measures, config: overview.healthConfigs[link.controllerID] ?? [],
                                         thresholds: thresholds)
            next.state = e.state
            next.reasons = e.reasons
            return next
        }
        let chosen = links(target, in: overview)
        guard !chosen.isEmpty else {
            if parse(target).key == nil { return .noData(now, "Aucun lien WAN dans la lecture") }
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Lien introuvable",
                                                   problem: "Aucun lien WAN «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let active = chosen.filter { $0.state != .disabled }
        guard !active.isEmpty else { return .noData(now, "Lien désactivé") }
        var parts: [String] = []
        if active.count > 1 {
            let up = active.filter { $0.state == .up || $0.state == .degraded }.count
            parts.append("\(up) actif\(up > 1 ? "s" : "") sur \(active.count)")
        } else {
            parts.append(active[0].state.label)
        }
        if let latency = active.compactMap(\.latencyMs).max() { parts.append(WANFormat.ms(latency)) }
        if let loss = active.compactMap(\.lossPercent).max() { parts.append("perte " + WANFormat.loss(loss)) }
        let value = parts.joined(separator: " · ")
        let down = active.filter { $0.state == .down }
        if let first = down.first, let text = WANAnalysis.alertText(first) {
            let more = down.count > 1 ? " (et \(down.count - 1) autre\(down.count > 2 ? "s" : ""))" : ""
            return MonRunOutcome(result: MonResult(date: now, reachable: false, value: value, error: text + siteSuffix(first.site, overview) + more))
        }
        let degraded = active.filter { $0.state == .degraded }.sorted { ($0.lossPercent ?? 0) > ($1.lossPercent ?? 0) }
        if let first = degraded.first, let text = WANAnalysis.alertText(first) {
            let more = degraded.count > 1 ? " (et \(degraded.count - 1) autre\(degraded.count > 2 ? "s" : ""))" : ""
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value, problem: text + siteSuffix(first.site, overview) + more))
        }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
    }
}
