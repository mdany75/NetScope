import Foundation
import NetScopeCore

/// Rassemble les données d'un rapport depuis l'état partagé et les magasins des autres écrans :
/// appareils du scan (AppState), fiches d'inventaire (InvModel), relevés SNMP (SwitchStore) et
/// réseaux Wi-Fi vus (WifiStore). Lecture seule : rien n'est interrogé sur le réseau ici.
@MainActor
enum RapportData {
    static func input(state: AppState, demo: Bool, now: Date = Date()) -> ReportInput {
        // Type choisi à la main (note 20) à la place du type détecté.
        let devices = InvModel.shared.withManualTypes(state.devices)
        let ranges = state.ranges.filter(\.isEnabled)
        let parsed = ranges.compactMap { try? $0.parsed() }
        // Note 28 : l'inventaire est propre au site actif ; on n'en garde que les fiches des plages
        // scannées qui correspondent aux appareils de ce scan.
        let inRanges = InvModel.shared.store.sortedRecords.filter { record in
            parsed.contains { $0.contains(record.ip) }
        }
        let records = ReportBuilder.sessionRecords(inRanges, devices: devices)

        // Note 28 : switchs du site actif seulement.
        let snapshots = SwitchStore.shared.siteSnapshots
        let switches = snapshots.map { ReportSwitch(snapshot: $0) }

        var input = ReportInput(
            devices: devices, records: records,
            ranges: ranges.map { ReportRange(label: $0.label, text: $0.text, vlan: $0.vlan) },
            switches: switches, links: links(snapshots), wifiNote: wifiNote(WifiStore.shared.networks),
            annex: snapshots.flatMap { ReportRawLine.macTable($0) + [ReportRawLine("")] }.dropLast().map { $0 },
            scanDate: devices.map(\.lastSeen).max(), now: now)
        input.extraProblems = dhcpProblems(InvModel.shared.store.events, ranges: parsed)

        if let interface = state.activeInterface {
            input.sourceIP = interface.address.description
            input.sourceName = devices.first { $0.ip == interface.address }?.hostnameLabel
            // Passerelle du Mac seulement si elle est dans les plages du site (sinon le Mac est
            // ailleurs : la passerelle d'un autre site n'a pas sa place dans ce rapport).
            if let gateway = interface.gateway, parsed.contains(where: { $0.contains(gateway) }) {
                let name = devices.first { $0.ip == gateway }?.hostnameLabel
                input.gateway = gateway.description + (name.map { " (\($0))" } ?? "")
            }
        }
        // Bilans « Santé courriel » ajoutés depuis la Boîte à outils (en démonstration : le bilan affiché).
        let mail = ToolStore.shared.mailHealth
        input.mailHealth = mail.exported
        if demo, input.mailHealth.isEmpty, let summary = mail.report?.summary { input.mailHealth = [summary] }
        // Vitesse des disques : dernier test de chaque emplacement (historique de l'outil).
        input.diskTests = DiskSpeedModel.shared.reportRecords
        // Wi-Fi FortiAP (note 27) : dernière lecture des bornes par les FortiGate.
        let fortiAP = FortiAPStore.shared
        input.fortiWifi = fortiAP.hasData ? fortiAP.overview : nil
        input.fortiWifiThresholds = fortiAP.thresholds
        // Étendues DHCP (note 37) : dernière lecture de la FortiGate, sinon l'estimation du Test DHCP.
        let dhcpScopes = DHCPScopeStore.shared
        let scopes = dhcpScopes.overview(devices: devices)
        input.dhcpScopes = scopes.scopes.isEmpty ? nil : scopes
        input.dhcpThresholds = dhcpScopes.thresholds
        // WAN et VPN (note 39) : dernière lecture des FortiGate du site actif.
        input.wan = WANStore.shared.reportOverview(state: state)
        input.wanThresholds = WANStore.shared.thresholds
        // Diagnostic Wi-Fi (note 47) : diagnostics retenus pour le rapport du site actif.
        input.wifiDiagnoses = WifiDiagnosisStore.shared.reported(forKey: SiteModel.shared.activeKey)
        if demo, input.wifiDiagnoses.isEmpty { input.wifiDiagnoses = WifiDiagnosisDemo.reportResults(state: state) }
        // Note 28 : les compléments du croquis décrivent le Siège seulement.
        if demo, SiteModel.shared.activeID == SitesDemo.siegeID { RapportDemo.complete(&input) }
        return input
    }

    /// Données de chaque site choisi dans le menu « Site ▾ » des Rapports : le site actif d'après le
    /// Scanner (comme ci-dessus), les autres d'après leur dernier scan enregistré et leur propre
    /// inventaire (lecture seule, aucun réseau). Rien n'est fusionné d'un site à l'autre.
    static func inputs(state: AppState, demo: Bool, keys: [String], now: Date = Date()) -> [ReportSiteInput] {
        let sites = SiteModel.shared
        return keys.map { key in
            let name = sites.name(forKey: key)
            if key == sites.activeKey { return ReportSiteInput(name: name, input: input(state: state, demo: demo, now: now)) }
            return ReportSiteInput(name: name, input: input(forSite: key, now: now))
        }
    }

    /// Un autre site que le site actif : appareils de son dernier scan (sites/<id>/resultats.json),
    /// fiches de son inventaire dans ses plages. Les relevés SNMP, le Wi-Fi vu par ce Mac et les
    /// outils (courriel, disques, FortiAP) ne décrivent que le site actif : ils n'y sont pas.
    static func input(forSite key: String, now: Date = Date()) -> ReportInput {
        let sites = SiteModel.shared
        let results = sites.storedResults(for: key) ?? SiteResults()
        let store = InvModel.shared.inventory(for: key)
        let named = results.devices.map { device -> Device in
            var copy = device
            copy.customName = results.customNames[device.id] ?? device.customName
            return copy
        }
        let devices = store.applyingManualTypes(to: named)
        let ranges = (sites.site(forKey: key)?.ranges ?? []).filter(\.isEnabled)
        let parsed = ranges.compactMap { try? $0.parsed() }
        let inRanges = store.sortedRecords.filter { record in parsed.contains { $0.contains(record.ip) } }
        var input = ReportInput(
            devices: devices, records: ReportBuilder.sessionRecords(inRanges, devices: devices),
            ranges: ranges.map { ReportRange(label: $0.label, text: $0.text, vlan: $0.vlan) },
            scanDate: results.finishedAt ?? devices.map(\.lastSeen).max(), now: now)
        input.extraProblems = dhcpProblems(store.events, ranges: parsed)
        return input
    }

    /// Serveurs DHCP non autorisés signalés par le Test DHCP (alertes « à traiter » de l'inventaire)
    /// dont l'adresse tombe dans les plages du rapport : un problème critique par adresse.
    static func dhcpProblems(_ events: [InvEvent], ranges: [IPRange]) -> [ReportProblem] {
        var seen: Set<IPv4Address> = []
        var result: [ReportProblem] = []
        for event in events.sorted(by: { $0.date > $1.date })
        where event.kind == .dhcpNonAutorise && event.status == .aTraiter && !event.baseline
            && ranges.contains(where: { $0.contains(event.ip) }) && !seen.contains(event.ip) {
            seen.insert(event.ip)
            var detail = event.detail.trimmingCharacters(in: .whitespaces)
            if !detail.isEmpty, !detail.hasSuffix(".") { detail += "." }
            result.append(ReportProblem(
                title: "DHCP non autorisé sur \(event.ip)", severity: .critique,
                recommendation: (detail.isEmpty ? "" : detail + " ")
                    + "Débrancher l’appareil, puis activer DHCP snooping sur les VLAN concernés."))
        }
        return result
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
