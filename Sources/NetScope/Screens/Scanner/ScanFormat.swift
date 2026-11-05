import AppKit
import NetScopeCore
import SwiftUI

/// Mise en forme française des valeurs du scanner.
enum ScanFormat {
    /// « 4,1 ms », « — » si absent.
    static func latency(_ value: Double?) -> String {
        guard let value else { return "—" }
        return decimal(value) + " ms"
    }

    /// Un chiffre après la virgule, à la française.
    static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// « 23 s », « 2 min 05 s ».
    static func seconds(_ interval: TimeInterval) -> String {
        let total = max(0, interval.clampedInt)
        if total < 60 { return "\(total) s" }
        return String(format: "%d min %02d s", total / 60, total % 60)
    }

    /// « À l’instant », « Il y a 2 min », « Il y a 3 h », « Il y a 2 j ».
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "À l’instant" }
        if elapsed < 3600 { return "Il y a \(Int(elapsed / 60)) min" }
        if elapsed < 86_400 { return "Il y a \(Int(elapsed / 3600)) h" }
        return "Il y a \((elapsed / 86_400).rounded(.towardZero).clampedInt) j"
    }

    private static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter
    }()

    /// « 12 août 2026, 09:14 »
    static func date(_ date: Date) -> String { longDate.string(from: date) }

    /// Ports web : ouverture dans le navigateur.
    static let webPorts: Set<UInt16> = [80, 443, 8000, 8080, 8443]

    /// URL à ouvrir pour un port (navigateur, SSH, VNC…), nil si aucune application ne s'en charge.
    static func url(for port: UInt16, ip: IPv4Address) -> URL? {
        switch port {
        case 443, 8443: return URL(string: "https://\(ip):\(port)")
        case 80: return URL(string: "http://\(ip)")
        case 8000, 8080: return URL(string: "http://\(ip):\(port)")
        case 22: return URL(string: "ssh://\(ip)")
        case 5900: return URL(string: "vnc://\(ip)")
        case 21: return URL(string: "ftp://\(ip)")
        default: return nil
        }
    }

    /// Libellé du bouton de port, comme le croquis (« Ouvrir 80 », « RAW 9100 »).
    static func portButtonLabel(_ port: UInt16) -> String {
        switch port {
        case 80, 443, 8000, 8080, 8443: return "Ouvrir \(port)"
        case 631: return "IPP 631"
        case 9100: return "RAW 9100"
        case 22: return "SSH 22"
        case 3389: return "RDP 3389"
        case 5900: return "VNC 5900"
        case 554: return "RTSP 554"
        case 21115...21119: return RustDeskPorts.buttonLabel(port)
        default: return "Port \(port)"
        }
    }

    /// Service affiché à côté du bouton (« HTTP », « RAW »…).
    static func service(_ port: UInt16) -> String {
        switch port {
        case 9100: return "RAW"
        case 541: return "FGFM"
        case 135: return "RPC"
        case 21115: return "NAT"
        case 21116: return "ID"
        case 21117: return "RELAIS"
        case 21118: return "DIRECT"
        case 21119: return "WS"
        default: return PortTag.serviceName(port)?.uppercased() ?? "TCP"
        }
    }

    /// Symbole d'un type d'appareil.
    static func symbol(_ type: DeviceType) -> String { type.symbolName }

    /// Moyens de découverte, déduits de ce qu'on sait de l'appareil.
    static func discovery(_ device: Device) -> String {
        var methods: [String] = []
        if device.mac != nil { methods.append("ARP") }
        if device.latencyMs != nil { methods.append("ping ICMP") }
        if device.hostname != nil {
            switch device.nameSource {
            case .mdns?: methods.append("mDNS")
            case .netbios?: methods.append("NetBIOS")
            case .dns?: methods.append("DNS inverse")
            case .fortigate?: methods.append("FortiGate")
            case .snmp?, nil: methods.append("nom d’hôte")
            }
        }
        if !device.openPorts.isEmpty { methods.append("ports TCP") }
        if device.snmpKind != nil { methods.append("SNMP") }
        if device.switchName != nil { methods.append("table MAC du switch") }
        return methods.isEmpty ? "—" : methods.joined(separator: ", ")
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Clés de tri du tableau

extension Device {
    var scanSortName: String { customName ?? "" }
    var scanSortHostname: String { hostnameLabel ?? "" }
    var scanSortVendor: String { vendorLabel }
    var scanSortMAC: UInt64 { mac?.value ?? .max }
    /// Sans réponse : en dernier.
    var scanSortLatency: Double { latencyMs ?? .infinity }
    var scanSortPorts: Int { openPorts.count }
    var scanSortSwitch: String { switchLocation ?? "" }
    /// PoE : alimentés d'abord (les plus gourmands en tête), puis ports PoE sans charge, ports sans
    /// PoE et inconnus. Lu dans le relevé des switchs (fil principal, où le tableau trie).
    var scanSortPoE: Double {
        guard Thread.isMainThread else { return 3_000 }
        let device = self
        return MainActor.assumeIsolated {
            guard let status = SwitchStore.shared.poeStatus(for: device) else { return 3_000 }
            if status.isPowered == true { return -(status.port?.consumptionW ?? status.port?.allocatedW ?? 0) }
            switch status.isPoEPort {
            case true?: return 1_000
            case false?: return 2_000
            case nil: return 3_000
            }
        }
    }
    var scanSortVLAN: Int { vlan ?? .max }
    var scanSortStatus: Int { isOnline ? 0 : 1 }
    var scanSortType: String { deviceType.label }
    var scanSortNameSource: String { nameSourceLabel ?? "" }
    var scanSortRange: String { rangeLabel ?? "" }
    var scanSortDomain: String { nameDomain ?? "" }
    var scanSortSNMP: String { snmpKind?.label ?? "" }
    var scanSortVendorOUI: String { mac.map { String($0.formatted(.upperColon).prefix(8)) } ?? "" }

    /// Au moins un port web ouvert.
    var scanHasWebPort: Bool { openPorts.contains { ScanFormat.webPorts.contains($0) } }
}

// MARK: - Mise en page

/// Disposition en lignes qui passent à la ligne (boutons de ports).
struct ScanFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Bouton compact à bordure (cartes du scanner) : hauteur et police au choix.
struct ScanOutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var font: Font = Theme.small
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Theme.neutralSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Intertitre de carte (11 pt, majuscules, gris).
struct ScanCardTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.5)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Message bref (vert, orange ou rouge) sous une action.
struct ScanToastView: View {
    let toast: ScanToast

    var body: some View {
        Text(toast.text)
            .font(Theme.small)
            .foregroundStyle(toast.tone.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(toast.tone.background))
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}
