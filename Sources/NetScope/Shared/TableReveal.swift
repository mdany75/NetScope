import AppKit
import SwiftUI

// Note 45 (0.15.0) : au retour sur un écran (Retour ⌘[, Avancer, clic dans la barre latérale),
// la liste revient à la même position : la ligne choisie est ramenée en vue, sans déplacer la
// liste si elle est déjà visible. Les écrans sont recréés à chaque changement (ContentView
// `.id(state.screen)`) : l'arrivée sur l'écran suffit à déclencher le défilement.
//
// Un `Table` de SwiftUI ne répond pas à `ScrollViewReader` sur macOS : on demande au tableau AppKit
// sous-jacent (NSTableView) de montrer la ligne, par son rang dans l'ordre affiché.

extension View {
    /// Ramène en vue la ligne choisie (`id`) à l'arrivée sur l'écran, puis seulement quand
    /// l'IDENTIFIANT choisi change : un scan en direct, un tri ou un filtre qui décale son rang ne
    /// fait jamais défiler le tableau de force. `index` donne son rang dans l'ordre affiché ; il
    /// est recalculé au moment du défilement (les lignes ont pu changer entre-temps).
    func revealRow<ID: Hashable>(id: ID?, index: @escaping () -> Int?) -> some View {
        background(TableRowRevealer(id: id.map(AnyHashable.init), index: index))
    }
}

private struct TableRowRevealer: NSViewRepresentable {
    let id: AnyHashable?
    let index: () -> Int?

    final class Coordinator {
        var revealed: AnyHashable?
        /// Dernier calcul du rang (lignes de la dernière mise à jour de la vue).
        var index: () -> Int? = { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.index = index
        guard let id, coordinator.revealed != id else { return }
        coordinator.revealed = id
        // Après la mise en page du tableau (ses lignes connues), puis une fois encore quand la
        // sélection demandée arrive un instant après (fiche d'inventaire).
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view, weak coordinator] in
                guard let view, let coordinator, coordinator.revealed == id,
                      let index = coordinator.index(), let table = Self.table(near: view), index < table.numberOfRows else { return }
                table.scrollRowToVisible(index)
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.revealed = nil
    }
    /// Le tableau le plus proche : le premier NSTableView sous l'ancêtre commun le plus proche.
    private static func table(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        for _ in 0..<8 {
            guard let current = ancestor else { return nil }
            if let found = firstTable(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTable(in: subview) { return found }
        }
        return nil
    }
}
