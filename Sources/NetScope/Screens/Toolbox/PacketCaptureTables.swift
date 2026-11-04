import NetScopeCore
import SwiftUI

// Tableaux de la capture de paquets (tableau standard, note 8) : liste des paquets, protocoles,
// conversations et plus gros émetteurs.

/// Liste des paquets (« outils.paquets ») : n°, temps, source, destination, protocole, longueur,
/// résumé ; facultatives : heure, delta, ports, VLAN, MAC, TTL.
struct PacketListTable: View {
    let rows: [PacketRow]
    @ObservedObject var model: ToolPacketCaptureModel
    @ObservedObject var table: StandardTableModel<PacketRow>
    var maxRows = 8

    static let columns: [StandardColumn] = [
        StandardColumn(id: "numero", title: "N°", isRequired: true),
        StandardColumn(id: "temps", title: "Temps"),
        StandardColumn(id: "source", title: "Source"),
        StandardColumn(id: "destination", title: "Destination"),
        StandardColumn(id: "protocole", title: "Protocole"),
        StandardColumn(id: "longueur", title: "Longueur"),
        StandardColumn(id: "resume", title: "Résumé", isRequired: true),
        StandardColumn(id: "heure", title: "Heure", isDefaultVisible: false),
        StandardColumn(id: "delta", title: "Delta", isDefaultVisible: false),
        StandardColumn(id: "portSource", title: "Port source", isDefaultVisible: false),
        StandardColumn(id: "portDestination", title: "Port de destination", isDefaultVisible: false),
        StandardColumn(id: "vlan", title: "VLAN", isDefaultVisible: false),
        StandardColumn(id: "macSource", title: "MAC source", isDefaultVisible: false),
        StandardColumn(id: "macDestination", title: "MAC de destination", isDefaultVisible: false),
        StandardColumn(id: "ttl", title: "TTL", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<PacketRow>] = [
        "numero": KeyPathComparator(\PacketRow.id),
        "temps": KeyPathComparator(\PacketRow.time),
        "source": KeyPathComparator(\PacketRow.source),
        "destination": KeyPathComparator(\PacketRow.destination),
        "protocole": KeyPathComparator(\PacketRow.protocolLabel),
        "longueur": KeyPathComparator(\PacketRow.length),
        "resume": KeyPathComparator(\PacketRow.summary),
        "heure": KeyPathComparator(\PacketRow.date),
        "delta": KeyPathComparator(\PacketRow.delta),
        "portSource": KeyPathComparator(\PacketRow.sourcePort),
        "portDestination": KeyPathComparator(\PacketRow.destinationPort),
        "vlan": KeyPathComparator(\PacketRow.vlan),
        "macSource": KeyPathComparator(\PacketRow.ethSource),
        "macDestination": KeyPathComparator(\PacketRow.ethDestination),
        "ttl": KeyPathComparator(\PacketRow.ttl),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<PacketRow> {
        StandardTableModel(id: "outils.paquets", columns: columns, sortKeys: sortKeys, defaultSort: "numero")
    }

    var body: some View {
        // Ordre de capture par défaut : pas de tri à refaire tant que la colonne N° croissante est choisie.
        let sorted = table.currentSort.map { $0.column == "numero" && $0.ascending } ?? true ? rows : rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: maxRows, emptyText: "Aucun paquet ne correspond au filtre d’affichage.") {
            Table(sorted, selection: $model.selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group {
                    TableColumn("N°", sortUsing: table.sort("numero")) { row in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(row.isReset ? Theme.criticalBadge : row.isWarning ? Theme.warningDot : PacketPalette.colors(row.kind).0.opacity(0.55))
                                .frame(width: 3, height: 14)
                            ToolTableText("\(row.id)", alignment: .trailing)
                        }
                    }
                    .width(min: 40, ideal: 52)
                    .customizationID("numero")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("TEMPS", sortUsing: table.sort("temps")) { row in
                        ToolTableText(PacketText.seconds(row.time), color: Theme.textSecondary, alignment: .trailing)
                    }
                    .width(min: 52, ideal: 72)
                    .customizationID("temps")

                    TableColumn("SOURCE", sortUsing: table.sort("source")) { row in
                        ToolTableText(row.source).help(row.source)
                    }
                    .width(min: 70, ideal: 108)
                    .customizationID("source")

                    TableColumn("DESTINATION", sortUsing: table.sort("destination")) { row in
                        ToolTableText(row.destination).help(row.destination)
                    }
                    .width(min: 70, ideal: 108)
                    .customizationID("destination")

                    TableColumn("PROTOCOLE", sortUsing: table.sort("protocole")) { row in
                        PacketProtocolChip(kind: row.kind)
                    }
                    .width(min: 54, ideal: 88)
                    .customizationID("protocole")

                    TableColumn("LONG.", sortUsing: table.sort("longueur")) { row in
                        ToolTableText("\(row.length)", alignment: .trailing)
                    }
                    .width(min: 36, ideal: 48)
                    .customizationID("longueur")

                    TableColumn("RÉSUMÉ", sortUsing: table.sort("resume")) { row in
                        ToolTableText(row.summary, mono: false,
                                      color: row.isReset ? Theme.critical : row.isWarning ? Theme.warning : Theme.text)
                            .help(row.summary)
                    }
                    .width(min: 120, ideal: 230)
                    .customizationID("resume")
                    .disabledCustomizationBehavior(.visibility)
                }
                Group {
                    TableColumn("HEURE", sortUsing: table.sort("heure")) { row in
                        ToolTableText(Self.clock(row.date), color: Theme.textSecondary)
                    }
                    .width(min: 90, ideal: 110)
                    .customizationID("heure")
                    .defaultVisibility(.hidden)

                    TableColumn("DELTA", sortUsing: table.sort("delta")) { row in
                        ToolTableText(PacketText.seconds(row.delta), color: Theme.textSecondary, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 76)
                    .customizationID("delta")
                    .defaultVisibility(.hidden)

                    TableColumn("PORT SRC", sortUsing: table.sort("portSource")) { row in
                        ToolTableText(row.sourcePort < 0 ? "—" : "\(row.sourcePort)", alignment: .trailing)
                    }
                    .width(min: 50, ideal: 64)
                    .customizationID("portSource")
                    .defaultVisibility(.hidden)

                    TableColumn("PORT DEST", sortUsing: table.sort("portDestination")) { row in
                        ToolTableText(row.destinationPort < 0 ? "—" : "\(row.destinationPort)", alignment: .trailing)
                    }
                    .width(min: 50, ideal: 64)
                    .customizationID("portDestination")
                    .defaultVisibility(.hidden)

                    TableColumn("VLAN", sortUsing: table.sort("vlan")) { row in
                        ToolTableText(row.vlan < 0 ? "—" : "\(row.vlan)", alignment: .trailing)
                    }
                    .width(min: 40, ideal: 48)
                    .customizationID("vlan")
                    .defaultVisibility(.hidden)

                    TableColumn("MAC SOURCE", sortUsing: table.sort("macSource")) { row in
                        ToolTableText(row.ethSource)
                    }
                    .width(min: 110, ideal: 130)
                    .customizationID("macSource")
                    .defaultVisibility(.hidden)

                    TableColumn("MAC DEST", sortUsing: table.sort("macDestination")) { row in
                        ToolTableText(row.ethDestination)
                    }
                    .width(min: 110, ideal: 130)
                    .customizationID("macDestination")
                    .defaultVisibility(.hidden)

                    TableColumn("TTL", sortUsing: table.sort("ttl")) { row in
                        ToolTableText(row.ttl < 0 ? "—" : "\(row.ttl)", alignment: .trailing)
                    }
                    .width(min: 36, ideal: 44)
                    .customizationID("ttl")
                    .defaultVisibility(.hidden)
                }
            }
        }
    }

    /// « 10:21:33,204518 ».
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm:ss"
        let micros = Int((date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)) * 1_000_000)
        return formatter.string(from: date) + "," + String(format: "%06d", micros)
    }
}

// MARK: - Statistiques

struct ProtocolStatRow: Identifiable {
    let stat: ProtocolStatistic
    let share: Double
    var id: String { stat.id }
    var label: String { stat.kind.label }
    var packets: Int { stat.packets }
    var bytes: Int { stat.bytes }
}

struct ProtocolStatsTable: View {
    let rows: [ProtocolStatRow]
    @ObservedObject var table: StandardTableModel<ProtocolStatRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "protocole", title: "Protocole", isRequired: true),
        StandardColumn(id: "paquets", title: "Paquets"),
        StandardColumn(id: "part", title: "Part des paquets"),
        StandardColumn(id: "octets", title: "Octets"),
    ]

    static let sortKeys: [String: KeyPathComparator<ProtocolStatRow>] = [
        "protocole": KeyPathComparator(\ProtocolStatRow.label),
        "paquets": KeyPathComparator(\ProtocolStatRow.packets, order: .reverse),
        "part": KeyPathComparator(\ProtocolStatRow.share, order: .reverse),
        "octets": KeyPathComparator(\ProtocolStatRow.bytes, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<ProtocolStatRow> {
        StandardTableModel(id: "outils.paquets.protocoles", columns: columns, sortKeys: sortKeys, defaultSort: "paquets")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 8) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("PROTOCOLE", sortUsing: table.sort("protocole")) { row in PacketProtocolChip(kind: row.stat.kind) }
                    .width(min: 70, ideal: 90)
                    .customizationID("protocole")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("PAQUETS", sortUsing: table.sort("paquets")) { row in ToolTableText(PacketText.number(row.packets), alignment: .trailing) }
                    .width(min: 56, ideal: 70)
                    .customizationID("paquets")
                TableColumn("PART", sortUsing: table.sort("part")) { row in
                    HStack(spacing: 6) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.neutralSoft)
                                Capsule().fill(PacketPalette.colors(row.stat.kind).0.opacity(0.7))
                                    .frame(width: max(2, proxy.size.width * row.share))
                            }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.1f", row.share * 100).replacingOccurrences(of: ".", with: ",") + "\u{00A0}%")
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .width(min: 110, ideal: 170)
                .customizationID("part")
                TableColumn("OCTETS", sortUsing: table.sort("octets")) { row in ToolTableText(PacketText.bytes(row.bytes), alignment: .trailing) }
                    .width(min: 60, ideal: 80)
                    .customizationID("octets")
            }
        }
    }
}

struct ConversationStatRow: Identifiable {
    let stat: ConversationStatistic
    var id: String { stat.id }
    var a: String { stat.key.a.label }
    var b: String { stat.key.b.label }
    var kind: String { stat.key.kind.label }
    var packets: Int { stat.packets }
    var bytes: Int { stat.bytes }
    var aToB: Int { stat.bytesAToB }
    var bToA: Int { stat.bytesBToA }
    var duration: Double { stat.duration }
}

struct ConversationStatsTable: View {
    let rows: [ConversationStatRow]
    @ObservedObject var table: StandardTableModel<ConversationStatRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "a", title: "Adresse A", isRequired: true),
        StandardColumn(id: "b", title: "Adresse B"),
        StandardColumn(id: "transport", title: "Transport"),
        StandardColumn(id: "paquets", title: "Paquets"),
        StandardColumn(id: "octets", title: "Octets"),
        StandardColumn(id: "aVersB", title: "A → B", isDefaultVisible: false),
        StandardColumn(id: "bVersA", title: "B → A", isDefaultVisible: false),
        StandardColumn(id: "duree", title: "Durée"),
    ]

    static let sortKeys: [String: KeyPathComparator<ConversationStatRow>] = [
        "a": KeyPathComparator(\ConversationStatRow.a),
        "b": KeyPathComparator(\ConversationStatRow.b),
        "transport": KeyPathComparator(\ConversationStatRow.kind),
        "paquets": KeyPathComparator(\ConversationStatRow.packets, order: .reverse),
        "octets": KeyPathComparator(\ConversationStatRow.bytes, order: .reverse),
        "aVersB": KeyPathComparator(\ConversationStatRow.aToB, order: .reverse),
        "bVersA": KeyPathComparator(\ConversationStatRow.bToA, order: .reverse),
        "duree": KeyPathComparator(\ConversationStatRow.duration, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<ConversationStatRow> {
        StandardTableModel(id: "outils.paquets.conversations", columns: columns, sortKeys: sortKeys, defaultSort: "octets")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 8) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("ADRESSE A", sortUsing: table.sort("a")) { row in ToolTableText(row.a).help(row.a) }
                    .width(min: 100, ideal: 170)
                    .customizationID("a")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("ADRESSE B", sortUsing: table.sort("b")) { row in ToolTableText(row.b).help(row.b) }
                    .width(min: 100, ideal: 170)
                    .customizationID("b")
                TableColumn("TRANSPORT", sortUsing: table.sort("transport")) { row in PacketProtocolChip(kind: row.stat.key.kind) }
                    .width(min: 60, ideal: 76)
                    .customizationID("transport")
                TableColumn("PAQUETS", sortUsing: table.sort("paquets")) { row in ToolTableText(PacketText.number(row.packets), alignment: .trailing) }
                    .width(min: 50, ideal: 62)
                    .customizationID("paquets")
                TableColumn("OCTETS", sortUsing: table.sort("octets")) { row in ToolTableText(PacketText.bytes(row.bytes), alignment: .trailing) }
                    .width(min: 60, ideal: 76)
                    .customizationID("octets")
                TableColumn("A → B", sortUsing: table.sort("aVersB")) { row in ToolTableText(PacketText.bytes(row.aToB), alignment: .trailing) }
                    .width(min: 60, ideal: 76)
                    .customizationID("aVersB")
                    .defaultVisibility(.hidden)
                TableColumn("B → A", sortUsing: table.sort("bVersA")) { row in ToolTableText(PacketText.bytes(row.bToA), alignment: .trailing) }
                    .width(min: 60, ideal: 76)
                    .customizationID("bVersA")
                    .defaultVisibility(.hidden)
                TableColumn("DURÉE", sortUsing: table.sort("duree")) { row in
                    ToolTableText(PacketText.seconds(row.duration, decimals: 3) + "\u{00A0}s", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 60, ideal: 76)
                .customizationID("duree")
            }
        }
    }
}

struct TalkerStatRow: Identifiable {
    let stat: TalkerStatistic
    var id: String { stat.id }
    var address: String { stat.address }
    var packetsSent: Int { stat.packetsSent }
    var bytesSent: Int { stat.bytesSent }
    var packetsReceived: Int { stat.packetsReceived }
    var bytesReceived: Int { stat.bytesReceived }
}

struct TalkerStatsTable: View {
    let rows: [TalkerStatRow]
    @ObservedObject var table: StandardTableModel<TalkerStatRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "adresse", title: "Adresse", isRequired: true),
        StandardColumn(id: "paquetsEmis", title: "Paquets émis"),
        StandardColumn(id: "octetsEmis", title: "Octets émis"),
        StandardColumn(id: "paquetsRecus", title: "Paquets reçus"),
        StandardColumn(id: "octetsRecus", title: "Octets reçus"),
    ]

    static let sortKeys: [String: KeyPathComparator<TalkerStatRow>] = [
        "adresse": KeyPathComparator(\TalkerStatRow.address),
        "paquetsEmis": KeyPathComparator(\TalkerStatRow.packetsSent, order: .reverse),
        "octetsEmis": KeyPathComparator(\TalkerStatRow.bytesSent, order: .reverse),
        "paquetsRecus": KeyPathComparator(\TalkerStatRow.packetsReceived, order: .reverse),
        "octetsRecus": KeyPathComparator(\TalkerStatRow.bytesReceived, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<TalkerStatRow> {
        StandardTableModel(id: "outils.paquets.emetteurs", columns: columns, sortKeys: sortKeys, defaultSort: "octetsEmis")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 8) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("ADRESSE", sortUsing: table.sort("adresse")) { row in ToolTableText(row.address, weight: .semibold).help(row.address) }
                    .width(min: 110, ideal: 200)
                    .customizationID("adresse")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("PAQUETS ÉMIS", sortUsing: table.sort("paquetsEmis")) { row in ToolTableText(PacketText.number(row.packetsSent), alignment: .trailing) }
                    .width(min: 60, ideal: 90)
                    .customizationID("paquetsEmis")
                TableColumn("OCTETS ÉMIS", sortUsing: table.sort("octetsEmis")) { row in ToolTableText(PacketText.bytes(row.bytesSent), alignment: .trailing) }
                    .width(min: 60, ideal: 90)
                    .customizationID("octetsEmis")
                TableColumn("PAQUETS REÇUS", sortUsing: table.sort("paquetsRecus")) { row in ToolTableText(PacketText.number(row.packetsReceived), alignment: .trailing) }
                    .width(min: 60, ideal: 90)
                    .customizationID("paquetsRecus")
                TableColumn("OCTETS REÇUS", sortUsing: table.sort("octetsRecus")) { row in ToolTableText(PacketText.bytes(row.bytesReceived), alignment: .trailing) }
                    .width(min: 60, ideal: 90)
                    .customizationID("octetsRecus")
            }
        }
    }
}
