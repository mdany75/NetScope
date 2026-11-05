import Foundation
import NetScopeCore

// Tests des corrections de relecture des outils courriel et de l'état des services en ligne :
// réponses DNS fixes (MailDNSFixture), aucun trafic réseau.

func registerMailReviewTests(_ suite: TestSuite) {
    suite.add("Courriel : « ip4: » vide dans le SPF, sans plantage des listes noires") {
        let fixture = MailDNSFixture(records: [
            "vide.test|TXT": ["v=spf1 ip4: ip4 -all"],
            "vide.test|MX": ["10 mx.vide.test."],
            "mx.vide.test|A": ["198.51.100.9"],
        ])
        let report = await MailHealth.run("vide.test", client: fixture)
        let targets = MailHealth.blacklistTargets("vide.test", mx: report.mx, spf: report.spf)
        try expectEqual(targets, [.domain("vide.test"), .ip(IPv4Address("198.51.100.9")!)], "adresse du MX seulement")
        try expect(report.spf.findings.contains { $0.status == .error }, "faute de syntaxe signalée")
    }

    suite.add("SPF : règle « all » reprise à travers deux redirect") {
        let fixture = MailDNSFixture(records: [
            "racine.test|TXT": ["v=spf1 redirect=a.test"],
            "a.test|TXT": ["v=spf1 redirect=b.test"],
            "b.test|TXT": ["v=spf1 ip4:198.51.100.1 -all"],
        ])
        let report = await SPFAnalyzer.analyze("racine.test", client: fixture)
        try expectEqual(report.allQualifier, "-", "-all de b.test")
        try expect(!report.findings.contains { $0.title.contains("Pas de règle") }, "pas de constat « Pas de règle all »")

        let local = MailDNSFixture(records: [
            "racine.test|TXT": ["v=spf1 include:a.test ~all"],
            "a.test|TXT": ["v=spf1 redirect=b.test"],
            "b.test|TXT": ["v=spf1 -all"],
        ])
        let own = await SPFAnalyzer.analyze("racine.test", client: local)
        try expectEqual(own.allQualifier, "~", "un include ne change pas la règle de la racine")
    }

    suite.add("MX : recherches A et AAAA sans réponse, hors note") {
        var fixture = MailDNSFixture(records: ["panne.test|MX": ["10 mx.panne.test."]],
                                     failures: ["mx.panne.test|A": "délai dépassé", "mx.panne.test|AAAA": "délai dépassé"])
        let mx = await MXLookup.run("panne.test", client: fixture)
        try expect(mx.hosts.first?.lookupFailed == true, "échec de requête mémorisé")
        try expect(!mx.findings.contains { $0.title == "Aucun MX joignable" }, "pas « Aucun MX joignable »")
        let report = await MailHealth.run("panne.test", client: fixture)
        let check = report.summary.checks.first { $0.category == .mx }
        try expect(check?.points == nil && check?.status == .info, "MX hors note")

        fixture.failures = [:]
        let empty = await MXLookup.run("panne.test", client: fixture)
        try expect(empty.findings.contains { $0.title == "Aucun MX joignable" }, "nom sans adresse : erreur")
    }

    suite.add("Santé courriel : DNSSEC lu sur la zone, pas sur le sous-domaine") {
        let fixture = MailDNSFixture(records: ["ventes.signe.ca|MX": ["0 ."]], signedDomains: ["signe.ca"])
        let report = await MailHealth.run("ventes.signe.ca", client: fixture)
        try expectEqual(report.dnssec, .signed, "DS de signe.ca")
    }

    suite.add("DNS : noms refusés au repli dig (« @ », « + », « - ») et état de dig") {
        for name in ["@1.2.3.4", "+short", "-f/etc/passwd"] {
            do {
                _ = try await DNSLookup.resolve(name, type: .a)
                throw TestFailure(message: "\(name) accepté", file: #fileID, line: #line)
            } catch let error as DNSError {
                try expectEqual(error, .invalidName(name), "nom refusé avant tout envoi")
            }
        }
        try expectEqual(DNSLookup.digStatus(";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 4242\n"), "NXDOMAIN", "état lu")
        try expect(DNSLookup.digStatus(";; connection timed out; no servers could be reached\n") == nil, "sans réponse : nil")
    }

    suite.add("Services : parties suivies filtrent les incidents (Google Workspace)") {
        let service = SvcCatalog.builtIn.first { $0.id == "googleworkspace" }!
        let other = SvcIncident(id: "1", title: "Agenda indisponible", impact: .outage, status: "En cours", affected: ["Google Calendar"])
        let gmail = SvcIncident(id: "2", title: "Lenteurs", impact: .degraded, status: "En cours", affected: ["Gmail"])
        let whole = SvcIncident(id: "3", title: "Incident", impact: .degraded, status: "En cours", affected: ["Google Workspace"])
        let onlyOther = SvcChecker.filtered(SvcFeedReport(health: .outage, description: "", incidents: [other]), for: service)
        try expectEqual(onlyOther.health, .operational, "incident d’un autre produit écarté")
        try expect(onlyOther.incidents.isEmpty, "liste vide")
        let mixed = SvcChecker.filtered(SvcFeedReport(health: .outage, description: "", incidents: [other, gmail, whole]), for: service)
        try expectEqual(mixed.incidents.map(\.id), ["2", "3"], "Gmail et Workspace gardés")
        try expectEqual(mixed.health, .degraded, "état recalculé")
        let unfiltered = SvcService(id: "x", name: "X", category: "", format: .statuspage, feedURL: nil, pageURL: "", endpoints: [])
        try expectEqual(SvcChecker.filtered(SvcFeedReport(health: .outage, description: "", incidents: [other]), for: unfiltered).health,
                        .outage, "sans parties suivies : rien de filtré")
        // Aucun incident, mais un composant non suivi dégradé : les parties suivies vont bien.
        let calm = SvcFeedReport(health: .degraded, description: "", incidents: [],
                                 components: [SvcComponent(name: "Google Calendar", health: .degraded), SvcComponent(name: "Gmail", health: .operational)])
        try expectEqual(SvcChecker.filtered(calm, for: service).health, .operational, "composant non suivi dégradé : écarté")
        let gmailDown = SvcFeedReport(health: .degraded, description: "", incidents: [],
                                      components: [SvcComponent(name: "Gmail", health: .degraded)])
        try expectEqual(SvcChecker.filtered(gmailDown, for: service).health, .degraded, "composant suivi dégradé : gardé")
    }

    suite.add("Services : catalogue enregistré, définition intégrée à jour") {
        var saved = SvcCatalog.builtIn[0]
        saved.feedURL = "https://ancienne.adresse.test/"
        saved.isEnabled = false
        let merged = SvcCatalog.merged(saved: [saved])
        try expectEqual(merged[0].feedURL, SvcCatalog.builtIn[0].feedURL, "adresse de cette version")
        try expectEqual(merged[0].isEnabled, false, "choix de l’utilisateur gardé")
    }

    suite.add("Typographie : espaces insécables dans les textes des outils courriel et services") {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folders = ["NetScopeCore/MailDNS", "NetScopeCore/MailTools", "NetScopeCore/ServiceStatus"]
        var files: [URL] = []
        for folder in folders {
            let url = sources.appendingPathComponent(folder)
            files += (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "swift" } ?? []
        }
        guard !files.isEmpty else { throw TestSkipped(reason: "sources introuvables") }
        var problems: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for literal in SwiftLiterals.texts(in: text) where SwiftLiterals.badTypography(literal) {
                problems.append("\(file.lastPathComponent)\u{00A0}: \(literal)")
            }
        }
        try expect(problems.isEmpty, "espace ordinaire avant : ; ? ! ou dans « »\u{00A0}: " + problems.prefix(5).joined(separator: " | "))
    }
}

/// Texte des littéraux de chaîne d'un fichier Swift (hors interpolations, commentaires et chaînes brutes).
enum SwiftLiterals {
    static func texts(in source: String) -> [String] {
        let chars = Array(source)
        var result: [String] = []
        var stack: [(kind: Character, depth: Int)] = [("c", 0)]   // c : code, i : interpolation, s : chaîne, m : multiligne
        var current = ""
        var i = 0
        func starts(_ text: String) -> Bool {
            let t = Array(text)
            return i + t.count <= chars.count && Array(chars[i..<(i + t.count)]) == t
        }
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
        }
        while i < chars.count {
            let kind = stack[stack.count - 1].kind
            let c = chars[i]
            if kind == "c" || kind == "i" {
                if starts("//") {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                } else if starts("/*") {
                    i += 2
                    while i < chars.count && !starts("*/") { i += 1 }
                    i += 2
                } else if starts("#\"") {
                    i += 2
                    while i < chars.count && !starts("\"#") { i += 1 }
                    i += 2
                } else if starts("\"\"\"") {
                    stack.append(("m", 0)); i += 3
                } else if c == "\"" {
                    stack.append(("s", 0)); i += 1
                } else if c == "(" {
                    stack[stack.count - 1].depth += 1; i += 1
                } else if c == ")" {
                    if kind == "i" && stack[stack.count - 1].depth == 0 { stack.removeLast() } else { stack[stack.count - 1].depth -= 1 }
                    i += 1
                } else {
                    i += 1
                }
                continue
            }
            if c == "\\" {
                flush()
                if i + 1 < chars.count && chars[i + 1] == "(" {
                    stack.append(("i", 0)); i += 2
                } else if starts("\\u{") {
                    while i < chars.count && chars[i] != "}" { i += 1 }
                    i += 1
                } else {
                    i += 2
                }
                continue
            }
            if kind == "m" && starts("\"\"\"") { flush(); stack.removeLast(); i += 3; continue }
            if kind == "s" && (c == "\"" || c == "\n") { flush(); stack.removeLast(); i += 1; continue }
            current.append(c)
            i += 1
        }
        flush()
        return result
    }

    /// Espace ordinaire avant « : ; ? ! » (suivis d'un blanc ou en fin de morceau), ou à l'intérieur de « ».
    static func badTypography(_ text: String) -> Bool {
        if text.contains("« ") || text.contains(" »") { return true }
        return text.range(of: " [:;?!](\\s|$)", options: .regularExpression) != nil
    }
}
