import Foundation
@testable import NetScopeCore

// Note 81 : mise à jour automatique de la base des fabricants. Aucun accès réseau : la décision
// est une fonction pure, le « téléchargement » est une fermeture qui renvoie des CSV fabriqués ici.

func registerOUIAutoUpdateTests(_ suite: TestSuite) {
    let now = ISO8601DateFormatter().date(from: "2026-11-05T14:00:00Z")!
    let day: TimeInterval = 86_400
    let online = NetworkPathStatus(isSatisfied: true)
    func context(databaseAge: Double?, scanning: Bool = false, path: NetworkPathStatus? = NetworkPathStatus(isSatisfied: true),
                 sandboxed: Bool = false) -> OUIAutoUpdateContext {
        OUIAutoUpdateContext(now: now, databaseDate: databaseAge.map { now.addingTimeInterval(-$0 * day) },
                             isScanning: scanning, path: path, isSandboxed: sandboxed)
    }

    suite.add("Base IEEE automatique : vérifier seulement une base de plus de 30 jours") {
        let settings = OUIAutoUpdateSettings()
        try expect(settings.isEnabled, "activée par défaut")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 45)), .check, "base de 45 jours")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: nil)), .check, "table intégrée seule")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 12)),
                        .skip(.databaseRecent(until: now.addingTimeInterval(18 * day))), "base de 12 jours")
        try expectEqual(OUIAutoUpdatePolicy.decide(OUIAutoUpdateSettings(isEnabled: false), context: context(databaseAge: 400)),
                        .skip(.disabled), "désactivée")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 400, sandboxed: true)),
                        .skip(.sandboxed), "jamais en démonstration")
    }

    suite.add("Base IEEE automatique : au plus une fois par mois, nouvel essai le lendemain d'un échec") {
        let checked = OUIAutoUpdateSettings(lastCheck: now.addingTimeInterval(-10 * day),
                                            lastOutcome: .updated(added: 0, total: 55_000))
        try expectEqual(OUIAutoUpdatePolicy.decide(checked, context: context(databaseAge: 40)),
                        .skip(.checkedRecently(until: now.addingTimeInterval(20 * day))), "vérifiée il y a 10 jours")
        let old = OUIAutoUpdateSettings(lastCheck: now.addingTimeInterval(-31 * day), lastOutcome: .updated(added: 3, total: 55_000))
        try expectEqual(OUIAutoUpdatePolicy.decide(old, context: context(databaseAge: 40)), .check, "vérifiée il y a 31 jours")
        let failedYesterday = OUIAutoUpdateSettings(lastCheck: now.addingTimeInterval(-2 * 3_600), lastOutcome: .failed("HTTP 503"))
        try expectEqual(OUIAutoUpdatePolicy.decide(failedYesterday, context: context(databaseAge: 40)),
                        .skip(.checkedRecently(until: now.addingTimeInterval(22 * 3_600))), "échec il y a 2 h : demain")
        let failedLongAgo = OUIAutoUpdateSettings(lastCheck: now.addingTimeInterval(-25 * 3_600), lastOutcome: .failed("HTTP 503"))
        try expectEqual(OUIAutoUpdatePolicy.decide(failedLongAgo, context: context(databaseAge: 40)), .check, "échec d'hier : nouvel essai")
        try expectEqual(OUIAutoUpdatePolicy.nextCheck(OUIAutoUpdateSettings(), databaseDate: nil), nil, "jamais vérifiée, sans date")
    }

    suite.add("Base IEEE automatique : jamais pendant un scan ni sur une connexion limitée") {
        let settings = OUIAutoUpdateSettings()
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 60, scanning: true)),
                        .skip(.scanning), "scan en cours")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 60, path: NetworkPathStatus(isSatisfied: true, isExpensive: true))),
                        .skip(.limitedConnection), "partage de connexion du téléphone (expensive)")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 60, path: NetworkPathStatus(isSatisfied: true, isConstrained: true))),
                        .skip(.limitedConnection), "mode données réduites (constrained)")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 60, path: NetworkPathStatus(isSatisfied: false))),
                        .skip(.offline), "hors ligne")
        try expectEqual(OUIAutoUpdatePolicy.decide(settings, context: context(databaseAge: 60, path: nil)), .skip(.offline), "état inconnu")
        try expect(OUIAutoUpdateSkip.scanning.isPostponed && OUIAutoUpdateSkip.limitedConnection.isPostponed, "seulement reportée")
        try expect(!OUIAutoUpdateSkip.disabled.isPostponed, "désactivée : pas un report")
        try expect(online.isSatisfied && !online.isLimited, "connexion ordinaire")
    }

    suite.add("Base IEEE automatique : date de l'en-tête et réglages relus") {
        let date = OUIAutoUpdatePolicy.databaseDate("2026-11-03")
        try expectEqual(date, ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"), "midi UTC")
        try expectEqual(OUIAutoUpdatePolicy.databaseDate("pas une date"), nil, "en-tête illisible")
        let settings = OUIAutoUpdateSettings(isEnabled: false, lastCheck: now, lastUpdate: now, lastOutcome: .updated(added: 312, total: 55_123))
        try expectEqual(OUIAutoUpdateSettings.decode(settings.encoded()), settings, "aller-retour JSON")
        try expectEqual(OUIAutoUpdateSettings.decode(Data("{".utf8)), OUIAutoUpdateSettings(), "illisible : réglage par défaut")
        try expectEqual(OUIAutoUpdateOutcome.updated(added: 312, total: 1).label, "+312 préfixes", "libellé")
        let text = OUIAutoUpdateRun.notificationText(.updated(added: 1_312, total: 55_123))
        try expectEqual(text?.title, "Base des fabricants mise à jour\u{00A0}: +1\u{202F}312 préfixes", "titre de la notification")
        try expectEqual(OUIAutoUpdateRun.notificationText(.failed("x")) == nil, true, "pas de notification d'échec")
    }

    suite.add("Base IEEE automatique : mise à jour réussie, puis échec sans perte de la base") {
        let header = "Registry,Assignment,Organization Name,Organization Address\n"
        func registry(_ count: Int) -> [String: Data] {
            var oui = header
            for index in 0..<count { oui += "MA-L,\(String(format: "%06lX", 0x100000 + index)),\"Fabricant \(index), Inc.\",Adresse\n" }
            var mam = header
            for index in 0..<1_000 { mam += "MA-M,\(String(format: "%07lX", 0xA000000 + index)),FABRICANT M\(index) LTD,\n" }
            var oui36 = header
            for index in 0..<1_000 { oui36 += "MA-S,\(String(format: "%09lX", 0x8C1F64000 + index)),\"Bloc \(index) GmbH\",\n" }
            return ["oui.csv": Data(oui.utf8), "mam.csv": Data(mam.utf8), "oui36.csv": Data(oui36.utf8)]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-oui-auto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("oui.tsv")
        let updater = OUIUpdater(destination: destination)
        let database = OUIDatabase(candidates: { [(destination, .user)] })
        // Base en place (20 100 préfixes MA-L) écrite par une première mise à jour.
        try updater.install(csv: registry(20_100), date: now.addingTimeInterval(-40 * day))
        database.reload()
        let before = database.count

        let first = await OUIAutoUpdateRun.perform(settings: OUIAutoUpdateSettings(), updater: updater, database: database, now: now) {
            registry(20_412)
        }
        try expectEqual(first?.outcome, .updated(added: 312, total: before + 312), "+312 préfixes")
        try expectEqual(first?.settings.lastCheck, now, "date de vérification")
        try expectEqual(first?.settings.lastUpdate, now, "date de mise à jour")
        try expectEqual(database.source.date, "2026-11-05", "nouvelle base chargée")
        let written = try Data(contentsOf: destination)

        struct Panne: Error, CustomStringConvertible { var description: String { "réseau injoignable" } }
        let second = await OUIAutoUpdateRun.perform(settings: first!.settings, updater: updater, database: database,
                                                    now: now.addingTimeInterval(31 * day)) { throw Panne() }
        try expectEqual(second?.outcome, .failed("réseau injoignable"), "échec du téléchargement")
        try expectEqual(second?.settings.lastUpdate, now, "dernière mise à jour inchangée")
        try expectEqual(try Data(contentsOf: destination), written, "fichier de la base intact")
        try expectEqual(database.count, before + 312, "base chargée intacte")

        let truncated = await OUIAutoUpdateRun.perform(settings: first!.settings, updater: updater, database: database,
                                                       now: now.addingTimeInterval(32 * day)) {
            ["oui.csv": Data((header + "MA-L,3C22FB,Apple,\n").utf8), "mam.csv": Data(), "oui36.csv": Data()]
        }
        try expect(truncated?.outcome.isFailure == true, "registre tronqué refusé")
        try expectEqual(try Data(contentsOf: destination), written, "toujours la même base")

        let cancelled = await OUIAutoUpdateRun.perform(settings: first!.settings, updater: updater, database: database, now: now) {
            throw CancellationError()
        }
        try expect(cancelled == nil, "annulation : rien d'enregistré")
    }
}
