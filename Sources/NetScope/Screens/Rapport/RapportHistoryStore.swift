import AppKit
import Foundation
import NetScopeCore

/// Note 42 : rapports passés de chaque site et base de la section « Depuis le dernier rapport ».
/// Chaque rapport produit (à la main ou planifié) laisse un instantané léger de son site dans
/// rapports/suivi/<clé du site>.json. En démonstration, l'historique vient de RapportSuiviDemo et
/// rien n'est lu ni écrit sur le disque.
@MainActor
final class RapportHistoryStore: ObservableObject {
    static let shared = RapportHistoryStore()

    /// Base de comparaison choisie dans les Rapports (rapports produits à la main).
    @Published var base: ReportFollowUpBase = .last
    @Published private(set) var histories: [String: ReportHistory] = [:]

    let isDemo: Bool
    private var directory: URL { RapportModel.shared.directory }

    init(demo: Bool = Launcher.isDemo) {
        isDemo = demo
    }

    /// Historique d'un site (lu une fois, puis gardé en mémoire).
    func history(forKey key: String, current: ReportSnapshot? = nil) -> ReportHistory {
        if let cached = histories[key] { return cached }
        let loaded: ReportHistory
        if isDemo {
            loaded = RapportSuiviDemo.history(forKey: key, current: current)
            // Sans l'état actuel, la démonstration ne connaît que la liste (mêmes identifiants) :
            // elle n'est gardée qu'une fois bâtie d'après l'état actuel.
            if current == nil { return loaded }
        } else {
            loaded = ReportHistory.load(forSite: key, in: directory)
        }
        // Lecture pendant le rendu : la mise en cache ne doit pas republier dans la même passe.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.histories[key] == nil else { return }
            self.histories[key] = loaded
        }
        return loaded
    }

    /// Comparaison de l'état décrit par `input` avec la base choisie (ou `choice`).
    func followUp(forKey key: String, siteName: String, input: ReportInput, choice: ReportFollowUpBase? = nil) -> ReportFollowUpResult {
        let current = ReportSnapshot.make(input: input, siteKey: key, siteName: siteName, created: input.now,
                                          reportDate: ReportText.isoDay(input.now), title: "", fileName: "")
        let history = history(forKey: key, current: current)
        return ReportFollowUp.result(history: history.snapshots, choice: choice ?? base, current: current)
    }

    // MARK: Enregistrement

    /// Garde l'instantané d'un rapport qui vient d'être produit.
    func record(_ snapshot: ReportSnapshot) {
        var history = histories[snapshot.siteKey] ?? history(forKey: snapshot.siteKey)
        history.add(snapshot)
        histories[snapshot.siteKey] = history
        // Le rapport suivant se compare à celui-ci.
        if case .report = base { base = .last }
        guard !isDemo else { return }
        do {
            try history.save(forSite: snapshot.siteKey, in: directory)
        } catch {
            NSLog("NetScope\u{00A0}: historique des rapports non enregistré\u{00A0}:\u{00A0}%@", error.localizedDescription)
        }
    }

    // MARK: Rapports passés

    func url(of snapshot: ReportSnapshot) -> URL {
        let folder = snapshot.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? directory
        return folder.appendingPathComponent(snapshot.fileName)
    }

    func fileExists(_ snapshot: ReportSnapshot) -> Bool {
        isDemo || FileManager.default.fileExists(atPath: url(of: snapshot).path)
    }

    /// Ouvre le fichier du rapport ; renvoie le message à afficher en cas d'échec.
    func open(_ snapshot: ReportSnapshot) -> String? {
        if isDemo { return "Démonstration\u{00A0}: aucun fichier n’est ouvert." }
        let url = url(of: snapshot)
        guard FileManager.default.fileExists(atPath: url.path) else { return "Fichier introuvable\u{00A0}: \(snapshot.fileName)" }
        NSWorkspace.shared.open(url)
        return nil
    }

    func reveal(_ snapshot: ReportSnapshot) -> String? {
        if isDemo { return "Démonstration\u{00A0}: aucun fichier sur le disque." }
        let url = url(of: snapshot)
        guard FileManager.default.fileExists(atPath: url.path) else { return "Fichier introuvable\u{00A0}: \(snapshot.fileName)" }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return nil
    }

    /// Supprime un rapport passé : son fichier va dans la Corbeille (récupérable) et son instantané
    /// est oublié. Renvoie le message à afficher.
    func delete(_ snapshot: ReportSnapshot) -> String {
        var history = histories[snapshot.siteKey] ?? history(forKey: snapshot.siteKey)
        history.remove(snapshot.id)
        histories[snapshot.siteKey] = history
        if case .report(let id) = base, id == snapshot.id { base = .last }
        RapportModel.shared.forgetRecent(fileName: snapshot.fileName)
        guard !isDemo else { return "Rapport retiré de la liste (démonstration\u{00A0}: aucun fichier touché)." }
        try? history.save(forSite: snapshot.siteKey, in: directory)
        let url = url(of: snapshot)
        guard FileManager.default.fileExists(atPath: url.path) else { return "Rapport retiré de la liste (fichier déjà absent)." }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return "Rapport supprimé\u{00A0}: \(snapshot.fileName) est dans la Corbeille."
        } catch {
            return "Rapport retiré de la liste, mais le fichier n’a pas pu aller à la Corbeille\u{00A0}: \(error.localizedDescription)"
        }
    }

    // MARK: Libellés

    /// « Dernier rapport · 6 oct. 2026 », « Rapport du 2026-09-22 », « Au plus tard le 2026-10-01 ».
    func baseLabel(forKey key: String) -> String {
        let snapshots = histories[key]?.snapshots ?? history(forKey: key).snapshots
        switch base {
        case .last:
            guard let last = snapshots.first else { return "Dernier rapport (aucun)" }
            return "Dernier rapport · \(last.reportDate)"
        case .report(let id):
            guard let chosen = snapshots.first(where: { $0.id == id }) else { return "Dernier rapport" }
            return "Rapport du \(chosen.reportDate)"
        case .date(let day):
            return "Au plus tard le \(day)"
        }
    }
}
