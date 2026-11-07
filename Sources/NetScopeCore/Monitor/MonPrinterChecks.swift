import Foundation

// Note 91 : sonde de Surveillance « Consommable bas (imprimante) ». Lecture SNMP de la Printer-MIB
// de l'imprimante visée (identifiants du site, comme la sonde SNMP), puis évaluation pure :
// alerte quand un consommable est au seuil ou en dessous (15 % par défaut), panne quand
// l'impression est bloquée (bourrage, plus de papier ou de toner, porte ouverte).

public enum MonPrinterChecks {
    /// Le relevé réussi est rendu avec l'adresse lue : l'application le range avec ceux de la fiche
    /// (sous la MAC de l'appareil du site de la sonde, jamais par l'IP seule).
    static func run(_ probe: MonProbe, host: String, context: MonRunContext) async -> MonRunOutcome {
        guard let address = try? await PingResolver.resolveAsync(host) else {
            return MonRunOutcome(result: .failure(context.now, error: "Nom introuvable\u{00A0}: \(host)"))
        }
        guard let target = context.snmpTarget(address) else {
            return MonRunOutcome(result: .failure(context.now, error: MonRunContext.missingSNMPCredentials))
        }
        do {
            let reading = try await PrinterMIB.read(client: SNMPClient(target: target), now: context.now)
            var outcome = MonRunOutcome(result: evaluate(reading, threshold: probe.resourceLimit ?? PrinterMIB.defaultThreshold,
                                                         now: context.now))
            outcome.printerReading = reading
            outcome.printerAddress = address
            return outcome
        } catch {
            return MonRunOutcome(result: .failure(context.now, error: error.localizedDescription))
        }
    }

    /// Résultat d'un relevé : valeur « Toner noir 8 % · 48 213 pages », alerte sous le seuil,
    /// panne quand une erreur bloque l'impression.
    public static func evaluate(_ reading: PrinterReading, threshold: Double, now: Date) -> MonResult {
        let value = reading.summary
        let blocking = reading.blockingErrors
        if !blocking.isEmpty {
            return MonResult(date: now, reachable: false, value: value,
                             error: "Impression bloquée\u{00A0}: " + blocking.map(\.label).joined(separator: ", "))
        }
        let low = reading.lowSupplies(threshold: threshold)
        var problems: [String] = []
        if !low.isEmpty {
            problems.append(low.map { "\($0.displayName) \($0.levelLabel)" }.joined(separator: ", ")
                            + " (seuil \(Int(threshold.rounded()))\u{00A0}%)")
        }
        // « Toner bas » : quand chaque toner ou encre publie son pourcentage, le seuil de la sonde
        // décide seul ; gardé si l'un d'eux dit seulement « il en reste » ou n'a pas de niveau.
        let colorants = reading.supplies.filter { $0.kind == .toner || $0.kind == .ink }
        let percentsKnown = !colorants.isEmpty && colorants.allSatisfy { $0.percent != nil }
        let warnings = reading.errors.filter { !$0.isBlocking && !($0 == .lowToner && percentsKnown) }
        if !warnings.isEmpty { problems.append(warnings.map(\.label).joined(separator: ", ")) }
        return MonResult(date: now, reachable: true, value: value,
                         problem: problems.isEmpty ? nil : problems.joined(separator: " · "))
    }
}
