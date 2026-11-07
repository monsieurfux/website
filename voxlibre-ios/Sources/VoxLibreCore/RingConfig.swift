import Foundation

/// Minimal string storage. The app backs `plain` with UserDefaults and `secret` with the Keychain.
protocol KeyValueStore: AnyObject {
    func get(_ key: String) -> String
    func set(_ key: String, _ value: String)
}

/// In-memory store (tests, previews).
final class MemoryStore: KeyValueStore {
    private var d: [String: String] = [:]
    func get(_ key: String) -> String { return d[key] ?? "" }
    func set(_ key: String, _ value: String) { d[key] = value }
}

/// Per-ring identity.
///
/// Android picks the ring from the list of bonded devices and keeps its MAC. iOS never reveals
/// Bluetooth MAC addresses – a ring is addressed by a per-phone peripheral UUID instead.
/// The handshake HMACs need the MAC though, so on iOS it is taken from the ring's own `0x80`
/// device-info frame (the ring sends it byte-reversed), with an optional manual override in
/// Settings. SN/FWID are parsed from the same frame, like on Android.
///
/// BIND KEY / USER ID are secrets minted by Vocci's servers at pairing time. The user enters
/// them in Settings; they live in the Keychain and are never shipped.
final class RingConfig {
    private let plain: KeyValueStore
    private let secret: KeyValueStore
    /// Set after construction by the app (the log sink does not exist yet when the config is built).
    var logger: (String) -> Void

    private(set) var peripheralID: String
    private(set) var peripheralName: String
    private(set) var macOverride: String
    private(set) var sn: String
    private(set) var fwid: String
    private(set) var deviceMac: String
    private(set) var bindKey: String
    private(set) var userId: String

    init(plain: KeyValueStore, secret: KeyValueStore, log: @escaping (String) -> Void = { _ in }) {
        self.plain = plain
        self.secret = secret
        self.logger = log
        peripheralID = plain.get("peripheralID")
        peripheralName = plain.get("peripheralName")
        macOverride = plain.get("macOverride")
        sn = plain.get("sn")
        fwid = plain.get("fwid")
        deviceMac = plain.get("deviceMac")
        bindKey = secret.get("bindKey")
        userId = secret.get("userId")
    }

    /// A ring is selected.
    var isConfigured: Bool { return !peripheralID.isEmpty }

    /// Server-minted credentials are present (required to authenticate).
    var hasCredentials: Bool { return !bindKey.isEmpty && !userId.isEmpty }

    /// The MAC string used inside the HMAC content: override if set, else the one the ring reported.
    var mac: String { return macOverride.isEmpty ? deviceMac : macOverride }

    var identity: RingIdentity {
        return RingIdentity(bindKey: bindKey, fwid: fwid, sn: sn, mac: mac)
    }

    func setPeripheral(id: String, name: String) {
        peripheralID = id
        peripheralName = name
        plain.set("peripheralID", id)
        plain.set("peripheralName", name)
        logger("ring selected: \(name) (\(id))")
    }

    func setBindKey(_ v: String) {
        bindKey = v.trimmingCharacters(in: .whitespacesAndNewlines)
        secret.set("bindKey", bindKey)
    }

    func setUserId(_ v: String) {
        userId = v.trimmingCharacters(in: .whitespacesAndNewlines)
        secret.set("userId", userId)
    }

    func setMacOverride(_ v: String) {
        macOverride = RingConfig.normalizeMac(v)
        plain.set("macOverride", macOverride)
    }

    /// "aa-bb-cc…" / "aa:bb:cc…" / "aabbcc…" → "AA:BB:CC…". Anything that is not 12 hex digits is kept
    /// (upper-cased, trimmed) so the user can see and fix what they typed.
    static func normalizeMac(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.isEmpty { return "" }
        let digits = t.filter { $0.isHexDigit }
        let separatorsOnly = t.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" }
        guard digits.count == 12, separatorsOnly else { return t }
        var parts: [String] = []
        var cur = ""
        for ch in digits {
            cur.append(ch)
            if cur.count == 2 {
                parts.append(cur)
                cur = ""
            }
        }
        return parts.joined(separator: ":")
    }

    /// Formats a MAC that the ring sent byte-reversed: `FF EE DD CC BB AA` → "AA:BB:CC:DD:EE:FF".
    static func macString(fromReversed bytes: [UInt8]) -> String {
        return bytes.reversed().map { Bytes.hex([$0]).uppercased() }.joined(separator: ":")
    }

    /// 0x80: `[snLen][SN][macLen][MAC rev][fwLen][FWID]` – updates SN/FWID (+ MAC) and persists them.
    /// Returns false when the frame is too short to contain a serial number.
    @discardableResult
    func parseDeviceInfo(_ d: [UInt8]) -> Bool {
        var o = 0
        guard o < d.count else { return false }
        let snLen = Int(d[o]); o += 1
        guard o + snLen <= d.count else { return false }
        sn = Bytes.ascii(d[o..<(o + snLen)])
        o += snLen
        if o < d.count {
            let macLen = Int(d[o]); o += 1
            if macLen == 6, o + macLen <= d.count {
                deviceMac = RingConfig.macString(fromReversed: Array(d[o..<(o + macLen)]))
            }
            o += macLen
            if o < d.count {
                let fwLen = Int(d[o]); o += 1
                if o + fwLen <= d.count {
                    fwid = Bytes.ascii(d[o..<(o + fwLen)])
                }
            }
        }
        logger("device-info: SN=\(sn) FWID=\(fwid) MAC(from ring)=\(deviceMac.isEmpty ? "?" : deviceMac)")
        plain.set("sn", sn)
        plain.set("fwid", fwid)
        plain.set("deviceMac", deviceMac)
        return true
    }
}
