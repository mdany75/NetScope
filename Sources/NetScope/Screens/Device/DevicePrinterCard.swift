import NetScopeCore
import SwiftUI

/// Note 91 : carte « Consommables » de la fiche d'une imprimante : toner ou encre par couleur,
/// tambour, kit de maintenance, bac de récupération, compteur de pages et alertes, lus par SNMP
/// (Printer-MIB) seulement sur clic.
struct DevicePrinterCard: View {
    @ObservedObject private var store = PrinterStore.shared
    let device: Device

    var body: some View {
        let reading = store.reading(for: device)
        DeviceCard(title: "Consommables") {
            VStack(alignment: .leading, spacing: 8) {
                if let reading {
                    ForEach(reading.supplies.sorted { ($0.percent ?? 101) < ($1.percent ?? 101) }) { supply in
                        supplyRow(supply)
                    }
                    HStack(spacing: 8) {
                        Text(reading.pageCount.map { "\(PrinterMIB.grouped($0)) pages" } ?? "Compteur non publié")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text("lu " + reading.readAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(reading.errors, id: \.self) { flag in
                        Label(flag.label, systemImage: flag.isBlocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(Theme.small)
                            .foregroundStyle(flag.isBlocking ? Theme.critical : Theme.warning)
                    }
                    // Alertes publiées par l'imprimante (prtAlertDescription).
                    ForEach(Array(reading.alerts.prefix(4).enumerated()), id: \.offset) { _, alert in
                        Text(alert).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Niveaux du toner, de l’encre, du tambour et du kit de maintenance, compteur de pages et alertes, lus par SNMP (Printer-MIB).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = store.error(for: device) {
                    Text(error).font(Theme.small).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    store.read(device)
                } label: {
                    Label(store.isReading(device) ? "Lecture…" : (reading == nil ? "Lire les consommables" : "Relire"),
                          systemImage: "drop.halffull")
                }
                .buttonStyle(.secondary)
                .disabled(store.isReading(device))
            }
        }
    }

    private func supplyRow(_ supply: PrinterSupply) -> some View {
        let low = supply.isLow(threshold: PrinterMIB.defaultThreshold)
        return HStack(spacing: 10) {
            // Contour fin : la pastille reste lisible en clair (jaune) comme en sombre (noir).
            Circle().fill(color(supply)).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: supply.color == nil ? 0 : 1))
            Text(supply.displayName).font(Theme.small).foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
                .help(supply.description)
            ProgressBar(fraction: (supply.percent ?? 0) / 100, color: low ? Theme.warning : Theme.accent, height: 6)
            Text(supply.levelLabel)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(low ? Theme.warning : Theme.text)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func color(_ supply: PrinterSupply) -> Color {
        switch supply.color {
        case .black: return Color(white: 0.12)
        case .cyan: return .cyan
        case .magenta: return .pink
        case .yellow: return .yellow
        case nil: return Theme.textTertiary
        }
    }
}
