import NetScopeCore
import SwiftUI

// MARK: - Tableau des plages (tableau standard « reglages.plages », note 8)

/// Ligne du tableau des plages : la plage enregistrée et les valeurs triables qui en découlent.
struct RegRangeRowData: Identifiable {
    let range: ScanRangeConfig
    /// Position dans la liste enregistrée (ordre d'origine, tri par défaut).
    let order: Int
    let site: String
    /// Nombre d'adresses ; -1 si la plage est illisible.
    let addresses: Int
    let devicesSeen: Int
    /// Dernière réponse d'un appareil de la plage.
    let lastSeen: Date?

    var id: UUID { range.id }
    var text: String { range.text }
    var label: String { range.label }
    var kind: String { range.kindLabel }
    var sortVLAN: Int { range.vlan ?? Int.max }
    var sortEnabled: Int { range.isEnabled ? 0 : 1 }
    var sortLastSeen: Date { lastSeen ?? .distantPast }
}

/// Plages du site : nom et VLAN modifiables sur place, inclusion au scan, suppression.
/// Note 28 : les plages sont celles du site choisi dans Réglages › Sites et plages (`ranges`) ;
/// `devices` : appareils du dernier scan de ce site (vide pour un autre site que l'actif).
struct RegRangeTable: View {
    @ObservedObject var table: StandardTableModel<RegRangeRowData>
    @Binding var ranges: [ScanRangeConfig]
    var siteName: String
    var devices: [Device]

    static let columns: [StandardColumn] = [
        StandardColumn(id: "plage", title: "Plage", isRequired: true),
        StandardColumn(id: "nom", title: "Nom"),
        StandardColumn(id: "format", title: "Format"),
        StandardColumn(id: "vlan", title: "VLAN"),
        StandardColumn(id: "adresses", title: "Adresses"),
        StandardColumn(id: "inclure", title: "Inclure au scan"),
        StandardColumn(id: "site", title: "Site", isDefaultVisible: false),
        StandardColumn(id: "appareils", title: "Appareils vus", isDefaultVisible: false),
        StandardColumn(id: "derniereReponse", title: "Dernière réponse", isDefaultVisible: false),
    ]

    /// « ordre » n'est pas une colonne : c'est l'ordre d'enregistrement, tri par défaut (sans flèche).
    static let sortKeys: [String: KeyPathComparator<RegRangeRowData>] = [
        "ordre": KeyPathComparator(\RegRangeRowData.order),
        "plage": KeyPathComparator(\RegRangeRowData.text),
        "nom": KeyPathComparator(\RegRangeRowData.label),
        "format": KeyPathComparator(\RegRangeRowData.kind),
        "vlan": KeyPathComparator(\RegRangeRowData.sortVLAN),
        "adresses": KeyPathComparator(\RegRangeRowData.addresses),
        "inclure": KeyPathComparator(\RegRangeRowData.sortEnabled),
        "site": KeyPathComparator(\RegRangeRowData.site),
        "appareils": KeyPathComparator(\RegRangeRowData.devicesSeen),
        "derniereReponse": KeyPathComparator(\RegRangeRowData.sortLastSeen),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegRangeRowData> {
        StandardTableModel(id: "reglages.plages", columns: columns, sortKeys: sortKeys, defaultSort: "ordre")
    }

    /// Hauteur d'une ligne (champs modifiables de 24 pt) et de l'en-tête : le tableau est dans la
    /// page défilante des Réglages, il prend la hauteur de ses lignes.
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 42

    private var rows: [RegRangeRowData] {
        let site = siteName
        return ranges.enumerated().map { index, range in
            let parsed = try? range.parsed()
            let seen = parsed.map { parsed in devices.filter { parsed.contains($0.ip) } } ?? []
            return RegRangeRowData(range: range, order: index, site: site, addresses: parsed?.count ?? -1,
                                   devicesSeen: seen.count, lastSeen: seen.map(\.lastSeen).max())
        }
        .sorted(using: table.sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn("PLAGE", sortUsing: table.sort("plage")) { row in
                    Text(row.text).font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(row.addresses < 0 ? Theme.critical : Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .help(row.addresses < 0 ? "Plage invalide" : row.text)
                        .frame(height: Self.rowHeight - 8)
                        .opacity(row.range.isEnabled ? 1 : 0.55)
                }
                .width(min: 100, ideal: 160)
                .customizationID("plage")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                    RegInlineField(text: labelBinding(row.range), placeholder: "Nom", mono: false)
                }
                .width(min: 60, ideal: 170)
                .customizationID("nom")

                TableColumn("FORMAT", sortUsing: table.sort("format")) { row in
                    Text(row.kind).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .width(min: 40, ideal: 90)
                .customizationID("format")

                TableColumn("VLAN", sortUsing: table.sort("vlan")) { row in
                    HStack(spacing: 3) {
                        Text("VLAN").font(Theme.mono(11)).foregroundStyle(Theme.neutralText).fixedSize()
                        RegInlineField(text: vlanBinding(row.range), placeholder: "?", mono: true).frame(width: 44)
                    }
                }
                .width(min: 84, ideal: 100)
                .customizationID("vlan")

                TableColumn("ADRESSES", sortUsing: table.sort("adresses")) { row in
                    Text(row.addresses < 0 ? "—" : RegFormat.count(row.addresses))
                        .font(Theme.mono(12))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 72, ideal: 84)
                .customizationID("adresses")

                // En-tête court (« SCAN ») : « INCLURE AU SCAN » serait coupé en petite fenêtre.
                TableColumn("SCAN", sortUsing: table.sort("inclure")) { row in
                    RegSwitch(isOn: enabledBinding(row.range))
                        .help(row.range.isEnabled ? "Plage incluse au scan" : "Plage non incluse au scan")
                }
                .width(min: 56, ideal: 70)
                .customizationID("inclure")
            }

            Group {
                TableColumn("SITE", sortUsing: table.sort("site")) { row in
                    Text(row.site).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .width(min: 70, ideal: 120)
                .customizationID("site")
                .defaultVisibility(.hidden)

                TableColumn("APPAREILS VUS", sortUsing: table.sort("appareils")) { row in
                    Text(row.devicesSeen == 0 ? "—" : RegFormat.count(row.devicesSeen))
                        .font(Theme.mono(12))
                        .foregroundStyle(row.devicesSeen == 0 ? Theme.textTertiary : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Appareils de cette plage trouvés par le scan")
                }
                .width(min: 70, ideal: 100)
                .customizationID("appareils")
                .defaultVisibility(.hidden)

                TableColumn("DERNIÈRE RÉPONSE", sortUsing: table.sort("derniereReponse")) { row in
                    Text(row.lastSeen.map { ScanFormat.relative($0) } ?? "—")
                        .font(Theme.small)
                        .foregroundStyle(row.lastSeen == nil ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(1)
                        .help("Dernière réponse d’un appareil de cette plage")
                }
                .width(min: 80, ideal: 120)
                .customizationID("derniereReponse")
                .defaultVisibility(.hidden)

                TableColumn("") { row in
                    Button {
                        delete(row.range)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Supprimer la plage \(row.text)")
                }
                .width(32)
                .customizationID("actions")
                .disabledCustomizationBehavior(.all)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: RegRangeRowData.ID.self) { ids in
            if let id = ids.first, let range = ranges.first(where: { $0.id == id }) {
                Button(range.isEnabled ? "Exclure du scan" : "Inclure au scan") {
                    enabledBinding(range).wrappedValue.toggle()
                }
                Divider()
                Button("Supprimer la plage \(range.text)", role: .destructive) { delete(range) }
            }
        }
        .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(rows.count) + 16)
    }

    // MARK: Modifications

    private func index(of range: ScanRangeConfig) -> Int? { ranges.firstIndex { $0.id == range.id } }

    private func delete(_ range: ScanRangeConfig) {
        ranges.removeAll { $0.id == range.id }
    }

    private func labelBinding(_ range: ScanRangeConfig) -> Binding<String> {
        Binding(get: { range.label }, set: { value in
            if let index = index(of: range) { ranges[index].label = value }
        })
    }

    private func vlanBinding(_ range: ScanRangeConfig) -> Binding<String> {
        Binding(get: { range.vlan.map(String.init) ?? "" }, set: { value in
            guard let index = index(of: range) else { return }
            let digits = value.filter(\.isNumber)
            if digits.isEmpty {
                ranges[index].vlan = nil
            } else if let number = Int(digits), (1...4094).contains(number) {
                ranges[index].vlan = number
            }
        })
    }

    private func enabledBinding(_ range: ScanRangeConfig) -> Binding<Bool> {
        Binding(get: { ranges.first { $0.id == range.id }?.isEnabled ?? range.isEnabled }, set: { value in
            if let index = index(of: range) { ranges[index].isEnabled = value }
        })
    }
}

/// Champ modifiable sur place dans une cellule (nom, VLAN).
private struct RegInlineField: View {
    @Binding var text: String
    let placeholder: String
    let mono: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(11) : Theme.small)
            .padding(.horizontal, 4)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(mono ? Theme.neutralSoft : Color.clear))
    }
}
