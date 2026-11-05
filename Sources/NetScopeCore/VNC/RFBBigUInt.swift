import Foundation

/// Entier non signé de taille quelconque, juste ce qu'il faut pour le Diffie-Hellman de
/// l'authentification Apple Remote Desktop : exponentiation modulaire de Montgomery (module impair).
/// Mots de 32 bits, poids faible en premier.
public struct RFBBigUInt: Equatable, Sendable, CustomStringConvertible {
    public private(set) var limbs: [UInt32]

    public init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    public init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    /// Octets gros-boutistes (ordre du réseau).
    public init(bigEndian bytes: [UInt8]) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 4] |= UInt32(byte) << UInt32((index % 4) * 8)
        }
        self.init(limbs: limbs)
    }

    /// Octets gros-boutistes, complétés par des zéros à gauche jusqu'à `length` (tronqués à gauche
    /// si la valeur est plus longue).
    public func bigEndianBytes(length: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            let limb = index / 4
            guard limb < limbs.count else { break }
            result[length - 1 - index] = UInt8((limbs[limb] >> UInt32((index % 4) * 8)) & 0xFF)
        }
        return result
    }

    public var isZero: Bool { limbs.isEmpty }
    public var bitWidth: Int { limbs.isEmpty ? 0 : limbs.count * 32 - limbs[limbs.count - 1].leadingZeroBitCount }

    public var description: String {
        guard !limbs.isEmpty else { return "0" }
        return limbs.reversed().enumerated().map { index, limb in
            index == 0 ? String(limb, radix: 16) : String(repeating: "0", count: 8 - String(limb, radix: 16).count) + String(limb, radix: 16)
        }.joined()
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] >> UInt32(index % 32) & 1 == 1
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    // MARK: Arithmétique sur des mots de longueur fixe

    /// a ≥ b, sur `count` mots.
    private static func greaterOrEqual(_ a: [UInt32], _ b: [UInt32], count: Int) -> Bool {
        for i in stride(from: count - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// a -= b sur `count` mots (a ≥ b, ou retenue ignorée).
    private static func subtract(_ a: inout [UInt32], _ b: [UInt32], count: Int) {
        var borrow: Int64 = 0
        for i in 0..<count {
            let difference = Int64(a[i]) - Int64(i < b.count ? b[i] : 0) - borrow
            a[i] = UInt32(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
    }

    /// self mod m, bit à bit (lent mais simple ; sert à réduire une entrée et à calculer R² mod m).
    public func modulo(_ m: RFBBigUInt) -> RFBBigUInt {
        precondition(!m.isZero, "module nul")
        let n = m.limbs.count
        var r = [UInt32](repeating: 0, count: n + 1)
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            // r = 2r + bit
            var carry: UInt32 = bit(index) ? 1 : 0
            for i in 0...n {
                let next = r[i] >> 31
                r[i] = r[i] << 1 | carry
                carry = next
            }
            if Self.greaterOrEqual(r, m.limbs, count: n + 1) { Self.subtract(&r, m.limbs, count: n + 1) }
        }
        return RFBBigUInt(limbs: r)
    }

    /// (base ^ exponent) mod modulus, module impair (Montgomery, mots de 32 bits).
    public static func modPow(_ base: RFBBigUInt, _ exponent: RFBBigUInt, _ modulus: RFBBigUInt) -> RFBBigUInt {
        precondition(modulus.limbs.first.map { $0 & 1 == 1 } ?? false, "module pair ou nul")
        let m = modulus.limbs
        let n = m.count
        // -m⁻¹ mod 2³² (Newton).
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- m[0] &* inverse) }
        let mPrime = 0 &- inverse

        func pad(_ value: RFBBigUInt) -> [UInt32] {
            value.limbs + [UInt32](repeating: 0, count: n - value.limbs.count)
        }

        func montgomery(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: n + 2)
            for i in 0..<n {
                var carry: UInt64 = 0
                let bi = UInt64(b[i])
                for j in 0..<n {
                    let s = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                    t[j] = UInt32(truncatingIfNeeded: s)
                    carry = s >> 32
                }
                var s = UInt64(t[n]) + carry
                t[n] = UInt32(truncatingIfNeeded: s)
                t[n + 1] = UInt32(s >> 32)
                let q = UInt64(t[0] &* mPrime)
                s = UInt64(t[0]) + q * UInt64(m[0])
                carry = s >> 32
                for j in 1..<n {
                    s = UInt64(t[j]) + q * UInt64(m[j]) + carry
                    t[j - 1] = UInt32(truncatingIfNeeded: s)
                    carry = s >> 32
                }
                s = UInt64(t[n]) + carry
                t[n - 1] = UInt32(truncatingIfNeeded: s)
                t[n] = t[n + 1] &+ UInt32(s >> 32)
                t[n + 1] = 0
            }
            var result = Array(t[0...n])
            if greaterOrEqual(result, m, count: n + 1) { subtract(&result, m, count: n + 1) }
            return Array(result[0..<n])
        }

        // R = 2^(32n) ; R² mod m par doublements successifs.
        var rSquared = [UInt32](repeating: 0, count: n + 1)
        rSquared[0] = 1
        for _ in 0..<(64 * n) {
            var carry: UInt32 = 0
            for i in 0...n {
                let next = rSquared[i] >> 31
                rSquared[i] = rSquared[i] << 1 | carry
                carry = next
            }
            if greaterOrEqual(rSquared, m, count: n + 1) { subtract(&rSquared, m, count: n + 1) }
        }
        let r2 = Array(rSquared[0..<n])
        let one = pad(RFBBigUInt(1))
        var result = montgomery(one, r2)          // 1 · R mod m
        let b = montgomery(pad(base.modulo(modulus)), r2)
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = montgomery(result, result)
            if exponent.bit(index) { result = montgomery(result, b) }
        }
        return RFBBigUInt(limbs: montgomery(result, one))
    }
}
