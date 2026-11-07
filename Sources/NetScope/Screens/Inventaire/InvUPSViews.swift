import NetScopeCore
import SwiftUI

// Note 98 : vue « Onduleurs » de l'Inventaire, comme la vue « Imprimantes » (note 95) : les fiches
// qui ont un relevé (UPSStore, rangé sous la MAC de l'onduleur dans le dossier de son site), les
// plus urgentes d'abord (sur batterie, puis l'autonomie la plus courte) ; rien n'est lu ici.
enum InvUPS {
    /// Relevé d'une fiche : clé MAC seulement, dans le dossier du site de la fiche (jamais par l'IP seule).
    @MainActor
    static func reading(_ row: SiteScopedRecord, store: UPSStore) -> UPSReading? {
        guard let mac = row.record.mac else { return nil }
        return store.readings(siteKey: row.siteKey)[mac.description]
    }

    @MainActor
    static func rows(_ rows: [SiteScopedRecord], store: UPSStore) -> [(row: SiteScopedRecord, reading: UPSReading)] {
        let found = rows.compactMap { row in reading(row, store: store).map { (row: row, reading: $0) } }
        return found.sorted { a, b in
            if a.reading.onBattery != b.reading.onBattery { return a.reading.onBattery }
            let ra = a.reading.runtimeMinutes ?? .infinity, rb = b.reading.runtimeMinutes ?? .infinity
            if ra != rb { return ra < rb }
            return FrenchOrder.precedes(a.row.record.displayName, b.row.record.displayName)
        }
    }
}

/// Résumé des onduleurs affichés (vue « Onduleurs »).
struct InvUPSPanel: View {
    let units: [(row: SiteScopedRecord, reading: UPSReading)]
    let multipleSites: Bool
    var onSelect: (String) -> Void

    var body: some View {
        let now = Date()
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Onduleurs", subtitle: "sur batterie d’abord, puis l’autonomie la plus courte · seuil \(UPSMIB.minutes(UPSMIB.defaultMinRuntime))") {
                    EmptyView()
                }
                if units.isEmpty {
                    Text("Aucun relevé d’onduleur. Ouvrez la fiche d’un onduleur et choisissez «\u{00A0}Lire l’onduleur\u{00A0}», ou ajoutez une sonde «\u{00A0}Onduleur (UPS)\u{00A0}» dans la Surveillance.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(units, id: \.row.id) { item in line(item.row, item.reading, now: now) }
                }
            }
        }
    }

    private func line(_ row: SiteScopedRecord, _ reading: UPSReading, now: Date) -> some View {
        let shortRuntime = (reading.runtimeMinutes ?? .infinity) < UPSMIB.defaultMinRuntime
        let due = reading.batteryDueReason(now: now)
        return Button { onSelect(row.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.record.displayName).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(multipleSites ? "\(row.record.ip.description) · \(row.siteName)" : row.record.ip.description)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .frame(width: 190, alignment: .leading)
                Text(reading.source.label).font(Theme.small.weight(.semibold))
                    .foregroundStyle(reading.onBattery || reading.source == .off ? Theme.critical : Theme.text)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                ProgressBar(fraction: (reading.chargePercent ?? 0) / 100, color: Theme.accent, height: 6)
                    .frame(minWidth: 60)
                Text(reading.runtimeMinutes.map(UPSMIB.minutes) ?? "—")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(shortRuntime ? Theme.warning : Theme.text)
                    .frame(width: 64, alignment: .trailing)
                let aged = due == nil && reading.batteryAgeNote(now: now) != nil
                Text(due != nil ? "Batterie à changer" : aged ? "Batterie à vérifier" : "Batterie OK")
                    .font(Theme.small).foregroundStyle(due != nil || aged ? Theme.warning : Theme.textTertiary).lineLimit(1)
                    .frame(width: 120, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reading.summary + (due.map { " · batterie à changer\u{00A0}: \($0)" }
            ?? reading.batteryAgeNote(now: now).map { " · batterie \($0)" } ?? ""))
    }
}
