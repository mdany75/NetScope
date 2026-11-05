import Foundation

/// Un volume monté sur ce Mac (onglet Ressources de la fiche « Ce Mac ») : capacité et espace
/// libre lus par Foundation, sans aucun trafic réseau (un partage déjà monté est lu tel quel).
public struct LocalVolume: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case interne, externe, reseau }

    public var id: String { path }
    public var name: String
    public var path: String
    public var kind: Kind
    public var totalBytes: UInt64
    public var availableBytes: UInt64

    public init(name: String, path: String, kind: Kind, totalBytes: UInt64, availableBytes: UInt64) {
        self.name = name
        self.path = path
        self.kind = kind
        self.totalBytes = totalBytes
        self.availableBytes = min(availableBytes, totalBytes)
    }

    public var usedBytes: UInt64 { totalBytes - availableBytes }
    /// Part utilisée (0 à 100) ; nil pour un volume de taille nulle.
    public var usedPercent: Double? {
        totalBytes == 0 ? nil : Double(usedBytes) / Double(totalBytes) * 100
    }

    public var kindLabel: String {
        switch kind {
        case .interne: return "Interne"
        case .externe: return "Externe"
        case .reseau: return "Réseau"
        }
    }
}

public enum LocalVolumes {
    /// Volumes visibles dans le Finder : le disque de démarrage d'abord, puis les autres par nom.
    public static func list() -> [LocalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [(LocalVolume, Bool)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            let available = important ?? UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let kind: LocalVolume.Kind = values.volumeIsLocal == false ? .reseau : values.volumeIsInternal == true ? .interne : .externe
            let name = values.volumeName ?? url.lastPathComponent
            volumes.append((LocalVolume(name: name, path: url.path, kind: kind, totalBytes: UInt64(total), availableBytes: available),
                            values.volumeIsRootFileSystem == true))
        }
        return sorted(volumes)
    }

    /// Ordre d'affichage : démarrage, internes, externes, réseau ; puis par nom.
    static func sorted(_ volumes: [(LocalVolume, Bool)]) -> [LocalVolume] {
        volumes.sorted { a, b in
            if a.1 != b.1 { return a.1 }
            func rank(_ v: LocalVolume) -> Int { v.kind == .interne ? 0 : v.kind == .externe ? 1 : 2 }
            if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }.map(\.0)
    }

    /// Le disque de démarrage (premier de la liste quand il est présent).
    public static func startup(in volumes: [LocalVolume]) -> LocalVolume? {
        volumes.first { $0.path == "/" } ?? volumes.first { $0.kind == .interne } ?? volumes.first
    }
}
