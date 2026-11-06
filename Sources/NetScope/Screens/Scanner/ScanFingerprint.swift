import NetScopeCore
import SwiftUI

// Note 68 : colonnes facultatives « Système » et « Versions » du Scanner (menu Colonnes).

extension Device {
    /// Clé de tri de la colonne Système (vide en fin de liste).
    var scanSortSystem: String { fingerprintReport.system?.label ?? "~" }
    /// Clé de tri de la colonne Versions.
    var scanSortVersions: String { fingerprintReport.versionsLabel ?? "~" }
}

/// Cellule « Système » : nom déduit, confiance en pastille discrète, indices en infobulle.
struct ScanSystemCell: View {
    let device: Device

    var body: some View {
        let system = device.fingerprintReport.system
        HStack(spacing: 5) {
            ScanCellText(system?.label ?? "—", dimmed: system == nil)
            if let system {
                Text(system.confidence.label)
                    .font(Theme.caption)
                    .foregroundStyle(system.confidence == .forte ? Theme.success : Theme.textTertiary)
                    .fixedSize()
            }
        }
        .help(system.map { result in
            "Confiance " + result.confidence.label + "\n" + result.clues.prefix(6).map(\.line).joined(separator: "\n")
        } ?? "Aucun indice (TTL, ports, scan de ports avec détection de services)")
    }
}

/// Cellule « Versions » : versions annoncées par les services lus.
struct ScanVersionsCell: View {
    let device: Device

    var body: some View {
        let versions = device.fingerprintReport.versionsLabel
        ScanCellText(versions ?? "—", mono: versions != nil, dimmed: versions == nil)
            .help(versions ?? "Aucune version lue (scan de ports avec détection de services)")
    }
}

extension ScanDeviceTable {
    /// Captures (--snapshot) : NETSCOPE_SCANNER_COLONNES=systeme,version,-mac affiche ces colonnes
    /// facultatives (et masque celles précédées de « - »), sans rien enregistrer.
    static var snapshotColumns: [String] {
        guard CommandLine.arguments.contains("--snapshot"),
              let raw = ProcessInfo.processInfo.environment["NETSCOPE_SCANNER_COLONNES"] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Applique NETSCOPE_SCANNER_COLONNES (en capture, le tableau n'enregistre rien).
    @MainActor
    static func applySnapshotColumns(to table: StandardTableModel<Device>) {
        for entry in snapshotColumns {
            let hide = entry.hasPrefix("-")
            let id = hide ? String(entry.dropFirst()) : entry
            if let column = table.columns.first(where: { $0.id == id }) { table.setVisible(!hide, column) }
        }
    }
}
