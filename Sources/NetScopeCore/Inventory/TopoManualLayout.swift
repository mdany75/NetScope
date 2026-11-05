import Foundation

// Note 78 (Carte du réseau) : nœuds déplacés à la main, retenus par site
// (sites/<id>/carte-disposition.json). Les positions sont celles du centre du nœud dans le dessin,
// à 100 % ; les nœuds non déplacés gardent la disposition automatique. Une position d'un nœud
// absent du dessin (filtre, appareil disparu) est gardée pour son retour.

public struct TopoManualLayout: Codable, Equatable, Sendable {
    public static let fileName = "carte-disposition.json"
    public static let currentVersion = 1

    public var version = TopoManualLayout.currentVersion
    /// Centre de chaque nœud déplacé (id du nœud → position).
    public var positions: [String: TopoGraph.Point]
    /// Hauteur des piles de feuilles de la disposition automatique au premier déplacement : les
    /// nœuds non déplacés gardent ensuite leur place, quelle que soit la taille de la fenêtre.
    public var maxStack: Int?
    public var updatedAt: Date?

    public init(positions: [String: TopoGraph.Point] = [:], maxStack: Int? = nil, updatedAt: Date? = nil) {
        self.positions = positions
        self.maxStack = maxStack
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool { positions.isEmpty }

    /// Hauteur des piles à utiliser avec cette disposition (4 par défaut).
    public var stack: Int { min(max(maxStack ?? 4, 1), 12) }

    /// Place un nœud ; la position est arrondie au point et gardée dans le dessin (jamais à gauche
    /// ou au-dessus de la marge). `maxStack` : piles de la disposition affichée, retenues au
    /// premier déplacement.
    public mutating func move(_ id: String, to point: TopoGraph.Point, nodeWidth: Double, nodeHeight: Double,
                              margin: Double = 22, maxStack: Int? = nil, at date: Date = Date()) {
        if positions.isEmpty { self.maxStack = maxStack ?? self.maxStack }
        let x = max(point.x, margin + nodeWidth / 2).rounded()
        let y = max(point.y, margin + nodeHeight / 2).rounded()
        positions[id] = TopoGraph.Point(x: x, y: y)
        updatedAt = date
    }

    /// Rend un nœud à la disposition automatique (la dernière rendue efface aussi les piles retenues).
    public mutating func restore(_ id: String, at date: Date = Date()) {
        guard positions.removeValue(forKey: id) != nil else { return }
        if positions.isEmpty { maxStack = nil }
        updatedAt = date
    }

    /// Nœuds déplacés présents dans ce dessin.
    public func movedCount(in layout: TopoGraph.Layout) -> Int {
        positions.keys.filter { layout.positions[$0] != nil }.count
    }

    // MARK: Fichier

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Lecture tolérante : nil si le fichier est illisible ou d'une version future ; les positions
    /// non finies sont écartées.
    public static func decode(_ data: Data) -> TopoManualLayout? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var layout = try? decoder.decode(TopoManualLayout.self, from: data),
              layout.version <= currentVersion else { return nil }
        layout.positions = layout.positions.filter { $0.value.x.isFinite && $0.value.y.isFinite }
        return layout
    }

    public static func url(in siteFolder: URL) -> URL { siteFolder.appendingPathComponent(fileName) }

    /// Lit la disposition d'un site (vide si absente ou illisible).
    public static func load(from url: URL) -> TopoManualLayout {
        guard let data = try? Data(contentsOf: url) else { return TopoManualLayout() }
        return decode(data) ?? TopoManualLayout()
    }

    /// Écrit la disposition (écriture atomique) ; une disposition vide efface le fichier.
    public func save(to url: URL) throws {
        if isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

public extension TopoGraph.Layout {
    /// Disposition avec les nœuds déplacés à la main : leur position remplace celle calculée, ils ne
    /// sont plus empilés, et le dessin s'agrandit pour les contenir.
    func applying(_ manual: TopoManualLayout, margin: Double = 22) -> TopoGraph.Layout {
        guard !manual.isEmpty else { return self }
        var result = self
        for (id, point) in manual.positions where positions[id] != nil {
            result.positions[id] = point
            result.stacked.remove(id)
            result.moved.insert(id)
        }
        for id in result.moved {
            guard let point = result.positions[id] else { continue }
            result.width = max(result.width, point.x + nodeWidth / 2 + margin)
            result.height = max(result.height, point.y + nodeHeight / 2 + margin)
        }
        return result
    }
}
