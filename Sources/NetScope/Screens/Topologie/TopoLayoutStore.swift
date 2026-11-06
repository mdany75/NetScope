import Foundation
import NetScopeCore

/// Note 78 : nœuds de la Carte du réseau déplacés à la main, retenus par site
/// (sites/<id>/carte-disposition.json, inclus dans la sauvegarde). Rien n'est écrit en
/// démonstration ; NETSCOPE_CARTE_DEPLACES=1 y place quelques nœuds à la main (captures).
@MainActor
final class TopoLayoutStore: ObservableObject {
    static let shared = TopoLayoutStore()

    /// Dispositions lues ou modifiées, par clé de site (lues au premier besoin, sans publier).
    private var layouts: [String: TopoManualLayout] = [:]
    private let isDemo: Bool
    private let files: SiteFiles

    init(demo: Bool = Launcher.isDemo, files: SiteFiles = .standard) {
        isDemo = demo
        self.files = files
    }

    /// Note 86 : disposition reçue d'un autre Mac, relue au prochain affichage.
    func forget(_ key: String) {
        layouts[key] = nil
        objectWillChange.send()
    }

    /// Disposition du site (vide : tout est placé automatiquement).
    func layout(for key: String) -> TopoManualLayout {
        if let cached = layouts[key] { return cached }
        let loaded = isDemo ? TopoManualLayout() : TopoManualLayout.load(from: TopoManualLayout.url(in: files.folder(for: key)))
        layouts[key] = loaded
        return loaded
    }

    /// `stack` : piles de la disposition affichée (retenues au premier déplacement).
    func move(_ id: String, to point: CGPoint, siteKey key: String, nodeSize: CGSize, margin: CGFloat, stack: Int) {
        var layout = layout(for: key)
        layout.move(id, to: TopoGraph.Point(x: Double(point.x), y: Double(point.y)),
                    nodeWidth: Double(nodeSize.width), nodeHeight: Double(nodeSize.height), margin: Double(margin), maxStack: stack)
        update(layout, for: key)
    }

    /// Rend un nœud à la disposition automatique.
    func restore(_ id: String, siteKey key: String) {
        var layout = layout(for: key)
        layout.restore(id)
        update(layout, for: key)
    }

    /// « Réinitialiser la disposition » : tous les nœuds du site reprennent leur place calculée.
    func reset(siteKey key: String) {
        update(TopoManualLayout(), for: key)
    }

    /// Démonstration (captures) : positions données d'avance, sans écriture.
    func seedDemo(_ positions: [String: TopoGraph.Point], stack: Int, siteKey key: String) {
        guard isDemo, layout(for: key).isEmpty, !positions.isEmpty else { return }
        update(TopoManualLayout(positions: positions, maxStack: stack, updatedAt: Date()), for: key)
    }

    private func update(_ layout: TopoManualLayout, for key: String) {
        objectWillChange.send()
        layouts[key] = layout
        guard !isDemo else { return }
        let url = TopoManualLayout.url(in: files.folder(for: key))
        do {
            try layout.save(to: url)
        } catch {
            AppLog.shared.error("Carte du réseau", "Disposition du site non enregistrée\u{00A0}: \(error.localizedDescription)")
        }
    }
}
