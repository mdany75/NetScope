import Foundation
import NetScopeCore

// Note 84 (0.27.1) : appareils Wi-Fi et repères Wi-Fi / filaire / DHCP. Classement Wi-Fi ou
// filaire, itinérance d'une borne à l'autre sans alerte, alerte gardée pour un appareil filaire,
// compteur des alertes à traiter, sonde « Port de switch », carte d'occupation et sa légende.
// Données fixes, aucun réseau.

func registerWirelessRoamingTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_800_000)
    func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }
    func mac(_ text: String) -> MACAddress { MACAddress(text)! }

    let laptopMAC = mac("8C:16:45:36:24:3C")
    let desktopMAC = mac("B0:7B:25:44:A1:6C")
    // Deux bornes FortiAP branchées sur deux switchs, un client Wi-Fi lu sur la FortiGate.
    let aps = [FortiManagedAP(name: "AP-ACCUEIL", serial: "FP231FTF22004101", ip: ip("10.0.0.102")),
               FortiManagedAP(name: "AP-ETG2", serial: "FP231FTF22004187", ip: ip("10.0.0.104"))]
    // Noms d'hôte des bornes (sans lecture Wi-Fi, la borne est nommée par sa fiche).
    let apDevices = [Device(ip: ip("10.0.0.102"), mac: mac("70:4C:A5:1E:22:9A"), hostname: "AP-ACCUEIL", switchName: "SW-CORE", switchPort: "Gi1/0/12",
                            deviceType: .pointAcces),
                     Device(ip: ip("10.0.0.104"), mac: mac("70:4C:A5:1E:31:04"), hostname: "AP-ETG2", switchName: "SW-ETG2", switchPort: "1/20",
                            deviceType: .pointAcces)]
    func overview(clientAP: String?) -> FortiWifiOverview {
        FortiWifiOverview(aps: aps, clients: clientAP.map {
            [FortiWifiClient(mac: laptopMAC, ip: ip("10.0.0.153"), hostname: "PF4L03M23", ssid: "Groupe-Interne", apName: $0, band: .ghz5)]
        } ?? [])
    }

    suite.add("Wi-Fi ou filaire : client de la FortiGate, port de borne, port « Wi-Fi », borne elle-même") {
        let context = InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: apDevices)
        try expectEqual(context.accessPointPorts["SW-CORE · Gi1/0/12"], "AP-ACCUEIL", "port de la borne d'après son adresse")
        try expectEqual(context.accessPointPorts["SW-ETG2 · 1/20"], "AP-ETG2", "deuxième borne")

        let client = InvWireless.classify(type: .poste, mac: laptopMAC, ip: ip("10.0.0.153"), from: "SW-ETG2 · 1/20",
                                          to: "SW-CORE · Gi1/0/12", remembered: nil, context: context, now: now)
        try expect(client.isWireless && client.reason == .fortiGateClient, "client vu par la FortiGate : Wi-Fi")
        try expectEqual(client.apBefore, "AP-ETG2", "borne de départ d'après le port")
        try expectEqual(client.apAfter, "AP-ACCUEIL", "borne d'arrivée d'après la FortiGate")
        try expectEqual(client.ssid, "Groupe-Interne", "SSID")

        // Sans lecture Wi-Fi : le port de la borne suffit.
        let portOnly = InvWirelessContext(overview: nil, devices: apDevices)
        let byPort = InvWireless.classify(type: .poste, mac: laptopMAC, ip: ip("10.0.0.153"), from: "SW-ETG2 · 1/20",
                                          to: "SW-CORE · Gi1/0/12", remembered: nil, context: portOnly, now: now)
        try expect(byPort.isWireless && byPort.reason == .accessPointPort("AP-ACCUEIL"), "port qui mène à une borne : Wi-Fi")
        try expect(byPort.apBefore == "AP-ETG2" && byPort.apAfter == "AP-ACCUEIL", "bornes d'après les ports")

        let wifiPort = InvWireless.classify(type: .inconnu, mac: nil, ip: ip("10.0.0.40"), from: "AP-ETG2 · Wi-Fi",
                                            to: "AP-ACCUEIL · Wi-Fi", remembered: nil, context: .none, now: now)
        try expect(wifiPort.isWireless && wifiPort.reason == .wifiPort, "port « Wi-Fi » : rattaché à sa borne")
        try expect(wifiPort.apBefore == "AP-ETG2" && wifiPort.apAfter == "AP-ACCUEIL", "bornes du port « Wi-Fi »")

        // La borne elle-même qui change de port : un vrai déplacement de câble.
        let ap = InvWireless.classify(type: .pointAcces, mac: mac("70:4C:A5:1E:22:9A"), ip: ip("10.0.0.102"), from: "SW-CORE · Gi1/0/12",
                                      to: "SW-CORE · Gi1/0/13", remembered: nil, context: context, now: now)
        try expect(!ap.isWireless, "une borne qui change de port reste filaire")

        // Poste filaire sans aucun indice Wi-Fi.
        let wired = InvWireless.classify(type: .poste, mac: desktopMAC, ip: ip("10.0.0.117"), from: "SW-CORE · Gi1/0/7",
                                         to: "SW-CORE · Gi1/0/22", remembered: nil, context: context, now: now)
        try expect(wired == .wired, "poste filaire : filaire")
    }

    suite.add("Wi-Fi ou filaire : ce Mac, mémoire de la fiche, téléphone, MAC privée, voisin LLDP") {
        let context = InvWirelessContext(localWifiIPs: [ip("10.0.0.135")])
        let thisMac = InvWireless.classify(type: .poste, mac: mac("3C:22:FB:7E:05:B1"), ip: ip("10.0.0.135"), from: "A · 1", to: "B · 2",
                                           remembered: nil, context: context, now: now)
        try expectEqual(thisMac.reason, .thisMac, "interface Wi-Fi de ce Mac")
        let recent = InvWirelessLink(apName: "AP-ETG2", ssid: "Groupe-Interne", seen: now.addingTimeInterval(-2 * 86_400))
        let remembered = InvWireless.classify(type: .poste, mac: desktopMAC, ip: ip("10.0.0.60"), from: "A · 1", to: "B · 2",
                                              remembered: recent, context: .none, now: now)
        try expect(remembered.isWireless && remembered.reason == .remembered && remembered.apBefore == "AP-ETG2",
                   "déjà vu en Wi-Fi il y a 2 jours")
        let old = InvWirelessLink(apName: "AP-ETG2", seen: now.addingTimeInterval(-40 * 86_400))
        try expect(!InvWireless.classify(type: .poste, mac: desktopMAC, ip: ip("10.0.0.60"), from: "A · 1", to: "B · 2",
                                         remembered: old, context: .none, now: now).isWireless, "vu en Wi-Fi il y a 40 jours : oublié")
        try expectEqual(InvWireless.classify(type: .telephone, mac: desktopMAC, ip: ip("10.0.0.61"), from: "A · 1", to: "B · 2",
                                             remembered: nil, context: .none, now: now).reason, .mobilePhone, "téléphone mobile")
        try expectEqual(InvWireless.classify(type: .poste, mac: mac("F2:6A:19:C4:0E:57"), ip: ip("10.0.0.62"), from: "A · 1", to: "B · 2",
                                             remembered: nil, context: .none, now: now).reason, .privateMAC, "adresse MAC privée")
        try expect(!InvWireless.classify(type: .telephoneIP, mac: mac("80:5E:C0:3A:61:21"), ip: ip("10.0.0.63"), from: "A · 1",
                                         to: "B · 2", remembered: nil, context: .none, now: now).isWireless, "téléphone IP : filaire")

        // Voisin LLDP « point d'accès » sur un port de switch relevé.
        let snapshot = SNMPSwitchSnapshot(host: ip("10.0.0.3"), system: SNMPSystemInfo(name: "SW-ETG2", descr: "Aruba"),
                                          interfaces: [SNMPInterface(index: 20, name: "1/20"), SNMPInterface(index: 21, name: "1/21"),
                                                       SNMPInterface(index: 24, name: "1/24")],
                                          neighbors: [SNMPLLDPNeighbor(localPortNum: 20, ifIndex: 20, sysName: "AP-ETG2", portID: "eth0",
                                                                       capabilities: [.bridge, .accessPoint]),
                                                      SNMPLLDPNeighbor(localPortNum: 21, ifIndex: 21, sysName: "FP231FTF22009999", portID: "lan1",
                                                                       sysDescr: "FortiAP-231F v7.2.8"),
                                                      SNMPLLDPNeighbor(localPortNum: 24, ifIndex: 24, sysName: "SW-CORE", portID: "Gi1/0/47",
                                                                       capabilities: [.bridge, .router])])
        let ports = InvWirelessContext.accessPointPorts(in: [snapshot])
        try expectEqual(ports["SW-ETG2 · 1/20"], "AP-ETG2", "capacité point d'accès")
        try expectEqual(ports["SW-ETG2 · 1/21"], "FP231FTF22009999", "description FortiAP")
        try expect(ports["SW-ETG2 · 1/24"] == nil, "switch voisin : pas une borne")
    }

    suite.add("Fusion d'un scan : itinérance Wi-Fi sans alerte, changement de port filaire en alerte") {
        var store = InventoryStore()
        let laptop = Device(ip: ip("10.0.0.153"), mac: laptopMAC, hostname: "PF4L03M23", switchName: "SW-ETG2", switchPort: "1/20",
                            deviceType: .poste)
        let desktop = Device(ip: ip("10.0.0.117"), mac: desktopMAC, hostname: "WKS346", switchName: "SW-CORE", switchPort: "Gi1/0/7",
                             deviceType: .poste)
        store.merge(apDevices + [laptop, desktop], at: now.addingTimeInterval(-86_400),
                    wireless: InvWirelessContext(overview: overview(clientAP: "AP-ETG2"), devices: apDevices + [laptop]))
        let key = InventoryStore.key(mac: laptopMAC)
        try expectEqual(store.record(key)?.wireless?.apName, "AP-ETG2", "association Wi-Fi retenue par la fiche")

        var moved = laptop
        moved.switchName = "SW-CORE"
        moved.switchPort = "Gi1/0/12"
        var movedDesktop = desktop
        movedDesktop.switchPort = "Gi1/0/22"
        let devices = apDevices + [moved, movedDesktop]
        let produced = store.merge(devices, at: now, wireless: InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: devices))
        let roam = produced.first { $0.key == key }
        try expectEqual(roam?.kind, .itineranceWifi, "itinérance, pas un changement de port")
        try expectEqual(roam?.severity, .info, "sans gravité")
        try expect(roam?.isAlert == false, "absente des alertes")
        try expectEqual(roam?.title, "Itinérance Wi-Fi\u{00A0}: PF4L03M23 passé de la borne AP-ETG2 à la borne AP-ACCUEIL", "titre")
        try expectEqual(store.record(key)?.switchLocation, "SW-CORE · Gi1/0/12", "emplacement mis à jour")
        try expectEqual(store.record(key)?.portHistory.count, 2, "historique des ports gardé")
        let wired = produced.first { $0.key == InventoryStore.key(mac: desktopMAC) }
        try expect(wired?.kind == .changementPort && wired?.severity == .alerte && wired?.isAlert == true, "poste filaire : alerte gardée")

        // Retour sur AP-ETG2 vingt minutes plus tard : un seul événement, de la première borne.
        var back = moved
        back.switchName = "SW-ETG2"
        back.switchPort = "1/20"
        let later = apDevices + [back, movedDesktop]
        store.merge(later, at: now.addingTimeInterval(1200), wireless: InvWirelessContext(overview: overview(clientAP: "AP-ETG2"), devices: later))
        let roams = store.events(for: key).filter { $0.kind == .itineranceWifi }
        try expectEqual(roams.count, 1, "itinérances rapprochées regroupées")
        try expectEqual(roams.first?.title, "Itinérance Wi-Fi\u{00A0}: PF4L03M23 revenu sur la borne AP-ETG2", "aller-retour")

        // Deux heures plus tard : une nouvelle itinérance, un nouvel événement.
        let far = apDevices + [moved, movedDesktop]
        store.merge(far, at: now.addingTimeInterval(3 * 3600),
                    wireless: InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: far))
        try expectEqual(store.events(for: key).filter { $0.kind == .itineranceWifi }.count, 2, "itinérance éloignée : deux événements")
    }

    suite.add("Alertes à traiter : anciens déplacements d'appareils Wi-Fi exclus, filaires comptés") {
        let date = now.addingTimeInterval(-3600)
        var wifiRecord = InvRecord(key: "mac:8c:16:45:36:24:3c", mac: laptopMAC, ip: ip("10.0.0.153"), detectedType: .poste,
                                   firstSeen: date, lastSeen: date)
        wifiRecord.wireless = InvWirelessLink(apName: "AP-ACCUEIL", seen: date)
        let wiredRecord = InvRecord(key: "mac:b0:7b:25:44:a1:6c", mac: desktopMAC, ip: ip("10.0.0.117"), detectedType: .poste,
                                    firstSeen: date, lastSeen: date)
        func move(_ record: InvRecord) -> InvEvent {
            InvEvent(date: date, kind: .changementPort, severity: .alerte, key: record.key, ip: record.ip,
                     title: "Changement de port", detail: "")
        }
        try expect(!InvWireless.isPending(move(wifiRecord), record: wifiRecord), "ancienne alerte d'un appareil Wi-Fi : hors compteur")
        try expect(InvWireless.isPending(move(wiredRecord), record: wiredRecord), "poste filaire : compté")
        var phone = wiredRecord
        phone.detectedType = .telephone
        try expect(!InvWireless.isWirelessMove(move(phone), record: phone), "téléphone mobile sans preuve du Wi-Fi : compté")
        var ap = wifiRecord
        ap.detectedType = .pointAcces
        try expect(!InvWireless.isWirelessMove(move(ap), record: ap), "borne déplacée : comptée")
        let scoped = SiteScopedEvent(siteKey: "s", siteName: "Siège", event: move(wifiRecord), record: wifiRecord)
        try expect(scoped.isWirelessMove && !scoped.isPending, "événement d'un site")
        // Alerte vieille de 60 jours, fiche vue en Wi-Fi hier : le déplacement date d'avant le Wi-Fi.
        var oldMove = move(wifiRecord)
        oldMove.date = now.addingTimeInterval(-60 * 86_400)
        var seenYesterday = wifiRecord
        seenYesterday.wireless = InvWirelessLink(apName: "AP-ACCUEIL", seen: now.addingTimeInterval(-86_400))
        try expect(InvWireless.isPending(oldMove, record: seenYesterday), "alerte de 60 jours, Wi-Fi d'hier : à traiter")
        // Changement de port émis depuis la 0.27.1 (déjà classé filaire) : jamais masqué.
        var checked = move(wifiRecord)
        checked.mediumChecked = true
        try expect(InvWireless.isPending(checked, record: wifiRecord), "changement de port classé à l'émission : à traiter")

        // Un ancien fichier (sans association Wi-Fi) se relit ; l'association est enregistrée.
        let data = try JSONEncoder().encode(wifiRecord)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(object["wireless"] != nil, "association Wi-Fi enregistrée")
        object["wireless"] = nil
        let legacy = try JSONDecoder().decode(InvRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(legacy.wireless == nil && legacy.key == wifiRecord.key, "fiche d'avant la 0.27.1")
        let event = InvEvent(date: date, kind: .itineranceWifi, severity: .info, key: "k", ip: ip("10.0.0.1"), title: "t", detail: "")
        let decoded = try JSONDecoder().decode(InvEvent.self, from: JSONEncoder().encode(event))
        try expectEqual(decoded.kind, .itineranceWifi, "type d'événement enregistré")
        try expectEqual(InvEventKind.itineranceWifi.label, "Itinérance Wi-Fi", "libellé de la chronologie")
    }

    suite.add("Wi-Fi ou filaire : borne sans type, ancien port de borne, mémoire contredite, MAC privée, titres") {
        // FortiAP sans nom d'hôte (type inconnu), reconnue par son adresse lue sur la FortiGate.
        let unnamedAP = Device(ip: ip("10.0.0.102"), mac: mac("70:4C:A5:1E:22:9A"), switchName: "SW-CORE", switchPort: "Gi1/0/12")
        let context = InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: [unnamedAP])
        try expect(context.isAccessPoint(ip: ip("10.0.0.102"), mac: nil), "adresse de la borne")
        let moved = InvWireless.classify(type: .inconnu, mac: unnamedAP.mac, ip: unnamedAP.ip, from: "SW-CORE · Gi1/0/12",
                                         to: "SW-CORE · Gi1/0/13", remembered: nil, context: context, now: now)
        try expect(!moved.isWireless, "borne sans type qui change de port : filaire")

        var store = InventoryStore()
        store.merge([unnamedAP], at: now.addingTimeInterval(-86_400), wireless: context)
        var replugged = unnamedAP
        replugged.switchPort = "Gi1/0/13"
        let produced = store.merge([replugged], at: now,
                                   wireless: InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: [replugged]))
        let event = produced.first { $0.key == InventoryStore.key(mac: unnamedAP.mac!) }
        try expect(event?.kind == .changementPort && event?.severity == .alerte, "borne déplacée : alerte gardée")
        try expect(event.map { InvWireless.isPending($0, record: store.record($0.key)) } == true, "comptée à traiter")

        // Poste filaire déplacé depuis le port qu'occupe aujourd'hui une borne : pas une itinérance.
        let portOnly = InvWirelessContext(overview: nil, devices: apDevices)
        try expect(!InvWireless.classify(type: .poste, mac: desktopMAC, ip: ip("10.0.0.117"), from: "SW-CORE · Gi1/0/12",
                                         to: "SW-CORE · Gi1/0/30", remembered: nil, context: portOnly, now: now).isWireless,
                   "ancien port de borne seul : filaire")

        // Fiche vue en Wi-Fi il y a 2 jours, mais absente des clients de la FortiGate lue : filaire.
        let recent = InvWirelessLink(apName: "AP-ETG2", seen: now.addingTimeInterval(-2 * 86_400))
        try expect(!InvWireless.classify(type: .poste, mac: desktopMAC, ip: ip("10.0.0.60"), from: "A · 1", to: "B · 2",
                                         remembered: recent, context: context, now: now).isWireless,
                   "mémoire contredite par la FortiGate")

        // MAC administrée localement, port filaire changé, sans borne ni client : l'alerte reste.
        let privateMAC = mac("F2:6A:19:C4:0E:57")
        let verdict = InvWireless.classify(type: .poste, mac: privateMAC, ip: ip("10.0.0.62"), from: "A · 1", to: "B · 2",
                                           remembered: nil, context: .none, now: now)
        try expect(verdict.isWireless && !verdict.isProvenWireless, "MAC privée : supposée Wi-Fi, pas prouvée")
        var wiredStore = InventoryStore()
        let vm = Device(ip: ip("10.0.0.62"), mac: privateMAC, hostname: "VM-LINUX", switchName: "SW-CORE", switchPort: "Gi1/0/5",
                        deviceType: .poste)
        wiredStore.merge([vm], at: now.addingTimeInterval(-86_400))
        var vmMoved = vm
        vmMoved.switchPort = "Gi1/0/6"
        let vmEvent = wiredStore.merge([vmMoved], at: now).first { $0.key == InventoryStore.key(mac: privateMAC) }
        try expect(vmEvent?.kind == .changementPort && vmEvent?.severity == .alerte, "MAC privée déplacée : alerte")
        try expect(vmEvent?.detail.contains("probablement Wi-Fi (adresse MAC privée)") == true, "mention de l'indice")
        try expect(wiredStore.record(InventoryStore.key(mac: privateMAC))?.wireless == nil, "aucune association Wi-Fi créée")

        // Déduction (port d'une borne) : l'association n'est ni créée ni rafraîchie.
        var deduced = InventoryStore()
        let laptop = Device(ip: ip("10.0.0.153"), mac: laptopMAC, switchName: "SW-ETG2", switchPort: "1/20", deviceType: .poste)
        deduced.merge(apDevices + [laptop], at: now.addingTimeInterval(-86_400), wireless: portOnly)
        var roamed = laptop
        roamed.switchName = "SW-CORE"
        roamed.switchPort = "Gi1/0/12"
        let roam = deduced.merge(apDevices + [roamed], at: now, wireless: portOnly).first { $0.key == InventoryStore.key(mac: laptopMAC) }
        try expectEqual(roam?.kind, .itineranceWifi, "port d'une borne : itinérance")
        try expect(deduced.record(InventoryStore.key(mac: laptopMAC))?.wireless == nil, "déduction : pas d'association créée")

        try expectEqual(InvWireless.roamingTitle(name: "PF4L03M23", from: nil, to: nil, apBefore: nil, apAfter: nil),
                        "Itinérance Wi-Fi\u{00A0}: PF4L03M23 vu derrière emplacement inconnu", "emplacements inconnus")
        try expectEqual(InvWireless.roamingTitle(name: "PF4L03M23", from: "A · 1", to: "B · 2", apBefore: nil, apAfter: nil),
                        "Itinérance Wi-Fi\u{00A0}: PF4L03M23 vu derrière B 2 (avant\u{00A0}: A 1)", "emplacements connus")
    }

    suite.add("Sonde « Port de switch » : itinérance Wi-Fi sans alerte, port filaire changé en alerte") {
        let laptop = Device(ip: ip("10.0.0.153"), mac: laptopMAC, switchName: "SW-CORE", switchPort: "Gi1/0/12", deviceType: .poste)
        let desktop = Device(ip: ip("10.0.0.117"), mac: desktopMAC, switchName: "SW-CORE", switchPort: "Gi1/0/22", deviceType: .poste)
        let devices = apDevices + [laptop, desktop]
        let context = InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: devices)
        let roaming = MonInventoryChecks.switchPort(mac: laptopMAC.description, expected: "SW-ETG2 · 1/20", devices: devices,
                                                    wireless: context, now: now)
        try expect(roaming.result.problem == nil, "client Wi-Fi : pas d'alerte")
        try expectEqual(roaming.result.value, "Wi-Fi · borne AP-ACCUEIL", "valeur : la borne")
        let wired = MonInventoryChecks.switchPort(mac: desktopMAC.description, expected: "SW-CORE · Gi1/0/7", devices: devices,
                                                  wireless: context, now: now)
        try expect(wired.result.problem != nil, "poste filaire déplacé : alerte")
        try expectEqual(NetScopeEventKind.forProbe(.switchPort, severity: .warning), .deviceMoved, "alerte « appareil déplacé »")
        // MAC privée seule : l'alerte reste.
        let privateDevice = Device(ip: ip("10.0.0.62"), mac: mac("F2:6A:19:C4:0E:57"), switchName: "SW-CORE", switchPort: "Gi1/0/6",
                                   deviceType: .poste)
        let privateCheck = MonInventoryChecks.switchPort(mac: "F2:6A:19:C4:0E:57", expected: "SW-CORE · Gi1/0/5",
                                                         devices: devices + [privateDevice], wireless: context, now: now)
        try expect(privateCheck.result.problem != nil, "MAC privée déplacée : alerte")
        // Type « borne » choisi à la main sur la fiche : un appareil vu derrière le port d'une borne reste en alerte.
        var record = InvRecord(key: InventoryStore.key(mac: laptopMAC), mac: laptopMAC, ip: ip("10.0.0.153"), detectedType: .poste,
                               firstSeen: now, lastSeen: now)
        record.annotations.customType = .pointAcces
        let manual = InvWirelessContext(overview: nil, devices: devices, records: [record])
        try expectEqual(manual.manualTypes[laptopMAC], .pointAcces, "type de la fiche retenu")
        let asAP = MonInventoryChecks.switchPort(mac: laptopMAC.description, expected: "SW-ETG2 · 1/20", devices: devices,
                                                 wireless: manual, now: now)
        try expect(asAP.result.problem != nil, "type choisi à la main : alerte")
    }

    suite.add("Carte d'occupation : filaire, Wi-Fi, bail DHCP, réservation, adresse fixe et légende") {
        func range(_ a: String, _ b: String) -> DHCPAddressRange { DHCPAddressRange(start: ip(a), end: ip(b)) }
        let report = DHCPScopeReadReport(
            servers: [DHCPServerConfig(id: 1, interface: "internal", ranges: [range("10.0.0.100", "10.0.0.199")],
                                       reservations: [DHCPReservation(ip: ip("10.0.0.111"), mac: mac("94:DD:F8:18:15:7D"), action: "reserved")],
                                       gateway: ip("10.0.0.1"), netmask: ip("255.255.255.0"))],
            leases: [DHCPLeaseEntry(ip: ip("10.0.0.153"), mac: laptopMAC, serverID: 1),
                     DHCPLeaseEntry(ip: ip("10.0.0.117"), mac: desktopMAC, serverID: 1),
                     DHCPLeaseEntry(ip: ip("10.0.0.170"), mac: mac("B0:7B:25:00:00:01"), serverID: 1)])
        let dhcp = AddressPlanDHCP(reports: [report], now: now)
        func record(_ address: String, _ m: MACAddress?, type: DeviceType = .poste, sw: String? = nil, port: String? = nil) -> InvRecord {
            InvRecord(key: m.map { InventoryStore.key(mac: $0) } ?? "ip:" + address, mac: m, ip: ip(address), detectedType: type,
                      switchName: sw, switchPort: port, firstSeen: now, lastSeen: now)
        }
        let records = [record("10.0.0.102", mac("70:4C:A5:1E:22:9A"), type: .pointAcces, sw: "SW-CORE", port: "Gi1/0/12"),
                       record("10.0.0.153", laptopMAC, sw: "SW-CORE", port: "Gi1/0/12"),
                       record("10.0.0.117", desktopMAC, sw: "SW-CORE", port: "Gi1/0/22"),
                       record("10.0.0.111", mac("94:DD:F8:18:15:7D"), type: .imprimante, sw: "SW-ETG2", port: "1/14"),
                       record("10.0.0.20", mac("00:1B:C5:0A:12:F3"), type: .iot, sw: "SW-ETG2", port: "1/2")]
        let context = InvWirelessContext(overview: overview(clientAP: "AP-ACCUEIL"), devices: [], records: records)
        let plan = AddressPlan(block: try Subnet(parsing: "10.0.0.0/24"), records: records, dhcp: dhcp, now: now, wireless: context)

        let laptop = plan.cell(ip("10.0.0.153"))
        try expectEqual(laptop.state, .enLigneWifi, "client Wi-Fi : couleur Wi-Fi")
        try expect(laptop.medium?.apAfter == "AP-ACCUEIL" && laptop.medium?.ssid == "Groupe-Interne", "borne et SSID")
        try expect(laptop.assignment == .dhcp && laptop.marker == .dhcp, "bail DHCP de la même MAC : repère DHCP")
        let desktop = plan.cell(ip("10.0.0.117"))
        try expect(desktop.state == .enLigne && desktop.medium?.isWireless == false, "poste filaire")
        try expectEqual(desktop.marker, .dhcp, "poste filaire en DHCP")
        try expectEqual(plan.cell(ip("10.0.0.111")).marker, .reservee, "réservation : repère réservation")
        let fixed = plan.cell(ip("10.0.0.20"))
        try expect(fixed.assignment == .fixe && fixed.marker == nil, "ni bail ni réservation : fixe, sans repère")
        try expect(plan.cell(ip("10.0.0.102")).state == .enLigne, "la borne elle-même est filaire")
        let lease = plan.cell(ip("10.0.0.170"))
        try expect(lease.state == .bail && lease.assignment == .dhcp && lease.marker == nil, "bail sans appareil : couleur du bail, pas de repère")
        try expect(plan.cell(ip("10.0.0.50")).assignment == nil, "adresse libre : rien à dire")
        // Sans lecture DHCP : attribution inconnue.
        let unread = AddressPlan(block: try Subnet(parsing: "10.0.0.0/24"), records: records, now: now, wireless: context)
        try expect(unread.cell(ip("10.0.0.20")).assignment == nil, "aucune étendue lue : attribution inconnue")
        // Hors de toute étendue lue, bail d'une autre MAC, conflit.
        let extra = records + [record("10.0.1.20", mac("00:1B:C5:0A:12:F4"), type: .iot),
                               record("10.0.0.170", mac("00:1B:C5:0A:12:F5")),
                               record("10.0.0.153", mac("00:1B:C5:0A:12:F6"))]
        let wide = AddressPlan(block: try Subnet(parsing: "10.0.0.0/23"), records: extra, dhcp: dhcp, now: now, wireless: context)
        try expect(wide.cell(ip("10.0.1.20")).assignment == nil, "sous-réseau sans étendue lue : pas « fixe »")
        try expect(wide.cell(ip("10.0.0.170")).assignment == nil, "bail d'une autre MAC : attribution incertaine")
        let conflict = wide.cell(ip("10.0.0.153"))
        try expect(conflict.state == .conflit && conflict.marker == nil, "case en conflit : sans repère")

        let page = plan.pages[0]
        try expectEqual(page.count(.enLigneWifi), 1, "une adresse Wi-Fi")
        try expectEqual(page.count(.enLigne), 4, "quatre filaires")
        let legend = AddressPlanLegend.items(page: page, cells: plan.cells(page: page.base), dhcpRead: true)
        let labels = legend.map(\.label)
        try expectEqual(Array(labels.prefix(2)), ["Filaire", "Wi-Fi"], "filaire puis Wi-Fi en tête")
        try expect(labels.contains("Libre") && labels.contains("Bail DHCP") && labels.contains("Réservée"),
                   "états présents (bail sans appareil, passerelle réservée)")
        try expect(!labels.contains("Hors ligne") && !labels.contains("Conflit"), "états absents de la page : pas dans la légende")
        try expectEqual(legend.first { $0.kind == .marker(.dhcp) }?.count, 2, "deux repères DHCP")
        try expectEqual(legend.first { $0.kind == .marker(.reservee) }?.count, 1, "un repère réservation")
        try expectEqual(legend.first { $0.kind == .state(.enLigneWifi) }?.help, "En ligne · Wi-Fi", "infobulle de la légende")
        // Page sans Wi-Fi ni DHCP : filaire et Wi-Fi restent dans la légende, sans repère.
        let empty = AddressPlan(block: try Subnet(parsing: "10.9.9.0/24"), records: [], now: now)
        let emptyLegend = AddressPlanLegend.items(page: empty.pages[0], cells: empty.cells(page: empty.pages[0].base), dhcpRead: false)
        try expectEqual(emptyLegend.map(\.label), ["Filaire", "Wi-Fi", "Libre", "Réseau"], "légende minimale")
    }
}
