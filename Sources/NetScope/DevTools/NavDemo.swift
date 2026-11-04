import Foundation
import NetScopeCore

/// Captures de la navigation entre les modules (notes 31, 33 et 34), sans réseau ni clic simulé :
///
///   NETSCOPE_NAV="carte:imprimantes>inventaire"  groupe « Imprimantes ×N » de la Carte → Inventaire filtré
///   NETSCOPE_NAV="carte:sw-etg2-01>scanner"       branche d'un switch (nœud et dessous) → Scanner filtré
///   NETSCOPE_NAV="port:SW-ETG2-01/1/14"           port de switch → l'appareil branché (ou Inventaire filtré)
///   NETSCOPE_NAV="appareil:10.182.122.111>carte"  « Ouvrir dans › Carte du réseau » d'un appareil
///
/// L'écran d'origine est retenu : les captures montrent l'étiquette du filtre transmis et le
/// bouton Retour actif (« Retour à Carte du réseau »).
@MainActor
enum NavDemo {
    static func apply(to state: AppState) {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_NAV"], let colon = raw.firstIndex(of: ":") else { return }
        let kind = raw[..<colon].lowercased()
        let rest = String(raw[raw.index(after: colon)...])
        let parts = rest.split(separator: ">", maxSplits: 1).map(String.init)
        let subject = parts.first ?? ""
        let target = parts.count > 1 ? NavModule(rawValue: parts[1].lowercased()) : nil
        let site = SiteModel.shared.activeKey

        state.recordsHistory = true
        defer { state.recordsHistory = false }
        switch kind {
        case "carte":
            state.screen = .carte
            let devices = InvModel.shared.withManualTypes(state.devices)
            let graph = TopoGraph.build(devices: devices, gateway: state.activeInterface?.gateway)
            let wanted = SearchText.fold(subject.replacingOccurrences(of: "groupe-", with: ""))
            guard let node = graph.nodes.first(where: { $0.kind == .groupe && SearchText.fold($0.title).hasPrefix(wanted) })
                    ?? graph.nodes.first(where: { SearchText.fold($0.title).contains(wanted)
                        || $0.deviceIDs.contains { id in devices.first { $0.id == id }.flatMap(\.hostname).map(SearchText.fold) == wanted } }),
                  let group = graph.navGroup(node.id, devices: devices, siteKey: site) else {
                print("NETSCOPE_NAV : aucun groupe «\u{00A0}\(subject)\u{00A0}» sur la Carte (\(graph.nodes.map(\.title).joined(separator: ", ")))")
                return
            }
            print("NETSCOPE_NAV : \(group.filterLabel) → \(target ?? .inventaire)")
            state.shownFocus[.carte] = .node(node.id)
            // La capture de la Carte montre aussi le groupe choisi et ses boutons « Inventaire », « Scanner ».
            state.pendingFocus[.carte] = .node(node.id)
            state.navigate(NavResolver.groupDestination(group, module: target ?? .inventaire))
        case "port":
            // « SW-ETG2-01/1/14 » : nom du switch, puis nom du port (qui peut contenir « / »).
            guard let slash = subject.firstIndex(of: "/") else { return }
            let name = String(subject[..<slash]), port = String(subject[subject.index(after: slash)...])
            guard let snapshot = SwitchStore.shared.orderedSnapshots.first(where: { $0.displayName.lowercased() == name.lowercased() }),
                  let iface = snapshot.interfaces.first(where: { $0.name == port }) else { return }
            state.screen = .switchs
            SwitchStore.shared.select(host: snapshot.id, port: iface.index)
            switch NavPortResolver.resolve(NavPortRef(host: snapshot.id, ifIndex: iface.index), in: state.navContext()) {
            case .go(let destination): state.navigate(destination)
            case .choose(_, _, _, let all): if let destination = all?.destination { state.navigate(destination) }
            case .message: break
            }
        case "appareil":
            guard let device = state.device(withID: subject) else { return }
            state.screen = .scanner
            state.selectedDeviceID = device.id
            let items = state.openInItems(.device(NavDeviceRef(device)))
            if let item = items.first(where: { $0.destination.module == (target ?? .appareil) }) {
                state.navigate(item.destination)
            }
        default:
            break
        }
    }
}
