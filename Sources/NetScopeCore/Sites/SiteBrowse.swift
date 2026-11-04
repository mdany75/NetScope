import Foundation

// 0.15.0, notes 49 et 48 (demandes de Dany) :
//
// - note 49 : un sélecteur de site unique sous le logo NetScope (recherche, pastille d'état de la
//   FortiGate du site, titre de la fenêtre) ;
// - note 48 : un menu « Site ▾ » dans Switchs et ports et dans Wi-Fi, qui montre les switchs et le
//   Wi-Fi d'un autre site (ou de plusieurs) SANS changer le site actif.
//
// Règles : pas de niveau Client ; plusieurs sites peuvent avoir les mêmes plages ; jamais de
// fusion entre deux sites. Un relevé SNMP n'appartient qu'au site pour lequel il a été fait (la
// même adresse de gestion peut désigner deux switchs chez deux clients) ; les FortiSwitch et le
// Wi-Fi d'un site viennent des seules FortiGate de ce site. Aucun accès réseau ici.

// MARK: - Sélecteur de site (note 49)

public enum SitePicker {
    /// Texte de recherche d'un site : nom, notes, plages, libellés et VLAN, plié (sans accents ni majuscules).
    public static func searchText(_ site: Site) -> String {
        var parts = [site.displayName, site.notes]
        for range in site.ranges {
            parts.append(range.text)
            parts.append(range.label)
            if let vlan = range.vlan { parts.append("vlan \(vlan)") }
        }
        return SearchText.foldedJoined(parts)
    }

    /// Sites qui correspondent à la recherche, dans l'ordre reçu : chaque mot doit se trouver
    /// dans le nom, les notes, une plage, un libellé ou « vlan N ». Recherche vide : tous.
    public static func filter(_ sites: [Site], query: String) -> [Site] {
        let words = SearchText.fold(query).split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return sites }
        return sites.filter { site in
            let text = searchText(site)
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Sous-titre de la fenêtre : « Site : Siège », ou « Aucun site (plages libres) ».
    public static func windowSubtitle(activeName: String?) -> String {
        guard let name = activeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "Aucun site (plages libres)"
        }
        return "Site\u{00A0}: \(name)"
    }

    /// Site suivant ou précédent dans la liste filtrée (flèches du sélecteur) : `current` absent,
    /// la première ligne ; on s'arrête aux bords.
    public static func step(from current: UUID?, in ids: [UUID], by offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return offset < 0 ? ids.last : ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}

/// Ce que l'app sait d'une FortiGate d'un site, pour la pastille du sélecteur.
public struct SiteFortiGateProbe: Hashable, Sendable {
    public var name: String
    public var isEnabled: Bool
    /// Lecture réussie en mémoire (cette session), et son heure.
    public var readAt: Date?
    /// Dernière erreur en mémoire (jeton absent, 403, certificat…).
    public var error: String?
    /// Dernier état enregistré (Réglages › Switchs › Contrôleurs FortiGate).
    public var status: FortiControllerStatus?

    public init(name: String, isEnabled: Bool = true, readAt: Date? = nil, error: String? = nil, status: FortiControllerStatus? = nil) {
        self.name = name
        self.isEnabled = isEnabled
        self.readAt = readAt
        self.error = error
        self.status = status
    }
}

/// Pastille d'état d'un site : sa FortiGate est-elle jointe ?
public enum SiteLinkState: Hashable, Sendable {
    /// Le site n'a aucune FortiGate associée.
    case noFortiGate
    /// FortiGate associée, jamais lue (ni testée).
    case notRead
    /// Au moins une FortiGate du site a répondu (heure de la lecture la plus récente).
    case joined(Date?)
    /// Toutes les FortiGate du site sont en échec ou désactivées : la raison.
    case problem(String)

    public static func evaluate(_ probes: [SiteFortiGateProbe]) -> SiteLinkState {
        guard !probes.isEmpty else { return .noFortiGate }
        let enabled = probes.filter(\.isEnabled)
        guard !enabled.isEmpty else { return .problem("lecture désactivée") }
        var joinedDates: [Date] = []
        var anyJoined = false
        var problems: [String] = []
        for probe in enabled {
            if probe.error == nil, probe.readAt != nil || probe.status?.kind == .ok {
                anyJoined = true
                if let date = probe.readAt ?? probe.status?.date { joinedDates.append(date) }
                continue
            }
            if let error = probe.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                problems.append(error)
            } else if let status = probe.status, status.kind != .untested, status.kind != .ok {
                problems.append(status.message.isEmpty ? defaultMessage(status.kind) : status.message)
            }
        }
        if anyJoined { return .joined(joinedDates.max()) }
        if let first = problems.first { return .problem(first) }
        return .notRead
    }

    private static func defaultMessage(_ kind: FortiControllerStatus.Kind) -> String {
        switch kind {
        case .missingToken: return "jeton absent"
        case .certificate: return "certificat à vérifier"
        default: return "lecture en échec"
        }
    }

    /// Libellé court : « FortiGate jointe », « Aucune FortiGate »…
    public var label: String {
        switch self {
        case .noFortiGate: return "Aucune FortiGate"
        case .notRead: return "FortiGate jamais lue"
        case .joined: return "FortiGate jointe"
        case .problem: return "FortiGate injoignable"
        }
    }

    /// Bulle d'aide complète (`time` met une heure en forme, ex. « 14:02 »).
    public func help(time: (Date) -> String) -> String {
        switch self {
        case .noFortiGate: return "Aucune FortiGate associée à ce site"
        case .notRead: return "FortiGate associée, pas encore lue (à la fin du prochain scan, ou par une lecture à la demande)"
        case .joined(let date): return "FortiGate jointe" + (date.map { ", lue à \(time($0))" } ?? "")
        case .problem(let reason): return "FortiGate injoignable\u{00A0}: \(reason)"
        }
    }
}

// MARK: - Switchs d'un site (note 48)

/// Un switch montré par « Switchs et ports » pour un site choisi dans son menu « Site ▾ ».
public struct SiteSwitchEntry: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// FortiSwitch lu par cette FortiGate (FortiLink).
        case fortiGate(String)
        /// Switch relevé en SNMP pour ce site.
        case snmp
    }

    public var siteKey: String
    public var siteName: String
    public var snapshot: SNMPSwitchSnapshot
    public var source: Source

    public init(siteKey: String, siteName: String, snapshot: SNMPSwitchSnapshot, source: Source) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.snapshot = snapshot
        self.source = source
    }

    /// « site|adresse » : le même switch (ou la même adresse FortiLink) sur deux sites donne deux lignes.
    public var id: String { SiteScope.id(site: siteKey, key: snapshot.id) }

    public var name: String { snapshot.displayName }
    public var portsUp: Int { snapshot.physicalPorts.filter(\.isUp).count }
    public var portsTotal: Int { snapshot.physicalPorts.count }

    public var sourceLabel: String {
        switch source {
        case .fortiGate(let name): return "FortiGate · \(name)"
        case .snmp: return "SNMP"
        }
    }

    /// Recherche commune (barre d'outils) : chaque mot dans le site, le nom, le modèle, l'adresse,
    /// la source ou l'emplacement.
    /// Un préfixe (« switch:FSW », « site:laval ») ne garde que sa valeur ; « -mot » exclut.
    public func matches(_ text: String) -> Bool {
        let words = SearchText.fold(text).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let haystack = SearchText.foldedJoined([siteName, name, snapshot.system.descr, snapshot.system.location ?? "",
                                                snapshot.host.description, snapshot.fortiLinkIP?.description ?? "", sourceLabel])
        for raw in words {
            var word = Substring(raw)
            var exclude = false
            if word.hasPrefix("-"), word.count > 1 {
                exclude = true
                word = word.dropFirst()
            }
            if let colon = word.firstIndex(of: ":") { word = word[word.index(after: colon)...] }
            let value = word.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty else { continue }
            if haystack.contains(value) == exclude { return false }
        }
        return true
    }

    /// Ce switch correspond-il à une demande « Ouvrir dans › Switchs et ports » (adresse ou nom) ?
    public func answers(to hostOrName: String) -> Bool {
        let wanted = hostOrName.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        return snapshot.id == wanted || snapshot.fortiLinkIP?.description == wanted
            || name.caseInsensitiveCompare(wanted) == .orderedSame
    }
}

/// Un relevé SNMP gardé en mémoire, avec le site pour lequel il a été fait.
public struct SiteSNMPReading: Hashable, Sendable {
    public var snapshot: SNMPSwitchSnapshot
    /// Site actif au moment du relevé (clé `SiteFiles.key`) ; nil : inconnu (jamais attribué).
    public var siteKey: String?

    public init(snapshot: SNMPSwitchSnapshot, siteKey: String?) {
        self.snapshot = snapshot
        self.siteKey = siteKey
    }
}

/// Switchs d'un site, sans rien lire sur le réseau.
public struct SiteSwitchView: Hashable, Sendable {
    public var entries: [SiteSwitchEntry]
    /// Message quand le site n'a rien à montrer (nil s'il y a des switchs).
    public var emptyMessage: String?
    /// Remarques (switchs SNMP associés jamais relevés pour ce site, FortiGate non lue…).
    public var notes: [String]
    /// FortiGate du site qu'on peut lire pour remplir la vue (identifiants).
    public var fortiGatesToRead: [UUID]

    public init(entries: [SiteSwitchEntry] = [], emptyMessage: String? = nil, notes: [String] = [], fortiGatesToRead: [UUID] = []) {
        self.entries = entries
        self.emptyMessage = emptyMessage
        self.notes = notes
        self.fortiGatesToRead = fortiGatesToRead
    }
}

public enum SiteSwitchBrowse {
    /// Switchs d'un site qui n'est pas le site actif (ou du site actif vu dans « Tous les sites ») :
    /// - FortiSwitch des dernières lectures des FortiGate DE CE SITE (`fortiReports`, filtrées) ;
    /// - switchs SNMP associés au site ou dans ses plages, mais seulement s'ils ont été relevés
    ///   pour CE site (un relevé fait pour un autre site, à la même adresse, est un autre switch).
    /// `fortiGateNames` : nom de chaque FortiGate du site (pour les remarques).
    public static func view(site: Site, siteKey: String, fortiReports: [FortiSiteReport],
                            fortiGateNames: [UUID: String] = [:], snmp: [SiteSNMPReading]) -> SiteSwitchView {
        let name = site.displayName
        let own = fortiReports.filter { site.fortiGateIDs.contains($0.controllerID) }
        var entries: [SiteSwitchEntry] = FortiMulti.snapshots(own).map { snapshot in
            SiteSwitchEntry(siteKey: siteKey, siteName: name, snapshot: snapshot,
                            source: .fortiGate(snapshot.controllerName ?? "FortiGate"))
        }
        let ranges = site.parsedRanges
        func belongs(_ host: IPv4Address) -> Bool {
            site.switchHosts.contains(host.description) || (!ranges.isEmpty && ScanRelevance.contains(ranges, host))
        }
        var seen = Set(entries.map(\.snapshot.id))
        let polled = snmp.filter { $0.siteKey == siteKey && !$0.snapshot.isViaController && belongs($0.snapshot.host) }
        for reading in polled where seen.insert(reading.snapshot.id).inserted {
            entries.append(SiteSwitchEntry(siteKey: siteKey, siteName: name, snapshot: reading.snapshot, source: .snmp))
        }

        var notes: [String] = []
        let polledHosts = Set(polled.map(\.snapshot.id))
        let missingSNMP = site.switchHosts.filter { !polledHosts.contains($0) }
        if !missingSNMP.isEmpty {
            let count = missingSNMP.count
            notes.append("\(count) switch\(count > 1 ? "s" : "") SNMP associé\(count > 1 ? "s" : "") (\(missingSNMP.joined(separator: ", "))) pas encore relevé\(count > 1 ? "s" : "") pour ce site\u{00A0}: le relevé SNMP se fait sur place, quand «\u{00A0}\(name)\u{00A0}» est le site actif.")
        }
        let readIDs = Set(own.map(\.controllerID))
        let unread = site.fortiGateIDs.filter { !readIDs.contains($0) }
        // FortiGate en partie lues seulement (sinon le message vide le dit déjà).
        if !unread.isEmpty, !own.isEmpty {
            let names = unread.map { fortiGateNames[$0] ?? "FortiGate" }
            notes.append((unread.count > 1 ? "FortiGate pas encore lues\u{00A0}: " : "FortiGate pas encore lue\u{00A0}: ") + names.joined(separator: ", ") + ".")
        }

        var empty: String?
        if entries.isEmpty {
            if site.fortiGateIDs.isEmpty && site.switchHosts.isEmpty {
                empty = "«\u{00A0}\(name)\u{00A0}» n’a ni FortiGate ni switch SNMP associé. Associez-les dans Réglages › Sites et plages (FortiGate) ou Réglages › Switchs (switchs SNMP)."
            } else if !own.isEmpty {
                empty = own.count > 1 ? "Les FortiGate de «\u{00A0}\(name)\u{00A0}» ne gèrent aucun FortiSwitch." : "La FortiGate de «\u{00A0}\(name)\u{00A0}» ne gère aucun FortiSwitch."
            } else if !site.fortiGateIDs.isEmpty {
                empty = "Les switchs de «\u{00A0}\(name)\u{00A0}» ne sont pas encore connus\u{00A0}: lisez sa FortiGate (lecture seule) ou ouvrez ce site sur place."
            } else {
                empty = "Les switchs SNMP de «\u{00A0}\(name)\u{00A0}» n’ont pas encore été relevés\u{00A0}: le relevé se fait sur place, quand c’est le site actif."
            }
        }
        return SiteSwitchView(entries: entries, emptyMessage: empty, notes: notes, fortiGatesToRead: site.fortiGateIDs)
    }
}

// MARK: - Wi-Fi d'un site (note 48)

public enum SiteWifiBrowse {
    /// Lectures Wi-Fi des FortiGate d'un site, dans l'ordre de ses FortiGate, renommées d'après le
    /// site (« Entrepôt Laval », ou « Entrepôt Laval · FGT-2 » quand il en a plusieurs) : la colonne
    /// « Site » des tableaux nomme le site, jamais une FortiGate d'un autre site.
    public static func reports(site: Site, fortiGateNames: [UUID: String] = [:],
                               cache: [UUID: FortiWifiSiteReport]) -> [FortiWifiSiteReport] {
        let several = site.fortiGateIDs.count > 1
        return site.fortiGateIDs.compactMap { id in
            guard var report = cache[id] else { return nil }
            let fortiGate = fortiGateNames[id] ?? report.site
            report.site = several ? "\(site.displayName) · \(fortiGate)" : site.displayName
            return report
        }
    }

    /// Vue de plusieurs sites : la fusion se fait DANS chaque site (`FortiWifiMerge.overview`),
    /// jamais entre deux sites (la même MAC sur deux sites reste deux clients).
    public static func overview(perSite groups: [[FortiWifiSiteReport]]) -> FortiWifiOverview {
        var result = FortiWifiOverview()
        for group in groups where !group.isEmpty {
            let part = FortiWifiMerge.overview(group)
            result.aps += part.aps
            result.clients += part.clients
            result.ssids += part.ssids
            result.rogues += part.rogues
            result.sites += part.sites
            result.notes += part.notes
            if let date = part.readAt { result.readAt = max(result.readAt ?? date, date) }
        }
        return result
    }

    /// Message quand un site n'a pas de Wi-Fi à montrer (nil : il y a des bornes ou des clients).
    public static func emptyMessage(site: Site, reports: [FortiWifiSiteReport]) -> String? {
        let name = site.displayName
        if site.fortiGateIDs.isEmpty {
            return "«\u{00A0}\(name)\u{00A0}» n’a pas de FortiGate associée\u{00A0}: ses bornes FortiAP ne peuvent pas être lues. Associez sa FortiGate dans Réglages › Sites et plages."
        }
        if reports.isEmpty {
            return "Les bornes de «\u{00A0}\(name)\u{00A0}» n’ont pas encore été lues\u{00A0}: «\u{00A0}Lire les bornes\u{00A0}» interroge sa FortiGate (lecture seule)."
        }
        if reports.allSatisfy({ $0.report.aps.isEmpty && $0.report.clients.isEmpty }) {
            return "La FortiGate de «\u{00A0}\(name)\u{00A0}» ne gère aucune borne FortiAP."
        }
        return nil
    }
}

// MARK: - Retour (note 45)

extension NavModule {
    /// Nom court du bouton ‹ Retour (« ‹ Inventaire », « ‹ Carte », « ‹ Fiche »).
    public var shortTitle: String {
        switch self {
        case .carte: return "Carte"
        case .appareil: return "Fiche"
        case .ping: return "Ping"
        case .switchs: return "Switchs"
        case .acces: return "Accès distant"
        default: return title
        }
    }
}
