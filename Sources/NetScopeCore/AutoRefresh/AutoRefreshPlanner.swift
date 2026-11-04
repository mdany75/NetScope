import Foundation

// Note 29 : planificateur de la relecture automatique (pur, sans horloge ni réseau : l'heure est
// toujours donnée). Il dit quand relire chaque partie, met en pause (site non actif, scan, veille,
// hors réseau, action requise), espace les essais après une erreur (délai croissant) et évite les
// doublons : une lecture faite ailleurs (bouton, fin de scan, Surveillance) repousse la suivante,
// et jamais deux lectures à la fois vers la même FortiGate.

public enum AutoRefreshPlanner {
    /// Une partie due dans les 30 s est relue avec celle qui l'est déjà (une seule tournée).
    public static let coalesceWindow: TimeInterval = 30
    /// Lecture en cours ailleurs : nouveau coup d'œil dans 15 s.
    public static let inFlightRetry: TimeInterval = 15
    /// Délai croissant plafonné à 1 h (ou à l'intervalle s'il est plus long).
    public static let maxBackoff: TimeInterval = 3600
    /// Après le réveil ou le retour du réseau, 30 s pour rejoindre le réseau avant de relire.
    public static let resumeDelay: TimeInterval = 30

    /// Attente avant le prochain essai : l'intervalle, puis le double à chaque échec de suite
    /// (5 min : 10, 20, 40, puis 60 min), plafonné à `maxBackoff`.
    public static func backoff(failures: Int, interval: TimeInterval) -> TimeInterval {
        guard interval > 0 else { return 0 }
        guard failures > 0 else { return interval }
        let doubled = interval * pow(2, Double(min(failures, 12)))
        return min(doubled, max(maxBackoff, interval))
    }

    /// Prochaine relecture d'une partie. `anchor` : début du suivi du site (site activé, app
    /// lancée) ; une partie jamais lue attend un intervalle complet après lui, sans rafale au
    /// lancement.
    public static func nextDue(_ track: AutoRefreshTrack, interval: TimeInterval, anchor: Date) -> Date {
        if track.failures > 0 {
            return (track.lastAttempt ?? anchor).addingTimeInterval(backoff(failures: track.failures, interval: interval))
        }
        // Un essai plus récent que la dernière lecture (abandonné) compte aussi : pas de boucle.
        var base = track.lastRead ?? anchor
        if let attempt = track.lastAttempt, attempt > base { base = attempt }
        return base.addingTimeInterval(interval)
    }

    /// Décision à l'instant `now`.
    public static func decide(now: Date, interval: AutoRefreshInterval, anchor: Date, conditions: AutoRefreshConditions,
                              tracks: [AutoRefreshPart: AutoRefreshTrack]) -> AutoRefreshDecision {
        guard interval.isOn else { return .paused(.disabled) }
        guard conditions.siteIsActive else { return .paused(.notActiveSite) }
        if conditions.asleep { return .paused(.asleep) }
        if !conditions.online { return .paused(.offline) }
        if conditions.scanning { return .paused(.scanning) }
        if let resume = conditions.resumeAfter, resume > now { return .paused(.resuming(until: resume)) }

        let candidates = tracks.filter(\.value.available)
        guard !candidates.isEmpty else { return .paused(.nothingToRead) }
        let ready = candidates.filter { $0.value.blockedReason == nil }
        guard !ready.isEmpty else {
            let first = candidates.sorted { $0.key < $1.key }.first?.value.blockedReason ?? ""
            return .paused(.needsAttention(first))
        }

        // Une lecture vers la FortiGate en cours (bouton, scan, Surveillance) bloque les autres
        // parties lues par elle : une seule lecture à la fois par FortiGate.
        let fortiBusy = tracks.contains { $0.key.usesFortiGate && $0.value.inFlight }
        func blocked(_ part: AutoRefreshPart, _ track: AutoRefreshTrack) -> Bool {
            track.inFlight || (part.usesFortiGate && fortiBusy)
        }
        let free = ready.filter { !blocked($0.key, $0.value) }
        guard !free.isEmpty else {
            return .wait(until: now.addingTimeInterval(inFlightRetry), retrying: false, failures: 0)
        }

        let dues = free.mapValues { nextDue($0, interval: interval.seconds, anchor: anchor) }
        let dueNow = dues.filter { $0.value <= now }
        if !dueNow.isEmpty {
            let horizon = now.addingTimeInterval(coalesceWindow)
            return .read(Set(dues.filter { $0.value <= horizon }.keys))
        }
        // Prochaine : la plus proche ; « nouvel essai » si c'est une partie en erreur.
        let soonest = dues.min { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }!
        let failures = free[soonest.key]?.failures ?? 0
        return .wait(until: soonest.value, retrying: failures > 0, failures: failures)
    }

    /// Heure à laquelle réévaluer la décision (au plus tard 30 s plus tard : la veille, le réseau
    /// ou un bouton peuvent tout changer entre-temps).
    public static func wakeUp(after decision: AutoRefreshDecision, now: Date, maxSleep: TimeInterval = 30) -> Date {
        let limit = now.addingTimeInterval(maxSleep)
        guard let next = decision.nextDate else { return limit }
        return min(max(next, now.addingTimeInterval(1)), limit)
    }
}

// MARK: - Switchs SNMP relus

public enum AutoRefreshTargets {
    /// Switchs SNMP relus automatiquement : jamais un switch d'un autre site, dont la communauté
    /// partirait en clair vers l'appareil qui porte la même adresse ici. Avec un site actif : ses
    /// switchs associés, et ceux sans site déjà relevés pour ce site. Sans site actif : ceux sans
    /// site, relevés sans site, dans les plages du dernier scan. Jamais un FortiSwitch (lu par la
    /// FortiGate).
    /// - Parameter readingSites: site actif au moment du dernier relevé réussi de chaque switch.
    public static func snmpHosts(_ hosts: [String], controllerHosts: Set<String>, activeSite: Site?, sites: [Site],
                                 readingSites: [String: String], scanRanges: [IPRange]) -> [String] {
        let activeKey = SiteFiles.key(for: activeSite?.id)
        var seen = Set<String>()
        return hosts.filter { host in
            guard seen.insert(host).inserted, !controllerHosts.contains(host), IPv4Address(host) != nil else { return false }
            let owners = sites.filter { $0.switchHosts.contains(host) }
            if let site = activeSite {
                if owners.contains(where: { $0.id == site.id }) { return true }
                guard owners.isEmpty else { return false }
                return readingSites[host] == activeKey
            }
            guard owners.isEmpty, readingSites[host] == activeKey, let ip = IPv4Address(host), !scanRanges.isEmpty else { return false }
            return ScanRelevance.contains(scanRanges, ip)
        }
    }
}

// MARK: - Textes

public enum AutoRefreshText {
    /// « à l’instant », « il y a 2 min », « il y a 1 h 05 », « il y a 3 j ».
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "à l’instant" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "il y a \(minutes)\u{00A0}min" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "il y a \(hours)\u{00A0}h" : "il y a \(hours)\u{00A0}h\u{00A0}\(String(format: "%02d", rest))"
        }
        return "il y a \(hours / 24)\u{00A0}j"
    }

    /// « dans moins d’une minute », « dans 3 min », « dans 1 h 05 ».
    public static func until(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "dans moins d’une minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "dans \(minutes)\u{00A0}min" }
        let rest = minutes % 60
        return rest == 0 ? "dans \(minutes / 60)\u{00A0}h" : "dans \(minutes / 60)\u{00A0}h\u{00A0}\(String(format: "%02d", rest))"
    }

    /// « Relu il y a 2 min · prochaine dans 3 min » ; « Pas encore relu · … » ;
    /// « Relu il y a 8 min · erreur, nouvel essai dans 12 min » ; « … · en pause pendant le scan ».
    public static func status(lastRead: Date?, decision: AutoRefreshDecision, reading: Bool, now: Date) -> String {
        let head = lastRead.map { "Relu " + ago($0, now: now) } ?? "Pas encore relu"
        if reading { return head + " · relecture en cours…" }
        switch decision {
        case .paused(let pause):
            return head + " · " + pause.label
        case .wait(let date, let retrying, _):
            return head + " · " + (retrying ? "erreur, nouvel essai " : "prochaine ") + until(date, now: now)
        case .read:
            return head + " · relecture en cours…"
        }
    }
}
