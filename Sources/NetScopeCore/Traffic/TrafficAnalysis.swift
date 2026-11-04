import Foundation

// Note 54 : calculs purs sur le trafic lu (aucun réseau) : fusion des sites, tri, charge des liens,
// « Qui sature le lien ? », applications inattendues, pays inhabituels, appareils menacés.

/// Charge d'un lien WAN.
public struct TrafficLinkUsage: Hashable, Sendable, Identifiable {
    public var link: TrafficLink
    /// Charge dans le sens le plus chargé (%), nil sans capacité connue.
    public var percent: Double?
    public var level: Level

    public enum Level: Int, Comparable, Sendable {
        case ok, warning, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String { link.id }
}

/// Un appareil qui charge le lien.
public struct TrafficConsumer: Hashable, Sendable, Identifiable {
    public var entry: TrafficEntry
    /// Part du trafic des sources du site (%).
    public var sharePercent: Double
    /// Part de la capacité du lien WAN du site (%), si connue.
    public var linkPercent: Double?
    /// Application principale de l'appareil (tirée des sessions).
    public var mainApplication: String?
    /// Destination principale (nom ou adresse).
    public var mainDestination: String?

    public var id: String { entry.id }
}

/// Réponse à « Qui sature le lien ? ».
public struct TrafficSaturationVerdict: Hashable, Sendable {
    /// Lien le plus chargé (nil sans lien WAN connu).
    public var link: TrafficLinkUsage?
    /// Plus gros consommateurs, du plus gros au plus petit.
    public var consumers: [TrafficConsumer]
    public var isSaturated: Bool
    /// Phrase de réponse (« Le lien wan1 du Siège est chargé à 96 % : … »).
    public var headline: String
    /// Explication et action conseillée.
    public var advice: String
}

public enum TrafficAnalysis {
    // MARK: Fusion

    /// Relevés de plusieurs sites réunis, dans l'ordre donné.
    public static func merge(_ sites: [TrafficSiteReport], period: TrafficPeriod) -> TrafficOverview {
        var overview = TrafficOverview(period: period)
        for site in sites {
            overview.entries += site.report.entries
            overview.sessions += site.report.sessions
            overview.links += site.report.links
            overview.sites.append(site.site)
            overview.readAt = max(overview.readAt ?? .distantPast, site.report.readAt)
            let prefix = sites.count > 1 ? site.site + "\u{00A0}: " : ""
            overview.notes += site.report.notes.map { prefix + $0 }
            for (view, status) in site.report.statuses {
                // La pire situation d'un site l'emporte (refusé > absent > vide > lu).
                let rank: [TrafficViewStatus: Int] = [.ok: 0, .empty: 1, .absent: 2, .failed: 3, .refused: 4]
                if let current = overview.statuses[view], rank[current, default: 0] >= rank[status, default: 0] { continue }
                overview.statuses[view] = status
            }
        }
        return overview
    }

    // MARK: Tri

    /// Lignes d'une vue triées par le critère (puis par octets, puis par nom).
    public static func sorted(_ entries: [TrafficEntry], by sort: TrafficSort) -> [TrafficEntry] {
        entries.sorted { a, b in
            switch sort {
            case .bandwidth where a.bandwidth != b.bandwidth: return a.bandwidth > b.bandwidth
            case .sessions where a.sessions != b.sessions: return a.sessions > b.sessions
            default:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
                if a.incidents != b.incidents { return a.incidents > b.incidents }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Mesure principale d'une ligne : le débit en temps réel, sinon les octets. `rates` : toutes
    /// les lignes comparées ont un débit (jamais des b/s comparés à des octets).
    static func weight(_ entry: TrafficEntry, rates: Bool) -> Double {
        rates ? entry.bandwidth : Double(entry.bytes)
    }

    /// Vrai si les débits servent à comparer ces lignes (temps réel, débit connu partout).
    static func usesRates(_ entries: [TrafficEntry], period: TrafficPeriod) -> Bool {
        period.isRealtime && !entries.isEmpty && entries.allSatisfy { $0.bandwidth > 0 }
    }

    // MARK: Liens

    public static func linkUsage(_ overview: TrafficOverview, thresholds: TrafficThresholds = .standard) -> [TrafficLinkUsage] {
        overview.wanLinks.map { link in
            let percent = link.utilization
            let level: TrafficLinkUsage.Level
            switch percent {
            case let p? where p >= thresholds.linkCriticalPercent: level = .critical
            case let p? where p >= thresholds.linkWarningPercent: level = .warning
            default: level = .ok
            }
            return TrafficLinkUsage(link: link, percent: percent, level: level)
        }
        .sorted { ($0.percent ?? -1) > ($1.percent ?? -1) }
    }

    // MARK: Consommateurs

    /// Plus gros consommateurs d'un ensemble de sources (part du total, part du lien du site).
    public static func consumers(_ overview: TrafficOverview, limit: Int = 5) -> [TrafficConsumer] {
        let sources = overview.entries(.sources)
        guard !sources.isEmpty else { return [] }
        // Débit ou octets : choisi par site (les sites ne se comparent qu'entre eux).
        var rates: [String: Bool] = [:]
        for (site, list) in Dictionary(grouping: sources, by: \.site) { rates[site] = usesRates(list, period: overview.period) }
        var totals: [String: Double] = [:]
        for entry in sources { totals[entry.site, default: 0] += weight(entry, rates: rates[entry.site] ?? false) }
        // Classement commun : la part du site d'abord (deux sites ne mélangent pas débits et octets).
        func share(_ entry: TrafficEntry) -> Double {
            let total = totals[entry.site] ?? 0
            return total > 0 ? weight(entry, rates: rates[entry.site] ?? false) / total * 100 : 0
        }
        // Même unité partout (débits, ou octets) : classement absolu ; sinon par part de chaque site.
        let sameUnit = Set(rates.values).count <= 1
        let ranked = sources.sorted { a, b in
            let (wa, wb) = (weight(a, rates: rates[a.site] ?? false), weight(b, rates: rates[b.site] ?? false))
            if a.site == b.site || sameUnit, wa != wb { return wa > wb }
            if share(a) != share(b) { return share(a) > share(b) }
            return a.id < b.id
        }
        return ranked.prefix(limit).map { entry in
            let share = share(entry)
            var linkPercent: Double?
            // Part du lien dans le sens dominant de l'appareil (une sauvegarde charge l'envoi).
            let uploads = entry.sentBytes > entry.receivedBytes
            if overview.period.isRealtime, entry.bandwidth > 0,
               let capacity = overview.wanLinks.filter({ $0.site == entry.site }).compactMap({ uploads ? $0.upCapacity : $0.downCapacity }).max(), capacity > 0 {
                linkPercent = min(100, entry.bandwidth / capacity * 100)
            }
            let (app, destination) = mainActivity(of: entry, in: overview)
            return TrafficConsumer(entry: entry, sharePercent: share, linkPercent: linkPercent, mainApplication: app, mainDestination: destination)
        }
    }

    /// Application et destination principales d'une source, d'après ses sessions.
    public static func mainActivity(of entry: TrafficEntry, in overview: TrafficOverview) -> (application: String?, destination: String?) {
        guard let ip = entry.ip else { return (nil, nil) }
        let mine = overview.sessions.filter { $0.site == entry.site && $0.source == ip }
        guard !mine.isEmpty else { return (nil, nil) }
        var apps: [String: UInt64] = [:]
        var destinations: [String: UInt64] = [:]
        for session in mine {
            if let app = session.application { apps[app, default: 0] &+= session.bytes }
            if let dst = session.destination?.description { destinations[dst, default: 0] &+= session.bytes }
        }
        let app = apps.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        var destination = destinations.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        // Nom de la destination quand la vue Destinations le connaît.
        if let address = destination,
           let named = overview.entries(.destinations).first(where: { $0.site == entry.site && $0.key == address && $0.hostname != nil }) {
            destination = named.hostname! + " (\(address))"
        }
        return (app, destination)
    }

    /// « Qui sature le lien ? » : le lien le plus chargé et ce qui le charge.
    public static func whoSaturates(_ overview: TrafficOverview, thresholds: TrafficThresholds = .standard) -> TrafficSaturationVerdict {
        let usages = linkUsage(overview, thresholds: thresholds)
        let top = usages.first
        // Consommateurs du site du lien le plus chargé (ou de tous les sites sans lien connu).
        var scoped = overview
        if let site = top?.link.site, overview.isMultiSite {
            scoped.entries = overview.entries.filter { $0.site == site }
            scoped.sessions = overview.sessions.filter { $0.site == site }
            scoped.links = overview.links.filter { $0.site == site }
        }
        let consumers = consumers(scoped, limit: 5)
        let nbsp = "\u{00A0}"
        let siteSuffix = overview.isMultiSite ? (top.map { " (\($0.link.site))" } ?? "") : ""
        guard let first = consumers.first else {
            return TrafficSaturationVerdict(link: top, consumers: [], isSaturated: (top?.level ?? .ok) >= .warning,
                                            headline: "Aucune source de trafic lue \(overview.period.span).",
                                            advice: "Relisez la FortiGate (droit «\(nbsp)FortiView\(nbsp)» en lecture) ou choisissez une autre période.")
        }
        let who = describe(first)
        let saturated = (top?.level ?? .ok) >= .warning
        var headline: String
        if let top, let percent = top.percent {
            headline = "Le lien \(top.link.label)\(siteSuffix) est chargé à \(ResourceFormat.percent(percent))"
            headline += saturated ? "\(nbsp): \(who) en est la première cause." : "\(nbsp): il n’est pas saturé. Premier consommateur\(nbsp): \(who)."
        } else {
            headline = "Premier consommateur \(overview.period.span)\(nbsp): \(who)."
        }
        var advice = "\(first.entry.name) représente \(ResourceFormat.percent(first.sharePercent)) du trafic des appareils"
        if let link = first.linkPercent { advice += " et \(ResourceFormat.percent(link)) de la capacité du lien" }
        advice += "."
        if let app = first.mainApplication { advice += " Application principale\(nbsp): \(app)." }
        if let destination = first.mainDestination { advice += " Destination principale\(nbsp): \(destination)." }
        if saturated {
            advice += isBackup(first.mainApplication) || isBackup(first.mainDestination)
                ? " Une sauvegarde ou une synchronisation vers le nuage occupe le lien\(nbsp): planifiez-la hors des heures ouvrables ou limitez son débit (régulateur de trafic «\(nbsp)traffic shaper\(nbsp)» de la FortiGate)."
                : " Vérifiez avec l’utilisateur si ce transfert est attendu\(nbsp); au besoin, limitez son débit par une politique de régulation de trafic sur la FortiGate."
        }
        return TrafficSaturationVerdict(link: top, consumers: consumers, isSaturated: saturated, headline: headline, advice: advice)
    }

    /// « Poste comptabilité (10.182.122.117) ».
    public static func describe(_ consumer: TrafficConsumer) -> String {
        let entry = consumer.entry
        let address = entry.ip?.description ?? entry.key
        return entry.name == address ? address : "\(entry.name) (\(address))"
    }

    static func isBackup(_ text: String?) -> Bool {
        guard let text = text.map(SearchText.fold) else { return false }
        return ["backup", "sauvegarde", "onedrive", "dropbox", "icloud", "google.drive", "google drive", "backblaze", "veeam",
                "acronis", "carbonite", "box", "sync", "s3", "wasabi"].contains { text.contains($0) }
    }

    // MARK: Applications et pays

    /// Catégories d'applications rarement voulues en entreprise.
    public static let riskyCategories = ["p2p", "proxy", "remote.access", "remote access", "game", "games", "jeux", "botnet",
                                         "malicious", "malware", "tor", "cryptomining", "crypto.mining", "bittorrent"]

    /// Applications inattendues : risque élevé (4 ou 5) ou catégorie à risque (mots entiers :
    /// « Storage.Backup » ne contient pas « tor »).
    public static func unexpectedApplications(_ overview: TrafficOverview) -> [TrafficEntry] {
        overview.entries(.applications).filter { entry in
            if (entry.risk ?? 0) >= 4 { return true }
            let folded = SearchText.fold((entry.category ?? "") + " " + entry.name)
            let words = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return riskyCategories.contains { category in
                category.contains(".") || category.contains(" ") ? folded.contains(category) : words.contains(category)
            }
        }
        .sorted { ($0.risk ?? 0, $0.bytes) > ($1.risk ?? 0, $1.bytes) }
    }

    /// Pays hors de la liste attendue (destinations ou vue Pays), par volume.
    public static func unusualCountries(_ overview: TrafficOverview, thresholds: TrafficThresholds = .standard) -> [(country: String, site: String, bytes: UInt64)] {
        let expected = Set(thresholds.expectedCountries.map(SearchText.fold))
        var totals: [String: (site: String, bytes: UInt64)] = [:]
        for entry in overview.entries(.destinations) {
            guard let country = entry.country, !expected.contains(SearchText.fold(country)) else { continue }
            let key = entry.site + "|" + country
            totals[key] = (entry.site, (totals[key]?.bytes ?? 0) &+ entry.bytes)
        }
        return totals.map { (country: String($0.key.split(separator: "|", maxSplits: 1).last ?? ""), site: $0.value.site, bytes: $0.value.bytes) }
            .sorted { $0.bytes == $1.bytes ? $0.country < $1.country : $0.bytes > $1.bytes }
    }

    // MARK: Menaces

    /// Menaces, de la plus grave à la moins grave.
    public static func threats(_ overview: TrafficOverview) -> [TrafficEntry] {
        overview.entries(.threats).sorted {
            ($0.threatLevel ?? .info, -$0.incidents, $0.name) < ($1.threatLevel ?? .info, -$1.incidents, $1.name)
        }
    }

    /// Appareils visés par au moins une menace de niveau moyen ou plus (« possiblement infectés »).
    public static func threatenedDevices(_ overview: TrafficOverview) -> [(site: String, ip: IPv4Address, name: String, threats: [TrafficEntry])] {
        var groups: [String: [TrafficEntry]] = [:]
        for entry in overview.entries(.threats) where entry.ip != nil && (entry.threatLevel ?? .info) <= .medium {
            groups[entry.site + "|" + entry.ip!.description, default: []].append(entry)
        }
        return groups.values.compactMap { list in
            guard let first = list.first, let ip = first.ip else { return nil }
            let name = first.hostname
                ?? overview.entries(.sources).first { $0.site == first.site && $0.ip == ip }?.name
                ?? ip.description
            return (first.site, ip, name, list.sorted { ($0.threatLevel ?? .info) < ($1.threatLevel ?? .info) })
        }
        .sorted { ($0.threats.first?.threatLevel ?? .info, $0.ip) < ($1.threats.first?.threatLevel ?? .info, $1.ip) }
    }

    // MARK: Totaux

    /// Débit total des liens WAN (réception, émission), en bits par seconde.
    public static func wanRates(_ overview: TrafficOverview) -> (rx: Double, tx: Double) {
        overview.wanLinks.reduce((0, 0)) { ($0.0 + $1.rxBps, $0.1 + $1.txBps) }
    }
}

/// Mise en forme du trafic (typographie française).
public enum TrafficFormat {
    public static func bytes(_ value: UInt64) -> String { SNMPFormat.bytes(value) }
    public static func rate(_ bps: Double) -> String { bps > 0 ? ResourceFormat.bitsPerSecond(bps) : "—" }

    /// « 1 h 12 min », « 45 s ».
    public static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        if seconds < 60 { return "\(seconds)\u{00A0}s" }
        if seconds < 3600 { return "\(seconds / 60)\u{00A0}min" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
    }

    /// « Élevé (4/5) ».
    public static func risk(_ value: Int?) -> String {
        guard let value else { return "—" }
        let label: String
        switch value {
        case 5: label = "Critique"
        case 4: label = "Élevé"
        case 3: label = "Moyen"
        case 2: label = "Faible"
        default: label = "Très faible"
        }
        return "\(label) (\(value)/5)"
    }
}
