import Darwin
import Foundation

/// Réglages d'une console série (termios).
public struct SerialSettings: Codable, Hashable, Sendable {
    public enum Parity: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, even, odd
        public var id: String { rawValue }
        public var letter: String { self == .none ? "N" : (self == .even ? "E" : "O") }
        public var label: String {
            switch self {
            case .none: return "Aucune (N)"
            case .even: return "Paire (E)"
            case .odd: return "Impaire (O)"
            }
        }
    }

    public enum FlowControl: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, xonXoff, rtsCts
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none: return "Aucun"
            case .xonXoff: return "XON/XOFF (logiciel)"
            case .rtsCts: return "RTS/CTS (matériel)"
            }
        }
        public var shortLabel: String {
            switch self {
            case .none: return "aucun"
            case .xonXoff: return "XON/XOFF"
            case .rtsCts: return "RTS/CTS"
            }
        }
    }

    /// Fin de ligne envoyée par Entrée.
    public enum LineEnding: String, Codable, CaseIterable, Identifiable, Sendable {
        case cr, crlf, lf
        public var id: String { rawValue }
        public var label: String { self == .cr ? "CR" : (self == .crlf ? "CR LF" : "LF") }
    }

    public static let baudRates = [1200, 2400, 4800, 9600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600]

    public var baudRate: Int
    public var dataBits: Int
    public var parity: Parity
    public var stopBits: Int
    public var flowControl: FlowControl
    public var lineEnding: LineEnding
    public var localEcho: Bool

    public init(baudRate: Int = 9600, dataBits: Int = 8, parity: Parity = .none, stopBits: Int = 1,
                flowControl: FlowControl = .none, lineEnding: LineEnding = .cr, localEcho: Bool = false) {
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.lineEnding = lineEnding
        self.localEcho = localEcho
    }

    /// Consoles Cisco, Fortinet, Aruba, HPE, Juniper : 9600 8N1 sans contrôle de flux.
    public static let ciscoConsole = SerialSettings()

    /// « 9600 8N1 ».
    public var summary: String { "\(baudRate) \(dataBits)\(parity.letter)\(stopBits)" }

    public enum ValidationError: LocalizedError, Equatable {
        case baud(Int), dataBits(Int), stopBits(Int)
        public var errorDescription: String? {
            switch self {
            case .baud(let value): return "Débit non pris en charge\u{00A0}: \(value) bauds."
            case .dataBits(let value): return "Bits de données invalides\u{00A0}: \(value) (5 à 8)."
            case .stopBits(let value): return "Bits d’arrêt invalides\u{00A0}: \(value) (1 ou 2)."
            }
        }
    }

    public func validated() throws -> SerialSettings {
        guard (50...4_000_000).contains(baudRate) else { throw ValidationError.baud(baudRate) }
        guard (5...8).contains(dataBits) else { throw ValidationError.dataBits(dataBits) }
        guard stopBits == 1 || stopBits == 2 else { throw ValidationError.stopBits(stopBits) }
        return self
    }

    /// Applique les réglages à une structure termios (mode brut, sans écho ni traduction).
    public func apply(to settings: inout termios) {
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(CSIZE)
        switch dataBits {
        case 5: settings.c_cflag |= tcflag_t(CS5)
        case 6: settings.c_cflag |= tcflag_t(CS6)
        case 7: settings.c_cflag |= tcflag_t(CS7)
        default: settings.c_cflag |= tcflag_t(CS8)
        }
        switch parity {
        case .none: settings.c_cflag &= ~tcflag_t(PARENB | PARODD)
        case .even:
            settings.c_cflag |= tcflag_t(PARENB)
            settings.c_cflag &= ~tcflag_t(PARODD)
        case .odd: settings.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        if stopBits == 2 { settings.c_cflag |= tcflag_t(CSTOPB) } else { settings.c_cflag &= ~tcflag_t(CSTOPB) }
        settings.c_cflag &= ~tcflag_t(CRTSCTS)
        settings.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch flowControl {
        case .none: break
        case .xonXoff: settings.c_iflag |= tcflag_t(IXON | IXOFF)
        case .rtsCts: settings.c_cflag |= tcflag_t(CRTSCTS)
        }
        // Lecture : retour dès qu'un octet est là.
        withUnsafeMutableBytes(of: &settings.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        cfsetispeed(&settings, speed_t(baudRate))
        cfsetospeed(&settings, speed_t(baudRate))
    }

    /// Octets d'Entrée selon la fin de ligne choisie.
    public var enterBytes: [UInt8] {
        switch lineEnding {
        case .cr: return [0x0D]
        case .crlf: return [0x0D, 0x0A]
        case .lf: return [0x0A]
        }
    }
}

/// Port série présent sur ce Mac, avec une description de l'adaptateur devinée par son nom.
public struct SerialPortInfo: Hashable, Identifiable, Sendable {
    public var path: String
    public var id: String { path }

    public init(path: String) {
        self.path = path
    }

    /// « cu.usbserial-A10K ».
    public var name: String { path.hasPrefix("/dev/") ? String(path.dropFirst(5)) : path }

    /// Adaptateur probable (pilote du nom de périphérique).
    public var adapter: String {
        let lower = name.lowercased()
        if lower.contains("bluetooth") { return "Bluetooth (pas un câble console)" }
        if lower.contains("slab_usbtouart") || lower.contains("cp210") { return "Silicon Labs CP210x (USB-série)" }
        if lower.contains("wchusbserial") || lower.contains("ch34") { return "WCH CH340 (USB-série)" }
        if lower.contains("usbserial-ft") || lower.contains("usbserial-a") || lower.contains("usbserial-b") || lower.contains("ftdi") {
            return "FTDI FT232 (USB-série)"
        }
        if lower.contains("pl2303") || lower.contains("usbserial-1") || lower.contains("usbserial-14") { return "Prolific PL2303 (USB-série)" }
        if lower.contains("usbserial") { return "Adaptateur USB-série" }
        if lower.contains("usbmodem") { return "Port console USB (CDC-ACM, mini-USB ou USB-C de l’appareil)" }
        if lower.contains("debug-console") { return "Console de débogage de macOS" }
        return "Port série"
    }

    /// Adaptateur USB (câble console probable), à proposer en premier.
    public var isUSB: Bool { name.lowercased().contains("usb") || name.contains("SLAB") || name.lowercased().contains("wch") }

    /// Ports /dev/cu.* présents (lecture du dossier seulement : aucun port n'est ouvert).
    public static func list(directory: String = "/dev", fileManager: FileManager = .default) -> [SerialPortInfo] {
        sorted(RemoteSerialPorts.list(directory: directory, fileManager: fileManager).map(SerialPortInfo.init(path:)))
    }

    /// Adaptateurs USB d'abord, puis ordre alphabétique.
    public static func sorted(_ ports: [SerialPortInfo]) -> [SerialPortInfo] {
        ports.sorted { lhs, rhs in
            lhs.isUSB != rhs.isUSB ? lhs.isUSB : lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}

/// Onglet de console série : ouvert seulement quand l'utilisateur ouvre la session (lecture et
/// écriture, accès exclusif), refermé à la fermeture de l'onglet.
public final class SerialTransport: TerminalTransport, @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        case open(String, Int32)
        case configure(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .open(let path, let code):
                if code == EBUSY { return "\(path) est déjà utilisé par une autre application (screen, minicom…)." }
                if code == ENOENT { return "\(path) n’est pas branché." }
                if code == EACCES { return "Accès refusé à \(path)." }
                return "Ouverture de \(path) impossible (\(String(cString: strerror(code))))."
            case .configure(let path, let code):
                return "Réglage de \(path) impossible (\(String(cString: strerror(code))))\u{00A0}: débit ou contrôle de flux non pris en charge par l’adaptateur\u{00A0}?"
            }
        }
    }

    public let path: String
    public let settings: SerialSettings
    private var fd: Int32 = -1
    /// File propre au chemin, partagée par les transports successifs du même port : la fermeture
    /// d'un ancien transport passe toujours avant l'ouverture du suivant (sinon TIOCEXCL → EBUSY).
    private let queue: DispatchQueue
    private static let queuesLock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]

    static func queue(for path: String) -> DispatchQueue {
        queuesLock.lock()
        defer { queuesLock.unlock() }
        if let queue = queues[path] { return queue }
        let queue = DispatchQueue(label: "netscope.serie." + path)
        queues[path] = queue
        return queue
    }
    private var readSource: DispatchSourceRead?
    private var handler: (@Sendable (TerminalTransportEvent) -> Void)?
    private let lock = TerminalLock()
    private var finished = false

    // <sys/ttycom.h>
    static let TIOCEXCL: UInt = 0x2000_740D
    static let TIOCNXCL: UInt = 0x2000_740E

    public init(path: String, settings: SerialSettings) {
        self.path = path
        self.settings = settings
        queue = Self.queue(for: path)
    }

    deinit {
        readSource?.cancel()
        if fd >= 0 {
            _ = ioctl(fd, Self.TIOCNXCL)
            Darwin.close(fd)
        }
    }

    public var wantsLocalEcho: Bool { settings.localEcho }

    public func start(_ handler: @escaping @Sendable (TerminalTransportEvent) -> Void) {
        self.handler = handler
        queue.async { [self] in
            do {
                try open()
                handler(.connected)
            } catch {
                finish((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func open() throws {
        let settings = try self.settings.validated()
        // O_NONBLOCK : l'ouverture n'attend pas le signal DCD (câble console sans modem).
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.open(path, errno) }
        _ = ioctl(descriptor, Self.TIOCEXCL)
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.configure(path, code)
        }
        settings.apply(to: &options)
        guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.configure(path, code)
        }
        tcflush(descriptor, TCIOFLUSH)
        fd = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        readSource = source
        source.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while fd >= 0 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                handler?(.data(Array(buffer[0..<count])))
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // Adaptateur débranché (ENXIO) ou fin de flux.
            finish(count == 0 ? "Port \(path) fermé." : "Adaptateur \(path) débranché.")
            return
        }
    }

    public func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            var offset = 0
            var attempts = 0
            while offset < bytes.count, attempts < 1_000 {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    attempts += 1
                    usleep(1_000)
                } else {
                    finish("Écriture impossible sur \(path).")
                    return
                }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {}

    /// Signal « break » de 0,25 à 0,5 s (tcsendbreak) : interruption du démarrage (ROMMON, BIOS).
    public func sendBreak() {
        queue.async { [self] in
            guard fd >= 0 else { return }
            tcsendbreak(fd, 0)
        }
    }

    public func close() {
        queue.async { [self] in finish(nil) }
    }

    private func finish(_ message: String?) {
        let first = lock.run { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard first else { return }
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            _ = ioctl(fd, Self.TIOCNXCL)
            Darwin.close(fd)
            fd = -1
        }
        handler?(.closed(message))
    }
}
