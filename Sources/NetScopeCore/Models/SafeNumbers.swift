import Foundation

// Conversions Double → Int sans plantage. `Int(x)` arrête l'application quand x est infini, NaN
// ou hors des limites d'Int (plantage de la 0.8.0 : un débit de lien invalide donnait un
// pourcentage infini dans le bilan d'un partage réseau). Toute valeur venue d'une mesure
// (débit, latence, durée, pourcentage) passe par ici avant d'être convertie en entier.

public extension Double {
    /// Entier arrondi au plus proche ; NaN donne 0, l'infini et les valeurs hors limites sont
    /// ramenés à Int.min ou Int.max.
    var clampedInt: Int {
        guard !isNaN else { return 0 }
        let rounded = self.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    /// La valeur si elle est finie, sinon nil.
    var finiteOrNil: Double? { isFinite ? self : nil }
}
