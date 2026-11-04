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
    /// Ramène en vue la ligne de rang `index` (ordre affiché du tableau) à l'arrivée sur l'écran,
    /// puis chaque fois que la ligne choisie change de rang depuis un autre écran.
    func revealRow(_ index: Int?) -> some View {
        background(TableRowRevealer(index: index))
    }
}

private struct TableRowRevealer: NSViewRepresentable {
    let index: Int?

    final class Coordinator {
        var revealed: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let index, context.coordinator.revealed != index else { return }
        context.coordinator.revealed = index
        // Après la mise en page du tableau (ses lignes connues), puis une fois encore quand la
        // sélection demandée arrive un instant après (fiche d'inventaire).
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, let table = Self.table(near: view), index < table.numberOfRows else { return }
                table.scrollRowToVisible(index)
            }
        }
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
