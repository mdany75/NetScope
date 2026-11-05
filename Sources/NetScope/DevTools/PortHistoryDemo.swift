import Foundation
import NetScopeCore

/// Démonstration de la note 74 : 30 jours d'historique du trafic de chaque port actif des switchs
/// de démonstration (SW-CORE-01, SW-ETG2-01, FortiSwitch des FortiGate). Aucun accès réseau.
///
/// - Courbes de bureau : faible la nuit et la fin de semaine, montée de 7 h 30 à 9 h, creux du
///   midi, descente après 17 h ; chaque port a sa part du lien et son bruit (déterministe).
/// - Sauvegardes nocturnes de 1 h 30 à 3 h sur les uplinks et le serveur (SW-CORE-01 · Gi1/0/40).
/// - Erreurs qui augmentent sur SW-CORE-01 · Gi1/0/18 (duplex non concordant, depuis trois jours)
///   et sur le FortiSwitch FSW-QUAI ; SW-ETG2-01 · 1/20 garde un vieux total sans nouvelle erreur.
/// - Les 7 derniers jours à 5 min (relecture automatique), avant à l'heure.
@MainActor
enum PortHistoryDemo {
    /// Heure des captures (14 h 32, comme le croquis) ; sinon l'heure réelle.
    static var now: Date {
        guard CommandLine.arguments.contains("--snapshot") else { return Date() }
        return Calendar.current.date(bySettingHour: 14, minute: 32, second: 0, of: Date()) ?? Date()
    }

    /// Erreurs par heure (en journée) des ports « qui se dégradent ».
    private static let risingErrors: [String: Double] = ["SW-CORE-01": 38, "FSW-QUAI": 26]

    static func make(snapshots: [SNMPSwitchSnapshot], now: Date? = nil) -> PortTrafficHistory {
        let now = now ?? Self.now
        var switches: [String: PortSwitchHistory] = [:]
        let calendar = Calendar.current
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 300) * 300)
        let today = calendar.startOfDay(for: now)
        for snapshot in snapshots {
            var history = PortSwitchHistory(host: snapshot.id, name: snapshot.displayName)
            for iface in snapshot.physicalPorts where iface.isUp {
                let profile = profile(snapshot, iface)
                var points: [PortTrafficPoint] = []
                var t = end.addingTimeInterval(-30 * 86_400)
                var step = 0
                while t < end {
                    let length: TimeInterval = end.timeIntervalSince(t) > 7 * 86_400 ? 3600 : 300
                    let next = t.addingTimeInterval(length)
                    let middle = t.addingTimeInterval(length / 2)
                    let isToday = calendar.isDate(middle, inSameDayAs: today)
                    let shape = dayShape(middle, calendar: calendar, isToday: isToday)
                    let backup = profile.backup > 0 ? backupShape(middle, calendar: calendar) * profile.backup : 0
                    let n1 = noise(iface.index &* 31 &+ profile.seed, step), n2 = noise(iface.index &* 17 &+ profile.seed &+ 7, step)
                    let speed = Double(iface.speedMbps ?? 1000) * 1_000_000
                    let inRate = min(speed * 0.97, speed * max(0.0003, profile.inShare * shape * (1 + 0.16 * n1) + backup * 0.15))
                    let outRate = min(speed * 0.97, speed * max(0.0004, profile.outShare * shape * (1 + 0.16 * n2) + backup))
                    // Pointe dans la tranche : plus marquée sur une heure que sur 5 minutes.
                    let burst = length > 300 ? 1.45 : 1.12
                    let inPeak = min(speed * 0.96, inRate * (burst + 0.22 * abs(n2)))
                    let outPeak = min(speed * 0.96, outRate * (burst + 0.22 * abs(n1)))
                    var errors: UInt64 = 0
                    if profile.errorsPerHour > 0, middle > now.addingTimeInterval(-3 * 86_400) {
                        let expected = profile.errorsPerHour * (0.35 + shape) * length / 3600
                        errors = UInt64(max(0, (expected * (1 + 0.5 * n1)).rounded()))
                    }
                    points.append(PortTrafficPoint(start: t, end: next, inBytes: inRate * length / 8, outBytes: outRate * length / 8,
                                                   inPeak: max(inRate, inPeak), outPeak: max(outRate, outPeak), errors: errors))
                    t = next
                    step += 1
                }
                history.ports[iface.index] = PortTrafficSeries(ifIndex: iface.index, name: iface.name, alias: iface.alias,
                                                               speedMbps: iface.speedMbps, isUp: true, points: points)
            }
            if !history.ports.isEmpty { switches[snapshot.id] = history }
        }
        return PortTrafficHistory(switches: switches)
    }

    // MARK: Profils

    private struct Profile {
        /// Part du lien en pleine journée (entrée, sortie).
        var inShare: Double
        var outShare: Double
        /// Sauvegarde nocturne (part du lien en sortie, 0 : aucune).
        var backup: Double = 0
        var errorsPerHour: Double = 0
        var seed: Int
    }

    private static func profile(_ snapshot: SNMPSwitchSnapshot, _ iface: SNMPInterface) -> Profile {
        let name = snapshot.displayName
        let seed = name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        let i = iface.index
        var p = Profile(inShare: 0.004 + 0.012 * abs(noise(i, 1)), outShare: 0.008 + 0.02 * abs(noise(i, 2)), seed: seed)
        let alias = iface.alias.lowercased()
        if name == "SW-CORE-01" {
            switch i {
            case 1: p.inShare = 0.34; p.outShare = 0.40; p.backup = 0.18     // pare-feu : Internet
            case 47: p.inShare = 0.24; p.outShare = 0.52; p.backup = 0.12    // uplink vers l'étage 2
            case 40: p.inShare = 0.19; p.outShare = 0.28; p.backup = 0.46    // contrôleur de domaine, sauvegarde
            case 12: p.inShare = 0.07; p.outShare = 0.12                     // borne Wi-Fi
            case 33, 34: p.inShare = 0.009; p.outShare = 0.01                // caméras
            case 18: p.inShare = 0.62; p.outShare = 0.21                     // 100 Mb/s presque saturé
            default: break
            }
        } else if name == "SW-ETG2-01" {
            switch i {
            case 25: p.inShare = 0.013; p.outShare = 0.010; p.backup = 0.01
            case 4, 5, 6: p.inShare = 0.003; p.outShare = 0.012
            case 9: p.inShare = 0.045; p.outShare = 0.004
            default: break
            }
        } else if alias.contains("fortilink") || alias.contains("isl") || alias.contains("uplink") {
            // Liens 10 Gb/s entre FortiSwitch et vers la FortiGate : quelques centaines de Mb/s le jour.
            let fast = (iface.speedMbps ?? 1000) >= 10_000
            p.inShare = fast ? 0.032 : 0.16; p.outShare = fast ? 0.041 : 0.2; p.backup = fast ? 0.012 : 0.06
        }
        if let rate = risingErrors[name], (iface.inErrors ?? 0) >= 100 { p.errorsPerHour = rate }
        // Caméras : flux constant jour et nuit (pas de forme de bureau).
        if alias.contains("caméra") || alias.contains("camera") { p.backup = 0 }
        return p
    }

    /// Forme d'une journée de bureau (0,06 la nuit, 1 en plein après-midi) ; fin de semaine calme.
    private static func dayShape(_ date: Date, calendar: Calendar, isToday: Bool) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let h = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
        let lunch = 1 - 0.28 * exp(-pow((h - 12.4) / 0.55, 2))
        let afternoon = 1 + 0.08 * exp(-pow((h - 14.5) / 1.4, 2))
        let bump = sigmoid((h - 8.1) * 2.6) * sigmoid((17.6 - h) * 1.9) * lunch * afternoon
        let weekend = !isToday && (parts.weekday == 1 || parts.weekday == 7)
        return 0.06 + (weekend ? 0.1 : 0.94) * bump
    }

    /// Sauvegarde nocturne de 1 h 30 à 3 h.
    private static func backupShape(_ date: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let h = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        return h >= 1.5 && h < 3 ? 1 : 0
    }

    /// Bruit déterministe entre −1 et 1 (le même à chaque capture).
    private static func noise(_ a: Int, _ b: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 20_001) / 10_000 - 1
    }
}
