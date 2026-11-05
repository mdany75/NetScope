import Darwin
import Foundation

/// Petites fonctions UDP du TFTP (sockets BSD, IPv4).
enum TFTPSocket {
    /// Socket UDP lié à `address:port` (port 0 : port libre choisi par macOS). Renvoie le socket et
    /// le port obtenu. `receiveDestination` demande l'adresse locale de chaque paquet reçu
    /// (IP_RECVDSTADDR), pour filtrer l'interface d'écoute quand le socket écoute partout.
    static func bind(address: IPv4Address?, port: UInt16, receiveDestination: Bool = false) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ToolSocket.lastError("socket UDP") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if receiveDestination {
            setsockopt(fd, IPPROTO_IP, IP_RECVDSTADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        // Tampons plus grands : une fenêtre de blocs de 64 Kio ne doit pas déborder.
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: (address?.value ?? 0).bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw TFTPBindError(code: code, port: port, address: address)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    struct Datagram {
        var bytes: [UInt8]
        var from: IPv4Address
        var fromPort: UInt16
        /// Adresse locale qui a reçu le paquet (IP_RECVDSTADDR), si demandée.
        var destination: IPv4Address?
    }

    enum Wait {
        case datagram(Datagram)
        case timeout
        case failure(String)
    }

    /// Attend un paquet au plus `timeout` secondes.
    static func receive(_ fd: Int32, timeout: TimeInterval) -> Wait {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(clamping: Int((max(0, min(timeout, 3600)) * 1000).rounded(.up)))
        let ready = poll(&pfd, 1, milliseconds)
        if ready == 0 { return .timeout }
        if ready < 0 {
            if errno == EINTR { return .timeout }
            return .failure(String(cString: strerror(errno)))
        }
        var buffer = [UInt8](repeating: 0, count: TFTPPacket.maxPacketSize + 16)
        var control = [UInt8](repeating: 0, count: 64)
        var from = sockaddr_in()
        var destination: IPv4Address?
        let count: Int = buffer.withUnsafeMutableBytes { bufferPointer in
            control.withUnsafeMutableBytes { controlPointer in
                withUnsafeMutablePointer(to: &from) { fromPointer in
                    var iov = iovec(iov_base: bufferPointer.baseAddress, iov_len: bufferPointer.count)
                    return withUnsafeMutablePointer(to: &iov) { iovPointer in
                        var message = msghdr(msg_name: UnsafeMutableRawPointer(fromPointer),
                                             msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
                                             msg_iov: iovPointer, msg_iovlen: 1,
                                             msg_control: controlPointer.baseAddress,
                                             msg_controllen: socklen_t(controlPointer.count), msg_flags: 0)
                        let received = recvmsg(fd, &message, 0)
                        if received >= 0 {
                            destination = Self.destination(in: controlPointer, length: Int(message.msg_controllen))
                        }
                        return received
                    }
                }
            }
        }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return .timeout }
            // Port injoignable (ICMP) sur un socket connecté : l'appareil n'écoute plus.
            if errno == ECONNREFUSED { return .failure("l’appareil a refusé la connexion (port fermé)") }
            return .failure(String(cString: strerror(errno)))
        }
        return .datagram(Datagram(bytes: Array(buffer[0..<count]),
                                  from: IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)),
                                  fromPort: UInt16(bigEndian: from.sin_port), destination: destination))
    }

    /// Lit l'adresse IP_RECVDSTADDR dans les données de contrôle (CMSG_* n'existe pas en Swift :
    /// en-têtes cmsghdr alignés sur 4 octets sous Darwin).
    private static func destination(in control: UnsafeMutableRawBufferPointer, length: Int) -> IPv4Address? {
        guard let base = control.baseAddress else { return nil }
        let headerSize = MemoryLayout<cmsghdr>.size
        func align(_ value: Int) -> Int { (value + 3) & ~3 }
        var offset = 0
        while offset + headerSize <= min(length, control.count) {
            let header = base.load(fromByteOffset: offset, as: cmsghdr.self)
            let cmsgLength = Int(header.cmsg_len)
            guard cmsgLength >= headerSize else { return nil }
            if header.cmsg_level == IPPROTO_IP && header.cmsg_type == IP_RECVDSTADDR,
               offset + align(headerSize) + 4 <= control.count {
                var raw: UInt32 = 0
                memcpy(&raw, base + offset + align(headerSize), 4)
                return IPv4Address(UInt32(bigEndian: raw))
            }
            offset += align(cmsgLength)
        }
        return nil
    }

    @discardableResult
    static func send(_ fd: Int32, _ bytes: [UInt8], to address: IPv4Address, port: UInt16) -> Bool {
        var addr = ToolSocket.address(address, port: port)
        let sent = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent == bytes.count
    }
}

/// Échec de l'ouverture du port d'écoute, expliqué en clair.
public struct TFTPBindError: Error, Equatable, Sendable, LocalizedError {
    public var code: Int32
    public var port: UInt16
    public var address: IPv4Address?

    public var isPermission: Bool { code == EACCES || code == EPERM }
    public var isInUse: Bool { code == EADDRINUSE }

    public var errorDescription: String? {
        if isInUse {
            return "Le port UDP \(port) est déjà utilisé (le serveur TFTP de macOS, tftpd, ou une autre application)\u{00A0}: arrêtez-le ou choisissez un autre port."
        }
        if isPermission {
            return "macOS refuse le port \(port)\u{00A0}: sous 1024, il faut écouter sur toutes les interfaces (sans droits administrateur) ou choisir un port au-dessus de 1024."
        }
        if code == EADDRNOTAVAIL, let address {
            return "L’adresse \(address) n’existe plus sur ce Mac (interface débranchée\u{00A0}?)."
        }
        return "Ouverture du port UDP \(port) impossible (\(String(cString: strerror(code))))."
    }
}
