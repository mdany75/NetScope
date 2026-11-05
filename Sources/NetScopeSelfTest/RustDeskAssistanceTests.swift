import Foundation
import NetScopeCore

// Correctif 0.27.3 : onglet « Assistance RustDesk » (pastille du jour, recherche, carnet).
// Données fixes seulement : aucun réseau, aucun fichier.

func registerRustDeskAssistanceTests(_ suite: TestSuite) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
    // 5 novembre 2026, 14 h (heure de Montréal).
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14)) ?? Date()
    let book = UUID()
    let gone = UUID()
    let history = [
        RustDeskLaunch(date: now.addingTimeInterval(-600), connectionID: book, name: "WKS-ACCUEIL-02", target: "184352907",
                       endUser: "Julie Gagnon (réception)", site: "Siège › Postes"),
        RustDeskLaunch(date: now.addingTimeInterval(-3 * 3_600), name: "Poste 731\u{00A0}905\u{00A0}246", target: "731905246"),
        RustDeskLaunch(date: now.addingTimeInterval(-13 * 3_600 - 60), connectionID: gone, name: "PORT-COMPTA-07", target: "263418095",
                       endUser: "Marc Tremblay", site: "Siège › Postes"),
        RustDeskLaunch(date: now.addingTimeInterval(-50 * 3_600), name: "SALLE-CONF-TV", target: "10.182.122.160",
                       endUser: "Salle Saint-Laurent", site: "Siège"),
        RustDeskLaunch(date: now.addingTimeInterval(-60 * 3_600), connectionID: book, name: "WKS-ACCUEIL-02", target: "184352907"),
    ]

    suite.add("Assistance RustDesk : pastille du jour et postes distincts") {
        // 14 h - 13 h 01 = 0 h 59 : encore aujourd'hui ; les deux plus anciens sont d'avant-hier.
        try expectEqual(RustDeskAssistance.todayCount(history, now: now, calendar: calendar), 3, "trois lancements aujourd'hui")
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 30)) ?? now
        try expectEqual(RustDeskAssistance.todayCount(history, now: midnight, calendar: calendar), 0, "après minuit : pastille vide")
        try expectEqual(RustDeskAssistance.todayCount([], now: now, calendar: calendar), 0, "historique vide")
        try expectEqual(RustDeskAssistance.distinctTargets(history), 4, "le même ID deux fois compte pour un poste")
    }

    suite.add("Assistance RustDesk : recherche dans l'historique") {
        try expectEqual(RustDeskAssistance.filter(history, query: "").count, history.count, "recherche vide : tout")
        try expectEqual(RustDeskAssistance.filter(history, query: "   ").map(\.id), history.map(\.id), "espaces seuls : tout, même ordre")
        try expectEqual(RustDeskAssistance.filter(history, query: "263 418").map(\.name), ["PORT-COMPTA-07"], "ID dicté par groupes")
        try expectEqual(RustDeskAssistance.filter(history, query: "731-905").count, 1, "tirets acceptés")
        try expectEqual(RustDeskAssistance.filter(history, query: "905\u{00A0}246").count, 1, "espace insécable accepté")
        try expectEqual(RustDeskAssistance.filter(history, query: "184352907").count, 2, "ID complet : chaque lancement")
        try expectEqual(RustDeskAssistance.filter(history, query: "reception").map(\.name), ["WKS-ACCUEIL-02"], "accents ignorés")
        try expectEqual(RustDeskAssistance.filter(history, query: "GAGNON").count, 1, "casse ignorée")
        try expectEqual(RustDeskAssistance.filter(history, query: "siège compta").map(\.name), ["PORT-COMPTA-07"], "tous les mots requis")
        try expectEqual(RustDeskAssistance.filter(history, query: "10.182.122").map(\.name), ["SALLE-CONF-TV"], "adresse IP directe")
        try expect(RustDeskAssistance.filter(history, query: "Laval").isEmpty, "aucun résultat")
    }

    suite.add("Assistance RustDesk : présence au carnet") {
        let ids: Set<UUID> = [book]
        let connections = [
            RemoteConnection(name: "WKS-ACCUEIL-02", proto: .rustdesk, host: "184352907"),
            RemoteConnection(name: "Salle", proto: .rustdesk, host: "10.182.122.160"),
            RemoteConnection(name: "Commutateur", proto: .ssh, host: "263418095"),
        ]
        let targets = RustDeskAssistance.bookTargets(connections)
        try expectEqual(targets, ["184352907", "10.182.122.160"], "connexions RustDesk seulement")
        try expect(RustDeskAssistance.isInBook(history[0], connectionIDs: ids, targets: []), "par la connexion d'origine")
        try expect(!RustDeskAssistance.isInBook(history[1], connectionIDs: ids, targets: targets), "ID collé sans l'enregistrer")
        try expect(!RustDeskAssistance.isInBook(history[2], connectionIDs: ids, targets: targets), "connexion supprimée depuis, ID absent")
        try expect(RustDeskAssistance.isInBook(history[3], connectionIDs: ids, targets: targets), "même adresse au carnet")
    }

    suite.add("Assistance RustDesk : nom proposé pour le carnet") {
        try expectEqual(RustDeskAssistance.suggestedName(history[0]), "WKS-ACCUEIL-02", "nom du poste gardé")
        try expectEqual(RustDeskAssistance.suggestedName(history[1]), "", "nom automatique d'un ID collé : recomposé par le carnet")
        try expectEqual(RustDeskAssistance.suggestedName(RustDeskLaunch(name: "Poste 731 905 246", target: "731905246")), "", "espaces ordinaires")
        try expectEqual(RustDeskAssistance.suggestedName(RustDeskLaunch(name: "10.0.0.5", target: "10.0.0.5")), "", "adresse seule")
        try expectEqual(RustDeskAssistance.suggestedName(RustDeskLaunch(name: "  ", target: "731905246")), "", "nom vide")
    }
}
