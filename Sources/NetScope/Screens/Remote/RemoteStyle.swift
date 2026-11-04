import NetScopeCore
import SwiftUI

// Couleurs et icônes des protocoles, d'après le croquis Remote.dc.html.

extension RemoteProtocol {
    var tint: Color {
        switch self {
        case .ssh: return Color(light: 0x1D4ED8, dark: 0x93ACF1)
        case .telnet: return Color(light: 0xC2410C, dark: 0xF6AC8E)
        case .rdp: return Color(light: 0x4338CA, dark: 0xA49EE5)
        case .vnc: return Color(light: 0x374151, dark: 0xB6BFCE)
        case .serie: return Color(light: 0x15803D, dark: 0x96EEB7)
        }
    }

    var soft: Color {
        switch self {
        case .ssh: return Color(light: 0xEFF6FF, dark: 0x1B3250)
        case .telnet: return Color(light: 0xFFEDD5, dark: 0x50391B)
        case .rdp: return Color(light: 0xEEF2FF, dark: 0x1B2750)
        case .vnc: return Color(light: 0xF3F4F6, dark: 0x2E333D)
        case .serie: return Color(light: 0xDCFCE7, dark: 0x1B502D)
        }
    }

    var symbol: String {
        switch self {
        case .ssh: return "terminal"
        case .telnet: return "terminal.fill"
        case .rdp: return "display"
        case .vnc: return "rectangle.on.rectangle"
        case .serie: return "cable.connector"
        }
    }
}

/// Carré coloré avec l'icône du protocole.
struct RemoteProtoIcon: View {
    let proto: RemoteProtocol
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: proto.symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(proto.tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size > 30 ? 8 : 6).fill(proto.soft))
    }
}

/// Petite étiquette du protocole (« SSH », « TELNET »).
struct RemoteProtoBadge: View {
    let proto: RemoteProtocol
    var text: String? = nil

    var body: some View {
        Text(text ?? proto.badge)
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.3)
            .foregroundStyle(proto.tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(proto.soft))
            .fixedSize()
    }
}

/// Pastille de joignabilité : pleine (joignable), cerclée (non joignable), pointillée (non vérifiée).
struct RemoteReachDot: View {
    let state: RemoteReachability
    var size: CGFloat = 9

    var body: some View {
        switch state {
        case .reachable:
            Circle().fill(Theme.success).frame(width: size, height: size)
        case .unreachable:
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 2).frame(width: size, height: size)
        case .unknown:
            Circle().strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5]))
                .frame(width: size, height: size)
        case .checking:
            SpeedPulseDot(color: Theme.accent, pulsing: true).frame(width: size, height: size)
        }
    }
}

extension RemoteReachability {
    var label: String {
        switch self {
        case .reachable: return "Joignable"
        case .unreachable: return "Non joignable"
        case .unknown: return "Non vérifiée"
        case .checking: return "Vérification…"
        }
    }

    var tone: Tone {
        switch self {
        case .reachable: return .success
        case .unreachable, .unknown: return .neutral
        case .checking: return .accent
        }
    }
}

/// Date relative courte (« Aujourd’hui 10:38 », « 30 oct. 14:22 »).
enum RemoteFormat {
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Jamais" }
        let time = DateFormatter()
        time.locale = Locale(identifier: "fr_CA")
        time.dateFormat = "HH:mm"
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Aujourd’hui \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "Hier \(time.string(from: date))" }
        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_CA")
        day.dateFormat = "d MMM HH:mm"
        return day.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
