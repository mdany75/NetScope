import Foundation

/// Historique du terminal : anneau de taille fixe (10 000 lignes par défaut). Ajouter une ligne
/// quand il est plein retire la plus ancienne en temps constant, même sous un flot de sortie.
public struct TerminalScrollback: Sendable {
    public let capacity: Int
    private var storage: [TerminalLine] = []
    private var head = 0
    /// Lignes retirées depuis l'ouverture (la vue s'en sert pour garder sa position).
    public private(set) var dropped = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public subscript(index: Int) -> TerminalLine {
        storage[(head + index) % storage.count]
    }

    mutating func append(_ line: TerminalLine) {
        if storage.count < capacity {
            storage.append(line)
        } else {
            storage[head] = line
            head = (head + 1) % capacity
            dropped += 1
        }
    }

    /// Retire la ligne la plus récente (agrandissement de la fenêtre : elle revient à l'écran).
    mutating func removeLast() -> TerminalLine? {
        guard !storage.isEmpty else { return nil }
        if head == 0 { return storage.removeLast() }
        // Remise à plat de l'anneau avant le retrait (rare : seulement au redimensionnement).
        storage = Array(storage[head...] + storage[..<head])
        head = 0
        return storage.removeLast()
    }

    mutating func removeAll() {
        dropped += storage.count
        storage.removeAll()
        head = 0
    }
}
