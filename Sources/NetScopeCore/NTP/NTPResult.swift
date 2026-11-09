import Foundation

/// Un échange NTP réussi avec un serveur.
public struct NTPSample: Equatable, Sendable {
    public var server: String
    public var address: IPv4Address
    public var version: Int
    public var mode: Int
    public var leap: Int
    public var stratum: Int
    public var poll: Int
    public var precision: Int
    public var rootDelay: Double
    public var rootDispersion: Double
    public var referenceID: String
    public var kissCode: String?
    public var serverTime: Date
    public var offset: Double
    public var roundTrip: Double

    public init(server: String, address: IPv4Address, version: Int = 4, mode: Int = 4, leap: Int = 0, stratum: Int,
                poll: Int = 6, precision: Int = -20, rootDelay: Double = 0, rootDispersion: Double = 0,
                referenceID: String, kissCode: String? = nil, serverTime: Date, offset: Double, roundTrip: Double) {
        self.server = server
        self.address = address
        self.version = version
        self.mode = mode
        self.leap = leap
        self.stratum = stratum
        self.poll = poll
        self.precision = precision
        self.rootDelay = rootDelay
        self.rootDispersion = rootDispersion
        self.referenceID = referenceID
        self.kissCode = kissCode
        self.serverTime = serverTime
        self.offset = offset
        self.roundTrip = roundTrip
    }

    public init(server: String, address: IPv4Address, packet: NTPPacket, sentAt t1: NTPTimestamp, receivedAt t4: NTPTimestamp, now: Date) {
        let times = NTPTimes(t1: t1, t2: packet.receiveTime, t3: packet.transmitTime, t4: t4)
        self.init(server: server, address: address, version: packet.version, mode: packet.mode, leap: packet.leap,
                  stratum: packet.stratum, poll: packet.poll, precision: packet.precision,
                  rootDelay: Double(packet.rootDelay) / 65_536, rootDispersion: Double(packet.rootDispersion) / 65_536,
                  referenceID: packet.referenceText, kissCode: packet.kissCode, serverTime: packet.transmitTime.date(near: now),
                  offset: times.offset, roundTrip: max(0, times.roundTrip))
    }

    /// Faux en strate 0 : un serveur qui refuse ou qui démarre ne donne pas d'heure exploitable.
    public var hasClock: Bool { stratum != 0 }
}

public enum NTPVerdict: Equatable, Sendable {
    case synchronized
    case notableOffset
    case largeOffset
    case unsynchronized
    case kissOfDeath(code: String)
    case silent

    /// Sous cette valeur (secondes), le décalage est bon.
    public static let goodLimit = 0.1
    /// Jusqu'à cette valeur, il est notable ; au-delà, fort.
    public static let notableLimit = 1.0

    public static func of(_ sample: NTPSample?) -> NTPVerdict {
        guard let sample else { return .silent }
        if sample.stratum == 0 {
            // Un refus porte un code ASCII. Sans code, ou avec INIT ou STEP, le serveur n'a simplement pas de source de temps.
            guard let code = sample.kissCode, !["INIT", "STEP"].contains(code) else { return .unsynchronized }
            return .kissOfDeath(code: code)
        }
        if sample.leap == 3 || sample.stratum >= 16 { return .unsynchronized }
        let magnitude = abs(sample.offset)
        if magnitude < goodLimit { return .synchronized }
        return magnitude <= notableLimit ? .notableOffset : .largeOffset
    }

    public var label: String {
        switch self {
        case .synchronized: return "Synchronisé"
        case .notableOffset: return "Décalage notable"
        case .largeOffset: return "Décalage fort"
        case .unsynchronized: return "Non synchronisé"
        case let .kissOfDeath(code): return "Refus (\(code))"
        case .silent: return "Muet"
        }
    }

    /// Le plus grave d'abord.
    public var rank: Int {
        switch self {
        case .silent: return 0
        case .unsynchronized: return 1
        case .largeOffset: return 2
        case .kissOfDeath: return 3
        case .notableOffset: return 4
        case .synchronized: return 5
        }
    }
}

/// Bilan d'un serveur : le meilleur échantillon et ce qui s'est passé pour les autres.
public struct NTPServerResult: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var server: String
    public var address: IPv4Address?
    public var sample: NTPSample?
    public var sent: Int
    public var answered: Int
    /// Datagrammes écartés : origine ou mode inattendu, paquet tronqué.
    public var rejected: Int
    public var failure: String?

    public init(server: String, address: IPv4Address? = nil, sample: NTPSample? = nil, sent: Int = 0, answered: Int = 0,
                rejected: Int = 0, failure: String? = nil) {
        self.server = server
        self.address = address
        self.sample = sample
        self.sent = sent
        self.answered = answered
        self.rejected = rejected
        self.failure = failure
    }

    public var verdict: NTPVerdict { NTPVerdict.of(sample) }
}

public extension NTPSample {
    var leapText: String {
        ["aucune seconde intercalaire", "dernière minute de 61\u{00A0}s", "dernière minute de 59\u{00A0}s", "horloge non synchronisée"][leap & 0x03]
    }
    var modeText: String { PacketDecoding.ntpModeName(mode) }
    var stratumText: String { PacketDecoding.ntpStratumName(stratum) }
    var precisionText: String { PacketDecoding.ntpPrecision(precision) }
    /// « 64 s » ; l'exposant reçu est borné pour un paquet hors norme.
    var pollText: String { "\(1 << max(0, min(poll, 17)))\u{00A0}s" }
}

public enum NTPFormat {
    /// « +12,3 ms », « −1,482 s », « +2 h 14 min ».
    public static func offset(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        return (seconds < 0 ? "−" : "+") + magnitude(abs(seconds))
    }

    /// « 12,3 ms », « 1,482 s », « 2 h 14 min », « 412 j 3 h ».
    public static func magnitude(_ seconds: Double) -> String {
        if seconds < 1 { return "\(ToolFormat.decimal(seconds * 1000))\u{00A0}ms" }
        if seconds < 60 { return "\(ToolFormat.decimal(seconds, digits: 3))\u{00A0}s" }
        let total = seconds.clampedInt
        let (days, hours, minutes, rest) = (total / 86_400, total / 3600 % 24, total / 60 % 60, total % 60)
        if days > 0 { return "\(ToolFormat.integer(days))\u{00A0}j \(hours)\u{00A0}h" }
        if hours > 0 { return "\(hours)\u{00A0}h \(minutes)\u{00A0}min" }
        return "\(minutes)\u{00A0}min \(rest)\u{00A0}s"
    }

    public static func roundTrip(_ seconds: Double) -> String { ToolFormat.milliseconds(seconds * 1000) }

    /// Explication en clair du verdict d'un serveur.
    public static func explanation(_ result: NTPServerResult) -> String {
        var parts = [meaning(result)]
        if let sample = result.sample, sample.hasClock {
            parts.append("Le calcul suppose un trajet symétrique\u{00A0}: valeur juste à ±\u{00A0}\(roundTrip(sample.roundTrip / 2)) près.")
        }
        if result.rejected > 0 {
            parts.append("\(result.rejected) réponse\(result.rejected > 1 ? "s" : "") écartée\(result.rejected > 1 ? "s" : "") (origine ou mode inattendu)\u{00A0}: réponse périmée ou forgée.")
        }
        return parts.joined(separator: " ")
    }

    private static func meaning(_ result: NTPServerResult) -> String {
        let drift = result.sample.map { "Ce Mac \($0.offset >= 0 ? "retarde" : "avance") de \(magnitude(abs($0.offset))) sur ce serveur" } ?? ""
        switch result.verdict {
        case .synchronized:
            return "\(drift)\u{00A0}: les deux horloges s’accordent, rien à corriger."
        case .notableOffset:
            return "\(drift)\u{00A0}: sans conséquence pour la plupart des services, mais les journaux de plusieurs appareils seront difficiles à recouper."
        case .largeOffset:
            return "\(drift)\u{00A0}: à corriger. L’une des deux horloges est fausse\u{00A0}; comparez avec un autre serveur pour savoir laquelle. Au-delà de 5\u{00A0}minutes, Kerberos (Active Directory) refuse les connexions, et les certificats peuvent paraître invalides."
        case .unsynchronized:
            return "Ce serveur répond, mais il indique lui-même ne pas être synchronisé\u{00A0}: son heure n’est pas fiable. Vérifiez sa propre source de temps avant de vous y fier."
        case let .kissOfDeath(code):
            let reason: String
            switch code {
            case "RATE": reason = "il estime être interrogé trop souvent. Attendez quelques minutes avant de relancer."
            case "DENY", "RSTR": reason = "une règle d’accès interdit ce Mac. Vérifiez la liste d’accès du serveur."
            default: reason = "il refuse de donner l’heure à ce Mac."
            }
            return "Ce serveur a répondu par un Kiss-o’-Death («\u{00A0}\(code)\u{00A0}»)\u{00A0}: " + reason
        case .silent:
            if let failure = result.failure { return failure }
            return "Aucune réponse à \(result.sent) essai\(result.sent > 1 ? "s" : "")\u{00A0}: port UDP filtré par un pare-feu, service NTP arrêté ou mauvaise adresse."
        }
    }

    /// Rapport à copier, un serveur par ligne.
    public static func report(_ results: [NTPServerResult]) -> String {
        results.map { result in
            var columns = [result.server, result.address?.description ?? "—", result.verdict.label]
            if let sample = result.sample, sample.hasClock {
                columns += [offset(sample.offset), roundTrip(sample.roundTrip), "strate \(sample.stratum)", sample.referenceID]
            }
            return columns.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
