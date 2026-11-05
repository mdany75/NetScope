import AppKit
import NetScopeCore
import SwiftUI

/// Carte d'occupation d'un bloc de /24 à /16 (note 78) : carte des pages (/24) du bloc, puis la
/// page choisie en 16 × 16 cases, avec le détail de l'adresse survolée ou choisie. Croise les
/// fiches du scan, les étendues, baux et réservations DHCP de la FortiGate et les plages exclues
/// du site ; propose la prochaine IP libre hors étendue DHCP de la page.
/// Note 84 : appareils filaires (vert) et Wi-Fi (cyan, symbole Wi-Fi), repère dans le coin pour une
/// adresse attribuée par bail DHCP (triangle) ou gardée par une réservation (point), légende dessous.
struct AnaOccupancyPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    let plan: AddressPlan
    let records: [InvRecord]
    let now: Date
    /// Site du bloc (nil : site actif) ; `siteName` : affiché quand plusieurs sites sont choisis.
    var siteKey: String?
    var siteName: String?
    /// Page montrée d'abord (celle du Mac, ou la plage choisie).
    var preferredPage: IPv4Address?
    /// Lecture DHCP de la FortiGate du site (nil : aucune étendue lue).
    var dhcpReadAt: Date?
    /// Change la taille du bloc (/24 à /16) autour de la page donnée.
    var onPrefix: (Int, IPv4Address) -> Void = { _, _ in }

    @State private var page: IPv4Address?
    /// Captures : NETSCOPE_ANA_ADRESSE=10.182.122.153 choisit l’adresse détaillée (démonstration).
    @State private var selected: IPv4Address? = Launcher.isDemo
        ? ProcessInfo.processInfo.environment["NETSCOPE_ANA_ADRESSE"].flatMap { IPv4Address($0) } : nil
    @State private var hovered: IPv4Address?
    @State private var copied: IPv4Address?

    private static let cell: CGFloat = 19
    private static let gap: CGFloat = 3
    private static let gridWidth: CGFloat = 30 + 16 * (cell + gap)

    var body: some View {
        let shownPage = page.flatMap { plan.page(containing: $0) } ?? plan.defaultPage(preferring: preferredPage)
        let cells = plan.cells(page: shownPage.base)
        let focusIP = hovered ?? selected.flatMap { shownPage.base.value == $0.value & 0xFFFF_FF00 ? $0 : nil } ?? Self.defaultFocus(cells)
        let focus = cells[Int(focusIP.value & 0xFF)]

        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                InvPanelTitle(title: "Carte d’occupation", subtitle: subtitle(page: shownPage),
                              shorterSubtitles: shorterSubtitles(page: shownPage)) {
                    blockMenu(page: shownPage)
                }
                if plan.pageCount > 1 {
                    pagesMap(current: shownPage)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        header
                        ForEach(0..<16, id: \.self) { row in
                            HStack(spacing: Self.gap) {
                                Text(".\(row * 16)").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 30, alignment: .leading)
                                ForEach(0..<16, id: \.self) { column in
                                    let item = cells[row * 16 + column]
                                    cellView(item, isFocus: item.ip == focus.ip)
                                }
                            }
                        }
                        legend(shownPage, cells: cells).padding(.top, 8)
                    }
                    .frame(width: Self.gridWidth, alignment: .leading)
                    detail(focus)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                nextFree(page: shownPage)
            }
        }
    }

    /// Versions plus courtes, sans doublon (identifiants de ViewThatFits).
    private func shorterSubtitles(page: AddressPlanPage) -> [String] {
        let full = subtitle(page: page)
        var result: [String] = []
        for text in [(siteName.map { $0 + " · " } ?? "") + plan.block.description, plan.block.description]
            where text != full && !result.contains(text) {
            result.append(text)
        }
        return result
    }

    private func subtitle(page: AddressPlanPage) -> String {
        let prefix = siteName.map { $0 + " · " } ?? ""
        if plan.pageCount > 1 {
            return prefix + "\(plan.block) · \(plan.pageCount) pages de /24 · page \(page.label)"
        }
        return prefix + "\(plan.block) · survolez une case pour voir l’adresse"
    }

    // MARK: Taille du bloc et carte des pages

    private func blockMenu(page: AddressPlanPage) -> some View {
        Menu {
            ForEach(Array(stride(from: 24, through: AddressPlan.minPrefix, by: -1)), id: \.self) { prefix in
                let block = Subnet(address: page.base, prefix: prefix)
                Button {
                    self.page = page.base
                    onPrefix(prefix, page.base)
                } label: {
                    let pages = 1 << (24 - prefix)
                    Text("/\(prefix) · \(block)" + (pages > 1 ? " · \(pages) pages" : ""))
                }
                .disabled(prefix == plan.block.prefix)
            }
        } label: {
            Label("Bloc /\(plan.block.prefix)", systemImage: "square.grid.3x3")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Taille de la carte\u{00A0}: un /24 seul, ou un bloc de /23 à /16 parcouru par pages de /24")
    }

    /// Une case par /24 du bloc : remplie selon l'occupation, liseré rouge s'il y a un conflit.
    private func pagesMap(current: AddressPlanPage) -> some View {
        let columns = min(16, plan.pageCount)
        // Le panneau fait 680 points en grande fenêtre (640 de contenu) : 16 pages tiennent sur une ligne.
        // Plusieurs rangées (/19 à /16) : troisième octet en tête de rangée, comme la carte des adresses.
        let labeled = plan.pageCount > 16
        let tile = min(84, max(22, (640 - (labeled ? 34 : 0) - CGFloat(columns - 1) * 4) / CGFloat(columns)))
        let height: CGFloat = labeled ? 15 : 34
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<(plan.pageCount + columns - 1) / columns, id: \.self) { row in
                HStack(spacing: 4) {
                    if labeled {
                        Text(plan.pages[row * columns].shortLabel).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 30, alignment: .leading)
                    }
                    ForEach(row * columns..<min(plan.pageCount, (row + 1) * columns), id: \.self) { index in
                        pageTile(plan.pages[index], isCurrent: plan.pages[index].base == current.base, width: tile, height: height)
                    }
                }
            }
            HStack(spacing: 10) {
                Text("\(plan.used) adresses prises sur \(RegFormat.count(plan.hosts)) · \(Int((plan.usage * 100).rounded()))\u{00A0}%")
                Text("\(plan.pages.filter { !$0.isEmpty }.count) page\(plan.pages.filter { !$0.isEmpty }.count > 1 ? "s" : "") en usage")
                Spacer(minLength: 0)
                Text("Cliquez sur une page pour l’afficher").foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
    }

    private func pageTile(_ item: AddressPlanPage, isCurrent: Bool, width: CGFloat, height: CGFloat) -> some View {
        let fill: Color
        if item.used > 0 {
            fill = Theme.success.opacity(0.22 + 0.68 * min(1, item.usage * 1.4))
        } else if item.count(.libreDHCP) > 0 {
            fill = Self.colors(.libreDHCP).fill
        } else if item.count(.exclue) > 0 {
            fill = Self.colors(.exclue).fill
        } else {
            fill = Theme.panel
        }
        let conflict = item.count(.conflit) > 0
        return ZStack {
            RoundedRectangle(cornerRadius: 3).fill(fill)
            RoundedRectangle(cornerRadius: 3).strokeBorder(conflict ? Theme.critical : Theme.borderStrong, lineWidth: conflict ? 1.5 : 1)
            if height > 20 {
                VStack(spacing: 0) {
                    Text(item.shortLabel).font(Theme.mono(10, weight: .semibold))
                    if item.used > 0 { Text("\(item.used)").font(Theme.mono(9)) }
                }
                .foregroundStyle(item.usage > 0.5 ? Theme.onAccent : Theme.text)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isCurrent ? Theme.text : Color.clear, lineWidth: 2).padding(-2))
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .help("\(item.label)\u{00A0}: \(item.used) prise\(item.used > 1 ? "s" : "") sur \(item.hosts)"
              + (item.count(.enLigneWifi) > 0 ? ", dont \(item.count(.enLigneWifi)) en Wi-Fi" : "")
              + (item.count(.bail) > 0 ? " · \(item.count(.bail)) baux DHCP sans appareil vu" : "")
              + (item.count(.libreDHCP) > 0 ? " · \(item.count(.libreDHCP)) libres dans l’étendue DHCP" : "")
              + (item.count(.exclue) > 0 ? " · \(item.count(.exclue)) exclues du scan" : "")
              + (conflict ? " · conflit IP" : ""))
        .onTapGesture {
            page = item.base
            selected = nil
        }
    }

    // MARK: Page de 256 adresses

    private var header: some View {
        HStack(spacing: Self.gap) {
            Text("").frame(width: 30)
            ForEach(0..<16, id: \.self) { column in
                Text("\(column)").font(Theme.mono(9)).foregroundStyle(Theme.textSecondary)
                    .frame(width: Self.cell)
            }
        }
    }

    /// Case encadrée quand rien n'est survolé ni choisi : le premier conflit, sinon la première
    /// adresse en ligne, sinon .1.
    static func defaultFocus(_ cells: [AddressPlanCell]) -> IPv4Address {
        (cells.first { $0.state == .conflit } ?? cells.first { $0.state.isOnline } ?? cells[1]).ip
    }

    static func colors(_ state: AddressPlanState) -> (fill: Color, border: Color) {
        switch state {
        case .enLigne: return (Color(hex: 0x16A34A), Color(hex: 0x15803D))
        // Note 84 : Wi-Fi en cyan (et symbole Wi-Fi dans la case), distinct du vert des filaires.
        case .enLigneWifi: return (Theme.wifiFill, Theme.wifi)
        case .horsLigne: return (Color(light: 0xCBD5E1, dark: 0x273444), Color(hex: 0x94A3B8))
        case .libre: return (Theme.panel, Theme.borderStrong)
        case .conflit: return (Color(hex: 0xB91C1C), Color(hex: 0x7F1D1D))
        // Sombre : gris plus clair que le fond du panneau, sinon les cases réseau et diffusion s'y perdent.
        case .reseau: return (Color(light: 0x374151, dark: 0x6B7280), Color(light: 0x1F2937, dark: 0x9CA3AF))
        case .bail: return (Color(light: 0x60A5FA, dark: 0x2563EB), Color(light: 0x2563EB, dark: 0x93C5FD))
        case .reservee: return (Color(light: 0xA78BFA, dark: 0x6D28D9), Color(light: 0x7C3AED, dark: 0xC4B5FD))
        case .exclue: return (Color(light: 0xFDE68A, dark: 0x5C3D0A), Color(light: 0xD97706, dark: 0xF59E0B))
        case .libreDHCP: return (Color(light: 0xE0EDFF, dark: 0x1B2E4A), Color(light: 0x93C5FD, dark: 0x3B6FB6))
        }
    }

    private func cellView(_ cell: AddressPlanCell, isFocus: Bool) -> some View {
        let colors = Self.colors(cell.state)
        return RoundedRectangle(cornerRadius: 3)
            .fill(colors.fill)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colors.border))
            .overlay {
                if cell.state == .enLigneWifi {
                    Image(systemName: "wifi").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .offset(y: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let marker = cell.marker { AnaCellMarker(kind: marker) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isFocus ? Theme.text : Color.clear, lineWidth: 2).padding(-2))
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Rectangle())
            .help(Self.tooltip(cell))
            .onHover { inside in
                if inside { hovered = cell.ip } else if hovered == cell.ip { hovered = nil }
            }
            .onTapGesture { selected = cell.ip }
    }

    /// Infobulle d'une case : état, accès (filaire ou Wi-Fi, borne, SSID) et attribution (note 84).
    static func tooltip(_ cell: AddressPlanCell) -> String {
        var parts = [cell.state.label]
        if let medium = cell.medium, cell.state.hasRecord, cell.state != .enLigneWifi, cell.state != .enLigne {
            parts.append(medium.medium.label)
        }
        if let medium = cell.medium, medium.isWireless {
            if let ap = medium.apAfter { parts.append("borne \(ap)") }
            if let ssid = medium.ssid { parts.append("SSID \(ssid)") }
        }
        if cell.state.hasRecord, let assignment = cell.assignment { parts.append(assignment.label) }
        return "\(cell.ip.description)\u{00A0}: " + parts.joined(separator: " · ")
    }

    private func legend(_ page: AddressPlanPage, cells: [AddressPlanCell]) -> some View {
        InvFlowLayout(spacing: 10) {
            ForEach(AddressPlanLegend.items(page: page, cells: cells, dhcpRead: dhcpReadAt != nil)) { item in
                HStack(spacing: 5) {
                    switch item.kind {
                    case .state(let state):
                        let colors = Self.colors(state)
                        RoundedRectangle(cornerRadius: 3).fill(colors.fill)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colors.border))
                            .overlay {
                                if state == .enLigneWifi {
                                    Image(systemName: "wifi").font(.system(size: 6, weight: .bold)).foregroundStyle(Theme.onAccent)
                                }
                            }
                            .frame(width: 12, height: 12)
                    case .marker(let assignment):
                        RoundedRectangle(cornerRadius: 3).fill(Theme.panelMuted)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderStrong))
                            .overlay(alignment: .topTrailing) { AnaCellMarker(kind: assignment, size: 7) }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .frame(width: 12, height: 12)
                    }
                    Text(item.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Text("\(item.count)").font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                }
                .help(item.help)
            }
        }
        .frame(width: Self.gridWidth, alignment: .leading)
    }

    // MARK: Détail

    @ViewBuilder
    private func detail(_ cell: AddressPlanCell) -> some View {
        let here = records.filter { $0.ip == cell.ip }.sorted { $0.lastSeen > $1.lastSeen }
        let record = cell.recordKey.flatMap { key in records.first { $0.key == key } }
        VStack(alignment: .leading, spacing: 8) {
            Text("ADRESSE CHOISIE").font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary)
            Text(cell.ip.description).font(Theme.mono(17, weight: .semibold)).textSelection(.enabled)
            pill(cell.state)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                switch cell.state {
                case .reseau:
                    row("Rôle", cell.ip.octets.3 == 0 || cell.ip == plan.block.network ? "Adresse réseau" : "Adresse de diffusion")
                case .conflit:
                    row("Nom", "\(max(here.filter(\.isOnline).count, 2)) appareils en conflit")
                    row("MAC", here.compactMap { $0.mac?.formatted(.upperColon) }.joined(separator: "\n"), mono: true)
                    row("Fabricant", here.map(\.vendorLabel).joined(separator: " / "))
                    row("Port", here.compactMap(\.switchLocation).joined(separator: "\n"), mono: true)
                case .enLigne, .enLigneWifi, .horsLigne:
                    if let record {
                        row("Nom", record.displayName)
                        row("Fabricant", record.vendorLabel)
                        row("MAC", record.mac?.formatted(.upperColon) ?? "—", mono: true)
                        accessRows(cell, record: record)
                        row("VLAN", record.vlan.map(String.init) ?? "—")
                        row("Vu", InvFormat.seen(record.lastSeen, online: record.isOnline, now: now))
                    }
                default:
                    EmptyView()
                }
                if let lease = cell.lease {
                    row("Bail", lease.hostname ?? "Sans nom")
                    if let mac = lease.mac { row("MAC du bail", mac.formatted(.upperColon), mono: true) }
                    if let expires = lease.expires { row("Expire", InvFormat.timeOrStamp(expires)) }
                }
                if let reservation = cell.reservation {
                    row("Réservation", reservation.description?.isEmpty == false ? reservation.description! : "Sans description")
                    if cell.lease == nil, let mac = reservation.mac { row("MAC réservée", mac.formatted(.upperColon), mono: true) }
                }
                if cell.isGateway { row("Rôle", "Passerelle de l’étendue DHCP") }
                if let scope = cell.scopeName { row("DHCP", scope + (cell.inPool ? "" : " (hors plage distribuée)")) }
                if let exclusion = cell.exclusion { row("Exclue", exclusion.label) }
            }
            Text(note(cell, record: record))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 2) {
                if let record, cell.state != .libre, cell.state != .libreDHCP {
                    Button("Ouvrir la fiche") {
                        model.selectedSite = siteKey
                        model.selectedKey = record.key
                        state.open(.inventaire)
                    }
                    .buttonStyle(.ghost)
                }
                if cell.state != .reseau, cell.exclusion == nil {
                    Button("Ping continu") { state.sendToPing(cell.ip.description) }.buttonStyle(.ghost)
                }
                if cell.state == .libre {
                    Button(copied == cell.ip ? "Copiée" : "Copier") { copy(cell.ip) }.buttonStyle(.ghost)
                }
            }
            .padding(.leading, -8)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func note(_ cell: AddressPlanCell, record: InvRecord?) -> String {
        switch cell.state {
        case .reseau: return "Non attribuable."
        case .libre: return "Ni fiche récente, ni bail, ni réservation, hors étendue DHCP\u{00A0}: candidate pour une IP fixe, à confirmer par un ping."
        case .libreDHCP: return "Libre, mais dans la plage distribuée par le DHCP\u{00A0}: à éviter pour une IP fixe (ou à exclure de l’étendue)."
        case .bail: return "Bail DHCP actif, mais l’appareil n’a pas été vu au dernier scan (éteint, pare-feu, ou plage non scannée)."
        case .reservee: return cell.isGateway ? "Adresse de la passerelle\u{00A0}: jamais distribuée." : "Gardée par une réservation DHCP, même sans bail en cours."
        case .exclue: return "Dans les plages exclues du site\u{00A0}: jamais sondée, état inconnu. Ne pas l’attribuer sans vérifier."
        case .conflit: return "Plusieurs MAC répondent à cette adresse\u{00A0}: IP fixe en double probable."
        case .horsLigne: return "Ne répond plus, mais l’adresse a servi récemment\u{00A0}: à éviter pour une IP fixe."
        case .enLigne, .enLigneWifi: return record?.openPorts.isEmpty == false
            ? "Ports ouverts\u{00A0}: " + (record?.openPorts.map(String.init).joined(separator: ", ") ?? "") + "."
            : "Répond au scan."
        }
    }

    /// Note 84 : accès (filaire et son port, ou Wi-Fi, sa borne et son SSID) et attribution de
    /// l'adresse (bail DHCP, réservation, fixe).
    @ViewBuilder
    private func accessRows(_ cell: AddressPlanCell, record: InvRecord) -> some View {
        let medium = cell.medium ?? .wired
        if medium.isWireless {
            row("Accès", "Wi-Fi" + (medium.reason.map { " (\($0.label))" } ?? ""))
            row("Borne", medium.apAfter ?? record.wireless?.apName ?? "inconnue")
            if let ssid = medium.ssid ?? record.wireless?.ssid {
                row("SSID", ssid + (medium.band.map { " · \($0.label)" } ?? ""))
            }
            if let location = record.switchLocation, !InvWirelessContext.isWifiPort(record.switchPort) {
                row("Port", location, mono: true)
            }
        } else {
            row("Accès", "Filaire")
            row("Port", record.switchLocation ?? "—", mono: true)
        }
        row("Adresse", cell.assignment.map(Self.assignmentText) ?? "Inconnue (aucune étendue DHCP lue)")
    }

    static func assignmentText(_ assignment: AddressAssignment) -> String {
        switch assignment {
        case .dhcp: return "Bail DHCP (attribuée par la FortiGate)"
        case .reservee: return "Réservée (réservation DHCP)"
        case .fixe: return "Fixe (ni bail ni réservation)"
        }
    }

    private func pill(_ state: AddressPlanState) -> some View {
        let (fg, bg): (Color, Color)
        switch state {
        case .enLigne: (fg, bg) = (Theme.success, Theme.successSoft)
        case .enLigneWifi: (fg, bg) = (Theme.wifi, Theme.wifiSoft)
        case .conflit: (fg, bg) = (Theme.critical, Theme.criticalSoft)
        case .exclue: (fg, bg) = (Theme.warning, Theme.warningSoft)
        case .bail, .reservee, .libreDHCP: (fg, bg) = (Theme.accentStrong, Theme.accentSoft)
        default: (fg, bg) = (Theme.neutralText, Theme.neutralSoft)
        }
        return InvPill(text: state.label, foreground: fg, background: bg, size: 12)
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String, mono: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary)
            if mono {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array((value.isEmpty ? "—" : value).split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        Text(String(line)).font(Theme.mono(10.5)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
            } else {
                Text(value.isEmpty ? "—" : value).font(Theme.small)
                    .fontWeight(key == "Nom" ? .medium : .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Prochaine IP libre

    private func nextFree(page: AddressPlanPage) -> some View {
        let pageSubnet = Subnet(address: page.base, prefix: 24)
        let candidates = plan.freeAddresses(in: pageSubnet, limit: 4)
        return VStack(alignment: .leading, spacing: 4) {
            Text("PROCHAINE IP LIBRE HORS ÉTENDUE DHCP · \(pageSubnet.description)")
                .font(Theme.captionSemibold).kerning(0.4).foregroundStyle(Theme.textSecondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let first = candidates.first {
                    Text(first.description).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.success)
                        .textSelection(.enabled)
                    if candidates.count > 1 {
                        Text("puis " + candidates.dropFirst().map(\.description).joined(separator: ", "))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Button(copied == first ? "Copiée" : "Copier") { copy(first) }.buttonStyle(.ghost)
                    Button("Vérifier par ping") { state.sendToPing(first.description) }.buttonStyle(.ghost)
                } else {
                    Text("Aucune adresse libre hors étendue DHCP dans cette page.").foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(Theme.small)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .help(dhcpReadAt.map { "Fiches de l’inventaire, étendues et baux DHCP lus sur la FortiGate \(InvFormat.timeOrStamp($0)), plages exclues du site. Jamais .0 ni .255." }
              ?? "Fiches de l’inventaire et plages exclues du site (aucune étendue DHCP lue sur une FortiGate). Jamais .0 ni .255.")
    }

    private func copy(_ ip: IPv4Address) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip.description, forType: .string)
        copied = ip
    }
}

/// Note 84 : repère dans le coin d'une case de la carte d'occupation : triangle pour un bail DHCP,
/// point pour une réservation (formes différentes, lisibles sans la couleur).
struct AnaCellMarker: View {
    let kind: AddressAssignment
    var size: CGFloat = 8

    var body: some View {
        switch kind {
        case .dhcp:
            AnaCornerTriangle().fill(Theme.dhcpMarker).frame(width: size, height: size)
        case .reservee:
            Circle().fill(Theme.reservedMarker)
                .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1))
                .frame(width: size - 1, height: size - 1)
                .padding(1)
        case .fixe:
            EmptyView()
        }
    }
}

/// Triangle du coin supérieur droit d'une case.
struct AnaCornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
