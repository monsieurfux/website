import Foundation

/// The ring stores recordings as `[seq:u8][len:u8][opus packet]…`, 48 kHz mono, 60 ms per packet.
enum OpusFraming {
    static let sampleRate = 48000
    static let packetMs = 60
    static let samplesPerPacket = sampleRate * packetMs / 1000   // 2880

    /// Splits the container into raw Opus packets (the sequence byte is ignored, as in the original).
    /// Stops at the first truncated packet.
    static func packets(from d: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var off = 0
        while off + 2 <= d.count {
            let len = Int(d[off + 1])
            guard off + 2 + len <= d.count else { break }
            out.append(Array(d[(off + 2)..<(off + 2 + len)]))
            off += 2 + len
        }
        return out
    }

    /// Duration implied by the packet count (used when the ring's .json was never fetched).
    static func durationMs(from d: [UInt8]) -> Int {
        return packets(from: d).count * packetMs
    }
}

/// Minimal 16-bit PCM WAV writer (same 44-byte header as the original `writeWav`).
enum Wav {
    static func header(pcmByteCount: Int, sampleRate: Int = 48000, channels: Int = 1) -> [UInt8] {
        var h = [UInt8]()
        h.reserveCapacity(44)
        h.append(contentsOf: Array("RIFF".utf8))
        h.append(contentsOf: le32(36 + pcmByteCount))
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8))
        h.append(contentsOf: le32(16))
        h.append(contentsOf: le16(1))                       // PCM
        h.append(contentsOf: le16(channels))
        h.append(contentsOf: le32(sampleRate))
        h.append(contentsOf: le32(sampleRate * channels * 2))
        h.append(contentsOf: le16(channels * 2))
        h.append(contentsOf: le16(16))
        h.append(contentsOf: Array("data".utf8))
        h.append(contentsOf: le32(pcmByteCount))
        return h
    }

    static func make(pcm: [Int16], sampleRate: Int = 48000, channels: Int = 1) -> Data {
        var data = Data(header(pcmByteCount: pcm.count * 2, sampleRate: sampleRate, channels: channels))
        data.reserveCapacity(44 + pcm.count * 2)
        for s in pcm {
            let u = UInt16(bitPattern: s)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8(u >> 8))
        }
        return data
    }

    private static func le16(_ v: Int) -> [UInt8] {
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private static func le32(_ v: Int) -> [UInt8] {
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
