import AppKit
import NetScopeCore
import UniformTypeIdentifiers

/// Bouton « Exporter » du Scanner : format par défaut choisi dans Réglages › Export et sauvegarde.
extension ScanController {
    /// Lignes affichées par le tableau du Scanner (filtres et tri), fournies par l'écran : le menu
    /// Fichier › « Exporter les résultats du scan… » exporte les mêmes lignes que le bouton.
    @MainActor static var displayedRows: (() -> [Device])?

    func export(_ devices: [Device], state: AppState) {
        switch RegPrefs.shared.exportFormat {
        case .csv: exportCSV(devices)
        case .json: exportJSON(devices)
        case .pdf: state.open(.rapports)
        }
    }

    /// « 1 appareil exporté », « 12 appareils exportés ».
    static func exportedLabel(_ count: Int) -> String {
        "\(count) appareil\(count > 1 ? "s" : "") exporté\(count > 1 ? "s" : "")"
    }

    /// Libellé d'aide du bouton.
    static var exportHelp: String {
        switch RegPrefs.shared.exportFormat {
        case .csv: return "Exporter les appareils affichés en CSV (format par défaut, Réglages › Export et sauvegarde)"
        case .json: return "Exporter les appareils affichés en JSON (format par défaut, Réglages › Export et sauvegarde)"
        case .pdf: return "Ouvrir les Rapports pour un PDF mis en page (format par défaut, Réglages › Export et sauvegarde)"
        }
    }

    /// Exporte les appareils en JSON (fenêtre d'enregistrement).
    func exportJSON(_ devices: [Device]) {
        let panel = NSSavePanel()
        panel.title = "Exporter les résultats du scan"
        panel.prompt = "Exporter"
        panel.allowedContentTypes = [.json]
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "NetScope-scan-\(day).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScanJSON.data(devices).write(to: url, options: .atomic)
            show("\(ScanController.exportedLabel(devices.count)) dans \(url.lastPathComponent)")
        } catch {
            show("Export impossible\u{00A0}: \(error.localizedDescription)", tone: .critical)
        }
    }
}
