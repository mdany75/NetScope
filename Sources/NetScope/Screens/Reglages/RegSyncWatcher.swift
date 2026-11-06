import CoreServices
import Foundation

/// Note 86 : surveillance d'un dossier et de ses sous-dossiers par FSEvents (dossier de données
/// de NetScope, dossier de synchronisation). FSEvents voit aussi les fichiers qu'iCloud Drive
/// dépose quand un autre Mac les a changés (NSMetadataQuery demanderait un conteneur iCloud
/// signé). Sur un partage réseau, il peut ne rien signaler : la minuterie de secours suffit.
/// Les événements arrivent regroupés (une seconde) sur le fil principal.
final class RegSyncWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, latency: TimeInterval = 1, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RegSyncWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let list = (0..<count).compactMap { array[$0] as? String }
            watcher.handler(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
