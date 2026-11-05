import Foundation
import NetScopeCore

// Note 78 (0.26.0) : export CSV de l'inventaire pour NetBox, GLPI et Snipe-IT, et rapprochement
// des MAC aléatoires (proposé, jamais automatique). Données fixes, aucun réseau.

func registerInventoryExportTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    func printer() -> InvRecord {
        var record = InvRecord(key: "mac:94:dd:f8:18:15:7d", mac: MACAddress("94:DD:F8:18:15:7D"), ip: IPv4Address("10.182.122.111")!,
                               hostname: "BRN94DDF818157D", vendor: "Brother", detectedType: .imprimante,
                               switchName: "SW-ETG2-01", switchPort: "1/14", vlan: 20, firstSeen: now.addingTimeInterval(-90 * day),
                               lastSeen: now)
        var notes = InvAnnotations(customName: "Imprimante accueil", tags: ["Imprimante", "Critique"], location: "2e étage, salle 204",
                                   wallJack: "P2-14", owner: "Réception", assetNumber: "INV-00412", notes: "Réservation DHCP")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        notes.hardware = InvHardware(purchaseDate: calendar.date(from: DateComponents(year: 2025, month: 3, day: 10, hour: 12)),
                                     warrantyEnd: calendar.date(from: DateComponents(year: 2028, month: 3, day: 9, hour: 12)),
                                     supplier: "CDW Canada", serialNumber: "E78123K4N", price: 449.99)
        record.annotations = notes
        return record
    }

    suite.add("Inventaire : export NetBox (colonnes de l'import des appareils)") {
        let csv = InvExternalCSV.export([printer()], format: .netbox, sites: ["Siège"], now: now)
        let table = InvCSV.table(csv)
        try expectEqual(table.first ?? [], ["name", "status", "role", "manufacturer", "device_type", "site", "location", "serial",
                                            "asset_tag", "description", "comments"], "en-têtes NetBox")
        try expect(csv.hasPrefix("name,status,"), "séparateur virgule")
        let row = table[1]
        try expectEqual(row[0], "Imprimante accueil", "nom")
        try expectEqual(row[1], "active", "statut NetBox")
        try expectEqual(row[2], "Imprimante", "rôle")
        try expectEqual(row[3], "Brother", "fabricant")
        try expectEqual(row[5], "Siège", "site")
        try expectEqual(row[6], "2e étage, salle 204", "emplacement (virgule protégée par des guillemets)")
        try expectEqual(row[7], "E78123K4N", "numéro de série saisi")
        try expectEqual(row[8], "INV-00412", "n° d'actif")
        try expect(row[9].contains("IP 10.182.122.111") && row[9].contains("MAC 94:DD:F8:18:15:7D") && row[9].contains("VLAN 20"),
                   "description réseau")
        try expect(row[10].contains("Étiquettes\u{00A0}: Imprimante, Critique"), "étiquettes dans les commentaires")
    }

    suite.add("Inventaire : export GLPI (Data injection) et Snipe-IT (actifs)") {
        let glpi = InvCSV.table(InvExternalCSV.export([printer()], format: .glpi, sites: ["Siège"], now: now))
        try expectEqual(glpi[0][0], "Nom", "GLPI : libellés français")
        try expect(glpi[0].contains("Numéro de série") && glpi[0].contains("Numéro d'inventaire") && glpi[0].contains("Adresse MAC"),
                   "GLPI : colonnes attendues")
        let g = Dictionary(uniqueKeysWithValues: zip(glpi[0], glpi[1]))
        try expectEqual(g["Statut"], "En service", "GLPI : statut")
        try expectEqual(g["Lieu"], "Siège > 2e étage, salle 204", "GLPI : lieu hiérarchique")
        try expectEqual(g["Date d'achat"], "2025-03-10", "GLPI : date ISO")
        try expectEqual(g["Durée de garantie"], "36", "GLPI : garantie en mois")
        try expectEqual(g["Usager"], "Réception", "GLPI : usager")

        let snipe = InvCSV.table(InvExternalCSV.export([printer()], format: .snipeIT, sites: ["Siège"], now: now))
        try expectEqual(snipe[0], ["Item Name", "Asset Tag", "Category", "Manufacturer", "Model Name", "Serial Number", "Status",
                                   "Location", "Purchase Date", "Purchase Cost", "Supplier", "Warranty", "MAC Address", "Notes"],
                        "Snipe-IT : en-têtes de l'importateur")
        let s = Dictionary(uniqueKeysWithValues: zip(snipe[0], snipe[1]))
        try expectEqual(s["Asset Tag"], "INV-00412", "Snipe-IT : étiquette d'actif")
        try expectEqual(s["Status"], "Ready to Deploy", "Snipe-IT : statut par défaut")
        try expectEqual(s["Purchase Cost"], "449.99", "Snipe-IT : prix à point décimal")
        try expectEqual(s["Model Name"], "Imprimante", "Snipe-IT : modèle inconnu remplacé par le type")
    }

    suite.add("Inventaire : export externe sans données (étiquette d'actif, fabricant, formules)") {
        let random = InvRecord(key: "mac:6a:1f:c7:02:9b:e4", mac: MACAddress("6A:1F:C7:02:9B:E4"), ip: IPv4Address("10.0.0.9")!,
                               hostname: "=HYPERLINK(\"x\")", isOnline: false, firstSeen: now.addingTimeInterval(-60 * day), lastSeen: now.addingTimeInterval(-45 * day),
                               offlineSince: now.addingTimeInterval(-45 * day))
        let s = InvCSV.table(InvExternalCSV.export([random], format: .snipeIT, now: now))
        let row = Dictionary(uniqueKeysWithValues: zip(s[0], s[1]))
        try expectEqual(row["Asset Tag"], "NS-6A1FC7029BE4", "étiquette tirée de la MAC")
        try expectEqual(row["Manufacturer"], "", "MAC aléatoire : pas de fabricant inventé")
        try expectEqual(row["Status"], "Archived", "disparu : archivé")
        try expect(row["Item Name"]?.hasPrefix("'=") == true, "nom pris pour une formule : protégé")
        let netbox = InvCSV.table(InvExternalCSV.export([random], format: .netbox, now: now))
        try expectEqual(netbox[1][1], "offline", "NetBox : hors ligne")
        try expectEqual(InvExportFormat.netbox.fileSuffix, "-netbox", "suffixe du fichier")
        try expectEqual(InvExternalCSV.export([random], format: .netscope, now: now), InvCSV.export([random], now: now),
                        "format NetScope inchangé")
    }

    suite.add("Inventaire : nom d'hôte et numéro de série normalisés (MAC aléatoires)") {
        try expectEqual(InvRandomMAC.normalizedHostname("iPhone-de-Julie.local"), "iphone-de-julie", "domaine retiré")
        try expectEqual(InvRandomMAC.normalizedHostname("Pixel-7 (2)"), "pixel-7", "suffixe de doublon retiré")
        try expectEqual(InvRandomMAC.normalizedHostname("WKS346-2"), "wks346", "suffixe -2 retiré")
        try expect(InvRandomMAC.normalizedHostname("iPhone") == nil, "nom générique")
        try expect(InvRandomMAC.normalizedHostname("10.0.0.5") == nil, "adresse IP")
        try expect(InvRandomMAC.normalizedHostname("ab") == nil, "trop court")
        var record = InvRecord(key: "k", mac: nil, ip: IPv4Address("10.0.0.1")!, firstSeen: now, lastSeen: now)
        record.annotations.hardware = InvHardware(serialNumber: " c02-xk 7 ")
        try expectEqual(InvRandomMAC.serial(of: record), "C02XK7", "numéro saisi normalisé")
        record.annotations.hardware = InvHardware(serialNumber: "To be filled by O.E.M.")
        try expect(InvRandomMAC.serial(of: record) == nil, "numéro bidon du BIOS ignoré")
    }

    suite.add("Inventaire : MAC aléatoires rapprochées par nom d'hôte ou numéro de série, sans fusion") {
        var store = InventoryStore()
        func device(_ ip: String, _ mac: String, _ host: String, online: Bool) -> Device {
            Device(ip: IPv4Address(ip)!, mac: MACAddress(mac), hostname: host, isOnline: online, firstSeen: now, lastSeen: now)
        }
        store.merge([device("10.0.0.20", "6A:1F:C7:02:9B:E4", "iPhone-de-Julie.local", online: true),
                     device("10.0.0.21", "DA:7C:10:4E:21:9B", "TC52-QUAI2", online: true),
                     device("10.0.0.30", "3C:22:FB:7E:05:B1", "Macmini-Dany", online: true)], at: now.addingTimeInterval(-9 * day), snapshot: false)
        var offline = [device("10.0.0.20", "6A:1F:C7:02:9B:E4", "iPhone-de-Julie.local", online: false),
                       device("10.0.0.21", "DA:7C:10:4E:21:9B", "TC52-QUAI2", online: false)]
        offline[0].latencyMs = nil
        store.merge(offline, at: now.addingTimeInterval(-8 * day), snapshot: false)
        store.merge([device("10.0.0.40", "D2:4E:81:7A:33:C0", "iPhone-de-Julie", online: true),
                     device("10.0.0.41", "AE:52:09:6B:D4:17", "android-7f3a9c21", online: true),
                     // Même nom que le Mac, MAC universelle d'un autre fabricant et en ligne en même temps : jamais proposé.
                     device("10.0.0.31", "00:50:56:AA:10:31", "Macmini-Dany", online: true)], at: now, snapshot: false)
        let count = store.records.count
        for mac in ["DA:7C:10:4E:21:9B", "AE:52:09:6B:D4:17"] {
            let record = try required78(store.records.values.first { $0.mac == MACAddress(mac) }, "fiche \(mac)")
            var notes = record.annotations
            notes.hardware = InvHardware(serialNumber: "21245B2D0057")
            store.setAnnotations(notes, for: record.key, at: now, recordEvent: false)
        }
        let matches = InvRandomMAC.matches(in: Array(store.records.values))
        try expectEqual(matches.count, 2, "deux rapprochements proposés")
        let byHost = try required78(matches.first { $0.randomMAC == .hostname }, "par nom d'hôte")
        try expectEqual(store.record(byHost.keep)?.ip.description, "10.0.0.40", "la fiche la plus récente est gardée")
        try expectEqual(store.record(byHost.absorb)?.ip.description, "10.0.0.20", "l'ancienne est à rattacher")
        try expect(byHost.reason.contains("MAC aléatoire"), "raison expliquée")
        let bySerial = try required78(matches.first { $0.randomMAC == .serial }, "par numéro de série")
        try expect(bySerial.reason.contains("21245B2D0057"), "numéro cité")

        let proposed = store.probableDuplicates()
        try expect(proposed.contains { $0.randomMAC == .serial }, "proposé dans les doublons probables")
        try expect(proposed.contains { $0.randomMAC == .hostname }, "doublon par nom d'hôte marqué « MAC aléatoire »")
        try expect(!proposed.contains { [$0.keep, $0.absorb].contains { store.record($0)?.hostname == "Macmini-Dany" } },
                   "deux appareils en ligne ensemble ne sont jamais proposés")
        try expectEqual(store.records.count, count, "rien n'est fusionné d'office")
        store.absorb(bySerial.absorb, into: bySerial.keep, at: now)
        try expectEqual(store.records.count, count - 1, "fusion seulement à la demande")
    }
}
