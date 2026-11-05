import Foundation
import NetScopeCore

// Note 78 (0.26.0) : événements dédiés des alertes (licence, firmware, Syslog, WAN) au lieu d'un
// « sonde en panne » générique, règles activables et relecture des anciens réglages. Données fixes.

/// Valeur présente, sinon échec du test (tests de la note 78).
func required78<T>(_ value: T?, _ what: String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
    return value
}

func registerAlertDedicatedTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    suite.add("Alertes : type dédié selon la sonde et la gravité") {
        try expectEqual(AlertEventKind.forProbe(.licenseExpiring, severity: .warning), .licenseExpiring, "licence")
        try expectEqual(AlertEventKind.forProbe(.firmwareOutdated, severity: .critical), .firmwareOutdated, "firmware critique")
        try expectEqual(AlertEventKind.forProbe(.syslogSeverity, severity: .warning), .syslogSevere, "Syslog")
        try expectEqual(AlertEventKind.forProbe(.wanLink, severity: .critical), .wanDown, "WAN en panne")
        try expectEqual(AlertEventKind.forProbe(.vpnTunnel, severity: .critical), .wanDown, "tunnel VPN tombé")
        try expectEqual(AlertEventKind.forProbe(.wanLink, severity: .warning), .probeWarning, "WAN dégradé : alerte générique")
        try expectEqual(AlertEventKind.forProbe(.ping, severity: .critical), .probeDown, "ping : toujours générique")
        try expectEqual(AlertEventKind.forProbe(.ping, severity: .warning), .probeWarning, "ping en alerte")
        try expect(AlertEventKind.forProbe(.ping, severity: .info) == nil, "info d'une sonde ping : rien")
        try expectEqual(AlertEventKind.forProbe(.newDevices, severity: .info), .newDevice, "nouvel appareil")
        try expect(AlertEventKind.forProbe(.licenseExpiring, severity: .success) == nil, "réussite : rien")

        try expectEqual(NetScopeEventKind.forProbe(.wanLink, severity: .critical), .wanDown, "notification WAN")
        try expectEqual(NetScopeEventKind.forProbe(.licenseExpiring, severity: .warning), .licenseExpiring, "notification licence")
        try expectEqual(NetScopeEventKind.forProbe(.switchPort, severity: .warning), .deviceMoved, "port de switch : déplacé")
        try expectEqual(NetScopeEventKind.forProbe(.http, severity: .critical), .probeDown, "HTTP : générique")
        try expectEqual(NetScopeEventKind.probeTitle(.licenseExpiring, severity: .critical, probeName: "IPS"),
                        "Licence expirée\u{00A0}: IPS", "titre licence expirée")
        try expectEqual(NetScopeEventKind.probeTitle(.wanDown, severity: .critical, probeName: "Siège / wan1"),
                        "WAN en panne\u{00A0}: Siège / wan1", "titre WAN")
    }

    suite.add("Alertes : l'adaptateur de sonde produit l'événement dédié") {
        let probe = MonProbe(name: "Siège / wan2", kind: .wanLink, target: "Siège / wan2")
        let alert = MonAlert(date: now, probeID: probe.id, probeName: probe.name, severity: .critical, message: "Lien wan2 tombé")
        let event = try required78(AlertEvent.probe(alert, probe: probe), "événement WAN")
        try expectEqual(event.kind, .wanDown, "type WAN")
        try expectEqual(event.severity, .critical, "critique")
        try expectEqual(event.title, "WAN en panne · Siège / wan2", "titre")
        try expectEqual(event.probeID, probe.id, "sonde rattachée")

        let license = MonProbe(name: "FortiGuard IPS", kind: .licenseExpiring, target: "*")
        let warn = MonAlert(date: now, probeID: license.id, probeName: license.name, severity: .warning, message: "Expire dans 12 jours")
        let licenseEvent = try required78(AlertEvent.probe(warn, probe: license), "événement licence")
        try expectEqual(licenseEvent.kind, .licenseExpiring, "type licence")
        try expectEqual(licenseEvent.severity, .warning, "alerte")
    }

    suite.add("Alertes : règles des événements dédiés (activables, rétablissement)") {
        var settings = AlertSettings()
        settings.isEnabled = true
        settings.smtp.isEnabled = true
        try expect(settings.rules.kinds.isSuperset(of: [.licenseExpiring, .firmwareOutdated, .syslogSevere, .wanDown]),
                   "dédiés choisis par défaut")
        settings.rules.throttleMinutes = 0
        let probe = MonProbe(name: "Siège / wan1", kind: .wanLink, target: "Siège / wan1")
        let down = MonAlert(date: now, probeID: probe.id, probeName: probe.name, severity: .critical, message: "Tombé")
        var planner = AlertPlanner()
        try expectEqual(planner.submit(try required78(AlertEvent.probe(down, probe: probe), "panne"), settings: settings, now: now), .queued,
                        "WAN en panne envoyé")
        // Rétablissement : la panne WAN a été signalée, il part.
        try expectEqual(planner.submit(.probeRecovery(probe: probe, value: "En ligne", at: now), settings: settings, now: now), .queued,
                        "rétablissement envoyé après une panne WAN")

        // Coupé : le type dédié ne part plus, même si « sonde en panne » reste choisi.
        settings.rules.kinds.remove(.wanDown)
        var second = AlertPlanner()
        try expectEqual(second.submit(try required78(AlertEvent.probe(down, probe: probe), "panne"), settings: settings, now: now),
                        .skipped(.kindDisabled), "WAN coupé")
        try expectEqual(second.submit(.probeRecovery(probe: probe, value: "En ligne", at: now), settings: settings, now: now),
                        .skipped(.noOpenAlert), "pas de rétablissement sans panne signalée")
        try expect(!settings.channels(forProbe: probe.id).isEmpty, "la sonde garde un canal (autres types choisis)")
    }

    suite.add("Alertes : anciennes règles relues (types dédiés hérités du générique)") {
        // Fichier d'avant la 0.26.0 : « sonde en panne » coupé, « sonde en alerte » choisi.
        let old = #"{"kinds":["sonde.alerte","sonde.retablie","appareil.nouveau"],"minimumSeverity":"info","throttleMinutes":15,"groupingSeconds":60,"quietHours":{"isEnabled":false,"startMinute":1320,"endMinute":420,"criticalBypass":true},"excludedProbes":[]}"#
        let rules = try JSONDecoder().decode(AlertRules.self, from: Data(old.utf8))
        try expect(!rules.kinds.contains(.wanDown), "WAN suit « sonde en panne », coupé")
        try expect(rules.kinds.contains(.licenseExpiring) && rules.kinds.contains(.firmwareOutdated) && rules.kinds.contains(.syslogSevere),
                   "licence, firmware et Syslog suivent « sonde en alerte », choisis")
        try expect(!rules.kinds.contains(.probeDown), "le reste inchangé")

        // Relu après écriture par cette version : le choix de l'utilisateur est gardé tel quel.
        var current = AlertRules()
        current.kinds.remove(.syslogSevere)
        let data = try JSONEncoder().encode(current)
        let again = try JSONDecoder().decode(AlertRules.self, from: data)
        try expectEqual(again.kinds, current.kinds, "aller-retour fidèle")
        try expect(!again.kinds.contains(.syslogSevere), "Syslog coupé reste coupé")

        // Type inconnu (version plus récente) : ignoré sans erreur.
        let future = #"{"kinds":["sonde.panne","futur.type"],"knownKinds":["sonde.panne","futur.type"]}"#
        let read = try JSONDecoder().decode(AlertRules.self, from: Data(future.utf8))
        try expect(read.kinds.contains(.probeDown), "type connu gardé")
    }

    suite.add("Notifications : types dédiés activés à la relecture d'anciens réglages") {
        let old = #"{"bannersEnabled":true,"enabledKinds":["probeDown","probeWarning"],"sound":"critical"}"#
        let settings = NotificationSettings.decoded(Data(old.utf8))
        for kind: NetScopeEventKind in [.licenseExpiring, .firmwareOutdated, .syslogSevere, .wanDown, .pingTargetDown, .pingTargetUp] {
            try expect(settings.isEnabled(kind), "\(kind.rawValue) activé par défaut")
        }
        try expect(!settings.isEnabled(.newDevice), "type coupé à l'époque : reste coupé")
        let quiet = NotificationSettings.decoded(Data(#"{"enabledKinds":["probeDown"]}"#.utf8))
        try expect(quiet.isEnabled(.wanDown), "WAN suit « sonde en panne »")
        try expect(!quiet.isEnabled(.licenseExpiring) && !quiet.isEnabled(.syslogSevere), "licence et Syslog suivent « sonde en alerte » coupé")
        try expectEqual(NetScopeEventKind.wanDown.defaultSeverity, .critical, "WAN : critique")
        try expectEqual(NetScopeEventKind.pingTargetUp.defaultSeverity, .success, "retour : rétabli")
    }
}
