import NetScopeCore
import SwiftUI

// Note 60 : fiche matériel remplie automatiquement. Modèle, numéro de série et firmware lus par SNMP
// ou par la FortiGate, montrés avec leur source et leur date, à côté des champs saisis (jamais
// remplacés : « Reprendre » copie le numéro détecté dans un numéro saisi vide).

/// Bloc « Matériel détecté » de la fiche de l'Inventaire.
struct InvDetectedHardwareBlock: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var feed = InvHardwareFeed.shared
    @ObservedObject private var model = InvModel.shared

    let record: InvRecord
    let siteKey: String
    /// Numéro de série du brouillon de la fiche (saisi, enregistré ou non).
    let enteredSerial: String
    let now: Date
    /// Brouillon modifié : « Reprendre » écrit dans le brouillon plutôt que dans la fiche enregistrée.
    var onAdopt: ((String) -> Void)? = nil

    private var detected: InvDetectedHardware? { record.detectedHardware }
    private var isReading: Bool { feed.isReading(site: siteKey, key: record.key) }
    /// La lecture à la demande ne vise que les appareils du site actif (ceux du réseau joint).
    private var canRead: Bool { siteKey == model.siteKey && record.hasAddress }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                title
                sourcePill
            }
            if let detected {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Modèle", detected.model)
                    GridRow {
                        label("N° de série")
                        VStack(alignment: .leading, spacing: 3) {
                            value(detected.serialNumber)
                            serialNote(detected)
                        }
                    }
                    row("Firmware", detected.firmware)
                }
                Text("Lu le \(InvFormat.stamp(detected.readAt))" + (detected.vendor.map { " · fabricant\u{00A0}: \($0)" } ?? ""))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Rien de lu pour l’instant. Le modèle, le numéro de série et le firmware se remplissent au relevé SNMP des switchs, à la fin d’un scan (sysDescr), par la FortiGate, ou avec «\u{00A0}Lire la fiche matériel\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ActionRow { readButton }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var title: some View {
        Text("Matériel détecté").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary).fixedSize()
    }

    @ViewBuilder
    private var sourcePill: some View {
        if let detected {
            InvPill(text: detected.sourceLabel, foreground: Theme.accentStrong, background: InvStyle.infoSoft, size: 10)
                .help("Lu par \(detected.sourceLabel) le \(InvFormat.stamp(detected.readAt)) (\(InvFormat.relative(detected.readAt, now: now).lowercased()))")
        }
    }

    @ViewBuilder
    private var readButton: some View {
        HStack(spacing: 6) {
            if isReading { ProgressView().controlSize(.small) }
            Button(isReading ? "Lecture…" : (detected == nil ? "Lire la fiche matériel" : "Relire la fiche matériel")) { feed.read(record, site: siteKey, state: state) }
                .buttonStyle(.secondary)
                .disabled(isReading || !canRead)
                .help(canRead ? "Lire le modèle, le numéro de série et le firmware de cet appareil (SNMP, ou la FortiGate pour un appareil Fortinet)"
                      : "Lecture possible seulement pour un appareil du site actif, avec une adresse IP")
        }
        .fixedSize()
    }

    private func row(_ title: String, _ text: String?) -> some View {
        GridRow {
            label(title)
            value(text)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize()
    }

    private func value(_ text: String?) -> some View {
        Text(text ?? "—")
            .font(Theme.mono(12))
            .foregroundStyle(text == nil ? Theme.textTertiary : Theme.text)
            .textSelection(.enabled)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Numéro saisi vide : « Reprendre » ; différent : signalé sobrement.
    @ViewBuilder
    private func serialNote(_ detected: InvDetectedHardware) -> some View {
        if let serial = detected.serialNumber {
            let entered = enteredSerial.trimmingCharacters(in: .whitespacesAndNewlines)
            if entered.isEmpty {
                HStack(spacing: 6) {
                    Text("Aucun numéro saisi").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Button("Reprendre") {
                        if let onAdopt { onAdopt(serial) } else { feed.adoptSerial(record, site: siteKey) }
                    }
                        .controlSize(.small)
                        .help("Copier «\u{00A0}\(serial)\u{00A0}» dans le numéro de série de la fiche")
                }
            } else if InvDetectedHardware.normalizedSerial(entered) != InvDetectedHardware.normalizedSerial(serial) {
                Label("Diffère du numéro saisi (\(entered))", systemImage: "exclamationmark.circle")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
                    .help("Le numéro saisi n’est pas remplacé\u{00A0}: vérifiez l’étiquette de l’appareil.")
            }
        }
    }
}

/// Lignes « Matériel détecté » de la carte Matériel de la fiche Appareil.
struct DeviceDetectedHardwareRows: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared
    @ObservedObject private var feed = InvHardwareFeed.shared
    let device: Device

    var body: some View {
        let record = model.store.existingKey(for: device).flatMap { model.store.record($0) }
        if let record {
            if let detected = record.detectedHardware {
                if let value = detected.model { DeviceKVRow(key: "Modèle détecté", value: value) }
                if let value = detected.serialNumber {
                    DeviceKVRow(key: "N° de série", value: value, detail: serialDetail(record, value))
                }
                if let value = detected.firmware { DeviceKVRow(key: "Firmware", value: value) }
                DeviceKVRow(key: "Fiche lue par", value: detected.sourceLabel, mono: false,
                            detail: InvFormat.relative(detected.readAt).lowercased())
            }
            ActionRow {
                HStack(spacing: 6) {
                    if feed.isReading(site: model.siteKey, key: record.key) { ProgressView().controlSize(.small) }
                    Button(record.detectedHardware == nil ? "Lire la fiche matériel" : "Relire la fiche matériel") {
                        feed.read(record, site: model.siteKey, state: state)
                    }
                    .buttonStyle(.secondary)
                    .disabled(feed.isReading(site: model.siteKey, key: record.key))
                    .help("Modèle, numéro de série et firmware par SNMP, ou par la FortiGate pour un appareil Fortinet")
                }
            }
            .padding(.top, 4)
        }
    }

    private func serialDetail(_ record: InvRecord, _ detected: String) -> String? {
        switch record.serialCheck {
        case .differs: return "diffère du numéro saisi"
        default: return nil
        }
    }
}
