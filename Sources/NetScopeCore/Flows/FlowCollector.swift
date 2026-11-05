import Foundation

// Note 75 : collecteur de flux de ce Mac. Écoute UDP sur les ports choisis (NetFlow v5/v9 sur 2055,
// IPFIX sur 4739, sFlow v5 sur 6343 par défaut), démarrée seulement à la demande. Chaque port
// accepte les quatre formats (reconnus au premier mot du datagramme). Décodage et agrégation sur
// le fil d'écoute, sous verrou ; la lecture (synthèses, état) se fait depuis n'importe quel fil.

/// Ports d'écoute du collecteur (au-dessus de 1024 : aucun droit administrateur).
public struct FlowCollectorPorts: Codable, Hashable, Sendable {
    public var netflow: UInt16
    public var ipfix: UInt16
    public var sflow: UInt16
    public var netflowEnabled: Bool
    public var ipfixEnabled: Bool
    public var sflowEnabled: Bool

    public init(netflow: UInt16 = 2055, ipfix: UInt16 = 4739, sflow: UInt16 = 6343,
                netflowEnabled: Bool = true, ipfixEnabled: Bool = true, sflowEnabled: Bool = true) {
        self.netflow = netflow
        self.ipfix = ipfix
        self.sflow = sflow
        self.netflowEnabled = netflowEnabled
        self.ipfixEnabled = ipfixEnabled
        self.sflowEnabled = sflowEnabled
    }

    public static let standard = FlowCollectorPorts()

    /// Ports à ouvrir (sans doublon : deux formats sur le même port partagent l'écoute).
    public var active: [(label: String, port: UInt16)] {
        var list: [(String, UInt16)] = []
        if netflowEnabled { list.append(("NetFlow", netflow)) }
        if ipfixEnabled { list.append(("IPFIX", ipfix)) }
        if sflowEnabled { list.append(("sFlow", sflow)) }
        var seen = Set<UInt16>()
        var merged: [(label: String, port: UInt16)] = []
        for (label, port) in list {
            if seen.insert(port).inserted {
                merged.append((label, port))
            } else if let index = merged.firstIndex(where: { $0.port == port }) {
                merged[index].label += " et " + label
            }
        }
        return merged
    }
}

/// Ce que le collecteur sait d'un exportateur.
public struct FlowExporterStatus: Hashable, Sendable, Identifiable {
    public var address: IPv4Address
    public var kinds: Set<FlowProtocolKind>
    public var datagrams: Int
    public var records: Int
    public var rejected: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// Port de ce Mac où arrivent ses datagrammes.
    public var port: UInt16
    public var templates: Int
    /// Ensembles de données en attente de leur gabarit.
    public var waiting: Int
    /// Échantillonnage annoncé ou vu (1 : aucun).
    public var sampling: UInt32
    public var lastError: String?

    public var id: IPv4Address { address }

    public init(address: IPv4Address, kinds: Set<FlowProtocolKind> = [], datagrams: Int = 0, records: Int = 0, rejected: Int = 0,
                firstSeen: Date, lastSeen: Date, port: UInt16 = 0, templates: Int = 0, waiting: Int = 0, sampling: UInt32 = 1,
                lastError: String? = nil) {
        self.address = address
        self.kinds = kinds
        self.datagrams = datagrams
        self.records = records
        self.rejected = rejected
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.port = port
        self.templates = templates
        self.waiting = waiting
        self.sampling = sampling
        self.lastError = lastError
    }

    /// « NetFlow v9, sFlow v5 ».
    public var kindsLabel: String { kinds.sorted().map(\.label).joined(separator: ", ") }
}

/// État du collecteur.
public struct FlowCollectorStatus: Hashable, Sendable {
    public var received: Int = 0
    public var rejected: Int = 0
    public var records: Int = 0
    public var lastRejection: String?
    public var exporters: [FlowExporterStatus] = []

    public init(received: Int = 0, rejected: Int = 0, records: Int = 0, lastRejection: String? = nil, exporters: [FlowExporterStatus] = []) {
        self.received = received
        self.rejected = rejected
        self.records = records
        self.lastRejection = lastRejection
        self.exporters = exporters
    }
}

public final class FlowCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: FlowDecoder
    private var aggregator: FlowAggregator
    private var stats = FlowCollectorStatus()
    private var exporterStats: [IPv4Address: FlowExporterStatus] = [:]
    private var listeners: [LogUDPListener] = []
    private let address: IPv4Address?

    /// `address` : adresse d'écoute (nil : toutes les interfaces ; 127.0.0.1 dans les tests).
    public init(address: IPv4Address? = nil, decoderLimits: FlowDecoder.Limits = .init(), limits: FlowAggregator.Limits = .init()) {
        self.address = address
        decoder = FlowDecoder(limits: decoderLimits)
        aggregator = FlowAggregator(limits: limits)
    }

    deinit { stop() }

    // MARK: Écoute

    /// Ports réellement ouverts.
    public var boundPorts: [UInt16] {
        lock.lock(); defer { lock.unlock() }
        return listeners.map(\.boundPort)
    }

    public var isListening: Bool {
        lock.lock(); defer { lock.unlock() }
        return !listeners.isEmpty
    }

    /// Ouvre les ports demandés. Renvoie les erreurs des ports qui n'ont pas pu s'ouvrir (les
    /// autres écoutent) ; lève une erreur si aucun ne s'ouvre. Port 0 : port libre (tests).
    @discardableResult
    public func start(ports: [(label: String, port: UInt16)], stopped: @escaping @Sendable (String?) -> Void = { _ in }) throws -> [String] {
        stop()
        var opened: [LogUDPListener] = []
        var errors: [String] = []
        for (label, port) in ports {
            let listener = LogUDPListener(port: port, address: address, name: "Flux " + label, handler: { [weak self] datagram in
                self?.ingest(datagram.bytes, from: datagram.from, port: port, at: datagram.date)
            }, stopped: stopped)
            do {
                try listener.start()
                opened.append(listener)
            } catch let error as LogBindError {
                errors.append(Self.describe(error, label: label))
            } catch {
                errors.append("\(label)\u{00A0}: ouverture du port \(port) impossible.")
            }
        }
        guard !opened.isEmpty else {
            throw FlowDecodeError(errors.joined(separator: " "))
        }
        lock.lock()
        listeners = opened
        lock.unlock()
        return errors
    }

    static func describe(_ error: LogBindError, label: String) -> String {
        if error.isInUse {
            return "\(label)\u{00A0}: le port UDP \(error.port) est déjà utilisé (un autre collecteur, ou une autre copie de NetScope)\u{00A0}; choisissez un autre port."
        }
        if error.isPermission {
            return "\(label)\u{00A0}: macOS refuse le port UDP \(error.port) (sous 1024, il faut les droits administrateur)\u{00A0}; choisissez un port au-dessus de 1024."
        }
        return "\(label)\u{00A0}: ouverture du port UDP \(error.port) impossible (\(String(cString: strerror(error.code))))."
    }

    public func stop() {
        lock.lock()
        let current = listeners
        listeners = []
        lock.unlock()
        for listener in current { listener.stop() }
    }

    // MARK: Réception

    /// Décode et agrège un datagramme (fil d'écoute, tests et démonstration).
    public func ingest(_ bytes: [UInt8], from exporter: IPv4Address, port: UInt16, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        stats.received += 1
        var exporterStat = exporterStats[exporter] ?? FlowExporterStatus(address: exporter, firstSeen: date, lastSeen: date, port: port)
        exporterStat.datagrams += 1
        exporterStat.lastSeen = max(exporterStat.lastSeen, date)
        exporterStat.port = port
        do {
            let result = try decoder.decode(bytes, from: exporter)
            guard aggregator.add(result, from: exporter, at: date) else {
                reject("\(exporter)\u{00A0}: trop d’exportateurs (\(aggregator.limits.maxExporters) au plus), datagramme écarté")
                return
            }
            exporterStat.kinds.insert(result.kind)
            exporterStat.records += result.records.count
            stats.records += result.records.count
            if let rate = result.samplingRate ?? result.records.map(\.samplingRate).max(), rate > 1 { exporterStat.sampling = rate }
            exporterStat.templates = decoder.templateCount(exporter: exporter)
            exporterStat.waiting = decoder.waitingCount(exporter: exporter)
            exporterStat.lastError = nil
            exporterStats[exporter] = exporterStat
        } catch {
            let reason = (error as? FlowDecodeError)?.message ?? error.localizedDescription
            exporterStat.rejected += 1
            exporterStat.lastError = reason
            exporterStats[exporter] = exporterStat
            reject("\(exporter)\u{00A0}: \(reason)")
        }
    }

    private func reject(_ reason: String) {
        stats.rejected += 1
        stats.lastRejection = reason
    }

    // MARK: Lecture

    /// État du collecteur et des exportateurs vus (le plus récent d'abord).
    public func status() -> FlowCollectorStatus {
        lock.lock()
        defer { lock.unlock() }
        var copy = stats
        copy.exporters = exporterStats.values.sorted { $0.address < $1.address }
        return copy
    }

    /// Synthèses des exportateurs (tous, ou ceux demandés), sur les `window` dernières secondes.
    public func summaries(window: TimeInterval, now: Date = Date(), exporters: [IPv4Address]? = nil,
                          wanOverrides: [IPv4Address: UInt32] = [:]) -> [FlowSummary] {
        lock.lock()
        defer { lock.unlock() }
        aggregator.prune(now: now)
        let list = exporters ?? aggregator.exporterAddresses
        return list.compactMap { aggregator.summary(exporter: $0, window: window, now: now, wanOverride: wanOverrides[$0]) }
    }

    /// Oublie un exportateur (gabarits, flux, compteurs).
    public func forget(exporter: IPv4Address) {
        lock.lock()
        defer { lock.unlock() }
        decoder.forget(exporter: exporter)
        aggregator.forget(exporter: exporter)
        exporterStats[exporter] = nil
    }

    /// Efface tout (flux, gabarits, compteurs).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        decoder = FlowDecoder(limits: decoder.limits)
        aggregator.removeAll()
        stats = FlowCollectorStatus()
        exporterStats = [:]
    }

    /// Lignes gardées en mémoire (tests de la mémoire bornée).
    public var storedRows: Int {
        lock.lock(); defer { lock.unlock() }
        return aggregator.storedRows
    }

    // MARK: Essai local

    /// Envoie un datagramme à ce Mac (127.0.0.1 seulement) : vérifie que l'écoute répond.
    @discardableResult
    public static func sendToSelf(_ bytes: [UInt8], port: UInt16) -> Bool {
        LogUDPListener.sendToSelf(bytes, port: port)
    }
}
