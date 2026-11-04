import NetScopeCore
import SwiftUI

// Type d'équipement choisi à la main (note 20). Une seule source : `customType` de la fiche
// d'inventaire (InvAnnotations), retenue par MAC ; un appareil sans MAC utilise la fiche trouvée comme à
// la fusion (fiche à MAC de même IP, sinon fiche par IP), et n'a un choix de session, par IP, que s'il
// n'a pas encore de fiche. Tous les écrans qui affichent le type d'un appareil du scan passent par ici.

extension InvModel {
    /// Type affiché d'un appareil du scan (détecté, ou choisi à la main).
    func typeChoice(for device: Device) -> DeviceTypeChoice {
        store.typeChoice(for: device, session: sessionTypes)
    }

    /// Appareils avec leur type affiché à la place du type détecté (Carte, Rapports, tableau du Scanner).
    func withManualTypes(_ devices: [Device]) -> [Device] {
        store.applyingManualTypes(to: devices, session: sessionTypes)
    }
}

extension DeviceType {
    /// Symbole SF du type (poste, imprimante, caméra…).
    var symbolName: String {
        switch self {
        case .poste: return "desktopcomputer"
        case .serveur: return "server.rack"
        case .imprimante: return "printer"
        case .camera: return "video"
        case .pointAcces: return "wifi.router"
        case .switch: return "rectangle.connected.to.line.below"
        case .routeur: return "network"
        case .telephone: return "iphone"
        case .console: return "gamecontroller"
        case .domotique: return "house"
        case .iot: return "sensor"
        case .inconnu: return "questionmark.square.dashed"
        }
    }
}

/// Sous-menu « Changer le type » : tous les types, coche sur le type actuel (commun à la
/// sélection), « Revenir au type détecté ». Pour un menu contextuel ou un bouton de menu.
struct DeviceTypeMenu: View {
    /// Appareils du scan, tels que dans `AppState.devices` (type détecté).
    let devices: [Device]
    var title = "Changer le type"
    /// Message après le changement (ex. toast du Scanner).
    var report: (String) -> Void = { _ in }

    var body: some View {
        Menu(title) { DeviceTypeMenuItems(devices: devices, report: report) }
    }
}

/// Éléments du menu des types (sans le sous-menu), pour un `Menu` existant.
struct DeviceTypeMenuItems: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var inventory = InvModel.shared
    let devices: [Device]
    var report: (String) -> Void = { _ in }

    /// Appareils tels que le scan les a vus (type détecté), même si on a reçu leur copie affichée.
    private var originals: [Device] { devices.map { state.device(withID: $0.id) ?? $0 } }

    var body: some View {
        let choices = originals.map { inventory.typeChoice(for: $0) }
        let current = DeviceTypeChoice.common(choices)
        ForEach(DeviceType.allCases, id: \.self) { type in
            Toggle(isOn: Binding(get: { current == type }, set: { _ in apply(type) })) {
                Label(type.label, systemImage: type.symbolName)
            }
        }
        Divider()
        Button(choices.count == 1 ? "Revenir au type détecté (\(choices[0].detected.label))" : "Revenir au type détecté") {
            apply(nil)
        }
        .disabled(!choices.contains(where: \.isManual))
        if devices.contains(where: { $0.mac == nil }) {
            Divider()
            Text("Sans adresse MAC\u{00A0}: type retenu sur la fiche de son adresse IP")
        }
    }

    private func apply(_ type: DeviceType?) {
        let sessionOnly = inventory.setManualType(type, for: originals, all: state.devices)
        let subject = devices.count == 1 ? devices[0].displayName : "\(devices.count) appareils"
        var message = type.map { "Type de \(subject)\u{00A0}: \($0.label) (choisi à la main)." }
            ?? "Type détecté rétabli pour \(subject)."
        if sessionOnly > 0 {
            message += " Sans adresse MAC, le choix ne vaut que pour cette session."
        }
        report(message)
    }
}

/// Petite marque « choisi à la main » à côté d'un type.
struct ManualTypeMark: View {
    var body: some View {
        Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .help("Type choisi à la main (un scan ne le remplace pas)")
    }
}
