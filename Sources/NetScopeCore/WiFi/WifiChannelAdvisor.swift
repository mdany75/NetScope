import Foundation

// Note 78 (Wi-Fi de ce Mac) : meilleur canal conseillé dans chaque bande (2,4, 5 et 6 GHz), d'après
// les réseaux vus par la dernière analyse. Chaque bloc de canaux possible (selon la largeur) reçoit
// une charge : la somme des réseaux voisins qui le chevauchent, pondérée par leur force (un voisin
// à −50 dBm gêne bien plus qu'un voisin à −85 dBm). Le bloc le moins chargé l'emporte ; à égalité,
// un canal hors DFS (5 GHz), puis un canal PSC (6 GHz), puis le plus bas.
//
// Calcul pur, sans CoreWLAN ni réseau : les tests passent des listes de réseaux fixes.

/// Un bloc de canaux candidat (canal principal et largeur) et sa charge.
public struct WifiChannelOption: Hashable, Sendable {
    public var band: WifiBand
    /// Canal principal à régler sur la borne.
    public var channel: Int
    public var widthMHz: Int
    /// Charge pondérée des réseaux qui chevauchent ce bloc (0 : libre).
    public var load: Double
    /// Nombre de réseaux qui chevauchent ce bloc.
    public var overlapping: Int
    /// Canal soumis au DFS (5 GHz, 52 à 144) : la borne doit écouter les radars avant d'émettre.
    public var isDFS: Bool
    /// Canal PSC (6 GHz) : celui que les appareils sondent en priorité.
    public var isPSC: Bool

    public init(band: WifiBand, channel: Int, widthMHz: Int, load: Double = 0, overlapping: Int = 0) {
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.load = load
        self.overlapping = overlapping
        isDFS = band == .ghz5 && WifiChannelAdvisor.isDFS(channel: channel, widthMHz: widthMHz)
        isPSC = band == .ghz6 && WifiChannelAdvisor.isPSC(channel)
    }

    /// « 6 », « 149 (80 MHz) ».
    public var label: String {
        band == .ghz24 && widthMHz == 20 ? "\(channel)" : "\(channel) (\(widthMHz)\u{00A0}MHz)"
    }

    /// « libre », « 1 réseau », « 3 réseaux ».
    public var overlapLabel: String {
        switch overlapping {
        case 0: return "libre"
        case 1: return "1 réseau en chevauchement"
        default: return "\(overlapping) réseaux en chevauchement"
        }
    }
}

/// Conseil d'une bande : meilleur bloc, autre choix, canal actuel de la connexion.
public struct WifiChannelAdvice: Hashable, Sendable, Identifiable {
    public enum Verdict: String, Hashable, Sendable {
        /// Aucune analyse : rien à conseiller.
        case noScan
        /// Connecté dans cette bande, et le canal actuel est aussi bon (ou presque) que le meilleur.
        case keep
        /// Connecté dans cette bande, et un autre canal est nettement moins chargé.
        case change
        /// Pas connecté dans cette bande : canal conseillé pour une borne à installer ou à régler.
        case suggest
    }

    public var band: WifiBand
    public var best: WifiChannelOption?
    /// Autre choix utile : hors DFS si le meilleur est DFS, ou plus étroit et libre si le meilleur ne l'est pas.
    public var alternative: WifiChannelOption?
    /// Canal de la connexion de ce Mac dans cette bande (charge sans compter la borne elle-même).
    public var current: WifiChannelOption?
    /// Réseaux vus dans cette bande.
    public var networkCount: Int
    public var verdict: Verdict

    public var id: String { band.rawValue }

    /// Phrase de conseil (« Canal 149 (80 MHz) libre ; votre canal 44 en a 3. »).
    public var summary: String {
        guard let best else { return "Lancez une analyse pour obtenir un canal conseillé." }
        var text: String
        switch verdict {
        case .noScan:
            return "Lancez une analyse pour obtenir un canal conseillé."
        case .keep:
            text = "Votre canal \(current?.label ?? best.label) convient (\(current?.overlapLabel ?? best.overlapLabel))."
        case .change:
            text = "Canal \(best.label) conseillé (\(best.overlapLabel))\u{00A0}; votre canal \(current?.label ?? "?") en compte \(current?.overlapping ?? 0)."
        case .suggest:
            text = networkCount == 0
                ? "Aucun réseau vu dans cette bande\u{00A0}: canal \(best.label) conseillé."
                : "Canal \(best.label) conseillé (\(best.overlapLabel))."
        }
        if best.isDFS { text += " Canal DFS\u{00A0}: la borne peut changer de canal si un radar est détecté." }
        if let alternative {
            text += best.isDFS && !alternative.isDFS
                ? " Hors DFS\u{00A0}: canal \(alternative.label) (\(alternative.overlapLabel))."
                : " Ou canal \(alternative.label) (\(alternative.overlapLabel))."
        }
        return text
    }
}

public enum WifiChannelAdvisor {
    /// Canaux PSC du 6 GHz (5, 21, 37… 229).
    public static let pscChannels6: [Int] = Array(stride(from: 5, through: 229, by: 16))
    /// Canaux de 20 MHz du 6 GHz (1, 5, 9… 233).
    public static let channels6: [Int] = Array(stride(from: 1, through: 233, by: 4))

    public static func isPSC(_ channel: Int) -> Bool { pscChannels6.contains(channel) }

    /// Le bloc touche-t-il les canaux DFS (52 à 144) ?
    public static func isDFS(channel: Int, widthMHz: Int) -> Bool {
        blockChannels(band: .ghz5, channel: channel, widthMHz: widthMHz).contains { (52...144).contains($0) }
    }

    /// Canaux de 20 MHz couverts par un bloc.
    public static func blockChannels(band: WifiBand, channel: Int, widthMHz: Int) -> [Int] {
        switch band {
        case .ghz24:
            return [channel]
        case .ghz5:
            let count = max(1, widthMHz / 20)
            guard let start = blockStarts5(widthMHz).last(where: { $0 <= channel }),
                  let index = WifiChannelLayout.channels5.firstIndex(of: start) else { return [channel] }
            return Array(WifiChannelLayout.channels5[index..<min(index + count, WifiChannelLayout.channels5.count)])
        case .ghz6:
            let block = 4 * max(1, widthMHz / 20)
            let start = ((channel - 1) / block) * block + 1
            return Array(stride(from: start, to: start + block, by: 4))
        }
    }

    /// Premiers canaux des blocs possibles en 5 GHz pour une largeur (165 : 20 MHz seulement).
    static func blockStarts5(_ widthMHz: Int) -> [Int] {
        switch widthMHz {
        case 160: return [36, 100]
        case 80: return [36, 52, 100, 116, 132, 149]
        case 40: return [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157]
        default: return WifiChannelLayout.channels5
        }
    }

    /// Largeurs proposées dans une bande.
    public static func widths(_ band: WifiBand) -> [Int] {
        switch band {
        case .ghz24: return [20]
        case .ghz5: return [20, 40, 80, 160]
        case .ghz6: return [20, 40, 80, 160]
        }
    }

    /// Largeur conseillée par défaut quand ce Mac n'est pas connecté dans la bande.
    public static func defaultWidth(_ band: WifiBand) -> Int {
        band == .ghz24 ? 20 : 80
    }

    /// Canaux principaux candidats d'une bande pour une largeur.
    public static func candidates(_ band: WifiBand, widthMHz: Int) -> [Int] {
        switch band {
        case .ghz24:
            return [1, 6, 11]
        case .ghz5:
            return blockStarts5(widthMHz)
        case .ghz6:
            if widthMHz <= 20 { return pscChannels6 }
            // Un bloc par PSC (le premier du bloc) : les appareils trouvent la borne sans sonder tout le 6 GHz.
            let block = 4 * (widthMHz / 20)
            var result: [Int] = []
            var start = 1
            while start + block - 4 <= 233 {
                if let psc = stride(from: start, to: start + block, by: 4).first(where: isPSC) { result.append(psc) }
                start += block
            }
            return result
        }
    }

    /// Poids d'un réseau voisin selon sa force.
    public static func weight(rssi: Int) -> Double {
        switch rssi {
        case (-65)...: return 1
        case (-75)..<(-65): return 0.6
        case (-85)..<(-75): return 0.3
        default: return 0.1
        }
    }

    /// Charge d'un bloc : réseaux de la bande qui le chevauchent (sauf ceux de `excluding`).
    public static func option(_ band: WifiBand, channel: Int, widthMHz: Int, networks: [WifiNetwork],
                              excluding: Set<String> = []) -> WifiChannelOption {
        let probe = WifiNetwork(ssid: nil, bssid: nil, channel: channel, band: band, widthMHz: widthMHz, rssi: -50)
        var option = WifiChannelOption(band: band, channel: channel, widthMHz: widthMHz)
        for network in networks where network.band == band && !excluding.contains(network.id) {
            guard WifiChannelLayout.overlaps(probe, network) else { continue }
            option.overlapping += 1
            option.load += weight(rssi: network.rssi)
        }
        option.load = (option.load * 100).rounded() / 100
        return option
    }

    /// Ordre de préférence : charge, puis hors DFS, puis PSC, puis canal le plus bas.
    static func isBetter(_ a: WifiChannelOption, than b: WifiChannelOption) -> Bool {
        if abs(a.load - b.load) > 0.001 { return a.load < b.load }
        if a.isDFS != b.isDFS { return !a.isDFS }
        if a.isPSC != b.isPSC { return a.isPSC }
        return a.channel < b.channel
    }

    /// Meilleur bloc d'une bande pour une largeur.
    public static func best(_ band: WifiBand, widthMHz: Int, networks: [WifiNetwork], excluding: Set<String> = [],
                            allowDFS: Bool = true) -> WifiChannelOption? {
        candidates(band, widthMHz: widthMHz)
            .map { option(band, channel: $0, widthMHz: widthMHz, networks: networks, excluding: excluding) }
            .filter { allowDFS || !$0.isDFS }
            .min { isBetter($0, than: $1) }
    }

    /// Écart de charge sous lequel le canal actuel est jugé aussi bon que le meilleur.
    public static let keepMargin = 0.5

    /// Conseil d'une bande. `scanned` : une analyse a eu lieu (sinon, rien à conseiller).
    public static func advice(_ band: WifiBand, networks: [WifiNetwork], connected: WifiNetwork?, scanned: Bool) -> WifiChannelAdvice {
        let inBand = networks.filter { $0.band == band }
        guard scanned else {
            return WifiChannelAdvice(band: band, best: nil, alternative: nil, current: nil, networkCount: inBand.count, verdict: .noScan)
        }
        let mine = connected?.band == band ? connected : nil
        // La borne de la connexion ne se gêne pas elle-même.
        let excluding: Set<String> = mine.map { [$0.id] } ?? []
        let width = mine.map { band == .ghz24 ? 20 : max(20, min($0.widthMHz, 160)) } ?? defaultWidth(band)
        guard let best = best(band, widthMHz: width, networks: networks, excluding: excluding) else {
            return WifiChannelAdvice(band: band, best: nil, alternative: nil, current: nil, networkCount: inBand.count, verdict: .noScan)
        }
        var alternative: WifiChannelOption?
        if best.isDFS, let clear = self.best(band, widthMHz: width, networks: networks, excluding: excluding, allowDFS: false),
           clear.load - best.load < 2 {
            alternative = clear
        } else if best.overlapping > 0, width > 20 {
            // Aucun bloc libre à cette largeur : une largeur deux fois plus petite l'est peut-être.
            if let narrower = self.best(band, widthMHz: width / 2, networks: networks, excluding: excluding), narrower.overlapping == 0 {
                alternative = narrower
            }
        }
        var current: WifiChannelOption?
        var verdict = WifiChannelAdvice.Verdict.suggest
        if let mine {
            let currentOption = option(band, channel: mine.channel, widthMHz: width, networks: networks, excluding: excluding)
            current = currentOption
            let sameBlock = blockChannels(band: band, channel: mine.channel, widthMHz: width)
                == blockChannels(band: band, channel: best.channel, widthMHz: width)
            verdict = sameBlock || currentOption.load - best.load <= keepMargin ? .keep : .change
        }
        return WifiChannelAdvice(band: band, best: best, alternative: alternative, current: current,
                                 networkCount: inBand.count, verdict: verdict)
    }

    /// Conseils des trois bandes.
    public static func advice(networks: [WifiNetwork], connected: WifiNetwork?, scanned: Bool) -> [WifiChannelAdvice] {
        WifiBand.allCases.map { advice($0, networks: networks, connected: connected, scanned: scanned) }
    }

    /// Recommandations « Préférer le canal… » en 5 et 6 GHz (le 2,4 GHz a déjà la sienne dans
    /// `WifiAdvisor`) : seulement quand la connexion de ce Mac est sur un canal nettement plus chargé.
    public static func recommendations(_ advices: [WifiChannelAdvice]) -> [WifiRecommendation] {
        advices.compactMap { advice in
            guard advice.band != .ghz24, advice.verdict == .change, let best = advice.best, let current = advice.current else { return nil }
            var detail = "Le canal \(best.label) est \(best.overlapping == 0 ? "libre" : "moins chargé (\(best.overlapLabel))"), "
                + "contre \(current.overlapping) réseau\(current.overlapping > 1 ? "x" : "") sur votre canal \(current.label)."
            if best.isDFS { detail += " Canal DFS\u{00A0}: possible changement de canal en cas de radar." }
            return WifiRecommendation(id: "meilleur-\(advice.band.rawValue)", severity: .conseil,
                                      title: "Préférer le canal \(best.label) en \(advice.band.label)",
                                      detail: detail, band: advice.band)
        }
    }
}
