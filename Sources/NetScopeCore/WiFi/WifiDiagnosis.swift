import Foundation

// Note 47 : diagnostic Wi-Fi d'un client, fonctions pures (testées sans réseau sur des données fixes).
// Chaque cause de la note est évaluée à part : signal, client collant, canal et chevauchements,
// interférences, largeur, DFS, charge, clients lents, capacités du client, bande, connexion et
// authentification, DHCP, au-delà du Wi-Fi (ping depuis ce Mac), lien de la borne vers son switch,
// WAN et limites du SSID. Verdict, preuves chiffrées et actions ; la cause la plus probable en tête.

/// Tout ce que le diagnostic d'un client peut lire.
public struct WifiDiagnosisInput: Sendable {
    public var client: FortiWifiClient
    public var details: WifiClientDetails
    /// Borne du client (nil : inconnue, causes de la borne non vérifiées).
    public var ap: FortiManagedAP?
    /// Bornes du site, celle du client comprise.
    public var siteAPs: [FortiManagedAP]
    /// AP voisins et non autorisés du site.
    public var neighbors: [FortiRogueAP]
    /// Clients de la même borne, le client compris.
    public var apClients: [FortiWifiClient]
    public var ssid: FortiSSID?
    /// Clients du même SSID sur le site.
    public var ssidClientCount: Int?
    public var measures: WifiDiagnosisMeasures

    public init(client: FortiWifiClient, details: WifiClientDetails = WifiClientDetails(), ap: FortiManagedAP? = nil,
                siteAPs: [FortiManagedAP] = [], neighbors: [FortiRogueAP] = [], apClients: [FortiWifiClient] = [],
                ssid: FortiSSID? = nil, ssidClientCount: Int? = nil, measures: WifiDiagnosisMeasures = .none) {
        self.client = client
        self.details = details
        self.ap = ap
        self.siteAPs = siteAPs
        self.neighbors = neighbors
        self.apClients = apClients
        self.ssid = ssid
        self.ssidClientCount = ssidClientCount
        self.measures = measures
    }

    /// Entrée tirée d'une lecture Wi-Fi (un ou plusieurs sites) : borne, bornes et voisins du site du
    /// client, clients de sa borne, SSID.
    public static func from(overview: FortiWifiOverview, client: FortiWifiClient, details: WifiClientDetails = WifiClientDetails(),
                            measures: WifiDiagnosisMeasures = .none) -> WifiDiagnosisInput {
        let ap = overview.ap(for: client)
        let site = client.site
        let ssid = client.ssid.flatMap { name in overview.ssids.first { $0.site == site && $0.ssid == name } }
        let ssidCount = client.ssid.map { name in overview.clients.filter { $0.site == site && $0.ssid == name }.count }
        return WifiDiagnosisInput(client: client, details: details, ap: ap, siteAPs: overview.aps.filter { $0.site == site },
                                  neighbors: overview.rogues.filter { $0.site == site }, apClients: ap.map { overview.clients(of: $0) } ?? [client],
                                  ssid: ssid, ssidClientCount: ssidCount, measures: measures)
    }

    /// Radio du client sur sa borne : par numéro, sinon par bande.
    public var radio: FortiAPRadio? {
        guard let ap else { return nil }
        if let id = client.radioID, let r = ap.radios.first(where: { $0.radioID == id }) { return r }
        if let band = client.band { return ap.radio(band) }
        return nil
    }
}

public enum WifiDiagnosis {
    static let nb = "\u{00A0}"

    // MARK: Mise en forme

    static func dbm(_ v: Int) -> String { WifiQuality.dbm(v) }
    static func db(_ v: Int) -> String { "\(v)\(nb)dB" }
    static func ms(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return (v >= 10 ? "\(Int(v.rounded()))" : PingFormat.decimal(v)) + "\(nb)ms"
    }
    static func pct(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return (r == r.rounded() ? "\(Int(r))" : PingFormat.decimal(r)) + "\(nb)%"
    }
    static func rate(_ v: Double) -> String {
        (v >= 100 || v == v.rounded() ? "\(Int(v.rounded()))" : PingFormat.decimal(v)) + "\(nb)Mb/s"
    }
    static func quoted(_ text: String) -> String { "«\(nb)\(text)\(nb)»" }
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) " + (n > 1 ? many : one) }
    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m >= 120 { return "\(m / 60)\(nb)h" }
        if m >= 60 { return "\(m / 60)\(nb)h \(m % 60)\(nb)min" }
        return "\(max(m, 0))\(nb)min"
    }

    static func radioLabel(_ radio: FortiAPRadio) -> String {
        var text = (radio.band?.label.replacingOccurrences(of: " ", with: nb) ?? "radio \(radio.radioID)")
        if let ch = radio.channel { text += " canal \(ch)" }
        if radio.band != .ghz24 || radio.effectiveWidth != 20 { text += " (\(radio.effectiveWidth)\(nb)MHz)" }
        return text
    }

    /// Force d'un dépassement : 0 au seuil, 1 à `span` au-delà.
    static func excess(_ value: Double, beyond threshold: Double, span: Double) -> Double {
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - threshold) / span))
    }

    // MARK: Diagnostic d'un client

    public static func diagnose(_ input: WifiDiagnosisInput, thresholds t: WifiDiagnosisThresholds = .standard,
                                now: Date = Date(), id: UUID = UUID()) -> WifiDiagnosisResult {
        var causes: [WifiCauseResult] = [
            signal(input, t), sticky(input, t), channel(input, t), interference(input, t), width(input, t), dfs(input, t),
            load(input, t), slowClients(input, t), clientCapability(input, t), band(input, t), connection(input, t),
            dhcp(input, t), network(input.measures, t), uplink(input.measures, t), wan(input.measures, t), ssidLimits(input, t),
        ]
        causes = order(causes)
        let client = input.client
        var context: [String] = []
        if let ap = input.ap ?? client.apName.map({ FortiManagedAP(name: $0) }) { context.append(ap.name) }
        if let radio = input.radio {
            context.append("radio \(radio.radioID)")
            context.append(radioLabel(radio))
        } else if let band = client.band {
            context.append(band.label.replacingOccurrences(of: " ", with: nb) + (client.channel.map { " canal \($0)" } ?? ""))
        }
        if let ssid = client.ssid { context.append("SSID " + ssid) }
        if let vlan = client.vlan { context.append("VLAN \(vlan)") }
        var notes: [String] = []
        if input.measures.paths.isEmpty {
            notes.append("Mesures de ping non faites\(nb): passerelle, DNS et Internet non vérifiés.")
        } else {
            notes.append("Les pings partent de ce Mac, pas du client\(nb): ils montrent l’état du réseau derrière la borne.")
        }
        if input.details == WifiClientDetails() {
            notes.append("Standard, flux spatiaux, déconnexions et itinérances du client non lus\(nb): ces causes se jugent sur le reste.")
        }
        return WifiDiagnosisResult(id: id, subject: .client(mac: client.mac.formatted(.upperColon), name: client.displayName), site: client.site,
                                   date: now, context: context.joined(separator: " · "), causes: causes, actions: actions(causes),
                                   measured: !input.measures.paths.isEmpty, notes: notes)
    }

    /// Problèmes d'abord, puis à surveiller, OK et non vérifiées ; à verdict égal, la plus forte,
    /// puis dans l'ordre des causes.
    static func order(_ causes: [WifiCauseResult]) -> [WifiCauseResult] {
        causes.sorted { a, b in
            if a.verdict != b.verdict { return a.verdict > b.verdict }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.cause.rank < b.cause.rank
        }
    }

    /// Actions des problèmes puis des points à surveiller, dans l'ordre des causes, sans doublon.
    static func actions(_ causes: [WifiCauseResult], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for verdict in [WifiVerdict.problem, .watch] {
            for cause in causes where cause.verdict == verdict {
                for action in cause.actions where seen.insert(action).inserted { result.append(action) }
            }
        }
        return Array(result.prefix(limit))
    }

    // MARK: Signal

    static func signal(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let c = input.client
        guard c.rssi != nil || c.snr != nil else {
            return WifiCauseResult(cause: .signal, verdict: .notMeasured, summary: "Niveau du signal non donné par la FortiGate.")
        }
        var evidence: [String] = []
        let apName = input.ap?.name ?? c.apName ?? "la borne"
        var verdict = WifiVerdict.ok
        var weight = 0.0
        if let rssi = c.rssi {
            evidence.append("RSSI \(dbm(rssi)) reçu par \(apName) (à surveiller sous \(dbm(t.weakRSSI)), problème sous \(dbm(t.badRSSI)))")
            if rssi < t.badRSSI { verdict = .problem } else if rssi < t.weakRSSI { verdict = max(verdict, .watch) }
            weight = max(weight, excess(Double(t.weakRSSI - rssi), beyond: 0, span: 15))
        }
        if let snr = c.snr {
            evidence.append("SNR \(db(snr))" + (c.noise.map { " (bruit \(dbm($0)))" } ?? "") + " (à surveiller sous \(db(t.weakSNR)))")
            if snr < t.badSNR { verdict = .problem } else if snr < t.weakSNR { verdict = max(verdict, .watch) }
            weight = max(weight, excess(Double(t.weakSNR - snr), beyond: 0, span: 12))
        }
        let history = input.details.signalHistory
        if history.count >= 3, let low = history.min() {
            let mean = Int((Double(history.reduce(0, +)) / Double(history.count)).rounded())
            evidence.append("Historique\(nb): moyenne \(dbm(mean)), au plus bas \(dbm(low)) sur \(history.count) relevés")
        }
        let summary: String
        var actions: [String] = []
        switch verdict {
        case .problem:
            summary = "Le signal est trop faible pour un débit stable\(nb): le client est trop loin de \(apName) ou un obstacle le coupe."
        case .watch:
            summary = "Le signal est juste\(nb): le débit baisse et les appels vidéo peuvent couper."
        default:
            summary = "Le signal est bon."
        }
        if verdict >= .watch {
            actions.append("Rapprocher le poste de \(apName) ou retirer l’obstacle (murs porteurs, métal, vitres teintées, étagères).")
            if let radio = input.radio, let power = radio.txPowerDBm, power < 14 {
                actions.append("Monter la puissance d’émission de \(apName) (\(power)\(nb)dBm en \(radio.band?.label ?? "radio \(radio.radioID)")) d’un cran, sans dépasser celle des bornes voisines.")
            } else {
                actions.append("Vérifier la puissance d’émission de \(apName) dans le profil FortiAP (ni au minimum ni très différente des bornes voisines).")
            }
            actions.append("Ajouter une borne dans cette zone si plusieurs postes y ont un signal faible.")
        }
        return WifiCauseResult(cause: .signal, verdict: verdict, summary: summary, evidence: evidence, actions: actions,
                               weight: verdict == .problem ? 0.6 + 0.4 * weight : weight)
    }

    // MARK: Client collant

    static func sticky(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let c = input.client
        guard let rssi = c.rssi else {
            return WifiCauseResult(cause: .sticky, verdict: .notMeasured, summary: "Signal du client inconnu.")
        }
        let apName = input.ap?.name ?? c.apName ?? ""
        let ssidName = c.ssid.map(quoted) ?? "le SSID"
        let actions = [
            "Activer l’itinérance assistée 802.11k et 802.11v (et 802.11r si les postes le gèrent) sur \(ssidName).",
            "Fixer un seuil de RSSI minimal (vers \(dbm(t.badRSSI + 3))) dans le profil FortiAP pour pousser les clients collants vers une meilleure borne.",
            "Sur le poste\(nb): régler l’agressivité d’itinérance de la carte Wi-Fi sur «\(nb)moyenne\(nb)» ou «\(nb)élevée\(nb)».",
        ]
        let others = input.details.heardAPs.filter { $0.apName.lowercased() != apName.lowercased() }
        if let best = others.max(by: { $0.rssi < $1.rssi }) {
            let gap = best.rssi - rssi
            let evidence = ["Associé à \(apName) à \(dbm(rssi))", "Entend \(best.apName) à \(dbm(best.rssi)) (\(gap >= 0 ? "+" : "")\(db(gap)))"]
            if gap >= t.stickyMarginDB && rssi < t.weakRSSI + 5 {
                return WifiCauseResult(cause: .sticky, verdict: .problem,
                                       summary: "Le client reste accroché à \(apName) alors que \(best.apName) est nettement plus forte.",
                                       evidence: evidence, actions: actions, weight: 0.5 + excess(Double(gap), beyond: Double(t.stickyMarginDB), span: 15) / 2)
            }
            return WifiCauseResult(cause: .sticky, verdict: .ok, summary: "Le client est sur la meilleure borne qu’il entend.", evidence: evidence)
        }
        guard rssi < t.weakRSSI else {
            return WifiCauseResult(cause: .sticky, verdict: .ok, summary: "Signal correct\(nb): aucune raison de changer de borne.",
                                   evidence: ["Associé à \(apName) à \(dbm(rssi))"])
        }
        let alternatives = input.siteAPs.filter { !$0.isOffline && $0.name != apName && $0.radios.contains(where: \.isServing) }
        guard !alternatives.isEmpty else {
            return WifiCauseResult(cause: .sticky, verdict: .ok, summary: "Aucune autre borne en ligne sur le site\(nb): rien vers quoi basculer.",
                                   evidence: ["Associé à \(apName) à \(dbm(rssi))"])
        }
        var evidence = ["Associé à \(apName) à \(dbm(rssi))",
                        "\(plural(alternatives.count, "autre borne en ligne", "autres bornes en ligne")) sur le site (\(alternatives.prefix(3).map(\.name).joined(separator: ", "))\(alternatives.count > 3 ? "…" : ""))"]
        if let since = c.associatedFor { evidence.append("Sur la même borne depuis \(minutes(since))") }
        let long = (c.associatedFor ?? 0) >= 20 * 60
        return WifiCauseResult(cause: .sticky, verdict: long ? .watch : .ok,
                               summary: long ? "Signal faible depuis longtemps sur la même borne\(nb): le client ne bascule peut-être pas vers une borne plus proche."
                                             : "Signal faible, mais le client vient d’arriver sur cette borne.",
                               evidence: evidence, actions: long ? actions : [], weight: long ? 0.3 : 0)
    }

    // MARK: Canal et chevauchements

    /// Chevauchements qui touchent cette radio de cette borne.
    static func overlaps(of radio: FortiAPRadio, on ap: FortiManagedAP, siteAPs: [FortiManagedAP]) -> [FortiChannelOverlap] {
        guard let band = radio.band, let channel = radio.channel else { return [] }
        var aps = siteAPs.filter { $0.site == ap.site && $0.name != ap.name }
        // La borne elle-même avec cette seule radio : les autres radios de la même bande ne comptent pas.
        var me = ap
        me.radios = [radio]
        aps.append(me)
        return FortiWifiAnalysis.channelOverlaps(aps).filter { o in
            o.band == band && ((o.first == ap.name && o.firstChannel == channel) || (o.second == ap.name && o.secondChannel == channel))
        }
    }

    static func channelResult(radio: FortiAPRadio, ap: FortiManagedAP, siteAPs: [FortiManagedAP], neighbors: [FortiRogueAP],
                              _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let found = overlaps(of: radio, on: ap, siteAPs: siteAPs)
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence: [String] = []
        let label = radioLabel(radio)
        if let util = radio.channelUtilization {
            evidence.append("\(ap.name) \(label)\(nb): canal occupé à \(pct(util)) (à surveiller au-delà de \(pct(t.busyUtilization)), saturé au-delà de \(pct(t.saturatedUtilization)))")
            if util > t.saturatedUtilization { verdict = .problem } else if util > t.busyUtilization { verdict = .watch }
            weight = excess(util, beyond: t.busyUtilization, span: 40)
        } else {
            evidence.append("\(ap.name) \(label)\(nb): occupation du canal non donnée")
        }
        for o in found.prefix(3) {
            let other = o.first == ap.name ? o.second : o.first
            let otherChannel = o.first == ap.name ? o.secondChannel : o.firstChannel
            let otherWidth = o.first == ap.name ? o.secondWidth : o.firstWidth
            evidence.append("\(o.kindLabel) avec \(other) (canal \(otherChannel)\(o.band == .ghz24 && otherWidth == 20 ? "" : ", \(otherWidth)\(nb)MHz"))")
            let partial24 = o.kind == .adjacent
            verdict = max(verdict, partial24 || (radio.channelUtilization ?? 0) > t.busyUtilization ? .problem : .watch)
            weight = max(weight, partial24 ? 0.7 : 0.45)
        }
        if found.count > 3 { evidence.append("et \(found.count - 3) autre\(found.count - 3 > 1 ? "s" : "") chevauchement\(found.count - 3 > 1 ? "s" : "")") }
        var actions: [String] = []
        let summary: String
        switch verdict {
        case .problem where !found.isEmpty:
            summary = "\(ap.name) partage ses fréquences avec \(plural(found.count, "autre borne", "autres bornes")) du site\(nb): elles se gênent."
        case .problem:
            summary = "Le canal est saturé\(nb): les clients attendent leur tour pour émettre."
        case .watch where !found.isEmpty:
            summary = "\(ap.name) partage son canal avec une autre borne du site\(nb): le temps d’antenne se partage."
        case .watch:
            summary = "Le canal est chargé\(nb): le débit baisse aux heures de pointe."
        default:
            summary = "Canal propre\(nb): aucun chevauchement avec les autres bornes du site."
        }
        if verdict >= .watch {
            if let next = suggestedChannel(radio: radio, ap: ap, siteAPs: siteAPs, neighbors: neighbors, t) {
                let width = radio.band == .ghz24 ? 20 : min(radio.effectiveWidth, 80)
                actions.append("Passer \(ap.name) sur le canal \(next) (\(radio.band?.label.replacingOccurrences(of: " ", with: nb) ?? ""), \(width)\(nb)MHz), le moins encombré d’après les bornes et les voisins.")
            }
            actions.append(radio.band == .ghz24
                           ? "N’utiliser que les canaux 1, 6 et 11 en 2,4\(nb)GHz (DARRP ou canaux fixés dans le profil FortiAP)."
                           : "Établir un plan de canaux\(nb): DARRP, ou canaux fixés dans le profil FortiAP pour que deux bornes voisines n’aient jamais le même bloc.")
        }
        return WifiCauseResult(cause: .channel, verdict: verdict, summary: summary, evidence: evidence, actions: actions,
                               weight: verdict == .problem ? 0.5 + weight / 2 : weight / 2)
    }

    static func channel(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ap = input.ap, let radio = input.radio, radio.channel != nil else {
            return WifiCauseResult(cause: .channel, verdict: .notMeasured, summary: "Borne ou radio du client inconnue.")
        }
        return channelResult(radio: radio, ap: ap, siteAPs: input.siteAPs, neighbors: input.neighbors, t)
    }

    /// Canal conseillé pour une radio : le moins occupé par les autres bornes du site et les voisins
    /// entendus ; nil si le canal actuel est déjà le meilleur.
    public static func suggestedChannel(radio: FortiAPRadio, ap: FortiManagedAP, siteAPs: [FortiManagedAP], neighbors: [FortiRogueAP],
                                        _ t: WifiDiagnosisThresholds = .standard) -> Int? {
        guard let band = radio.band, let current = radio.channel else { return nil }
        let width = band == .ghz24 ? 20 : min(radio.effectiveWidth, 80)
        let candidates: [Int]
        switch band {
        case .ghz24: candidates = FortiWifiAnalysis.clean24
        case .ghz5:
            switch width {
            case 80: candidates = [36, 52, 100, 116, 132, 149]
            case 40: candidates = [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157]
            default: candidates = WifiChannelLayout.channels5
            }
        case .ghz6: candidates = stride(from: 1, through: 225, by: width / 5).map { $0 }
        }
        func score(_ channel: Int) -> Int {
            var s = 0
            for other in siteAPs where !other.isOffline && other.name != ap.name && other.site == ap.site {
                for r in other.radios where r.isServing && r.band == band {
                    guard let ch = r.channel else { continue }
                    if FortiWifiAnalysis.overlaps(band: band, channel, width, ch, r.effectiveWidth) { s += 3 }
                }
            }
            for n in neighbors where n.band == band || (n.band == nil && n.channel.map { WifiBand.guess(channel: $0) } == band) {
                guard let ch = n.channel, FortiWifiAnalysis.overlaps(band: band, channel, width, ch, 20) else { continue }
                let rssi = n.rssi ?? t.neighborRSSI
                if rssi >= t.neighborRSSI + 10 { s += 2 } else if rssi >= t.neighborRSSI { s += 1 }
            }
            // À égalité, les canaux sans DFS d'abord (pas de coupure radar).
            return s * 2 + (band == .ghz5 && (52...144).contains(channel) ? 1 : 0)
        }
        let currentScore = score(current)
        guard let best = candidates.min(by: { (score($0), $0) < (score($1), $1) }) else { return nil }
        let currentBlock = candidates.last { $0 <= current } ?? current
        return score(best) < currentScore && best != currentBlock ? best : nil
    }

    // MARK: Interférences

    /// AP voisins qui recouvrent cette radio et qu'elle entend assez fort.
    static func interferers(radio: FortiAPRadio, ap: FortiManagedAP, neighbors: [FortiRogueAP], _ t: WifiDiagnosisThresholds) -> [FortiRogueAP] {
        guard let band = radio.band, let channel = radio.channel else { return [] }
        return neighbors.filter { n in
            guard let ch = n.channel, (n.band ?? WifiBand.guess(channel: ch)) == band else { return false }
            guard n.seenBy.isEmpty || n.seenBy.contains(where: { $0.lowercased() == ap.name.lowercased() }) else { return false }
            guard FortiWifiAnalysis.overlaps(band: band, channel, radio.effectiveWidth, ch, 20) else { return false }
            return (n.rssi ?? t.neighborRSSI) >= t.neighborRSSI || n.isUnauthorized
        }
        .sorted { ($0.isUnauthorized ? 1 : 0, $0.rssi ?? -100) > ($1.isUnauthorized ? 1 : 0, $1.rssi ?? -100) }
    }

    static func interferenceResult(radio: FortiAPRadio, ap: FortiManagedAP, siteAPs: [FortiManagedAP], neighbors: [FortiRogueAP],
                                   _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let found = interferers(radio: radio, ap: ap, neighbors: neighbors, t)
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence: [String] = []
        var actions: [String] = []
        let unauthorized = found.filter(\.isUnauthorized)
        let loud = found.filter { ($0.rssi ?? -100) >= t.neighborRSSI + 10 }
        for n in found.prefix(3) {
            var line = (n.ssid.map(quoted) ?? "SSID caché") + (n.vendor.map { " (\($0))" } ?? "")
            if let ch = n.channel { line += " canal \(ch)" }
            if let r = n.rssi { line += " à \(dbm(r))" }
            line += ", vu par \(ap.name)"
            if n.isUnauthorized { line += n.onWire ? " — non autorisé, branché sur le réseau" : " — non autorisé" }
            evidence.append(line)
        }
        if found.count > 3 { evidence.append("et \(found.count - 3) autre\(found.count - 3 > 1 ? "s" : "") AP voisin\(found.count - 3 > 1 ? "s" : "") sur ce canal") }
        if !unauthorized.isEmpty || !loud.isEmpty {
            verdict = .problem
            weight = 0.5 + Double(min(loud.count + unauthorized.count, 5)) / 10
        } else if !found.isEmpty {
            verdict = .watch
            weight = Double(min(found.count, 5)) / 10
        }
        if let noise = radio.noiseDBm {
            evidence.append("Bruit de fond \(dbm(noise)) (bruyant au-dessus de \(dbm(t.noisyFloor)))")
            if noise > t.noisyFloor + 5 {
                verdict = .problem
                weight = max(weight, 0.6)
            } else if noise > t.noisyFloor {
                verdict = max(verdict, .watch)
                weight = max(weight, 0.35)
            }
            if noise > t.noisyFloor {
                actions.append("Chercher une source de bruit près de \(ap.name)\(nb): four à micro-ondes, caméra ou téléphone sans fil, Bluetooth, néons (une capture de spectre la confirme).")
            }
        }
        if let n = radio.interferingAPs, n > 0 {
            evidence.append("\(ap.name) signale \(plural(n, "AP brouilleur", "AP brouilleurs")) sur ce canal")
            if n >= 5 { verdict = max(verdict, .watch); weight = max(weight, 0.3) }
        }
        for rogue in unauthorized.prefix(2) {
            let name = rogue.ssid.map(quoted) ?? "caché"
            actions.append(rogue.onWire
                           ? "Retrouver et débrancher l’AP non autorisé \(name)\(nb): il est branché sur le réseau câblé (table MAC des switchs)."
                           : "Localiser l’AP non autorisé \(name), puis l’accepter ou le neutraliser sur la FortiGate.")
        }
        if verdict >= .watch, !found.isEmpty {
            if let next = suggestedChannel(radio: radio, ap: ap, siteAPs: siteAPs, neighbors: neighbors, t) {
                actions.append("Changer \(ap.name) de canal pour s’éloigner de \(found.first?.ssid.map(quoted) ?? "ses voisins") (canal conseillé\(nb): \(next)).")
            } else if radio.band == .ghz24 {
                actions.append("Faire passer les clients en 5\(nb)GHz\(nb): la bande 2,4\(nb)GHz n’a que trois canaux et le voisinage les occupe tous.")
            }
        }
        let summary: String
        switch verdict {
        case .problem where !unauthorized.isEmpty: summary = "Un point d’accès non autorisé émet sur le même canal\(nb): il brouille la borne et doit être retiré."
        case .problem where found.isEmpty: summary = "Le bruit de fond est élevé\(nb): un appareil non Wi-Fi brouille le canal."
        case .problem: summary = "Des réseaux voisins émettent fort sur le même canal\(nb): ils prennent du temps d’antenne."
        case .watch: summary = "Des réseaux voisins sont entendus sur ce canal."
        default: summary = "Aucun voisin gênant entendu sur ce canal."
        }
        return WifiCauseResult(cause: .interference, verdict: verdict, summary: summary, evidence: evidence, actions: actions, weight: weight)
    }

    static func interference(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ap = input.ap, let radio = input.radio, radio.channel != nil else {
            return WifiCauseResult(cause: .interference, verdict: .notMeasured, summary: "Borne ou radio du client inconnue.")
        }
        return interferenceResult(radio: radio, ap: ap, siteAPs: input.siteAPs, neighbors: input.neighbors, t)
    }

    // MARK: Largeur et DFS

    static func widthResult(radio: FortiAPRadio, ap: FortiManagedAP, siteAPs: [FortiManagedAP]) -> WifiCauseResult {
        let width = radio.effectiveWidth
        let label = radioLabel(radio)
        switch radio.band {
        case .ghz24? where width >= 40:
            return WifiCauseResult(cause: .width, verdict: .problem,
                                   summary: "\(width)\(nb)MHz en 2,4\(nb)GHz recouvre presque toute la bande\(nb): la radio brouille et se fait brouiller.",
                                   evidence: ["\(ap.name) \(label)"], actions: ["Repasser la radio 2,4\(nb)GHz de \(ap.name) en 20\(nb)MHz."], weight: 0.6)
        case .ghz5?:
            let others = siteAPs.filter { !$0.isOffline && $0.site == ap.site && $0.radio(.ghz5) != nil }.count
            if width >= 160 && others >= 2 {
                return WifiCauseResult(cause: .width, verdict: .watch,
                                       summary: "160\(nb)MHz avec \(others) bornes 5\(nb)GHz sur le site\(nb): il ne reste que deux blocs, les bornes se chevauchent.",
                                       evidence: ["\(ap.name) \(label)"], actions: ["Réduire la largeur 5\(nb)GHz à 80 ou 40\(nb)MHz\(nb): plus de canaux libres, débit encore largement suffisant."], weight: 0.4)
            }
            if width >= 80 && others >= 4 && !overlaps(of: radio, on: ap, siteAPs: siteAPs).isEmpty {
                return WifiCauseResult(cause: .width, verdict: .watch,
                                       summary: "80\(nb)MHz avec \(others) bornes 5\(nb)GHz\(nb): six blocs seulement, d’où les chevauchements.",
                                       evidence: ["\(ap.name) \(label)", "\(others) bornes en 5\(nb)GHz sur le site"],
                                       actions: ["Réduire la largeur 5\(nb)GHz à 40\(nb)MHz sur les bornes qui se chevauchent\(nb): douze blocs au lieu de six."], weight: 0.35)
            }
        default:
            break
        }
        return WifiCauseResult(cause: .width, verdict: .ok, summary: "Largeur adaptée à la bande.", evidence: ["\(ap.name) \(label)"])
    }

    static func width(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ap = input.ap, let radio = input.radio, radio.channel != nil else {
            return WifiCauseResult(cause: .width, verdict: .notMeasured, summary: "Borne ou radio du client inconnue.")
        }
        return widthResult(radio: radio, ap: ap, siteAPs: input.siteAPs)
    }

    /// Canaux DFS du 5 GHz (radar) en Amérique du Nord.
    public static func isDFS(channel: Int, band: WifiBand?) -> Bool {
        (band ?? WifiBand.guess(channel: channel)) == .ghz5 && (52...144).contains(channel)
    }

    static func dfsResult(radio: FortiAPRadio, ap: FortiManagedAP, changes: Int?) -> WifiCauseResult {
        guard let channel = radio.channel, radio.band == .ghz5 else {
            return WifiCauseResult(cause: .dfs, verdict: .ok, summary: "Sans objet hors de la bande 5\(nb)GHz.")
        }
        guard isDFS(channel: channel, band: radio.band) else {
            return WifiCauseResult(cause: .dfs, verdict: .ok, summary: "Canal \(channel) hors DFS\(nb): pas de coupure radar possible.")
        }
        var evidence = ["\(ap.name) sur le canal \(channel), un canal DFS (52 à 144)"]
        let actions = ["Sortir \(ap.name) des canaux DFS (36 à 48 ou 149 à 165), ou exclure les canaux touchés par le radar dans le profil FortiAP."]
        if let changes {
            evidence.append("\(plural(changes, "changement de canal", "changements de canal")) dû\(changes > 1 ? "s" : "") au radar récemment")
            if changes >= 2 {
                return WifiCauseResult(cause: .dfs, verdict: .problem, summary: "Le radar fait changer la borne de canal\(nb): chaque fois, les clients sont coupés une minute.",
                                       evidence: evidence, actions: actions, weight: 0.4 + Double(min(changes, 6)) / 10)
            }
            if changes == 1 {
                return WifiCauseResult(cause: .dfs, verdict: .watch, summary: "Un changement de canal radar récent\(nb): une coupure courte a pu se produire.",
                                       evidence: evidence, actions: actions, weight: 0.3)
            }
        } else {
            evidence.append("Changements de canal radar non lus")
        }
        return WifiCauseResult(cause: .dfs, verdict: .ok,
                               summary: "Canal DFS\(nb): très bien tant qu’aucun radar n’est détecté (certains vieux postes ne le voient pas).",
                               evidence: evidence)
    }

    static func dfs(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ap = input.ap, let radio = input.radio, radio.channel != nil else {
            return WifiCauseResult(cause: .dfs, verdict: .notMeasured, summary: "Borne ou radio du client inconnue.")
        }
        return dfsResult(radio: radio, ap: ap, changes: input.measures.dfsChannelChanges)
    }

    // MARK: Charge et clients lents

    /// Clients d'une radio, d'après la liste (le compte de la radio s'il est plus grand).
    static func radioClients(_ radio: FortiAPRadio, in clients: [FortiWifiClient]) -> [FortiWifiClient] {
        clients.filter { $0.radioID == radio.radioID || ($0.radioID == nil && $0.band != nil && $0.band == radio.band) }
    }

    static func loadResult(radio: FortiAPRadio, ap: FortiManagedAP, clients: [FortiWifiClient], _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let listed = radioClients(radio, in: clients).count
        let count = max(radio.clientCount ?? 0, listed)
        let watchAt = Int((Double(t.maxClientsPerRadio) * 0.75).rounded())
        var evidence = ["\(plural(count, "client", "clients")) sur \(ap.name) \(radioLabel(radio)) (surchargée au-delà de \(t.maxClientsPerRadio))"]
        let total = max(ap.totalClients, clients.count)
        if total > count { evidence.append("\(plural(total, "client", "clients")) sur la borne au total") }
        let actions = ["Activer l’équilibrage de charge entre bornes et entre bandes (Frequency Handoff et AP Handoff du profil FortiAP).",
                       "Ajouter une borne dans la zone la plus dense (salle de réunion, accueil).",
                       "Limiter le nombre de clients par radio dans le profil FortiAP pour forcer la répartition."]
        if count > t.maxClientsPerRadio {
            return WifiCauseResult(cause: .load, verdict: .problem, summary: "La radio sert trop de clients\(nb): chacun n’a qu’une petite part du temps d’antenne.",
                                   evidence: evidence, actions: actions,
                                   weight: 0.5 + excess(Double(count), beyond: Double(t.maxClientsPerRadio), span: Double(t.maxClientsPerRadio)) / 2)
        }
        if count >= watchAt {
            return WifiCauseResult(cause: .load, verdict: .watch, summary: "La radio approche de sa limite de clients.", evidence: evidence,
                                   actions: Array(actions.prefix(1)), weight: 0.3)
        }
        return WifiCauseResult(cause: .load, verdict: .ok, summary: "Charge normale.", evidence: evidence)
    }

    static func load(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ap = input.ap, let radio = input.radio else {
            return WifiCauseResult(cause: .load, verdict: .notMeasured, summary: "Borne ou radio du client inconnue.")
        }
        return loadResult(radio: radio, ap: ap, clients: input.apClients, t)
    }

    static func slowResult(radio: FortiAPRadio, ap: FortiManagedAP, clients: [FortiWifiClient], _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let mine = radioClients(radio, in: clients)
        let rated = mine.filter { $0.rateMbps != nil }
        guard rated.count >= 2 else {
            return WifiCauseResult(cause: .slowClients, verdict: rated.isEmpty && mine.count > 1 ? .notMeasured : .ok,
                                   summary: rated.isEmpty && mine.count > 1 ? "Débits des clients non donnés." : "Pas d’autre client sur cette radio.")
        }
        let slow = rated.filter { ($0.rateMbps ?? 0) < t.lowRateMbps }.sorted { ($0.rateMbps ?? 0) < ($1.rateMbps ?? 0) }
        let share = Double(slow.count) / Double(rated.count)
        var evidence = ["\(slow.count) client\(slow.count > 1 ? "s" : "") sur \(rated.count) sous \(rate(t.lowRateMbps)) sur \(ap.name) \(radioLabel(radio))"]
        if !slow.isEmpty {
            evidence.append("Les plus lents\(nb): " + slow.prefix(3).map { "\($0.displayName) (\(rate($0.rateMbps ?? 0)))" }.joined(separator: ", "))
        }
        let busy = (radio.channelUtilization ?? 0) > t.busyUtilization
        var actions = ["Retirer les débits de base anciens (1, 2, 5,5 et 11\(nb)Mb/s)\(nb): débit minimal de 12 ou 24\(nb)Mb/s sur le SSID."]
        if radio.band == .ghz24 { actions.append("Activer le pilotage de bande (band steering) pour envoyer les postes bi-bande en 5\(nb)GHz.") }
        if !slow.isEmpty { actions.append("Remplacer, câbler ou rapprocher les postes les plus lents (" + slow.prefix(3).map(\.displayName).joined(separator: ", ") + ").") }
        if share >= t.slowShare && busy {
            return WifiCauseResult(cause: .slowClients, verdict: .problem,
                                   summary: "Des clients lents monopolisent le temps d’antenne d’un canal déjà chargé\(nb): tout le monde ralentit.",
                                   evidence: evidence, actions: actions, weight: 0.4 + share / 2)
        }
        if share >= t.slowShare || slow.count >= 3 {
            return WifiCauseResult(cause: .slowClients, verdict: .watch,
                                   summary: "Plusieurs clients lents sur la radio\(nb): ils prennent plus de temps d’antenne que les autres.",
                                   evidence: evidence, actions: actions, weight: share / 2)
        }
        return WifiCauseResult(cause: .slowClients, verdict: .ok, summary: "Pas de client lent qui ralentisse les autres.", evidence: evidence)
    }

    static func slowClients(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ap = input.ap, let radio = input.radio else {
            return WifiCauseResult(cause: .slowClients, verdict: .notMeasured, summary: "Borne ou radio du client inconnue.")
        }
        return slowResult(radio: radio, ap: ap, clients: input.apClients, t)
    }

    // MARK: Client

    static func clientCapability(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let c = input.client
        let d = input.details
        let tx = d.txRateMbps ?? c.rateMbps
        let rx = d.rxRateMbps
        guard tx != nil || rx != nil || d.standard != nil || d.spatialStreams != nil || d.powerSave != nil else {
            return WifiCauseResult(cause: .client, verdict: .notMeasured, summary: "Débit, standard et antennes du client non donnés.")
        }
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence: [String] = []
        var actions: [String] = []
        let weakSignal = (c.rssi ?? 0) < t.weakRSSI
        if tx != nil || rx != nil {
            var line = "Débit négocié"
            if let tx { line += " \(rate(tx)) vers le client" }
            if let rx { line += (tx != nil ? "," : "") + " \(rate(rx)) depuis le client" }
            evidence.append(line + " (bas sous \(rate(t.lowRateMbps)))")
            let low = [tx, rx].compactMap { $0 }.min() ?? .infinity
            if low < t.lowRateMbps {
                // Débit bas avec un signal faible : la conséquence du signal, pas du poste.
                verdict = weakSignal ? .watch : .problem
                weight = excess(t.lowRateMbps - low, beyond: 0, span: t.lowRateMbps) * (weakSignal ? 0.4 : 0.8)
            }
        }
        if let standard = d.standard {
            evidence.append("Standard\(nb): \(standard.label)")
            if standard == .legacy {
                verdict = .problem
                weight = max(weight, 0.6)
                actions.append("Poste en 802.11a/b/g\(nb): le remplacer, lui ajouter un adaptateur Wi-Fi 6 ou le câbler\(nb); il ralentit toute la radio.")
            } else if standard == .wifi4 {
                verdict = max(verdict, .watch)
                weight = max(weight, 0.3)
                actions.append("Poste en Wi-Fi 4\(nb): prévoir un adaptateur Wi-Fi 6 (USB ou carte) pour un débit et une itinérance nettement meilleurs.")
            }
        }
        if let streams = d.spatialStreams {
            evidence.append("\(plural(streams, "flux spatial", "flux spatiaux")) (antennes)")
            if streams <= 1 {
                verdict = max(verdict, .watch)
                weight = max(weight, 0.25)
                actions.append("Une seule antenne\(nb): le débit plafonne (tablette, terminal, objet connecté)\(nb); placer ce poste près d’une borne.")
            }
        }
        if d.powerSave == true {
            evidence.append("Économie d’énergie Wi-Fi active")
            verdict = max(verdict, .watch)
            weight = max(weight, 0.25)
            actions.append("Désactiver l’économie d’énergie de la carte Wi-Fi du poste (mode «\(nb)performances maximales\(nb)»).")
        }
        if verdict >= .watch { actions.append("Mettre à jour le pilote de la carte Wi-Fi du poste (les vieux pilotes gèrent mal l’itinérance et le 5\(nb)GHz).") }
        let summary: String
        switch verdict {
        case .problem: summary = "Le poste lui-même limite le débit\(nb): ancien standard ou débit négocié trop bas malgré un signal correct."
        case .watch: summary = weakSignal ? "Débit bas, surtout à cause du signal\(nb); le poste a aussi ses limites." : "Le poste a des limites qui pèsent sur son débit."
        default: summary = "Le poste négocie un bon débit."
        }
        return WifiCauseResult(cause: .client, verdict: verdict, summary: summary, evidence: evidence, actions: actions, weight: weight)
    }

    static func band(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let c = input.client
        guard let band = c.band else {
            return WifiCauseResult(cause: .band, verdict: .notMeasured, summary: "Bande du client inconnue.")
        }
        guard band == .ghz24 else {
            return WifiCauseResult(cause: .band, verdict: .ok, summary: "Client en \(band.label)\(nb): la bonne bande.", evidence: ["Client en \(band.label)"])
        }
        let ap5 = input.ap.map { $0.radio(.ghz5) != nil || $0.radio(.ghz6) != nil }
        let capable = input.details.supports5GHz ?? (input.details.standard.map { $0 >= .wifi5 })
        var evidence = ["Client en 2,4\(nb)GHz" + (c.channel.map { " (canal \($0))" } ?? "")]
        if ap5 == true { evidence.append("\(input.ap?.name ?? "La borne") émet aussi en 5\(nb)GHz") }
        if capable == true { evidence.append("Le poste sait se connecter en 5\(nb)GHz") }
        let actions = ["Activer le pilotage de bande (band steering, «\(nb)Prefer 5 GHz\(nb)») sur \(c.ssid.map(quoted) ?? "le SSID").",
                       "Sur le poste\(nb): choisir «\(nb)5\(nb)GHz de préférence\(nb)» dans les réglages avancés de la carte Wi-Fi.",
                       "Réserver le 2,4\(nb)GHz aux objets qui n’ont que cette bande (SSID séparé si le pilotage ne suffit pas)."]
        if ap5 == true && capable == true {
            return WifiCauseResult(cause: .band, verdict: .problem,
                                   summary: "Le poste reste en 2,4\(nb)GHz alors que le 5\(nb)GHz est disponible\(nb): bande lente et encombrée.",
                                   evidence: evidence, actions: actions, weight: 0.55)
        }
        if ap5 == true && capable == nil {
            return WifiCauseResult(cause: .band, verdict: .watch,
                                   summary: "Client en 2,4\(nb)GHz alors que la borne émet aussi en 5\(nb)GHz (capacité 5\(nb)GHz du poste inconnue).",
                                   evidence: evidence, actions: actions, weight: 0.35)
        }
        return WifiCauseResult(cause: .band, verdict: .ok,
                               summary: ap5 == false ? "La borne n’émet qu’en 2,4\(nb)GHz." : "Le poste n’a que le 2,4\(nb)GHz.", evidence: evidence)
    }

    // MARK: Connexion et authentification

    static func connection(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let c = input.client
        let d = input.details
        guard d.authFailures != nil || d.disconnects != nil || d.roams != nil || c.associatedFor != nil || d.lastFailureReason != nil else {
            return WifiCauseResult(cause: .connection, verdict: .notMeasured, summary: "Déconnexions et échecs d’authentification non lus.")
        }
        let window = max(1, d.windowMinutes ?? 60)
        let windowLabel = window >= 60 && window % 60 == 0 ? (window == 60 ? "la dernière heure" : "les \(window / 60) dernières heures") : "les \(window) dernières minutes"
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence: [String] = []
        var actions: [String] = []
        if let auth = d.authMethod { evidence.append("Authentification\(nb): \(auth)") }
        if let failures = d.authFailures {
            evidence.append("\(plural(failures, "échec", "échecs")) d’authentification sur \(windowLabel)")
            if failures >= t.authFailuresProblem { verdict = .problem; weight = max(weight, 0.7) }
            else if failures > 0 { verdict = max(verdict, .watch); weight = max(weight, 0.3) }
        }
        let reason = d.lastFailureReason?.lowercased() ?? ""
        if let raw = d.lastFailureReason { evidence.append("Dernier échec\(nb): \(raw)") }
        if reason.contains("passe") || reason.contains("password") || reason.contains("psk") || reason.contains("4-way") || reason.contains("handshake") {
            actions.append("Mot de passe refusé\(nb): oublier le réseau sur le poste et ressaisir la clé du SSID (vérifier qu’elle n’a pas changé).")
        }
        if reason.contains("radius") || reason.contains("802.1x") || reason.contains("eap") || reason.contains("reject") || reason.contains("refus") || reason.contains("certificat") {
            actions.append("802.1X refusé\(nb): vérifier le compte de l’utilisateur et le journal du serveur RADIUS (NPS, FortiAuthenticator), le certificat du serveur et l’heure du poste.")
        }
        if let n = d.disconnects {
            evidence.append("\(plural(n, "déconnexion", "déconnexions")) sur \(windowLabel)")
            if n >= t.disconnectsProblem { verdict = .problem; weight = max(weight, 0.5 + excess(Double(n), beyond: Double(t.disconnectsProblem), span: 20) / 2) }
            else if n >= t.disconnectsWatch { verdict = max(verdict, .watch); weight = max(weight, 0.35) }
        }
        if let roams = d.roams {
            let perHour = Double(roams) * 60 / Double(window)
            evidence.append("\(plural(roams, "itinérance", "itinérances")) entre bornes sur \(windowLabel)")
            if perHour >= Double(t.roamsPerHourWatch) {
                verdict = max(verdict, .watch)
                weight = max(weight, 0.35)
                actions.append("Itinérances trop fréquentes\(nb): baisser la puissance des bornes qui se recouvrent trop, ou relever le seuil d’itinérance du poste.")
            }
        }
        if let since = c.associatedFor {
            evidence.append("Associé depuis \(minutes(since))")
            if since < 120 && (d.disconnects ?? 0) > 0 {
                verdict = max(verdict, .watch)
                weight = max(weight, 0.3)
            }
        }
        if verdict >= .watch, d.disconnects ?? 0 > 0 {
            actions.append("Déconnexions répétées\(nb): comparer avec le signal (le client décroche-t-il en bout de zone\(nb)?) et vérifier le délai de réauthentification du SSID.")
        }
        let summary: String
        switch verdict {
        case .problem where (d.authFailures ?? 0) >= t.authFailuresProblem: summary = "L’authentification échoue à répétition\(nb): le client n’arrive pas à se connecter durablement."
        case .problem: summary = "Le client se déconnecte souvent."
        case .watch: summary = "Quelques déconnexions ou itinérances à surveiller."
        default: summary = "Connexion stable."
        }
        return WifiCauseResult(cause: .connection, verdict: verdict, summary: summary, evidence: evidence, actions: actions, weight: weight)
    }

    // MARK: DHCP

    static func dhcp(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let c = input.client
        let vlan = c.vlan.map { " du VLAN \($0)" } ?? ""
        let serverAction = "Vérifier le serveur DHCP\(vlan) (étendue active, relais DHCP) et que le SSID \(c.ssid.map(quoted) ?? "") est bien sur le bon VLAN."
        guard let ip = c.ip else {
            return WifiCauseResult(cause: .dhcp, verdict: .problem, summary: "Le client n’a pas d’adresse IP\(nb): il est associé mais ne peut rien faire.",
                                   evidence: ["Aucune adresse IP connue de la FortiGate"], actions: [serverAction], weight: 0.9)
        }
        if ip.value >> 16 == (169 << 8 | 254) {
            return WifiCauseResult(cause: .dhcp, verdict: .problem,
                                   summary: "Adresse 169.254 attribuée par le poste lui-même\(nb): le serveur DHCP n’a pas répondu.",
                                   evidence: ["Adresse \(ip)"], actions: [serverAction, "Sur le poste\(nb): renouveler le bail (désactiver puis réactiver le Wi-Fi)."], weight: 0.95)
        }
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence = ["Adresse \(ip) obtenue"]
        var actions: [String] = []
        if let scope = input.measures.dhcp {
            evidence.append("Étendue \(scope.scopeName)\(nb): \(pct(scope.percent)) occupée, \(plural(scope.free, "adresse libre", "adresses libres")) sur \(scope.poolSize)")
            if scope.critical || scope.free == 0 {
                verdict = .problem
                weight = 0.6
            } else if scope.warning {
                verdict = .watch
                weight = 0.3
            }
            if verdict >= .watch {
                actions.append("Libérer des adresses dans l’étendue \(scope.scopeName)\(nb): bail plus court (invités), plage élargie, ou sous-réseau plus grand.")
            }
        }
        if let delay = input.details.dhcpDelayMs {
            evidence.append("Adresse obtenue en \(ms(delay))")
            if delay > t.dhcpDelayProblem { verdict = .problem; weight = max(weight, 0.5) }
            else if delay > t.dhcpDelayWatch { verdict = max(verdict, .watch); weight = max(weight, 0.3) }
            if delay > t.dhcpDelayWatch { actions.append("DHCP lent\(nb): vérifier la charge du serveur DHCP et le relais entre le VLAN et le serveur.") }
        }
        let summary: String
        switch verdict {
        case .problem: summary = "Le DHCP risque de refuser des adresses (étendue pleine ou serveur lent)."
        case .watch: summary = "Le DHCP fonctionne, mais l’étendue ou le délai est à surveiller."
        default: summary = "Le client a une adresse valide."
        }
        return WifiCauseResult(cause: .dhcp, verdict: verdict, summary: summary, evidence: evidence, actions: actions, weight: weight)
    }

    // MARK: Au-delà du Wi-Fi

    static func network(_ m: WifiDiagnosisMeasures, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard !m.paths.isEmpty else {
            return WifiCauseResult(cause: .network, verdict: .notMeasured, summary: "Mesures non faites (ping depuis ce Mac vers la passerelle, le DNS et Internet).")
        }
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence: [String] = []
        var bad: Set<WifiPathTarget> = []
        for p in m.paths {
            var line = "\(p.target.label) \(p.address)\(nb): "
            if p.received == 0 {
                line += "aucune réponse sur \(p.sent)"
                bad.insert(p.target)
                verdict = .problem
                weight = max(weight, 0.8)
                evidence.append(line)
                continue
            }
            line += "perte \(pct(p.lossPercent)), moyenne \(ms(p.averageMs))"
            if let j = p.jitterMs { line += ", gigue \(ms(j))" }
            evidence.append(line)
            let latencyWatch = p.target == .internet ? t.internetLatencyWatch : t.gatewayLatencyWatch
            let latencyProblem = p.target == .internet ? t.internetLatencyProblem : t.gatewayLatencyProblem
            let avg = p.averageMs ?? 0
            if p.lossPercent > t.lossProblem || avg > latencyProblem {
                verdict = .problem
                bad.insert(p.target)
                weight = max(weight, 0.5 + excess(p.lossPercent, beyond: t.lossProblem, span: 20) / 2)
            } else if p.lossPercent > t.lossWatch || avg > latencyWatch || (p.jitterMs ?? 0) > t.jitterWatch {
                verdict = max(verdict, .watch)
                bad.insert(p.target)
                weight = max(weight, 0.3)
            }
        }
        var actions: [String] = []
        if bad.contains(.gateway) {
            actions.append("Le problème n’est pas que Wi-Fi\(nb): la passerelle répond mal même depuis ce Mac\(nb); vérifier sa charge et le câblage vers elle.")
        }
        if bad.contains(.dns) && !bad.contains(.gateway) {
            actions.append("Vérifier le serveur DNS (\(m.path(.dns)?.address ?? "DNS")) ou en donner un autre par DHCP.")
        }
        if bad.contains(.internet) && !bad.contains(.gateway) {
            actions.append("Vérifier le lien Internet du site (débit, perte, SD-WAN) et la mise en forme du trafic (traffic shaping) du SSID.")
        }
        if verdict >= .watch {
            actions.append("Lancer un Ping continu vers la passerelle depuis ce Mac (Ping continu), puis depuis le poste du client pour comparer.")
        }
        let summary: String
        switch verdict {
        case .problem where bad.contains(.gateway): summary = "Le réseau local lui-même perd des paquets (mesuré depuis ce Mac)\(nb): le Wi-Fi n’est pas le seul en cause."
        case .problem: summary = "Internet ou le DNS répond mal (mesuré depuis ce Mac)."
        case .watch: summary = "Latence ou perte légère vers \(bad.map(\.label).sorted().joined(separator: ", ").lowercased()) (mesuré depuis ce Mac)."
        default: summary = "Passerelle, DNS et Internet répondent bien (mesuré depuis ce Mac)."
        }
        return WifiCauseResult(cause: .network, verdict: verdict, summary: summary, evidence: evidence, actions: actions, weight: weight)
    }

    static func uplink(_ m: WifiDiagnosisMeasures, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let u = m.uplink else {
            return WifiCauseResult(cause: .uplink, verdict: .notMeasured, summary: "Port du switch de la borne inconnu (borne absente du dernier scan ou switch non lu).")
        }
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence = ["Branchée sur \(u.label)"]
        var actions: [String] = []
        if u.linkUp == false {
            evidence.append("Lien du port\(nb): coupé")
            verdict = .problem
            weight = 0.9
            actions.append("Le port \(u.label) est coupé\(nb): vérifier le câble, la prise murale et le port (activé, VLAN).")
        }
        if let speed = u.speedMbps {
            evidence.append("Vitesse\(nb): \(speed >= 1000 ? "\(speed / 1000)\(nb)Gb/s" : "\(speed)\(nb)Mb/s")" + (u.duplex.map { ", \($0)" } ?? ""))
            if speed <= 100 {
                verdict = .problem
                weight = max(weight, 0.7)
                actions.append("Le port \(u.label) n’est qu’à \(speed)\(nb)Mb/s\(nb): câble abîmé ou paire coupée\(nb); refaire le câble ou la prise (une borne Wi-Fi 6 a besoin de 1\(nb)Gb/s au moins).")
            }
        }
        if u.duplex?.lowercased().contains("half") == true {
            verdict = .problem
            weight = max(weight, 0.7)
            actions.append("Port en semi-duplex\(nb): remettre la négociation automatique des deux côtés.")
        }
        if let errors = u.rxErrors {
            evidence.append("\(plural(Int(min(errors, UInt64(Int.max))), "erreur", "erreurs")) en réception")
            if errors >= 1000 { verdict = .problem; weight = max(weight, 0.6) }
            else if errors > 0 { verdict = max(verdict, .watch); weight = max(weight, 0.3) }
            if errors > 0 { actions.append("Erreurs sur \(u.label)\(nb): tester le câble (test de câble du switch) et remplacer le cordon de brassage.") }
        }
        if let poe = u.poeLabel {
            evidence.append("PoE\(nb): \(poe)" + (u.poePowerW.map { " (\(PingFormat.decimal($0))\(nb)W)" } ?? ""))
        }
        if u.poeFault {
            verdict = .problem
            weight = max(weight, 0.8)
            actions.append("Défaut PoE sur \(u.label)\(nb): vérifier le budget PoE du switch et la classe demandée par la borne.")
        }
        let summary: String
        switch verdict {
        case .problem: summary = "Le lien entre la borne et son switch limite ou coupe le trafic."
        case .watch: summary = "Le lien de la borne fonctionne, avec quelques erreurs."
        default: summary = "Lien de la borne normal."
        }
        return WifiCauseResult(cause: .uplink, verdict: verdict, summary: summary, evidence: evidence, actions: actions, weight: weight)
    }

    static func wan(_ m: WifiDiagnosisMeasures, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard !m.wan.isEmpty else {
            return WifiCauseResult(cause: .wan, verdict: .notMeasured, summary: "État du WAN du site non lu.")
        }
        var verdict = WifiVerdict.ok
        var weight = 0.0
        var evidence: [String] = []
        for link in m.wan {
            var line = link.name + "\(nb): " + (link.up == false ? "tombé" : "actif")
            if let l = link.latencyMs { line += ", latence \(ms(l))" }
            if let p = link.lossPercent { line += ", perte \(pct(p))" }
            evidence.append(line)
            if link.up == false { verdict = max(verdict, m.wan.allSatisfy { $0.up == false } ? .problem : .watch); weight = max(weight, 0.6) }
            if (link.lossPercent ?? 0) > t.lossProblem || (link.latencyMs ?? 0) > t.internetLatencyProblem { verdict = .problem; weight = max(weight, 0.6) }
            else if (link.lossPercent ?? 0) > t.lossWatch || (link.latencyMs ?? 0) > t.internetLatencyWatch { verdict = max(verdict, .watch); weight = max(weight, 0.3) }
        }
        let actions = verdict >= .watch ? ["Vérifier le lien WAN du site (fournisseur, modem, règles SD-WAN) avant de toucher au Wi-Fi."] : []
        return WifiCauseResult(cause: .wan, verdict: verdict,
                               summary: verdict == .problem ? "Le WAN du site est dégradé\(nb): tous les clients en souffrent." : (verdict == .watch ? "Un lien WAN est dégradé." : "WAN normal."),
                               evidence: evidence, actions: actions, weight: weight)
    }

    // MARK: SSID

    static func ssidLimits(_ input: WifiDiagnosisInput, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let ssid = input.ssid else {
            return WifiCauseResult(cause: .ssid, verdict: .notMeasured, summary: "Configuration du SSID non lue.")
        }
        var evidence = ["\(quoted(ssid.ssid))\(nb): \(ssid.securityLabel)" + (ssid.vlan.map { ", VLAN \($0)" } ?? "")]
        if ssid.captivePortal == true {
            evidence.append("Portail captif\(nb): une session expirée bloque la navigation sans couper le Wi-Fi")
        }
        if let max = ssid.maxClients, let count = input.ssidClientCount {
            evidence.append("\(plural(count, "client", "clients")) sur \(max) au plus")
            if count >= max {
                return WifiCauseResult(cause: .ssid, verdict: .problem, summary: "Le SSID a atteint son nombre maximal de clients\(nb): les nouveaux sont refusés.",
                                       evidence: evidence, actions: ["Relever la limite de clients du SSID \(quoted(ssid.ssid)) (max-clients) ou la répartir par borne."], weight: 0.8)
            }
            if Double(count) >= Double(max) * 0.9 {
                return WifiCauseResult(cause: .ssid, verdict: .watch, summary: "Le SSID approche de son nombre maximal de clients.",
                                       evidence: evidence, actions: ["Relever la limite de clients du SSID \(quoted(ssid.ssid)) avant qu’elle ne bloque."], weight: 0.3)
            }
        }
        return WifiCauseResult(cause: .ssid, verdict: .ok, summary: "Aucune limite du SSID atteinte.", evidence: evidence)
    }
}
