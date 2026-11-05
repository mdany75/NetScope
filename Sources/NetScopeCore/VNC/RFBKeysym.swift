import Foundation

/// Codes de touches X11 (« keysyms », RFC 6143 § 7.5.4) et correspondance avec le clavier du Mac.
public enum RFBKeysym {
    public static let backSpace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let insert: UInt32 = 0xFF63
    public static let delete: UInt32 = 0xFFFF
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let f1: UInt32 = 0xFFBE
    public static let shiftLeft: UInt32 = 0xFFE1
    public static let shiftRight: UInt32 = 0xFFE2
    public static let controlLeft: UInt32 = 0xFFE3
    public static let controlRight: UInt32 = 0xFFE4
    public static let capsLock: UInt32 = 0xFFE5
    public static let metaLeft: UInt32 = 0xFFE7
    public static let altLeft: UInt32 = 0xFFE9
    public static let altRight: UInt32 = 0xFFEA
    /// Touche Windows sur un PC, Commande sur un Mac.
    public static let superLeft: UInt32 = 0xFFEB
    public static let superRight: UInt32 = 0xFFEC
    public static let keypadEnter: UInt32 = 0xFF8D
    public static let numLock: UInt32 = 0xFF7F
    public static let printScreen: UInt32 = 0xFF61

    /// Ctrl-Alt-Suppr (ouverture de session Windows, gestionnaire des tâches).
    public static let ctrlAltDelete: [UInt32] = [controlLeft, altLeft, delete]

    /// F1 à F20 (n de 1 à 20).
    public static func function(_ n: Int) -> UInt32 { f1 + UInt32(max(1, min(20, n)) - 1) }

    /// Touches spéciales selon le code de touche virtuel du Mac (kVK_… de Carbon, indépendant de la
    /// disposition du clavier).
    public static let macKeyCodes: [UInt16: UInt32] = [
        0x24: returnKey, 0x30: tab, 0x33: backSpace, 0x35: escape, 0x75: delete, 0x72: insert,
        0x73: home, 0x77: end, 0x74: pageUp, 0x79: pageDown,
        0x7B: left, 0x7C: right, 0x7D: down, 0x7E: up,
        0x4C: keypadEnter, 0x47: numLock,
        0x7A: function(1), 0x78: function(2), 0x63: function(3), 0x76: function(4), 0x60: function(5),
        0x61: function(6), 0x62: function(7), 0x64: function(8), 0x65: function(9), 0x6D: function(10),
        0x67: function(11), 0x6F: function(12), 0x69: function(13), 0x6B: function(14), 0x71: function(15),
        0x6A: function(16), 0x40: function(17), 0x4F: function(18), 0x50: function(19), 0x5A: function(20),
        // Pavé numérique : chiffres et opérateurs X11 du pavé.
        0x52: 0xFFB0, 0x53: 0xFFB1, 0x54: 0xFFB2, 0x55: 0xFFB3, 0x56: 0xFFB4, 0x57: 0xFFB5,
        0x58: 0xFFB6, 0x59: 0xFFB7, 0x5B: 0xFFB8, 0x5C: 0xFFB9, 0x41: 0xFFAE, 0x43: 0xFFAA,
        0x45: 0xFFAB, 0x4E: 0xFFAD, 0x4B: 0xFFAF, 0x51: 0xFFBD,
    ]

    /// Touches de modification selon le code de touche virtuel du Mac.
    public static let macModifierKeyCodes: [UInt16: UInt32] = [
        0x38: shiftLeft, 0x3C: shiftRight, 0x3B: controlLeft, 0x3E: controlRight,
        0x3A: altLeft, 0x3D: altRight, 0x37: superLeft, 0x36: superRight, 0x39: capsLock,
    ]

    /// Keysym d'un caractère : Latin-1 tel quel, le reste en 0x01000000 + point de code Unicode.
    public static func character(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0D, 0x0A: return returnKey
        case 0x09: return tab
        case 0x1B: return escape
        case 0x08, 0x7F: return backSpace
        case 0x20...0x7E, 0xA0...0xFF: return scalar.value
        default: return 0x0100_0000 + scalar.value
        }
    }

    /// Keysym d'une frappe : touche spéciale d'abord, sinon le caractère produit (sans Ctrl ni
    /// Option, mais avec Maj : « A » majuscule, comme le veut X11).
    public static func forMacKey(keyCode: UInt16, characters: String?) -> UInt32? {
        if let special = macKeyCodes[keyCode] { return special }
        guard let scalar = characters?.unicodeScalars.first else { return nil }
        // Touches de fonction de AppKit (0xF700…) sans correspondance : ignorées.
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return character(scalar)
    }
}
