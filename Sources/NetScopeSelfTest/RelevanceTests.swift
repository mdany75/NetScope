import Foundation
import NetScopeCore

// Note 18 : bilan des switchs, emplacements et capture LLDP/CDP rattachés aux plages et au réseau
// qui les ont produits. Logique pure, aucun accès réseau.

func registerRelevanceTests(_ suite: TestSuite) {
    func range(_ text: String) -> IPRange { try! IPRange(parsing: text) }
    func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

    let bureau = NetworkContext(interface: "en0", subnet: try? Subnet(parsing: "10.182.122.0/24"), gateway: IPv4Address("10.182.122.1"))
    let maison = NetworkContext(interface: "en0", subnet: try? Subnet(parsing: "192.168.1.0/24"), gateway: IPv4Address("192.168.1.1"))

    /// Bilan du scan de 10.182.122.0/24 : relevé impossible du switch 10.182.122.124.
    func failedBilan() throws -> SwitchAutoResult {
        SwitchAutoResult(ranges: [range("10.182.122.0/24")], network: bureau,
                         queriedHosts: [ip("10.182.122.1"), ip("10.182.122.124")], respondedHosts: [ip("10.182.122.124")],
                         discoveredHosts: [ip("10.182.122.124")],
                         failed: [.init(name: "10.182.122.124", host: ip("10.182.122.124"))], communitiesTried: 1)
    }

    suite.add("Pertinence : plages qui se recouvrent, se couvrent, adresse contenue") {
        try expect(ScanRelevance.overlaps(range("10.0.0.0/24"), range("10.0.0.100-200")), "/24 et portion")
        try expect(!ScanRelevance.overlaps(range("10.182.122.0/24"), range("192.168.1.0/24")), "réseaux distincts")
        try expect(ScanRelevance.covers([range("10.0.0.0/24")], range("10.0.0.10-20")), "portion couverte")
        try expect(ScanRelevance.covers([range("10.0.0.1-100"), range("10.0.0.101-254")], range("10.0.0.0/24")),
                   "deux portions contiguës couvrent le /24")
        try expect(!ScanRelevance.covers([range("10.0.0.1-100")], range("10.0.0.0/24")), "couverture partielle")
        try expect(ScanRelevance.contains([range("10.0.0.0/24")], ip("10.0.0.7")), "adresse dans la plage")
        try expectEqual(ScanRelevance.rangesLabel([range("10.182.122.0/24")]), "Plage 10.182.122.0/24", "libellé d'une plage")
        try expectEqual(ScanRelevance.rangesLabel([range("10.0.1.0/24"), range("10.0.2.0/24")]),
                        "Plages 10.0.1.0/24, 10.0.2.0/24", "libellé de deux plages")
    }

    suite.add("Pertinence : bilan gardé pour la même plage") {
        let bilan = try failedBilan()
        let shown = bilan.presentation(checked: [range("10.182.122.0/24")], network: bureau)
        try expectEqual(shown?.result, bilan, "bilan entier")
        try expectEqual(shown?.isStale, false, "même réseau : actuel")
        try expectEqual(bilan.rangesLabel, "Plage 10.182.122.0/24", "le message nomme la plage")
    }

    suite.add("Pertinence : bilan masqué pour une autre plage (constat de Dany)") {
        let bilan = try failedBilan()
        try expect(bilan.relevant(to: [range("192.168.1.0/24")]) == nil, "plage 192.168.1.0/24 : rien à afficher")
        try expect(bilan.presentation(checked: [range("192.168.1.0/24")], network: maison) == nil, "présentation masquée")
        try expect(bilan.relevant(to: []) == nil, "aucune plage cochée : masqué")
    }

    suite.add("Pertinence : recouvrement partiel, seule la partie pertinente reste") {
        let sw1 = SwitchAutoResult.SwitchEntry(name: "SW-A", host: ip("10.0.1.2"), located: [ip("10.0.1.10"), ip("10.0.2.20")])
        let sw2 = SwitchAutoResult.SwitchEntry(name: "SW-B", host: ip("10.0.2.2"), located: [ip("10.0.2.21")])
        let gestion = SwitchAutoResult.SwitchEntry(name: "SW-GESTION", host: ip("10.9.9.2"), located: [ip("10.0.1.11")])
        let bilan = SwitchAutoResult(
            ranges: [range("10.0.1.0/24"), range("10.0.2.0/24")], network: bureau,
            queriedHosts: [ip("10.0.1.2"), ip("10.0.2.2"), ip("10.0.2.3")], respondedHosts: [ip("10.0.1.2"), ip("10.0.2.2")],
            discoveredHosts: [ip("10.0.1.2"), ip("10.0.2.2")], switches: [sw1, sw2, gestion],
            failed: [.init(name: "SW-C", host: ip("10.0.2.9"))],
            locatedHosts: [ip("10.0.1.10"), ip("10.0.1.11"), ip("10.0.2.20"), ip("10.0.2.21")], filledHosts: [ip("10.0.2.20")])
        guard let part = bilan.relevant(to: [range("10.0.1.0/24")]) else { throw TestFailure(message: "partie attendue", file: #fileID, line: #line) }
        try expectEqual(part.ranges, [range("10.0.1.0/24")], "seule la plage cochée")
        try expectEqual(part.rangesLabel, "Plage 10.0.1.0/24", "libellé filtré")
        try expectEqual(part.switchNames, ["SW-A", "SW-GESTION"], "SW-B (autre plage, rien de localisé ici) écarté")
        try expectEqual(part.switches.first?.located, [ip("10.0.1.10")], "emplacements de SW-A filtrés")
        try expectEqual(part.located, 2, "appareils localisés dans la plage cochée")
        try expectEqual(part.queried, 1, "hôtes interrogés de la plage")
        try expectEqual(part.responded, 1, "réponses SNMP de la plage")
        try expectEqual(part.filledMACs, 0, "MAC complétées hors plage écartées")
        try expect(part.failed.isEmpty, "échec de l'autre plage écarté")
        // Plages cochées plus larges : le bilan entier reste.
        try expectEqual(bilan.relevant(to: [range("10.0.0.0/16")]), bilan, "plages couvertes : inchangé")
    }

    suite.add("Pertinence : un nouveau scan efface le bilan, même sans découverte") {
        var ledger = SwitchAutoLedger(result: try failedBilan())
        // Scan de 192.168.1.0/24 avec la découverte désactivée (ou SNMP sauté) : aucun bilan.
        ledger.scanStarted(ranges: [range("192.168.1.0/24")], network: maison)
        try expect(ledger.result == nil, "effacé au début du scan")
        ledger.scanEnded(interrupted: false, planned: false)
        try expect(ledger.result == nil, "toujours vide après un scan sans découverte")
        // Découverte prévue mais scan arrêté : bilan « interrompu » rattaché à la nouvelle plage.
        ledger.scanStarted(ranges: [range("192.168.1.0/24")], network: maison)
        ledger.scanEnded(interrupted: true, planned: true)
        try expectEqual(ledger.result?.interrupted, true, "interruption notée")
        try expectEqual(ledger.result?.ranges, [range("192.168.1.0/24")], "rattachée à la plage du scan")
        try expectEqual(ledger.result?.network, maison, "et à son réseau")
        // Bilan d'une découverte : rattaché au scan qui l'a produit, quoi qu'il contienne.
        ledger.scanStarted(ranges: [range("192.168.1.0/24")], network: maison)
        ledger.record(SwitchAutoResult(ranges: [range("10.0.0.0/16")], queriedHosts: [ip("192.168.1.5")]))
        try expectEqual(ledger.result?.ranges, [range("192.168.1.0/24")], "plages du scan")
        ledger.clear()
        try expect(ledger.result == nil, "« Effacer »")
    }

    suite.add("Pertinence : un switch d'un autre réseau qui ne répond pas n'est pas signalé") {
        // Cause du constat : 10.182.122.124, découvert sur l'ancien réseau, est encore interrogé
        // pendant le scan de 192.168.1.0/24 ; son échec ne concerne pas cette plage.
        let polled: [SwitchAutoResult.SwitchEntry] = [
            .init(name: "10.182.122.124", host: ip("10.182.122.124")),
            .init(name: "SW-MAISON", host: ip("192.168.1.2")),
            .init(name: "SW-OK", host: ip("192.168.1.3")),
            .init(name: "SW-GESTION", host: ip("10.9.9.2")),
        ]
        let failures = SwitchAutoResult.reportedFailures(polled: polled, succeeded: [ip("192.168.1.3")],
                                                         discoveredNow: [ip("10.9.9.2")], ranges: [range("192.168.1.0/24")])
        try expectEqual(failures.map(\.name), ["SW-MAISON", "SW-GESTION"],
                        "échecs de la plage scannée et des switchs découverts à l'instant seulement")
    }

    suite.add("Pertinence : changement d'interface ou de passerelle, encart et bilan périmés") {
        let capture = NetworkContext(interface: "en7", subnet: try? Subnet(parsing: "10.182.122.0/24"), gateway: ip("10.182.122.1"))
        try expect(!capture.isStale(comparedTo: capture), "même réseau : actuel")
        try expect(capture.isStale(comparedTo: nil), "interface disparue : périmé")
        try expect(capture.isStale(comparedTo: NetworkContext(interface: "en0", subnet: capture.subnet, gateway: capture.gateway)),
                   "autre interface : périmé")
        try expect(capture.isStale(comparedTo: NetworkContext(interface: "en7", subnet: maison.subnet, gateway: maison.gateway)),
                   "autre sous-réseau : périmé")
        try expect(capture.isStale(comparedTo: NetworkContext(interface: "en7", subnet: capture.subnet, gateway: ip("10.182.122.254"))),
                   "autre passerelle : périmé")
        try expect(!capture.isStale(comparedTo: NetworkContext(interface: "en7", subnet: capture.subnet, gateway: nil)),
                   "passerelle pas encore lue : pas de changement")
        try expect(!NetworkContext(interface: "en7").isStale(comparedTo: capture), "capture ancienne sans réseau : seule l'interface compte")
        try expectEqual(capture.label, "en7 · 10.182.122.0/24", "libellé du réseau")
        let local = LocalInterface(name: "en0", address: ip("10.182.122.135"), netmask: ip("255.255.255.0"), gateway: ip("10.182.122.1"))
        try expectEqual(NetworkContext(local), bureau, "contexte d'une interface locale")
        // Bilan de la même plage, mais le Mac a changé de réseau : affiché comme ancien.
        let shown = try failedBilan().presentation(checked: [range("10.182.122.0/24")], network: maison)
        try expectEqual(shown?.isStale, true, "bilan d'un autre réseau : périmé")
        // Emplacement d'un appareil : actuel seulement dans les plages cochées, sur le même réseau.
        let checked = [range("192.168.1.0/24")]
        try expect(ScanRelevance.isLocationCurrent(ip("192.168.1.20"), checked: checked, networkStale: false), "plage cochée : actuel")
        try expect(!ScanRelevance.isLocationCurrent(ip("10.182.122.111"), checked: checked, networkStale: false), "autre plage : ancien")
        try expect(!ScanRelevance.isLocationCurrent(ip("192.168.1.20"), checked: checked, networkStale: true), "réseau changé : ancien")
    }
}
