import NetScopeCore
import SwiftUI

/// Note 68 : carte « Système et versions » de l'Aperçu : système déduit, confiance, versions
/// annoncées, services en clair et indices (d'où vient chaque déduction).
struct DeviceFingerprintCard: View {
    let device: Device

    var body: some View {
        let report = device.fingerprintReport
        DeviceCard(title: "Système et versions") {
            VStack(alignment: .leading, spacing: 10) {
                if let system = report.system {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(system.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        DeviceConfidenceChip(confidence: system.confidence)
                    }
                }
                VStack(spacing: 0) {
                    if let type = report.strongType {
                        DeviceKVRow(key: "Type indiqué", value: type.label, mono: false,
                                    detail: type == device.deviceType ? "retenu" : nil)
                    }
                    DeviceKVRow(key: "Versions annoncées", value: report.versionsLabel ?? "aucune lue", mono: report.versionsLabel != nil,
                                valueColor: report.versionsLabel == nil ? Theme.textSecondary : Theme.text)
                    let clear = DeviceFingerprintCard.clearServices(report)
                    if !clear.isEmpty {
                        DeviceKVRow(key: "En clair", value: clear, mono: false, valueColor: Theme.warning)
                    }
                }
                if let system = report.system {
                    let clues = DeviceClueGroup.groups(system.clues)
                    VStack(alignment: .leading, spacing: 6) {
                        ToolFieldLabel("Indices")
                        ForEach(clues.prefix(4)) { group in
                            DeviceClueRow(group: group)
                        }
                        if clues.count > 4 {
                            Text(clues.count == 5 ? "et 1 autre indice" : "et \(clues.count - 4) autres indices")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                .help(clues.dropFirst(4).map(\.line).joined(separator: "\n"))
                        }
                    }
                }
                if device.fingerprint?.services.isEmpty != false {
                    // Le bouton « Scanner les ports » est celui de la carte Services connus, juste à côté.
                    Text("Bannières, en-têtes HTTP, certificat et SMB se lisent par un scan de ports avec la détection de services.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// « Telnet (23), HTTP (80) ».
    static func clearServices(_ report: FPReport) -> String {
        report.services.compactMap { service in service.clearText.map { "\($0) (\(service.port))" } }
            .joined(separator: ", ")
    }
}

/// Pastille de confiance (forte, moyenne, faible).
struct DeviceConfidenceChip: View {
    let confidence: FPConfidence

    var body: some View {
        Chip(text: "Confiance " + confidence.label, tone: tone)
            .help("Forte\u{00A0}: indice sans ambiguïté (certificat, en-tête, sysDescr) ou plusieurs indices concordants. Faible\u{00A0}: TTL ou port seuls.")
    }

    private var tone: Tone {
        switch confidence {
        case .forte: return .success
        case .moyenne: return .accent
        case .faible: return .neutral
        }
    }
}

/// Indices identiques sur plusieurs ports (en-tête Server sur 80 et 443) : une seule ligne.
struct DeviceClueGroup: Identifiable {
    var clue: FPClue
    var ports: [UInt16]
    var id: String { clue.source.rawValue + "|" + clue.observed + "|" + clue.conclusion }

    /// « En-tête HTTP · 80, 443 ».
    var sourceLabel: String {
        clue.source.label + (ports.isEmpty ? "" : " · " + ports.map(String.init).joined(separator: ", "))
    }

    var line: String { "\(sourceLabel)\u{00A0}: \(clue.observed) → \(clue.conclusion)" }

    static func groups(_ clues: [FPClue]) -> [DeviceClueGroup] {
        var result: [DeviceClueGroup] = []
        for clue in clues {
            var key = clue
            key.port = nil
            if let index = result.firstIndex(where: { $0.id == DeviceClueGroup(clue: key, ports: []).id }) {
                if let port = clue.port, !result[index].ports.contains(port) { result[index].ports.append(port) }
            } else {
                result.append(DeviceClueGroup(clue: key, ports: clue.port.map { [$0] } ?? []))
            }
        }
        return result
    }
}

/// Un indice sur deux lignes : source et conclusion, puis ce qui a été lu (SF Mono).
struct DeviceClueRow: View {
    let group: DeviceClueGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.sourceLabel)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(group.clue.conclusion)
                    .font(Theme.captionSemibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Text(group.clue.observed)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(group.clue.observed)
        }
    }
}
