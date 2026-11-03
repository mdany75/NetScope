import Foundation

/// Événement du journal : coupure, alerte, retour en ligne, information.
public struct PingEvent: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case coupure, alerte, retabli, info

        public var label: String {
            switch self {
            case .coupure: return "Coupure"
            case .alerte: return "Alerte"
            case .retabli: return "Rétabli"
            case .info: return "Info"
            }
        }
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    /// Cible concernée (adresse) ou « Session ».
    public let subject: String
    public let message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: Level, subject: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.subject = subject
        self.message = message
    }
}

/// Transforme les mesures d'une cible en événements : coupure à la 3e perte consécutive,
/// retour en ligne, pertes isolées, latence au-dessus du seuil.
public enum PingEventDetector {
    /// `previousLosses` : pertes consécutives avant cette mesure.
    /// `previousAboveThreshold` : la mesure précédente dépassait déjà le seuil ; l'alerte de latence
    /// n'est émise qu'au franchissement, pour ne pas noyer le journal sous une latence durablement élevée.
    public static func events(for sample: PingSample, previousLosses: Int, interval: TimeInterval,
                              thresholdMs: Double, subject: String, previousAboveThreshold: Bool = false) -> [PingEvent] {
        let offline = PingTargetStatus.offlineThreshold
        if sample.isLost {
            guard previousLosses + 1 == offline else { return [] }
            let reason = sample.failure.map { $0 == .timeout ? "délai dépassé" : $0.label } ?? "délai dépassé"
            return [PingEvent(date: sample.date, level: .coupure, subject: subject,
                              message: "\(reason) (\(offline) paquets perdus)")]
        }
        var result: [PingEvent] = []
        if previousLosses >= offline {
            let outage = PingFormat.duration(Double(previousLosses) * interval)
            result.append(PingEvent(date: sample.date, level: .retabli, subject: subject,
                                    message: "retour en ligne après \(outage) (\(previousLosses) paquets perdus)"))
        } else if previousLosses > 0 {
            let first = sample.sequence - previousLosses
            let text = previousLosses > 1 ? "\(previousLosses) paquets perdus (seq \(first) à \(sample.sequence - 1))"
                                          : "1 paquet perdu (seq \(first))"
            result.append(PingEvent(date: sample.date, level: .alerte, subject: subject, message: text))
        }
        if let rtt = sample.rttMs, rtt > thresholdMs, !previousAboveThreshold {
            result.append(PingEvent(date: sample.date, level: .alerte, subject: subject,
                                    message: "latence élevée \(PingFormat.ms(rtt)) (seuil \(PingFormat.decimal(thresholdMs, digits: 0)) ms)"))
        }
        return result
    }

    /// Seuil d'alerte par défaut : 20 ms sur le réseau local, 50 ms au-delà.
    public static func defaultThreshold(for address: IPv4Address?) -> Double {
        guard let address else { return 50 }
        switch AddressScope.of(address) {
        case .privee, .bouclage, .liaisonLocale: return 20
        default: return 50
        }
    }
}
