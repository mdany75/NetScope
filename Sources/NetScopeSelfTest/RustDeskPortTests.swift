import Foundation
import NetScopeCore

// Note 6 : ports RustDesk dans les ports ouverts. Données fixes, aucun trafic réseau.

func registerRustDeskPortTests(_ suite: TestSuite) {
    suite.add("RustDesk : noms des ports TCP 21115 à 21119 et UDP 21116") {
        try expectEqual(PortScanner.serviceName(21115), "rustdesk-nat", "21115 : test NAT")
        try expectEqual(PortScanner.serviceName(21116), "rustdesk-id", "21116 : ID")
        try expectEqual(PortScanner.serviceName(21117), "rustdesk-relais", "21117 : relais")
        try expectEqual(PortScanner.serviceName(21118), "rustdesk-direct", "21118 : accès direct / WebSocket")
        try expectEqual(PortScanner.serviceName(21119), "rustdesk-ws", "21119 : WebSocket du relais")
        for port in RustDeskPorts.tcpPorts {
            try expectEqual(PortScanner.serviceName(port), RustDeskPorts.info(port)?.service, "catalogue identique pour \(port)")
            try expectEqual(PortScanResult(port: port, state: .open).service, RustDeskPorts.info(port)?.service, "colonne Service \(port)")
        }
        try expectEqual(PortScanner.udpServiceName(21116), "rustdesk-hb", "21116/udp nommé")
        try expectEqual(PortScanner.udpServiceName(53), "dns", "UDP ordinaire : nom TCP")
        try expectEqual(RustDeskPorts.info(21116)?.component, "hbbs", "21116 sur hbbs")
        try expectEqual(RustDeskPorts.info(21117)?.component, "hbbr", "21117 sur hbbr")
        try expect(RustDeskPorts.info(21120) == nil, "21120 n’est pas RustDesk")
        try expectEqual(RustDeskPorts.buttonLabel(21117), "RustDesk 21117", "libellé du bouton")
        try expect(RustDeskPorts.help(port: 21116, role: .server(confirmed: true)).contains("UDP 21116"),
                   "l’infobulle de 21116 signale l’UDP non vérifié")
        try expect(RustDeskPorts.help(port: 21118, role: .client).contains("accès IP direct"), "infobulle du client")
    }

    suite.add("RustDesk : reconnaissance du serveur, du relais et du client à accès IP direct") {
        try expectEqual(RustDeskPorts.role(openPorts: [22, 21115, 21116, 21117]), .server(confirmed: true), "21115 à 21117 : serveur")
        try expectEqual(RustDeskPorts.role(openPorts: [21116, 21117]), .server(confirmed: true), "21116 et 21117 : serveur")
        try expectEqual(RustDeskPorts.role(openPorts: [21116, 21118]), .server(confirmed: false), "scan rapide (21116, 21118) : serveur à confirmer")
        try expectEqual(RustDeskPorts.role(openPorts: [21117, 21119]), .relay, "relais seul")
        try expectEqual(RustDeskPorts.role(openPorts: [135, 445, 21118]), .client, "21118 seul : client")
        try expect(RustDeskPorts.role(openPorts: [21118, 21119]) == nil, "21118 avec 21119 : ni client ni serveur")
        try expect(RustDeskPorts.role(openPorts: [22, 80, 443]) == nil, "aucun port RustDesk")
        try expect(RustDeskPorts.Role.client.isServer == false && RustDeskPorts.Role.relay.isServer, "isServer")
        try expectEqual(RustDeskPorts.Role.server(confirmed: true).label, "Serveur RustDesk", "libellé serveur")
        try expectEqual(RustDeskPorts.Role.client.label, "Client RustDesk (accès IP direct)", "libellé client")

        // Type détecté : serveur pour hbbs, poste pour l'accès direct ; RDP reste prioritaire pour un poste.
        let guess = { (ports: [UInt16]) in ScanDeviceClassifier.guess(ports: ports, vendor: nil, hostname: "srv-assistance", mac: nil) }
        try expectEqual(guess([22, 21115, 21116, 21117]), .serveur, "serveur RustDesk : type Serveur")
        try expectEqual(guess([21118]), .poste, "21118 seul : poste")
        try expectEqual(guess([135, 445, 21118]), .poste, "poste Windows avec accès direct")
        try expectEqual(guess([9100, 21118]), .imprimante, "les autres indices passent avant 21118")
    }

    suite.add("RustDesk : ports vérifiés à chaque scan et préréglage Accès distant") {
        try expect(ScanProfile.essentialPorts.contains(21116) && ScanProfile.essentialPorts.contains(21118), "21116 et 21118 essentiels")
        try expect(!ScanProfile.essentialPorts.contains(21117), "21117 n’est pas sondé à chaque scan")
        try expectEqual(ScanProfile.essentialPorts.count, Set(ScanProfile.essentialPorts).count, "sans doublon")
        try expect(Set(RustDeskPorts.tcpPorts).isSubset(of: Set(ScanProfile.extendedPorts)), "profil complet : 21115 à 21119")
        try expect(Set(RustDeskPorts.quickScanPorts).isSubset(of: Set(ScanProfile.commonPorts)), "ports courants : 21116 et 21118")
        let preset = PortPreset.remoteAccess
        try expectEqual(preset.ports, [22, 23, 3389, 5900, 21115, 21116, 21117, 21118, 21119], "ports du préréglage")
        try expectEqual(preset.label, "Accès distant et RustDesk (9 ports)", "libellé du menu")
        try expect(preset.id != PortPreset(profile: .personnalise).id, "identifiant distinct du profil Personnalisé")
        try expect(PortPreset.thematic.contains(preset), "proposé dans « Scanner les ports › … »")
        try expectEqual(ScanProfile.parsePorts("22, 23, 3389, 5900, 21115-21119"), preset.ports, "même liste que la Boîte à outils")
    }

    suite.add("RustDesk : migration douce des ports du profil Personnalisé") {
        let old = "21,22,23,25,53,80,135,139,443,445,554,631,3389,5900,8080,8443,9100"
        try expectEqual(ScanProfile.migratedCustomPorts(old), ScanProfile.defaultCustomPortsText, "ancienne valeur par défaut : mise à jour")
        try expectEqual(ScanProfile.migratedCustomPorts(" 21, 22,23,25,53,80,135,139,443,445,554,631,3389,5900,8080,8443,9100 "),
                        ScanProfile.defaultCustomPortsText, "espaces ignorés")
        try expectEqual(ScanProfile.migratedCustomPorts("22, 80, 8000-8010"), "22, 80, 8000-8010", "liste personnalisée gardée")
        try expectEqual(ScanProfile.migratedCustomPorts(old + ",161"), old + ",161", "ancienne liste modifiée : gardée")
        let migrated = ScanProfile.migratedCustomPorts(ScanProfile.defaultCustomPortsText)
        try expectEqual(migrated, ScanProfile.defaultCustomPortsText, "idempotent")
        let ports = ScanProfile.parsePorts(ScanProfile.defaultCustomPortsText) ?? []
        try expect(ports.contains(21116) && ports.contains(21118), "nouvelle valeur : 21116 et 21118")
    }

    suite.add("RustDesk : URL de l’accès IP direct") {
        try expectEqual(RustDeskPorts.directURL(host: "10.182.122.126")?.absoluteString,
                        "rustdesk://connection/new/10.182.122.126", "port 21118 implicite")
        try expectEqual(RustDeskPorts.directURL(host: " 10.0.0.5 ", port: 21200)?.absoluteString,
                        "rustdesk://connection/new/10.0.0.5:21200", "autre port")
        try expectEqual(RustDeskPorts.directURL(host: "poste-12.bureau.local")?.absoluteString,
                        "rustdesk://connection/new/poste-12.bureau.local", "nom d’hôte")
        try expect(RustDeskPorts.directURL(host: "") == nil, "vide refusé")
        try expect(RustDeskPorts.directURL(host: "10.0.0.5/../x?password=1") == nil, "caractères refusés")
    }

    suite.add("RustDesk : bilan du test du serveur (résultats fixes)") {
        func report(_ open: [UInt16]) -> RustDeskPorts.ServerReport {
            RustDeskPorts.ServerReport(results: RustDeskPorts.serverTestPorts.map {
                PortScanResult(port: $0, state: open.contains($0) ? .open : .closed, rttMs: 1)
            })
        }
        let ok = report([21115, 21116, 21117, 21118])
        try expectEqual(ok.verdict, .ok, "ID et relais")
        try expectEqual(ok.title, "Serveur RustDesk joignable", "titre")
        try expect(ok.message.contains("UDP 21116 n’est pas vérifié"), "UDP signalé")
        try expect(!ok.message.contains("21115"), "test NAT présent : rien à signaler")
        try expect(report([21116, 21117]).message.contains("21115"), "test NAT absent signalé")
        try expectEqual(report([21115, 21116]).verdict, .noRelay, "relais absent")
        try expectEqual(report([21117]).verdict, .relayOnly, "relais seul")
        try expectEqual(report([]).verdict, .unreachable, "rien")
        let partial = RustDeskPorts.ServerReport(results: [PortScanResult(port: 21116, state: .open)])
        try expectEqual(partial.lines.map(\.port), RustDeskPorts.serverTestPorts, "toujours cinq lignes")
        try expectEqual(partial.lines.first { $0.port == 21117 }?.state, .filtered, "port sans réponse : filtré")
        try expect(partial.lines.first { $0.port == 21119 }?.isOptional == true, "21119 facultatif")
    }

    suite.add("RustDesk : rapport et recherche (accès distant, pas port inconnu)") {
        try expectEqual(ReportBuilder.risk(port: 21118, type: .poste)?.service, "RustDesk, accès IP direct", "21118 d’un poste")
        try expect(ReportBuilder.risk(port: 21116, type: .serveur) == nil, "ports du serveur attendus")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func device(_ ip: String, _ ports: [UInt16], _ type: DeviceType) -> Device {
            Device(ip: IPv4Address(ip)!, mac: nil, vendor: nil, hostname: nil, customName: nil, isOnline: true,
                   latencyMs: 1, openPorts: ports, switchName: nil, switchPort: nil, vlan: nil,
                   firstSeen: now, lastSeen: now, rangeLabel: nil, deviceType: type)
        }
        let server = device("10.10.0.20", [22, 21115, 21116, 21117, 21118], .serveur)
        let client = device("10.182.122.126", [135, 445, 21118], .poste)
        let risky = ReportBuilder.riskyPorts([server, client])
        try expect(!risky.contains { $0.ip == server.ip && $0.port == 21118 }, "21118 du serveur : WebSocket, pas un risque")
        try expect(risky.contains { $0.ip == client.ip && $0.port == 21118 }, "21118 du poste : accès direct signalé")
        try expect(server.searchFreeText.contains("Serveur RustDesk"), "« rustdesk » trouve le serveur")
        try expect(client.searchFreeText.contains("Client RustDesk (accès IP direct)"), "« rustdesk » trouve le poste")
    }
}
