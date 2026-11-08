import NetScopeCore
import SwiftUI

@MainActor
final class ToolMACModel: ObservableObject {
    @Published var text = "70:4C:A5:1E:22:9A"
}

/// Convertisseur MAC/OUI : formats, fabricant, type d'adresse et correspondance dans l'inventaire.
struct MACConverterView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolMACModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolLabeledField(label: "Adresse MAC (tout format)") {
                ToolTextField(placeholder: "94:DD:F8:18:15:7D, 94dd.f818.157d…", text: $model.text,
                              invalid: info == nil && !model.text.isEmpty, height: 36)
            }
            ToolFlowLayout(spacing: 6) {
                Text("Exemples de l’inventaire\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 26)
                ForEach(examples, id: \.self) { example in
                    Button(example) { model.text = example }
                        .buttonStyle(.plain)
                        .font(Theme.mono(12))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                }
            }
            if let info {
                ToolCellGrid(cells: info.formats.map { ToolCell(key: $0.label, value: $0.value) }, columns: 2)
                HStack(alignment: .top, spacing: 12) {
                    card(title: "Fabricant (OUI \(info.oui))", value: info.vendorLabel, detail: nil)
                    card(title: "Type d’adresse", value: info.kind, detail: info.cast)
                    inventoryCard(info.mac)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if !model.text.isEmpty {
                ToolNotice(tone: .critical, message: "MAC invalide\u{00A0}: 12 caractères hexadécimaux attendus (reçu \(MACVendorLookup.hexDigitCount(model.text))).")
            }
        }
    }

    private var info: MACVendorInfo? { MACVendorLookup.lookup(model.text) }

    /// Quelques MAC de l'inventaire, dans des formats différents (sinon celles du croquis).
    private var examples: [String] {
        let macs = state.devices.compactMap(\.mac).prefix(4)
        guard !macs.isEmpty else { return ["70:4C:A5:1E:22:9A", "94DD.F818.157D", "b0-7b-25-4a-91-0e", "DA:A1:19:5C:07:E2"] }
        let styles: [MACAddress.Style] = [.upperColon, .cisco, .hyphen, .upperColon]
        var list = macs.enumerated().map { index, mac in mac.formatted(styles[index % styles.count]) }
        if let random = state.devices.compactMap(\.mac).first(where: \.isRandomized), !macs.contains(random) {
            list[list.count - 1] = random.formatted(.upperColon)
        }
        return list
    }

    private func card(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel(title)
            Text(value).font(Theme.bodySemibold).foregroundStyle(Theme.text).textSelection(.enabled)
            if let detail { Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func inventoryCard(_ mac: MACAddress) -> some View {
        let device = state.devices.first { $0.mac == mac }
        return VStack(alignment: .leading, spacing: 6) {
            ToolFieldLabel("Dans l’inventaire")
            if let device {
                Button("\(device.ip.description) · \(device.displayName)") { state.showDevice(device.id) }
                    .buttonStyle(.secondary)
                Text([device.switchLocation, device.vlan.map { "VLAN \($0)" }].compactMap { $0 }.joined(separator: " · ").toolIfEmpty("—"))
                    .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Non trouvée dans le dernier scan").font(Theme.bodySemibold)
                Text("—").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

extension String {
    func toolIfEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
