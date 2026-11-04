import AppKit
import NetScopeCore

/// Mesure les textes du rapport avec les polices réellement dessinées par RapportPageView
/// (`.system` et `.system(design: .monospaced)`), pour que la hauteur des lignes de tableau
/// calculée par `ReportPageMetrics` corresponde au rendu (ni ligne vide, ni texte coupé).
enum RapportTextMeasure {
    static func install() {
        ReportTextMeasurer.installed = ReportTextMeasurer(name: "AppKit") { text, size, mono, bold in
            let weight: NSFont.Weight = bold ? .semibold : .regular
            let font = mono
                ? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight)
                : NSFont.systemFont(ofSize: CGFloat(size), weight: weight)
            return Double((text as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
        }
    }
}
