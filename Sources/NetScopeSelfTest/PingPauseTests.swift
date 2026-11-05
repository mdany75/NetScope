import Foundation
import NetScopeCore

// Tests de la pause par cible du ping continu (0.21.0, note 11) : périodes de pause, état
// « En pause », journal et export CSV sans pertes pendant la pause. Données fixes, aucun réseau.

func registerPingPauseTests(_ suite: TestSuite) {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let at = { (seconds: Double) in start.addingTimeInterval(seconds) }

    suite.add("Ping : pause d'une cible (périodes, bascule, durée)") {
        var pauses = PingPausePeriods()
        try expect(!pauses.isPaused && pauses.pausedSince == nil, "pas de pause au départ")
        try expect(!pauses.resume(at: at(1)), "reprendre sans pause : rien")
        try expect(pauses.pause(at: at(10)), "mise en pause")
        try expect(!pauses.pause(at: at(12)), "déjà en pause : rien de plus")
        try expect(pauses.isPaused && pauses.pausedSince == at(10), "en pause depuis 10 s")
        try expect(pauses.covers(at(10)) && pauses.covers(at(500)), "pause ouverte : tout ce qui suit est couvert")
        try expect(!pauses.covers(at(9.9)), "avant la pause : non couvert")
        try expect(abs(pauses.pausedDuration(until: at(25)) - 15) < 0.001, "15 s de pause en cours")
        try expect(pauses.resume(at: at(30)), "reprise")
        try expect(!pauses.isPaused && pauses.pausedSince == nil, "plus en pause")
        try expect(pauses.covers(at(29.9)) && !pauses.covers(at(30)), "fin exclue")
        try expect(!pauses.covers(at(31)), "après la reprise : non couvert")
        try expect(pauses.toggle(at: at(40)), "bascule : en pause")
        try expect(!pauses.toggle(at: at(45)), "bascule : reprise")
        try expectEqual(pauses.periods.count, 2, "deux périodes")
        try expect(abs(pauses.pausedDuration(until: at(100)) - 25) < 0.001, "20 s + 5 s de pause")

        var backwards = PingPausePeriods()
        backwards.pause(at: at(50))
        backwards.resume(at: at(40))
        try expectEqual(backwards.periods.first?.end, at(50), "reprise datée avant la pause : période vide")
    }

    suite.add("Ping : réinitialisation, envoi et journal de la pause") {
        var pauses = PingPausePeriods()
        pauses.pause(at: at(0))
        pauses.resume(at: at(5))
        pauses.reset(at: at(6))
        try expect(pauses.periods.isEmpty, "réinitialisation : pauses passées oubliées")
        pauses.pause(at: at(7))
        pauses.reset(at: at(9))
        try expect(pauses.isPaused && pauses.pausedSince == at(7), "réinitialisation : la pause en cours continue, début réel gardé")

        try expect(PingPausePeriods.isSending(globalPaused: false, targetPaused: false), "ni pause : envoi")
        try expect(!PingPausePeriods.isSending(globalPaused: false, targetPaused: true), "cible en pause : rien")
        try expect(!PingPausePeriods.isSending(globalPaused: true, targetPaused: false), "pause globale : rien")
        try expect(!PingPausePeriods.isSending(globalPaused: true, targetPaused: true), "les deux : rien")

        try expectEqual(PingPausePeriods.journalMessage(paused: true), "mise en pause", "journal : mise en pause")
        try expectEqual(PingPausePeriods.journalMessage(paused: false), "reprise", "journal : reprise")
        try expectEqual(PingPausePeriods.journalMessage(paused: false, duration: 0.4), "reprise", "pause très courte")
        try expectEqual(PingPausePeriods.journalMessage(paused: false, duration: 12), "reprise après \(PingFormat.duration(12)) de pause", "avec durée")
        try expectEqual(PingPausePeriods.journalMessage(paused: false, duration: 120), "reprise après \(PingFormat.duration(120)) de pause", "en minutes")
    }

    suite.add("Ping : état « En pause » d'une cible") {
        var history = PingHistory()
        try expectEqual(PingTargetStatus.of(history, isPaused: true), .enPause, "vide et en pause")
        for index in 1...3 { history.append(PingSample(sequence: index, date: at(Double(index)), rttMs: nil)) }
        try expectEqual(PingTargetStatus.of(history), .horsLigne, "3 pertes : hors ligne")
        try expectEqual(PingTargetStatus.of(history, isPaused: true), .enPause, "la pause l'emporte")
        try expectEqual(PingTargetStatus.enPause.label, "En pause", "libellé")
    }

    suite.add("Ping : export CSV sans pertes pendant la pause") {
        // Une mesure par seconde de 0 à 9 ; pause de 3 à 7 s : les mesures 4 à 7 (envoyées à 3…6 s,
        // dont des pertes arrivées en retard) ne doivent pas être exportées.
        let samples = (0..<10).map { index -> PingSample in
            let lost = (3...6).contains(index)
            return PingSample(sequence: index + 1, date: at(Double(index)), rttMs: lost ? nil : 2.5 + Double(index))
        }
        var pauses = PingPausePeriods()
        pauses.pause(at: at(3))
        pauses.resume(at: at(7))
        try expectEqual(pauses.excluding(samples).map(\.sequence), [1, 2, 3, 8, 9, 10], "mesures hors pause")

        let targets = [PingCSV.Target(name: "=Imprimante; étage 2", address: "10.0.0.5", samples: samples, pauses: pauses),
                       PingCSV.Target(name: "Passerelle", address: "10.0.0.1",
                                      samples: [PingSample(sequence: 1, date: at(4), rttMs: nil)])]
        let csv = PingCSV.make(targets)
        let lines = csv.split(separator: "\n").map(String.init)
        try expectEqual(lines.first, PingCSV.header, "en-tête")
        try expectEqual(lines.count, 1 + 6 + 1, "6 mesures hors pause + 1 de l'autre cible")
        try expectEqual(PingCSV.count(targets), 7, "compte exporté")
        let paused = lines.dropFirst().filter { $0.contains("10.0.0.5") }
        try expect(!paused.contains { $0.hasSuffix(";1;délai dépassé") }, "aucune perte comptée pendant la pause")
        try expect(paused.allSatisfy { $0.contains(";'=Imprimante, étage 2;") }, "champ protégé (formule, séparateur)")
        try expect(paused.first?.contains(";1;2,500;0;") == true, "virgule décimale : \(paused.first ?? "")")
        try expect(lines.last?.hasSuffix(";10.0.0.1;1;;1;délai dépassé") == true, "perte d'une cible sans pause : exportée")
        try expect(csv.hasSuffix("\n"), "fin de ligne finale")
    }
}
