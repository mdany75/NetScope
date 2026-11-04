import NetScopeCore
import SwiftUI

/// État d'affichage d'un port (couleurs du croquis Switch.dc.html).
enum SwitchPortState {
    case up1g, up100, poe, down, disabled, err, trunk

    init(_ iface: SNMPInterface, snapshot: SNMPSwitchSnapshot, uplinks: Set<Int>) {
        if !iface.adminUp { self = .disabled }
        else if iface.operStatus != .up { self = .down }
        else if uplinks.contains(iface.index) { self = .trunk }
        else if (iface.inErrors ?? 0) >= 100 { self = .err }
        else if snapshot.poePort(iface.index)?.isDelivering == true { self = .poe }
        else if (iface.speedMbps ?? 0) >= 1000 { self = .up1g }
        else { self = .up100 }
    }

    var fill: Color {
        switch self {
        case .up1g: return Color(hex: 0x15803D)
        case .up100: return Color(hex: 0xDCFCE7)
        case .poe: return Color(hex: 0x2563EB)
        case .down, .disabled: return Color(hex: 0x334155)
        case .err: return Color(hex: 0xB91C1C)
        case .trunk: return Color(hex: 0xF8FAFC)
        }
    }

    var stroke: Color {
        switch self {
        case .up1g: return Color(hex: 0x166534)
        case .up100: return Color(hex: 0x15803D)
        case .poe: return Color(hex: 0x1D4ED8)
        case .down, .disabled: return Color(hex: 0x475569)
        case .err: return Color(hex: 0x991B1B)
        case .trunk: return Color(hex: 0x94A3B8)
        }
    }

    var labelColor: Color {
        switch self {
        case .up1g, .poe, .err: return .white
        case .up100: return Color(hex: 0x14532D)
        case .down, .disabled: return Color(hex: 0xCBD5E1)
        case .trunk: return Color(hex: 0x0F172A)
        }
    }

    var label: String {
        switch self {
        case .up1g: return "Actif"
        case .up100: return "Actif · 100\u{00A0}Mb/s"
        case .poe: return "Actif · PoE"
        case .down: return "Inactif"
        case .disabled: return "Désactivé (admin)"
        case .err: return "Actif · erreurs"
        case .trunk: return "Trunk / uplink"
        }
    }

    /// Couleurs de la pastille d'état du détail.
    var badge: (background: Color, foreground: Color) {
        switch self {
        case .up1g: return (Theme.successSoft, Theme.success)
        case .up100: return (Theme.successSoft, Color(light: 0x14532D, dark: 0x9CE7BA))
        case .poe: return (Color(light: 0xDBEAFE, dark: 0x1B3250), Theme.accentStrong)
        case .down, .disabled: return (Theme.neutralSoft, Theme.textSecondary)
        case .err: return (Theme.criticalSoft, Theme.critical)
        case .trunk: return (Color(light: 0xE2E8F0, dark: 0x253347), Color(light: 0x0F172A, dark: 0xA5B6DF))
        }
    }
}

/// Façade dessinée du switch : ports cuivre en deux rangées (impairs en haut, pairs en bas),
/// ports de module à droite.
struct SwitchFaceplate: View {
    let snapshot: SNMPSwitchSnapshot
    let selected: Int?
    let found: Int?
    /// Largeur minimale du cadre (largeur de la carte) : le cadre va jusqu'au bord droit.
    var minWidth: CGFloat = 0
    let onSelect: (Int) -> Void

    var body: some View {
        let uplinks = snapshot.locatedUplinks
        let ports = snapshot.physicalPorts
        let copper = ports.filter { !$0.isModular }
        let modules = ports.filter(\.isModular)
        let top = copper.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let bottom = copper.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(SwitchText.brand(snapshot).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(.white)
                Text(SwitchText.shortModel(snapshot))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0xCBD5E1))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    led("SYST")
                    if !snapshot.poePorts.isEmpty || snapshot.poeBudgetW != nil { led("PoE") }
                }
                .padding(.top, 3)
            }
            .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                row(top, uplinks: uplinks, width: 20)
                row(bottom, uplinks: uplinks, width: 20)
            }

            if !modules.isEmpty {
                VStack(spacing: 5) {
                    row(modules.enumerated().filter { $0.offset % 2 == 0 }.map(\.element), uplinks: uplinks, width: 26, grouped: false)
                    row(modules.enumerated().filter { $0.offset % 2 == 1 }.map(\.element), uplinks: uplinks, width: 26, grouped: false)
                    Text(SwitchText.moduleLabel(modules))
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0xCBD5E1))
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0x475569)).frame(width: 1) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize()
        .frame(minWidth: minWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Color(hex: 0x1E293B)))
    }

    private func led(_ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Theme.successDot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(Color(hex: 0xCBD5E1)).fixedSize()
        }
    }

    private func row(_ ports: [SNMPInterface], uplinks: Set<Int>, width: CGFloat, grouped: Bool = true) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(ports.enumerated()), id: \.element.index) { position, iface in
                port(iface, uplinks: uplinks, width: width)
                    .padding(.leading, grouped && position > 0 && position % 6 == 0 ? 6 : 0)
            }
        }
    }

    private func port(_ iface: SNMPInterface, uplinks: Set<Int>, width: CGFloat) -> some View {
        let state = SwitchPortState(iface, snapshot: snapshot, uplinks: uplinks)
        let isFound = found == iface.index
        let isSelected = selected == iface.index
        return Button { onSelect(iface.index) } label: {
            Text(iface.isModular && iface.name.lowercased().hasPrefix("te") ? "T" + iface.shortLabel : iface.shortLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.labelColor)
                .frame(width: width, height: 22)
                .background(RoundedRectangle(cornerRadius: 3).fill(state.fill))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(state.stroke))
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isFound ? Color(hex: 0xF59E0B) : (isSelected ? Color.white : Color.clear), lineWidth: 2)
                )
                .padding(-2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(iface.name) · \(state.label)\(iface.alias.isEmpty ? "" : " · " + iface.alias)")
    }
}

/// Légende des couleurs de la façade.
struct SwitchLegend: View {
    var body: some View {
        // Passe à la ligne en petite fenêtre ; chaque libellé reste entier.
        FlowLayout(spacing: 14, lineSpacing: 6) {
            item(.up1g, "Actif 1\u{00A0}Gb/s")
            item(.up100, "Actif 100\u{00A0}Mb/s")
            item(.poe, "PoE actif")
            item(.trunk, "Trunk / uplink")
            item(.err, "Erreurs")
            item(.down, "Inactif / désactivé")
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.panel).frame(width: 14, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: 0xF59E0B), lineWidth: 2))
                Text("Appareil trouvé").fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
    }

    private func item(_ state: SwitchPortState, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(state.fill).frame(width: 14, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(state.stroke))
            Text(label).fixedSize()
        }
    }
}

// MARK: - Textes dérivés des relevés

enum SwitchText {
    static func brand(_ snapshot: SNMPSwitchSnapshot) -> String {
        snapshot.system.brand ?? "Switch"
    }

    /// Modèle court pour la façade : premier mot qui contient un chiffre et un tiret (« 9300-48P », « 2930F-24G »).
    static func shortModel(_ snapshot: SNMPSwitchSnapshot) -> String {
        let words = snapshot.system.descr.split(whereSeparator: { $0 == " " || $0 == "," })
        if let word = words.first(where: { $0.contains("-") && $0.contains(where: \.isNumber) && !$0.contains(".") }) {
            let parts = word.split(separator: "-")
            return parts.prefix(2).joined(separator: "-")
        }
        return snapshot.system.descr.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// Version du logiciel tirée de sysDescr (« Version 17.9.4a », « revision WC.16.11.0012 »).
    static func firmware(_ descr: String) -> String {
        let patterns = ["[Vv]ersion\\s+([^\\s,;]+)", "revision\\s+([^\\s,;]+)", "\\b(v\\d+\\.\\d+[^\\s,;]*)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: descr, range: NSRange(descr.startIndex..., in: descr)),
               let range = Range(match.range(at: 1), in: descr) {
                return String(descr[range])
            }
        }
        return "—"
    }

    /// Modèle complet : début de sysDescr, avant la virgule.
    static func model(_ snapshot: SNMPSwitchSnapshot) -> String {
        let summary = snapshot.system.summary
        let head = summary.split(separator: ",").first.map(String.init) ?? summary
        return head.isEmpty ? "Modèle inconnu" : head
    }

    static func moduleLabel(_ modules: [SNMPInterface]) -> String {
        let speed = modules.compactMap(\.speedMbps).max() ?? 0
        return speed >= 10_000 ? "SFP+ \(speed / 1000)G" : "SFP"
    }

    /// « 48 ports + 4 SFP+ ».
    static func portsSummary(_ snapshot: SNMPSwitchSnapshot) -> String {
        let ports = snapshot.physicalPorts
        let modules = ports.filter(\.isModular).count
        let copper = ports.count - modules
        return modules > 0 ? "\(copper) ports + \(modules) SFP+" : "\(copper) ports"
    }

    /// « à l’instant », « il y a 4 min », « il y a 3 h ».
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date).rounded(.towardZero).clampedInt
        if seconds < 60 { return "à l’instant" }
        if seconds < 3600 { return "il y a \(seconds / 60)\u{00A0}min" }
        if seconds < 86_400 { return "il y a \(seconds / 3600)\u{00A0}h" }
        return "il y a \(seconds / 86_400)\u{00A0}j"
    }

    /// Temps écoulé depuis le dernier changement d'état d'un port.
    static func lastChange(_ iface: SNMPInterface, uptime: UInt32?) -> String {
        guard let uptime, let change = iface.lastChangeTicks, change <= uptime else { return "—" }
        return "il y a " + SNMPFormat.duration(seconds: Int((uptime - change) / 100))
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
