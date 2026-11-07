import Foundation
import CryptoKit

/// What the auth handshake mixes into its HMACs.
struct RingIdentity: Equatable {
    var bindKey: String
    var fwid: String
    var sn: String
    var mac: String   // "AA:BB:CC:DD:EE:FF" – see RingConfig.mac
}

struct RingChallenge: Equatable {
    let nonce: String
    let ringAuth: String
}

/// The nested-HMAC handshake math, ported 1:1 from `RingProtocol.java`.
enum RingCrypto {
    /// HMAC-SHA256 where both key and message are taken as UTF-8 text; result as lowercase hex.
    static func hmacHex(key: String, message: String) -> String {
        let k = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: k)
        return Bytes.hex(Array(mac))
    }

    /// `kh()`: hex string of the UTF-8 bytes of the bind key. Used as the HMAC key *string*.
    static func keyHex(_ id: RingIdentity) -> String {
        return Bytes.hex(Array(id.bindKey.utf8))
    }

    /// `content(n)`: `<fwid>_<sn>_<mac>_<n>`.
    static func content(_ id: RingIdentity, _ n: String) -> String {
        return id.fwid + "_" + id.sn + "_" + id.mac + "_" + n
    }

    /// Parses the ring's challenge: payload `[01][?]<nonce>@<ringAuth>` (nonce starts at byte 2).
    /// Mirrors Java's `split("@")` use: nonce = part 0, ringAuth = part 1 or "".
    static func parseChallenge(_ data: [UInt8]) -> RingChallenge? {
        guard data.count >= 2, data[0] == 0x01 else { return nil }
        let body = Bytes.utf8(data[2...])
        let parts = body.split(separator: "@", maxSplits: Int.max, omittingEmptySubsequences: false)
        let nonce = parts.first.map(String.init) ?? ""
        let ringAuth = parts.count > 1 ? String(parts[1]) : ""
        return RingChallenge(nonce: nonce, ringAuth: ringAuth)
    }

    /// Does the ring prove it knows the bind key? (Original only logs this, it never aborts.)
    static func verifyRing(_ c: RingChallenge, identity id: RingIdentity) -> Bool {
        return hmacHex(key: keyHex(id), message: content(id, c.nonce)) == c.ringAuth
    }

    /// Payload of the app's answer: `[03][len(an)] an '@' aa` with
    /// `an = "app_" + nonce`, `inner = HMAC(kh, an)`, `aa = HMAC(inner, content(an))`.
    static func appResponse(nonce: String, identity id: RingIdentity) -> [UInt8] {
        let an = "app_" + nonce
        let inner = hmacHex(key: keyHex(id), message: an)
        let aa = hmacHex(key: inner, message: content(id, an))
        let anb = Array(an.utf8)
        let aab = Array(aa.utf8)
        var pl = [UInt8]()
        pl.reserveCapacity(2 + anb.count + 1 + aab.count)
        pl.append(0x03)
        pl.append(UInt8(truncatingIfNeeded: anb.count))
        pl.append(contentsOf: anb)
        pl.append(UInt8(ascii: "@"))
        pl.append(contentsOf: aab)
        return pl
    }

    /// `0x81` payload: `[03][len(userId)] userId`.
    static func userIdPayload(_ userId: String) -> [UInt8] {
        let uid = Array(userId.utf8)
        return [0x03, UInt8(truncatingIfNeeded: uid.count)] + uid
    }
}
