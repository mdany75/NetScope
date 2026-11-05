import Foundation
import NetScopeCore

/// Note 71 : balises de démonstration de l'analyseur Wi-Fi. Les octets sont fabriqués au format réel
/// (WifiBeaconBuilder) puis décodés par le même parseur que les vraies balises ; aucun appel à CoreWLAN.
/// Scénario : la borne FAP-Salle204 n'a pas 802.11r (itinérance incomplète) et sa radio 2,4 GHz est
/// saturée ; UBNT-Logistik reste en WPA2 seul en 2,4 et 5 GHz alors que son 6 GHz est en WPA3.
enum WifiBeaconDemo {
    private typealias B = WifiBeaconBuilder

    static func decorate(_ networks: [WifiNetwork]) -> [WifiNetwork] {
        networks.map { network in
            var copy = network
            if let bytes = bytes(for: network) { copy.beacon = WifiBeaconParser.parse(bytes) }
            return copy
        }
    }

    private struct Spec {
        var generation: WifiGeneration
        var streams = 2
        var security: [UInt8] = []
        var roaming: (k: Bool, v: Bool, r: Bool) = (false, false, false)
        var load: (clients: Int, percent: Int)?
        var vendor: [UInt8] = []
        var dtim = 1
    }

    private static func spec(for bssid: String) -> Spec? {
        let fortinetRoaming = (k: true, v: true, r: true)
        let wpa3Enterprise = B.rsn(akms: [5, 3], pmf: .required)
        switch bssid {
        case "70:4C:A5:1E:22:A0":
            return Spec(generation: .wifi6, streams: 4, security: wpa3Enterprise, roaming: fortinetRoaming, load: (22, 38),
                        vendor: B.fortinet(name: "FAP-Accueil-01", model: "FAP431F", serial: "FP431FTF21000187"))
        case "70:4C:A5:1E:22:A8":
            return Spec(generation: .wifi6, security: wpa3Enterprise, roaming: fortinetRoaming, load: (14, 46),
                        vendor: B.fortinet(name: "FAP-Accueil-01", model: "FAP431F", serial: "FP431FTF21000187"))
        case "70:4C:A5:3B:91:18":
            // Profil SSID sans « Fast BSS Transition » sur cette borne : 11r absent.
            return Spec(generation: .wifi6, security: B.rsn(akms: [5], pmf: .required), roaming: (true, true, false), load: (19, 52),
                        vendor: B.fortinet(name: "FAP-Salle204", model: "FAP231F", serial: "FP231FTF20004410"))
        case "70:4C:A5:3B:91:10":
            return Spec(generation: .wifi6, security: B.rsn(akms: [5], pmf: .required), roaming: (true, true, false), load: (32, 81),
                        vendor: B.fortinet(name: "FAP-Salle204", model: "FAP231F", serial: "FP231FTF20004410"))
        case "70:4C:A5:3B:91:11":
            return Spec(generation: .wifi6, load: (14, 81),
                        vendor: B.fortinet(name: "FAP-Salle204", model: "FAP231F", serial: "FP231FTF20004410"), dtim: 3)
        case "02:1F:6B:A0:44:93":
            return Spec(generation: .wifi4, streams: 1, security: B.rsn(akms: [2]))
        case "9C:53:22:7B:0E:41":
            return Spec(generation: .wifi4, security: B.rsn(akms: [2]), dtim: 3)
        case "9C:53:22:5D:18:C2":
            return Spec(generation: .wifi4, security: B.rsn(akms: [2]), load: (3, 12),
                        vendor: B.wps(device: "Wireless Router", manufacturer: "TP-Link", model: "Archer C6"))
        case "94:B4:0F:62:7A:01":
            return Spec(generation: .wifi4, security: B.rsn(akms: [1]), roaming: (true, true, false), load: (9, 34),
                        vendor: B.aruba(name: "AP-ENTREPOT-N1"))
        case "94:B4:0F:62:7A:11":
            return Spec(generation: .wifi5, security: B.rsn(akms: [1]), roaming: (true, true, false), load: (6, 21),
                        vendor: B.aruba(name: "AP-ENTREPOT-N1"))
        case "78:8A:20:4E:C3:05":
            return Spec(generation: .wifi4, security: B.rsn(akms: [2], pmf: .optional), roaming: (true, false, false), load: (17, 58))
        case "78:8A:20:4E:C3:06":
            return Spec(generation: .wifi5, security: B.rsn(akms: [2], pmf: .optional), roaming: (true, false, false), load: (11, 33))
        case "78:8A:20:4E:C3:07":
            return Spec(generation: .wifi6E, security: B.rsn(akms: [8], pmf: .required), roaming: (true, false, false), load: (2, 6))
        case "96:DD:F8:18:15:7D":
            return Spec(generation: .wifi4, streams: 1, security: B.rsn(akms: [2]),
                        vendor: B.wps(device: "DCP-L2640DW", manufacturer: "Brother", model: "DCP-L2640DW"))
        case "3C:52:A1:09:7E:2C":
            return Spec(generation: .wifi7, security: B.rsn(akms: [8, 24], pairwise: [8, 9], pmf: .required), load: (4, 9))
        default:
            return nil
        }
    }

    static func bytes(for network: WifiNetwork) -> [UInt8]? {
        guard let bssid = network.bssid?.formatted(.upperColon), let spec = spec(for: bssid) else { return nil }
        var bytes = B.ssid(network.ssid)
        if network.band != .ghz6 { bytes += B.dsParameter(channel: network.channel) }
        bytes += B.tim(dtimPeriod: spec.dtim)
        switch network.band {
        case .ghz24: bytes += B.country("CA", firstChannel: 1, count: 11, maxPower: 30)
        case .ghz5: bytes += B.country("CA", firstChannel: 36, count: 25, maxPower: 23)
        case .ghz6: bytes += B.country("CA", firstChannel: 1, count: 59, maxPower: 24)
        }
        if let load = spec.load { bytes += B.bssLoad(clients: load.clients, utilizationPercent: load.percent, capacity: (100 - load.percent) * 3125 / 10) }
        bytes += radio(network, spec)
        bytes += spec.security
        if spec.roaming.r { bytes += B.mobilityDomain(0x4CE3, overDS: false) }
        if spec.roaming.k { bytes += B.rmCapabilities(neighborReport: true) }
        bytes += B.extendedCapabilities(bssTransition: spec.roaming.v)
        bytes += B.wmm() + spec.vendor
        return bytes
    }

    /// Éléments radio selon la bande et la génération (HT, VHT, HE, EHT).
    private static func radio(_ network: WifiNetwork, _ spec: Spec) -> [UInt8] {
        let width = network.widthMHz, channel = network.channel
        var bytes: [UInt8] = []
        if network.band != .ghz6 {
            bytes += B.htCapabilities(streams: spec.streams) + B.htOperation(primary: channel, width40: width >= 40)
            if network.band == .ghz5, spec.generation >= .wifi5 {
                bytes += B.vhtCapabilities(streams: spec.streams) + B.vhtOperation(widthMHz: width, center: center5(channel, width))
            }
        }
        if spec.generation >= .wifi6 {
            bytes += B.heCapabilities(streams: spec.streams)
            bytes += network.band == .ghz6
                ? B.heOperation(sixGHz: (channel, min(160, width), center6(channel, min(160, width))))
                : B.heOperation()
        }
        if spec.generation == .wifi7 {
            bytes += B.ehtCapabilities() + B.ehtOperation(widthMHz: width, center: center6(channel, width))
        }
        return bytes
    }

    private static func center5(_ channel: Int, _ width: Int) -> Int {
        let starts: [Int]
        switch width {
        case 160: starts = [36, 100]
        case 80: starts = [36, 52, 100, 116, 132, 149]
        case 40: starts = [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157]
        default: return channel
        }
        let start = starts.last { $0 <= channel } ?? channel
        return start + (width / 20 - 1) * 2
    }

    private static func center6(_ channel: Int, _ width: Int) -> Int {
        let block = max(1, width / 20) * 4
        let start = ((channel - 1) / block) * block + 1
        return start + (block - 4) / 2
    }
}
