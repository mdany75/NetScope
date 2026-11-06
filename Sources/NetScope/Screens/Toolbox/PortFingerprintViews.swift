import NetScopeCore
import SwiftUI

// Note 68 : produit et version reconnus dans le tableau des ports (outil et fiche Appareil).

extension PortScanResult {
    /// Service reconnu d'après ce que le port a répondu (nil : rien de lu).
    var fingerprint: FPServiceResult? {
        observation.map(FPServiceRules.analyze)
    }

    /// Clé de tri « Produit et version » (vide en fin de liste).
    var toolSortProduct: String { fingerprint?.productLabel ?? "~" }
}

/// Cellule « Produit et version » : produit reconnu, pastille « en clair », indices en infobulle.
struct PortProductCell: View {
    let result: PortScanResult

    var body: some View {
        let service = result.fingerprint
        HStack(spacing: 5) {
            ToolTableText(service?.productLabel ?? "—", color: service?.productLabel == nil ? Theme.textTertiary : Theme.text)
            if let clear = service?.clearText {
                Chip(text: clear == "SMB1" ? "obsolète" : "en clair", tone: .warning)
                    .fixedSize()
            }
        }
        .help(help(service))
    }

    private func help(_ service: FPServiceResult?) -> String {
        guard let service else { return "Rien de reconnu (cochez « Détection de services » pour lire les bannières)" }
        var lines: [String] = []
        if let system = service.system { lines.append("Système\u{00A0}: \(system)") }
        if let clear = service.clearText { lines.append("\(clear) en clair\u{00A0}: identifiants et données lisibles sur le réseau") }
        lines += service.clues.prefix(5).map(\.line)
        return lines.joined(separator: "\n")
    }
}

extension Device {
    /// Ports connus (inventaire), avec ce qu'un scan précédent en a lu.
    var knownPortRows: [PortScanResult] {
        openPorts.sorted().map { port in
            let observation = fingerprint?.service(port)
            return PortScanResult(port: port, state: .open, banner: observation.flatMap(Device.bannerText) ?? "connu (inventaire)",
                                  observation: observation)
        }
    }

    /// Texte de la colonne Bannière pour une observation gardée.
    static func bannerText(_ observation: FPServiceObservation) -> String? {
        if let banner = observation.banner { return banner }
        if let dialect = observation.smbDialect { return FPSMB.dialectLabel(dialect) + (observation.smbSambaHint == true ? " · Samba" : "") }
        if observation.smb1Only == true { return "SMB1 seulement" }
        let parts = [observation.httpStatus, observation.httpServer.map { "Server: \($0)" },
                     observation.certSubject.map { "TLS " + ($0.organization ?? $0.commonName ?? "") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
