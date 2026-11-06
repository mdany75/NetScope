import Foundation

// Note 94 : section « Relevé Wi-Fi sur plan » des rapports. L'image de chaque étage (plan, carte de
// chaleur du signal, mesures, bornes) est dessinée par l'application ; le moteur en tire le texte,
// les indicateurs, les zones mortes et les chevauchements de canaux.

/// Un étage du relevé pour le rapport.
public struct ReportFloorSurveyFloor: Sendable {
    public var name: String
    public var image: ReportImage?
    public var analysis: WifiFloorAnalysis
    public var hasScale: Bool
    public var apNames: [String]

    public init(name: String, image: ReportImage?, analysis: WifiFloorAnalysis, hasScale: Bool, apNames: [String]) {
        self.name = name
        self.image = image
        self.analysis = analysis
        self.hasScale = hasScale
        self.apNames = apNames
    }

    /// Étage d'après le relevé (l'image est fournie par l'application).
    public static func make(_ floor: WifiFloor, image: ReportImage?) -> ReportFloorSurveyFloor {
        ReportFloorSurveyFloor(name: floor.name, image: image, analysis: WifiHeatmap.analysis(floor), hasScale: floor.metresPerPixel != nil,
                               apNames: floor.aps.map(\.name))
    }
}

extension ReportBuilder {
    /// Section « Relevé Wi-Fi sur plan » : un bilan, une image et les constats par étage.
    public static func floorSurveyBlocks(_ floors: [ReportFloorSurveyFloor]) -> [ReportBlock] {
        let measured = floors.filter { $0.analysis.measureCount > 0 }
        guard !measured.isEmpty else {
            return [.note("Aucun relevé Wi-Fi sur plan pour ce site\u{00A0}: importer le plan d’un étage (écran Wi-Fi, onglet «\u{00A0}Relevé sur plan\u{00A0}») et prendre des mesures.")]
        }
        let total = measured.reduce(0) { $0 + $1.analysis.measureCount }
        var blocks: [ReportBlock] = [
            .paragraph("Relevé de couverture sur plan\u{00A0}: \(plural(measured.count, "étage", "étages")), \(plural(total, "mesure", "mesures")) prises sur place par ce Mac (signal, bruit, débit du lien, borne et canal captés). La carte de chaleur interpole le signal entre les mesures (jusqu’à \(Int(WifiHeatmap.reachMetres))\u{00A0}m d’une mesure)\u{00A0}; en dessous de −75\u{00A0}dBm, la zone est considérée comme morte."),
        ]
        for floor in measured {
            let a = floor.analysis
            blocks.append(.paragraph("\(floor.name)\u{00A0}: " + WifiHeatmap.summary(a)))
            blocks.append(.kpis([
                ReportKPI("\(a.measureCount)", a.measureCount > 1 ? "mesures" : "mesure"),
                ReportKPI("\(Int(a.goodPercent.rounded()))\u{00A0}%", "à −67\u{00A0}dBm ou mieux", tone: a.goodPercent >= 80 ? .success : .warning),
                ReportKPI("\(a.deadZones.count)", a.deadZones.count > 1 ? "zones mortes" : "zone morte", tone: a.deadZones.isEmpty ? .success : .critical),
                ReportKPI(a.medianRSSI.map { "\($0)\u{00A0}dBm" } ?? "—", "signal médian"),
            ]))
            if let image = floor.image { blocks.append(.image(image)) }
            var notes: [String] = []
            if !floor.hasScale { notes.append("Plan sans échelle\u{00A0}: distances et surfaces estimées (largeur supposée de \(Int(WifiFloor.assumedWidthMetres))\u{00A0}m).") }
            for zone in a.deadZones.prefix(4) {
                notes.append("Zone morte d’environ \(Int(zone.areaSquareMetres.rounded()))\u{00A0}m² (repère sur le plan).")
            }
            for item in WifiHeatmap.distinctOverlaps(a.overlaps).prefix(4) {
                let overlap = item.overlap
                notes.append("Chevauchement de canaux\u{00A0}: canal \(overlap.channel) (\(overlap.band.label)) partagé avec " + overlap.others.joined(separator: ", ")
                             + " (jusqu’à \(overlap.strongestRSSI)\u{00A0}dBm" + (item.places > 1 ? ", à \(item.places) endroits)." : ")."))
            }
            if a.suggestion != nil {
                notes.append("Emplacement suggéré d’une borne ajoutée\u{00A0}: le losange sur le plan, au centre de la plus grande zone faible.")
            }
            blocks += notes.map { .note($0) }
        }
        return blocks
    }
}
