import Foundation

/// Compteurs cumulés d'un disque physique (statistiques du pilote de stockage de macOS) :
/// octets lus et écrits, temps passé à lire et à écrire (nanosecondes).
public struct DiskIOCounters: Hashable, Sendable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var readNanoseconds: UInt64
    public var writeNanoseconds: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64, readNanoseconds: UInt64, writeNanoseconds: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.readNanoseconds = readNanoseconds
        self.writeNanoseconds = writeNanoseconds
    }
}

/// Un disque physique de ce Mac et ses compteurs.
public struct DiskIOSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { bsdName }
    /// « disk0 ».
    public var bsdName: String
    /// Modèle (« APPLE SSD AP1024Z ») ou nom BSD.
    public var name: String
    public var isInternal: Bool
    public var counters: DiskIOCounters

    public init(bsdName: String, name: String, isInternal: Bool, counters: DiskIOCounters) {
        self.bsdName = bsdName
        self.name = name
        self.isInternal = isInternal
        self.counters = counters
    }
}

/// Activité d'un disque entre deux relevés.
public struct DiskIORate: Hashable, Sendable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    /// Part du temps où le disque a travaillé (0 à 100), comme « % occupé » d'iostat.
    public var busyPercent: Double

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double, busyPercent: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.busyPercent = busyPercent
    }
}

public enum DiskIOMath {
    /// Débits et occupation entre deux relevés ; nil si l'intervalle est nul ou si un compteur
    /// a reculé (disque débranché puis rebranché, compteurs remis à zéro).
    public static func rate(from old: DiskIOCounters, to new: DiskIOCounters, seconds: Double) -> DiskIORate? {
        guard seconds > 0, seconds.isFinite,
              new.bytesRead >= old.bytesRead, new.bytesWritten >= old.bytesWritten,
              new.readNanoseconds >= old.readNanoseconds, new.writeNanoseconds >= old.writeNanoseconds else { return nil }
        let read = Double(new.bytesRead - old.bytesRead) / seconds
        let write = Double(new.bytesWritten - old.bytesWritten) / seconds
        let busyNs = Double(new.readNanoseconds - old.readNanoseconds) + Double(new.writeNanoseconds - old.writeNanoseconds)
        let busy = min(100, max(0, busyNs / (seconds * 1_000_000_000) * 100))
        return DiskIORate(readBytesPerSecond: read, writeBytesPerSecond: write, busyPercent: busy)
    }

    /// Débit d'un disque, libellé comme le Moniteur d'activité : « 85,2 Mo/s ».
    public static func throughput(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite else { return "—" }
        let units = ["o/s", "Ko/s", "Mo/s", "Go/s"]
        var amount = max(0, value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let text = amount >= 100 || unit == 0 ? String(amount.clampedInt) : String(format: "%.1f", amount).replacingOccurrences(of: ".", with: ",")
        return text + "\u{00A0}" + units[unit]
    }
}
