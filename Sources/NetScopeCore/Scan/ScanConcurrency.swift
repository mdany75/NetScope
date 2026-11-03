import Foundation

/// Exécution concurrente avec un plafond : jamais plus de `limit` travaux en même temps.
public enum ScanConcurrency {
    /// Exécute `body` pour chaque élément, au plus `limit` à la fois, dans l'ordre de la liste.
    /// Si la tâche appelante est annulée, plus aucun travail n'est lancé et ceux en cours se terminent.
    public static func forEach<T: Sendable>(_ items: [T], limit: Int,
                                            _ body: @escaping @Sendable (T) async -> Void) async {
        let limit = max(1, limit)
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            var started = 0
            while started < limit, !Task.isCancelled, let item = iterator.next() {
                group.addTask { await body(item) }
                started += 1
            }
            while await group.next() != nil {
                if !Task.isCancelled, let item = iterator.next() {
                    group.addTask { await body(item) }
                }
            }
        }
    }

    /// Variante qui rassemble les résultats non nuls (ordre non garanti).
    public static func compactMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int,
                                                            _ body: @escaping @Sendable (T) async -> R?) async -> [R] {
        let limit = max(1, limit)
        return await withTaskGroup(of: R?.self) { group in
            var results: [R] = []
            var iterator = items.makeIterator()
            var started = 0
            while started < limit, !Task.isCancelled, let item = iterator.next() {
                group.addTask { await body(item) }
                started += 1
            }
            while let result = await group.next() {
                if let result { results.append(result) }
                if !Task.isCancelled, let item = iterator.next() {
                    group.addTask { await body(item) }
                }
            }
            return results
        }
    }
}

extension Duration {
    /// Durée en nanosecondes (arrondie, jamais négative).
    var scanNanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        let total = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
        return total <= 0 ? 0 : UInt64(total)
    }

    /// Durée en secondes.
    var scanSeconds: Double { Double(scanNanoseconds) / 1e9 }
}
