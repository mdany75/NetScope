import Foundation
import NetScopeCore

/// Démonstration de la note 10 (Inventaire, phase 3), rejouée par le vrai moteur, sans réseau ni
/// fichier : un appareil ajouté à la main (en stock, jamais scanné), deux appareils archivés (ancien
/// NAS et poste remplacé), une garantie bientôt échue (imprimante d'accueil, 24 jours), une active et
/// une échue, une pièce jointe (contrat d'entretien), et la MAC de ce Mac vue aussi à Laval.
///
/// Captures : NETSCOPE_INV_VUE choisit ce que montre l'Inventaire :
/// - « archives » : la vue « Archivés » ;
/// - « manuel » : la fiche de l'appareil ajouté à la main ;
/// - « feuille » : la feuille « Ajouter un appareil » remplie ;
/// - « garanties » : le filtre « Garantie bientôt échue ».
@MainActor
enum InvManualDemo {
    static var view: String? {
        guard RegEnvironment.isSnapshot || Launcher.isDemo else { return nil }
        return ProcessInfo.processInfo.environment["NETSCOPE_INV_VUE"]?.lowercased()
    }

    /// La feuille d'ajout est dessinée remplie (captures).
    static var prefills: Bool { view == "feuille" }

    /// Contenu de la feuille remplie.
    static let draft = InvManualDraft(name: "Imprimante d’étiquettes quai 3", ip: IPv4Address("10.182.122.180"), vendor: "Zebra",
                                      type: .imprimante, location: "Rez-de-chaussée · Quai 3", wallJack: "P0-11",
                                      owner: "Expédition", notes: "Livrée le 4 novembre, à brancher sur SW-CORE-01.",
                                      tags: ["Stock", "Quai"])

    /// Nom de l'appareil ajouté à la main de la démonstration.
    static let manualName = "Imprimante d’étiquettes Zebra ZT411"

    /// Appareils du parc de démonstration qui seront archivés (ajoutés au premier scan, il y a 90 jours).
    static func retiredDevices(at date: Date) -> [Device] {
        [
            Device(ip: IPv4Address("10.182.122.150")!, mac: MACAddress("00:11:32:5A:0C:41"), vendor: "Synology",
                   hostname: "NAS-ANCIEN", isOnline: true, latencyMs: 1.6, openPorts: [80, 443, 445, 5000],
                   switchName: "SW-CORE-01", switchPort: "Gi1/0/33", vlan: 1, firstSeen: date, lastSeen: date,
                   rangeLabel: "Bureau", deviceType: .serveur),
            Device(ip: IPv4Address("10.182.122.159")!, mac: MACAddress("B0:7B:25:3E:10:F7"), vendor: "Dell",
                   hostname: "WKS201", isOnline: true, latencyMs: 2.2, openPorts: [135, 445],
                   switchName: "SW-ETG2-01", switchPort: "1/19", vlan: 1, firstSeen: date, lastSeen: date,
                   rangeLabel: "Bureau", deviceType: .poste),
        ]
    }

    /// Ajouts de la phase 3 à l'inventaire du Siège, une fois l'historique rejoué (InvDemo).
    static func seed(_ store: inout InventoryStore, now: Date) {
        func at(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        let calendar = Calendar.current

        // Deux appareils retirés du parc : archivés (restaurables, vue « Archivés »).
        for (ip, days, note) in [("10.182.122.150", 20.0, "Remplacé par le NAS de la salle B01. Disques effacés le \(InvFormat.day(at(20)))."),
                                 ("10.182.122.159", 9.0, "Poste remplacé par WKS346 (comptabilité).")] {
            guard let record = store.records.values.first(where: { $0.ip.description == ip }) else { continue }
            var notes = record.annotations
            notes.notes = note
            notes.tags = ip.hasSuffix(".150") ? ["Réseau"] : ["Poste"]
            store.setAnnotations(notes, for: record.key, at: at(days + 1), recordEvent: false)
            store.removeRecords([record.key], exclude: false, archive: true, at: at(days))
        }

        // Liste « Ne plus réajouter » (Réglages › Sites et plages › Inventaire du site) : le
        // téléphone d'un visiteur retiré avec exclusion, et la MAC d'un portable de prêt écrite à la main.
        let visitor = Device(ip: IPv4Address("10.182.122.171")!, mac: MACAddress("A4:C3:F0:5D:21:9B"), vendor: "Apple",
                             hostname: "iPhone-visiteur", isOnline: true, latencyMs: 8.4, openPorts: [],
                             vlan: 20, firstSeen: at(15), lastSeen: at(15), rangeLabel: "Bureau", deviceType: .telephone)
        store.addScanned([visitor], at: at(15))
        if let key = store.existingKey(for: visitor) {
            store.removeRecords([key], exclude: true, archive: false, at: at(14))
        }
        if let loaner = MACAddress("F8:FF:C2:4B:7A:10") {
            store.exclude(mac: loaner, name: "Portable de prêt (salle de formation)", at: at(6))
        }

        // Appareil ajouté à la main : en stock, jamais vu par un scan.
        let manual = InvManualDraft(name: manualName, vendor: "Zebra", type: .imprimante,
                                    location: "Sous-sol · Armoire TI", owner: "Service TI", assetNumber: "INV-00533",
                                    notes: "Neuve, en stock. Sera branchée au quai 3 (prise P0-11).", tags: ["Stock"])
        if let key = try? store.addManual(manual, at: at(3), id: UUID(uuidString: "0A11DE70-0010-4C1E-9A11-00000000B001")!) {
            var notes = store.record(key)!.annotations
            notes.hardware = InvHardware(purchaseDate: at(4), warrantyEnd: calendar.date(byAdding: .year, value: 2, to: at(4)),
                                         supplier: "Zebra Canada", serialNumber: "99J224600871", price: 2_189)
            store.setAnnotations(notes, for: key, at: at(3), recordEvent: false)
        }

        // Garanties : bientôt échue (imprimante d'accueil), active (switch cœur), échue (contrôleur de domaine).
        let warranties: [(String, Date, Date, String, String, Double?)] = [
            ("10.182.122.111", calendar.date(byAdding: .day, value: -1_071, to: now)!, calendar.date(byAdding: .day, value: 24, to: now)!,
             "Bureau en Gros Affaires", "E78123K4N", 349.99),
            ("10.182.122.2", at(640), calendar.date(byAdding: .year, value: 3, to: at(640))!, "CDW Canada", "FOC2419X0AB", 6_840),
            ("10.10.0.10", at(1_860), calendar.date(byAdding: .day, value: -35, to: now)!, "Dell Technologies", "7HQ2LM3", nil),
        ]
        for (ip, bought, end, supplier, serial, price) in warranties {
            guard let record = store.records.values.first(where: { $0.ip.description == ip && $0.hostname != "MacBook-Air-Accueil" }) else { continue }
            var notes = record.annotations
            notes.hardware = InvHardware(purchaseDate: bought, warrantyEnd: end, supplier: supplier, serialNumber: serial, price: price)
            store.setAnnotations(notes, for: record.key, at: at(85), recordEvent: false)
        }

        // Une pièce jointe : le contrat d'entretien de l'imprimante d'accueil (rien sur le disque).
        if let printer = store.records.values.first(where: { $0.ip.description == "10.182.122.111" && $0.hostname != "MacBook-Air-Accueil" }) {
            let folder = InvAttachmentFiles.folderName(for: printer, id: UUID(uuidString: "C0FFEE11-0010-4C1E-9A11-00000000B002")!)
            store.addAttachment(InvAttachment(id: UUID(uuidString: "C0FFEE11-0010-4C1E-9A11-00000000B003")!,
                                              fileName: "Contrat-entretien-Brother-2024.pdf", storedName: "Contrat-entretien-Brother-2024.pdf",
                                              size: 184_320, added: at(85)), folder: folder, to: printer.key)
        }
    }

    /// Laval : ce Mac y a été vu lors de la visite d'avant-hier (même MAC que dans l'inventaire du
    /// Siège : signalée sur les deux sites, jamais fusionnée).
    static func seedLaval(_ store: inout InventoryStore, now: Date) {
        let seen = now.addingTimeInterval(-2 * 86_400 - 3_600)
        let visit = Device(ip: IPv4Address("10.20.0.60")!, mac: MACAddress("3C:22:FB:7E:05:B1"), vendor: "Apple",
                           hostname: "Macmini-de-Dany", isOnline: false, latencyMs: nil, openPorts: [22, 5900],
                           vlan: 1, firstSeen: seen, lastSeen: seen, rangeLabel: "Bureaux", deviceType: .poste)
        store.addScanned([visit], at: seen)
        if let key = store.existingKey(for: visit), var notes = store.record(key)?.annotations {
            notes.customName = "Mac du technicien (visite)"
            store.setAnnotations(notes, for: key, at: seen, recordEvent: false)
        }
    }
}
