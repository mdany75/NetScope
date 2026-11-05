import AppKit
import NetScopeCore
import SwiftUI

// Vues de détail de la capture de paquets : arborescence des couches, vue hexadécimale et ASCII
// (surlignage du champ choisi, clic sur un octet), flux suivi, couleurs par protocole.

/// Couleurs par protocole (texte, fond), dynamiques en clair et en sombre.
enum PacketPalette {
    static func colors(_ kind: PacketProtocol) -> (Color, Color) {
        switch kind {
        case .tcp: return (Color(light: 0x5B21B6, dark: 0xC4B5FD), Color(light: 0xEDE9FE, dark: 0x2E2546))
        case .tls: return (Color(light: 0x6D28D9, dark: 0xD8B4FE), Color(light: 0xF3E8FF, dark: 0x352348))
        case .http, .ssdp: return (Color(light: 0x166534, dark: 0x86EFAC), Color(light: 0xDCFCE7, dark: 0x173C26))
        case .udp: return (Color(light: 0x0E7490, dark: 0x67E8F9), Color(light: 0xCFFAFE, dark: 0x163A42))
        case .dns, .mdns, .nbns: return (Color(light: 0x1D4ED8, dark: 0x93C5FD), Color(light: 0xDBEAFE, dark: 0x1C2D4D))
        case .dhcp: return (Color(light: 0x0F766E, dark: 0x5EEAD4), Color(light: 0xCCFBF1, dark: 0x163D39))
        case .arp: return (Color(light: 0x92400E, dark: 0xFCD34D), Color(light: 0xFEF3C7, dark: 0x40321A))
        case .icmp, .icmpv6, .igmp: return (Color(light: 0xBE185D, dark: 0xF9A8D4), Color(light: 0xFCE7F3, dark: 0x45202F))
        case .lldp, .cdp, .stp, .llc: return (Color(light: 0x57534E, dark: 0xD6D3D1), Color(light: 0xF5F5F4, dark: 0x34312E))
        case .ipv4, .ipv6, .vlan: return (Color(light: 0x3730A3, dark: 0xA5B4FC), Color(light: 0xE0E7FF, dark: 0x262A4A))
        // Note 78 : téléphonie, supervision, authentification.
        case .sip, .rtp, .rtcp: return (Color(light: 0x9A3412, dark: 0xFDBA74), Color(light: 0xFFEDD5, dark: 0x41291A))
        case .snmp, .syslog, .ntp: return (Color(light: 0x075985, dark: 0x7DD3FC), Color(light: 0xE0F2FE, dark: 0x1A3140))
        case .radius: return (Color(light: 0x9F1239, dark: 0xFDA4AF), Color(light: 0xFFE4E6, dark: 0x3F1D26))
        default: return (Theme.neutralText, Theme.neutralSoft)
        }
    }

    /// Texte du côté client et du côté serveur d'un flux suivi (rouge et bleu, comme Wireshark).
    static let clientText = Color(light: 0x9F1239, dark: 0xFDA4AF)
    static let clientBackground = Color(light: 0xFFF1F2, dark: 0x3A1E25)
    static let serverText = Color(light: 0x1E40AF, dark: 0x93C5FD)
    static let serverBackground = Color(light: 0xEFF6FF, dark: 0x1C2A40)
    /// Octets du champ choisi.
    static let highlightText = Theme.accentStrong
    static let highlightBackground = Theme.accentSoft
    /// Octets de la couche du champ choisi (surlignage discret).
    static let layerBackground = Color(light: 0x000000, dark: 0xFFFFFF, opacity: 0.05)
}

/// Puce de protocole (colonne « Protocole »).
struct PacketProtocolChip: View {
    let kind: PacketProtocol

    var body: some View {
        let (foreground, background) = PacketPalette.colors(kind)
        Text(kind.label)
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(background))
            .fixedSize()
    }
}

/// Cadre commun des panneaux de détail (filet de 1 pt, coins arrondis).
struct PacketPanel<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Arborescence

/// Détail du paquet en arbre par couche ; un clic choisit le champ (et le surligne dans l'hexa).
struct PacketTreeView: View {
    let packet: CapturedPacket
    @ObservedObject var model: ToolPacketCaptureModel
    var height: CGFloat = 236

    private struct Line: Identifiable {
        let field: PacketField
        let depth: Int
        let kind: PacketProtocol?
        var id: Int { field.id }
    }

    private var lines: [Line] {
        var result: [Line] = []
        func visit(_ field: PacketField, depth: Int, kind: PacketProtocol?) {
            result.append(Line(field: field, depth: depth, kind: kind))
            guard model.expanded.contains(field.id) else { return }
            for child in field.children { visit(child, depth: depth + 1, kind: nil) }
        }
        for layer in packet.decoded.layers { visit(layer.node, depth: 0, kind: layer.kind) }
        return result
    }

    var body: some View {
        PacketPanel(height: height) {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line).id(line.id) }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selectedField) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = model.selectedField { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ line: Line) -> some View {
        let field = line.field
        let selected = model.selectedField == field.id
        return HStack(spacing: 5) {
            Group {
                if field.children.isEmpty {
                    Color.clear
                } else {
                    Button { model.toggle(field.id) } label: {
                        Image(systemName: model.expanded.contains(field.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.expanded.contains(field.id) ? "Replier" : "Déplier")
                }
            }
            .frame(width: 12)
            if let kind = line.kind {
                Circle().fill(PacketPalette.colors(kind).0).frame(width: 7, height: 7)
                Text(field.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            } else {
                (Text(field.name).foregroundColor(Theme.textSecondary)
                    + Text(field.value.isEmpty ? "" : "\u{00A0}: ").foregroundColor(Theme.textSecondary)
                    + Text(field.value).font(Theme.mono(11.5)).foregroundColor(Theme.text))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if field.length > 0, line.kind == nil {
                Text(field.length == 1 ? "1\u{00A0}o" : "\(field.length)\u{00A0}o")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.leading, 8 + CGFloat(line.depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 21)
        .background(selected ? PacketPalette.highlightBackground : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectField(field.id) }
        .help(field.text)
    }
}

// MARK: - Hexadécimal

/// Octets du paquet : décalage, hexadécimal (deux groupes de huit) et ASCII. Le champ choisi est
/// surligné, sa couche plus discrètement ; un clic sur un octet choisit le champ qui le contient.
struct PacketHexView: View {
    let bytes: [UInt8]
    let highlight: Range<Int>?
    let layer: Range<Int>?
    var bytesPerRow = 16
    var height: CGFloat = 236
    let onSelect: (Int) -> Void

    static let cellWidth: CGFloat = 19
    static let asciiWidth: CGFloat = 7.2
    static let offsetWidth: CGFloat = 40

    /// Largeur du panneau pour `bytesPerRow` octets par ligne.
    static func width(bytesPerRow: Int) -> CGFloat {
        offsetWidth + CGFloat(bytesPerRow) * cellWidth + (bytesPerRow > 8 ? 6 : 0) + 12 + CGFloat(bytesPerRow) * asciiWidth + 20
    }

    var body: some View {
        PacketPanel(height: height) {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<rowCount, id: \.self) { row in rowView(row).id(row) }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
                .onChange(of: highlight) { _, range in
                    guard let range else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(range.lowerBound / bytesPerRow, anchor: .center) }
                }
                .onAppear {
                    if let range = highlight { proxy.scrollTo(range.lowerBound / bytesPerRow, anchor: .center) }
                }
            }
        }
        .frame(width: Self.width(bytesPerRow: bytesPerRow))
    }

    private var rowCount: Int { (bytes.count + bytesPerRow - 1) / bytesPerRow }

    private func rowView(_ row: Int) -> some View {
        let start = row * bytesPerRow
        return HStack(spacing: 0) {
            Text(String(format: "%04x", start))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: Self.offsetWidth, alignment: .leading)
            ForEach(0..<bytesPerRow, id: \.self) { column in
                let index = start + column
                cell(index, text: index < bytes.count ? String(format: "%02x", bytes[index]) : "", width: Self.cellWidth)
                if column == 7, bytesPerRow > 8 { Color.clear.frame(width: 6) }
            }
            Color.clear.frame(width: 12)
            ForEach(0..<bytesPerRow, id: \.self) { column in
                let index = start + column
                cell(index, text: index < bytes.count ? String(PacketText.ascii(bytes[index])) : "", width: Self.asciiWidth)
            }
        }
        .font(Theme.mono(11))
        .frame(height: 18)
    }

    private func cell(_ index: Int, text: String, width: CGFloat) -> some View {
        let selected = highlight?.contains(index) ?? false
        let inLayer = layer?.contains(index) ?? false
        return Text(text)
            .foregroundStyle(selected ? PacketPalette.highlightText : Theme.text)
            .fontWeight(selected ? .semibold : .regular)
            .frame(width: width, height: 18)
            .background(selected ? PacketPalette.highlightBackground : inLayer ? PacketPalette.layerBackground : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { if index < bytes.count { onSelect(index) } }
    }
}

// MARK: - Flux suivi

/// Données d'un flux TCP ou UDP remises dans l'ordre : client en rouge, serveur en bleu.
struct PacketFlowView: View {
    let stream: FlowStream
    let isTLS: Bool
    @ObservedObject var model: ToolPacketCaptureModel

    /// Au plus ce nombre d'octets affichés par morceau (le reste est signalé).
    static let chunkLimit = 32_768

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    title
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    actions
                }
            }
            if isTLS {
                ToolNotice(tone: .accent, title: "Contenu chiffré (TLS)",
                           message: "NetScope ne déchiffre pas TLS\u{00A0}: seuls les messages en clair de la négociation (Client Hello, SNI, Server Hello) sont lisibles. Le reste du flux apparaît comme des octets illisibles.")
            }
            if stream.missingBytes > 0 {
                ToolNotice(tone: .warning, message: "\(PacketText.octets(stream.missingBytes)) manquent (segments absents de la capture)\u{00A0}: le flux a des trous.")
            }
            PacketPanel(height: estimatedHeight) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if stream.chunks.isEmpty {
                            Text("Aucune donnée dans ce flux (seulement des paquets de contrôle).")
                                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(Array(stream.chunks.enumerated()), id: \.offset) { _, chunk in chunkView(chunk) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Hauteur du panneau : celle du contenu (lignes estimées), au plus 380 pt (au-delà, il défile).
    private var estimatedHeight: CGFloat {
        var lines = 0
        for chunk in stream.chunks {
            let shown = chunk.data.prefix(Self.chunkLimit)
            let textLines = model.streamShowsHex ? (shown.count + 15) / 16 : shown.filter { $0 == 0x0A }.count + 1 + shown.count / 120
            lines += textLines + 2
            if lines > 40 { break }
        }
        return min(380, max(80, CGFloat(lines) * 15 + CGFloat(stream.chunks.count) * 16 + 24))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Flux \(stream.key.kind.label) · \(stream.packetNumbers.count) paquet\(stream.packetNumbers.count > 1 ? "s" : "")")
                .font(Theme.bodySemibold)
            // Petite fenêtre : les deux pastilles passent l'une sous l'autre plutôt que d'élargir la page.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { legends }
                VStack(alignment: .leading, spacing: 4) { legends }
            }
        }
    }

    @ViewBuilder private var legends: some View {
        legend(color: PacketPalette.clientText, background: PacketPalette.clientBackground,
               text: "Client \(stream.client.label) · \(PacketText.bytes(stream.clientBytes))")
        legend(color: PacketPalette.serverText, background: PacketPalette.serverBackground,
               text: "Serveur \(stream.server.label) · \(PacketText.bytes(stream.serverBytes))")
    }

    private func legend(color: Color, background: Color, text: String) -> some View {
        Text(text)
            .font(Theme.mono(11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(background))
            .lineLimit(1)
            .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.streamShowsHex) {
                Text("ASCII").tag(false)
                Text("Hexadécimal").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                ToolActions.copy(stream.chunks.map { model.streamShowsHex ? Self.hexDump($0.data) : FlowStream.printable($0.data) }.joined(separator: "\n"))
            } label: {
                Label("Copier", systemImage: "doc.on.doc")
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            Button("Tous les paquets") { model.clearFollow() }
                .buttonStyle(.secondary)
                .controlSize(.small)
        }
        .fixedSize()
    }

    private func chunkView(_ chunk: FlowChunk) -> some View {
        let shown = Array(chunk.data.prefix(Self.chunkLimit))
        let text = model.streamShowsHex ? Self.hexDump(shown) : FlowStream.printable(shown)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(chunk.fromClient ? "Client → serveur" : "Serveur → client") · paquet n°\u{00A0}\(chunk.firstPacket) · \(PacketText.octets(chunk.data.count))")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            Text(text + (chunk.data.count > shown.count ? "\n… \(PacketText.octets(chunk.data.count - shown.count)) de plus" : ""))
                .font(Theme.mono(11.5))
                .foregroundStyle(chunk.fromClient ? PacketPalette.clientText : PacketPalette.serverText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .fill(chunk.fromClient ? PacketPalette.clientBackground : PacketPalette.serverBackground))
        }
    }

    /// « 0000  16 03 01 02 00 01 00 01  fc 03 03 …  ................ ».
    static func hexDump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { start in
            let slice = bytes[start..<min(start + 16, bytes.count)]
            var hexPart = slice.enumerated().map { ($0.offset == 8 ? " " : "") + String(format: "%02x", $0.element) }.joined(separator: " ")
            hexPart = hexPart.padding(toLength: 48, withPad: " ", startingAt: 0)
            return String(format: "%04x  ", start) + hexPart + "  " + String(slice.map(PacketText.ascii))
        }.joined(separator: "\n")
    }
}
