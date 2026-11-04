import Foundation

// Latence vers le serveur d'un partage réseau, mesurée à côté du test de vitesse : quelques pings
// (moteur Ping de NetScope). Appelé seulement pendant un vrai test, jamais dans les tests
// automatiques ni en démonstration.

public enum DiskNetworkProbe {
    /// Latence moyenne (ms) de `count` pings vers `server`, ou nil (nom introuvable, ping refusé
    /// ou filtré par le serveur).
    public static func serverLatency(_ server: String, count: Int = 5, interval: TimeInterval = 0.2) async -> Double? {
        guard let address = try? await PingResolver.resolveAsync(server) else { return nil }
        let collector = SampleCollector()
        let monitor = PingMonitor(address: address, options: PingOptions(interval: interval, timeout: 1)) { sample in
            collector.add(sample)
        }
        do { try monitor.start() } catch { return nil }
        let deadline = Date().addingTimeInterval(Double(count) * interval + 1.5)
        while collector.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { break }
        }
        monitor.stop()
        return DiskMath.mean(collector.latencies)
    }

    private final class SampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [PingSample] = []

        func add(_ sample: PingSample) {
            lock.lock()
            samples.append(sample)
            lock.unlock()
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
        var latencies: [Double] { lock.lock(); defer { lock.unlock() }; return samples.compactMap(\.rttMs) }
    }
}
