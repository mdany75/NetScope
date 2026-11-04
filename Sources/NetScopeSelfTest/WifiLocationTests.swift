import Foundation
import NetScopeCore

// Tests de l'autorisation de localisation (Wi-Fi) : correspondance état → bouton et message.
// Aucun appel à CoreLocation ni au réseau.

func registerWifiLocationTests(_ suite: TestSuite) {
    suite.add("Wi-Fi : localisation, action selon l'état") {
        let expected: [WifiLocationStatus: WifiLocationAction] = [
            .servicesDisabled: .openSettings, .notDetermined: .request, .denied: .openSettings,
            .restricted: .openSettings, .authorized: .refresh,
        ]
        for status in WifiLocationStatus.allCases {
            try expectEqual(WifiLocationGuidance.make(status: status).action, expected[status], "action pour \(status)")
        }
        try expectEqual(WifiLocationGuidance.make(status: .notDetermined).buttonTitle, "Autoriser la localisation", "libellé de la demande")
        try expectEqual(WifiLocationGuidance.make(status: .denied).buttonTitle, "Ouvrir les réglages de localisation", "libellé des réglages")
        try expectEqual(WifiLocationGuidance.make(status: .authorized).buttonTitle, "Actualiser les noms", "libellé autorisé")
        try expect(WifiLocationGuidance.make(status: .denied).isWarning, "refus signalé")
        try expect(!WifiLocationGuidance.make(status: .notDetermined).isWarning, "demande neutre")
        let authorized = WifiLocationGuidance.make(status: .authorized)
        try expect(authorized.message.contains("ne fournit pas encore les noms"), "autorisé mais noms absents")
        try expect(!authorized.isWarning, "autorisé : message neutre")
    }

    suite.add("Wi-Fi : localisation, demande en attente puis sans fenêtre") {
        let pending = WifiLocationGuidance.make(status: .notDetermined, requestPending: true)
        try expectEqual(pending.action, .request, "on peut redemander")
        try expect(pending.message.contains("Demande envoyée"), "message d'attente")
        let silent = WifiLocationGuidance.make(status: .notDetermined, requestPending: true, requestUnanswered: true)
        try expectEqual(silent.action, .openSettings, "sans réponse : réglages")
        try expectEqual(silent.secondaryAction, .request, "sans réponse : on peut encore redemander")
        try expectEqual(silent.secondaryButtonTitle, "Redemander", "libellé du second bouton")
        // La fenêtre peut être ouverte mais pas encore lue : message au conditionnel, délai généreux.
        try expect(silent.message.contains("Si aucune fenêtre"), "message au conditionnel")
        try expect(silent.message.contains("Si la fenêtre de macOS est ouverte"), "cas de la fenêtre encore ouverte")
        try expect(WifiLocationGuidance.promptTimeout >= 30, "délai assez long pour lire la fenêtre")
        try expect(pending.secondaryAction == nil, "pas de second bouton pendant l'attente")
        // Une fois répondu, l'attente ne compte plus.
        try expectEqual(WifiLocationGuidance.make(status: .authorized, requestPending: true, requestUnanswered: true).action,
                        .refresh, "autorisé l'emporte")
        try expectEqual(WifiLocationGuidance.make(status: .denied, requestPending: true).action, .openSettings, "refus l'emporte")
    }

    suite.add("Wi-Fi : localisation, service désactivé dans macOS") {
        try expectEqual(WifiLocationStatus.from(servicesEnabled: false, status: .authorized), .servicesDisabled, "désactivé l'emporte")
        try expectEqual(WifiLocationStatus.from(servicesEnabled: true, status: .denied), .denied, "état conservé")
        let guidance = WifiLocationGuidance.make(status: .servicesDisabled)
        try expectEqual(guidance.action, .openSettings, "ouvre les réglages")
        try expect(guidance.message.contains("désactivé"), "message explicite")
    }

    suite.add("Wi-Fi : localisation, typographie et adresse des réglages") {
        try expectEqual(WifiLocationGuidance.settingsURL,
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices", "adresse")
        try expect(URL(string: WifiLocationGuidance.settingsURL) != nil, "adresse valide")
        for status in WifiLocationStatus.allCases {
            for pending in [false, true] {
                for unanswered in [false, true] {
                    let text = WifiLocationGuidance.make(status: status, requestPending: pending, requestUnanswered: unanswered).message
                    for mark in [":", ";", "?", "!"] {
                        try expect(!text.contains(" \(mark)"), "espace ordinaire avant « \(mark) » (\(status))")
                    }
                    try expect(!text.contains("'"), "apostrophe droite (\(status))")
                }
            }
        }
    }
}
