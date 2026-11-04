import Foundation

/// Sondes Wi-Fi de la note 27 : elles lisent la dernière lecture Wi-Fi des FortiGate (aucun trafic
/// propre ; l'application relit la FortiGate quand la lecture est plus vieille que l'intervalle).
public enum MonFortiAPChecks {
    /// Bornes visées : « * » (ou « toutes ») pour toutes, sinon par nom, identifiant ou série,
    /// éventuellement précédé du site (« Siège / AP-ACCUEIL »).
    public static func targets(_ text: String, in overview: FortiWifiOverview) -> [FortiManagedAP] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "*" || t.lowercased() == "toutes" || t.lowercased() == "tous" { return overview.aps }
        var site: String?
        var key = t.lowercased()
        if let slash = t.firstIndex(of: "/") {
            site = t[..<slash].trimmingCharacters(in: .whitespaces).lowercased()
            key = t[t.index(after: slash)...].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return overview.aps.filter { ap in
            (site == nil || ap.site.lowercased() == site) && ap.keys.contains(key)
        }
    }

    public static func offline(target: String, overview: FortiWifiOverview?, now: Date) -> MonRunOutcome {
        guard let overview, overview.readAt != nil else {
            return .noData(now, "En attente d’une lecture de la FortiGate")
        }
        let aps = targets(target, in: overview)
        guard !aps.isEmpty else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Borne introuvable",
                                                   problem: "Aucune borne «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let down = aps.filter(\.isOffline)
        if aps.count == 1, let ap = aps.first {
            if ap.isOffline {
                return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "Hors ligne",
                                                       error: "\(ap.name) déconnectée de la FortiGate"))
            }
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "En ligne · \(ap.totalClients) client\(ap.totalClients > 1 ? "s" : "")"))
        }
        guard down.isEmpty else {
            let names = down.prefix(3).map(\.name).joined(separator: ", ") + (down.count > 3 ? "…" : "")
            return MonRunOutcome(result: MonResult(date: now, reachable: false, value: "\(down.count) hors ligne sur \(aps.count)",
                                                   error: "Bornes hors ligne\u{00A0}: \(names)"))
        }
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "\(aps.count) bornes en ligne"))
    }

    public static func overload(target: String, overview: FortiWifiOverview?, thresholds: FortiWifiThresholds, now: Date) -> MonRunOutcome {
        guard let overview, overview.readAt != nil else {
            return .noData(now, "En attente d’une lecture de la FortiGate")
        }
        let aps = targets(target, in: overview)
        guard !aps.isEmpty else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: "Borne introuvable",
                                                   problem: "Aucune borne «\u{00A0}\(target)\u{00A0}» dans la lecture de la FortiGate"))
        }
        let online = aps.filter { !$0.isOffline }
        guard !online.isEmpty else {
            return .noData(now, "Borne hors ligne")
        }
        let loads = FortiWifiAnalysis.overloaded(online, clients: overview.clients, thresholds: thresholds)
        let clients = online.reduce(0) { $0 + $1.totalClients }
        let busiest = online.flatMap(\.radios).compactMap(\.channelUtilization).max()
        var value = "\(clients) client\(clients > 1 ? "s" : "")"
        if let busiest { value += " · canal \(Int(busiest.rounded()))\u{00A0}%" }
        guard let first = loads.first else {
            return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value))
        }
        var reasons: [String] = []
        if first.tooManyClients { reasons.append("\(first.radio.clientCount ?? 0) clients") }
        if first.busyChannel, let u = first.radio.channelUtilization { reasons.append("canal à \(Int(u.rounded()))\u{00A0}%") }
        let band = first.radio.band?.label ?? "radio \(first.radio.radioID)"
        let more = loads.count > 1 ? " (et \(loads.count - 1) autre\(loads.count > 2 ? "s" : ""))" : ""
        return MonRunOutcome(result: MonResult(date: now, reachable: true, value: value,
                                               problem: "\(first.apName) surchargée en \(band)\u{00A0}: " + reasons.joined(separator: ", ") + more))
    }
}
