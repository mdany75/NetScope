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
                        "Plages 10.0.1.0/24 et 10.0.2.0/24", "libellé de deux plages")
        let trois = [range("10.182.122.0/24"), range("192.168.50.0/24"), range("10.10.0.1-50")]
        try expectEqual(ScanRelevance.rangesLabel(trois), "3 plages", "au-delà de deux : le nombre")
        try expectEqual(ScanRelevance.rangesLabel([range("10.10.0.1-50")], names: [range("10.10.0.1-50"): "10.10.0.1-50"]),
                        "Plage 10.10.0.1-50", "texte saisi plutôt que la forme lue")
        try expectEqual(ScanRelevance.rangesList(trois, names: [range("10.10.0.1-50"): "10.10.0.1-50"]),
                        "10.182.122.0/24\u{00A0}; 192.168.50.0/24\u{00A0}; 10.10.0.1-50", "liste complète pour l'aide")
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
        // Le switch de gestion (hors des plages du bilan) reste même s'il n'a rien localisé ici.
        let part2 = bilan.relevant(to: [range("10.0.2.0/24")])
        try expectEqual(part2?.switchNames, ["SW-A", "SW-B", "SW-GESTION"], "SW-A y a localisé 10.0.2.20 ; gestion gardé")
        try expectEqual(part2?.failedNames, ["SW-C"], "échec de la plage cochée gardé")
        // Le libellé nomme la partie cochée, pas toute la plage du scan (compteurs cohérents).
        let large = SwitchAutoResult(ranges: [range("10.0.0.0/16")], network: bureau,
                                     queriedHosts: [ip("10.0.1.5"), ip("10.0.7.5")])
        let cochee = large.relevant(to: [range("10.0.1.0/24")])
        try expectEqual(cochee?.rangesLabel, "Plage 10.0.1.0/24", "partie cochée d'un /16")
        try expectEqual(cochee?.queried, 1, "compteur de la partie cochée")
        let chevauche = large.relevant(to: [range("10.0.255.200-10.1.0.20")])
        try expectEqual(chevauche?.rangesLabel, "Plage 10.0.255.200-10.0.255.254", "portion commune quand rien n'est inclus")
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

    suite.add("Pertinence : seuls les switchs de ce réseau sont relevés en fin de scan") {
        // Cause du constat : 10.182.122.124, découvert sur l'ancien réseau, était encore interrogé
        // pendant le scan de 192.168.1.0/24 ; son échec était signalé pour cette plage.
        let known = [ip("10.182.122.124"), ip("192.168.1.2"), ip("10.9.9.2"), ip("172.16.0.2"), ip("10.0.5.2")]
        let polled = SwitchAutoResult.hostsToPoll(known: known, manual: [ip("10.9.9.2")], discoveredNow: [ip("10.0.5.2")],
                                                  ranges: [range("192.168.1.0/24")], localSubnet: maison.subnet)
        try expectEqual(polled, [ip("192.168.1.2"), ip("10.9.9.2"), ip("10.0.5.2")],
                        "plage scannée, switch ajouté à la main (gestion routée), découvert à l'instant ; pas l'ancien réseau")
        let local = SwitchAutoResult.hostsToPoll(known: [ip("192.168.1.250")], manual: [], discoveredNow: [],
                                                 ranges: [range("192.168.1.1-100")], localSubnet: maison.subnet)
        try expectEqual(local, [ip("192.168.1.250")], "sous-réseau de l'interface")
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
        // Câble débranché puis rebranché (autre port) : même réseau, mais lien changé.
        var cable = capture
        cable.linkStamp = 1_000
        var moved = cable
        moved.linkStamp = 2_000
        try expect(cable.isStale(comparedTo: moved), "lien coupé depuis la capture : périmé")
        try expect(!cable.isStale(comparedTo: cable), "même lien : actuel")
        try expect(!capture.isStale(comparedTo: moved), "capture sans indicateur de lien : ignoré")
    }

    suite.add("Pertinence : emplacements relevés, actuels seulement sur leur réseau et confirmés") {
        var ledger = LocationLedger()
        let checked = [range("192.168.1.0/24")]
        // Site A (maison) : 192.168.1.20 localisé par la découverte.
        ledger.discoveryFinished(ranges: checked, located: [ip("192.168.1.20")], network: maison)
        try expectEqual(ledger.status(of: ip("192.168.1.20"), checked: checked, network: maison), .current, "même plage, même réseau")
        try expectEqual(ledger.status(of: ip("192.168.1.20"), checked: [], network: maison), .rangeUnchecked, "plage décochée")
        try expectEqual(ledger.status(of: ip("192.168.1.30"), checked: checked, network: maison), .unconfirmed, "jamais relevé")
        // Site B, même plage, autre passerelle : l'emplacement du site A n'est plus actuel.
        let siteB = NetworkContext(interface: "en0", subnet: maison.subnet, gateway: ip("192.168.1.254"))
        try expectEqual(ledger.status(of: ip("192.168.1.20"), checked: checked, network: siteB), .networkChanged, "autre site")
        // Bureau puis retour sur la plage du bureau sans rescan : ancien réseau.
        ledger.record([ip("10.182.122.111")], network: bureau)
        try expectEqual(ledger.status(of: ip("10.182.122.111"), checked: [range("10.182.122.0/24")], network: maison),
                        .networkChanged, "plage du bureau recochée à la maison")
        // Nouvelle découverte sur la plage : l'appareil non relocalisé (switch muet) perd sa confirmation,
        // celui d'une autre plage la garde.
        ledger.discoveryFinished(ranges: checked, located: [], network: maison)
        try expectEqual(ledger.status(of: ip("192.168.1.20"), checked: checked, network: maison), .unconfirmed, "non relocalisé")
        try expectEqual(ledger.status(of: ip("10.182.122.111"), checked: [range("10.182.122.0/24")], network: bureau),
                        .current, "autre plage non touchée")
        // VLAN : celui d'un emplacement suit l'emplacement ; sinon (VLAN de la plage) seulement la plage cochée.
        try expectEqual(ledger.vlanStatus(of: ip("192.168.1.20"), hasSwitchLocation: true, checked: checked, network: maison),
                        .unconfirmed, "VLAN relevé non confirmé")
        try expectEqual(ledger.vlanStatus(of: ip("192.168.1.20"), hasSwitchLocation: false, checked: checked, network: maison),
                        .current, "VLAN de la plage cochée")
        try expect(LocationStatus.current.explanation == nil && LocationStatus.rangeUnchecked.explanation != nil, "explications")
        ledger.clear()
        try expectEqual(ledger.status(of: ip("10.182.122.111"), checked: [range("10.182.122.0/24")], network: bureau),
                        .unconfirmed, "« Effacer »")
    }

    suite.add("Pertinence : relecture de l'interface active (choix gardé, passerelle relue)") {
        let mask = ip("255.255.255.0")
        let wifi = LocalInterface(name: "en0", address: ip("192.168.1.57"), netmask: mask, kind: .wifi, gateway: ip("192.168.1.1"))
        let cable = LocalInterface(name: "en7", address: ip("10.0.0.20"), netmask: mask, kind: .ethernet, gateway: ip("10.0.0.1"))
        let listed = [LocalInterface(name: "en0", address: ip("192.168.1.57"), netmask: mask),
                      LocalInterface(name: "en7", address: ip("10.0.0.33"), netmask: mask)]
        // en7 choisie dans Réglages, renouvellement DHCP : en7 gardée (pas en0, listée avant), type et passerelle gardés.
        guard case .keep(let kept) = InterfaceRefresh.decide(active: cable, preferred: "en7", listed: listed,
                                                             defaultGateway: ip("192.168.1.1")) else {
            throw TestFailure(message: "en7 attendue", file: #fileID, line: #line)
        }
        try expectEqual(kept.name, "en7", "interface choisie gardée")
        try expectEqual(kept.address, ip("10.0.0.33"), "nouvelle adresse")
        try expectEqual(kept.kind, .ethernet, "type gardé")
        try expectEqual(kept.gateway, ip("10.0.0.1"), "même sous-réseau : passerelle gardée (route par défaut ailleurs)")
        // Même adresse, autre passerelle (autre site sur la même plage) : vue.
        guard case .keep(let moved) = InterfaceRefresh.decide(active: wifi, preferred: nil, listed: listed,
                                                              defaultGateway: ip("192.168.1.254")) else {
            throw TestFailure(message: "en0 attendue", file: #fileID, line: #line)
        }
        try expectEqual(moved.gateway, ip("192.168.1.254"), "changement de passerelle à adresse égale")
        try expect(NetworkContext(wifi).isStale(comparedTo: NetworkContext(moved)), "bilan du site A périmé")
        // Interface disparue : il faut choisir ; le choix de l'utilisateur revient dès qu'elle reparaît.
        try expectEqual(InterfaceRefresh.decide(active: cable, preferred: nil, listed: [listed[0]], defaultGateway: nil), .choose,
                        "interface disparue")
        try expectEqual(InterfaceRefresh.decide(active: wifi, preferred: "en7", listed: listed, defaultGateway: nil), .choose,
                        "choix de l'utilisateur revenu")
        var kinds = listed
        kinds[0].kind = .wifi
        kinds[1].kind = .ethernet
        try expectEqual(InterfaceRefresh.pick(from: kinds, preferred: "en7", defaultGateway: ip("192.168.1.1"))?.name, "en7",
                        "choix de l'utilisateur")
        try expectEqual(InterfaceRefresh.pick(from: kinds, preferred: nil, defaultGateway: ip("192.168.1.1"))?.gateway,
                        ip("192.168.1.1"), "passerelle relue pour l'interface choisie")
    }
}
