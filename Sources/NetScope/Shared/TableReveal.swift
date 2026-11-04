import SwiftUI

// Note 45 (0.15.0) : au retour sur un écran (Retour ⌘[, Avancer, clic dans la barre latérale),
// la liste revient à la même position : la ligne choisie est ramenée en vue, sans déplacer la
// liste si elle est déjà visible. Les écrans sont recréés à chaque changement (ContentView
// `.id(state.screen)`) : l'arrivée sur l'écran suffit à déclencher le défilement.

extension View {
    /// Ramène la ligne `id` en vue quand le tableau apparaît (et quand `id` change d'écran à écran).
    func revealSelection<ID: Hashable>(_ id: ID?) -> some View {
        modifier(RevealSelection(id: id))
    }
}

private struct RevealSelection<ID: Hashable>: ViewModifier {
    let id: ID?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onAppear {
                guard let id else { return }
                // Après la première mise en page du tableau (lignes connues), puis une fois de plus
                // quand la sélection demandée arrive un instant après (fiche d'inventaire).
                DispatchQueue.main.async { proxy.scrollTo(id) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(id) }
            }
        }
    }
}
