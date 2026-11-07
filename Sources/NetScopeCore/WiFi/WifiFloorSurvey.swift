import Foundation

// Note 94 : relevé Wi-Fi sur plan (carte de chaleur). Le plan d'un étage (PDF ou image, rendu en
// image à l'import) reçoit une échelle (deux points et une distance), des mesures prises au clic
// (signal, bruit, débit du lien, borne et canal captés ; bornes voisines seulement sur demande) et
// les bornes placées à la main. La carte de chaleur, les zones mortes, les chevauchements de canaux
// et l'emplacement suggéré d'une borne se calculent ici, sans réseau ni interface : les tests passent
// des étages fixes. Les étages d'un site vont dans sites/<site>/wifi-plans.json (synchronisé avec
// le site, note 86) ; depuis la 0.37.1 (note 95), l'image de chaque plan est à part, dans
// sites/<site>/wifi-plans/<étage>.jpg : une mesure ne renvoie plus le plan entier aux autres Mac.

/// Point du plan en coordonnées relatives (0 à 1 de la largeur et de la hauteur de l'image).
public struct WifiPlanPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

/// Échelle du plan : deux points et la distance réelle qui les sépare.
public struct WifiFloorScale: Codable, Hashable, Sendable {
    public var a: WifiPlanPoint
    public var b: WifiPlanPoint
    public var metres: Double

    public init(a: WifiPlanPoint, b: WifiPlanPoint, metres: Double) {
        self.a = a
        self.b = b
        self.metres = metres
    }

    /// Mètres par pixel de l'image ; nil si les deux points sont confondus ou la distance nulle.
    public func metresPerPixel(width: Double, height: Double) -> Double? {
        let pixels = hypot((b.x - a.x) * width, (b.y - a.y) * height)
        guard pixels >= 1, metres > 0, metres.isFinite else { return nil }
        return metres / pixels
    }
}

/// Borne voisine vue par un balayage fait à la demande pendant la mesure.
public struct WifiFloorNeighbor: Codable, Hashable, Sendable {
    public var ssid: String?
    public var bssid: String?
    public var band: WifiBand
    public var channel: Int
    public var widthMHz: Int
    public var rssi: Int

    public init(ssid: String?, bssid: String?, band: WifiBand, channel: Int, widthMHz: Int = 20, rssi: Int) {
        self.ssid = ssid
        self.bssid = bssid
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.rssi = rssi
    }
}

/// Une mesure prise à un endroit du plan.
public struct WifiFloorMeasure: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var point: WifiPlanPoint
    public var time: Date
    public var ssid: String?
    public var bssid: String?
    /// Nom de la borne captée, quand une borne placée sur le plan porte ce BSSID (ou en démo).
    public var apName: String?
    public var band: WifiBand?
    public var channel: Int?
    public var widthMHz: Int?
    public var rssi: Int
    public var noise: Int?
    /// Débit du lien annoncé par la carte Wi-Fi (Mb/s).
    public var linkRateMbps: Double?
    /// Bornes voisines ; nil : balayage non demandé.
    public var neighbors: [WifiFloorNeighbor]?

    public init(id: UUID = UUID(), point: WifiPlanPoint, time: Date, ssid: String? = nil, bssid: String? = nil, apName: String? = nil,
                band: WifiBand? = nil, channel: Int? = nil, widthMHz: Int? = nil, rssi: Int, noise: Int? = nil,
                linkRateMbps: Double? = nil, neighbors: [WifiFloorNeighbor]? = nil) {
        self.id = id
        self.point = point
        self.time = time
        self.ssid = ssid
        self.bssid = bssid
        self.apName = apName
        self.band = band
        self.channel = channel
        self.widthMHz = widthMHz
        self.rssi = rssi
        self.noise = noise
        self.linkRateMbps = linkRateMbps
        self.neighbors = neighbors
    }

    public var snr: Int? { noise.map { rssi - $0 } }

    /// Borne captée telle qu'affichée : son nom, sinon son BSSID.
    public var apLabel: String? { apName ?? bssid }
}

/// Borne placée à la main sur le plan (FortiAP lue sur la FortiGate, ou autre).
public struct WifiFloorAP: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var serial: String?
    public var model: String?
    public var point: WifiPlanPoint
    /// BSSID de la borne (majuscules, deux-points), appris quand une mesure prise sur ses ondes est
    /// nommée par la FortiGate ; sert ensuite à nommer les mesures et les voisines sans elle.
    public var bssids: [String]

    public init(id: UUID = UUID(), name: String, serial: String? = nil, model: String? = nil, point: WifiPlanPoint, bssids: [String] = []) {
        self.id = id
        self.name = name
        self.serial = serial
        self.model = model
        self.point = point
        self.bssids = bssids
    }

    private enum CodingKeys: String, CodingKey { case id, name, serial, model, point, bssids }

    /// Fichiers d'avant les BSSID : `bssids` absent → aucun.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        point = try c.decode(WifiPlanPoint.self, forKey: .point)
        bssids = try c.decodeIfPresent([String].self, forKey: .bssids) ?? []
    }
}

/// Un étage : plan (image), échelle, mesures et bornes placées.
public struct WifiFloor: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Image du plan (JPEG ou PNG) et sa taille en pixels.
    public var image: Data
    public var imageWidth: Double
    public var imageHeight: Double
    public var scale: WifiFloorScale?
    public var measures: [WifiFloorMeasure]
    public var aps: [WifiFloorAP]

    /// Largeur supposée d'un plan sans échelle, pour que les calculs restent possibles.
    public static let assumedWidthMetres = 40.0

    public init(id: UUID = UUID(), name: String, image: Data, imageWidth: Double, imageHeight: Double, scale: WifiFloorScale? = nil,
                measures: [WifiFloorMeasure] = [], aps: [WifiFloorAP] = []) {
        self.id = id
        self.name = name
        self.image = image
        self.imageWidth = max(1, imageWidth)
        self.imageHeight = max(1, imageHeight)
        self.scale = scale
        self.measures = measures
        self.aps = aps
    }

    /// Mètres par pixel d'après l'échelle ; nil sans échelle.
    public var metresPerPixel: Double? { scale?.metresPerPixel(width: imageWidth, height: imageHeight) }
    /// Mètres par pixel employés par les calculs (largeur supposée sans échelle).
    public var effectiveMetresPerPixel: Double { metresPerPixel ?? Self.assumedWidthMetres / imageWidth }

    /// Distance réelle (m) entre deux points du plan.
    public func metres(_ a: WifiPlanPoint, _ b: WifiPlanPoint) -> Double {
        hypot((a.x - b.x) * imageWidth, (a.y - b.y) * imageHeight) * effectiveMetresPerPixel
    }

    /// Nom de la borne qui émet ce BSSID : borne placée qui le porte, sinon mesure déjà nommée.
    public func apName(bssid: String?) -> String? {
        guard let key = bssid?.uppercased(), !key.isEmpty else { return nil }
        if let ap = aps.first(where: { $0.bssids.contains(key) }) { return ap.name }
        return measures.last { $0.bssid?.uppercased() == key && $0.apName != nil }?.apName
    }

    /// Associe un BSSID à la borne placée de ce nom (et le retire des autres) ; false : aucune borne de ce nom.
    @discardableResult
    public mutating func learn(bssid: String?, apName: String?) -> Bool {
        guard let key = bssid?.uppercased(), !key.isEmpty, let apName,
              let index = aps.firstIndex(where: { $0.name == apName }) else { return false }
        for i in aps.indices where i != index { aps[i].bssids.removeAll { $0 == key } }
        if !aps[index].bssids.contains(key) { aps[index].bssids.append(key) }
        return true
    }

    public var widthMetres: Double { imageWidth * effectiveMetresPerPixel }
    public var heightMetres: Double { imageHeight * effectiveMetresPerPixel }

    private enum CodingKeys: String, CodingKey { case id, name, image, imageWidth, imageHeight, scale, measures, aps }

    /// Note 95 : l'image n'est plus écrite dans le JSON (fichier à part) ; un ancien fichier qui
    /// la contient encore est relu tel quel, puis migré à l'enregistrement suivant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decodeIfPresent(Data.self, forKey: .image) ?? Data()
        imageWidth = max(1, try c.decode(Double.self, forKey: .imageWidth))
        imageHeight = max(1, try c.decode(Double.self, forKey: .imageHeight))
        scale = try c.decodeIfPresent(WifiFloorScale.self, forKey: .scale)
        measures = try c.decodeIfPresent([WifiFloorMeasure].self, forKey: .measures) ?? []
        aps = try c.decodeIfPresent([WifiFloorAP].self, forKey: .aps) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(imageWidth, forKey: .imageWidth)
        try c.encode(imageHeight, forKey: .imageHeight)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encode(measures, forKey: .measures)
        try c.encode(aps, forKey: .aps)
    }
}

/// Étages d'un site.
public struct WifiFloorPlans: Codable, Hashable, Sendable {
    /// 2 (0.37.1, note 95) : images des plans hors du JSON.
    public static let currentVersion = 2
    public static let fileName = "wifi-plans.json"
    /// Dossier des images des plans, à côté du fichier du site.
    public static let imageFolder = "wifi-plans"
    public static let maxFloors = 30
    public static let maxMeasuresPerFloor = 1_000

    public var version: Int
    public var floors: [WifiFloor]

    public init(floors: [WifiFloor] = []) {
        version = Self.currentVersion
        self.floors = floors
    }

    public var isEmpty: Bool { floors.isEmpty }

    public func floor(_ id: UUID?) -> WifiFloor? { floors.first { $0.id == id } }

    /// Nom d'un nouvel étage : le texte saisi, sinon « Étage N ».
    public static func floorName(_ text: String, index: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Étage \(index)" : String(trimmed.prefix(60))
    }

    public mutating func add(_ measure: WifiFloorMeasure, to floorID: UUID) {
        guard let index = floors.firstIndex(where: { $0.id == floorID }) else { return }
        floors[index].measures.append(measure)
        if floors[index].measures.count > Self.maxMeasuresPerFloor {
            floors[index].measures.removeFirst(floors[index].measures.count - Self.maxMeasuresPerFloor)
        }
    }

    /// JSON du site, sans les images des plans (fichiers à part, `write(to:)`).
    public func encoded() -> Data? {
        var copy = self
        copy.version = max(version, Self.currentVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(copy)
    }

    /// Lecture tolérante : illisible ou d'une version future → nil (le fichier n'est pas écrasé).
    public static func decode(_ data: Data) -> WifiFloorPlans? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let plans = try? decoder.decode(WifiFloorPlans.self, from: data), plans.version <= currentVersion else { return nil }
        return plans
    }

    public static func url(in files: SiteFiles, siteKey: String) -> URL {
        files.folder(for: siteKey).appendingPathComponent(fileName)
    }

    // MARK: Images des plans (note 95)

    /// Chemin de l'image d'un étage, relatif au dossier du site (« wifi-plans/<id>.jpg »).
    public static func imagePath(_ floorID: UUID) -> String { imageFolder + "/" + floorID.uuidString + ".jpg" }

    /// Vrai pour le chemin d'une image de plan dans le dossier des données
    /// (« sites/<site>/wifi-plans/<id>.jpg »).
    public static func isImagePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == Substring(SiteFiles.folderName), parts[2] == Substring(imageFolder),
              path.lowercased().hasSuffix(".jpg") else { return false }
        return UUID(uuidString: String(parts[3].dropLast(4))) != nil
    }

    /// Fichiers d'un site lus dans son dossier.
    public struct Loaded: Sendable {
        public var plans: WifiFloorPlans
        /// Ancien fichier (images dans le JSON) : à réécrire dans le nouveau format.
        public var needsMigration: Bool
        /// Étages dont l'image manque encore (pas encore reçue d'un autre Mac).
        public var missingImages: [UUID]
    }

    /// Lit le fichier du site et les images de ses plans ; nil : fichier absent ou illisible.
    /// Un ancien fichier (images dans le JSON) est relu tel quel et signalé à migrer.
    public static func read(folder: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)), var plans = decode(data) else { return nil }
        var migrate = plans.version < currentVersion
        var missing: [UUID] = []
        for index in plans.floors.indices {
            if !plans.floors[index].image.isEmpty {
                migrate = true
                continue
            }
            let url = folder.appendingPathComponent(imagePath(plans.floors[index].id))
            if let image = try? Data(contentsOf: url), !image.isEmpty {
                plans.floors[index].image = image
            } else {
                missing.append(plans.floors[index].id)
            }
        }
        return Loaded(plans: plans, needsMigration: migrate, missingImages: missing)
    }

    /// Écrit les images des plans (seulement celles qui ont changé), puis le JSON du site, puis
    /// retire les images des étages supprimés. Une image encore absente (pas reçue) est laissée.
    public func write(to folder: URL) throws {
        let manager = FileManager.default
        let images = folder.appendingPathComponent(Self.imageFolder, isDirectory: true)
        try manager.createDirectory(at: images, withIntermediateDirectories: true)
        for floor in floors where !floor.image.isEmpty {
            let url = folder.appendingPathComponent(Self.imagePath(floor.id))
            if (try? Data(contentsOf: url)) != floor.image { try floor.image.write(to: url, options: .atomic) }
        }
        guard let data = encoded() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
        let kept = Set(floors.map { $0.id.uuidString + ".jpg" })
        for name in (try? manager.contentsOfDirectory(atPath: images.path)) ?? []
        where name.lowercased().hasSuffix(".jpg") && !kept.contains(name) && UUID(uuidString: String(name.dropLast(4))) != nil {
            try? manager.removeItem(at: images.appendingPathComponent(name))
        }
    }
}

// MARK: - Carte de chaleur

/// Mesure affichée par la carte de chaleur.
public enum WifiHeatMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case signal, snr, debit, borne, canal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .signal: return "Signal"
        case .snr: return "Signal/bruit"
        case .debit: return "Débit du lien"
        case .borne: return "Borne captée"
        case .canal: return "Canal"
        }
    }

    /// Borne et canal : couleur par valeur (borne la plus proche), sans interpolation.
    public var isCategorical: Bool { self == .borne || self == .canal }

    public func value(_ measure: WifiFloorMeasure) -> Double? {
        switch self {
        case .signal: return Double(measure.rssi)
        case .snr: return measure.snr.map(Double.init)
        case .debit: return measure.linkRateMbps
        case .borne, .canal: return nil
        }
    }

    public func category(_ measure: WifiFloorMeasure) -> String? {
        switch self {
        case .borne: return measure.apLabel
        case .canal: return measure.channel.map { "Canal \($0)" + (measure.band.map { " (\($0.label))" } ?? "") }
        default: return nil
        }
    }

    /// Qualité d'une valeur (0 : excellente … 3 : zone morte), pour la couleur et la légende.
    public func level(_ value: Double) -> Int {
        switch self {
        case .signal: return value >= -60 ? 0 : (value >= -67 ? 1 : (value >= Double(WifiHeatmap.deadRSSI) ? 2 : 3))
        case .snr: return value >= 35 ? 0 : (value >= 25 ? 1 : (value >= 15 ? 2 : 3))
        case .debit: return value >= 400 ? 0 : (value >= 150 ? 1 : (value >= 50 ? 2 : 3))
        case .borne, .canal: return 0
        }
    }

    /// Libellés des quatre niveaux (légende).
    public var levelLabels: [String] {
        switch self {
        case .signal: return ["≥ −60\u{00A0}dBm", "−60 à −67", "−67 à −75", "< −75 (zone morte)"]
        case .snr: return ["≥ 35\u{00A0}dB", "25 à 35", "15 à 25", "< 15"]
        case .debit: return ["≥ 400\u{00A0}Mb/s", "150 à 400", "50 à 150", "< 50"]
        case .borne, .canal: return []
        }
    }
}

/// Grille de la carte de chaleur : une case carrée (en pixels de l'image), de gauche à droite puis de
/// haut en bas. Une case trop loin de toute mesure reste vide (nil).
public struct WifiHeatGrid: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    /// Côté d'une case en fraction de la largeur et de la hauteur de l'image.
    public var cellWidth: Double
    public var cellHeight: Double
    public var values: [Double?]
    public var categories: [String?]

    public func index(column: Int, row: Int) -> Int { row * columns + column }

    public func center(column: Int, row: Int) -> WifiPlanPoint {
        WifiPlanPoint(x: (Double(column) + 0.5) * cellWidth, y: (Double(row) + 0.5) * cellHeight)
    }
}

/// Zone morte : cases voisines sous le seuil du signal.
public struct WifiDeadZone: Hashable, Sendable {
    public var center: WifiPlanPoint
    public var areaSquareMetres: Double
    public var cells: Int
}

/// Chevauchement de canaux constaté à un endroit (borne captée et voisines sur des canaux qui se recouvrent).
public struct WifiChannelOverlap: Hashable, Sendable {
    public var band: WifiBand
    public var channel: Int
    /// Bornes en concurrence (SSID ou BSSID), sans la borne captée.
    public var others: [String]
    public var strongestRSSI: Int
    public var point: WifiPlanPoint
}

/// Bilan d'un étage.
public struct WifiFloorAnalysis: Hashable, Sendable {
    public var measureCount: Int
    /// Cases couvertes par les mesures et leur part (%) par niveau de signal (0 : excellent … 3 : zone morte).
    public var coveredCells: Int
    public var levelPercents: [Double]
    public var deadZones: [WifiDeadZone]
    public var overlaps: [WifiChannelOverlap]
    /// Emplacement suggéré d'une borne ajoutée ; nil : aucune zone faible.
    public var suggestion: WifiPlanPoint?
    public var strongestRSSI: Int?
    public var weakestRSSI: Int?
    public var medianRSSI: Int?

    public var deadPercent: Double { levelPercents.count > 3 ? levelPercents[3] : 0 }
    public var goodPercent: Double { levelPercents.prefix(2).reduce(0, +) }
}

public enum WifiHeatmap {
    /// Signal sous lequel une case est en zone morte (dBm).
    public static let deadRSSI = -75
    /// Signal sous lequel une case est faible (emplacement suggéré).
    public static let weakRSSI = -67
    /// Portée d'une mesure : au-delà, la case reste vide (m).
    public static let reachMetres = 8.0
    /// Rayon autour d'une borne suggérée (m).
    public static let suggestionRadiusMetres = 7.0
    /// Zone faible minimale pour suggérer une borne : au moins ce nombre de cases et cette surface.
    public static let suggestionMinimumCells = 4
    public static let suggestionMinimumSquareMetres = 4.0
    /// Signal minimal d'une voisine pour compter un chevauchement (dBm).
    public static let overlapRSSI = -80

    /// Grille d'interpolation : pondération par l'inverse du carré de la distance (mesures dans la
    /// portée), borne ou canal de la mesure la plus proche.
    public static func grid(_ floor: WifiFloor, metric: WifiHeatMetric, columns: Int = 64) -> WifiHeatGrid {
        let columns = max(2, columns)
        let cellPixels = floor.imageWidth / Double(columns)
        let rows = max(1, Int((floor.imageHeight / cellPixels).rounded(.up)))
        let cellWidth = 1 / Double(columns)
        let cellHeight = cellPixels / floor.imageHeight
        let numeric = floor.measures.compactMap { m in metric.value(m).map { (m.point, $0) } }
        let labeled = floor.measures.compactMap { m in metric.category(m).map { (m.point, $0) } }
        var values = [Double?](repeating: nil, count: columns * rows)
        var categories = [String?](repeating: nil, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let center = WifiPlanPoint(x: (Double(column) + 0.5) * cellWidth, y: min(1, (Double(row) + 0.5) * cellHeight))
                let index = row * columns + column
                if metric.isCategorical {
                    var best: (Double, String)?
                    for (point, label) in labeled {
                        let d = floor.metres(center, point)
                        if d <= reachMetres, d < (best?.0 ?? .infinity) { best = (d, label) }
                    }
                    categories[index] = best?.1
                } else {
                    values[index] = interpolate(numeric, at: center, floor: floor)
                }
            }
        }
        return WifiHeatGrid(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight, values: values, categories: categories)
    }

    /// Valeur interpolée en un point (nil : aucune mesure à portée).
    public static func interpolate(_ samples: [(WifiPlanPoint, Double)], at point: WifiPlanPoint, floor: WifiFloor) -> Double? {
        var weights = 0.0
        var sum = 0.0
        for (where_, value) in samples {
            let d = floor.metres(point, where_)
            guard d <= reachMetres else { continue }
            if d < 0.25 { return value }
            let w = 1 / (d * d)
            weights += w
            sum += w * value
        }
        return weights > 0 ? sum / weights : nil
    }

    /// Deux canaux se recouvrent-ils ? 2,4 GHz : moins de 5 canaux d'écart ; 5 et 6 GHz : blocs communs.
    public static func overlaps(band: WifiBand, _ a: Int, width a2: Int, _ b: Int, width b2: Int) -> Bool {
        if band == .ghz24 { return abs(a - b) < 5 }
        let first = Set(WifiChannelAdvisor.blockChannels(band: band, channel: a, widthMHz: a2))
        let second = Set(WifiChannelAdvisor.blockChannels(band: band, channel: b, widthMHz: b2))
        return !first.isDisjoint(with: second) || a == b
    }

    /// Chevauchements constatés par les mesures qui ont balayé les voisines.
    public static func channelOverlaps(_ floor: WifiFloor) -> [WifiChannelOverlap] {
        var result: [WifiChannelOverlap] = []
        // Nom des bornes connues par leur BSSID (mesures nommées), sinon le SSID de la voisine.
        var names: [String: String] = [:]
        for ap in floor.aps { for bssid in ap.bssids { names[bssid.uppercased()] = ap.name } }
        for measure in floor.measures {
            if let bssid = measure.bssid?.uppercased(), let name = measure.apName { names[bssid] = name }
        }
        for measure in floor.measures {
            guard let band = measure.band, let channel = measure.channel, let neighbors = measure.neighbors else { continue }
            let width = measure.widthMHz ?? 20
            let others = neighbors.filter { n in
                n.band == band && n.rssi >= overlapRSSI && n.bssid?.uppercased() != measure.bssid?.uppercased()
                    && overlaps(band: band, channel, width: width, n.channel, width: n.widthMHz)
            }
            guard !others.isEmpty else { continue }
            let labels = Array(Set(others.map { n in n.bssid.flatMap { names[$0.uppercased()] } ?? n.ssid ?? n.bssid ?? "?" }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            result.append(WifiChannelOverlap(band: band, channel: channel, others: labels,
                                             strongestRSSI: others.map(\.rssi).max() ?? overlapRSSI, point: measure.point))
        }
        return result
    }

    /// Chevauchements regroupés (même bande, même canal, mêmes bornes) avec le nombre d'endroits.
    public static func distinctOverlaps(_ overlaps: [WifiChannelOverlap]) -> [(overlap: WifiChannelOverlap, places: Int)] {
        var order: [String] = []
        var groups: [String: (overlap: WifiChannelOverlap, places: Int)] = [:]
        for overlap in overlaps {
            let key = "\(overlap.band.rawValue)|\(overlap.channel)|" + overlap.others.joined(separator: ",")
            if var group = groups[key] {
                group.places += 1
                if overlap.strongestRSSI > group.overlap.strongestRSSI { group.overlap.strongestRSSI = overlap.strongestRSSI }
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = (overlap, 1)
            }
        }
        return order.compactMap { groups[$0] }
    }

    /// Bilan de l'étage d'après la grille du signal.
    public static func analysis(_ floor: WifiFloor, columns: Int = 64) -> WifiFloorAnalysis {
        let grid = grid(floor, metric: .signal, columns: columns)
        var counts = [0, 0, 0, 0]
        var covered = 0
        for value in grid.values {
            guard let value else { continue }
            covered += 1
            counts[WifiHeatMetric.signal.level(value)] += 1
        }
        let percents = counts.map { covered > 0 ? Double($0) * 100 / Double(covered) : 0 }
        let rssis = floor.measures.map(\.rssi).sorted()
        return WifiFloorAnalysis(measureCount: floor.measures.count, coveredCells: covered, levelPercents: percents,
                                 deadZones: deadZones(grid, floor: floor), overlaps: channelOverlaps(floor),
                                 suggestion: suggestion(grid, floor: floor), strongestRSSI: rssis.last, weakestRSSI: rssis.first,
                                 medianRSSI: rssis.isEmpty ? nil : rssis[rssis.count / 2])
    }

    /// Zones mortes : groupes de cases voisines (4-connexité) sous `deadRSSI`, de la plus grande à la plus petite.
    public static func deadZones(_ grid: WifiHeatGrid, floor: WifiFloor) -> [WifiDeadZone] {
        var seen = Set<Int>()
        var zones: [WifiDeadZone] = []
        let cellArea = pow(grid.cellWidth * floor.imageWidth * floor.effectiveMetresPerPixel, 2)
        func isDead(_ i: Int) -> Bool { (grid.values[i] ?? 0) < Double(deadRSSI) && grid.values[i] != nil }
        for start in grid.values.indices where isDead(start) && !seen.contains(start) {
            var stack = [start]
            seen.insert(start)
            var cells: [Int] = []
            while let i = stack.popLast() {
                cells.append(i)
                let column = i % grid.columns, row = i / grid.columns
                for (c, r) in [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
                where c >= 0 && r >= 0 && c < grid.columns && r < grid.rows {
                    let j = grid.index(column: c, row: r)
                    if isDead(j), !seen.contains(j) { seen.insert(j); stack.append(j) }
                }
            }
            let points = cells.map { grid.center(column: $0 % grid.columns, row: $0 / grid.columns) }
            let center = WifiPlanPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                                       y: points.map(\.y).reduce(0, +) / Double(points.count))
            zones.append(WifiDeadZone(center: center, areaSquareMetres: Double(cells.count) * cellArea, cells: cells.count))
        }
        return zones.sorted { $0.cells > $1.cells }
    }

    /// Emplacement suggéré d'une borne ajoutée : la case faible qui a le plus de cases faibles dans
    /// un rayon de `suggestionRadiusMetres` (en cas d'égalité, la plus loin des bornes placées) ;
    /// nil si cette zone faible est trop petite (moins de 4 cases ou de 4 m²).
    public static func suggestion(_ grid: WifiHeatGrid, floor: WifiFloor) -> WifiPlanPoint? {
        let weak = grid.values.indices.filter { (grid.values[$0] ?? 0) < Double(weakRSSI) && grid.values[$0] != nil }
        guard !weak.isEmpty else { return nil }
        let points = weak.map { grid.center(column: $0 % grid.columns, row: $0 / grid.columns) }
        var best: (score: Int, distance: Double, point: WifiPlanPoint)?
        for candidate in points {
            let score = points.filter { floor.metres($0, candidate) <= suggestionRadiusMetres }.count
            let distance = floor.aps.map { floor.metres($0.point, candidate) }.min() ?? 0
            if best == nil || score > best!.score || (score == best!.score && distance > best!.distance + 1e-9) {
                best = (score, distance, candidate)
            }
        }
        guard let best else { return nil }
        let cellArea = pow(grid.cellWidth * floor.imageWidth * floor.effectiveMetresPerPixel, 2)
        guard best.score >= suggestionMinimumCells, Double(best.score) * cellArea >= suggestionMinimumSquareMetres else { return nil }
        return best.point
    }

    /// Bornes et canaux distincts d'une grille catégorielle, dans l'ordre alphabétique (légende et couleurs).
    public static func categories(_ grid: WifiHeatGrid) -> [String] {
        Array(Set(grid.categories.compactMap { $0 })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Ligne de bilan en mots (rapport, panneau).
    public static func summary(_ analysis: WifiFloorAnalysis) -> String {
        guard analysis.measureCount > 0 else { return "Aucune mesure sur cet étage." }
        func pct(_ value: Double) -> String { String(Int(value.rounded())) + "\u{00A0}%" }
        var text = "\(analysis.measureCount) mesure\(analysis.measureCount > 1 ? "s" : "")\u{00A0}; "
        text += "\(pct(analysis.goodPercent)) de la surface relevée à −67\u{00A0}dBm ou mieux"
        if analysis.deadZones.isEmpty {
            text += ", aucune zone morte"
        } else {
            let n = analysis.deadZones.count
            text += ", \(n) zone\(n > 1 ? "s" : "") morte\(n > 1 ? "s" : "") (\(pct(analysis.deadPercent)))"
        }
        if !analysis.overlaps.isEmpty {
            let n = analysis.overlaps.count
            text += ", chevauchement de canaux à \(n) endroit\(n > 1 ? "s" : "")"
        }
        return text + "."
    }
}
