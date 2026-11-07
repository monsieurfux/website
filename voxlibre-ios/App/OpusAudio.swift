import Foundation
import AVFoundation

/// Decodes the ring's raw Opus packets with Core Audio's built-in Opus codec (the iOS counterpart
/// of the Android `MediaCodec` "audio/opus" decoder – no third-party library involved).
enum OpusDecoder {
    enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case convert(String)

        var description: String {
            switch self {
            case .unsupported(let s): return "unsupported: " + s
            case .convert(let s): return "convert: " + s
            }
        }
    }

    /// 48 kHz mono 16-bit PCM. Packets are fed one at a time (60 ms each = 2880 frames), the
    /// pattern Core Audio documents for streaming decode.
    static func decode(packets: [[UInt8]]) throws -> [Int16] {
        let rate = Double(OpusFraming.sampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(OpusFraming.samplesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw Failure.unsupported("Opus input format")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                            channels: 1, interleaved: true) else {
            throw Failure.unsupported("PCM output format")
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw Failure.unsupported("Opus → PCM converter")
        }
        // 120 ms is the longest possible Opus packet; leave room for it.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(OpusFraming.samplesPerPacket * 2)) else {
            throw Failure.unsupported("PCM buffer")
        }

        var out = [Int16]()
        out.reserveCapacity(packets.count * OpusFraming.samplesPerPacket)

        for packet in packets {
            if packet.isEmpty {
                // zero-length packet = a lost/skipped frame: keep the timeline with silence
                out.append(contentsOf: [Int16](repeating: 0, count: OpusFraming.samplesPerPacket))
                continue
            }
            let comp = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: packet.count)
            packet.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    comp.data.copyMemory(from: base, byteCount: packet.count)
                }
            }
            comp.packetCount = 1
            comp.byteLength = UInt32(packet.count)
            if let descs = comp.packetDescriptions {
                descs[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                        mDataByteSize: UInt32(packet.count))
            }

            var provided = false
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
                if provided {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                inputStatus.pointee = .haveData
                return comp
            }
            if status == .error {
                throw Failure.convert(error?.localizedDescription ?? "unknown error")
            }
            let n = Int(pcm.frameLength)
            if n > 0, let channel = pcm.int16ChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: n))
            }
        }
        return out
    }
}

protocol AudioSink: AnyObject {
    func log(_ m: String)
    func toast(_ m: String)
    func playbackChanged(playing: Bool, name: String?)
}

/// Plays the ring's raw-Opus recordings: decode (.opus → PCM) → WAV cache → AVAudioPlayer.
/// Self-contained; talks back only through `AudioSink`.
final class OpusAudio: NSObject, AVAudioPlayerDelegate {
    weak var sink: AudioSink?
    private let files: LocalFileStore
    private var player: AVAudioPlayer?
    private var currentName: String?
    private var decoding = Set<String>()

    init(files: LocalFileStore) {
        self.files = files
        super.init()
    }

    /// Decodes (off the main thread) if needed, then plays. `name` is the .opus file in Documents.
    func play(name: String) {
        let opusURL = files.url(for: name)
        guard FileManager.default.fileExists(atPath: opusURL.path) else {
            sink?.toast("download first")
            return
        }
        let wavName = name.replacingOccurrences(of: ".opus", with: ".wav")
        let wavURL = files.cacheURL(for: wavName)
        if FileManager.default.fileExists(atPath: wavURL.path) {
            playWav(wavURL, name: name)
            return
        }
        guard !decoding.contains(name) else { return }
        decoding.insert(name)
        sink?.toast("decoding…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try Data(contentsOf: opusURL)
                let packets = OpusFraming.packets(from: [UInt8](data))
                let pcm = try OpusDecoder.decode(packets: packets)
                try Wav.make(pcm: pcm).write(to: wavURL, options: .atomic)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.decoding.remove(name)
                    let secs = String(format: "%.2f", Double(pcm.count) / Double(OpusFraming.sampleRate))
                    self.sink?.log("decoded \(name) (\(pcm.count * 2)B PCM / \(secs)s, \(packets.count) packets)")
                    self.playWav(wavURL, name: name)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.decoding.remove(name)
                    self.sink?.log("decode failed: \(error)")
                    self.sink?.toast("decode failed")
                }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        currentName = nil
        sink?.playbackChanged(playing: false, name: nil)
    }

    /// Ring single click: pause/resume the recording that is loaded.
    func togglePlayback() {
        guard let p = player else {
            sink?.log("play/pause: nothing is loaded")
            return
        }
        if p.isPlaying { p.pause() } else { p.play() }
        sink?.playbackChanged(playing: p.isPlaying, name: currentName)
    }

    private func playWav(_ url: URL, name: String) {
        do {
            stop()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            guard p.prepareToPlay(), p.play() else {
                sink?.log("play failed: player refused to start")
                sink?.toast("not playable")
                return
            }
            player = p
            currentName = name
            sink?.log("playing \(url.lastPathComponent)")
            sink?.toast("playing…")
            sink?.playbackChanged(playing: true, name: name)
        } catch {
            sink?.log("play failed: \(error)")
            sink?.toast("not playable")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        sink?.log("play end")
        self.player = nil
        currentName = nil
        sink?.playbackChanged(playing: false, name: nil)
    }
}
