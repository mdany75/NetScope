import Foundation
import NetScopeCore

// Note 78 (Wi-Fi de ce Mac) : meilleur canal en 2,4, 5 et 6 GHz, historique du signal sur une heure
// et relevé par pièce. Réseaux et mesures fixes ; aucun appel à CoreWLAN ni au réseau.

private func net(_ ssid: String, _ bssid: String, _ band: WifiBand, _ channel: Int, _ width: Int, _ rssi: Int,
                 connected: Bool = false) -> WifiNetwork {
    WifiNetwork(ssid: ssid, bssid: MACAddress(bssid), channel: channel, band: band, widthMHz: width, rssi: rssi,
                noise: -92, isConnected: connected)
}

func registerWifiLocalTests(_ suite: TestSuite) {
    // MARK: Meilleur canal

    suite.add("Wi-Fi ce Mac : canaux candidats et DFS") {
        try expectEqual(WifiChannelAdvisor.candidates(.ghz24, widthMHz: 20), [1, 6, 11], "2,4 GHz : 1, 6, 11")
        try expectEqual(WifiChannelAdvisor.candidates(.ghz5, widthMHz: 80), [36, 52, 100, 116, 132, 149], "5 GHz, 80 MHz")
        try expectEqual(WifiChannelAdvisor.candidates(.ghz6, widthMHz: 20).prefix(3).map { $0 }, [5, 21, 37], "6 GHz : PSC")
        try expectEqual(WifiChannelAdvisor.candidates(.ghz6, widthMHz: 80).count, 14, "6 GHz, 80 MHz : 14 blocs (1 à 221)")
        try expectEqual(WifiChannelAdvisor.candidates(.ghz6, widthMHz: 160), [5, 37, 69, 101, 133, 165, 197], "6 GHz, 160 MHz : 7 blocs")
        try expect(WifiChannelAdvisor.isDFS(channel: 52, widthMHz: 20), "52 est DFS")
        try expect(!WifiChannelAdvisor.isDFS(channel: 36, widthMHz: 80), "36 à 48 hors DFS")
        try expect(WifiChannelAdvisor.isDFS(channel: 36, widthMHz: 160), "36 à 64 (160 MHz) touche le DFS")
        try expect(!WifiChannelAdvisor.isDFS(channel: 149, widthMHz: 80), "149 à 161 hors DFS")
        try expectEqual(WifiChannelAdvisor.blockChannels(band: .ghz5, channel: 44, widthMHz: 80), [36, 40, 44, 48], "bloc de 44 à 80 MHz")
        try expectEqual(WifiChannelAdvisor.blockChannels(band: .ghz6, channel: 37, widthMHz: 80), [33, 37, 41, 45], "bloc de 37 à 80 MHz")
        try expectEqual(WifiChannelOption(band: .ghz5, channel: 149, widthMHz: 80).label, "149 (80\u{00A0}MHz)", "libellé")
    }

    suite.add("Wi-Fi ce Mac : meilleur canal 5 GHz, connexion sur un canal chargé") {
        let mine = net("Bureau", "70:4C:A5:00:00:01", .ghz5, 44, 80, -52, connected: true)
        let networks = [
            mine,
            net("Voisin-A", "10:00:00:00:00:01", .ghz5, 36, 80, -60),
            net("Voisin-B", "10:00:00:00:00:02", .ghz5, 40, 40, -64),
            net("Voisin-C", "10:00:00:00:00:03", .ghz5, 48, 20, -70),
            net("Voisin-D", "10:00:00:00:00:04", .ghz5, 100, 80, -82),
            net("Voisin-E", "10:00:00:00:00:05", .ghz5, 157, 40, -88),
        ]
        let advice = WifiChannelAdvisor.advice(.ghz5, networks: networks, connected: mine, scanned: true)
        try expectEqual(advice.verdict, .change, "36–48 porte trois voisins")
        try expectEqual(advice.current?.overlapping, 3, "la borne elle-même n'est pas comptée")
        try expectEqual(advice.best?.channel, 52, "52–64 libre (DFS, mais seul bloc libre en 80 MHz avec 116 et 132)")
        try expectEqual(advice.best?.overlapping, 0, "bloc libre")
        try expect(advice.best?.isDFS == true, "52 est DFS")
        try expect(advice.alternative?.isDFS == false, "un choix hors DFS est proposé")
        try expectEqual(advice.alternative?.channel, 149, "149–161 : un voisin faible seulement")
        let recos = WifiChannelAdvisor.recommendations([advice])
        try expectEqual(recos.map(\.id), ["meilleur-ghz5"], "une recommandation 5 GHz")
        try expect(recos[0].title.contains("52"), "titre : canal conseillé")
        try expect(advice.summary.contains("DFS"), "résumé : DFS signalé")
    }

    suite.add("Wi-Fi ce Mac : canal actuel conservé quand il est aussi bon") {
        let mine = net("Bureau", "70:4C:A5:00:00:01", .ghz5, 149, 80, -50, connected: true)
        let networks = [mine, net("Voisin", "10:00:00:00:00:01", .ghz5, 36, 80, -60), net("Voisin2", "10:00:00:00:00:02", .ghz5, 100, 80, -61)]
        let advice = WifiChannelAdvisor.advice(.ghz5, networks: networks, connected: mine, scanned: true)
        try expectEqual(advice.verdict, .keep, "149 est libre")
        try expect(WifiChannelAdvisor.recommendations([advice]).isEmpty, "aucune recommandation")
        try expect(advice.summary.hasPrefix("Votre canal 149"), "résumé : canal conservé")
    }

    suite.add("Wi-Fi ce Mac : 6 GHz (PSC) et 2,4 GHz sans connexion") {
        let networks = [
            net("Voisin-6E", "3C:52:A1:09:7E:2C", .ghz6, 5, 160, -70),
            net("Autre-6E", "3C:52:A1:09:7E:2D", .ghz6, 69, 80, -80),
            net("A", "20:00:00:00:00:01", .ghz24, 1, 20, -50),
            net("B", "20:00:00:00:00:02", .ghz24, 6, 20, -55),
            net("C", "20:00:00:00:00:03", .ghz24, 6, 20, -60),
            net("D", "20:00:00:00:00:04", .ghz24, 11, 20, -86),
        ]
        let six = WifiChannelAdvisor.advice(.ghz6, networks: networks, connected: nil, scanned: true)
        try expectEqual(six.verdict, .suggest, "pas connecté en 6 GHz")
        try expectEqual(six.best?.widthMHz, 80, "80 MHz par défaut")
        try expectEqual(six.best?.channel, 37, "1–29 occupé (160 MHz), 33–45 libre : PSC 37")
        try expect(six.best?.isPSC == true, "canal PSC")
        let two = WifiChannelAdvisor.advice(.ghz24, networks: networks, connected: nil, scanned: true)
        try expectEqual(two.best?.channel, 11, "11 : un seul voisin, très faible")
        let none = WifiChannelAdvisor.advice(.ghz5, networks: networks, connected: nil, scanned: true)
        try expectEqual(none.networkCount, 0, "aucun réseau en 5 GHz")
        try expectEqual(none.best?.channel, 36, "bande vide : 36 (hors DFS, le plus bas)")
        try expect(none.summary.hasPrefix("Aucun réseau vu"), "résumé : bande vide")
        let unscanned = WifiChannelAdvisor.advice(.ghz5, networks: [], connected: nil, scanned: false)
        try expectEqual(unscanned.verdict, .noScan, "sans analyse")
        try expect(unscanned.best == nil, "rien de conseillé sans analyse")
    }

    suite.add("Wi-Fi ce Mac : largeur plus étroite proposée quand aucun bloc n'est libre") {
        let mine = net("Bureau", "70:4C:A5:00:00:01", .ghz5, 36, 80, -50, connected: true)
        var networks = [mine]
        // Chaque bloc de 80 MHz porte un voisin de 20 MHz ; 44–48 (40 MHz) reste libre.
        for (k, channel) in [36, 56, 100, 120, 136, 149].enumerated() {
            networks.append(net("V\(k)", "30:00:00:00:00:0\(k)", .ghz5, channel, 20, -60))
        }
        let advice = WifiChannelAdvisor.advice(.ghz5, networks: networks, connected: mine, scanned: true)
        try expect((advice.best?.overlapping ?? 0) > 0, "aucun bloc de 80 MHz libre")
        try expectEqual(advice.alternative?.widthMHz, 40, "un bloc de 40 MHz libre est proposé")
        try expectEqual(advice.alternative?.overlapping, 0, "bloc de 40 MHz libre")
    }

    // MARK: Historique du signal

    suite.add("Wi-Fi ce Mac : historique d'une heure (oubli, fenêtre, statistiques)") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var timeline = WifiSignalTimeline()
        // 70 minutes de relevés toutes les 10 s ; changement de borne à la 65e minute.
        for k in 0..<(70 * 6) {
            let time = start.addingTimeInterval(Double(k) * 10)
            let rssi: Int? = (k >= 300 && k < 306) ? nil : -55 - (k % 7)
            timeline.append(WifiSignalSample(time: time, rssi: rssi, noise: -92, channel: 44,
                                             bssid: k < 390 ? "AA:AA:AA:AA:AA:01" : "AA:AA:AA:AA:AA:02"))
        }
        let now = start.addingTimeInterval(Double(70 * 6 - 1) * 10)
        try expect(timeline.coveredSeconds(now: now) <= WifiSignalTimeline.maxAge, "une heure au plus")
        try expectEqual(timeline.samples.count, 361, "relevés de plus d'une heure oubliés")
        let stats = try unwrap(timeline.stats(WifiSignalSpan.oneHour.seconds, now: now), "statistiques sur 1 h")
        try expectEqual(stats.minimum, -61, "minimum")
        try expectEqual(stats.maximum, -55, "maximum")
        try expectEqual(stats.disconnected, 6, "une minute sans connexion")
        try expectEqual(stats.roams, 1, "un changement de borne")
        try expectEqual(stats.averageNoise, -92, "bruit moyen")
        let short = try unwrap(timeline.stats(WifiSignalSpan.twoMinutes.seconds, now: now), "2 min")
        try expectEqual(short.count, 13, "2 minutes : 13 relevés à 10 s")
        // Graphe : la minute sans connexion coupe la courbe.
        let buckets = timeline.drawableBuckets(WifiSignalSpan.oneHour.seconds, now: now, count: 120)
        try expectEqual(buckets.count, 120, "120 tranches")
        let empty = buckets.filter { !$0.hasData }.count
        try expect(empty >= 1 && empty <= 3, "tranches vides pendant la coupure (obtenu \(empty))")
        // 10 minutes à 5 s par tranche : relevés toutes les 10 s, tranches vides comblées.
        let ten = timeline.drawableBuckets(WifiSignalSpan.tenMinutes.seconds, now: now, count: 120)
        try expect(ten.dropFirst().allSatisfy(\.hasData), "pas de trou entre deux relevés à 10 s")
    }

    suite.add("Wi-Fi ce Mac : relevé hors d'ordre et libellés des durées") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var timeline = WifiSignalTimeline()
        timeline.append(WifiSignalSample(time: t0.addingTimeInterval(20), rssi: -60))
        timeline.append(WifiSignalSample(time: t0, rssi: -50))
        try expectEqual(timeline.samples.map(\.rssi), [-50, -60], "relevés triés par heure")
        try expectEqual(WifiSignalSpan.oneHour.label, "1\u{00A0}h", "1 h")
        try expectEqual(WifiSignalSpan.tenMinutes.label, "10\u{00A0}min", "10 min")
        try expectEqual(WifiSignalSpan.twoMinutes.bucketCount, 60, "2 min : une tranche par relevé de 2 s")
    }

    // MARK: Relevé par pièce

    suite.add("Wi-Fi ce Mac : relevé par pièce (constats, résumé, fichier)") {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var survey = WifiRoomSurvey()
        survey.add(WifiRoomMeasure(room: "Accueil", time: t, ssid: "Bureau-Corp", bssid: "70:4C:A5:1E:22:A0", band: .ghz5, channel: 44,
                                   rssi: -48, noise: -93, linkRateMbps: 866.7, latencyMs: 2.4, jitterMs: 0.6, lossPercent: 0,
                                   latencyTarget: "passerelle 10.0.0.1", downloadMbps: 412.5))
        survey.add(WifiRoomMeasure(room: "Salle 204", time: t.addingTimeInterval(300), rssi: -66, noise: -88, latencyMs: 41, lossPercent: 0))
        survey.add(WifiRoomMeasure(room: "Entrepôt", time: t.addingTimeInterval(600), rssi: -79, noise: -90, latencyMs: 12, lossPercent: 15))
        survey.add(WifiRoomMeasure(room: "accueil", time: t.addingTimeInterval(900), rssi: -50, noise: -93))
        try expectEqual(survey.measures.first?.verdict, .bon, "accueil : bon")
        try expectEqual(survey.measures[1].verdict, .moyen, "salle 204 : SNR 22 et latence 41 ms")
        try expectEqual(survey.measures[1].issues, ["latence élevée"], "constat de latence")
        try expectEqual(survey.measures[2].verdict, .faible, "entrepôt : faible")
        try expectEqual(survey.measures[2].issues.first, "signal faible", "signal faible d'abord")
        let rooms = survey.rooms
        try expectEqual(rooms.count, 3, "accueil et Accueil : une seule pièce")
        try expectEqual(rooms.first?.room, "Entrepôt", "la plus faible d'abord")
        try expectEqual(rooms.last?.count, 2, "deux mesures pour l'accueil")
        try expectEqual(survey.summary, "3 pièces · 1 faible · 1 moyenne", "résumé")
        try expectEqual(WifiRoomSurvey.roomName("  ", index: 4), "Point 4", "pièce sans nom")

        let data = try unwrap(survey.encoded(), "encodage")
        let back = try unwrap(WifiRoomSurvey.decode(data), "relecture")
        try expectEqual(back, survey, "aller-retour du fichier")
        var future = survey
        future.version = 99
        try expect(WifiRoomSurvey.decode(future.encoded()!) == nil, "version future refusée (fichier non écrasé)")
        let files = SiteFiles(base: URL(fileURLWithPath: "/tmp/netscope-test"))
        try expect(WifiRoomSurvey.url(in: files, siteKey: "abc").path.hasSuffix("sites/abc/wifi-releve.json"), "fichier du site")
        survey.remove([survey.measures[0].id])
        try expectEqual(survey.measures.count, 3, "mesure retirée")
    }

    suite.add("Wi-Fi ce Mac : export CSV du relevé") {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let survey = WifiRoomSurvey(measures: [
            WifiRoomMeasure(room: "Salle; réunion", time: t, ssid: "Bureau-Corp", band: .ghz5, channel: 44, rssi: -61, noise: -92,
                            linkRateMbps: 573.5, latencyMs: 3.25, lossPercent: 0, latencyTarget: "passerelle 10.0.0.1", downloadMbps: 245),
            WifiRoomMeasure(room: "=SOMME(A1)", time: t.addingTimeInterval(60), rssi: -72),
        ])
        let csv = survey.csv(site: "Siège", timeZone: TimeZone(identifier: "America/Toronto")!)
        let lines = csv.split(separator: "\n").map(String.init)
        try expectEqual(lines.count, 4, "titre, en-tête et deux mesures")
        try expect(lines[1].hasPrefix("Pièce;Date;Heure;SSID"), "en-tête")
        try expect(lines[2].hasPrefix("\"Salle; réunion\";2027-01-15;03:00:00;Bureau-Corp;;5 GHz;44;-61;-92;31;573,5;3,3;"), "mesure : \(lines[2])")
        try expect(lines[2].contains(";245;Bon;"), "débit mesuré et qualité")
        try expect(lines[3].hasPrefix("'=SOMME(A1)"), "formule neutralisée")
        try expect(lines[3].contains(";Faible;signal faible;"), "constats")
        try expectEqual(WifiRoomSurvey.number(12.04), "12", "arrondi")
        try expectEqual(WifiRoomSurvey.number(0.55), "0,6", "virgule décimale")
    }
}

/// Valeur présente, sinon échec.
private func unwrap<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message + " — valeur absente", file: file, line: line) }
    return value
}
