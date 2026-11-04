import Foundation

/// Historique Retour / Avancer (⌘[ et ⌘]), comme un navigateur : aller ailleurs empile l'endroit
/// quitté et efface la pile « Avancer » ; Retour rend l'endroit précédent et garde l'actuel pour
/// Avancer. La pile est bornée (`limit`) : les plus anciens endroits tombent en premier.
public struct NavHistory: Hashable, Sendable {
    public private(set) var back: [NavLocation] = []
    public private(set) var forward: [NavLocation] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Endroit où mène Retour (bulle d'aide « Retour à Carte du réseau »).
    public var previous: NavLocation? { back.last }
    public var next: NavLocation? { forward.first }

    /// On quitte `location` pour aller ailleurs (`to`) : il est empilé, et la pile Avancer est vidée.
    /// Rien n'est empilé si l'on ne bouge pas (même endroit), ni deux fois de suite le même endroit.
    public mutating func leave(_ location: NavLocation, to destination: NavLocation? = nil) {
        if let destination, destination == location { return }
        forward.removeAll()
        if back.last == location { return }
        back.append(location)
        if back.count > limit { back.removeFirst(back.count - limit) }
    }

    /// Retour : rend l'endroit précédent ; `current` passe en tête de la pile Avancer.
    public mutating func goBack(from current: NavLocation) -> NavLocation? {
        guard let previous = back.popLast() else { return nil }
        forward.insert(current, at: 0)
        if forward.count > limit { forward.removeLast(forward.count - limit) }
        return previous
    }

    /// Avancer : rend l'endroit suivant ; `current` repasse sur la pile Retour.
    public mutating func goForward(from current: NavLocation) -> NavLocation? {
        guard !forward.isEmpty else { return nil }
        let next = forward.removeFirst()
        back.append(current)
        if back.count > limit { back.removeFirst(back.count - limit) }
        return next
    }

    public mutating func clear() {
        back.removeAll()
        forward.removeAll()
    }
}
