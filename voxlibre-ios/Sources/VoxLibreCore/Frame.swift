import Foundation

/// Builds AA55 frames: `[AA][55][seqHi][seqLo][lenHi][lenLo][op][payload…][chk=00][0D][0A]`.
/// `len` counts `op + payload`. The checksum byte is always 0, exactly like the original.
struct FrameEncoder {
    private var seq: UInt16 = 1

    mutating func encode(op: UInt8, payload: [UInt8]) -> [UInt8] {
        seq = seq &+ 1
        if seq == 0 { seq = 1 }
        let ln = payload.count + 1
        var f = [UInt8]()
        f.reserveCapacity(10 + payload.count)
        f.append(0xAA)
        f.append(0x55)
        f.append(UInt8(seq >> 8))
        f.append(UInt8(seq & 0xFF))
        f.append(UInt8((ln >> 8) & 0xFF))
        f.append(UInt8(ln & 0xFF))
        f.append(op)
        f.append(contentsOf: payload)
        f.append(0x00)
        f.append(0x0D)
        f.append(0x0A)
        return f
    }
}

/// Reads the fields the original `frameOp` / `frameData` read.
enum Frame {
    /// Opcode, or -1 when the frame is too short to contain one.
    static func op(_ v: [UInt8]) -> Int {
        return v.count >= 7 ? Int(v[6]) : -1
    }

    /// Payload (`len - 1` bytes after the opcode). Like the original it needs >= 10 bytes.
    /// Unlike Java's `Arrays.copyOfRange` it never zero-pads or throws on a bogus length; it clamps.
    static func data(_ v: [UInt8]) -> [UInt8] {
        guard v.count >= 10 else { return [] }
        let len = (Int(v[4]) << 8) | Int(v[5])
        let end = min(7 + len - 1, v.count)
        guard end > 7 else { return [] }
        return Array(v[7..<end])
    }

    /// Total on-wire size declared by a frame header (header 6 + len + trailer 3).
    static func declaredTotal(_ v: [UInt8]) -> Int {
        return 9 + ((Int(v[4]) << 8) | Int(v[5]))
    }
}

/// iOS-specific safety net. Android asked for MTU 247; iOS negotiates its own (often smaller)
/// MTU and cannot be told otherwise, so a long frame may arrive split over several
/// notifications. This stitches such frames back together.
///
/// It is deliberately conservative so every input the Android code handled still behaves the
/// same: a chunk is only held back when it *looks* like the first piece of a split frame, i.e.
/// it starts with AA55, it filled the whole notification (`maybeFragment`) and it is shorter
/// than the length its header declares. Everything else passes through untouched.
struct FrameAssembler {
    private var buf: [UInt8] = []

    var hasPartial: Bool { return !buf.isEmpty }

    /// - Parameter maybeFragment: true when `chunk` used the full notification payload
    ///   (a sender only splits a frame when it ran out of room).
    mutating func feed(_ chunk: [UInt8], maybeFragment: Bool) -> [[UInt8]] {
        if buf.isEmpty {
            guard maybeFragment, chunk.count >= 6, chunk[0] == 0xAA, chunk[1] == 0x55,
                  chunk.count < Frame.declaredTotal(chunk) else {
                return [chunk]
            }
            buf = chunk
            return []
        }
        // A new frame header while a partial is pending: the partial is as complete as it will get.
        if chunk.count >= 2, chunk[0] == 0xAA, chunk[1] == 0x55 {
            let partial = buf
            buf = []
            return [partial] + feed(chunk, maybeFragment: maybeFragment)
        }
        buf.append(contentsOf: chunk)
        if buf.count >= Frame.declaredTotal(buf) || !maybeFragment {
            let whole = buf
            buf = []
            return [whole]
        }
        return []
    }

    /// Hands out whatever is pending (used by a timeout so a mis-detected fragment cannot stall).
    mutating func flush() -> [UInt8]? {
        guard !buf.isEmpty else { return nil }
        let partial = buf
        buf = []
        return partial
    }

    mutating func reset() {
        buf = []
    }
}
