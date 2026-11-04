import Foundation

// Note 36 : écriture différée et regroupée de l'inventaire. Avant, chaque changement (fiche,
// favori, alerte acceptée, fin de scan) réécrivait tout le fichier, sur le fil principal : jusqu'à
// plusieurs secondes pour un site de 5 000 appareils à long historique.
//
// Maintenant : `schedule` retient la dernière version à écrire et l'écrit après un court délai,
// sur une file de fond ; dix changements rapprochés donnent une seule écriture. L'écriture reste
// atomique (fichier temporaire puis remplacement) : un fichier n'est jamais à moitié écrit.
// `flush` écrit tout de suite ce qui attend (changement de site, fermeture, sauvegarde) et
// `cancel` l'oublie (site supprimé : rien ne doit recréer son dossier).

public final class InventoryWriter: @unchecked Sendable {
    public typealias Failure = @Sendable (URL, Error) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let onError: Failure?
    /// Dernière version à écrire, par fichier.
    private var pending: [URL: InventoryStore] = [:]
    private var scheduled = false
    private var writes = 0

    /// `delay` : attente avant d'écrire, pour regrouper les changements rapprochés.
    public init(delay: TimeInterval = 0.8, label: String = "NetScope.inventaire.ecriture", onError: Failure? = nil) {
        self.delay = delay
        self.onError = onError
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Nombre d'écritures faites (essais).
    public var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    /// Une version attend-elle d'être écrite ?
    public var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Écrira cette version de l'inventaire (elle remplace celle qui attendait pour ce fichier).
    public func schedule(_ store: InventoryStore, to url: URL) {
        lock.lock()
        pending[url] = store
        let start = !scheduled
        scheduled = true
        lock.unlock()
        guard start else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.writePending() }
    }

    /// Écrit tout de suite ce qui attend, et attend la fin des écritures en cours.
    public func flush() {
        queue.sync { writePending() }
    }

    /// Oublie ce qui attend pour ce fichier (une écriture déjà commencée se termine d'abord).
    public func cancel(_ url: URL) {
        queue.sync {
            lock.lock()
            pending[url] = nil
            lock.unlock()
        }
    }

    /// Sur la file d'écriture.
    private func writePending() {
        lock.lock()
        let batch = pending
        pending = [:]
        scheduled = false
        lock.unlock()
        for (url, store) in batch.sorted(by: { $0.key.path < $1.key.path }) {
            do {
                try store.save(to: url)
                lock.lock()
                writes += 1
                lock.unlock()
            } catch {
                onError?(url, error)
            }
        }
    }
}
