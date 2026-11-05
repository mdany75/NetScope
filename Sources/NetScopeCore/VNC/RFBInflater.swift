import Foundation
import zlib

/// Flux zlib persistant de l'encodage ZRLE (RFC 6143 § 7.7.6) : un seul flux pour toute la
/// session, chaque rectangle se terminant par une purge (Z_SYNC_FLUSH) du serveur. Bibliothèque
/// zlib du système (libz), aucune dépendance externe.
final class RFBInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var ready = false

    init() {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if ready { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Décompresse `input` (suite du flux) et rend tous les octets produits ; au-delà de
    /// `maxOutput` octets, le flux est rejeté (bombe zlib).
    func inflate(_ input: [UInt8], maxOutput: Int = Int.max) throws -> [UInt8] {
        if !ready {
            guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw RFBError.protocolViolation("zlib indisponible")
            }
            ready = true
        }
        guard !input.isEmpty else { return [] }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var source = input
        try source.withUnsafeMutableBufferPointer { inputBuffer in
            stream.pointee.next_in = inputBuffer.baseAddress
            stream.pointee.avail_in = uInt(inputBuffer.count)
            repeat {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { outBuffer in
                    stream.pointee.next_out = outBuffer.baseAddress
                    stream.pointee.avail_out = uInt(outBuffer.count)
                    let status = zlib.inflate(stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw RFBError.protocolViolation("flux ZRLE corrompu (zlib \(status))")
                    }
                    return outBuffer.count - Int(stream.pointee.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
                guard output.count <= maxOutput else {
                    throw RFBError.protocolViolation("ZRLE\u{00A0}: données décompressées trop grandes (plus de \(maxOutput) octets)")
                }
                // Place restante en sortie : toute l'entrée disponible a été traitée.
                if stream.pointee.avail_out != 0 { break }
            } while true
            stream.pointee.next_in = nil
        }
        return output
    }
}

/// Compression zlib d'un bloc (tests et serveur de démonstration) : flux persistant, purge
/// Z_SYNC_FLUSH à chaque appel, comme un serveur VNC.
public final class RFBDeflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var ready = false

    public init() {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if ready { deflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    public func deflate(_ input: [UInt8]) -> [UInt8] {
        if !ready {
            guard deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return [] }
            ready = true
        }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var source = input
        source.withUnsafeMutableBufferPointer { inputBuffer in
            stream.pointee.next_in = inputBuffer.baseAddress
            stream.pointee.avail_in = uInt(inputBuffer.count)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { outBuffer in
                    stream.pointee.next_out = outBuffer.baseAddress
                    stream.pointee.avail_out = uInt(outBuffer.count)
                    _ = zlib.deflate(stream, Z_SYNC_FLUSH)
                    return outBuffer.count - Int(stream.pointee.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
                if stream.pointee.avail_out != 0 { break }
            } while true
            stream.pointee.next_in = nil
        }
        return output
    }
}
