import Foundation

// Note 25 : quelle FortiGate interroger ? Celles dont une plage couverte contient ou chevauche une
// plage scannée ; sinon celle qui couvre l'adresse du Mac ; la plage la plus précise gagne quand
// deux FortiGate couvrent les mêmes adresses ; aucune : SNMP seulement. Fonctions pures.

/// Deux FortiGate qui couvrent des adresses en commun.
public struct FortiRangeConflict: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// Même plage chez les deux : la première de la liste l'emporte (à corriger).
        case identical
        /// Chevauchement de même précision : la première de la liste l'emporte (à corriger).
        case ambiguous
        /// Une plage contient l'autre : la plus précise l'emporte sur les adresses communes.
        case nested
        /// Chevauchement partiel de précisions différentes : la plus précise l'emporte.
        case partial
    }

    public var first: UUID
    public var firstSite: String
    public var firstRange: String
    public var second: UUID
    public var secondSite: String
    public var secondRange: String
    public var kind: Kind

    public var id: String { "\(first.uuidString)|\(firstRange)|\(second.uuidString)|\(secondRange)" }

    /// Vrai pour un vrai conflit (le choix dépend de l'ordre de la liste).
    public var isAmbiguous: Bool { kind == .identical || kind == .ambiguous }

    /// Explication en français.
    public var message: String {
        let a = "«\u{00A0}\(firstSite)\u{00A0}» (\(firstRange))"
        let b = "«\u{00A0}\(secondSite)\u{00A0}» (\(secondRange))"
        switch kind {
        case .identical:
            return "Conflit\u{00A0}: \(a) et \(b) couvrent la même plage. \(firstSite) est utilisée (première de la liste)\u{00A0}; retirez la plage de l’une des deux."
        case .ambiguous:
            return "Conflit\u{00A0}: \(a) et \(b) se chevauchent avec la même précision. \(firstSite) est utilisée pour les adresses communes (première de la liste)."
        case .nested, .partial:
            return "Chevauchement\u{00A0}: \(a) et \(b). La plage la plus précise l’emporte pour les adresses communes."
        }
    }
}

/// Résultat du choix des FortiGate pour un scan.
public struct FortiControllerSelection: Hashable, Sendable {
    public enum Reason: String, Sendable {
        /// Une plage couverte contient ou chevauche une plage scannée.
        case scannedRange
        /// Aucune plage scannée couverte : la FortiGate qui couvre l'adresse du Mac.
        case macAddress
        /// Aucune FortiGate n'a de plage couverte (réglages de la 0.9.0) : toutes celles activées.
        case noRanges
    }

    public struct Pick: Hashable, Sendable, Identifiable {
        public var controllerID: UUID
        public var site: String
        public var reason: Reason
        /// Plages couvertes de cette FortiGate qui ont servi au choix.
        public var coveredRanges: [String]
        /// Plages scannées (ou adresse du Mac) qu'elle couvre.
        public var scannedRanges: [String]

        public var id: UUID { controllerID }

        /// « 10.182.0.0/16 » ou « 10.182.0.0/16, 192.168.50.0/24 ».
        public var rangeLabel: String { coveredRanges.joined(separator: ", ") }
    }

    public var picks: [Pick]
    public var conflicts: [FortiRangeConflict]
    /// Plages scannées qu'aucune FortiGate ne couvre (SNMP seulement).
    public var uncovered: [String]

    public init(picks: [Pick] = [], conflicts: [FortiRangeConflict] = [], uncovered: [String] = []) {
        self.picks = picks
        self.conflicts = conflicts
        self.uncovered = uncovered
    }

    public var controllerIDs: [UUID] { picks.map(\.controllerID) }
    public var isEmpty: Bool { picks.isEmpty }
    public func pick(for id: UUID) -> Pick? { picks.first { $0.controllerID == id } }
}

public enum FortiControllerSelector {
    /// Contrôleurs à interroger pour ces plages scannées et cette adresse du Mac (contrôleurs
    /// activés seulement, dans l'ordre de la liste).
    public static func select(_ controllers: [FortiGateController], scanned: [IPRange], macAddress: IPv4Address?) -> FortiControllerSelection {
        let active = controllers.filter(\.isEnabled)
        let candidates: [(index: Int, controller: FortiGateController, range: FortiCoveredRange)] = active.enumerated().flatMap { index, controller in
            controller.coveredRanges.map { (index, controller, $0) }
        }
        let conflicts = self.conflicts(active)

        var covered: [UUID: [String]] = [:]
        var scannedBy: [UUID: [String]] = [:]
        var uncovered: [String] = []
        func note(_ id: UUID, covered range: String, scanned: String) {
            if !(covered[id] ?? []).contains(range) { covered[id, default: []].append(range) }
            if !(scannedBy[id] ?? []).contains(scanned) { scannedBy[id, default: []].append(scanned) }
        }

        for segment in scanned.flatMap(\.segments) {
            let bounds = segment.bounds
            let lo = UInt64(bounds.first.value), hi = UInt64(bounds.last.value)
            let touching = candidates.filter { $0.range.overlaps(first: bounds.first, last: bounds.last) }
            guard !touching.isEmpty else {
                if !uncovered.contains(segment.description) { uncovered.append(segment.description) }
                continue
            }
            // Intervalles élémentaires : entre deux bornes, chaque adresse est couverte par les mêmes
            // plages ; la plus précise (la plus petite) l'emporte, à égalité la première de la liste.
            var cuts: Set<UInt64> = [lo, hi + 1]
            for item in touching {
                cuts.insert(max(lo, UInt64(item.range.first.value)))
                cuts.insert(min(hi, UInt64(item.range.last.value)) + 1)
            }
            let points = cuts.sorted()
            for (start, next) in zip(points, points.dropFirst()) where start < next {
                let end = next - 1
                let covering = touching.filter { UInt64($0.range.first.value) <= start && UInt64($0.range.last.value) >= end }
                guard let best = covering.min(by: { ($0.range.size, $0.index) < ($1.range.size, $1.index) }) else { continue }
                note(best.controller.id, covered: best.range.text, scanned: segment.description)
            }
        }

        var picks = active.compactMap { controller -> FortiControllerSelection.Pick? in
            guard let ranges = covered[controller.id] else { return nil }
            return .init(controllerID: controller.id, site: controller.displayName, reason: .scannedRange,
                         coveredRanges: ranges, scannedRanges: scannedBy[controller.id] ?? [])
        }

        if picks.isEmpty, let mac = macAddress {
            if let best = candidates.filter({ $0.range.contains(mac) }).min(by: { ($0.range.size, $0.index) < ($1.range.size, $1.index) }) {
                picks = [.init(controllerID: best.controller.id, site: best.controller.displayName, reason: .macAddress,
                               coveredRanges: [best.range.text], scannedRanges: [mac.description])]
            }
        }

        // Réglages de la 0.9.0 (aucune plage nulle part) : la FortiGate est interrogée comme avant.
        if picks.isEmpty, !active.isEmpty, candidates.isEmpty {
            picks = active.map { .init(controllerID: $0.id, site: $0.displayName, reason: .noRanges, coveredRanges: [], scannedRanges: []) }
            uncovered = []
        }
        return FortiControllerSelection(picks: picks, conflicts: conflicts, uncovered: uncovered)
    }

    /// Chevauchements entre les plages de contrôleurs différents (activés ou non, selon la liste
    /// donnée), dans l'ordre de la liste.
    public static func conflicts(_ controllers: [FortiGateController]) -> [FortiRangeConflict] {
        var result: [FortiRangeConflict] = []
        let ranges = controllers.map(\.coveredRanges)
        for i in controllers.indices {
            for j in controllers.indices where j > i {
                for a in ranges[i] {
                    for b in ranges[j] where a.overlaps(b) {
                        let kind: FortiRangeConflict.Kind
                        if a.first == b.first && a.last == b.last {
                            kind = .identical
                        } else if a.size == b.size {
                            kind = .ambiguous
                        } else if a.covers(b) || b.covers(a) {
                            kind = .nested
                        } else {
                            kind = .partial
                        }
                        result.append(FortiRangeConflict(first: controllers[i].id, firstSite: controllers[i].displayName, firstRange: a.text,
                                                         second: controllers[j].id, secondSite: controllers[j].displayName, secondRange: b.text,
                                                         kind: kind))
                    }
                }
            }
        }
        return result
    }
}
