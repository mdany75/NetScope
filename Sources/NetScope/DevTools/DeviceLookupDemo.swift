import Foundation
import NetScopeCore

/// Démonstration de « Ouvrir une fiche » et des appareils saisis à la main (écran Appareil).
/// Valeurs fictives ; aucun réseau (la vérification par ping n'est jamais lancée).
///
/// Captures (avec --snapshot --demo et NETSCOPE_ECRANS=appareil) :
/// - NETSCOPE_APPAREIL_VIDE=1 : aucun appareil choisi (panneau « Ouvrir une fiche ») ;
/// - NETSCOPE_APPAREIL_SAISIE="10.182" : texte du champ principal (suggestions) ;
/// - NETSCOPE_APPAREIL_FORMULAIRE=1 : formulaire « Saisir un appareil à la main » rempli ;
/// - NETSCOPE_APPAREIL_MANUEL=1 : fiche d'un appareil saisi à la main, vérifié par ping.
@MainActor
enum DeviceLookupDemo {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Appareil saisi à la main de la démonstration : mini PC de la salle de conférence, absent du scan.
    static func manualEntry(now: Date) -> ManualDeviceEntry {
        ManualDeviceEntry(id: UUID(uuidString: "5A0C3E1B-7D1F-4C55-9E7A-1D2B3C4D5E6F")!,
                          ip: IPv4Address("10.182.122.168")!, mac: MACAddress("1C:69:7A:0B:44:E2"),
                          name: "Mini PC salle de conférence", type: .poste,
                          created: now.addingTimeInterval(-26 * 60),
                          lastCheck: ManualDeviceEntry.Check(date: now.addingTimeInterval(-2 * 60), latencyMs: 3.8))
    }

    /// Fiches consultées récemment (dont l'appareil saisi à la main).
    static func recents(now: Date, state: AppState) -> [DeviceRecentView] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var list: [DeviceRecentView] = []
        for (ip, minutes) in [("10.182.122.111", 4.0), ("10.10.0.20", 55), ("10.182.122.146", 190), ("192.168.50.21", 1_500)] {
            if let device = state.devices.first(where: { $0.ip.description == ip }) {
                list.append(DeviceRecentView(device: device, viewed: ago(minutes)))
            }
        }
        // Autre site actif (NETSCOPE_SITE) : ces appareils du Siège peuvent manquer.
        list.insert(DeviceRecentView(device: manualEntry(now: now).device, viewed: ago(2), isManual: true), at: min(1, list.count))
        return list
    }

    static func apply(to state: AppState, now: Date = Date()) {
        state.setManualDemo([manualEntry(now: now)], recents: recents(now: now, state: state))
        guard CommandLine.arguments.contains("--snapshot") else { return }
        let model = DeviceLookupModel.shared
        if environment["NETSCOPE_APPAREIL_VIDE"] == "1" { state.selectedDeviceID = nil }
        if let text = environment["NETSCOPE_APPAREIL_SAISIE"] {
            state.selectedDeviceID = nil
            model.query = text
        }
        if environment["NETSCOPE_APPAREIL_FORMULAIRE"] == "1" {
            state.selectedDeviceID = nil
            model.form = DeviceManualDraft(ip: "10.182.122.185", name: "Borne de pointage quai 2", mac: "00:07:4d:2a:91:c3",
                                           type: .iot, notes: "Prêtée par le fournisseur jusqu’au 30 novembre. Branchée sur la prise Q2-04.")
            model.formShown = true
        }
        if environment["NETSCOPE_APPAREIL_MANUEL"] == "1" {
            state.selectedDeviceID = manualEntry(now: now).deviceID
        }
    }
}
