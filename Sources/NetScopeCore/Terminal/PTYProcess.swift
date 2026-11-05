import Darwin
import Foundation

/// Processus local lancé dans un pseudo-terminal (openpty + posix_spawn) : /usr/bin/ssh pour les
/// onglets SSH. Le processus devient chef de session et prend le pseudo-terminal comme terminal de
/// contrôle (Ctrl-C, taille de la fenêtre) ; aucun fork dans l'application.
public final class PTYProcess: TerminalTransport, @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        case openpty(Int32)
        case spawn(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .openpty(let code): return "Pseudo-terminal indisponible (\(String(cString: strerror(code))))."
            case .spawn(let path, let code): return "Lancement de \(path) impossible (\(String(cString: strerror(code))))."
            }
        }
    }

    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public private(set) var pid: pid_t = 0

    private var master: Int32 = -1
    private var columns: Int
    private var rows: Int
    private let queue = DispatchQueue(label: "netscope.pty.lecture")
    private let writeQueue = DispatchQueue(label: "netscope.pty.ecriture")
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var handler: (@Sendable (TerminalTransportEvent) -> Void)?
    private let lock = TerminalLock()
    private var finished = false
    /// Posé (sous le verrou) juste avant waitpid : après, le pid peut appartenir à un autre processus.
    private var reaped = false

    // Constantes de <sys/ttycom.h> et <spawn.h> (macros non importées par Swift).
    static let TIOCSWINSZ: UInt = 0x8008_7467
    static let spawnSetSID: Int32 = 0x0400
    static let spawnCloexecDefault: Int32 = 0x4000
    static let spawnSetSigDefault: Int32 = 0x0004
    static let spawnSetSigMask: Int32 = 0x0008

    public init(executable: String, arguments: [String], environment: [String: String], columns: Int = 80, rows: Int = 24) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.columns = columns
        self.rows = rows
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
        if master >= 0 { Darwin.close(master) }
    }

    /// Lance le processus. Les événements arrivent sur un fil d'arrière-plan.
    public func start(_ handler: @escaping @Sendable (TerminalTransportEvent) -> Void) {
        self.handler = handler
        do {
            try launch()
            handler(.connected)
        } catch {
            finish((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func launch() throws {
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&masterFD, &slaveFD, &name, nil, &size) == 0 else { throw Failure.openpty(errno) }
        // Saisie UTF-8 : l'effacement arrière retire un caractère entier, pas un octet.
        var settings = termios()
        if tcgetattr(slaveFD, &settings) == 0 {
            settings.c_iflag |= tcflag_t(IUTF8)
            tcsetattr(slaveFD, TCSANOW, &settings)
        }
        let slavePath = String(cString: name)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Ouvert APRÈS setsid dans le processus enfant : il devient son terminal de contrôle.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Self.spawnSetSID | Self.spawnCloexecDefault | Self.spawnSetSigDefault | Self.spawnSetSigMask
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults: sigset_t = ~0
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        Darwin.close(slaveFD)
        guard status == 0 else {
            Darwin.close(masterFD)
            throw Failure.spawn(executable, status)
        }
        pid = child
        master = masterFD
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)

        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        readSource = read
        read.resume()

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        // Référence forte jusqu’à la fin du processus : waitpid est toujours appelé (pas de zombie).
        exit.setEventHandler { self.childExited() }
        exitSource = exit
        exit.resume()
    }

    /// Lit tout ce qui attend sur le pseudo-terminal ; renvoie faux à la fin du flux.
    @discardableResult
    private func drain() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                handler?(.data(Array(buffer[0..<count])))
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return true }
            // 0 ou EIO : plus aucun processus ne tient le terminal.
            readSource?.cancel()
            readSource = nil
            return false
        }
    }

    private func childExited() {
        var status: Int32 = 0
        lock.run { reaped = true }
        _ = waitpid(pid, &status, 0)
        if readSource != nil { drain() }
        let signal = status & 0x7F
        let code = (status >> 8) & 0xFF
        if signal != 0 {
            finish(signal == SIGHUP || signal == SIGTERM ? nil : "Processus arrêté par le signal \(signal).")
        } else {
            finish(code == 0 ? nil : "Session terminée (code \(code)).")
        }
    }

    private func finish(_ message: String?) {
        let first = lock.run { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard first else { return }
        exitSource?.cancel()
        exitSource = nil
        handler?(.closed(message))
    }

    public func send(_ bytes: [UInt8]) {
        guard master >= 0, !bytes.isEmpty else { return }
        let fd = master
        writeQueue.async {
            var offset = 0
            var attempts = 0
            while offset < bytes.count, attempts < 500 {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    attempts += 1
                    usleep(2_000)
                } else {
                    return
                }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, Self.TIOCSWINSZ, &size)
        // Le noyau prévient déjà le groupe au premier plan ; le signal direct couvre le cas où
        // le pseudo-terminal n'est pas devenu terminal de contrôle.
        // Sous le verrou : le processus n'est pas encore récolté, son pid ne peut pas être réattribué.
        let target = pid
        lock.run { if target > 0, !reaped, !finished { kill(target, SIGWINCH) } }
    }

    /// Ferme la session : SIGHUP au groupe du processus, puis SIGKILL s'il résiste.
    public func close() {
        guard pid > 0 else { return }
        let target = pid
        let done = lock.run { finished }
        guard !done else { return }
        kill(-target, SIGHUP)
        kill(target, SIGHUP)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.lock.run({ self.finished }) else { return }
            kill(-target, SIGKILL)
            kill(target, SIGKILL)
        }
    }
}
