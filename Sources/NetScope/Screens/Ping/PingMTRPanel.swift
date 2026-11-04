import AppKit
import NetScopeCore
import SwiftUI

/// Un saut du tableau MTR, avec le nom affiché et les clés de tri.
struct PingHopLine: Identifiable {
    let hop: PingMTRHop
    /// Nom inverse (PTR), nom de la cible, adresse, « (sans PTR) » ou « ??? ».
    let host: String

    var id: Int { hop.ttl }
    var stats: PingHopStats { hop.stats }

    // MARK: Clés de tri (une valeur absente passe après les autres)

    var sortTTL: Int { hop.ttl }
    var sortHost: String { host }
    var sortAddress: IPv4Address { hop.address ?? IPv4Address(UInt32.max) }
    var sortLoss: Double { stats.lossPercent }
    var sortSent: Int { stats.sent }
    var sortReceived: Int { stats.received }
    var sortLost: Int { stats.lost }
    var sortLast: Double { stats.last ?? .greatestFiniteMagnitude }
    var sortAverage: Double { stats.average ?? .greatestFiniteMagnitude }
    var sortBest: Double { stats.best ?? .greatestFiniteMagnitude }
    var sortWorst: Double { stats.worst ?? .greatestFiniteMagnitude }
    var sortDeviation: Double { stats.standardDeviation ?? .greatestFiniteMagnitude }
}

/// Tableau MTR / traceroute vers la cible sélectionnée (tableau standard, note 8).
struct PingMTRPanel: View {
    @ObservedObject var controller: PingController
    let target: PingTarget
    @StateObject private var table = StandardTableModel<PingHopLine>(
        id: "ping.mtr", columns: PingMTRPanel.columns, sortKeys: PingMTRPanel.sortKeys, defaultSort: "numero")

    /// Ligne du croquis : 32 ; au-delà de `maxRows` sauts, le tableau défile.
    static let rowHeight: CGFloat = 32
    static let maxRows = 15

    /// « Envoyés » est masquée par défaut : c'est le nombre de cycles, déjà dans le sous-titre, et
    /// les dix colonnes du croquis ne tiennent pas dans la colonne de gauche.
    static let columns: [StandardColumn] = [
        StandardColumn(id: "numero", title: "N°", isRequired: true),
        StandardColumn(id: "hote", title: "Hôte"),
        StandardColumn(id: "ip", title: "IP"),
        StandardColumn(id: "perte", title: "Perte"),
        StandardColumn(id: "envoyes", title: "Envoyés", isDefaultVisible: false),
        StandardColumn(id: "dernier", title: "Dernier"),
        StandardColumn(id: "moyenne", title: "Moy"),
        StandardColumn(id: "meilleur", title: "Meilleur"),
        StandardColumn(id: "pire", title: "Pire"),
        StandardColumn(id: "ecartType", title: "Écart-type"),
        StandardColumn(id: "recus", title: "Reçus", isDefaultVisible: false),
        StandardColumn(id: "perdus", title: "Perdus", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<PingHopLine>] = [
        "numero": KeyPathComparator(\PingHopLine.sortTTL),
        "hote": KeyPathComparator(\PingHopLine.sortHost),
        "ip": KeyPathComparator(\PingHopLine.sortAddress),
        "perte": KeyPathComparator(\PingHopLine.sortLoss),
        "envoyes": KeyPathComparator(\PingHopLine.sortSent),
        "dernier": KeyPathComparator(\PingHopLine.sortLast),
        "moyenne": KeyPathComparator(\PingHopLine.sortAverage),
        "meilleur": KeyPathComparator(\PingHopLine.sortBest),
        "pire": KeyPathComparator(\PingHopLine.sortWorst),
        "ecartType": KeyPathComparator(\PingHopLine.sortDeviation),
        "recus": KeyPathComparator(\PingHopLine.sortReceived),
        "perdus": KeyPathComparator(\PingHopLine.sortLost),
    ]

    var body: some View {
        let report = controller.mtrReport
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MTR / Traceroute").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    (Text("vers ").foregroundColor(Theme.textSecondary)
                        + Text(target.addressLabel).font(Theme.mono(12)).foregroundColor(Theme.text)
                        + Text(" · \(info(report))").foregroundColor(Theme.textSecondary))
                        .font(Theme.small)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if controller.isMTRRunning {
                    Button { controller.stopMTR() } label: {
                        Label("Arrêter", systemImage: "stop.fill").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(PingSmallButtonStyle())
                } else {
                    Button { controller.startMTR() } label: {
                        Label("Lancer MTR", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(PingSmallButtonStyle(prominent: true))
                    .disabled(target.address == nil)
                }
                Button("Résolution DNS : \(controller.resolveHopNames ? "oui" : "non")") {
                    controller.resolveHopNames.toggle()
                }
                .buttonStyle(PingSmallButtonStyle())
                .help("Afficher le nom inverse (PTR) de chaque saut")
                Button("Copier le rapport") { controller.copyMTRReport() }
                    .buttonStyle(PingSmallButtonStyle())
                    .disabled(report == nil)
                // Icône seule : l'en-tête du croquis est déjà plein (aussi au clic droit sur l'en-tête).
                StandardColumnsMenu(model: table, compact: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            if let report, !report.hops.isEmpty {
                let rows = report.hops.map { PingHopLine(hop: $0, host: hostname(for: $0)) }
                    .sorted(using: table.sortOrder)
                PingHopTable(rows: rows, controller: controller, table: table)
                    .standardTableHeight(rows: rows.count, rowHeight: Self.rowHeight, maxRows: Self.maxRows)
            } else {
                Text(placeholder)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 13))
                Text(note(report)).fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private func hostname(for hop: PingMTRHop) -> String {
        guard let address = hop.address else { return "???" }
        if hop.isDestination, controller.resolveHopNames, controller.hostnames[address] == nil,
           target.name != target.addressLabel {
            return target.name
        }
        guard controller.resolveHopNames else { return address.description }
        return controller.hostnames[address] ?? "(sans PTR)"
    }

    private func info(_ report: PingMTRReport?) -> String {
        guard let report, report.cycles > 0 else { return controller.isMTRRunning ? "découverte du chemin…" : "pas encore lancé" }
        let hops = report.hops.count
        return "\(hops) \(hops > 1 ? "sauts" : "saut") · \(report.cycles) cycles · ICMP"
    }

    private var placeholder: String {
        if let error = controller.mtrError { return error }
        if controller.isMTRRunning { return "Découverte du chemin en cours (TTL 1 à 30)…" }
        return "Cliquer sur « Lancer MTR » pour suivre chaque saut du chemin vers \(target.addressLabel) : perte, latence et écart-type par routeur."
    }

    private func note(_ report: PingMTRReport?) -> String {
        guard let report, !report.hops.isEmpty else {
            return "Le MTR envoie un Echo Request par saut et par cycle (TTL croissant) ; chaque routeur répond par « Time Exceeded »."
        }
        if report.hops.count == 1 {
            return "Même sous-réseau : 1 seul saut L3. Le chemin L2 (switchs et ports) se lit sur l’écran Switchs et ports."
        }
        if report.hops.count == 2 {
            return "Routage par la passerelle. Une perte sur le dernier saut seulement pointe vers l’appareil ou son port de switch, pas vers le cœur."
        }
        return "Une perte sur un saut intermédiaire qui ne se propage pas aux sauts suivants vient d’une limitation ICMP du routeur, pas d’une vraie perte sur le chemin."
    }
}

/// Tableau des sauts : clic droit pour copier l'adresse ou l'ajouter au ping continu.
private struct PingHopTable: View {
    let rows: [PingHopLine]
    @ObservedObject var controller: PingController
    @ObservedObject var table: StandardTableModel<PingHopLine>

    /// Hauteur du contenu d'une cellule (la ligne fait 32 avec les marges du tableau).
    static let cellHeight: CGFloat = 24

    var body: some View {
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            Group {
                TableColumn(StandardTableHeading("N°"), sortUsing: table.sort("numero")) { line in
                    PingCell("\(line.hop.ttl)", color: Theme.textSecondary)
                        .frame(height: Self.cellHeight)
                }
                .width(min: 24, ideal: 28, max: 40)
                .customizationID("numero")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(StandardTableHeading("HÔTE"), sortUsing: table.sort("hote")) { line in
                    let dimmed = line.host.hasPrefix("(") || line.host == "???"
                    Text(line.host)
                        .font(.system(size: 12, weight: line.hop.isDestination ? .semibold : .regular))
                        .foregroundStyle(dimmed ? Theme.textSecondary : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(line.hop.isDestination ? "\(line.host) · destination" : line.host)
                }
                .width(min: 80, ideal: 94)
                .customizationID("hote")

                TableColumn(StandardTableHeading("IP"), sortUsing: table.sort("ip")) { line in
                    PingCell(line.hop.address?.description ?? "—", mono: true, size: 11)
                }
                .width(min: 100, ideal: 110)
                .customizationID("ip")

                TableColumn(StandardTableHeading("PERTE"), sortUsing: table.sort("perte")) { line in
                    let loss = line.stats.lossPercent
                    PingCell(PingFormat.percent(loss), mono: true, color: pingLossColor(loss), bold: loss > 0, trailing: true)
                }
                .width(min: 46, ideal: 52)
                .customizationID("perte")

                TableColumn(StandardTableHeading("ENVOYÉS"), sortUsing: table.sort("envoyes")) { line in
                    PingCell("\(line.stats.sent)", mono: true, color: Theme.textSecondary, trailing: true)
                }
                .width(min: 56, ideal: 64)
                .customizationID("envoyes")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("DERNIER"), sortUsing: table.sort("dernier")) { line in
                    PingCell(PingFormat.decimal(line.stats.last), mono: true, trailing: true)
                }
                .width(min: 54, ideal: 60)
                .customizationID("dernier")

                TableColumn(StandardTableHeading("MOY"), sortUsing: table.sort("moyenne")) { line in
                    PingCell(PingFormat.decimal(line.stats.average), mono: true, bold: true, trailing: true)
                }
                .width(min: 38, ideal: 42)
                .customizationID("moyenne")

                TableColumn(StandardTableHeading("MEILLEUR"), sortUsing: table.sort("meilleur")) { line in
                    PingCell(PingFormat.decimal(line.stats.best), mono: true, trailing: true)
                }
                .width(min: 60, ideal: 68)
                .customizationID("meilleur")

                TableColumn(StandardTableHeading("PIRE"), sortUsing: table.sort("pire")) { line in
                    PingCell(PingFormat.decimal(line.stats.worst), mono: true, trailing: true)
                }
                .width(min: 38, ideal: 42)
                .customizationID("pire")

                TableColumn(StandardTableHeading("ÉCART-TYPE"), sortUsing: table.sort("ecartType")) { line in
                    PingCell(PingFormat.decimal(line.stats.standardDeviation), mono: true, trailing: true)
                }
                .width(min: 70, ideal: 80)
                .customizationID("ecartType")
            }

            Group {
                TableColumn(StandardTableHeading("REÇUS"), sortUsing: table.sort("recus")) { line in
                    PingCell("\(line.stats.received)", mono: true, trailing: true)
                }
                .width(min: 48, ideal: 56)
                .customizationID("recus")
                .defaultVisibility(.hidden)

                TableColumn(StandardTableHeading("PERDUS"), sortUsing: table.sort("perdus")) { line in
                    PingCell("\(line.stats.lost)", mono: true,
                             color: line.stats.lost > 0 ? pingLossColor(line.stats.lossPercent) : Theme.text, trailing: true)
                }
                .width(min: 50, ideal: 60)
                .customizationID("perdus")
                .defaultVisibility(.hidden)
            }
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: Int.self) { ttls in
            if let ttl = ttls.first, let address = rows.first(where: { $0.id == ttl })?.hop.address {
                Button("Copier l’adresse") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address.description, forType: .string)
                }
                Button("Ajouter au ping continu") { controller.add(address.description) }
            }
        }
    }
}

/// Texte d'une cellule des tableaux du Ping (une ligne ; chiffres alignés à droite en police mono).
struct PingCell: View {
    let text: String
    var mono = false
    var color: Color = Theme.text
    var bold = false
    var size: CGFloat = 12
    /// Nombre aligné à droite (croquis).
    var trailing = false

    init(_ text: String, mono: Bool = false, color: Color = Theme.text, bold: Bool = false, size: CGFloat = 12,
         trailing: Bool = false) {
        self.text = text
        self.mono = mono
        self.color = color
        self.bold = bold
        self.size = size
        self.trailing = trailing
    }

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(size, weight: bold ? .semibold : .regular) : .system(size: size))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// Petit bouton du croquis (hauteur 28, 12 pt).
struct PingSmallButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(prominent ? (configuration.isPressed ? Theme.accentStrong : Theme.accent)
                                : (configuration.isPressed ? Theme.panelMuted : Theme.panel)))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(prominent ? Color.clear : Theme.borderStrong))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}
