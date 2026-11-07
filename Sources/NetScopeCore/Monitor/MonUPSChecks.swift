import Foundation

// Note 98 : sonde de Surveillance « Onduleur ». Lecture SNMP de l'onduleur visé (UPS-MIB, puis
// MIB du fabricant ; identifiants du site, comme la sonde SNMP), puis évaluation pure : panne au
// passage sur batterie ou quand la sortie est coupée, alerte quand l'autonomie descend sous le
// seuil (10 min par défaut), quand la batterie est faible ou à changer.

public enum MonUPSChecks {
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
            let reading = try await UPSMIB.read(client: SNMPClient(target: target), now: context.now)
            var outcome = MonRunOutcome(result: evaluate(reading, minRuntime: probe.resourceLimit ?? UPSMIB.defaultMinRuntime,
                                                         now: context.now))
            outcome.upsReading = reading
            outcome.upsAddress = address
            return outcome
        } catch {
            return MonRunOutcome(result: .failure(context.now, error: error.localizedDescription))
        }
    }

    /// Résultat d'un relevé : valeur « Secteur · batterie 100 % · autonomie 42 min », panne sur
    /// batterie ou sortie coupée, alerte sous le seuil d'autonomie ou batterie à changer.
    public static func evaluate(_ reading: UPSReading, minRuntime: Double, now: Date) -> MonResult {
        let value = reading.summary
        // Autotest de la batterie (souvent hebdomadaire) : la plupart des cartes publient « sur
        // batterie » pendant le test alors que l'onduleur est sur secteur : ce n'est pas une panne.
        let selfTest = reading.lastTest == .inProgress || reading.alarms.contains(UPSMIB.alarmLabel(24))
        if selfTest, reading.source == .battery || reading.alarms.contains(UPSMIB.alarmLabel(2)) {
            return MonResult(date: now, reachable: true, value: "Autotest en cours · " + value, problem: nil)
        }
        if reading.source == .battery {
            var text = "Sur batterie"
            if let seconds = reading.secondsOnBattery, seconds > 0 { text += " depuis \(UPSMIB.minutes(Double(seconds) / 60))" }
            if let runtime = reading.runtimeMinutes { text += ", autonomie \(UPSMIB.minutes(runtime))" }
            return MonResult(date: now, reachable: false, value: value, error: text)
        }
        if reading.source == .off { return MonResult(date: now, reachable: false, value: value, error: "Sortie de l’onduleur coupée") }
        if reading.batteryStatus == .depleted { return MonResult(date: now, reachable: false, value: value, error: "Batterie épuisée") }
        var problems: [String] = []
        if let runtime = reading.runtimeMinutes, runtime < minRuntime {
            problems.append("Autonomie basse\u{00A0}: \(UPSMIB.minutes(runtime)) (seuil \(UPSMIB.minutes(minRuntime)))")
        }
        if reading.batteryStatus == .low { problems.append("Batterie faible") }
        if let reason = reading.batteryDueReason(now: now) { problems.append("Batterie à changer\u{00A0}: \(reason)") }
        if reading.source == .bypass { problems.append("En contournement (bypass)\u{00A0}: la charge n’est plus protégée") }
        if let load = reading.loadPercent, load >= 90 { problems.append("Charge de la sortie \(UPSMIB.percent(load))") }
        // Alarmes déjà traitées plus haut, ou sans conséquence (test en cours, attente du secteur).
        let known = [1, 2, 3, 9, 21, 24].map { UPSMIB.alarmLabel($0) }
        let others = reading.alarms.filter { !known.contains($0) }
        if !others.isEmpty { problems.append(others.joined(separator: ", ")) }
        return MonResult(date: now, reachable: true, value: value, problem: problems.isEmpty ? nil : problems.joined(separator: " · "))
    }
}
