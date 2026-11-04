import Foundation
import NetScopeCore

/// Rassemble les données d'un rapport depuis l'état partagé et les magasins des autres écrans :
/// appareils du scan (AppState), fiches d'inventaire (InvModel), relevés SNMP (SwitchStore) et
/// réseaux Wi-Fi vus (WifiStore). Lecture seule : rien n'est interrogé sur le réseau ici.
@MainActor
enum RapportData {
    static func input(state: AppState, demo: Bool, now: Date = Date()) -> ReportInput {
        let devices = state.devices
        let ranges = state.ranges.filter(\.isEnabled)
        let parsed = ranges.compactMap { try? $0.parsed() }
        // L'inventaire est commun à tous les clients : on ne garde que les fiches des plages scannées
        // qui correspondent aux appareils de ce scan (une fiche d'un autre client sur la même plage
        // privée n'entre pas dans le rapport).
        let inRanges = InvModel.shared.store.sortedRecords.filter { record in
            parsed.contains { $0.contains(record.ip) }
        }
        let records = ReportBuilder.sessionRecords(inRanges, devices: devices)

        let snapshots = SwitchStore.shared.orderedSnapshots
        let switches = snapshots.map { ReportSwitch(snapshot: $0) }

        var input = ReportInput(
            devices: devices, records: records,
            ranges: ranges.map { ReportRange(label: $0.label, text: $0.text, vlan: $0.vlan) },
            switches: switches, links: links(snapshots), wifiNote: wifiNote(WifiStore.shared.networks),
            annex: snapshots.flatMap { ReportRawLine.macTable($0) + [ReportRawLine("")] }.dropLast().map { $0 },
            scanDate: devices.map(\.lastSeen).max(), now: now)

        if let interface = state.activeInterface {
            input.sourceIP = interface.address.description
            input.sourceName = devices.first { $0.ip == interface.address }?.hostnameLabel
            if let gateway = interface.gateway {
                let name = devices.first { $0.ip == gateway }?.hostnameLabel
                input.gateway = gateway.description + (name.map { " (\($0))" } ?? "")
            }
        }
        if demo { RapportDemo.complete(&input) }
        return input
    }

    /// Liens entre switchs relevés, d'après LLDP : « SW-CORE-01 Gi1/0/47 ↔ SW-ETG2-01 25 (LLDP) ».
    static func links(_ snapshots: [SNMPSwitchSnapshot]) -> [String] {
        func key(_ name: String) -> String { name.lowercased().split(separator: ".").first.map(String.init) ?? "" }
        let names = Dictionary(snapshots.map { (key($0.displayName), $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<String> = []
        var result: [String] = []
        for snapshot in snapshots {
            for neighbor in snapshot.neighbors {
                guard let other = names[key(neighbor.sysName)], other != snapshot.displayName else { continue }
                let pair = [snapshot.displayName, other].sorted().joined(separator: "|")
                guard !seen.contains(pair) else { continue }
                seen.insert(pair)
                let local = neighbor.ifIndex.flatMap { snapshot.interface($0)?.name } ?? "port \(neighbor.localPortNum)"
                result.append("\(snapshot.displayName) \(local) ↔ \(other) \(neighbor.portID) (LLDP)")
            }
        }
        return result
    }

    /// Synthèse des réseaux Wi-Fi vus par ce Mac (nil si aucune analyse).
    static func wifiNote(_ networks: [WifiNetwork]) -> String? {
        guard !networks.isEmpty else { return nil }
        let band24 = networks.filter { $0.band == .ghz24 }.count
        let best = WifiAdvisor.bestChannel24(networks)
        var text = "\(networks.count) réseau\(networks.count > 1 ? "x" : "") Wi-Fi vu\(networks.count > 1 ? "s" : "") depuis ce Mac, dont \(band24) en 2,4 GHz"
        if band24 > 0 { text += "\u{00A0}; canal 2,4 GHz le moins encombré\u{00A0}: \(best)" }
        return text + "."
    }
}
