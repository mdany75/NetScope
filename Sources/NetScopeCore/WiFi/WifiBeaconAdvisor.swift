import Foundation

// Note 71 : constats tirés des éléments des balises, ajoutés aux recommandations de l'analyseur
// Wi-Fi (itinérance sans 802.11k/v/r, borne saturée, WPA2 seul quand WPA3 est possible).

public enum WifiBeaconAdvisor {
    /// Utilisation du canal (en %) au-delà de laquelle une borne est jugée saturée.
    public static let utilizationThreshold = 70
    /// Nombre de clients associés au-delà duquel une borne est jugée saturée.
    public static let clientThreshold = 40

    /// Identité d'une borne : BSSID sans le dernier octet ni le bit « administré localement »
    /// (les BSSID d'une même borne ne diffèrent que par le dernier octet).
    public static func apKey(_ network: WifiNetwork) -> UInt64? {
        network.bssid.map { ($0.value & ~UInt64(0x0200_0000_0000)) >> 8 }
    }

    /// Nom lisible d'une borne : nom annoncé, sinon BSSID.
    public static func apLabel(_ network: WifiNetwork) -> String {
        network.beacon?.apName ?? network.bssid?.formatted(.upperColon) ?? network.displaySSID
    }

    public static func isSaturated(_ load: WifiBSSLoad) -> Bool {
        load.utilizationPercent > utilizationThreshold || load.stationCount > clientThreshold
    }

    public static func recommendations(networks: [WifiNetwork], connected: WifiNetwork?) -> [WifiRecommendation] {
        roaming(networks, connected: connected) + saturation(networks, connected: connected) + wpa3(networks, connected: connected)
    }

    /// SSID nommés, avec balise lue, dans l'ordre : réseau connecté, puis les plus diffusés.
    /// Les BSSID suspects (même nom, autre constructeur) ne sont pas des bornes du réseau : écartés.
    private static func groups(_ networks: [WifiNetwork], connected: WifiNetwork?) -> [(ssid: String, members: [WifiNetwork])] {
        let twins = Set(WifiAdvisor.suspiciousTwins(networks, connected: connected).map(\.id))
        let withBeacon = networks.filter { !$0.isHidden && $0.beacon != nil && !twins.contains($0.id) }
        return Dictionary(grouping: withBeacon, by: { $0.ssid! })
            .map { (ssid: $0.key, members: $0.value.sorted { $0.rssi > $1.rssi }) }
            .sorted { a, b in
                let ca = a.ssid == connected?.ssid, cb = b.ssid == connected?.ssid
                if ca != cb { return ca }
                if a.members.count != b.members.count { return a.members.count > b.members.count }
                return a.ssid < b.ssid
            }
    }

    private static func names(_ list: [WifiNetwork]) -> String {
        var labels: [String] = []
        for network in list {
            let label = apLabel(network)
            if !labels.contains(label) { labels.append(label) }
        }
        let shown = labels.prefix(3).joined(separator: ", ")
        return labels.count > 3 ? "\(shown) et \(labels.count - 3) autre(s)" : shown
    }

    private static func join(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " et " + items.last!
    }

    // MARK: Itinérance

    public static func roaming(_ networks: [WifiNetwork], connected: WifiNetwork?) -> [WifiRecommendation] {
        var result: [WifiRecommendation] = []
        for (ssid, members) in groups(networks, connected: connected) {
            let aps = Set(members.compactMap(apKey))
            guard aps.count >= 2 else { continue }
            let features: [(String, (WifiBeaconInfo) -> Bool)] = [
                ("802.11k", { $0.supports11k }), ("802.11v", { $0.supports11v }), ("802.11r", { $0.supports11r }),
            ]
            var absent: [String] = []
            var partial: [(String, [WifiNetwork])] = []
            for (name, test) in features {
                let lacking = members.filter { !test($0.beacon!) }
                if lacking.count == members.count { absent.append(name) } else if !lacking.isEmpty { partial.append((name, lacking)) }
            }
            guard !absent.isEmpty || !partial.isEmpty else { continue }
            let enterprise = members.contains { $0.beacon?.rsn?.hasEnterprise == true }
            let lacksR = absent.contains("802.11r") || partial.contains { $0.0 == "802.11r" }
            let isConnected = connected?.ssid == ssid
            var sentences: [String] = []
            if !absent.isEmpty {
                sentences.append("\(aps.count) bornes diffusent ce réseau, mais aucune n’annonce \(join(absent)).")
            } else {
                sentences.append("\(aps.count) bornes diffusent ce réseau avec des réglages d’itinérance inégaux.")
            }
            for (name, lacking) in partial {
                sentences.append("\(name) absent sur \(names(lacking)).")
            }
            if enterprise && lacksR {
                sentences.append("En 802.1X, sans 802.11r chaque changement de borne refait toute l’authentification RADIUS (coupure des appels).")
            } else {
                sentences.append("Les clients changent de borne trop tard ou trop lentement\u{00A0}: activez 11k (liste des voisines), 11v (transition guidée) et 11r (transition rapide) sur le SSID.")
            }
            let focus = partial.first?.1.first ?? (isConnected ? members.first { $0.isConnected } : nil) ?? members.first
            result.append(WifiRecommendation(
                id: "itinerance-\(ssid)",
                severity: absent.count == 3 || (isConnected && enterprise && absent.contains("802.11r")) ? .alerte : .conseil,
                title: absent.count == 3 ? "Itinérance sans 802.11k/v/r\u{00A0}: «\u{00A0}\(ssid)\u{00A0}»"
                    : "Itinérance incomplète\u{00A0}: «\u{00A0}\(ssid)\u{00A0}»",
                detail: sentences.joined(separator: " "),
                networkID: focus?.id, band: focus?.band))
            if result.count == 3 { break }
        }
        return result
    }

    // MARK: Saturation

    public static func saturation(_ networks: [WifiNetwork], connected: WifiNetwork?) -> [WifiRecommendation] {
        struct Radio: Hashable { var ap: UInt64?; var channel: Int; var band: WifiBand }
        let loaded = networks.filter { $0.beacon?.bssLoad != nil }
        // Une radio (borne, canal) peut porter plusieurs SSID : un seul constat, clients additionnés.
        let radios = Dictionary(grouping: loaded) { Radio(ap: apKey($0) ?? UInt64($0.id.hashValue.magnitude), channel: $0.channel, band: $0.band) }
        var candidates: [(utilization: Int, recommendation: WifiRecommendation)] = []
        for (radio, members) in radios {
            let loads = members.compactMap { $0.beacon?.bssLoad }
            let utilization = loads.map(\.utilizationPercent).max() ?? 0
            let clients = loads.map(\.stationCount).reduce(0, +)
            guard utilization > utilizationThreshold || clients > clientThreshold else { continue }
            let focus = members.first { $0.isConnected } ?? members.max { $0.rssi < $1.rssi }!
            let named = focus.beacon?.apName
            let ssids = Set(members.map(\.displaySSID)).sorted()
            let subject = named ?? "«\u{00A0}\(focus.displaySSID)\u{00A0}»"
            var reasons: [String] = []
            if utilization > utilizationThreshold { reasons.append("canal occupé à \(utilization)\u{00A0}%") }
            if clients > clientThreshold { reasons.append("\(clients) clients associés") }
            let detail = "\(reasons.joined(separator: " et ").prefix(1).uppercased() + reasons.joined(separator: " et ").dropFirst()) "
                + "(seuils\u{00A0}: \(utilizationThreshold)\u{00A0}% ou \(clientThreshold) clients)"
                + (ssids.count > 1 ? " sur \(ssids.count) SSID (\(ssids.joined(separator: ", ")))" : "")
                + ". Ajoutez une borne dans la zone, poussez les clients vers le 5\u{00A0}GHz ou réduisez le nombre de SSID."
            candidates.append((utilization, WifiRecommendation(
                id: "sature-\(radio.band.rawValue)-\(radio.channel)-\(focus.id)",
                severity: utilization >= 90 ? .critique : .alerte,
                title: "Borne saturée\u{00A0}: \(subject) (\(radio.band.label), canal \(radio.channel))",
                detail: detail, networkID: focus.id, band: radio.band)))
        }
        return candidates.sorted { ($0.utilization, $0.recommendation.id) > ($1.utilization, $1.recommendation.id) }
            .prefix(4).map(\.recommendation)
    }

    // MARK: WPA3

    public static func wpa3(_ networks: [WifiNetwork], connected: WifiNetwork?) -> [WifiRecommendation] {
        var result: [WifiRecommendation] = []
        for (ssid, members) in groups(networks, connected: connected) {
            let personal = members.filter { $0.beacon?.security == .wpa2Personal }
            let withSAE = members.filter { $0.beacon?.rsn?.hasSAE == true }
            let capable = personal.filter { $0.beacon!.generation(band: $0.band).requiresWPA3Support }
            if !personal.isEmpty, !withSAE.isEmpty || !capable.isEmpty {
                let detail: String
                if !withSAE.isEmpty {
                    detail = "Le même réseau offre déjà WPA3 (SAE) sur \(withSAE.count) BSSID, mais \(personal.count) BSSID restent en WPA2-PSK seul (\(names(personal))). Activez le mode de transition WPA2/WPA3 sur toutes les bornes."
                } else {
                    let generation = capable.map { $0.beacon!.generation(band: $0.band) }.max()!
                    detail = "Ces bornes \(generation.label) prennent en charge WPA3 (exigé pour la certification Wi-Fi 6), mais n’annoncent que WPA2-PSK. Activez le mode de transition WPA2/WPA3 (PMF facultative) pour protéger les clients récents."
                }
                let focus = personal.first!
                result.append(WifiRecommendation(id: "wpa3-\(ssid)", severity: .conseil,
                                                 title: "WPA2 seul alors que WPA3 est possible\u{00A0}: «\u{00A0}\(ssid)\u{00A0}»",
                                                 detail: detail, networkID: focus.id, band: focus.band))
            } else {
                let enterprise = members.filter {
                    $0.beacon?.security == .wpa2Enterprise && $0.beacon!.pmf == .absent
                        && $0.beacon!.generation(band: $0.band).requiresWPA3Support
                }
                if let focus = enterprise.first {
                    result.append(WifiRecommendation(
                        id: "wpa3-\(ssid)", severity: .conseil,
                        title: "WPA2-Entreprise sans PMF\u{00A0}: «\u{00A0}\(ssid)\u{00A0}»",
                        detail: "Ces bornes \(focus.beacon!.generation(band: focus.band).label) peuvent passer en WPA3-Entreprise (PMF obligatoire), qui protège les trames de gestion contre la déauthentification forcée.",
                        networkID: focus.id, band: focus.band))
                }
            }
            if result.count == 3 { break }
        }
        return result
    }
}

// MARK: - Encodeur (démonstration et tests)

/// Fabrique des éléments d'information au format des balises réelles : sert aux données de
/// démonstration et aux tests (aller-retour avec le parseur).
public enum WifiBeaconBuilder {
    public static func element(_ id: UInt8, _ body: [UInt8]) -> [UInt8] {
        let clipped = Array(body.prefix(255))
        return [id, UInt8(clipped.count)] + clipped
    }

    public static func extended(_ extID: UInt8, _ body: [UInt8]) -> [UInt8] {
        element(255, [extID] + body)
    }

    public static func ssid(_ name: String?) -> [UInt8] {
        element(0, Array((name ?? "").utf8))
    }

    public static func dsParameter(channel: Int) -> [UInt8] { element(3, [UInt8(clamping: channel)]) }

    public static func tim(dtimPeriod: Int) -> [UInt8] { element(5, [0, UInt8(clamping: dtimPeriod), 0, 0]) }

    public static func country(_ code: String, firstChannel: Int, count: Int, maxPower: Int) -> [UInt8] {
        element(7, Array(code.utf8.prefix(2)) + [0x20, UInt8(clamping: firstChannel), UInt8(clamping: count), UInt8(clamping: maxPower)])
    }

    public static func bssLoad(clients: Int, utilization: Int, capacity: Int = 0) -> [UInt8] {
        element(11, le16(clients) + [UInt8(clamping: utilization)] + le16(capacity))
    }

    /// Utilisation exprimée en pourcentage (convertie sur 255).
    public static func bssLoad(clients: Int, utilizationPercent: Int, capacity: Int = 0) -> [UInt8] {
        bssLoad(clients: clients, utilization: Int((Double(utilizationPercent) * 255 / 100).rounded()), capacity: capacity)
    }

    public static func htCapabilities(streams: Int) -> [UInt8] {
        var mcs = [UInt8](repeating: 0, count: 16)
        for k in 0..<min(4, max(1, streams)) { mcs[k] = 0xFF }
        return element(45, [0xEF, 0x09, 0x17] + mcs + [0, 0, 0, 0, 0, 0, 0])
    }

    public static func htOperation(primary: Int, width40: Bool) -> [UInt8] {
        element(61, [UInt8(clamping: primary), width40 ? 0x05 : 0x00] + [UInt8](repeating: 0, count: 20))
    }

    public static func vhtCapabilities(streams: Int) -> [UInt8] {
        let map = le16(Int(mcsMap(streams: streams)))
        return element(191, [0xB2, 0x79, 0x83, 0x0F] + map + [0, 0] + map + [0, 0])
    }

    /// 20/40 MHz : code 0 ; 80 MHz : centre ; 160 MHz : centre du bloc de 80 puis centre de 160.
    public static func vhtOperation(widthMHz: Int, center: Int) -> [UInt8] {
        switch widthMHz {
        case 160: return element(192, [1, UInt8(clamping: center - 8), UInt8(clamping: center), 0xFC, 0xFF])
        case 80: return element(192, [1, UInt8(clamping: center), 0, 0xFC, 0xFF])
        default: return element(192, [0, 0, 0, 0xFC, 0xFF])
        }
    }

    public static func heCapabilities(streams: Int) -> [UInt8] {
        let map = le16(Int(mcsMap(streams: streams)))
        let mac: [UInt8] = [0x0D, 0x01, 0x08, 0x1A, 0x40, 0x00]
        let phy: [UInt8] = [0x04, 0x70, 0x0C, 0x89, 0x7F, 0x03, 0x80, 0x04, 0x00, 0x00, 0x00]
        return extended(35, mac + phy + map + map)
    }

    /// HE Operation ; en 6 GHz, informations 6 GHz (canal primaire, largeur, centre).
    public static func heOperation(sixGHz: (primary: Int, widthMHz: Int, center: Int)? = nil) -> [UInt8] {
        var params: UInt32 = 0x0001F4
        var tail: [UInt8] = []
        if let six = sixGHz {
            params |= 1 << 17
            let code: UInt8 = six.widthMHz >= 160 ? 3 : (six.widthMHz >= 80 ? 2 : (six.widthMHz >= 40 ? 1 : 0))
            tail = [UInt8(clamping: six.primary), code, UInt8(clamping: six.center), 0, 0x0B]
        }
        let head: [UInt8] = [UInt8(params & 0xFF), UInt8((params >> 8) & 0xFF), UInt8((params >> 16) & 0xFF), 0x2A, 0xFC, 0xFF]
        return extended(36, head + tail)
    }

    public static func ehtCapabilities() -> [UInt8] {
        extended(108, [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x22, 0x22, 0x22])
    }

    public static func ehtOperation(widthMHz: Int, center: Int) -> [UInt8] {
        let code: UInt8
        switch widthMHz {
        case 320: code = 4
        case 160: code = 3
        case 80: code = 2
        case 40: code = 1
        default: code = 0
        }
        return extended(106, [0x01, 0x44, 0x44, 0x44, 0x44, code, UInt8(clamping: center), 0])
    }

    /// RSN : AKM et chiffres de l'OUI IEEE (00-0F-AC).
    public static func rsn(akms: [UInt8], pairwise: [UInt8] = [4], group: UInt8 = 4, pmf: WifiPMF = .absent) -> [UInt8] {
        var body: [UInt8] = [1, 0, 0x00, 0x0F, 0xAC, group]
        body += le16(pairwise.count) + pairwise.flatMap { [0x00, 0x0F, 0xAC, $0] }
        body += le16(akms.count) + akms.flatMap { [0x00, 0x0F, 0xAC, $0] }
        let caps: UInt16 = 0x000C | (pmf == .absent ? 0 : 0x0080) | (pmf == .required ? 0x0040 : 0)
        body += [UInt8(caps & 0xFF), UInt8(caps >> 8)]
        return element(48, body)
    }

    public static func mobilityDomain(_ mdid: UInt16, overDS: Bool) -> [UInt8] {
        element(54, [UInt8(mdid & 0xFF), UInt8(mdid >> 8), overDS ? 0x01 : 0x00])
    }

    public static func rmCapabilities(neighborReport: Bool) -> [UInt8] {
        element(70, [neighborReport ? 0x73 : 0x71, 0xD0, 0x00, 0x00, 0x0C])
    }

    public static func extendedCapabilities(bssTransition: Bool) -> [UInt8] {
        element(127, [0x04, 0x00, bssTransition ? 0x08 : 0x00, 0x00, 0x00, 0x00, 0x00, 0x40])
    }

    public static func wmm() -> [UInt8] {
        element(221, [0x00, 0x50, 0xF2, 0x02, 0x01, 0x01, 0x80, 0x00, 0x03, 0xA4, 0x00, 0x00, 0x27, 0xA4, 0x00, 0x00,
                      0x42, 0x43, 0x5E, 0x00, 0x62, 0x32, 0x2F, 0x00])
    }

    public static func fortinet(name: String, model: String? = nil, serial: String? = nil) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x09, 0x0F, 0x0A, 0x00]
        body += tlv(1, name)
        if let model { body += tlv(2, model) }
        if let serial { body += tlv(3, serial) }
        return element(221, body)
    }

    public static func aruba(name: String) -> [UInt8] {
        element(221, [0x00, 0x0B, 0x86, 0x03, 0x00] + Array(name.utf8))
    }

    public static func cisco(name: String, clients: Int) -> [UInt8] {
        var nameBytes = Array(name.utf8.prefix(15))
        nameBytes += [UInt8](repeating: 0, count: 16 - nameBytes.count)
        return element(133, [0x00, 0x00, 0x8F, 0x00, 0x0F, 0x00, 0xFF, 0x03, 0x59, 0x00] + nameBytes
                       + [UInt8(clamping: clients), 0x00, 0x00, 0x25])
    }

    public static func wps(device: String?, manufacturer: String?, model: String?) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x50, 0xF2, 0x04, 0x10, 0x4A, 0x00, 0x01, 0x10, 0x10, 0x44, 0x00, 0x01, 0x02]
        func attribute(_ type: UInt16, _ text: String?) {
            guard let text else { return }
            let bytes = Array(text.utf8)
            body += [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
        }
        attribute(0x1021, manufacturer)
        attribute(0x1023, model)
        attribute(0x1011, device)
        return element(221, body)
    }

    public static func oweTransition() -> [UInt8] {
        element(221, [0x50, 0x6F, 0x9A, 0x1C])
    }

    // MARK: Aides

    private static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func tlv(_ type: UInt8, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(255))
        return [type, UInt8(bytes.count)] + bytes
    }

    /// Carte des MCS : MCS 0-9 pour les `streams` premiers flux, non pris en charge ensuite.
    private static func mcsMap(streams: Int) -> UInt16 {
        var map: UInt16 = 0xFFFF
        for stream in 0..<min(8, max(1, streams)) {
            map &= ~(UInt16(0x3) << (2 * stream))
            map |= UInt16(0x2) << (2 * stream)
        }
        return map
    }
}
