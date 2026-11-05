import Foundation
import NetScopeCore

/// Historique de démonstration (mode --demo) : quelques scans passés rejoués par le vrai moteur,
/// d'après les croquis Inventaire et Analyse. Aucun accès réseau.
@MainActor
enum InvDemo {
    static func seed(_ store: inout InventoryStore, devices: [Device], now: Date) {
        func at(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func extra(_ ip: String, _ mac: String, _ host: String, _ vendor: String, _ sw: String, _ port: String,
                   _ vlan: Int, _ type: DeviceType, name: String? = nil) -> Device {
            Device(ip: IPv4Address(ip)!, mac: MACAddress(mac), vendor: vendor, hostname: host, customName: name,
                   isOnline: true, latencyMs: 2.4, switchName: sw, switchPort: port, vlan: vlan,
                   rangeLabel: "Bureau", deviceType: type)
        }

        // Le parc, indexé par MAC : chaque étape modifie quelques appareils puis fusionne le tout.
        var fleet: [String: Device] = [:]
        var order: [String] = []
        func put(_ device: Device) {
            let key = device.mac?.formatted(.colon) ?? device.id
            if fleet[key] == nil { order.append(key) }
            fleet[key] = device
        }
        func change(_ ip: String, _ body: (inout Device) -> Void) {
            guard let key = fleet.first(where: { $0.value.ip.description == ip })?.key else { return }
            body(&fleet[key]!)
        }
        func scan(_ date: Date) {
            for key in order where fleet[key]?.isOnline == true { fleet[key]?.lastSeen = date }
            let list = order.compactMap { fleet[$0] }.map { device -> Device in
                var copy = device
                copy.firstSeen = min(copy.firstSeen, date)
                return copy
            }
            // Note 84 : clients Wi-Fi et bornes de la démonstration (itinérance sans alerte).
            store.merge(list, at: date, wireless: WirelessDemo.context(devices: list, now: now))
        }

        let lateNew: Set<String> = ["10.182.122.133", "10.182.122.140"]
        // Il y a 90 jours : premier scan (référence).
        for device in devices where !lateNew.contains(device.id) {
            var past = device
            past.firstSeen = at(90)
            past.lastSeen = at(90)
            past.isOnline = true
            past.latencyMs = past.latencyMs ?? 2.1
            if device.id == "10.182.122.111" {
                past.ip = IPv4Address("10.182.122.87")!
                past.switchName = "SW-CORE-01"
                past.switchPort = "Gi1/0/22"
                past.openPorts = [80, 443, 9100]
            }
            if device.id == "10.182.122.117" { past.switchPort = "Gi1/0/7" }
            put(past)
        }
        put(extra("10.182.122.158", "B0:7B:25:3E:11:02", "WKS298", "Dell", "SW-CORE-01", "Gi1/0/27", 1, .poste))
        put(extra("10.182.122.160", "3C:22:FB:7E:05:B2", "Macmini-de-Dany", "Apple", "SW-ETG2-01", "1/11", 1, .poste,
                  name: "Macmini-de-Dany (Ethernet)"))
        put(extra("10.182.122.171", "9C:93:4E:21:0A:5B", "XRX-9C934E21", "Xerox", "SW-CORE-01", "Gi1/0/30", 30, .imprimante,
                  name: "Imprimante locataire"))
        // Note 84 : deuxième borne et portables en Wi-Fi (le premier changera de borne).
        for device in WirelessDemo.devices(firstSeen: at(90)) where device.ip.description != WirelessDemo.roamingIP { put(device) }
        // Note 10 : deux appareils retirés du parc depuis (archivés à la fin, InvManualDemo).
        for retired in InvManualDemo.retiredDevices(at: at(90)) { put(retired) }
        scan(at(90))

        change("10.182.122.158") { $0.isOnline = false }
        change("10.182.122.150") { $0.isOnline = false }
        scan(at(81))
        change("10.182.122.87") { $0.ip = IPv4Address("10.182.122.111")! }
        change("10.182.122.159") { $0.isOnline = false }
        scan(at(60))
        change("10.182.122.171") { $0.isOnline = false }
        scan(at(36))
        change("10.182.122.160") { $0.isOnline = false }
        scan(at(32))
        change("10.182.122.111") { $0.switchName = "SW-ETG2-01"; $0.switchPort = "1/14" }
        scan(at(15))
        if let hp = devices.first(where: { $0.id == "10.182.122.140" }) {
            var past = hp
            past.firstSeen = at(5)
            put(past)
        }
        // Note 84 : portable en Wi-Fi derrière la borne AP-ETG2 depuis 5 jours.
        for device in WirelessDemo.devices(firstSeen: at(5)) where device.ip.description == WirelessDemo.roamingIP { put(device) }
        scan(at(5))
        // Hier : un scan de plus (sert de point de comparaison).
        scan(at(1))
        // Il y a 3 h : le poste de la réception ne répond plus.
        change("10.182.122.146") { $0.isOnline = false; $0.latencyMs = nil }
        scan(now.addingTimeInterval(-3 * 3600))
        // Note 84 : il vient de passer de la borne AP-ETG2 à la borne AP-ACCUEIL (itinérance, sans alerte).
        change(WirelessDemo.roamingIP) {
            $0.switchName = WirelessDemo.accueilPort.switchName
            $0.switchPort = WirelessDemo.accueilPort.port
            $0.lastSeen = now.addingTimeInterval(-6 * 60)
        }

        // Maintenant : l'état réel de la démonstration, plus une seconde MAC qui répond sur .140 (conflit IP).
        var current = devices.map { device -> Device in
            var copy = device
            if lateNew.contains(device.id) && device.id == "10.182.122.133" { copy.firstSeen = device.lastSeen }
            if device.id == "10.182.122.140" { copy.firstSeen = at(5) }
            return copy
        }
        for key in order {
            guard let device = fleet[key], !current.contains(where: { $0.mac == device.mac }) else { continue }
            current.append(device)
        }
        current.append(Device(ip: IPv4Address("10.182.122.140")!, mac: MACAddress("5C:F9:38:02:7A:41"), vendor: "Apple",
                              hostname: "MacBook-Air-Accueil", isOnline: true, latencyMs: 9.2, switchName: "SW-ETG2-01",
                              switchPort: "1/7", vlan: 30, firstSeen: now.addingTimeInterval(-600),
                              lastSeen: now.addingTimeInterval(-60), rangeLabel: "Bureau", deviceType: .poste))
        store.merge(current, at: now, wireless: WirelessDemo.context(devices: current, now: now))

        // Fiches renseignées par le technicien (croquis Inventaire).
        let notes: [(String, [String], String, String, String, String, String, Bool)] = [
            ("10.182.122.1", ["Réseau", "Critique"], "Sous-sol · Salle serveurs B01", "Baie A · U12", "Service TI", "INV-00101", "Passerelle et serveur DHCP officiel du site.", true),
            ("10.182.122.2", ["Réseau", "Critique"], "Sous-sol · Salle serveurs B01", "Baie A · U20", "Service TI", "INV-00102", "Catalyst 9300-48P, alimente les AP en PoE+.", true),
            ("10.182.122.3", ["Réseau"], "2e étage · Local télécom T2", "Baie 2 · U04", "Service TI", "INV-00103", "Aruba 2930F-24G, uplink vers SW-CORE-01.", false),
            ("10.182.122.102", ["Réseau"], "1er étage · Accueil · plafond", "P1-03", "Service TI", "INV-00231", "", false),
            ("10.182.122.106", ["Affichage"], "1er étage · Hall d’entrée", "P1-08", "", "", "", false),
            ("10.182.122.111", ["Imprimante", "Critique"], "2e étage · Salle 204", "P2-14", "Réception", "INV-00412", "Réservation DHCP sur FortiGate-60F. Firmware 1.07.", true),
            ("10.182.122.113", ["Poste"], "2e étage · Salle 211", "P2-21", "Marc", "INV-00377", "", false),
            ("10.182.122.117", ["Poste"], "1er étage · Comptabilité 108", "P1-17", "Comptabilité", "INV-00346", "", false),
            ("10.182.122.135", ["Poste"], "", "", "Dany Ménard", "", "Poste du technicien (NetScope).", true),
            ("10.182.122.146", ["Poste"], "1er étage · Réception", "P1-01", "Réception", "INV-00341", "", false),
            ("10.182.122.158", ["Poste"], "1er étage · Salle 115", "P1-29", "", "INV-00298", "", false),
            ("10.182.122.171", ["Imprimante", "Locataire"], "1er étage · Local 120", "P1-24", "Locataire", "", "", false),
            ("192.168.50.21", ["Sécurité", "Critique"], "Rez-de-chaussée · Quai de chargement", "P0-05", "Sécurité", "INV-00521", "", false),
            ("10.10.0.10", ["Réseau", "Critique"], "Sous-sol · Salle serveurs B01", "Baie B · U08", "Service TI", "INV-00150", "", false),
        ]
        for (ip, tags, location, jack, owner, asset, text, favorite) in notes {
            guard let record = store.records.values.first(where: { $0.ip.description == ip && $0.hostname != "MacBook-Air-Accueil" })
            else { continue }
            var annotations = record.annotations
            annotations.tags = tags
            annotations.location = location
            annotations.wallJack = jack
            annotations.owner = owner
            annotations.assetNumber = asset
            annotations.notes = text
            annotations.isFavorite = favorite
            store.setAnnotations(annotations, for: record.key, at: at(89), recordEvent: false)
        }
        // Note 10 : appareil ajouté à la main, archives, garanties, pièce jointe.
        InvManualDemo.seed(&store, now: now)
        // Note 60 : modèle, numéro de série et firmware lus par SNMP et par la FortiGate.
        HardwareDetectDemo.seed(&store, now: now)
        // Note 78 : MAC aléatoires à rapprocher (proposé, jamais fusionné d’office).
        InventoryRandomMACDemo.seed(&store, now: now)
        // Note 6 : ID RustDesk des postes de la réception et de la comptabilité.
        RustDeskDemo.seed(&store, now: now)
    }
}
