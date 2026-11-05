import NetScopeCore
import SwiftUI

/// Journal des transferts TFTP (tableau standard « outils.tftp », note 8) : heure, appareil, sens,
/// fichier, taille, progression, débit, état et détail en clair ; facultatives : rôle, durée,
/// taille de bloc.
struct TFTPJournalTable: View {
    let rows: [TFTPTransferRecord]
    @ObservedObject var table: StandardTableModel<TFTPTransferRecord>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "heure", title: "Heure", isRequired: true),
        StandardColumn(id: "appareil", title: "Appareil"),
        StandardColumn(id: "sens", title: "Sens", isDefaultVisible: false),
        StandardColumn(id: "fichier", title: "Fichier"),
        StandardColumn(id: "taille", title: "Taille"),
        StandardColumn(id: "progression", title: "Progression"),
        StandardColumn(id: "debit", title: "Débit"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "detail", title: "Détail", isDefaultVisible: false),
        StandardColumn(id: "role", title: "Rôle", isDefaultVisible: false),
        StandardColumn(id: "duree", title: "Durée", isDefaultVisible: false),
        StandardColumn(id: "bloc", title: "Bloc", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<TFTPTransferRecord>] = [
        "heure": KeyPathComparator(\TFTPTransferRecord.date),
        "appareil": KeyPathComparator(\TFTPTransferRecord.peerSort),
        "sens": KeyPathComparator(\TFTPTransferRecord.flow.label),
        "fichier": KeyPathComparator(\TFTPTransferRecord.filename),
        "taille": KeyPathComparator(\TFTPTransferRecord.sizeSort),
        "progression": KeyPathComparator(\TFTPTransferRecord.progressSort),
        "debit": KeyPathComparator(\TFTPTransferRecord.rateSort),
        "etat": KeyPathComparator(\TFTPTransferRecord.statusText),
        "detail": KeyPathComparator(\TFTPTransferRecord.detail),
        "role": KeyPathComparator(\TFTPTransferRecord.role.label),
        "duree": KeyPathComparator(\TFTPTransferRecord.seconds),
        "bloc": KeyPathComparator(\TFTPTransferRecord.blockSort),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<TFTPTransferRecord> {
        StandardTableModel(id: "outils.tftp", columns: columns, sortKeys: sortKeys, defaultSort: "heure", defaultAscending: false)
    }

    /// Ligne copiée (tabulations).
    static func line(_ record: TFTPTransferRecord) -> String {
        [ToolText.time(record.date), record.peerLabel, record.role.label, record.flow.label, record.filename, record.sizeText,
         record.rateText, record.statusText, record.detail].joined(separator: "\t")
    }

    var body: some View {
        ToolStandardTableFrame(rowCount: rows.count, maxRows: 10,
                               emptyText: "Aucun transfert pour ce site. Démarrez le serveur ou lancez un transfert client.") {
            Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                Group {
                    TableColumn("HEURE", sortUsing: table.sort("heure")) { record in
                        ToolTableText(ToolText.time(record.date), size: 11, color: Theme.textSecondary)
                    }
                    .width(min: 60, ideal: 70)
                    .customizationID("heure")
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("APPAREIL", sortUsing: table.sort("appareil")) { record in
                        HStack(spacing: 6) {
                            ToolTableText(record.peer, size: 11, weight: .semibold)
                                .fixedSize()
                            if let name = record.peerName {
                                ToolTableText(name, size: 11, mono: false, color: Theme.textSecondary)
                            }
                        }
                        .help(record.peerLabel)
                    }
                    .width(min: 100, ideal: 160)
                    .customizationID("appareil")

                    TableColumn("SENS", sortUsing: table.sort("sens")) { record in
                        HStack(spacing: 4) {
                            Image(systemName: record.flow.symbol).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(record.flow == .toDevice ? Theme.accentStrong : Theme.success)
                            ToolTableText(record.flow.label, size: 11, mono: false)
                        }
                        .help(record.flowHelp)
                    }
                    .width(min: 66, ideal: 78)
                    .customizationID("sens")
                    .defaultVisibility(.hidden)

                    TableColumn("FICHIER", sortUsing: table.sort("fichier")) { record in
                        HStack(spacing: 5) {
                            Image(systemName: record.flow.symbol).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(record.flow == .toDevice ? Theme.accentStrong : Theme.success)
                                .frame(width: 12)
                            ToolTableText(record.filename, size: 11)
                        }
                        .help("\(record.filename)\n\(record.flowHelp)")
                    }
                    .width(min: 110, ideal: 180)
                    .customizationID("fichier")

                    TableColumn("TAILLE", sortUsing: table.sort("taille")) { record in
                        ToolTableText(record.status == .refused ? "—" : TFTPFormat.bytes(record.total ?? record.bytes), size: 11,
                                      color: record.status == .refused ? Theme.textTertiary : Theme.text, alignment: .trailing)
                    }
                    .width(min: 56, ideal: 62)
                    .customizationID("taille")

                    TableColumn("PROGRESSION", sortUsing: table.sort("progression")) { record in
                        TFTPProgressCell(record: record)
                    }
                    .width(min: 70, ideal: 92)
                    .customizationID("progression")
                }
                Group {
                    TableColumn("DÉBIT", sortUsing: table.sort("debit")) { record in
                        ToolTableText(record.bytes > 0 ? record.rateText : "—", size: 11,
                                      color: record.bytes > 0 ? Theme.text : Theme.textTertiary, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 70)
                    .customizationID("debit")

                    TableColumn("ÉTAT", sortUsing: table.sort("etat")) { record in
                        Chip(text: record.statusText, tone: record.status.tone)
                            .help(record.detail.isEmpty ? record.status.label : record.detail)
                    }
                    .width(min: 64, ideal: 104)
                    .customizationID("etat")

                    TableColumn("DÉTAIL", sortUsing: table.sort("detail")) { record in
                        ToolTableText(record.detail, size: 11, mono: false,
                                      color: record.status == .failed || record.status == .refused ? Theme.critical : Theme.textSecondary)
                            .help(record.detail)
                    }
                    .width(min: 120, ideal: 260)
                    .customizationID("detail")
                    .defaultVisibility(.hidden)

                    TableColumn("RÔLE", sortUsing: table.sort("role")) { record in
                        ToolTableText(record.role.label, size: 11, mono: false)
                    }
                    .width(min: 56, ideal: 64)
                    .customizationID("role")
                    .defaultVisibility(.hidden)

                    TableColumn("DURÉE", sortUsing: table.sort("duree")) { record in
                        ToolTableText(record.seconds > 0 ? ToolFormat.seconds(record.seconds) : "—", size: 11, alignment: .trailing)
                    }
                    .width(min: 56, ideal: 66)
                    .customizationID("duree")
                    .defaultVisibility(.hidden)

                    TableColumn("BLOC", sortUsing: table.sort("bloc")) { record in
                        ToolTableText(record.blockSize.map(String.init) ?? "—", size: 11, alignment: .trailing)
                    }
                    .width(min: 44, ideal: 56)
                    .customizationID("bloc")
                    .defaultVisibility(.hidden)
                }
            }
        }
    }
}

/// Barre d'avancement d'un transfert, avec le pourcentage.
private struct TFTPProgressCell: View {
    let record: TFTPTransferRecord

    var body: some View {
        if let fraction = record.fraction, record.status != .refused {
            HStack(spacing: 6) {
                ProgressBar(fraction: fraction, color: color, height: 5)
                if record.status != .done {
                    Text("\(Int((fraction * 100).rounded(.down)))\u{00A0}%")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .help(record.sizeText)
        } else if record.status == .running {
            ProgressView().controlSize(.mini)
        } else {
            ToolTableText("—", size: 11, color: Theme.textTertiary)
        }
    }

    private var color: Color {
        switch record.status {
        case .done: return Theme.success
        case .failed, .cancelled: return Theme.warning
        default: return Theme.accent
        }
    }
}

extension TFTPTransferRecord.Status {
    var tone: Tone {
        switch self {
        case .running: return .accent
        case .done: return .success
        case .failed: return .critical
        case .refused: return .warning
        case .cancelled: return .neutral
        }
    }
}

extension TFTPTransferRecord {
    /// « 10.182.122.3 · Switch étage 2 ».
    var peerLabel: String { peerName.map { "\(peer) · \($0)" } ?? peer }
    var peerSort: IPv4Address { IPv4Address(peer) ?? IPv4Address(0) }
    var sizeSort: Int64 { total ?? bytes }
    var progressSort: Double { fraction ?? -1 }
    var rateSort: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
    var blockSort: Int { blockSize ?? 0 }

    var flowHelp: String {
        switch (role, flow) {
        case (.server, .toDevice): return "L’appareil a lu ce fichier sur le Mac (RRQ)."
        case (.server, .fromDevice): return "L’appareil a écrit ce fichier sur le Mac (WRQ)."
        case (.client, .toDevice): return "Le Mac a envoyé ce fichier à l’appareil (put)."
        case (.client, .fromDevice): return "Le Mac a récupéré ce fichier de l’appareil (get)."
        }
    }
}
