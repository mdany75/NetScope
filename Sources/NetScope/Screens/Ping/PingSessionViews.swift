import NetScopeCore
import SwiftUI

// Note 78 (0.26.0) : menu « Session » de la barre d'outils du ping continu et choix de la
// disposition (cartes, tableau compact, automatique).

/// Menu « Session » : ouvrir, enregistrer, rouvrir la dernière, notification macOS.
struct PingSessionMenu: View {
    @ObservedObject var controller: PingController

    var body: some View {
        Menu {
            Button("Ouvrir une session…") { controller.openSession() }
            Button("Enregistrer la session…") { controller.saveSessionAs() }
                .disabled(controller.targets.isEmpty)
            if let last = controller.lastSession, controller.targets.isEmpty {
                Button("Rouvrir la dernière session (\(last.summary))") { controller.reopenLastSession() }
            }
            Divider()
            Toggle("Notifier quand une cible tombe ou revient", isOn: $controller.notifyChanges)
        } label: {
            Label("Session", systemImage: "rectangle.stack")
        }
        .fixedSize()
        .help("Enregistrer ou rouvrir la liste des cibles et les réglages (pas les mesures)\u{00A0}; notification macOS à la coupure et au retour")
    }
}

/// Disposition des cibles : « Auto » passe au tableau compact au-delà de 9 cibles.
struct PingLayoutPicker: View {
    @ObservedObject var controller: PingController

    var body: some View {
        let count = controller.targets.count
        let autoTitle = "Auto"
        PingSegmented(options: [
            .init(value: PingLayoutChoice.automatic, title: autoTitle,
                  help: "Cartes jusqu’à \(PingLayoutChoice.cardLimit) cibles, tableau compact au-delà (\(count) maintenant)"),
            .init(value: PingLayoutChoice.cards, title: "Cartes", help: "Toujours des cartes"),
            .init(value: PingLayoutChoice.table, title: "Tableau", help: "Toujours le tableau compact"),
        ], selection: controller.layoutChoice) { controller.layoutChoice = $0 }
            .fixedSize()
            .accessibilityLabel("Disposition des cibles")
    }
}
