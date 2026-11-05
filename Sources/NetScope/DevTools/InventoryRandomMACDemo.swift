import Foundation
import NetScopeCore

/// Note 78 : MAC aléatoires de la démonstration (--demo). Deux appareils à « adresse privée »
/// ont laissé une fiche orpheline en changeant de MAC ; l'Inventaire propose de les rapprocher
/// (panneau « Doublons probables »), sans rien fusionner d'office :
/// - l'iPhone de Julie : même nom d'hôte, nouvelle MAC aléatoire depuis 9 jours ;
/// - le terminal Zebra du quai : nom d'hôte Android aléatoire, même numéro de série saisi.
///
/// Captures : NETSCOPE_INV_VUE=doublons ouvre le panneau des doublons probables.
@MainActor
enum InventoryRandomMACDemo {
    static func seed(_ store: inout InventoryStore, now: Date) {
        func at(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func device(_ ip: String, _ mac: String, _ host: String, online: Bool, seen: Date, first: Date, type: DeviceType) -> Device {
            Device(ip: IPv4Address(ip)!, mac: MACAddress(mac), hostname: host, isOnline: online, latencyMs: online ? 14.2 : nil,
                   switchName: "FortiAP-231F", switchPort: "Wi-Fi", vlan: 30, firstSeen: first, lastSeen: seen,
                   rangeLabel: "Bureau", deviceType: type)
        }
        // Anciennes fiches : vues il y a 40 jours, plus vues depuis 9 jours.
        let oldPhone = device("10.182.122.162", "6A:1F:C7:02:9B:E4", "iPhone-de-Julie", online: true, seen: at(9), first: at(40), type: .telephone)
        let oldScanner = device("10.182.122.164", "DA:7C:10:4E:21:9B", "TC52-QUAI2", online: true, seen: at(12), first: at(60), type: .iot)
        store.merge([oldPhone, oldScanner], at: at(9.5), snapshot: false)
        var gone = [oldPhone, oldScanner]
        for index in gone.indices { gone[index].isOnline = false; gone[index].latencyMs = nil }
        store.merge(gone, at: at(9), snapshot: false)
        // Nouvelles MAC aléatoires, en ligne maintenant.
        let newPhone = device("10.182.122.175", "D2:4E:81:7A:33:C0", "iPhone-de-Julie", online: true, seen: now.addingTimeInterval(-120),
                              first: at(8.8), type: .telephone)
        let newScanner = device("10.182.122.178", "AE:52:09:6B:D4:17", "android-7f3a9c21d0e4", online: true, seen: now.addingTimeInterval(-300),
                                first: at(11), type: .iot)
        store.merge([newPhone, newScanner], at: now.addingTimeInterval(-60), snapshot: false)
        // Numéro de série saisi sur les deux fiches du terminal (étiquette au dos de l'appareil).
        for mac in ["DA:7C:10:4E:21:9B", "AE:52:09:6B:D4:17"] {
            guard let wanted = MACAddress(mac), let record = store.records.values.first(where: { $0.mac == wanted }) else { continue }
            var notes = record.annotations
            notes.hardware = InvHardware(supplier: "Zebra Technologies", serialNumber: "21245B2D0057")
            if mac.hasPrefix("DA") { notes.customName = "Terminal Zebra du quai" }
            store.setAnnotations(notes, for: record.key, at: at(20), recordEvent: false)
        }
    }
}
