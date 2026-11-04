import Foundation

/// Liste d'étiquettes dans une cellule de tableau (note 8) : combien en afficher dans la largeur
/// disponible, le reste étant résumé par « +N ».
public enum TagOverflow {
    /// Nombre d'étiquettes à afficher.
    /// - `widths` : largeur de chaque étiquette, dans l'ordre.
    /// - `available` : largeur de la cellule.
    /// - `overflowWidth` : largeur de « +N » pour N étiquettes cachées.
    /// Tout tient : toutes. Sinon, le plus grand nombre qui laisse la place à « +N » (0 au besoin).
    public static func visibleCount(widths: [Double], available: Double, spacing: Double,
                                    overflowWidth: (Int) -> Double) -> Int {
        guard !widths.isEmpty else { return 0 }
        if total(widths[...], spacing: spacing) <= available { return widths.count }
        var count = widths.count - 1
        while count > 0 {
            let needed = total(widths.prefix(count), spacing: spacing) + spacing + overflowWidth(widths.count - count)
            if needed <= available { return count }
            count -= 1
        }
        return 0
    }

    private static func total(_ widths: ArraySlice<Double>, spacing: Double) -> Double {
        widths.reduce(0, +) + spacing * Double(max(0, widths.count - 1))
    }
}
