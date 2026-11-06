import AppKit
import Foundation
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Outil du clic sur le plan.
enum WifiFloorTool: String, CaseIterable, Identifiable {
    case measure, scale, ap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .measure: return "Mesurer"
        case .scale: return "Échelle"
        case .ap: return "Placer une borne"
        }
    }
}

/// Note 94 : relevé Wi-Fi sur plan, un fichier par site (sites/<site>/wifi-plans.json, synchronisé
/// avec le site par la note 86). Chaque mesure est lancée par un clic de l'utilisateur sur le plan :
/// signal, bruit, débit du lien, borne et canal lus localement (CoreWLAN, par WifiStore) ; les
/// bornes voisines seulement s'il coche « Bornes voisines » (un balayage de quelques secondes).
///
/// Rien n'est mesuré, balayé ni écrit en démonstration ni pendant les captures (WifiFloorDemo).
@MainActor
final class WifiFloorStore: ObservableObject {
    static let shared = WifiFloorStore()

    @Published private(set) var plans = WifiFloorPlans()
    @Published private(set) var siteKey: String?
    @Published var selectedFloorID: UUID?
    @Published var metric: WifiHeatMetric = .signal
    @Published var tool: WifiFloorTool = .measure
    /// Balayer les bornes voisines à chaque mesure (quelques secondes de plus).
    @Published var withNeighbors = false
    /// Premier point de l'échelle, puis les deux points en attente de la distance.
    @Published var scaleFirst: WifiPlanPoint?
    @Published var scalePending: (a: WifiPlanPoint, b: WifiPlanPoint)?
    /// Nom de la borne à placer au prochain clic (outil « Placer une borne »).
    @Published var apName = ""
    @Published private(set) var phase: String?
    @Published var message: String?

    let isDemo: Bool
    private var readOnly = Set<String>()
    private var task: Task<Void, Never>?
    private var write: Task<Void, Never>?

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot) {
        isDemo = demo
        if demo {
            plans = WifiFloorDemo.plans(now: Date())
            selectedFloorID = plans.floors.first?.id
            siteKey = SiteModel.shared.activeKey
            if let metric = WifiFloorDemo.snapshotMetric { self.metric = metric }
        }
    }

    var floor: WifiFloor? { plans.floor(selectedFloorID) ?? plans.floors.first }
    var isMeasuring: Bool { phase != nil }

    // MARK: Site

    func reloadFromDisk(siteKey key: String) {
        guard !isDemo, key == siteKey, !isMeasuring else { return }
        siteKey = nil
        load(siteKey: key)
    }

    func load(siteKey key: String) {
        guard key != siteKey else { return }
        cancel()
        siteKey = key
        guard !isDemo else { return }
        plans = Self.read(siteKey: key) ?? WifiFloorPlans()
        if Self.isUnreadable(siteKey: key) {
            readOnly.insert(key)
            message = "Relevé sur plan de ce site illisible (version plus récente de NetScope\u{00A0}?)\u{00A0}: les changements ne seront pas enregistrés."
        }
        if plans.floor(selectedFloorID) == nil { selectedFloorID = plans.floors.first?.id }
    }

    private static func url(siteKey: String) -> URL? {
        SiteModel.shared.files.map { WifiFloorPlans.url(in: $0, siteKey: siteKey) }
    }

    private static func read(siteKey: String) -> WifiFloorPlans? {
        guard let url = url(siteKey: siteKey), let data = try? Data(contentsOf: url) else { return nil }
        return WifiFloorPlans.decode(data)
    }

    private static func isUnreadable(siteKey: String) -> Bool {
        guard let url = url(siteKey: siteKey), FileManager.default.fileExists(atPath: url.path) else { return false }
        return read(siteKey: siteKey) == nil
    }

    private func save() {
        guard !isDemo, !RegEnvironment.isSnapshot, let key = siteKey, !readOnly.contains(key),
              let url = Self.url(siteKey: key), let data = plans.encoded() else { return }
        let previous = write
        write = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func update(_ change: (inout WifiFloor) -> Void) {
        guard let id = floor?.id, let index = plans.floors.firstIndex(where: { $0.id == id }) else { return }
        change(&plans.floors[index])
        save()
    }

    // MARK: Étages

    /// Importe le plan d'un étage (PDF : première page ; image) et l'ajoute au site.
    func importPlan() {
        guard plans.floors.count < WifiFloorPlans.maxFloors else {
            message = "Trop d’étages pour ce site (\(WifiFloorPlans.maxFloors) au plus)."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .tiff, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choisir le plan de l’étage (PDF ou image)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let rendered = Self.render(url) else {
            message = "Plan illisible\u{00A0}: \(url.lastPathComponent)."
            return
        }
        let name = WifiFloorPlans.floorName(url.deletingPathExtension().lastPathComponent, index: plans.floors.count + 1)
        let floor = WifiFloor(name: name, image: rendered.data, imageWidth: rendered.width, imageHeight: rendered.height)
        plans.floors.append(floor)
        selectedFloorID = floor.id
        tool = .scale
        scaleFirst = nil
        message = "Plan «\u{00A0}\(name)\u{00A0}» importé. Indiquer l’échelle\u{00A0}: cliquer deux points du plan, puis saisir leur distance."
        save()
    }

    /// Image du plan (2 400 px au plus sur le grand côté), en JPEG sur fond blanc.
    static func render(_ url: URL) -> (data: Data, width: Double, height: Double)? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let longest: CGFloat = 2_400
        let factor = longest / max(image.size.width, image.size.height)
        let size = NSSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return (data, Double(size.width), Double(size.height))
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { $0.name = String(trimmed.prefix(60)) }
    }

    func removeFloor() {
        guard let id = floor?.id else { return }
        plans.floors.removeAll { $0.id == id }
        selectedFloorID = plans.floors.first?.id
        save()
    }

    // MARK: Clic sur le plan

    func tap(_ point: WifiPlanPoint, wifi: WifiStore) {
        guard floor != nil else { return }
        switch tool {
        case .measure: measure(at: point, wifi: wifi)
        case .scale:
            if let first = scaleFirst {
                scalePending = (first, point)
                scaleFirst = nil
            } else {
                scaleFirst = point
                scalePending = nil
            }
        case .ap: placeAP(at: point)
        }
    }

    func applyScale(metres: Double) {
        guard let pending = scalePending, metres > 0, metres.isFinite else { return }
        update { $0.scale = WifiFloorScale(a: pending.a, b: pending.b, metres: metres) }
        scalePending = nil
        tool = .measure
        message = "Échelle enregistrée\u{00A0}: \(WifiRoomSurvey.number(metres))\u{00A0}m."
    }

    func cancelScale() {
        scaleFirst = nil
        scalePending = nil
    }

    private func placeAP(at point: WifiPlanPoint) {
        let name = apName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            message = "Choisir ou saisir le nom de la borne avant de cliquer sur le plan."
            return
        }
        let known = FortiAPStore.shared.shownOverview.aps.first { $0.name == name }
        update { floor in
            if let index = floor.aps.firstIndex(where: { $0.name == name }) {
                floor.aps[index].point = point
            } else {
                floor.aps.append(WifiFloorAP(name: name, serial: known?.serial, model: known?.model, point: point))
            }
        }
        message = "Borne «\u{00A0}\(name)\u{00A0}» placée."
    }

    func removeAP(_ id: UUID) {
        update { $0.aps.removeAll { $0.id == id } }
    }

    func removeMeasures(_ ids: Set<UUID>) {
        update { $0.measures.removeAll { ids.contains($0.id) } }
    }

    func removeLastMeasure() {
        update { if !$0.measures.isEmpty { $0.measures.removeLast() } }
    }

    // MARK: Mesure

    private func measure(at point: WifiPlanPoint, wifi: WifiStore) {
        guard !isMeasuring, let floorID = floor?.id else { return }
        message = nil
        if isDemo {
            plans.add(WifiFloorDemo.measure(at: point, floorID: floorID, withNeighbors: withNeighbors), to: floorID)
            message = "Mesure ajoutée (démonstration)."
            return
        }
        wifi.refresh()
        guard let connection = wifi.connection, let network = connection.network else {
            message = "Mesure impossible\u{00A0}: ce Mac n’est connecté à aucun réseau Wi-Fi."
            return
        }
        let bssid = network.bssid?.formatted(.upperColon)
        var measure = WifiFloorMeasure(point: point, time: Date(), ssid: network.ssid, bssid: bssid, apName: nil,
                                       band: network.band, channel: network.channel, widthMHz: network.widthMHz, rssi: network.rssi,
                                       noise: network.noise, linkRateMbps: connection.transmitRate)
        guard withNeighbors else {
            plans.add(measure, to: floorID)
            message = "Mesure ajoutée\u{00A0}: \(WifiQuality.dbm(measure.rssi))."
            save()
            return
        }
        // Balayage demandé : quelques secondes, puis les voisines de ce balayage.
        phase = "Balayage des bornes voisines…"
        let before = wifi.scanCount
        wifi.scan()
        task = Task { [weak self] in
            for _ in 0..<80 where wifi.isScanning {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            if wifi.scanCount != before {
                measure.neighbors = wifi.networks.filter { !$0.isConnected }.map {
                    WifiFloorNeighbor(ssid: $0.ssid, bssid: $0.bssid?.formatted(.upperColon), band: $0.band, channel: $0.channel,
                                      widthMHz: $0.widthMHz, rssi: $0.rssi)
                }
            }
            self.plans.add(measure, to: floorID)
            self.phase = nil
            self.task = nil
            self.message = "Mesure ajoutée\u{00A0}: \(WifiQuality.dbm(measure.rssi))"
                + (measure.neighbors.map { ", \($0.count) borne\($0.count > 1 ? "s" : "") voisine\($0.count > 1 ? "s" : "")" } ?? ", voisines non lues") + "."
            self.save()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = nil
    }

    // MARK: Export

    /// PDF de l'étage affiché (plan, carte de chaleur, bilan).
    func exportPDF(siteName: String) {
        guard let floor else { return }
        let panel = NSSavePanel()
        let slug = (siteName + "-" + floor.name).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        panel.nameFieldStringValue = "releve-wifi-\(slug).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = WifiFloorExport.pdf(floor, metric: metric, siteName: siteName) else {
            message = "Export impossible."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            message = "Relevé exporté\u{00A0}: \(url.lastPathComponent)."
        } catch {
            message = "Export impossible\u{00A0}: \(error.localizedDescription)"
        }
    }

    /// Étages du site pour la section « Relevé Wi-Fi sur plan » des rapports.
    func reportFloors(siteKey key: String) -> [ReportFloorSurveyFloor] {
        let source: WifiFloorPlans
        if isDemo || key == siteKey {
            source = (isDemo && key != SiteModel.shared.activeKey) ? WifiFloorPlans() : plans
        } else {
            source = Self.read(siteKey: key) ?? WifiFloorPlans()
        }
        return source.floors.filter { !$0.measures.isEmpty }.map { floor in
            ReportFloorSurveyFloor.make(floor, image: WifiFloorExport.reportImage(floor))
        }
    }
}
