import XCTest
@testable import VoxLibreCore

/// Framing, crypto and telemetry: every expected value below comes from running the ORIGINAL
/// Java code (tools/RefVectors.java → Vectors.swift), not from the Swift implementation.
final class ProtocolTests: XCTestCase {
    private var identity: RingIdentity {
        return RingIdentity(bindKey: Ref.bindKey, fwid: Ref.fwid, sn: Ref.sn, mac: Ref.mac)
    }

    // MARK: framing

    func testHandshakeFramesMatchJava() {
        var e = FrameEncoder()
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x82, payload: [0x05])), Ref.frameProtoHex)
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x80, payload: [])), Ref.frameDeviceInfoHex)
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x81, payload: RingCrypto.userIdPayload(Ref.userId))), Ref.frameUserIdHex)
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x82, payload: [0x01])), Ref.frameRequestChallengeHex)
        let resp = RingCrypto.appResponse(nonce: Ref.nonce, identity: identity)
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x82, payload: resp)), Ref.frameAppResponseHex)
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x11, payload: [])), Ref.frameListHex)
    }

    func testSequenceWrapsLikeJava() {
        var e = FrameEncoder()
        for _ in 0..<65533 { _ = e.encode(op: 0x00, payload: []) }   // next seq = 0xFFFF
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x30, payload: [0x01])), Ref.frameWrapAHex)
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x25, payload: [])), Ref.frameWrapBHex)      // 0 is skipped → 1
        XCTAssertEqual(Bytes.hex(e.encode(op: 0x2a, payload: [0, 0])), Ref.frameWrapCHex)
    }

    func testFrameAccessors() {
        let resp = RingCrypto.appResponse(nonce: Ref.nonce, identity: identity)
        var e = FrameEncoder()
        let f = e.encode(op: 0x82, payload: resp)
        XCTAssertEqual(Frame.op(f), 0x82)
        XCTAssertEqual(Frame.data(f), resp)
        XCTAssertEqual(Ref.frameDataRoundTripOk, "yes")
        XCTAssertEqual(Frame.op([0xAA, 0x55, 0, 1]), -1)
        XCTAssertEqual(Frame.data([0xAA, 0x55, 0, 1, 0, 1, 0x80, 0]), [])
        // bogus length must clamp, never trap
        XCTAssertEqual(Frame.data([0xAA, 0x55, 0, 1, 0xFF, 0xFF, 0x80, 1, 2, 3]), [1, 2, 3])
        XCTAssertEqual(Frame.data([0xAA, 0x55, 0, 1, 0, 0, 0x80, 1, 2, 3]), [])
    }

    // MARK: reassembly

    func testAssemblerPassesWholeFramesThrough() {
        var a = FrameAssembler()
        let f = hexBytes(Ref.frameAppResponseHex)
        XCTAssertEqual(a.feed(f, maybeFragment: true), [f])
        XCTAssertEqual(a.feed([1, 2, 3], maybeFragment: false), [[1, 2, 3]])   // not AA55: untouched
        XCTAssertFalse(a.hasPartial)
    }

    func testAssemblerStitchesSplitFrame() {
        var a = FrameAssembler()
        let f = hexBytes(Ref.frameAppResponseHex)
        let first = Array(f[0..<40])
        let second = Array(f[40..<80])
        let third = Array(f[80...])
        XCTAssertEqual(a.feed(first, maybeFragment: true), [])
        XCTAssertTrue(a.hasPartial)
        XCTAssertEqual(a.feed(second, maybeFragment: true), [])
        XCTAssertEqual(a.feed(third, maybeFragment: false), [f])
        XCTAssertFalse(a.hasPartial)
    }

    func testAssemblerFlushesPartialOnNewHeaderAndTimeout() {
        var a = FrameAssembler()
        let f = hexBytes(Ref.frameAppResponseHex)
        let first = Array(f[0..<40])
        let next = hexBytes(Ref.frameListHex)
        XCTAssertEqual(a.feed(first, maybeFragment: true), [])
        XCTAssertEqual(a.feed(next, maybeFragment: false), [first, next])
        XCTAssertEqual(a.feed(first, maybeFragment: true), [])
        XCTAssertEqual(a.flush(), first)
        XCTAssertNil(a.flush())
    }

    // MARK: crypto

    func testHandshakeMathMatchesJava() {
        XCTAssertEqual(RingCrypto.keyHex(identity), Ref.kh)
        XCTAssertEqual(RingCrypto.content(identity, Ref.nonce), Ref.contentNonce)
        XCTAssertEqual(RingCrypto.hmacHex(key: Ref.kh, message: Ref.contentNonce), Ref.ringDauth)
        XCTAssertEqual(RingCrypto.hmacHex(key: Ref.kh, message: Ref.appName), Ref.inner)
        XCTAssertEqual(Bytes.hex(RingCrypto.appResponse(nonce: Ref.nonce, identity: identity)), Ref.appResponsePayloadHex)
        XCTAssertEqual(Bytes.hex(RingCrypto.userIdPayload(Ref.userId)), Ref.userIdPayloadHex)
    }

    func testChallengeParsingAndRingVerification() {
        let payload: [UInt8] = [0x01, 0x00] + Array((Ref.nonce + "@" + Ref.ringDauth).utf8)
        let c = RingCrypto.parseChallenge(payload)
        XCTAssertEqual(c, RingChallenge(nonce: Ref.nonce, ringAuth: Ref.ringDauth))
        XCTAssertTrue(RingCrypto.verifyRing(c!, identity: identity))
        var wrong = identity
        wrong.bindKey = "ffffffffffffffffffffffffffffffff"
        XCTAssertFalse(RingCrypto.verifyRing(c!, identity: wrong))
        // no '@': ringAuth is empty
        XCTAssertEqual(RingCrypto.parseChallenge([0x01, 0x00] + Array("abc".utf8)),
                       RingChallenge(nonce: "abc", ringAuth: ""))
        XCTAssertNil(RingCrypto.parseChallenge([0x03, 0x00]))
        XCTAssertNil(RingCrypto.parseChallenge([0x01]))
    }

    // MARK: device info / telemetry

    func testDeviceInfoParsing() {
        let config = RingConfig(plain: MemoryStore(), secret: MemoryStore())
        XCTAssertTrue(config.parseDeviceInfo(hexBytes(Ref.deviceInfoHex)))
        XCTAssertEqual("SN=\(config.sn) FWID=\(config.fwid)", Ref.deviceInfoParsed)
        // the ring reports its MAC byte-reversed
        XCTAssertEqual(config.deviceMac, Ref.mac)
        XCTAssertEqual(config.mac, Ref.mac)
        config.setMacOverride("11-22-33-44-55-66")
        XCTAssertEqual(config.mac, "11:22:33:44:55:66")
        XCTAssertFalse(config.parseDeviceInfo([]))
        XCTAssertFalse(config.parseDeviceInfo([9, 1, 2]))   // SN length beyond the frame
    }

    func testMacNormalization() {
        XCTAssertEqual(RingConfig.normalizeMac("aa-bb-cc-dd-ee-ff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(RingConfig.normalizeMac(" aabbccddeeff "), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(RingConfig.normalizeMac("AA:BB:CC:DD:EE:FF"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(RingConfig.normalizeMac("not a mac"), "NOT A MAC")
        XCTAssertEqual(RingConfig.normalizeMac(""), "")
    }

    func testStatusDecodingMatchesJava() {
        func render(_ s: RingStatus) -> String {
            return "hw=\(s.hwVer) fw=\(s.fwVer) battSt=\(s.battStatus) batt=\(s.battPct) hostRssi=\(s.hostRssi) volt=\(s.voltMv) model=\(s.model ?? "?")"
        }
        XCTAssertEqual(render(Telemetry.decodeStatus(hexBytes(Ref.f2Hex))!), Ref.f2Decoded)
        XCTAssertEqual(render(Telemetry.decodeStatus(hexBytes(Ref.f2ShortHex))!), Ref.f2ShortDecoded)
        XCTAssertNil(Telemetry.decodeStatus([0, 1, 2]))
    }

    func testStorageDecodingMatchesJava() {
        let s = Telemetry.decodeStorage(hexBytes(Ref.s14Hex))!
        XCTAssertEqual("free=\(s.free) tot=\(s.total)", Ref.s14Decoded)
        XCTAssertNil(Telemetry.decodeStorage([1, 2, 3]))
    }

    func testFaultDecoding() {
        let msg = Array("boom".utf8)
        let d: [UInt8] = [0x01, 0x02, 0x00, 0x00, UInt8(msg.count)] + msg
        let f = Telemetry.decodeFault(d)!
        XCTAssertEqual(f.code, 0x0102)
        XCTAssertEqual(f.message, "boom")
        XCTAssertEqual(Telemetry.decodeFault([0, 7, 0])!.message, "")
        XCTAssertNil(Telemetry.decodeFault([0, 1]))
    }

    // MARK: opus container / wav

    func testOpusPacketSplitting() {
        let d: [UInt8] = [0, 3, 1, 2, 3, 1, 2, 9, 9, 2, 5, 1]   // last packet claims 5 bytes, has 1
        XCTAssertEqual(OpusFraming.packets(from: d), [[1, 2, 3], [9, 9]])
        XCTAssertEqual(OpusFraming.durationMs(from: d), 120)
        XCTAssertEqual(OpusFraming.packets(from: []), [])
        XCTAssertEqual(OpusFraming.samplesPerPacket, 2880)
    }

    func testWavHeaderMatchesJava() {
        XCTAssertEqual(Bytes.hex(Wav.header(pcmByteCount: 11520)), Ref.wavHeader11520Hex)
        XCTAssertEqual(Bytes.hex(Wav.header(pcmByteCount: 0)), Ref.wavHeader0Hex)
        let w = Wav.make(pcm: [1, -1])
        XCTAssertEqual(w.count, 48)
        XCTAssertEqual(Array(w.suffix(4)), [0x01, 0x00, 0xFF, 0xFF])
    }
}
