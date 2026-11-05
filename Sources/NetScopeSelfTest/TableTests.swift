import Foundation
import NetScopeCore

// Notes 8, 19 et 20 : étiquettes « +N » des cellules, préréglages de ports, type choisi à la main.

func registerTableTests(_ suite: TestSuite) {
    suite.add("Cellule adaptative : étiquettes qui tiennent, puis « +N »") {
        let plus: (Int) -> Double = { _ in 20 }
        try expectEqual(TagOverflow.visibleCount(widths: [], available: 100, spacing: 3, overflowWidth: plus), 0, "liste vide")
        try expectEqual(TagOverflow.visibleCount(widths: [30, 30, 30], available: 96, spacing: 3, overflowWidth: plus), 3,
                        "tout tient pile : pas de « +N »")
        // 30 + 3 + 30 + 3 + 20 = 86 ≤ 90, mais trois étiquettes (96) dépassent.
        try expectEqual(TagOverflow.visibleCount(widths: [30, 30, 30, 30], available: 90, spacing: 3, overflowWidth: plus), 2,
                        "deux étiquettes et « +2 »")
        try expectEqual(TagOverflow.visibleCount(widths: [30, 30, 30, 30], available: 200, spacing: 3, overflowWidth: plus), 4,
                        "plus large : tout est affiché")
        try expectEqual(TagOverflow.visibleCount(widths: [80, 30], available: 60, spacing: 3, overflowWidth: plus), 0,
                        "trop étroit : « +2 » seul")
        // La largeur de « +N » dépend de N : « +10 » est plus large que « +9 ».
        let widths = Array(repeating: 10.0, count: 12)
        let wide: (Int) -> Double = { $0 >= 10 ? 30 : 20 }
        try expectEqual(TagOverflow.visibleCount(widths: widths, available: 46, spacing: 2, overflowWidth: wide), 1,
                        "« +11 » plus large")
    }

    suite.add("Préréglages de ports : mêmes que les profils de Réglages") {
        let presets = PortPreset.all(customPorts: [22, 80, 80, 8080])
        try expectEqual(presets.map(\.profile), ScanProfile.allCases, "un préréglage par profil, même ordre")
        try expectEqual(presets[0].label, "24 ports essentiels", "libellé du menu")
        try expectEqual(presets[0].shortLabel, "24 essentiels", "libellé de la barre d'outils")
        try expectEqual(presets[0].ports, ScanProfile.essentialPorts, "ports essentiels")
        let custom = presets.first { $0.profile == .personnalise }!
        try expectEqual(custom.ports, [22, 80, 8080], "personnalisé : ports des Réglages, sans doublon")
        try expectEqual(custom.label, "Personnalisé (3 ports)", "pluriel")
        try expectEqual(PortPreset(profile: .personnalise, customPorts: [443]).label, "Personnalisé (1 port)", "singulier")
        let complet = PortPreset(profile: .complet)
        try expect(complet.ports.count > 1000, "complet : plus de 1 000 ports")
        try expect(complet.label.contains("\u{202F}"), "milliers séparés par une espace fine insécable")
    }

    suite.add("Type choisi à la main : une seule source, par MAC, jamais écrasé par un scan") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let mac = MACAddress("94:DD:F8:15:73:7D")!
        let printer = Device(ip: IPv4Address("10.0.0.111")!, mac: mac, deviceType: .poste)
        var store = InventoryStore()
        try expectEqual(store.typeChoice(for: printer), DeviceTypeChoice(detected: .poste), "type détecté par défaut")
        // Fiche créée au besoin, type retenu par MAC.
        try expect(store.setManualType(.imprimante, for: printer, at: t0), "retenu")
        let key = InventoryStore.key(mac: mac)
        try expectEqual(store.record(key)?.annotations.customType, .imprimante, "même champ que l'Inventaire")
        try expectEqual(store.record(key)?.type, .imprimante, "fiche : type choisi")
        let choice = store.typeChoice(for: printer)
        try expect(choice.isManual && choice.type == .imprimante && choice.detected == .poste, "choix manuel")
        // Nouvelle adresse IP, même MAC : le choix suit l'appareil.
        var moved = printer
        moved.ip = IPv4Address("10.0.0.50")!
        try expectEqual(store.typeChoice(for: moved).type, .imprimante, "retenu par MAC, pas par IP")
        // Un scan qui détecte autre chose ne remplace pas le choix.
        var rescanned = printer
        rescanned.deviceType = .serveur
        store.merge([rescanned], at: t0.addingTimeInterval(60))
        try expectEqual(store.record(key)?.annotations.customType, .imprimante, "scan suivant : choix gardé")
        try expectEqual(store.record(key)?.detectedType, .serveur, "type détecté mis à jour")
        try expectEqual(store.applyingManualTypes(to: [rescanned]).first?.deviceType, .imprimante, "Carte et Rapports")
        // Revenir au type détecté.
        store.setManualType(nil, for: printer, at: t0.addingTimeInterval(120))
        try expectEqual(store.typeChoice(for: rescanned), DeviceTypeChoice(detected: .serveur), "retour au type détecté")
        // Appareil sans MAC : rien n'est retenu dans l'inventaire, seulement le choix de session.
        let routed = Device(ip: IPv4Address("10.20.0.5")!, deviceType: .inconnu)
        try expect(!store.setManualType(.camera, for: routed), "sans MAC : refusé")
        try expectEqual(store.typeChoice(for: routed).type, .inconnu, "rien de retenu")
        try expectEqual(store.typeChoice(for: routed, session: [routed.id: .camera]).type, .camera, "choix de session par IP")
        try expectEqual(store.typeChoice(for: printer, session: [printer.id: .camera]).type, .poste,
                        "avec MAC : la session ne compte pas")
        // Sans MAC mais rattaché à la fiche à MAC de même IP (comme à la fusion) : le choix est repris.
        store.setManualType(.imprimante, for: printer, at: t0.addingTimeInterval(180))
        let viaRouter = Device(ip: IPv4Address("10.0.0.111")!, deviceType: .poste)
        let routedChoice = store.typeChoice(for: viaRouter)
        try expect(routedChoice.isManual && routedChoice.type == .imprimante, "sans MAC : fiche à MAC de même IP")
        try expect(store.setManualType(nil, for: viaRouter, at: t0.addingTimeInterval(200)), "sans MAC : fiche existante modifiée")
        try expectEqual(store.record(key)?.annotations.customType, nil, "retour au type détecté sur la fiche à MAC")
        // Sans MAC, fiche par IP (annotée dans l'Inventaire) : « Revenir » efface vraiment le type.
        store.merge([routed], at: t0.addingTimeInterval(240))
        try expect(store.setManualType(.camera, for: routed, at: t0.addingTimeInterval(250)), "fiche ip: retenue")
        try expectEqual(store.record(InventoryStore.key(ip: routed.ip))?.annotations.customType, .camera, "fiche par IP")
        try expectEqual(store.typeChoice(for: routed).type, .camera, "type de la fiche par IP")
        store.setManualType(nil, for: routed, at: t0.addingTimeInterval(260))
        try expectEqual(store.typeChoice(for: routed), DeviceTypeChoice(detected: .inconnu), "revenir : type détecté rétabli")
        // Plusieurs appareils : type commun coché seulement s'ils l'ont tous.
        try expectEqual(DeviceTypeChoice.common([DeviceTypeChoice(detected: .poste), DeviceTypeChoice(detected: .serveur, manual: .poste)]),
                        .poste, "même type")
        try expectEqual(DeviceTypeChoice.common([DeviceTypeChoice(detected: .poste), DeviceTypeChoice(detected: .serveur)]),
                        nil, "types différents")
    }
}
