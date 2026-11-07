import Foundation

/// Small byte/string helpers shared by the protocol code.
enum Bytes {
    private static let digits: [Character] = Array("0123456789abcdef")

    /// Lowercase hex, identical to the original `String.format("%02x", b)` loop.
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var s = ""
        for b in bytes {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0F)])
        }
        return s
    }

    static func fromHex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48      // 0-9
        case 97...102: return c - 87     // a-f
        case 65...70: return c - 55      // A-F
        default: return nil
        }
    }

    static func utf8<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        return String(decoding: Array(bytes), as: UTF8.self)
    }

    /// ISO-8859-1: every byte maps to the code point of the same value.
    static func latin1<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var v = String.UnicodeScalarView()
        for b in bytes { v.append(Unicode.Scalar(b)) }
        return String(v)
    }

    /// US-ASCII like Java: bytes >= 0x80 become U+FFFD.
    static func ascii<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var v = String.UnicodeScalarView()
        for b in bytes {
            if b < 0x80 {
                v.append(Unicode.Scalar(b))
            } else if let r = Unicode.Scalar(UInt32(0xFFFD)) {
                v.append(r)
            }
        }
        return String(v)
    }

    /// Big-endian helpers (callers guarantee the bounds, as the original did).
    static func u16(_ a: [UInt8], _ i: Int) -> Int {
        return (Int(a[i]) << 8) | Int(a[i + 1])
    }

    static func u32(_ a: [UInt8], _ i: Int) -> Int64 {
        return (Int64(a[i]) << 24) | (Int64(a[i + 1]) << 16) | (Int64(a[i + 2]) << 8) | Int64(a[i + 3])
    }
}
