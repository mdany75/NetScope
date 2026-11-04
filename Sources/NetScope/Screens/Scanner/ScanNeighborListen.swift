import Foundation
import NetScopeCore

/// Méthode « LLDP / CDP passif » des profils de scan : pendant le scan, écoute des annonces du
/// switch voisin sur l'interface active (rien n'est envoyé). Passe par /dev/bpf seulement s'il est
/// déjà lisible (ChmodBPF de Wireshark) : un scan ne demande jamais le mot de passe d'administrateur.
extension ScanController {
    /// Durée d'écoute : les annonces LLDP partent toutes les 30 s, celles de CDP toutes les 60 s.
    nonisolated static let neighborListenSeconds: TimeInterval = 65

    func listenForNeighbor(_ state: AppState) {
        guard !Launcher.isDemo, let interface = state.activeInterface else { return }
        let active = state.activeInterface
        let toolName = "Boîte à outils › \(ToolKind.lldp.label)"
        neighborTask?.cancel()
        neighborTask = Task.detached(priority: .utility) {
            guard BPFCapture.readableDevice() != nil,
                  let capture = try? BPFCapture(interface: interface.name, filter: BPFFilter.neighbors, promiscuous: false) else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    ScanController.shared.show("LLDP/CDP passif\u{00A0}: /dev/bpf n’est pas lisible. Utilisez \(toolName) (autorisation de macOS).",
                                               tone: .neutral)
                }
                return
            }
            defer { capture.stop() }
            let end = Date().addingTimeInterval(ScanController.neighborListenSeconds)
            var frames: [CapturedFrame] = []
            while Date() < end, !Task.isCancelled {
                frames += capture.read(timeout: 0.5)
                let neighbors = NeighborFrameDecoder.neighbors(in: frames, interface: interface.name)
                if let neighbor = neighbors.first(where: { $0.protocols.contains(.lldp) }) ?? neighbors.first {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        ToolStore.shared.neighbors.recordPassive(neighbor, interface: interface, active: active)
                        ScanController.shared.show("Switch voisin entendu (\(neighbor.headline)).", tone: .success)
                    }
                    return
                }
            }
        }
    }
}
