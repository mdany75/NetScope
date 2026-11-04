import Foundation

// Raccourcis clavier des menus de NetScope : combinaison de touches, catalogue des commandes,
// réglages de l'utilisateur (sérialisés), conflits entre eux et avec les raccourcis connus de macOS.
// Sans AppKit : l'application traduit en KeyboardShortcut de SwiftUI.

/// Touches de modification.
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// Symboles dans l'ordre de macOS : ⌃ ⌥ ⇧ ⌘.
    public var symbols: [String] {
        var list: [String] = []
        if contains(.control) { list.append("⌃") }
        if contains(.option) { list.append("⌥") }
        if contains(.shift) { list.append("⇧") }
        if contains(.command) { list.append("⌘") }
        return list
    }
}

/// Une combinaison de touches (« ⇧⌘R »). `key` : un caractère en minuscule (« r », « . », « 1 »)
/// ou un nom de touche spéciale (`KeyCombo.specialKeys`).
public struct KeyCombo: Hashable, Codable, Sendable, CustomStringConvertible {
    public var key: String
    public var modifiers: ShortcutModifiers

    public init(_ key: String, _ modifiers: ShortcutModifiers = .command) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    /// Touches spéciales reconnues, avec leur symbole.
    public static let specialKeys: [String: String] = [
        "return": "↩", "escape": "⎋", "delete": "⌫", "forwardDelete": "⌦", "tab": "⇥", "space": "Espace",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6",
        "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]

    public var isFunctionKey: Bool { key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// Symbole de la touche (« R », « , », « ↩ »).
    public var keySymbol: String {
        if let special = KeyCombo.specialKeys[key] { return special }
        return key.uppercased()
    }

    /// Une case par touche, comme le croquis (« ⇧ », « ⌘ », « R »).
    public var displayParts: [String] { modifiers.symbols + [keySymbol] }

    /// « ⇧⌘R »
    public var display: String { displayParts.joined() }

    public var description: String { display }

    /// Forme enregistrée, stable et lisible : « cmd+shift+r », « ctrl+opt+f5 », « cmd+, ».
    public var serialized: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Relit `serialized` ; nil si la forme est invalide.
    public init?(serialized text: String) {
        guard !text.isEmpty else { return nil }
        var modifiers: ShortcutModifiers = []
        var rest = Substring(text)
        // La touche peut elle-même être « + » (« cmd++ ») : on lit les préfixes de modification.
        let names: [(String, ShortcutModifiers)] = [("ctrl+", .control), ("opt+", .option), ("shift+", .shift), ("cmd+", .command)]
        var progressed = true
        while progressed {
            progressed = false
            for (name, flag) in names where rest.hasPrefix(name) && rest.count > name.count {
                modifiers.insert(flag)
                rest = rest.dropFirst(name.count)
                progressed = true
            }
        }
        let key = String(rest)
        guard key.count == 1 || KeyCombo.specialKeys[key] != nil else { return nil }
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.controlCharacters.contains(scalar) { return nil }
        self.init(key, modifiers)
    }

    /// Raison pour laquelle la combinaison ne peut pas servir de raccourci de menu (nil : valide).
    public var problem: String? {
        if isFunctionKey { return nil }
        if modifiers.isDisjoint(with: [.command, .control, .option]) {
            return "Ajoutez ⌘, ⌃ ou ⌥\u{00A0}: une touche seule (ou avec ⇧) gênerait la saisie."
        }
        return nil
    }

    // Codable sous la forme `serialized`.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let combo = KeyCombo(serialized: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Raccourci invalide\u{00A0}: \(text)"))
        }
        self = combo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serialized)
    }

    /// Touche d'un événement clavier : code de touche (kVK_…) pour les touches spéciales, sinon le
    /// caractère produit sans modification. nil : touche de modification seule ou inconnue.
    public static func key(keyCode: UInt16, characters: String?) -> String? {
        let special: [UInt16: String] = [
            36: "return", 76: "return", 53: "escape", 51: "delete", 117: "forwardDelete", 48: "tab", 49: "space",
            126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
            101: "f9", 109: "f10", 103: "f11", 111: "f12",
        ]
        if let name = special[keyCode] { return name }
        guard let characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              // Touches de fonction d'AppKit (zone privée U+F700…U+F8FF) non listées ci-dessus.
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return characters.lowercased()
    }
}

/// Groupes de la liste des raccourcis (ordre du croquis).
public enum ShortcutGroup: String, CaseIterable, Sendable, Identifiable {
    case scan, selection, navigation, screens

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scan: return "Scan"
        case .selection: return "Sélection"
        case .navigation: return "Navigation"
        case .screens: return "Écrans"
        }
    }
}

/// Une commande des menus qui peut avoir un raccourci.
public struct ShortcutAction: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var group: ShortcutGroup
    public var defaultCombo: KeyCombo?

    public init(id: String, title: String, group: ShortcutGroup, defaultCombo: KeyCombo?) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultCombo = defaultCombo
    }
}

/// Identifiants des commandes fixes (ceux des écrans : `ShortcutCatalog.screenID`).
public enum ShortcutID {
    public static let startScan = "scan.lancer"
    public static let stopScan = "scan.arreter"
    public static let newScan = "scan.nouveau"
    public static let rescanSelection = "scan.rescannerSelection"
    public static let nextProfile = "scan.profilSuivant"
    public static let ping = "selection.ping"
    public static let openDevice = "selection.fiche"
    public static let copyIP = "selection.copierIP"
    public static let copyMAC = "selection.copierMAC"
    public static let openBrowser = "selection.navigateur"
    public static let search = "navigation.rechercher"
    public static let export = "navigation.exporter"
    public static let settings = "navigation.reglages"
    /// Retour / Avancer entre les écrans (note 34).
    public static let back = "navigation.retour"
    public static let forward = "navigation.avancer"
    /// Choisir le site actif (note 49) : sélecteur sous le logo NetScope.
    public static let chooseSite = "navigation.site"
}

/// Catalogue des commandes et raccourcis par défaut (croquis Reglages.dc.html, section Raccourcis).
public enum ShortcutCatalog {
    public static let fixedActions: [ShortcutAction] = [
        ShortcutAction(id: ShortcutID.startScan, title: "Lancer le scan", group: .scan, defaultCombo: KeyCombo("r")),
        ShortcutAction(id: ShortcutID.stopScan, title: "Arrêter le scan", group: .scan, defaultCombo: KeyCombo(".")),
        ShortcutAction(id: ShortcutID.newScan, title: "Nouveau scan (effacer et relancer)", group: .scan, defaultCombo: KeyCombo("n")),
        ShortcutAction(id: ShortcutID.rescanSelection, title: "Rescanner les ports de la sélection", group: .scan,
                       defaultCombo: KeyCombo("r", [.shift, .command])),
        ShortcutAction(id: ShortcutID.nextProfile, title: "Changer de profil", group: .scan, defaultCombo: KeyCombo("p", [.option, .command])),
        ShortcutAction(id: ShortcutID.ping, title: "Ping continu de l’appareil choisi", group: .selection, defaultCombo: KeyCombo("p")),
        ShortcutAction(id: ShortcutID.openDevice, title: "Ouvrir la fiche appareil", group: .selection, defaultCombo: KeyCombo("i")),
        ShortcutAction(id: ShortcutID.copyIP, title: "Copier l’IP", group: .selection, defaultCombo: KeyCombo("c", [.shift, .command])),
        ShortcutAction(id: ShortcutID.copyMAC, title: "Copier la MAC", group: .selection, defaultCombo: KeyCombo("m", [.shift, .command])),
        ShortcutAction(id: ShortcutID.openBrowser, title: "Ouvrir dans le navigateur", group: .selection, defaultCombo: KeyCombo("o")),
        ShortcutAction(id: ShortcutID.search, title: "Rechercher partout", group: .navigation, defaultCombo: KeyCombo("f")),
        ShortcutAction(id: ShortcutID.export, title: "Exporter les résultats", group: .navigation, defaultCombo: KeyCombo("e")),
        ShortcutAction(id: ShortcutID.settings, title: "Réglages", group: .navigation, defaultCombo: KeyCombo(",")),
        ShortcutAction(id: ShortcutID.back, title: "Retour à l’écran précédent", group: .navigation, defaultCombo: KeyCombo("[")),
        ShortcutAction(id: ShortcutID.forward, title: "Avancer", group: .navigation, defaultCombo: KeyCombo("]")),
        ShortcutAction(id: ShortcutID.chooseSite, title: "Choisir le site", group: .navigation,
                       defaultCombo: KeyCombo("s", [.shift, .command])),
    ]

    public static func screenID(_ screen: String) -> String { "ecran." + screen }

    /// Une commande « Aller à » par écran (identifiant, titre), ⌘1 à ⌘9 pour les neuf premiers.
    public static func screenActions(_ screens: [(id: String, title: String)]) -> [ShortcutAction] {
        screens.enumerated().map { index, screen in
            ShortcutAction(id: screenID(screen.id), title: screen.title, group: .screens,
                           defaultCombo: index < 9 ? KeyCombo(String(index + 1)) : nil)
        }
    }

    /// Raccourcis connus de macOS et des menus standard (Application, Édition, Fenêtre) : un
    /// raccourci de NetScope identique serait ignoré ou masquerait le leur.
    public static let systemReserved: [KeyCombo: String] = [
        KeyCombo("q"): "Quitter NetScope",
        KeyCombo("h"): "Masquer NetScope",
        KeyCombo("h", [.option, .command]): "Masquer les autres",
        KeyCombo("w"): "Fermer la fenêtre",
        KeyCombo("m"): "Placer dans le Dock",
        KeyCombo("c"): "Copier",
        KeyCombo("v"): "Coller",
        KeyCombo("x"): "Couper",
        KeyCombo("a"): "Tout sélectionner",
        KeyCombo("z"): "Annuler",
        KeyCombo("z", [.shift, .command]): "Rétablir",
        KeyCombo("v", [.option, .shift, .command]): "Coller et adapter le style",
        KeyCombo("`"): "Fenêtre suivante",
        KeyCombo("tab"): "Changer d’application",
        KeyCombo("space"): "Spotlight",
        KeyCombo("space", [.option, .command]): "Fenêtre de recherche du Finder",
        KeyCombo("space", [.control]): "Source de saisie précédente",
        KeyCombo("space", [.control, .command]): "Emoji et symboles",
        KeyCombo("q", [.control, .command]): "Verrouiller l’écran",
        KeyCombo("q", [.shift, .command]): "Fermer la session",
        KeyCombo("escape", [.option, .command]): "Forcer à quitter",
        KeyCombo("3", [.shift, .command]): "Capture de l’écran",
        KeyCombo("4", [.shift, .command]): "Capture d’une zone",
        KeyCombo("5", [.shift, .command]): "Outil Capture d’écran",
        KeyCombo("6", [.shift, .command]): "Capture de la Touch Bar",
        KeyCombo("f", [.control, .command]): "Plein écran",
        KeyCombo("d", [.option, .command]): "Afficher ou masquer le Dock",
        KeyCombo("/", [.shift, .command]): "Aide",
        KeyCombo("up", [.control]): "Mission Control",
        KeyCombo("down", [.control]): "Fenêtres de l’application",
        KeyCombo("left", [.control]): "Bureau précédent",
        KeyCombo("right", [.control]): "Bureau suivant",
        KeyCombo("s", [.control, .command]): "Afficher la barre latérale",
    ]
}

/// Conflit d'un raccourci.
public enum ShortcutConflict: Hashable, Sendable {
    /// Même combinaison qu'une autre commande de NetScope (son identifiant).
    case duplicate(String)
    /// Combinaison réservée par macOS ou un menu standard (son nom).
    case system(String)
}

/// Raccourcis choisis par l'utilisateur : seulement les écarts aux valeurs par défaut.
/// `nil` dans `overrides` : aucun raccourci pour cette commande.
public struct ShortcutSettings: Equatable, Sendable {
    public private(set) var overrides: [String: KeyCombo?] = [:]

    public init(overrides: [String: KeyCombo?] = [:]) {
        self.overrides = overrides
    }

    /// Raccourci en vigueur d'une commande.
    public func combo(for action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action.id] { return override }
        return action.defaultCombo
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        guard let override = overrides[action.id] else { return false }
        return override != action.defaultCombo
    }

    /// Fixe le raccourci (nil : aucun) ; la valeur par défaut efface l'écart.
    public mutating func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if combo == action.defaultCombo {
            overrides.removeValue(forKey: action.id)
        } else {
            overrides[action.id] = .some(combo)
        }
    }

    public mutating func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action.id)
    }

    public mutating func resetAll() {
        overrides = [:]
    }

    public var customizedCount: Int { overrides.count }

    /// Conflits de chaque commande (identifiant → conflits), pour les commandes données.
    public func conflicts(in actions: [ShortcutAction],
                          reserved: [KeyCombo: String] = ShortcutCatalog.systemReserved) -> [String: [ShortcutConflict]] {
        var byCombo: [KeyCombo: [String]] = [:]
        for action in actions {
            if let combo = combo(for: action) { byCombo[combo, default: []].append(action.id) }
        }
        var result: [String: [ShortcutConflict]] = [:]
        for action in actions {
            guard let combo = combo(for: action) else { continue }
            var list: [ShortcutConflict] = []
            for other in byCombo[combo] ?? [] where other != action.id { list.append(.duplicate(other)) }
            if let name = reserved[combo] { list.append(.system(name)) }
            if !list.isEmpty { result[action.id] = list }
        }
        return result
    }

    /// Commande qui a déjà cette combinaison (autre que `action`), pour l'avertissement de l'enregistreur.
    public func owner(of combo: KeyCombo, among actions: [ShortcutAction], excluding action: ShortcutAction? = nil) -> ShortcutAction? {
        actions.first { $0.id != action?.id && self.combo(for: $0) == combo }
    }

    // MARK: Sérialisation : { "scan.lancer": "cmd+shift+l", "selection.navigateur": "" }

    public func encoded() -> Data {
        var map: [String: String] = [:]
        for (id, combo) in overrides { map[id] = combo?.serialized ?? "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(map)) ?? Data()
    }

    /// Relit `encoded()` ; les entrées invalides sont ignorées.
    public static func decoded(_ data: Data?) -> ShortcutSettings {
        guard let data, let map = try? JSONDecoder().decode([String: String].self, from: data) else { return ShortcutSettings() }
        var settings = ShortcutSettings()
        for (id, text) in map {
            if text.isEmpty {
                settings.overrides[id] = .some(nil)
            } else if let combo = KeyCombo(serialized: text) {
                settings.overrides[id] = .some(combo)
            }
        }
        return settings
    }
}
