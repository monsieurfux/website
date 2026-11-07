import Foundation

/// Decoded `0xf2` status frame.
struct RingStatus: Equatable {
    var hwVer: String
    var fwVer: String
    var battStatus: Int
    var battPct: Int
    var hostRssi: Int      // positive magnitude, shown as -N dBm
    var voltMv: Int
    var model: String?     // only present on longer frames
}

/// Pure decoders for the telemetry opcodes (ported from `RingProtocol.handleCtrl`).
enum Telemetry {
    /// 0xf2 – needs >= 12 bytes.
    static func decodeStatus(_ d: [UInt8]) -> RingStatus? {
        guard d.count >= 12 else { return nil }
        let hw = "\((d[1] >> 4) & 15).\(d[1] & 15).\(d[2])"
        let fw = "\((d[3] >> 4) & 15).\(d[3] & 15)." + String(format: "%02d", Int(d[4]))
        let battStatus = Int(d[5])
        let batt = Int(d[6])
        let hostRssi = 256 - Int(d[9])
        let volt = (Int(d[10]) << 8) | Int(d[11])
        var model: String? = nil
        if d.count > 14 {
            let ml = Int(d[14])
            if ml > 0 && d.count >= 15 + ml {
                model = Bytes.latin1(d[15..<(15 + ml)])
            }
        }
        return RingStatus(hwVer: hw, fwVer: fw, battStatus: battStatus, battPct: batt,
                          hostRssi: hostRssi, voltMv: volt, model: model)
    }

    /// 0x14 – storage: free = u32 at 0, total = u32 at 8. Needs >= 12 bytes.
    static func decodeStorage(_ d: [UInt8]) -> (free: Int64, total: Int64)? {
        guard d.count >= 12 else { return nil }
        return (Bytes.u32(d, 0), Bytes.u32(d, 8))
    }

    /// 0x18 – device fault: code = u16 at 0, optional message (u16 length at 3, text at 5).
    static func decodeFault(_ d: [UInt8]) -> (code: Int, message: String)? {
        guard d.count >= 3 else { return nil }
        let code = (Int(d[0]) << 8) | Int(d[1])
        var msg = ""
        if d.count > 5 {
            let ln = (Int(d[3]) << 8) | Int(d[4])
            if ln > 0 && d.count >= 5 + ln {
                msg = Bytes.utf8(d[5..<(5 + ln)])
            }
        }
        return (code, msg)
    }
}
