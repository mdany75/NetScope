import AppKit
import Foundation
import NetScopeCore

/// Note 94 : démonstration du relevé Wi-Fi sur plan (--demo, captures) : deux étages du Siège avec
/// un plan dessiné ici (pièces, murs, noms), l'échelle (10 m), les FortiAP du site placées et des
/// mesures tirées d'un modèle de propagation simple. Rien n'est mesuré ni balayé.
enum WifiFloorDemo {
    struct Room {
        let name: String
        let rect: CGRect
    }

    struct Radio {
        let name: String
        let serial: String
        let model: String
        let point: CGPoint
        let bssid: String
        let channel: Int
        let width: Int
    }

    static let width: CGFloat = 1600
    static let height: CGFloat = 1000
    /// 40 px par mètre : 40 m × 25 m.
    static let pixelsPerMetre: CGFloat = 40

    static let groundRooms = [
        Room(name: "Accueil", rect: CGRect(x: 0, y: 0, width: 400, height: 350)),
        Room(name: "Salle de conférence", rect: CGRect(x: 400, y: 0, width: 450, height: 350)),
        Room(name: "Bureaux ouverts", rect: CGRect(x: 850, y: 0, width: 750, height: 500)),
        Room(name: "Corridor", rect: CGRect(x: 0, y: 350, width: 850, height: 150)),
        Room(name: "Cuisine", rect: CGRect(x: 0, y: 500, width: 350, height: 500)),
        Room(name: "Serveurs", rect: CGRect(x: 350, y: 500, width: 250, height: 250)),
        Room(name: "Toilettes", rect: CGRect(x: 350, y: 750, width: 250, height: 250)),
        Room(name: "Entrepôt", rect: CGRect(x: 600, y: 500, width: 1000, height: 500)),
    ]

    static let upperRooms = [
        Room(name: "Direction", rect: CGRect(x: 0, y: 0, width: 500, height: 450)),
        Room(name: "Comptabilité", rect: CGRect(x: 500, y: 0, width: 550, height: 450)),
        Room(name: "Salle de formation", rect: CGRect(x: 1050, y: 0, width: 550, height: 450)),
        Room(name: "Corridor", rect: CGRect(x: 0, y: 450, width: 1600, height: 130)),
        Room(name: "Archives", rect: CGRect(x: 0, y: 580, width: 600, height: 420)),
        Room(name: "Bureaux", rect: CGRect(x: 600, y: 580, width: 1000, height: 420)),
    ]

    static let groundRadios = [
        Radio(name: "AP-ACCUEIL", serial: "FP231FTF22004101", model: "FAP-231F", point: CGPoint(x: 210, y: 230),
              bssid: "70:4C:A5:41:01:10", channel: 36, width: 80),
        Radio(name: "AP-SALLE-CONF", serial: "FP431FTF21000912", model: "FAP-431F", point: CGPoint(x: 640, y: 160),
              bssid: "70:4C:A5:09:12:10", channel: 44, width: 80),
        Radio(name: "AP-ENTREPOT", serial: "FP231FTF22004233", model: "FAP-231F", point: CGPoint(x: 980, y: 740),
              bssid: "70:4C:A5:42:33:10", channel: 149, width: 80),
    ]

    static let upperRadios = [
        Radio(name: "AP-DIRECTION", serial: "FP23JFTF23001044", model: "FAP-23JF", point: CGPoint(x: 260, y: 230),
              bssid: "70:4C:A5:10:44:10", channel: 100, width: 80),
        Radio(name: "AP-ETG2", serial: "FP231FTF22004187", model: "FAP-231F", point: CGPoint(x: 1100, y: 760),
              bssid: "70:4C:A5:41:87:10", channel: 52, width: 80),
    ]

    static let groundID = UUID(uuidString: "5A7E0094-0001-4C1E-9A11-00000000F001")!
    static let upperID = UUID(uuidString: "5A7E0094-0002-4C1E-9A11-00000000F002")!

    /// Captures : NETSCOPE_WIFI_VUE=plan ouvre l'onglet ; NETSCOPE_WIFI_PLAN_MESURE=canal|borne|snr|debit.
    static var opensPlan: Bool {
        CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["NETSCOPE_WIFI_VUE"] == "plan"
    }

    static var snapshotMetric: WifiHeatMetric? {
        ProcessInfo.processInfo.environment["NETSCOPE_WIFI_PLAN_MESURE"].flatMap(WifiHeatMetric.init(rawValue:))
    }

    static func plans(now: Date) -> WifiFloorPlans {
        WifiFloorPlans(floors: [
            floor(id: groundID, name: "Rez-de-chaussée", rooms: groundRooms, radios: groundRadios, points: groundPoints, now: now),
            floor(id: upperID, name: "Étage 2", rooms: upperRooms, radios: upperRadios, points: upperPoints, now: now),
        ])
    }

    private static func floor(id: UUID, name: String, rooms: [Room], radios: [Radio], points: [CGPoint], now: Date) -> WifiFloor {
        let image = planImage(rooms: rooms) ?? Data()
        let scale = WifiFloorScale(a: WifiPlanPoint(x: 40 / width, y: 970 / height), b: WifiPlanPoint(x: 440 / width, y: 970 / height), metres: 10)
        var measures: [WifiFloorMeasure] = []
        for (index, point) in points.enumerated() {
            var m = measure(at: point, radios: radios, index: index, time: now.addingTimeInterval(Double(index - points.count) * 50))
            if index % 3 == 0 { m.neighbors = neighbors(at: point, radios: radios, excluding: m.bssid) }
            measures.append(m)
        }
        let aps = radios.map { WifiFloorAP(name: $0.name, serial: $0.serial, model: $0.model,
                                           point: WifiPlanPoint(x: $0.point.x / width, y: $0.point.y / height)) }
        return WifiFloor(id: id, name: name, image: image, imageWidth: width, imageHeight: height, scale: scale, measures: measures, aps: aps)
    }

    /// Chemin du technicien : points répartis dans les pièces (rez-de-chaussée).
    static let groundPoints: [CGPoint] = [
        (90, 90), (300, 90), (120, 300), (330, 290), (480, 80), (700, 90), (560, 280), (780, 300),
        (920, 80), (1100, 90), (1300, 80), (1520, 90), (960, 300), (1180, 280), (1400, 300), (1540, 430),
        (1000, 450), (60, 420), (300, 430), (560, 430), (780, 430), (90, 600), (250, 780), (100, 940),
        (470, 600), (470, 880), (700, 580), (900, 620), (1150, 600), (1350, 600), (1530, 580), (700, 820),
        (880, 940), (1100, 900), (1280, 800), (1420, 920), (1560, 960), (1560, 760),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    static let upperPoints: [CGPoint] = [
        (100, 100), (400, 120), (250, 380), (620, 100), (900, 120), (700, 380), (1150, 100), (1450, 150),
        (1300, 400), (200, 520), (800, 520), (1400, 520), (120, 700), (420, 900), (750, 680), (1000, 900),
        (1300, 680), (1520, 920),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    /// Signal reçu d'une borne : modèle log-distance (exposant 3,2) et affaiblissement des rayonnages.
    static func rssi(from radio: Radio, at point: CGPoint) -> Int {
        let metres = max(1, hypot(point.x - radio.point.x, point.y - radio.point.y) / pixelsPerMetre)
        var value = -36 - 32 * log10(Double(metres))
        if point.x > 1280, point.y > 640 { value -= 7 }
        if point.x > 1350, point.y < 480 { value -= 3 }
        let wobble = Double((Int(point.x) * 7 + Int(point.y) * 13) % 5) - 2
        return Int((value + wobble).rounded())
    }

    static func measure(at point: CGPoint, radios: [Radio], index: Int, time: Date) -> WifiFloorMeasure {
        let best = radios.max { rssi(from: $0, at: point) < rssi(from: $1, at: point) } ?? radios[0]
        let signal = rssi(from: best, at: point)
        let noise = -92 - (index % 4)
        let rate: Double = signal >= -55 ? 1201 : (signal >= -62 ? 864 : (signal >= -68 ? 576 : (signal >= -74 ? 288 : 72)))
        return WifiFloorMeasure(point: WifiPlanPoint(x: point.x / width, y: point.y / height), time: time, ssid: "Bureau-Corp",
                                bssid: best.bssid, apName: best.name, band: .ghz5, channel: best.channel, widthMHz: best.width,
                                rssi: signal, noise: noise, linkRateMbps: rate)
    }

    static func neighbors(at point: CGPoint, radios: [Radio], excluding bssid: String?) -> [WifiFloorNeighbor] {
        var list = radios.filter { $0.bssid != bssid }.map {
            WifiFloorNeighbor(ssid: "Bureau-Corp", bssid: $0.bssid, band: .ghz5, channel: $0.channel, widthMHz: $0.width, rssi: rssi(from: $0, at: point))
        }
        // Réseau du voisin, de l'autre côté du mur de l'accueil.
        if point.x < 700, point.y < 500 {
            list.append(WifiFloorNeighbor(ssid: "Voisin-Invite", bssid: "A4:2B:B0:11:22:33", band: .ghz5, channel: 40, widthMHz: 40,
                                          rssi: Int(-58 - Double(point.x) / 40)))
        }
        return list.filter { $0.rssi >= -88 }
    }

    /// Mesure d'un clic en démonstration (étage choisi), d'après le même modèle.
    static func measure(at point: WifiPlanPoint, floorID: UUID?, withNeighbors: Bool) -> WifiFloorMeasure {
        let radios = floorID == upperID ? upperRadios : groundRadios
        let pixel = CGPoint(x: point.x * width, y: point.y * height)
        var m = measure(at: pixel, radios: radios, index: Int(pixel.x), time: Date())
        if withNeighbors { m.neighbors = neighbors(at: pixel, radios: radios, excluding: m.bssid) }
        return m
    }

    // MARK: Plan dessiné

    /// Plan d'étage en JPEG : fond blanc, murs, portes, noms des pièces et cartouche.
    static func planImage(rooms: [Room]) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Repère du haut à gauche, comme les points du plan.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(white: 0.965, alpha: 1).setFill()
        for room in rooms where room.name == "Corridor" { room.rect.fill() }
        NSColor(white: 0.25, alpha: 1).setStroke()
        for room in rooms {
            let path = NSBezierPath(rect: room.rect.insetBy(dx: 4, dy: 4))
            path.lineWidth = 7
            path.stroke()
        }
        // Portes : ouvertures blanches dans les murs vers le corridor.
        NSColor.white.setFill()
        for room in rooms where room.name != "Corridor" {
            let r = room.rect
            let door = r.minY >= 340 ? CGRect(x: r.minX + 60, y: r.minY - 6, width: 70, height: 20)
                                      : CGRect(x: r.minX + 60, y: r.maxY - 14, width: 70, height: 20)
            NSBezierPath(rect: door).fill()
        }
        // Noms des pièces (texte retourné pour rester lisible dans le repère inversé).
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ]
        for room in rooms {
            let text = NSAttributedString(string: room.name, attributes: attributes)
            let size = text.size()
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: room.rect.midX - size.width / 2, yBy: room.rect.minY + 34 + size.height)
            t.scaleX(by: 1, yBy: -1)
            t.concat()
            text.draw(at: .zero)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
