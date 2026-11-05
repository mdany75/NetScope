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
            AppLog.shared.error("Rapports", "Historique des rapports non enregistré\u{00A0}:\u{00A0}\(error.localizedDescription)")
        }
    }

    // MARK: Rapports passés

    /// Nom de fichier relu du disque, réduit à son dernier composant ; nil : vide, « . » ou « .. ».
    /// Un instantané modifié ou abîmé ne peut ainsi jamais viser un fichier hors de son dossier.
    nonisolated static func safeFileName(_ name: String) -> String? {
        let last = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != ".", last != "..", last != "/" else { return nil }
        return last
    }

    /// Fichier d'un rapport passé ; nil si le nom relu n'est pas un nom de fichier sûr.
    func url(of snapshot: ReportSnapshot) -> URL? {
        guard let name = Self.safeFileName(snapshot.fileName) else { return nil }
        let folder = snapshot.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? directory
        return folder.appendingPathComponent(name)
    }

    func fileExists(_ snapshot: ReportSnapshot) -> Bool {
        isDemo || url(of: snapshot).map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    /// Ouvre le fichier du rapport ; renvoie le message à afficher en cas d'échec.
    func open(_ snapshot: ReportSnapshot) -> String? {
        if isDemo { return "Démonstration\u{00A0}: aucun fichier n’est ouvert." }
        guard let url = url(of: snapshot), FileManager.default.fileExists(atPath: url.path) else {
            return "Fichier introuvable\u{00A0}: \(snapshot.fileName)"
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    func reveal(_ snapshot: ReportSnapshot) -> String? {
        if isDemo { return "Démonstration\u{00A0}: aucun fichier sur le disque." }
        guard let url = url(of: snapshot), FileManager.default.fileExists(atPath: url.path) else {
            return "Fichier introuvable\u{00A0}: \(snapshot.fileName)"
        }
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
        guard let url = url(of: snapshot) else { return "Rapport retiré de la liste (nom de fichier invalide\u{00A0}: aucun fichier touché)." }
        guard FileManager.default.fileExists(atPath: url.path) else { return "Rapport retiré de la liste (fichier déjà absent)." }
        // Le fichier doit être dans le dossier noté pour ce rapport (jamais ailleurs sur le disque).
        let expected = (snapshot.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? directory).standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent().path == expected.path else {
            return "Rapport retiré de la liste (fichier hors du dossier des rapports\u{00A0}: non touché)."
        }
        // Rapport multisite : un seul fichier pour plusieurs instantanés ; il reste tant qu'un autre y renvoie.
        if isShared(snapshot) {
            return "Rapport retiré de la liste de ce site\u{00A0}; le fichier \(snapshot.fileName) reste, car il couvre aussi d’autres sites."
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return "Rapport supprimé\u{00A0}: \(snapshot.fileName) est dans la Corbeille."
        } catch {
            return "Rapport retiré de la liste, mais le fichier n’a pas pu aller à la Corbeille\u{00A0}: \(error.localizedDescription)"
        }
    }

    /// Un autre instantané (tous sites confondus) renvoie-t-il au même fichier ?
    private func isShared(_ snapshot: ReportSnapshot) -> Bool {
        var keys = Set(histories.keys)
        let suivi = ReportHistory.directory(in: directory)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: suivi.path) {
            for name in names where name.hasSuffix(".json") { keys.insert(String(name.dropLast(5))) }
        }
        let folder = snapshot.folder ?? ""
        for key in keys {
            let others = (histories[key] ?? ReportHistory.load(forSite: key, in: directory)).snapshots
            if others.contains(where: { $0.id != snapshot.id && $0.fileName == snapshot.fileName && ($0.folder ?? "") == folder }) {
                return true
            }
        }
        return false
    }

    // MARK: Sites supprimés ou renommés

    /// Site supprimé : son historique de suivi va à la corbeille (instantanés : appareils, IP, MAC).
    func discardSite(_ key: String) {
        histories[key] = nil
        guard !isDemo else { return }
        let url = ReportHistory.url(forSite: key, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            AppLog.shared.error("Rapports", "Historique des rapports de \(key) non retiré\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Plages libres enregistrées comme site : l'historique suit la nouvelle clé (jamais écrasé).
    func renameSite(from old: String, to new: String) {
        histories[old] = nil
        histories[new] = nil
        guard !isDemo else { return }
        let from = ReportHistory.url(forSite: old, in: directory)
        let to = ReportHistory.url(forSite: new, in: directory)
        guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { return }
        do {
            // Les instantanés notent leur site : ils prennent la nouvelle clé.
            let history = ReportHistory(snapshots: ReportHistory.load(forSite: old, in: directory).snapshots.map { snapshot in
                var copy = snapshot
                copy.siteKey = new
                return copy
            })
            try history.save(forSite: new, in: directory)
            try FileManager.default.removeItem(at: from)
        } catch {
            AppLog.shared.error("Rapports", "Historique des rapports non déplacé\u{00A0}: \(error.localizedDescription)")
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
