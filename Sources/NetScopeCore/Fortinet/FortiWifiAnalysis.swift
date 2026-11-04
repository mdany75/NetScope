import Foundation

// Note 27 : diagnostic du Wi-Fi géré, fonctions pures. Chevauchement des canaux entre bornes d'un
// même site (2,4 GHz : canaux qui se recouvrent ; 5 et 6 GHz : même canal ou largeurs qui se
// recouvrent), clients à signal faible, bornes surchargées ou hors ligne, AP non autorisés, et
// conseils en clair.

/// Seuils du diagnostic (réglables dans l'écran Wi-Fi).
public struct FortiWifiThresholds: Codable, Hashable, Sendable {
    /// Signal faible sous ce RSSI (dBm).
    public var weakRSSI: Int
    /// Signal faible sous ce rapport signal/bruit (dB).
    public var weakSNR: Int
    /// Radio surchargée au-delà de ce nombre de clients.
    public var maxClientsPerRadio: Int
    /// Radio surchargée au-delà de cette utilisation du canal (%).
    public var maxChannelUtilization: Double

    public init(weakRSSI: Int = -70, weakSNR: Int = 20, maxClientsPerRadio: Int = 30, maxChannelUtilization: Double = 70) {
        self.weakRSSI = weakRSSI
        self.weakSNR = weakSNR
        self.maxClientsPerRadio = max(1, maxClientsPerRadio)
        self.maxChannelUtilization = min(100, max(1, maxChannelUtilization))
    }

    public static let standard = FortiWifiThresholds()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FortiWifiThresholds.standard
        self.init(weakRSSI: (try? c.decodeIfPresent(Int.self, forKey: .weakRSSI)) ?? d.weakRSSI,
                  weakSNR: (try? c.decodeIfPresent(Int.self, forKey: .weakSNR)) ?? d.weakSNR,
                  maxClientsPerRadio: (try? c.decodeIfPresent(Int.self, forKey: .maxClientsPerRadio)) ?? d.maxClientsPerRadio,
                  maxChannelUtilization: (try? c.decodeIfPresent(Double.self, forKey: .maxChannelUtilization)) ?? d.maxChannelUtilization)
    }
}

/// Deux radios de bornes d'un même site qui se gênent.
public struct FortiChannelOverlap: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// Même canal : les bornes se partagent le temps d'antenne (co-canal).
        case sameChannel
        /// 2,4 GHz : canaux qui se recouvrent en partie (ex. 1 et 3) : brouillage mutuel.
        case adjacent
        /// 5 ou 6 GHz : canaux différents dans un même bloc de largeur (ex. 36 et 44 en 80 MHz).
        case sharedWidth
    }

    public var site: String
    public var band: WifiBand
    public var first: String
    public var firstChannel: Int
    public var firstWidth: Int
    public var second: String
    public var secondChannel: Int
    public var secondWidth: Int
    public var kind: Kind

    public var id: String { "\(site)|\(band.rawValue)|\(first)|\(firstChannel)|\(second)|\(secondChannel)" }

    /// « AP-ACCUEIL (canal 36, 80 MHz) et AP-SALLE (canal 44, 80 MHz) ».
    public var pairLabel: String {
        func one(_ name: String, _ ch: Int, _ w: Int) -> String {
            band == .ghz24 && w == 20 ? "\(name) (canal \(ch))" : "\(name) (canal \(ch), \(w)\u{00A0}MHz)"
        }
        return one(first, firstChannel, firstWidth) + " et " + one(second, secondChannel, secondWidth)
    }

    public var kindLabel: String {
        switch kind {
        case .sameChannel: return "Même canal"
        case .adjacent: return "Canaux qui se recouvrent"
        case .sharedWidth: return "Largeurs qui se recouvrent"
        }
    }
}

/// Radio d'une borne au-delà des seuils.
public struct FortiOverload: Hashable, Sendable, Identifiable {
    public var site: String
    public var apName: String
    public var radio: FortiAPRadio
    public var tooManyClients: Bool
    public var busyChannel: Bool

    public var id: String { "\(site)|\(apName)|\(radio.radioID)" }
}

/// Conseil en clair.
public struct FortiWifiAdvice: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case offline, rogue, overlap, weakSignal, overload, openSSID, width24, note, healthy
    }

    public var id: String
    public var kind: Kind
    public var severity: WifiRecommendation.Severity
    public var title: String
    public var detail: String
    public var site: String?
    /// Borne à montrer (« Voir la borne »).
    public var apName: String?
    public var band: WifiBand?
}

/// Diagnostic complet.
public struct FortiWifiDiagnosis: Hashable, Sendable {
    public var overlaps: [FortiChannelOverlap]
    public var weakClients: [FortiWifiClient]
    public var overloaded: [FortiOverload]
    public var offline: [FortiManagedAP]
    public var unauthorized: [FortiRogueAP]
    public var advice: [FortiWifiAdvice]

    /// Alertes à compter dans la tuile « Alertes » (sans les conseils ni les infos).
    public var alertCount: Int { advice.filter { $0.severity <= .alerte }.count }
}

public enum FortiWifiAnalysis {
    // MARK: Canaux

    /// Vrai si deux radios de même bande se recouvrent en fréquence.
    public static func overlaps(band: WifiBand, _ a: Int, _ wa: Int, _ b: Int, _ wb: Int) -> Bool {
        let sa = WifiChannelLayout.span(channel: a, band: band, widthMHz: wa)
        let sb = WifiChannelLayout.span(channel: b, band: band, widthMHz: wb)
        return abs(sa.center - sb.center) < sa.half + sb.half - 0.0001
    }

    /// Chevauchements entre radios de bornes différentes d'un même site, bande par bande. Une
    /// borne hors ligne n'émet pas : elle est ignorée.
    public static func channelOverlaps(_ aps: [FortiManagedAP]) -> [FortiChannelOverlap] {
        struct Item { let site: String; let ap: String; let band: WifiBand; let channel: Int; let width: Int }
        var items: [Item] = []
        for ap in aps where !ap.isOffline {
            for radio in ap.radios where radio.isServing {
                guard let band = radio.band, let channel = radio.channel else { continue }
                items.append(Item(site: ap.site, ap: ap.name, band: band, channel: channel, width: radio.effectiveWidth))
            }
        }
        var result: [FortiChannelOverlap] = []
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i], b = items[j]
                guard a.site == b.site, a.band == b.band, a.ap != b.ap,
                      overlaps(band: a.band, a.channel, a.width, b.channel, b.width) else { continue }
                let kind: FortiChannelOverlap.Kind
                if a.channel == b.channel { kind = .sameChannel }
                else { kind = a.band == .ghz24 ? .adjacent : .sharedWidth }
                result.append(FortiChannelOverlap(site: a.site, band: a.band, first: a.ap, firstChannel: a.channel, firstWidth: a.width,
                                                  second: b.ap, secondChannel: b.channel, secondWidth: b.width, kind: kind))
            }
        }
        return result
    }

    /// Canaux 2,4 GHz sans recouvrement (Amérique du Nord).
    public static let clean24 = [1, 6, 11]

    // MARK: Clients, charge, état

    /// Signal faible : RSSI sous le seuil ou SNR sous le seuil.
    public static func isWeak(_ client: FortiWifiClient, thresholds: FortiWifiThresholds = .standard) -> Bool {
        if let rssi = client.rssi, rssi < thresholds.weakRSSI { return true }
        if let snr = client.snr, snr < thresholds.weakSNR { return true }
        return false
    }

    public static func weakClients(_ clients: [FortiWifiClient], thresholds: FortiWifiThresholds = .standard) -> [FortiWifiClient] {
        clients.filter { isWeak($0, thresholds: thresholds) }.sorted { ($0.rssi ?? 0) < ($1.rssi ?? 0) }
    }

    /// Clients d'une radio : donnée de la radio, sinon les clients comptés sur la borne et la bande.
    static func clientCount(_ radio: FortiAPRadio, ap: FortiManagedAP, clients: [FortiWifiClient]) -> Int {
        if let n = radio.clientCount { return n }
        let keys = ap.keys
        return clients.filter { c in
            c.site == ap.site && !keys.isDisjoint(with: [c.apName, c.apKey].compactMap { $0?.lowercased() })
                && (c.radioID == radio.radioID || (c.radioID == nil && c.band != nil && c.band == radio.band))
        }.count
    }

    public static func overloaded(_ aps: [FortiManagedAP], clients: [FortiWifiClient] = [],
                                  thresholds: FortiWifiThresholds = .standard) -> [FortiOverload] {
        var result: [FortiOverload] = []
        for ap in aps where !ap.isOffline {
            for radio in ap.radios where radio.isServing {
                let count = clientCount(radio, ap: ap, clients: clients)
                let many = count > thresholds.maxClientsPerRadio
                let busy = (radio.channelUtilization ?? 0) > thresholds.maxChannelUtilization
                guard many || busy else { continue }
                var r = radio
                r.clientCount = count
                result.append(FortiOverload(site: ap.site, apName: ap.name, radio: r, tooManyClients: many, busyChannel: busy))
            }
        }
        return result
    }

    // MARK: Diagnostic et conseils

    static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// `maskMACs` : adresses MAC des conseils réduites au préfixe du fabricant (« AA:BB:CC:xx:xx:xx »),
    /// comme l'option « masquer les MAC » des rapports.
    public static func diagnose(_ overview: FortiWifiOverview, thresholds: FortiWifiThresholds = .standard,
                                maskMACs: Bool = false) -> FortiWifiDiagnosis {
        func macText(_ mac: MACAddress) -> String {
            let text = mac.formatted(.upperColon)
            return maskMACs ? String(text.prefix(8)) + ":xx:xx:xx" : text
        }
        let overlaps = channelOverlaps(overview.aps)
        let weak = weakClients(overview.clients, thresholds: thresholds)
        let overload = overloaded(overview.aps, clients: overview.clients, thresholds: thresholds)
        let offline = overview.offlineAPs
        let unauthorized = overview.rogues.filter(\.isUnauthorized)
        var advice: [FortiWifiAdvice] = []
        let multi = overview.isMultiSite
        func at(_ site: String) -> String { multi && !site.isEmpty ? " (\(site))" : "" }
        let nbsp = "\u{00A0}"

        for ap in offline {
            var detail = "La borne \(ap.name)\(ap.model.isEmpty ? "" : " (\(ap.model))") ne répond plus à la FortiGate"
            if let ip = ap.ip { detail += ", dernière adresse \(ip)" }
            detail += ". Vérifiez son alimentation PoE et son câble (port du switch), puis son état dans WiFi & Switch Controller › Managed FortiAPs."
            advice.append(FortiWifiAdvice(id: "offline|\(ap.id)", kind: .offline, severity: .critique,
                                          title: "Borne hors ligne\(nbsp): \(ap.name)\(at(ap.site))", detail: detail, site: ap.site, apName: ap.name))
        }

        for rogue in unauthorized {
            let name = rogue.ssid.map { "«\(nbsp)\($0)\(nbsp)»" } ?? "SSID caché"
            var detail = "\(name)" + (rogue.bssid.map { " (\(macText($0)))" } ?? "")
            if let ch = rogue.channel { detail += ", canal \(ch)" }
            if let r = rogue.rssi { detail += ", \(r)\(nbsp)dBm" }
            if !rogue.seenBy.isEmpty { detail += ", vu par " + rogue.seenBy.prefix(3).joined(separator: ", ") }
            detail += rogue.onWire ? ". Il est branché sur votre réseau câblé\(nbsp): retrouvez-le (table MAC des switchs) et débranchez-le."
                : ". Classé non autorisé par la FortiGate\(nbsp): localisez-le, puis acceptez-le ou neutralisez-le."
            advice.append(FortiWifiAdvice(id: "rogue|\(rogue.id)", kind: .rogue, severity: .critique,
                                          title: "Point d’accès non autorisé\(at(rogue.site))", detail: detail, site: rogue.site, band: rogue.band))
        }

        for o in overlaps {
            switch o.kind {
            case .adjacent:
                advice.append(FortiWifiAdvice(id: "overlap|\(o.id)", kind: .overlap, severity: .alerte,
                                              title: "Canaux 2,4\(nbsp)GHz qui se recouvrent\(at(o.site))",
                                              detail: "\(o.pairLabel) se brouillent mutuellement. N’utilisez que les canaux 1, 6 et 11 en 20\(nbsp)MHz (profil FortiAP › Radio 2,4\(nbsp)GHz › Canaux).",
                                              site: o.site, apName: o.first, band: o.band))
            case .sameChannel where o.band == .ghz24:
                advice.append(FortiWifiAdvice(id: "overlap|\(o.id)", kind: .overlap, severity: .conseil,
                                              title: "Même canal 2,4\(nbsp)GHz\(at(o.site))",
                                              detail: "\(o.pairLabel) partagent le temps d’antenne si elles s’entendent. Répartissez-les sur 1, 6 et 11, ou baissez la puissance de l’une des deux.",
                                              site: o.site, apName: o.first, band: o.band))
            case .sameChannel, .sharedWidth:
                let widthHint = max(o.firstWidth, o.secondWidth) > 40 ? " ou réduisez la largeur à 40\(nbsp)MHz" : ""
                advice.append(FortiWifiAdvice(id: "overlap|\(o.id)", kind: .overlap, severity: .alerte,
                                              title: (o.kind == .sameChannel ? "Même canal " : "Largeurs qui se recouvrent en ") + o.band.label + at(o.site),
                                              detail: "\(o.pairLabel) occupent les mêmes fréquences. Placez-les dans des blocs différents\(widthHint) (DARRP ou canaux fixés dans le profil FortiAP).",
                                              site: o.site, apName: o.first, band: o.band))
            }
        }

        if !weak.isEmpty {
            let names = weak.prefix(3).map { c -> String in
                let signal = c.rssi.map { "\($0)\(nbsp)dBm" } ?? c.snr.map { "SNR \($0)\(nbsp)dB" } ?? ""
                return (c.hostname ?? macText(c.mac)) + (c.apName.map { " sur \($0)" } ?? "") + (signal.isEmpty ? "" : " (\(signal))")
            }
            let more = weak.count > 3 ? " et \(weak.count - 3) autre\(weak.count - 3 > 1 ? "s" : "")" : ""
            advice.append(FortiWifiAdvice(id: "weak", kind: .weakSignal, severity: .alerte,
                                          title: weak.count == 1 ? "1 client à signal faible" : "\(weak.count) clients à signal faible",
                                          detail: names.joined(separator: ", ") + more + ". Sous \(thresholds.weakRSSI)\(nbsp)dBm ou \(thresholds.weakSNR)\(nbsp)dB de SNR, le débit chute et les appels se coupent\(nbsp): rapprochez une borne, ajoutez-en une, ou activez le 802.11k/v pour l’itinérance.",
                                          site: weak.first?.site, apName: weak.first?.apName, band: weak.first?.band))
        }

        for o in overload {
            var reasons: [String] = []
            if o.tooManyClients { reasons.append("\(o.radio.clientCount ?? 0) clients (seuil \(thresholds.maxClientsPerRadio))") }
            if o.busyChannel, let u = o.radio.channelUtilization {
                reasons.append("canal occupé à \(Int(u.rounded()))\(nbsp)% (seuil \(Int(thresholds.maxChannelUtilization.rounded()))\(nbsp)%)")
            }
            let band = o.radio.band?.label ?? "radio \(o.radio.radioID)"
            advice.append(FortiWifiAdvice(id: "overload|\(o.id)", kind: .overload, severity: .alerte,
                                          title: "Borne surchargée\(nbsp): \(o.apName) en \(band)\(at(o.site))",
                                          detail: capitalized(reasons.joined(separator: ", "))
                                            + ". Activez l’équilibrage des clients (load balancing, band steering vers le 5\(nbsp)GHz) ou ajoutez une borne dans cette zone.",
                                          site: o.site, apName: o.apName, band: o.radio.band))
        }

        var seenOpen = Set<String>()
        for ssid in overview.ssids where ssid.isOpen && seenOpen.insert(ssid.site + "|" + ssid.ssid).inserted {
            let portal = ssid.captivePortal == true
            advice.append(FortiWifiAdvice(id: "open|\(ssid.id)", kind: .openSSID, severity: portal ? .conseil : .alerte,
                                          title: "SSID ouvert\(nbsp): «\(nbsp)\(ssid.ssid)\(nbsp)»\(at(ssid.site))",
                                          detail: portal ? "Portail captif sans chiffrement\(nbsp): le trafic des invités circule en clair. Passez en OWE (Enhanced Open) si les appareils le permettent, et isolez le VLAN\(ssid.vlan.map { " \($0)" } ?? "")."
                                            : "Aucun chiffrement\(nbsp): n’importe qui à portée lit le trafic. Passez en WPA2/WPA3 ou en OWE, et isolez ce réseau du LAN.",
                                          site: ssid.site))
        }

        for ap in overview.aps where !ap.isOffline {
            if let r = ap.radios.first(where: { $0.band == .ghz24 && $0.isServing && $0.effectiveWidth >= 40 }) {
                advice.append(FortiWifiAdvice(id: "width24|\(ap.id)", kind: .width24, severity: .conseil,
                                              title: "40\(nbsp)MHz en 2,4\(nbsp)GHz\(nbsp): \(ap.name)\(at(ap.site))",
                                              detail: "La radio 2,4\(nbsp)GHz utilise \(r.effectiveWidth)\(nbsp)MHz (canal \(r.channel ?? 0))\(nbsp): elle recouvre la plupart des canaux. Repassez en 20\(nbsp)MHz.",
                                              site: ap.site, apName: ap.name, band: .ghz24))
            }
        }

        for note in overview.notes {
            advice.append(FortiWifiAdvice(id: "note|\(note)", kind: .note, severity: .info, title: "Lecture incomplète", detail: note))
        }

        if advice.isEmpty, !overview.aps.isEmpty {
            advice.append(FortiWifiAdvice(id: "healthy", kind: .healthy, severity: .info, title: "Rien à signaler",
                                          detail: "\(overview.aps.count) borne\(overview.aps.count > 1 ? "s" : "") en ligne, aucun chevauchement de canal, aucun client sous les seuils."))
        }
        // Tri stable : par gravité, puis dans l'ordre où les conseils ont été établis.
        advice = advice.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
        return FortiWifiDiagnosis(overlaps: overlaps, weakClients: weak, overloaded: overload, offline: offline,
                                  unauthorized: unauthorized, advice: advice)
    }
}
