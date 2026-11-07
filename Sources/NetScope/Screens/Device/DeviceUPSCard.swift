import NetScopeCore
import SwiftUI

/// Note 98 : carte « Onduleur » de la fiche d'un onduleur : alimentation (secteur, batterie,
/// contournement), charge de la batterie, autonomie, charge de la sortie, tensions, température,
/// dernier test et remplacement de la batterie, lus par SNMP (UPS-MIB et MIB du fabricant)
/// seulement sur clic.
struct DeviceUPSCard: View {
    @ObservedObject private var store = UPSStore.shared
    @ObservedObject private var monitors = MonStore.shared
    let device: Device

    /// Seuil d'autonomie de la sonde « Onduleur » qui vise cet appareil, sinon celui proposé.
    private var minRuntime: Double {
        let targets = Set([device.ip.description, device.hostname, device.customName].compactMap { $0?.lowercased() })
        let active = SiteModel.shared.activeID
        let probe = monitors.probes.first {
            $0.kind == .upsStatus && targets.contains($0.target.lowercased()) && monitors.site(of: $0) == active
        }
        return probe?.resourceLimit ?? UPSMIB.defaultMinRuntime
    }

    var body: some View {
        let reading = store.reading(for: device)
        let now = Date()
        DeviceCard(title: "Onduleur") {
            VStack(alignment: .leading, spacing: 8) {
                if let reading {
                    HStack(spacing: 8) {
                        Image(systemName: reading.onBattery ? "battery.25" : "powerplug")
                            .foregroundStyle(sourceColor(reading))
                        Text(reading.source.label).font(Theme.body.weight(.semibold)).foregroundStyle(sourceColor(reading))
                        Spacer(minLength: 8)
                        if let model = reading.displayModel {
                            Text(model).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    gauge("Batterie", reading.chargePercent, label: reading.chargePercent.map(UPSMIB.percent),
                          low: (reading.chargePercent ?? 100) < 50)
                    gauge("Charge de sortie", reading.loadPercent, label: reading.loadPercent.map(UPSMIB.percent),
                          low: (reading.loadPercent ?? 0) >= 90)
                    line("Autonomie", reading.runtimeMinutes.map(UPSMIB.minutes) ?? "—",
                         warn: (reading.runtimeMinutes ?? .infinity) < minRuntime)
                    line("Tensions", voltages(reading))
                    if let temperature = reading.temperature {
                        line("Température", "\(Int(temperature.rounded()))\u{00A0}°C", warn: temperature >= 40)
                    }
                    line("Dernier test", [reading.lastTest?.label, reading.lastTestDate.map(UPSMIB.dateLabel)]
                        .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—", warn: reading.lastTest == .failed)
                    let due = reading.batteryDueReason(now: now)
                    let ageNote = reading.batteryAgeNote(now: now)
                    line("Batterie posée", reading.batteryReplacedDate.map(UPSMIB.dateLabel) ?? "—", warn: due != nil || ageNote != nil)
                    if let due {
                        Label("Batterie à changer\u{00A0}: \(due)", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.small).foregroundStyle(Theme.warning)
                    } else if let ageNote {
                        Label("Batterie \(ageNote) (date pas toujours mise à jour au remplacement)", systemImage: "info.circle")
                            .font(Theme.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(reading.alarms, id: \.self) { alarm in
                        Label(alarm, systemImage: "bell.fill").font(Theme.small).foregroundStyle(Theme.warning)
                    }
                    Text("\(reading.mibs.joined(separator: ", ")) · lu " + reading.readAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .font(Theme.small).foregroundStyle(Theme.textTertiary)
                } else {
                    Text("Alimentation (secteur, batterie, contournement), charge de la batterie, autonomie, charge, tensions, température, dernier test et remplacement de la batterie, lus par SNMP (UPS-MIB, APC, Eaton, CyberPower).")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.isUnsaved(device) {
                    Text(UPSStore.noMACNotice).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                if let error = store.error(for: device) {
                    Text(error).font(Theme.small).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    store.read(device)
                } label: {
                    Label(store.isReading(device) ? "Lecture…" : (reading == nil ? "Lire l’onduleur" : "Relire"),
                          systemImage: "minus.plus.batteryblock")
                }
                .buttonStyle(.secondary)
                .disabled(store.isReading(device))
            }
        }
    }

    private func sourceColor(_ reading: UPSReading) -> Color {
        switch reading.source {
        case .battery, .off: return Theme.critical
        case .bypass, .unknown, .other: return Theme.warning
        default: return Theme.success
        }
    }

    private func voltages(_ reading: UPSReading) -> String {
        let input = reading.inputVoltage.map { "entrée \(Int($0.rounded()))\u{00A0}V" }
        let output = reading.outputVoltage.map { "sortie \(Int($0.rounded()))\u{00A0}V" }
        return [input, output].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—"
    }

    private func gauge(_ title: String, _ value: Double?, label: String?, low: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 120, alignment: .leading)
            ProgressBar(fraction: (value ?? 0) / 100, color: low ? Theme.warning : Theme.accent, height: 6)
            Text(label ?? "—").font(Theme.mono(11, weight: .semibold)).foregroundStyle(low ? Theme.warning : Theme.text)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func line(_ title: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 120, alignment: .leading)
            Text(value).font(Theme.small).foregroundStyle(warn ? Theme.warning : Theme.text).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
