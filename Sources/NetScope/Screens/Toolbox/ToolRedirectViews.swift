import NetScopeCore
import SwiftUI

/// Test MTU : renvoie vers le ping continu (pings de taille croissante avec le bit DF).
struct MTUToolView: View {
    @EnvironmentObject private var state: AppState
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Cible") {
                    ToolTextField(placeholder: "10.182.122.1", text: $target)
                }
                Button("Ouvrir dans Ping continu") { state.sendToPing(target) }
                    .buttonStyle(.primary)
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolNotice(tone: .accent, title: "Le test MTU se fait dans Ping continu",
                       message: "La recherche de MTU envoie des pings de taille croissante avec le bit Don’t Fragment (1472 + 28 = 1500 octets, puis 8972 + 28 = 9000 pour les trames jumbo). La cible est ajoutée au ping continu, qui porte le moteur ICMP.")
            ToolCellGrid(cells: [
                ToolCell(key: "Ethernet standard", value: "1500", detail: "charge ICMP max 1472 octets"),
                ToolCell(key: "PPPoE", value: "1492", detail: "charge ICMP max 1464 octets"),
                ToolCell(key: "Trames jumbo", value: "9000", detail: "charge ICMP max 8972 octets"),
            ], columns: 3)
        }
        .onAppear {
            if target.isEmpty { target = state.activeInterface?.gateway?.description ?? "" }
        }
    }
}

/// iperf3 et Speedtest : liens vers l'écran Speedtest.
struct SpeedRedirectView: View {
    @EnvironmentObject private var state: AppState
    let tool: ToolKind

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolNotice(tone: .accent, title: tool == .iperf ? "iperf3 est dans l’écran Speedtest" : "Le test de débit est dans l’écran Speedtest",
                       message: tool == .iperf
                       ? "Mesure du débit réel entre ce Mac et un serveur iperf3 du réseau (flux parallèles, sens envoi, réception ou bidirectionnel), avec l’historique des mesures."
                       : "Débit Internet descendant et montant, latence au repos et sous charge (bufferbloat), avec l’historique des tests.")
            Button {
                state.open(.speedtest)
            } label: {
                Label("Ouvrir Speedtest", systemImage: Screen.speedtest.symbol)
            }
            .buttonStyle(.primary)
        }
    }
}
