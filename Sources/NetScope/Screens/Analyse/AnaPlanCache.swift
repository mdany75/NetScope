import NetScopeCore
import SwiftUI

// Note 78 : le plan d'adressage (carte d'occupation) et les lignes « Prochaine IP libre » coûtent
// jusqu'à 65 536 évaluations par bloc /16. Ils ne sont plus recalculés à chaque rendu de l'écran :
// ce cache garde le dernier résultat et ne le recalcule que si ses données changent.
//
// - Identité (site, bloc) nouvelle : calcul immédiat (premier affichage, autre plage choisie), une
//   seule fois ; la capture hors écran (--snapshot) voit donc tout de suite le bon plan.
// - Mêmes site et bloc, données changées (scan en cours, DHCP relu, exclusions) : l'ancien résultat
//   reste affiché pendant qu'une tâche détachée calcule le nouveau, hors du MainActor.

/// Données dont dépend un calcul du plan : une valeur différente demande un nouveau calcul.
struct AnaPlanInputs: Hashable, Sendable {
    let subnets: [AddressPlanSubnet]
    let dhcpReadAt: Date?
    let dhcpScopes: Int
    let dhcpLeases: Int
    let exclusions: AddressExclusions
    let recentWindow: TimeInterval
    /// Empreinte des fiches (adresse, présence, conflit, dernière vue), indépendante de l'ordre.
    let records: Int
    let count: Int
    /// Minute du calcul : un appareil hors ligne finit par ne plus occuper son adresse.
    let minute: Int
    /// Note 84 : empreinte des clients Wi-Fi et des ports des bornes (filaire ou Wi-Fi).
    let wireless: Int

    @MainActor
    init(addressing: AnaAddressing, records: [InvRecord], recentWindow: TimeInterval, now: Date) {
        subnets = addressing.subnets
        dhcpReadAt = addressing.dhcpReadAt
        dhcpScopes = addressing.dhcp.scopes.count
        dhcpLeases = addressing.dhcp.leases.count
        exclusions = addressing.exclusions
        self.recentWindow = recentWindow
        var digest = 0
        for record in records {
            var hasher = Hasher()
            hasher.combine(record.key)
            hasher.combine(record.ip.value)
            hasher.combine(record.isOnline)
            hasher.combine(record.hasConflict)
            hasher.combine(record.lastSeen)
            hasher.combine(record.wireless?.seen)
            hasher.combine(record.wireless?.apName)
            // Type (choisi à la main ou détecté) et MAC : ils décident du classement filaire ou Wi-Fi.
            hasher.combine(record.type)
            hasher.combine(record.mac)
            hasher.combine(record.switchName)
            hasher.combine(record.switchPort)
            digest = digest &+ hasher.finalize()
        }
        self.records = digest
        count = records.count
        minute = Int(now.timeIntervalSinceReferenceDate / 60)
        var wifi = addressing.wireless.localWifiIPs.count
        for (mac, client) in addressing.wireless.clientsByMAC {
            var hasher = Hasher()
            hasher.combine(mac)
            hasher.combine(client)
            wifi = wifi &+ hasher.finalize()
        }
        for ip in addressing.wireless.accessPointIPs { wifi = wifi &+ Int(ip.value) }
        for (location, ap) in addressing.wireless.accessPointPorts {
            var hasher = Hasher()
            hasher.combine(location)
            hasher.combine(ap)
            wifi = wifi &+ hasher.finalize()
        }
        wireless = wifi
    }
}

/// Dernier résultat d'un calcul coûteux, recalculé hors du MainActor quand ses données changent.
@MainActor
final class AnaAsyncCache<Identity: Hashable & Sendable, Value: Sendable>: ObservableObject {
    private var identity: Identity?
    private var inputs: AnaPlanInputs?
    private var value: Value?
    private var pending: AnaPlanInputs?
    private var task: Task<Void, Never>?

    func value(identity: Identity, inputs: AnaPlanInputs, compute: @escaping @Sendable () -> Value) -> Value {
        if let value, identity == self.identity {
            if inputs != self.inputs, inputs != pending {
                pending = inputs
                task?.cancel()
                task = Task { [weak self] in
                    let result = await Task.detached(priority: .userInitiated) { compute() }.value
                    guard let self, !Task.isCancelled, self.identity == identity, self.pending == inputs else { return }
                    self.value = result
                    self.inputs = inputs
                    self.pending = nil
                    self.objectWillChange.send()
                }
            }
            return value
        }
        task?.cancel()
        task = nil
        pending = nil
        let result = compute()
        self.identity = identity
        self.inputs = inputs
        value = result
        return result
    }
}

/// Bloc de la carte d'occupation d'un site.
struct AnaPlanIdentity: Hashable, Sendable {
    let site: String
    let block: Subnet
}
