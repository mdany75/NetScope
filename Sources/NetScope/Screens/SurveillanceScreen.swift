import NetScopeCore
import SwiftUI

/// Écran `Screen.surveillance`, provisoire (en construction), voir le croquis dans docs/croquis/.
struct SurveillanceScreen: View {
    var body: some View {
        UnderConstructionView(
            screen: .surveillance,
            summary: "Surveille en continu des appareils et des services, et prévient (notification macOS, barre de menus) quand quelque chose tombe.",
            features: [
                "Sondes : ping, port TCP, HTTP, DNS, avec intervalle et seuils",
                "Éditeur de sonde",
                "Journal des alertes",
                "Icône dans la barre de menus",
                "Aperçu de la notification macOS",
            ]
        )
    }
}
