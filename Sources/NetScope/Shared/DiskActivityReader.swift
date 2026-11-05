import Foundation
import IOKit
import NetScopeCore

/// Lecture locale des compteurs de chaque disque physique (pilotes IOBlockStorageDriver), comme
/// le Moniteur d'activité et iostat. Les images disque et les volumes virtuels sont ignorés ; les
/// partages réseau n'ont pas de disque ici (leur activité est du trafic réseau).
enum DiskActivityReader {
    static func read() -> [DiskIOSnapshot] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var disks: [DiskIOSnapshot] = []
        while true {
            let driver = IOIteratorNext(iterator)
            guard driver != 0 else { break }
            defer { IOObjectRelease(driver) }
            guard let stats = properties(of: driver)?["Statistics"] as? [String: Any] else { continue }
            var device: io_registry_entry_t = 0
            var deviceProps: [String: Any] = [:]
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS {
                deviceProps = properties(of: device) ?? [:]
                IOObjectRelease(device)
            }
            let protocolInfo = deviceProps["Protocol Characteristics"] as? [String: Any] ?? [:]
            let location = (protocolInfo["Physical Interconnect Location"] as? String ?? "").lowercased()
            let interconnect = (protocolInfo["Physical Interconnect"] as? String ?? "").lowercased()
            if location.contains("virtual") || interconnect.contains("virtual") || interconnect.contains("disk image") { continue }
            var media: io_registry_entry_t = 0
            var bsd = ""
            if IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS {
                bsd = properties(of: media)?["BSD Name"] as? String ?? ""
                IOObjectRelease(media)
            }
            guard !bsd.isEmpty else { continue }
            let product = ((deviceProps["Device Characteristics"] as? [String: Any])?["Product Name"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let counters = DiskIOCounters(bytesRead: number(stats["Bytes (Read)"]), bytesWritten: number(stats["Bytes (Write)"]),
                                          readNanoseconds: number(stats["Total Time (Read)"]),
                                          writeNanoseconds: number(stats["Total Time (Write)"]))
            disks.append(DiskIOSnapshot(bsdName: bsd, name: product.isEmpty ? bsd : product,
                                        isInternal: !location.contains("external"), counters: counters))
        }
        return disks.sorted { a, b in
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.bsdName.localizedStandardCompare(b.bsdName) == .orderedAscending
        }
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    private static func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

/// Un disque et son activité entre les deux derniers relevés.
struct LocalDiskLoad: Identifiable, Hashable {
    var id: String { snapshot.bsdName }
    var snapshot: DiskIOSnapshot
    var rate: DiskIORate?
}
