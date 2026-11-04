import Foundation
import NetScopeCore

/// Moteur de test Internet de démonstration (`--demo`) : rejoue une progression et un résultat
/// réalistes sans rien envoyer sur le réseau. Le Speedtest l'utilise à la place des vrais moteurs
/// (Cloudflare, LibreSpeed, M-Lab, Ookla) dès que `Launcher.isDemo` est vrai.
struct SpeedtestDemoEngine: SpeedTestEngine {
    var server: SpeedServer
    var streams: Int

    func run() -> AsyncStream<SpeedEvent> {
        let server = self.server
        let streams = self.streams
        return AsyncStream { continuation in
            let task = Task {
                let info = SpeedServerInfo(city: server.city ?? "Montréal", country: server.country ?? "CA",
                                           clientIP: "203.0.113.24", asn: 577, asOrganization: "Bell Canada",
                                           source: server.source.label, serverName: server.name, serverID: server.id)
                continuation.yield(.server(info))
                let tick: UInt64 = 100_000_000
                // Latence : 1 s.
                for step in 1...10 {
                    try? await Task.sleep(nanoseconds: tick)
                    if Task.isCancelled { continuation.finish(); return }
                    continuation.yield(.update(SpeedLiveUpdate(phase: .latency, elapsed: Double(step) / 10,
                                                               latencyMs: 6 + Double(step % 3) * 0.4,
                                                               fraction: 0.1 * Double(step) / 10)))
                }
                continuation.yield(.latencyMeasured(idleMs: 6, jitterMs: 1.4))
                // Téléchargement puis téléversement : 4 s chacun, montée progressive.
                for (phase, target, range) in [(SpeedPhase.download, 912.0, 0.1...0.55), (.upload, 487.0, 0.55...1)] {
                    for step in 1...40 {
                        try? await Task.sleep(nanoseconds: tick)
                        if Task.isCancelled { continuation.finish(); return }
                        let t = Double(step) / 10
                        let mbps = target * (1 - exp(-t * 1.6)) + sin(t * 3) * target * 0.015
                        let fraction = range.lowerBound + (range.upperBound - range.lowerBound) * Double(step) / 40
                        continuation.yield(.update(SpeedLiveUpdate(phase: phase, elapsed: t, mbps: max(0, mbps),
                                                                   fraction: fraction)))
                    }
                    continuation.yield(phase == .download ? .downloadMeasured(target) : .uploadMeasured(target))
                }
                continuation.yield(.finished(SpeedTestSummary(
                    downMbps: 912, upMbps: 487, idleLatencyMs: 6, loadedLatencyMs: 18, jitterMs: 1.4,
                    probesSent: 40, probesLost: 0, streams: streams, server: info,
                    downloadBytes: 456_000_000, uploadBytes: 243_000_000)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
