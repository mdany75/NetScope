import Foundation

// Note 61 : tracé des liens de la Carte du réseau, commun au dessin à l'écran (TopoCanvas) et aux
// exports (SVG, draw.io, rapports). Coordonnées du dessin à 100 %, centre des nœuds.

/// Morceau d'un tracé : départ, segment droit, courbe quadratique ou cubique.
public enum TopoPathSegment: Hashable, Sendable {
    case move(TopoGraph.Point)
    case line(TopoGraph.Point)
    case quad(TopoGraph.Point, control: TopoGraph.Point)
    case cubic(TopoGraph.Point, control1: TopoGraph.Point, control2: TopoGraph.Point)

    /// Point d'arrivée du morceau.
    public var end: TopoGraph.Point {
        switch self {
        case .move(let point), .line(let point), .quad(let point, _), .cubic(let point, _, _): return point
        }
    }
}

public enum TopoGeometry {
    /// Ordonnée du palier horizontal entre un parent et ses enfants.
    public static func busY(parent: TopoGraph.Point, nodeHeight: Double) -> Double {
        parent.y + nodeHeight / 2 + 24
    }

    /// Lien de la hiérarchie : en équerre, du bas du parent jusqu'au haut de l'enfant ; pour une
    /// feuille empilée, par un rail à gauche de sa colonne jusqu'à son flanc gauche. `free` : un des
    /// deux nœuds est placé à la main (courbe du bas du parent au haut de l'enfant).
    public static func treePath(parent: TopoGraph.Point, child: TopoGraph.Point, free: Bool, stacked: Bool,
                                nodeWidth: Double, nodeHeight: Double) -> [TopoPathSegment] {
        let start = TopoGraph.Point(x: parent.x, y: parent.y + nodeHeight / 2)
        if free {
            let end = TopoGraph.Point(x: child.x, y: child.y - nodeHeight / 2)
            let bend = max(abs(end.y - start.y) / 2, 40)
            return [.move(start), .cubic(end, control1: TopoGraph.Point(x: start.x, y: start.y + bend),
                                         control2: TopoGraph.Point(x: end.x, y: end.y - bend))]
        }
        let bus = busY(parent: parent, nodeHeight: nodeHeight)
        if stacked {
            let rail = child.x - nodeWidth / 2 - 12
            return [.move(start), .line(TopoGraph.Point(x: start.x, y: bus)), .line(TopoGraph.Point(x: rail, y: bus)),
                    .line(TopoGraph.Point(x: rail, y: child.y)), .line(TopoGraph.Point(x: child.x - nodeWidth / 2, y: child.y))]
        }
        let end = TopoGraph.Point(x: child.x, y: child.y - nodeHeight / 2)
        return [.move(start), .line(TopoGraph.Point(x: start.x, y: bus)), .line(TopoGraph.Point(x: end.x, y: bus)), .line(end)]
    }

    /// Étiquette de port d'un lien de la hiérarchie : sur la descente vers l'enfant, au-dessus d'une
    /// feuille empilée, ou sur la fin de la courbe d'un nœud placé à la main.
    public static func treeLabel(parent: TopoGraph.Point, child: TopoGraph.Point, free: Bool, stacked: Bool,
                                 nodeWidth: Double, nodeHeight: Double) -> TopoGraph.Point {
        let top = child.y - nodeHeight / 2
        if free {
            // Juste au-dessus de l'enfant (la courbe y arrive à la verticale) : les étiquettes de deux
            // enfants voisins ne se chevauchent pas.
            let gap = top - (parent.y + nodeHeight / 2)
            return TopoGraph.Point(x: child.x, y: top - min(max(gap / 2, 11), 16))
        }
        if stacked { return TopoGraph.Point(x: child.x + nodeWidth / 2 - 30, y: top - 9) }
        return TopoGraph.Point(x: child.x, y: (busY(parent: parent, nodeHeight: nodeHeight) + top) / 2)
    }

    /// Courbe d'un lien redondant. Deux nœuds sur la même rangée (switchs voisins d'un anneau) : arc
    /// sous eux, du bas de l'un au bas de l'autre. Sinon : courbe entre les centres, bombée sur le côté.
    public static func redundantCurve(_ a: TopoGraph.Point, _ b: TopoGraph.Point, nodeWidth: Double,
                                      nodeHeight: Double) -> (start: TopoGraph.Point, control: TopoGraph.Point, end: TopoGraph.Point) {
        if abs(a.y - b.y) < nodeHeight {
            let (left, right) = a.x <= b.x ? (a, b) : (b, a)
            let bottom = max(left.y, right.y) + nodeHeight / 2
            let inset = nodeWidth / 4
            let start = TopoGraph.Point(x: left.x + inset, y: left.y + nodeHeight / 2)
            let end = TopoGraph.Point(x: right.x - inset, y: right.y + nodeHeight / 2)
            return (start, TopoGraph.Point(x: (start.x + end.x) / 2, y: bottom + 30), end)
        }
        let mid = TopoGraph.Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let bulge = min(90, max(50, length * 0.3))
        return (a, TopoGraph.Point(x: mid.x - dy / length * bulge, y: mid.y + dx / length * bulge), b)
    }

    /// Milieu de la courbe d'un lien redondant (étiquette des ports).
    public static func redundantMidpoint(_ curve: (start: TopoGraph.Point, control: TopoGraph.Point, end: TopoGraph.Point)) -> TopoGraph.Point {
        TopoGraph.Point(x: 0.25 * curve.start.x + 0.5 * curve.control.x + 0.25 * curve.end.x,
                        y: 0.25 * curve.start.y + 0.5 * curve.control.y + 0.25 * curve.end.y)
    }
}
