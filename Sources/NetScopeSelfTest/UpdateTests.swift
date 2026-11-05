import Foundation
import NetScopeCore

// Tests de la mise à jour : versions, lecture des réponses GitHub (JSON fixes), choix de la
// version, codes HTTP, préférences. Aucun accès réseau : le transport est simulé.

private let releaseJSON = """
{
  "url": "https://api.github.com/repos/mdany75/NetScope/releases/1",
  "html_url": "https://github.com/mdany75/NetScope/releases/tag/v1.1.0",
  "id": 1,
  "tag_name": "v1.1.0",
  "name": "NetScope 1.1.0",
  "draft": false,
  "prerelease": false,
  "created_at": "2026-10-28T13:58:12Z",
  "published_at": "2026-10-28T14:03:00Z",
  "body": "## Nouveautés\\r\\n- Détection du port de switch par **SNMP v3**\\r\\n- Analyseur Wi-Fi 6 GHz\\r\\n\\r\\n* Corrections du `ping` continu",
  "assets": [
    {
      "url": "https://api.github.com/repos/mdany75/NetScope/releases/assets/11",
      "id": 11,
      "name": "NetScope.dmg",
      "content_type": "application/x-apple-diskimage",
      "size": 18400000,
      "browser_download_url": "https://github.com/mdany75/NetScope/releases/download/v1.1.0/NetScope.dmg"
    },
    {
      "url": "https://api.github.com/repos/mdany75/NetScope/releases/assets/12",
      "id": 12,
      "name": "NetScope.dmg.sha256",
      "size": 64,
      "browser_download_url": "https://github.com/mdany75/NetScope/releases/download/v1.1.0/NetScope.dmg.sha256"
    }
  ]
}
"""

private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, dmg: Bool = true) -> UpdRelease {
    let assets = dmg ? [UpdAsset(name: "NetScope.dmg", size: 1, browserDownloadURL: URL(string: "https://example.invalid/\(tag).dmg")!)] : []
    return UpdRelease(tagName: tag, isPrerelease: prerelease, isDraft: draft, assets: assets)
}

/// Transport simulé : renvoie la réponse prévue pour chaque chemin, et note les requêtes.
private final class FakeTransport: @unchecked Sendable {
    var responses: [String: (Int, String)] = [:]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    private func respond(to request: URLRequest) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let path = request.url!.path + (request.url!.query.map { "?" + $0 } ?? "")
        return responses[path] ?? (500, "")
    }

    var transport: UpdateChecker.Transport {
        { [self] request in
            let (status, body) = respond(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

func registerUpdateTests(_ suite: TestSuite) {
    suite.add("Mises à jour : notes de version lues dans le CHANGELOG") {
        let text = """
        # Changements

        ## 0.23.0 — 2026-11-05

        Une version de fiabilité : NetScope tient un journal
        de ses erreurs.

        ### Ajouté
        - **Journal de NetScope** (Réglages) : les erreurs
          de chaque module sont gardées.
        - **« Exporter un diagnostic… »** : une archive .zip.

        ### Corrigé
        - Le ping continu ne se figeait plus après une mise en veille. Autre phrase.

        ## 0.2.1 — 2026-11-03

        ### Corrigé
        - `oui.tsv` lu au bon endroit.

        ## Brouillon sans numéro
        - ignoré
        """
        let versions = ChangelogNotes.parse(text)
        try expectEqual(versions.map(\.version), ["0.23.0", "0.2.1"], "deux versions, l'en-tête sans numéro ignoré")
        let first = versions[0]
        try expectEqual(first.summary, "Une version de fiabilité : NetScope tient un journal de ses erreurs.", "paragraphe d'introduction sur deux lignes")
        try expectEqual(first.sections.map(\.title), ["Ajouté", "Corrigé"], "rubriques")
        try expectEqual(first.sections[0].items, ["Journal de NetScope", "« Exporter un diagnostic… »"], "titres en gras des points")
        try expectEqual(first.sections[1].items, ["Le ping continu ne se figeait plus après une mise en veille"], "sans gras : première phrase")
        try expectEqual(first.itemCount, 3, "trois points")
        try expect(first.date != nil, "date lue")
        try expectEqual(versions[1].summary, "", "pas d'introduction")
        try expectEqual(versions[1].shortSummary, "oui.tsv lu au bon endroit", "résumé repris des points, sans code Markdown")
    }

    suite.add("Mises à jour : historique complet des versions avec les dates d'installation") {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = ["0.23.0", "0.22.0", "0.21.0", "0.20.0"].map { ChangelogVersion(version: $0, date: nil, summary: "r", sections: []) }
        let history = [UpdHistoryEntry(version: "0.22.0", channel: .stable, date: day.addingTimeInterval(3_600)),
                       UpdHistoryEntry(version: "0.20.0", channel: .stable, date: day),
                       UpdHistoryEntry(version: "0.22.0", channel: .stable, date: day.addingTimeInterval(-60))]
        let rows = UpdTimeline.rows(changelog: notes, history: history, running: "0.22.0")
        try expectEqual(rows.map(\.version), ["0.23.0", "0.22.0", "0.21.0", "0.20.0"], "toutes les versions, la plus récente d'abord")
        try expectEqual(rows.map(\.state), [.newer, .running, .notInstalled, .previous], "états")
        try expectEqual(rows[1].installedAt, day.addingTimeInterval(-60), "première installation retenue")
        try expectEqual(rows[2].installedAt, nil, "jamais installée sur ce Mac")
        let orphan = UpdTimeline.rows(changelog: [], history: [], running: "1.0.0-beta.1")
        try expectEqual(orphan.map(\.version), ["1.0.0-beta.1"], "version en cours même sans CHANGELOG")
        try expectEqual(orphan.first?.channel, .beta, "préversion : canal Bêta")
        var prefs = UpdPreferences()
        for n in 0..<150 { prefs.recordRunning(version: "0.\(n).0", now: day) }
        try expectEqual(prefs.history.count, 150, "historique gardé au-delà de 20 versions")
    }

    suite.add("Mises à jour : le CHANGELOG du projet se lit en entier") {
        let versions = ChangelogNotes.bundled()
        try expect(versions.count >= 25, "au moins 25 versions lues (\(versions.count))")
        try expect(versions.allSatisfy { $0.itemCount > 0 || !$0.summary.isEmpty }, "chaque version a un résumé ou des points")
    }

    suite.add("Mise à jour : comparaison des versions sémantiques") {
        // Une version illisible devient -1.0.0 : la comparaison échoue alors visiblement.
        func v(_ text: String) -> UpdVersion { UpdVersion(text) ?? UpdVersion(major: -1) }
        try expect(v("0.1.0") < v("0.1.1"), "0.1.0 < 0.1.1")
        try expect(v("0.1.1") < v("1.0.0"), "0.1.1 < 1.0.0")
        try expect(v("0.9.9") < v("0.10.0"), "comparaison numérique, pas alphabétique")
        try expectEqual(v("v1.2.3"), v("1.2.3"), "« v » facultatif")
        try expectEqual(v("1.0"), v("1.0.0"), "composante absente = 0")
        try expectEqual(v("2"), v("2.0.0"), "majeure seule")
        try expect(v("1.0.0-beta.1") < v("1.0.0"), "préversion avant la version finale")
        try expect(v("1.0.0-beta.2") < v("1.0.0-beta.10"), "identifiants numériques comparés en nombres")
        try expect(v("1.0.0-beta.9") < v("1.0.0-rc.1"), "beta < rc")
        try expect(v("1.0.0-alpha") < v("1.0.0-alpha.1"), "préfixe plus court avant")
        try expect(v("1.0.0-1") < v("1.0.0-alpha"), "numérique avant alphanumérique")
        try expect(v("0.9.2-beta.3") < v("1.0.0-beta.1"), "préversion d'une version antérieure")
        try expectEqual(v("1.1.0+build.7"), v("1.1.0"), "métadonnées de build ignorées")
        try expectEqual(v("V1.1.0-Beta.2").description, "1.1.0-Beta.2", "description")
        try expect(v("1.1.0-beta.2").isPrerelease, "préversion détectée")
        try expect(!(v("1.1.0").isPrerelease), "version finale")
        for bad in ["", "v", "1.2.3.4", "1..2", "a.b.c", "1.2.3-", "1.2.3-beta..1", "-1.0.0", "1.2.x"] {
            try expect(UpdVersion(bad) == nil, "refusée : « \(bad) »")
        }
    }

    suite.add("Mise à jour : lecture d'une réponse de release GitHub (JSON fixe)") {
        let release = try UpdateChecker.decodeRelease(Data(releaseJSON.utf8))
        try expectEqual(release.tagName, "v1.1.0", "étiquette")
        try expectEqual(release.version, UpdVersion("1.1.0"), "version")
        try expectEqual(release.name, "NetScope 1.1.0", "titre")
        try expect(!release.isPrerelease && !release.isDraft, "version finale publiée")
        try expectEqual(release.htmlURL?.absoluteString, "https://github.com/mdany75/NetScope/releases/tag/v1.1.0", "page web")
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026; components.month = 10; components.day = 28
        components.hour = 14; components.minute = 3
        try expectEqual(release.publishedAt, components.date, "date de publication")
        try expectEqual(release.assets.count, 2, "deux fichiers joints")
        let dmg = try release.diskImage.orThrow("image disque repérée")
        try expectEqual(dmg.size, 18_400_000, "taille")
        try expectEqual(dmg.browserDownloadURL.absoluteString,
                        "https://github.com/mdany75/NetScope/releases/download/v1.1.0/NetScope.dmg", "adresse publique")
        try expectEqual(dmg.apiURL?.absoluteString, "https://api.github.com/repos/mdany75/NetScope/releases/assets/11", "adresse API")
        try expectEqual(release.noteLines,
                        ["Détection du port de switch par SNMP v3", "Analyseur Wi-Fi 6 GHz", "Corrections du ping continu"],
                        "notes nettoyées")

        let list = try UpdateChecker.decodeReleases(Data("[\(releaseJSON)]".utf8))
        try expectEqual(list.count, 1, "liste")
        try expectEqual(try UpdateChecker.decodeReleases(Data("[]".utf8)).count, 0, "liste vide")
        do {
            _ = try UpdateChecker.decodeRelease(Data("{\"name\": \"x\"}".utf8))
            throw TestFailure(message: "JSON incomplet accepté", file: #fileID, line: #line)
        } catch let error as UpdError {
            guard case .invalidResponse = error else { throw TestFailure(message: "erreur inattendue \(error)", file: #fileID, line: #line) }
        }
        // Sans image disque : pas proposée.
        let noDmg = UpdRelease(tagName: "v9.0.0", assets: [dmg].map { var a = $0; a.name = "NetScope.zip"; return a })
        try expect(noDmg.diskImage == nil, "seul « NetScope.dmg » compte")
    }

    suite.add("Mise à jour : choix de la version selon le canal") {
        let releases = [release("v1.0.0"), release("v1.1.0"), release("v1.2.0-beta.1", prerelease: true),
                        release("v2.0.0", draft: true), release("pas-une-version"), release("v1.1.5", dmg: false)]
        let stable = UpdateChecker.evaluate(releases, current: UpdVersion("1.0.0")!, channel: .stable)
        try expectEqual(stable.latest?.tagName, "v1.1.5", "dernière version finale (brouillon exclu)")
        try expectEqual(stable.update?.tagName, "v1.1.0", "proposée : la plus récente avec une image disque")
        let beta = UpdateChecker.evaluate(releases, current: UpdVersion("1.0.0")!, channel: .beta)
        try expectEqual(beta.update?.tagName, "v1.2.0-beta.1", "Bêta : préversion proposée")
        let upToDate = UpdateChecker.evaluate(releases, current: UpdVersion("1.2.0")!, channel: .beta)
        try expect(upToDate.update == nil, "à jour : rien à proposer")
        try expectEqual(upToDate.latest?.tagName, "v1.2.0-beta.1", "dernière du canal quand même connue")
        // Une préversion mal marquée (prerelease false, « -beta » dans l'étiquette) reste hors Stable.
        let mislabeled = UpdateChecker.evaluate([release("v1.3.0-beta.1")], current: UpdVersion("1.0.0")!, channel: .stable)
        try expect(mislabeled.update == nil, "préversion exclue du canal Stable")
        try expect(UpdateChecker.evaluate([], current: UpdVersion("0.1.0")!, channel: .stable).latest == nil, "aucune version")
    }

    suite.add("Mise à jour : codes HTTP, dépôt privé et requêtes (transport simulé)") {
        try expect(UpdateChecker.error(forStatus: 200, hasToken: false) == nil, "200 exploitable")
        try expectEqual(UpdateChecker.error(forStatus: 404, hasToken: false), .privateRepository(hasToken: false), "404 sans jeton")
        try expectEqual(UpdateChecker.error(forStatus: 404, hasToken: true), .privateRepository(hasToken: true), "404 avec jeton")
        try expectEqual(UpdateChecker.error(forStatus: 401, hasToken: true), .badToken, "401")
        try expectEqual(UpdateChecker.error(forStatus: 403, hasToken: false), .rateLimited, "403")
        try expectEqual(UpdateChecker.error(forStatus: 502, hasToken: false), .http(502), "502")
        try expect(UpdError.privateRepository(hasToken: false).localizedDescription.contains("Dépôt privé"), "message du dépôt privé")
        try expect(UpdError.privateRepository(hasToken: false).localizedDescription.contains("jeton GitHub"), "propose un jeton")

        // Dépôt privé sans jeton : 404 sur /releases/latest et sur le dépôt.
        let fake = FakeTransport()
        fake.responses["/repos/mdany75/NetScope/releases/latest"] = (404, "{\"message\":\"Not Found\"}")
        fake.responses["/repos/mdany75/NetScope"] = (404, "{\"message\":\"Not Found\"}")
        let checker = UpdateChecker(transport: fake.transport)
        do {
            _ = try await checker.check(current: UpdVersion("1.0.0")!, channel: .stable)
            throw TestFailure(message: "404 accepté", file: #fileID, line: #line)
        } catch let error as UpdError {
            try expectEqual(error, .privateRepository(hasToken: false), "dépôt privé signalé")
        }
        let first = try fake.requests.first.orThrow("requête envoyée")
        try expectEqual(first.url?.absoluteString, "https://api.github.com/repos/mdany75/NetScope/releases/latest", "adresse Stable")
        try expectEqual(first.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json", "en-tête Accept")
        try expect(first.value(forHTTPHeaderField: "Authorization") == nil, "aucun jeton envoyé")

        // Dépôt public sans aucune version finale : pas une erreur.
        fake.responses["/repos/mdany75/NetScope"] = (200, "{}")
        let none = try await checker.check(current: UpdVersion("1.0.0")!, channel: .stable)
        try expect(none.latest == nil && none.update == nil, "aucune version publiée")

        // Canal Bêta avec jeton : liste, jeton transmis.
        let beta = FakeTransport()
        beta.responses["/repos/mdany75/NetScope/releases?per_page=30"] = (200, "[\(releaseJSON)]")
        let withToken = UpdateChecker(token: "  ghp_exemple  ", transport: beta.transport)
        let result = try await withToken.check(current: UpdVersion("1.0.0")!, channel: .beta)
        try expectEqual(result.update?.tagName, "v1.1.0", "mise à jour trouvée")
        try expectEqual(beta.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_exemple", "jeton nettoyé et transmis")
        let up = try await withToken.check(current: UpdVersion("1.1.0")!, channel: .beta)
        try expect(up.update == nil, "même version : à jour")
        try expect(UpdateChecker(token: "   ").token == nil, "jeton vide ignoré")

        // Téléchargement : adresse publique sans jeton, API avec jeton.
        let dmg = try UpdateChecker.decodeRelease(Data(releaseJSON.utf8)).diskImage.orThrow("image disque")
        try expectEqual(UpdDownloader.request(for: dmg, token: nil).url, dmg.browserDownloadURL, "téléchargement public")
        let privateRequest = UpdDownloader.request(for: dmg, token: "ghp_exemple")
        try expectEqual(privateRequest.url, dmg.apiURL, "téléchargement par l'API")
        try expectEqual(privateRequest.value(forHTTPHeaderField: "Accept"), "application/octet-stream", "contenu binaire demandé")
    }

    suite.add("Mise à jour : fréquence, préférences, signature et installation (sans réseau)") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try expect(UpdFrequency.quotidienne.isDue(lastCheck: nil, now: now, atLaunch: false), "jamais vérifié : due")
        try expect(!UpdFrequency.quotidienne.isDue(lastCheck: now.addingTimeInterval(-3600), now: now, atLaunch: true), "il y a 1 h : pas due")
        try expect(UpdFrequency.quotidienne.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now, atLaunch: false), "il y a 25 h : due")
        try expect(!UpdFrequency.hebdomadaire.isDue(lastCheck: now.addingTimeInterval(-3 * 86400), now: now, atLaunch: true), "hebdomadaire, 3 jours")
        try expect(UpdFrequency.hebdomadaire.isDue(lastCheck: now.addingTimeInterval(-8 * 86400), now: now, atLaunch: false), "hebdomadaire, 8 jours")
        try expect(UpdFrequency.auDemarrage.isDue(lastCheck: now, now: now, atLaunch: true), "au démarrage")
        try expect(!UpdFrequency.auDemarrage.isDue(lastCheck: now, now: now, atLaunch: false), "pas en cours de route")
        try expect(UpdFrequency.quotidienne.isDue(lastCheck: now.addingTimeInterval(86400 * 30), now: now, atLaunch: false), "date future : due")

        var prefs = UpdPreferences()
        try expectEqual(prefs.frequency, .quotidienne, "par défaut : chaque jour")
        try expect(prefs.isCheckDue(now: now, atLaunch: true), "première vérification due")
        prefs.automaticCheck = false
        try expect(!prefs.isCheckDue(now: now, atLaunch: true), "vérification automatique coupée")
        prefs.recordRunning(version: "0.9.2-beta.1", now: now)
        prefs.recordRunning(version: "1.0.0", now: now)
        prefs.recordRunning(version: "1.0.0", now: now)
        try expectEqual(prefs.history.map(\.version), ["1.0.0", "0.9.2-beta.1"], "historique sans doublon")
        try expectEqual(prefs.history.last?.channel, .beta, "canal déduit de la version")
        prefs.skippedVersion = "1.1.0"
        try expect(prefs.isSkipped(release("v1.1.0")), "version ignorée")
        try expect(!prefs.isSkipped(release("v1.1.1")), "version suivante signalée")
        let json = try JSONEncoder().encode(prefs)
        try expectEqual(try JSONDecoder().decode(UpdPreferences.self, from: json), prefs, "aller-retour JSON")
        let partial = try JSONDecoder().decode(UpdPreferences.self, from: Data("{\"channel\":\"beta\"}".utf8))
        try expect(partial.channel == .beta && partial.frequency == .quotidienne && partial.automaticCheck, "champs absents : défauts")

        let codesign = """
        Executable=/Applications/NetScope.app/Contents/MacOS/NetScope
        Identifier=com.danymenard.netscope
        Format=app bundle with Mach-O thin (arm64)
        Authority=Developer ID Application: Dany Ménard (2F5M9B25A6)
        Authority=Developer ID Certification Authority
        TeamIdentifier=2F5M9B25A6
        """
        let fields = UpdSignature.parseCodesignDetails(codesign)
        try expectEqual(fields["TeamIdentifier"], UpdSignature.expectedTeamID, "équipe lue")
        try expectEqual(fields["Identifier"], "com.danymenard.netscope", "identifiant lu")
        try expect(fields["Authority"]?.contains("Certification Authority") ?? false, "autorités réunies")

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk9</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk9s1</string><key>mount-point</key><string>/Volumes/NetScope 1</string></dict>
        </array></dict></plist>
        """
        try expectEqual(UpdInstaller.mountPoint(fromHdiutilPlist: Data(plist.utf8))?.path, "/Volumes/NetScope 1", "point de montage")
        try expect(UpdInstaller.mountPoint(fromHdiutilPlist: Data("rien".utf8)) == nil, "sortie illisible")
        try expect(UpdInstaller.runningBundle(URL(fileURLWithPath: "/Users/x/NetScope/.build/debug")) == nil, "swift run : pas de paquet")
        try expectEqual(UpdInstaller.runningBundle(URL(fileURLWithPath: "/Applications/NetScope.app"))?.path, "/Applications/NetScope.app", "paquet .app")
        try expect(UpdInstaller.installBlocker(bundleURL: URL(fileURLWithPath: "/tmp/debug")) != nil, "installation désactivée hors .app")
        let script = UpdInstaller.relaunchScript
        try expect(script.hasPrefix("#!/bin/sh"), "script shell")
        try expect(script.contains("kill -0 \"$PID\""), "attend la fin du processus")
        try expect(script.contains("/usr/bin/ditto \"$SRC\" \"$DEST\""), "copie avec ditto")
        try expect(script.contains("/usr/bin/open \"$DEST\""), "relance")
        try expect(script.contains("mv \"$OLD\" \"$DEST\""), "remet l'ancienne version en cas d'échec")
    }
}

private extension Optional {
    func orThrow(_ message: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(message) : valeur absente", file: file, line: line) }
        return value
    }
}
