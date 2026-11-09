import Darwin
import Foundation
import NetScopeCore

// Note 118 : Navigateur Bonjour. Logique pure sur données fixes ; le furetage réel n'est jamais lancé ici.

private func txtRecord(_ items: [String]) -> Data {
    var data = Data()
    for item in items {
        let bytes = Array(item.utf8)
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

func registerBonjourTests(_ suite: TestSuite) {
    suite.add("Bonjour : TXT décodé (valeur, valeur vide, clé seule, valeur avec =)") {
        let txt = BonjourTXT.decode(txtRecord(["rp=ipp/print", "note=", "Duplex", "url=a=b"]))
        try expectEqual(txt, ["rp": "ipp/print", "note": "", "Duplex": "", "url": "a=b"], "quatre formes")
    }

    suite.add("Bonjour : TXT, première occurrence retenue sans casse, clé vide ignorée") {
        let txt = BonjourTXT.decode(txtRecord(["Ty=premier", "TY=second", "=sans-cle", ""]))
        try expectEqual(txt, ["Ty": "premier"], "doublon et entrées vides")
    }

    suite.add("Bonjour : TXT tronqué, on garde ce qui précède ; valeur binaire en hexadécimal") {
        var data = txtRecord(["ok=1"])
        data.append(contentsOf: [0x20, 0x61])
        try expectEqual(BonjourTXT.decode(data), ["ok": "1"], "longueur annoncée trop grande")
        let binary = Data([0x04, 0x62, 0x3D, 0xFF, 0xFE])
        try expectEqual(BonjourTXT.decode(binary), ["b": "0xfffe"], "UTF-8 invalide")
        try expectEqual(BonjourTXT.decode(Data([0x00])), [:], "TXT vide du système")
    }

    suite.add("Bonjour : adresses sockaddr réparties en IPv4 et IPv6, sans doublon") {
        let v4: [UInt8] = [16, UInt8(AF_INET), 0x02, 0x77, 10, 182, 122, 40] + [UInt8](repeating: 0, count: 8)
        var v6 = [UInt8](repeating: 0, count: 28)
        v6[0] = 28
        v6[1] = UInt8(AF_INET6)
        v6[8] = 0xFE
        v6[9] = 0x80
        v6[23] = 0x01
        let result = BonjourAddress.split([Data(v4), Data(v4), Data(v6), Data([1])])
        try expectEqual(result.ipv4, ["10.182.122.40"], "IPv4")
        try expectEqual(result.ipv6, ["fe80::1"], "IPv6")
    }

    suite.add("Bonjour : libellés français et type inconnu lisible") {
        try expectEqual(BonjourCatalog.label(for: "_ipp._tcp."), "Imprimante IPP", "avec point final")
        try expectEqual(BonjourCatalog.label(for: "_SMB._tcp.local."), "Partage SMB", "casse et domaine")
        try expectEqual(BonjourCatalog.label(for: "_foo._udp"), "Service foo (UDP)", "inconnu")
    }

    suite.add("Bonjour : réponse d’énumération convertie en type, déchets écartés") {
        try expectEqual(BonjourCatalog.typeFromEnumeration(name: "_http", type: "_tcp.local."), "_http._tcp", "TCP")
        try expectEqual(BonjourCatalog.typeFromEnumeration(name: "_hap", type: "_udp.local."), "_hap._udp", "UDP")
        try expectEqual(BonjourCatalog.typeFromEnumeration(name: "http", type: "_tcp.local."), nil, "sans souligné")
        try expectEqual(BonjourCatalog.typeFromEnumeration(name: "_http", type: "_foo.local."), nil, "protocole inconnu")
    }

    suite.add("Bonjour : tout le catalogue est déclaré dans Info.plist") {
        let url = URL(fileURLWithPath: "Resources/Info.plist")
        guard let data = try? Data(contentsOf: url) else { throw TestSkipped(reason: "Resources/Info.plist absent du dossier courant") }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let declared = Set(plist?["NSBonjourServices"] as? [String] ?? [])
        try expectEqual(Set(BonjourCatalog.types + [BonjourCatalog.enumerationType]).subtracting(declared).sorted(), [], "types manquants")
    }

    suite.add("Bonjour : regroupement par hôte, sans tenir compte de la casse ni du point final") {
        let services = [
            BonjourService(type: "_ipp._tcp", instance: "A", host: "Imprimante.local.", port: 631, ipv4: ["10.0.0.5"]),
            BonjourService(type: "_http._tcp", instance: "A", host: "imprimante.local", port: 80, ipv4: ["10.0.0.5"]),
            BonjourService(type: "_ssh._tcp", instance: "B", host: "nas.local.", port: 22, ipv4: ["10.0.0.9"]),
        ]
        let groups = BonjourGrouping.device.groups(services)
        try expectEqual(groups.map(\.services.count), [2, 1], "deux appareils")
        try expect(groups[0].title.lowercased() == "imprimante.local", "nom sans point final")
        try expectEqual(groups[0].subtitle, "10.0.0.5 · 2 services", "adresse et nombre")
    }

    suite.add("Bonjour : deux hôtes sur une même IP restent deux appareils") {
        let services = [
            BonjourService(type: "_hap._tcp", instance: "A", host: "pont-a.local.", ipv4: ["10.0.0.5"]),
            BonjourService(type: "_hap._tcp", instance: "B", host: "pont-b.local.", ipv4: ["10.0.0.5"]),
            BonjourService(type: "_http._tcp", instance: "C", ipv4: ["10.0.0.5"]),
        ]
        let groups = BonjourGrouping.device.groups(services)
        try expectEqual(groups.count, 3, "l’IP partagée ne fusionne rien")
        try expectEqual(groups.last?.title, "Non résolus", "sans hôte, aucun appareil déduit de l’IP")
        try expectEqual(groups.last?.services.map(\.instance), ["C"], "service sans hôte à part")
    }

    suite.add("Bonjour : un service sans hôte ne rejoint pas l’hôte de son IP ; les non résolus finissent la liste") {
        let services = [
            BonjourService(type: "_googlecast._tcp", instance: "Inconnu"),
            BonjourService(type: "_ipp._tcp", instance: "A", host: "zeta.local.", ipv4: ["10.0.0.5"]),
            BonjourService(type: "_http._tcp", instance: "B", ipv4: ["10.0.0.5"]),
        ]
        let groups = BonjourGrouping.device.groups(services)
        try expectEqual(groups.map(\.title), ["zeta.local", "Non résolus"], "ordre")
        try expectEqual(groups[0].services.map(\.instance), ["A"], "seul le service de cet hôte")
    }

    suite.add("Bonjour : regroupement par type, trié par libellé") {
        let services = [
            BonjourService(type: "_smb._tcp", instance: "A", host: "a.local."),
            BonjourService(type: "_ipp._tcp", instance: "B", host: "b.local."),
            BonjourService(type: "_smb._tcp", instance: "C", host: "c.local."),
        ]
        let groups = BonjourGrouping.type.groups(services)
        try expectEqual(groups.map(\.title), ["Imprimante IPP", "Partage SMB"], "alphabétique")
        try expectEqual(groups[1].subtitle, "_smb._tcp · 2 services", "type brut et nombre")
    }

    suite.add("Bonjour : filtre sur tous les champs, TXT compris, sans casse ni accents") {
        let services = [
            BonjourService(type: "_ipp._tcp", instance: "Accueil", host: "a.local.", port: 631, ipv4: ["10.0.0.5"], txt: ["note": "Étage 2"]),
            BonjourService(type: "_ssh._tcp", instance: "Serveur", host: "b.local.", port: 22, ipv4: ["10.0.0.9"]),
        ]
        try expectEqual(BonjourFilter.apply(services, query: "etage").map(\.instance), ["Accueil"], "valeur TXT")
        try expectEqual(BonjourFilter.apply(services, query: "IMPRIMANTE 631").map(\.instance), ["Accueil"], "libellé et port")
        try expectEqual(BonjourFilter.apply(services, query: "10.0.0.9").map(\.instance), ["Serveur"], "adresse")
        try expectEqual(BonjourFilter.apply(services, query: "  ").count, 2, "filtre vide")
        try expectEqual(BonjourFilter.apply(services, query: "absent").count, 0, "aucun")
    }

    suite.add("Bonjour : codes d’autorisation refusée reconnus") {
        try expect(BonjourAccess.isDenied(errorCode: -72008), "configuration manquante")
        try expect(BonjourAccess.isDenied(errorCode: -65570), "PolicyDenied")
        try expect(!BonjourAccess.isDenied(errorCode: -72007), "simple délai dépassé")
    }

    suite.add("Bonjour : rapport lisible d’un groupe") {
        let services = [BonjourService(type: "_ipp._tcp", instance: "Accueil", host: "a.local.", port: 631, ipv4: ["10.0.0.5"], txt: ["rp": "ipp/print"])]
        let report = BonjourFormat.report(BonjourGrouping.device.groups(services))
        try expectEqual(report, "a.local · 10.0.0.5 · 1 service\n  Imprimante IPP (_ipp._tcp) · Accueil · a.local:631 · 10.0.0.5 · rp=ipp/print", "texte")
    }
}
