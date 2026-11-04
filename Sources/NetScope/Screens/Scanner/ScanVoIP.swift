import Foundation
import NetScopeCore

/// Note 30 : téléphones IP reconnus d'après ce que NetScope sait déjà, sans rien envoyer de plus :
/// voisins LLDP des switchs relevés (SNMP ou FortiGate) qui s'annoncent « téléphone », voisins
/// LLDP / CDP entendus par ce Mac (VLAN voix du port), plages nommées « Voix ».
extension ScanController {
    /// Reporte les indices VoIP sur les appareils du scan ; renvoie le nombre d'appareils changés.
    @discardableResult
    func applyVoIPHints(_ state: AppState) -> Int {
        let hints = VoIPDetector.hints(snapshots: Array(SwitchStore.shared.snapshots.values),
                                       neighbors: ToolStore.shared.neighbors.neighbors,
                                       ranges: state.ranges, devices: state.devices)
        guard !hints.isEmpty else { return 0 }
        let result = VoIPDetector.apply(hints, to: state.devices)
        if result.changed > 0 { state.devices = result.devices }
        return result.changed
    }
}
