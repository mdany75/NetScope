import Foundation

// Calculs du test de vitesse des disques : débits, IOPS, percentiles, échelle des jauges, et
// mise en forme à la française. Rien ici ne touche au disque : tout se vérifie sur des valeurs fixes.

public enum DiskMath {
    /// 1 Mio : taille des blocs séquentiels.
    public static let sequentialBlock = 1 << 20
    /// 4 Kio : taille des accès aléatoires.
    public static let randomBlock = 4096

    /// Débit en Mo/s (1 Mo = 1 000 000 octets, comme les fabricants de disques) ; nil si la durée est nulle.
    public static func megabytesPerSecond(bytes: Int64, seconds: Double) -> Double? {
        guard seconds > 0, bytes >= 0 else { return nil }
        return Double(bytes) / 1_000_000 / seconds
    }

    /// Mo/s → Mbit/s (pour comparer au débit d'un lien réseau).
    public static func megabits(fromMegabytes value: Double) -> Double { value * 8 }

    /// Opérations par seconde ; nil si la durée est nulle.
    public static func iops(operations: Int, seconds: Double) -> Double? {
        guard seconds > 0, operations >= 0 else { return nil }
        return Double(operations) / seconds
    }

    /// Moyenne des valeurs finies (une mesure NaN ou infinie est ignorée) ; nil s'il n'y en a aucune.
    public static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    /// Percentile par la méthode du rang le plus proche (p95 : la valeur sous laquelle se trouvent
    /// 95 % des mesures). `fraction` entre 0 et 1.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 1
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    /// Débit instantané entre deux relevés (octets cumulés, secondes depuis le début).
    public static func instantRate(previousBytes: Int64, previousTime: Double, bytes: Int64, time: Double) -> Double? {
        megabytesPerSecond(bytes: bytes - previousBytes, seconds: time - previousTime)
    }

    /// Graduation de jauge (Mo/s) : le premier palier au-dessus du plus haut débit vu.
    public static func gaugeScale(for peak: Double) -> Double {
        let steps: [Double] = [100, 250, 500, 1000, 2000, 3000, 5000, 8000, 12000]
        return steps.first { peak <= $0 * 0.95 } ?? (ceil(peak / 4000) * 4000)
    }

    /// Espace libre nécessaire : la taille du fichier plus 10 % de marge.
    public static func requiredFreeSpace(forTestSize size: Int64) -> Int64 {
        size + size / 10
    }

    public static func hasRoom(freeBytes: Int64?, testSize: Int64) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= requiredFreeSpace(forTestSize: testSize)
    }

    /// Au-delà de 1 Gio dans un dossier nuage, on demande une confirmation (quota, forfait).
    public static let cloudConfirmationThreshold: Int64 = 1 << 30

    public static func needsCloudConfirmation(kind: DiskLocationKind, testSize: Int64) -> Bool {
        kind == .nuage && testSize > cloudConfirmationThreshold
    }

    /// Classe probable d'un disque local d'après sa lecture séquentielle (Mo/s).
    public static func driveClass(readMBps: Double) -> String {
        switch readMBps {
        case 2500...: return "SSD NVMe rapide"
        case 1200..<2500: return "SSD NVMe ou Thunderbolt"
        case 350..<1200: return "SSD SATA ou USB 3.1"
        case 150..<350: return "disque dur ou SSD en USB 3"
        case 40..<150: return "disque dur ou clé USB rapide"
        default: return "clé USB ou disque lent"
        }
    }
}

/// Mise en forme à la française (virgule décimale, espace insécable avant l'unité).
public enum DiskFormat {
    static let nbsp = "\u{00A0}"

    public static func number(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// « 2 850 » (espace fine insécable entre les milliers), « 98,4 » sous 100, « 7,2 » sous 10.
    public static func rate(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 100 { return grouped(value.clampedInt) }
        return number(value, digits: 1)
    }

    /// « 2 850 Mo/s ».
    public static func rateWithUnit(_ value: Double) -> String { rate(value) + nbsp + "Mo/s" }

    /// « 940 Mbit/s », « 1,2 Gbit/s ».
    public static func bits(_ megabits: Double) -> String {
        guard megabits.isFinite else { return "—" }
        if megabits >= 1000 { return number(megabits / 1000, digits: megabits >= 10_000 ? 0 : 1) + nbsp + "Gbit/s" }
        return grouped(megabits.clampedInt) + nbsp + "Mbit/s"
    }

    public static func iops(_ value: Double) -> String { value.isFinite ? grouped(value.clampedInt) : "—" }

    /// Latence : « 0,08 ms », « 1,4 ms », « 23 ms ».
    public static func latency(_ ms: Double) -> String {
        guard ms.isFinite else { return "—" }
        if ms < 1 { return number(ms, digits: 2) + nbsp + "ms" }
        if ms < 10 { return number(ms, digits: 1) + nbsp + "ms" }
        return grouped(ms.clampedInt) + nbsp + "ms"
    }

    /// Durée : « 42 s », « 3 min 05 s ».
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let total = max(0, seconds.clampedInt)
        if total < 60 { return "\(total)" + nbsp + "s" }
        return "\(total / 60)" + nbsp + "min " + String(format: "%02d", total % 60) + nbsp + "s"
    }

    /// Taille d'un volume (décimal, comme le Finder) : « 412 Go », « 1,9 To », « 850 Mo ».
    public static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1e12 { return number(value / 1e12, digits: 1) + nbsp + "To" }
        if value >= 1e9 { return grouped((value / 1e9).clampedInt) + nbsp + "Go" }
        return grouped((value / 1e6).clampedInt) + nbsp + "Mo"
    }

    /// Taille d'un fichier d'essai (binaire) : « 256 Mio », « 1 Gio », « 10 Gio ».
    public static func testSize(_ bytes: Int64) -> String {
        if bytes >= 1 << 30, bytes % (1 << 30) == 0 { return "\(bytes >> 30)" + nbsp + "Gio" }
        if bytes >= 1 << 30 { return number(Double(bytes) / Double(1 << 30), digits: 1) + nbsp + "Gio" }
        return "\(bytes >> 20)" + nbsp + "Mio"
    }

    /// Milliers séparés par une espace fine insécable (« 12 400 »).
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, char) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result.append("\u{202F}") }
            result.append(char)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }
}
