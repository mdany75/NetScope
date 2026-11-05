import Darwin
import Foundation

/// Vitesse et duplex négociés d'une interface, lus par SIOCGIFMEDIA (ioctl local, aucun trafic).
/// Note 58 : étape « Lien » du bilan de raccordement.
public struct LinkMedia: Equatable, Sendable {
    public var isActive: Bool?
    public var speedMbps: UInt64?
    public var duplex: LinkDuplex?
    /// « 1000baseT », « 100baseTX » (nil : média inconnu ou autonégociation en cours).
    public var label: String?

    public init(isActive: Bool?, speedMbps: UInt64?, duplex: LinkDuplex?, label: String?) {
        self.isActive = isActive
        self.speedMbps = speedMbps
        self.duplex = duplex
        self.label = label
    }

    // Constantes de <net/if_media.h> (recopiées : toutes ne sont pas importées en Swift).
    static let typeMask: Int32 = 0x0000_00E0
    static let subtypeMask: Int32 = 0x0000_001F
    static let ether: Int32 = 0x0000_0020
    static let fullDuplex: Int32 = 0x0010_0000
    static let halfDuplex: Int32 = 0x0020_0000
    static let statusValid: Int32 = 0x1
    static let statusActive: Int32 = 0x2

    /// Sous-types Ethernet : libellé et vitesse.
    static let etherSubtypes: [Int32: (label: String, mbps: UInt64)] = [
        3: ("10baseT", 10), 4: ("10base2", 10), 5: ("10base5", 10), 6: ("100baseTX", 100), 7: ("100baseFX", 100),
        8: ("100baseT4", 100), 9: ("100baseVG", 100), 10: ("100baseT2", 100), 11: ("1000baseSX", 1000),
        12: ("10baseSTP", 10), 13: ("10baseFL", 10), 14: ("1000baseLX", 1000), 15: ("1000baseCX", 1000),
        16: ("1000baseT", 1000), 18: ("10GbaseSR", 10_000), 19: ("10GbaseLR", 10_000), 20: ("10GbaseCX4", 10_000),
        21: ("10GbaseT", 10_000), 22: ("2500baseT", 2500), 23: ("5000baseT", 5000),
    ]

    /// Décode le mot `ifm_active` et le mot `ifm_status` d'un `ifmediareq`.
    public static func decode(active: Int32, status: Int32) -> LinkMedia {
        let isActive: Bool? = status & statusValid != 0 ? status & statusActive != 0 : nil
        var duplex: LinkDuplex?
        if active & fullDuplex != 0 { duplex = .full } else if active & halfDuplex != 0 { duplex = .half }
        guard active & typeMask == ether, let subtype = etherSubtypes[active & subtypeMask] else {
            return LinkMedia(isActive: isActive, speedMbps: nil, duplex: duplex, label: nil)
        }
        return LinkMedia(isActive: isActive, speedMbps: subtype.mbps, duplex: duplex, label: subtype.label)
    }

    /// Lecture locale ; nil si l'interface ne répond pas à SIOCGIFMEDIA.
    public static func read(_ name: String) -> LinkMedia? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { raw in
            for (i, byte) in name.utf8.prefix(15).enumerated() { raw[i] = byte }
        }
        // SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq).
        let code: UInt = 0xC000_0000 | ((UInt(MemoryLayout<ifmediareq>.size) & 0x1FFF) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56
        guard ioctl(fd, code, &request) == 0 else { return nil }
        return decode(active: request.ifm_active, status: request.ifm_status)
    }

    /// « 1 Gb/s », « 100 Mb/s », « 2,5 Gb/s ».
    public static func speedLabel(_ mbps: UInt64) -> String {
        let nb = "\u{00A0}"
        if mbps >= 1000 {
            let gb = Double(mbps) / 1000
            let text = gb == gb.rounded() ? String(Int(gb)) : ToolFormat.decimal(gb, digits: 1)
            return text + "\(nb)Gb/s"
        }
        return "\(mbps)\(nb)Mb/s"
    }
}
