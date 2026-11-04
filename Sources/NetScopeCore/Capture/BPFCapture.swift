import Darwin
import Foundation

/// Instruction BPF classique (même disposition que `struct bpf_insn` : 8 octets).
public struct BPFInstruction: Equatable, Sendable {
    public var code: UInt16
    public var jt: UInt8
    public var jf: UInt8
    public var k: UInt32

    public init(_ code: UInt16, _ jt: UInt8, _ jf: UInt8, _ k: UInt32) {
        self.code = code
        self.jt = jt
        self.jf = jf
        self.k = k
    }
}

/// Filtres BPF fixes posés dans le noyau (seules les trames utiles remontent) et petit interprète
/// des mêmes instructions, pour les tests.
public enum BPFFilter {
    // Codes employés : ld/ldh/ldb absolus, ldh indexé, ldx 4*([k]&0xf), jeq, jset, ret.
    static let ldW: UInt16 = 0x20, ldH: UInt16 = 0x28, ldB: UInt16 = 0x30
    static let ldHInd: UInt16 = 0x48, ldxMSH: UInt16 = 0xB1
    static let jeq: UInt16 = 0x15, jset: UInt16 = 0x45, ret: UInt16 = 0x06

    /// LLDP (EtherType 0x88CC) ou CDP (destination 01:00:0C:CC:CC:CC).
    public static let neighbors: [BPFInstruction] = [
        BPFInstruction(ldH, 0, 0, 12),
        BPFInstruction(jeq, 4, 0, 0x88CC),
        BPFInstruction(ldW, 0, 0, 0),
        BPFInstruction(jeq, 0, 3, 0x0100_0CCC),
        BPFInstruction(ldH, 0, 0, 4),
        BPFInstruction(jeq, 0, 1, 0xCCCC),
        BPFInstruction(ret, 0, 0, 65_535),
        BPFInstruction(ret, 0, 0, 0),
    ]

    /// IPv4, UDP, non fragmenté (ni décalage ni drapeau « autres fragments »), port de destination 68.
    public static let dhcpClient: [BPFInstruction] = [
        BPFInstruction(ldH, 0, 0, 12),
        BPFInstruction(jeq, 0, 8, 0x0800),
        BPFInstruction(ldB, 0, 0, 23),
        BPFInstruction(jeq, 0, 6, 17),
        BPFInstruction(ldH, 0, 0, 20),
        BPFInstruction(jset, 4, 0, 0x3FFF),
        BPFInstruction(ldxMSH, 0, 0, 14),
        BPFInstruction(ldHInd, 0, 0, 16),
        BPFInstruction(jeq, 0, 1, 68),
        BPFInstruction(ret, 0, 0, 65_535),
        BPFInstruction(ret, 0, 0, 0),
    ]

    /// Exécute le programme sur une trame ; renvoie le nombre d'octets gardés (0 : rejetée).
    /// Comme le noyau, une lecture hors de la trame rejette la trame.
    public static func run(_ program: [BPFInstruction], on packet: [UInt8]) -> UInt32 {
        var a: UInt32 = 0, x: UInt32 = 0, pc = 0
        func load(_ offset: Int, _ size: Int) -> UInt32? {
            guard offset >= 0, offset + size <= packet.count else { return nil }
            switch size {
            case 1: return UInt32(packet[offset])
            case 2: return UInt32(CaptureBytes.u16(packet, offset))
            default: return CaptureBytes.u32(packet, offset)
            }
        }
        while pc < program.count {
            let insn = program[pc]
            pc += 1
            switch insn.code {
            case ldW: guard let v = load(Int(insn.k), 4) else { return 0 }; a = v
            case ldH: guard let v = load(Int(insn.k), 2) else { return 0 }; a = v
            case ldB: guard let v = load(Int(insn.k), 1) else { return 0 }; a = v
            case ldHInd: guard let v = load(Int(x) + Int(insn.k), 2) else { return 0 }; a = v
            case ldxMSH: guard let v = load(Int(insn.k), 1) else { return 0 }; x = (v & 0x0F) * 4
            case jeq: pc += Int(a == insn.k ? insn.jt : insn.jf)
            case jset: pc += Int(a & insn.k != 0 ? insn.jt : insn.jf)
            case ret: return insn.k
            default: return 0
            }
        }
        return 0
    }
}

/// Lecture des enregistrements d'un tampon BPF (`struct bpf_hdr` puis la trame, alignés sur 4 octets).
public enum BPFBuffer {
    /// Alignement des enregistrements (BPF_ALIGNMENT = sizeof(int32_t) sur macOS).
    static let alignment = 4

    public static func frames(in buffer: [UInt8], length: Int? = nil) -> [CapturedFrame] {
        let end = min(length ?? buffer.count, buffer.count)
        var frames: [CapturedFrame] = []
        var offset = 0
        // bpf_hdr : horodatage (2 × 32 bits), caplen (32), datalen (32), hdrlen (16).
        while offset + 18 <= end {
            let seconds = CaptureBytes.le32(buffer, offset)
            let micros = CaptureBytes.le32(buffer, offset + 4)
            let capLength = Int(CaptureBytes.le32(buffer, offset + 8))
            let headerLength = Int(CaptureBytes.le16(buffer, offset + 16))
            guard headerLength >= 18, capLength >= 0 else { break }
            let start = offset + headerLength
            guard start + capLength <= end else { break }
            let date = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(micros) / 1_000_000)
            frames.append(CapturedFrame(bytes: Array(buffer[start..<(start + capLength)]), date: date))
            let next = offset + align(headerLength + capLength)
            guard next > offset else { break }
            offset = next
        }
        return frames
    }

    static func align(_ value: Int) -> Int { (value + alignment - 1) & ~(alignment - 1) }
}

/// Codes ioctl de BPF (les macros _IOW de <net/bpf.h> ne sont pas importées en Swift).
public enum BPFIoctl {
    static let void: UInt = 0x2000_0000, out: UInt = 0x4000_0000, `in`: UInt = 0x8000_0000

    static func code(_ direction: UInt, _ number: UInt, _ length: Int) -> UInt {
        direction | ((UInt(length) & 0x1FFF) << 16) | (UInt(UInt8(ascii: "B")) << 8) | number
    }

    public static let getBufferLength = code(out, 102, 4)               // BIOCGBLEN
    public static let setBufferLength = code(out | `in`, 102, 4)        // BIOCSBLEN
    public static let setFilter = code(`in`, 103, 16)                   // BIOCSETF (struct bpf_program)
    public static let promiscuous = code(void, 105, 0)                  // BIOCPROMISC
    public static let setInterface = code(`in`, 108, 32)                // BIOCSETIF (struct ifreq)
    public static let immediate = code(`in`, 112, 4)                    // BIOCIMMEDIATE
    public static let seeSent = code(`in`, 119, 4)                      // BIOCSSEESENT
}

/// Capture passive sur /dev/bpf*, possible seulement si l'utilisateur peut ouvrir ces fichiers
/// (accès donné par ChmodBPF de Wireshark, par exemple). Rien n'est jamais écrit sur le réseau.
public final class BPFCapture: @unchecked Sendable {
    private var fd: Int32
    private let bufferLength: Int
    private let lock = NSLock()
    /// Lectures en cours (poll/read hors verrou) : le descripteur n'est fermé qu'à zéro, pour
    /// qu'un numéro fermé puis réattribué ne soit jamais lu.
    private var activeReads = 0
    private var stopping = false

    /// Premier /dev/bpf* ouvrable en lecture par cet utilisateur, sinon nil (accès réservé à root).
    public static func readableDevice() -> String? {
        for index in 0..<256 {
            let path = "/dev/bpf\(index)"
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return path
            }
            // ENOENT : plus de périphérique ; EBUSY : celui-ci est pris, on essaie le suivant.
            if errno == ENOENT { return nil }
            if errno == EACCES || errno == EPERM { return nil }
        }
        return nil
    }

    /// Ouvre un périphérique BPF, l'attache à l'interface et pose le filtre fixe.
    public init(interface: String, filter: [BPFInstruction], promiscuous: Bool) throws {
        guard CaptureInterfaceName.isValid(interface) else {
            throw ToolError.invalidInput("Nom d’interface refusé\u{00A0}: « \(interface) ».")
        }
        var opened: Int32 = -1
        for index in 0..<256 {
            let candidate = open("/dev/bpf\(index)", O_RDONLY)
            if candidate >= 0 { opened = candidate; break }
            if errno != EBUSY { break }
        }
        guard opened >= 0 else { throw ToolSocket.lastError("ouverture de /dev/bpf") }
        fd = opened

        var length: UInt32 = 1 << 16
        _ = ioctl(fd, BPFIoctl.setBufferLength, &length)
        var actual: UInt32 = 0
        guard ioctl(fd, BPFIoctl.getBufferLength, &actual) == 0, actual > 0 else {
            close(fd)
            throw ToolSocket.lastError("taille du tampon BPF")
        }
        bufferLength = Int(actual)

        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { raw in
            for (i, byte) in interface.utf8.prefix(15).enumerated() { raw[i] = byte }
        }
        guard ioctl(fd, BPFIoctl.setInterface, &request) == 0 else {
            close(fd)
            throw ToolSocket.lastError("attache BPF à \(interface)")
        }
        var one: UInt32 = 1
        _ = ioctl(fd, BPFIoctl.immediate, &one)
        var zero: UInt32 = 0
        _ = ioctl(fd, BPFIoctl.seeSent, &zero)
        if promiscuous {
            // Mode promiscuité : seulement pour recevoir les adresses de groupe LLDP et CDP.
            _ = ioctl(fd, BPFIoctl.promiscuous, 0)
        }
        var instructions = filter
        let status: Int32 = instructions.withUnsafeMutableBufferPointer { buffer in
            var program = BPFProgram(length: UInt32(buffer.count), instructions: UnsafeMutableRawPointer(buffer.baseAddress!))
            return ioctl(fd, BPFIoctl.setFilter, &program)
        }
        guard status == 0 else {
            close(fd)
            throw ToolSocket.lastError("filtre BPF")
        }
    }

    deinit { stop() }

    /// Attend au plus `timeout` secondes et renvoie les trames reçues.
    public func read(timeout: TimeInterval) -> [CapturedFrame] {
        lock.lock()
        guard fd >= 0, !stopping else {
            lock.unlock()
            return []
        }
        let current = fd
        activeReads += 1
        lock.unlock()
        defer { endRead() }
        var poller = pollfd(fd: current, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Int32(max(0, timeout) * 1000))
        guard ready > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: bufferLength)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(current, $0.baseAddress, bufferLength) }
        guard count > 0 else { return [] }
        return BPFBuffer.frames(in: buffer, length: count)
    }

    /// Demande l'arrêt. Si une lecture est en cours, c'est elle qui ferme le descripteur en sortant
    /// (au plus le délai de son poll) ; sinon il est fermé tout de suite.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopping = true
        closeIfIdle()
    }

    private func endRead() {
        lock.lock()
        defer { lock.unlock() }
        activeReads -= 1
        if stopping { closeIfIdle() }
    }

    /// À appeler sous verrou.
    private func closeIfIdle() {
        guard activeReads == 0, fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}

/// Même disposition que `struct bpf_program` (u_int, puis pointeur aligné sur 8 octets).
private struct BPFProgram {
    var length: UInt32
    var instructions: UnsafeMutableRawPointer
}
