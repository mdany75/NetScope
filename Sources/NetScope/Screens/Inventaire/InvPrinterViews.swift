import NetScopeCore
import SwiftUI

// Note 95 (prévue à la note 91) : vue « Imprimantes » de l'Inventaire. Les fiches qui ont un relevé
// des consommables (PrinterStore, rangé sous la MAC de l'imprimante dans le dossier de son site),
// triées du niveau de consommable le plus bas au plus haut ; rien n'est lu sur le réseau ici.
enum InvPrinters {
    /// Relevé d'une fiche : clé MAC seulement, dans le dossier du site de la fiche. Un relevé rangé
    /// sous une IP (imprimante lue sans MAC connue) n'est pas repris ici : l'IP seule ne choisit
    /// jamais un appareil, et cette IP peut appartenir aujourd'hui à un autre.
    @MainActor
    static func reading(_ row: SiteScopedRecord, store: PrinterStore) -> PrinterReading? {
        guard let mac = row.record.mac else { return nil }
        return store.readings(siteKey: row.siteKey)[mac.description]
    }

    /// Fiches avec un relevé, du consommable le plus bas au plus haut ; niveau inconnu à la fin.
    @MainActor
    static func rows(_ rows: [SiteScopedRecord], store: PrinterStore) -> [(row: SiteScopedRecord, reading: PrinterReading)] {
        let found = rows.compactMap { row in reading(row, store: store).map { (row: row, reading: $0) } }
        return found.sorted { a, b in
            let la = a.reading.lowest?.percent ?? .infinity
            let lb = b.reading.lowest?.percent ?? .infinity
            if la != lb { return la < lb }
            return FrenchOrder.precedes(a.row.record.displayName, b.row.record.displayName)
        }
    }
}

/// Résumé des consommables des imprimantes affichées (vue « Imprimantes »).
struct InvPrinterPanel: View {
    let printers: [(row: SiteScopedRecord, reading: PrinterReading)]
    let multipleSites: Bool
    var onSelect: (String) -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Consommables", subtitle: "du niveau le plus bas au plus haut · seuil \(Int(PrinterMIB.defaultThreshold))\u{00A0}%") {
                    EmptyView()
                }
                if printers.isEmpty {
                    Text("Aucun relevé de consommables. Ouvrez la fiche d’une imprimante et choisissez «\u{00A0}Lire les consommables\u{00A0}», ou ajoutez une sonde «\u{00A0}Imprimante\u{00A0}» dans la Surveillance.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(printers, id: \.row.id) { item in line(item.row, item.reading) }
                }
            }
        }
    }

    private func line(_ row: SiteScopedRecord, _ reading: PrinterReading) -> some View {
        let lowest = reading.lowest
        let low = lowest?.isLow(threshold: PrinterMIB.defaultThreshold) ?? false
        return Button { onSelect(row.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.record.displayName).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(multipleSites ? "\(row.record.ip.description) · \(row.siteName)" : row.record.ip.description)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .frame(width: 190, alignment: .leading)
                Text(lowest?.displayName ?? "Niveau inconnu").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                ProgressBar(fraction: (lowest?.percent ?? 0) / 100, color: low ? Theme.warning : Theme.accent, height: 6)
                    .frame(minWidth: 60)
                Text(lowest?.levelLabel ?? "—")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(low ? Theme.warning : Theme.text)
                    .frame(width: 56, alignment: .trailing)
                Text(reading.readAt.formatted(.relative(presentation: .named)))
                    .font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .frame(width: 96, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reading.summary)
    }
}
