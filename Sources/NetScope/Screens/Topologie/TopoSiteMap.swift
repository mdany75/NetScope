import AppKit
import NetScopeCore
import SwiftUI

/// Carte d'un site sans l'écran : appareils du dernier scan, passerelle, relevés des switchs et
/// disposition retenue. Sert à l'écran Carte du réseau et à la section « Carte du réseau » des
/// rapports (note 61), rapports planifiés compris. Lecture seule : aucun accès réseau.
@MainActor
enum TopoSiteMap {
    /// Appareils gardés pour le site et ceux de son dernier scan : le Scanner pour le site actif,
    /// sinon les résultats enregistrés du site.
    static func siteDevices(key: String, state: AppState) -> (all: [Device], lastScan: [Device]) {
        let sites = SiteModel.shared
        if key == sites.activeKey {
            let scan = ScanController.shared
            return (state.devices, TopoScope.lastScan(state.devices, since: scan.startedAt, ranges: scan.lastScanRanges))
        }
        let results = sites.storedResults(for: key) ?? SiteResults()
        let devices = results.devices.map { device -> Device in
            var copy = device
            copy.customName = results.customNames[device.id] ?? device.customName
            return copy
        }
        return (devices, TopoScope.lastScan(devices, since: results.startedAt, ranges: results.parsedScanRanges))
    }

    /// Appareils dessinés (types choisis à la main) : ceux du dernier scan, ou tous ceux que garde le site.
    static func mapDevices(key: String, state: AppState, includePrevious: Bool = false) -> [Device] {
        let devices = siteDevices(key: key, state: state)
        let shown = includePrevious ? devices.all : devices.lastScan
        let model = InvModel.shared
        return key == SiteModel.shared.activeKey ? model.withManualTypes(shown)
            : model.inventory(for: key).applyingManualTypes(to: shown)
    }

    /// Passerelle du dessin : celle de l'interface pour le site actif ; pour un autre site,
    /// l'appareil de son dernier scan qui a la MAC de passerelle apprise par le site.
    static func gateway(_ devices: [Device], key: String, state: AppState) -> IPv4Address? {
        let sites = SiteModel.shared
        if key == sites.activeKey { return state.activeInterface?.gateway }
        guard let macs = sites.site(forKey: key)?.hints.gatewayMACs, !macs.isEmpty else { return nil }
        return devices.first { device in device.mac.map(macs.contains) ?? false }?.ip
    }

    /// Relevés des switchs du site : ceux du site actif seulement (les relevés SNMP et FortiGate ne
    /// sont gardés que pour lui). Démonstration : avec l'anneau de FortiSwitch.
    static func switches(key: String) -> [SNMPSwitchSnapshot] {
        guard key == SiteModel.shared.activeKey else { return [] }
        let snapshots = SwitchStore.shared.siteSnapshots
        return Launcher.isDemo ? TopoDemo.withRing(snapshots) : snapshots
    }

    /// Carte du site (appareils déjà filtrés).
    static func graph(_ devices: [Device], key: String, state: AppState) -> TopoGraph {
        TopoGraph.build(devices: devices, gateway: gateway(devices, key: key, state: state),
                        conflictIPs: InvModel.shared.inventory(for: key).conflictIPs, switches: switches(key: key))
    }

    /// Disposition de la carte entière qui tient le mieux dans `box` (hauteur des piles essayée de 1
    /// à 6) ; avec des nœuds placés à la main, celle qu'ils ont retenue.
    static func layout(_ graph: TopoGraph, key: String, box: CGSize, showEndDevices: Bool = true) -> TopoGraph.Layout {
        let manual = TopoLayoutStore.shared.layout(for: key)
        let margin = Double(TopoStyle.margin)
        let hidden: (TopoNode) -> Bool = { node in !showEndDevices && (node.kind == .groupe || node.kind == .appareil) }
        func layout(_ stack: Int) -> TopoGraph.Layout {
            graph.layout(nodeWidth: TopoStyle.nodeWidth, nodeHeight: TopoStyle.nodeHeight,
                         levelGap: 50, stackGap: 20, maxStack: stack, margin: margin, hidden: hidden)
        }
        if !manual.isEmpty { return layout(manual.stack).applying(manual, margin: margin) }
        var best: (layout: TopoGraph.Layout, fit: Double)?
        for stack in (1...6).reversed() {
            let candidate = layout(stack)
            let fit = min(Double(box.width) / candidate.width, Double(box.height) / candidate.height)
            if let current = best, fit <= current.fit + 0.01 { continue }
            best = (candidate, fit)
        }
        return best?.layout ?? layout(4)
    }

    // MARK: Rapports

    /// Image déjà rendue par site (même carte : pas de nouveau rendu).
    private static var cache: [String: (signature: Int, image: ReportImage)] = [:]

    /// Note 61 : carte du site pour la section « Carte du réseau » des rapports : la carte entière du
    /// dernier scan, tous VLAN, sans recherche, avec ses nœuds placés à la main ; image en clair.
    static func reportMap(key: String, siteName: String, state: AppState) -> ReportMap? {
        let devices = mapDevices(key: key, state: state)
        guard !devices.isEmpty else { return nil }
        let graph = graph(devices, key: key, state: state)
        // Proportions d'une page lettre (largeur utile × hauteur restante sous le titre).
        let layout = layout(graph, key: key, box: CGSize(width: 533, height: 560))
        let content = TopoExportContent(graph: graph, layout: layout, showPortLabels: true, title: "", details: [],
                                        showHeader: false, showLegend: true)
        var hasher = Hasher()
        hasher.combine(content.scene.nodes)
        hasher.combine(content.scene.links)
        hasher.combine(siteName)
        let signature = hasher.finalize()
        let image: ReportImage?
        if let cached = cache[key], cached.signature == signature {
            image = cached.image
        } else if let rendered = TopoExporter.reportImage(content, siteName: siteName) {
            cache[key] = (signature, rendered)
            image = rendered
        } else {
            image = nil
        }
        return ReportMap.make(graph: graph, siteName: siteName, image: image)
    }
}
