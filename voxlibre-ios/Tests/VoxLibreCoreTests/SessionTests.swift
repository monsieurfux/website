import XCTest
@testable import VoxLibreCore

/// Everything strongly held for one test (the components only keep weak references to each other).
final class Rig {
    let plain = MemoryStore()
    let secret = MemoryStore()
    let sched = ManualScheduler()
    let files = FakeFiles()
    let sink = FakeSink()
    let link = FakeLink()
    let config: RingConfig
    let gestures: RingGestures
    let library: RingLibrary
    let session: RingSession

    init(credentials: Bool = true) {
        config = RingConfig(plain: plain, secret: secret)
        config.setPeripheral(id: "11111111-2222-3333-4444-555555555555", name: "Test Ring")
        if credentials {
            config.setBindKey(Ref.bindKey)
            config.setUserId(Ref.userId)
        }
        gestures = RingGestures(scheduler: sched)
        library = RingLibrary(store: plain, files: files, scheduler: sched)
        session = RingSession(config: config, gestures: gestures, library: library)
        session.sink = sink
        session.link = link
        library.net = session
        library.out = sink
        gestures.sink = sink
    }

    /// Runs the whole handshake against a simulated ring and returns once authenticated.
    func authenticate() {
        session.toggleConnect()
        session.onConnected()
        session.onAuthReady()
        session.onAuthFrame(ringFrame(op: 0x82, [0x05, 0x00]))
        session.onAuthFrame(ringFrame(op: 0x80, hexBytes(Ref.deviceInfoHex)))
        session.onAuthFrame(ringFrame(op: 0x81, [0x03]))
        let challenge: [UInt8] = [0x01, 0x00] + Array((Ref.nonce + "@" + Ref.ringDauth).utf8)
        session.onAuthFrame(ringFrame(op: 0x82, challenge))
        session.onAuthFrame(ringFrame(op: 0x82, [0x03]))
    }
}

final class SessionTests: XCTestCase {
    func testHandshakeProducesJavaIdenticalFrames() {
        let r = Rig()
        r.session.toggleConnect()
        XCTAssertEqual(r.link.connectedTo, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(r.sink.statuses.last, "connecting…")

        r.session.onConnected()
        r.session.onAuthReady()
        XCTAssertEqual(r.link.authWrites.map { Bytes.hex($0) }, [Ref.frameProtoHex])

        r.session.onAuthFrame(ringFrame(op: 0x82, [0x05, 0x00]))                 // ring acks the protocol request
        r.session.onAuthFrame(ringFrame(op: 0x80, hexBytes(Ref.deviceInfoHex)))   // ring sends SN / MAC / FWID
        r.session.onAuthFrame(ringFrame(op: 0x81, [0x03]))                       // ring acks the user id
        let challenge: [UInt8] = [0x01, 0x00] + Array((Ref.nonce + "@" + Ref.ringDauth).utf8)
        r.session.onAuthFrame(ringFrame(op: 0x82, challenge))

        XCTAssertEqual(r.link.authWrites.map { Bytes.hex($0) }, [
            Ref.frameProtoHex,
            Ref.frameDeviceInfoHex,
            Ref.frameUserIdHex,
            Ref.frameRequestChallengeHex,
            Ref.frameAppResponseHex,
        ])
        // the MAC derived from the ring's 0x80 frame reproduces the ring's own challenge proof
        XCTAssertTrue(r.sink.logs.contains("challenge nonce=\(Ref.nonce) verifyRing=true"))
        XCTAssertFalse(r.session.isConnected)

        r.session.onAuthFrame(ringFrame(op: 0x82, [0x03]))
        XCTAssertTrue(r.session.isConnected)
        XCTAssertEqual(r.link.enableControlCalls, 1)
        XCTAssertEqual(r.sink.statuses.last, "authenticated")
    }

    func testControlReadyStartsTelemetryAndListing() {
        let r = Rig()
        r.authenticate()
        r.session.onControlReady()
        XCTAssertEqual(r.link.ctrlWrites.map { Frame.op($0) }, [0x30, 0x25, 0x11, 0x2a])
        XCTAssertEqual(Frame.data(r.link.ctrlWrites[0]), [0x01])
        XCTAssertEqual(Frame.data(r.link.ctrlWrites[3]), [0, 0])
    }

    func testReadAndDeletePayloadsMatchJava() {
        let r = Rig()
        r.authenticate()
        r.session.sendRead("amsg_1700000000_mono.opus")
        r.session.sendDelete("amsg_1700000000_mono.json")
        XCTAssertEqual(r.link.ctrlWrites.map { Frame.op($0) }, [0x12, 0x17])
        XCTAssertEqual(Frame.data(r.link.ctrlWrites[0]), Frame.data(hexBytes(Ref.frameReadHex)))
        XCTAssertEqual(Frame.data(r.link.ctrlWrites[1]), Frame.data(hexBytes(Ref.frameDeleteHex)))
    }

    func testTelemetryFlowsToSink() {
        let r = Rig()
        r.authenticate()
        r.session.onCtrlFrame(ringFrame(op: 0xf2, hexBytes(Ref.f2Hex)))
        let dev = r.sink.devices.last!
        XCTAssertEqual(dev.model, "Timon")
        XCTAssertEqual(dev.fw, "1.2.05")
        XCTAssertEqual(dev.hw, "2.3.7")
        XCTAssertEqual(dev.sn, "SN0001")
        let t = r.sink.telems.last!
        XCTAssertEqual(t.batt, 87)
        XCTAssertEqual(t.volt, 4000)
        XCTAssertEqual(t.st, 1)
        XCTAssertEqual(t.rssi, 62)

        r.session.onCtrlFrame(ringFrame(op: 0x14, hexBytes(Ref.s14Hex)))
        XCTAssertEqual(r.sink.telems.last!.free, 2097152)
        XCTAssertEqual(r.sink.telems.last!.tot, 4194304)
    }

    func testUnknownOpcodeIsFlaggedUnmapped() {
        let r = Rig()
        r.authenticate()
        r.session.onCtrlFrame(ringFrame(op: 0x7e, [0xAB]))
        XCTAssertTrue(r.sink.logs.contains("RX [ctrl] op=0x7e ab [unmapped]"))
        r.session.onCtrlFrame(ringFrame(op: 0x16, []))
        XCTAssertTrue(r.sink.logs.contains("heartbeat(0x16)"))
    }

    func testButtonEventsReachGestures() {
        let r = Rig()
        r.authenticate()
        r.gestures.setMediaToggle(true)
        r.session.onCtrlFrame(ringFrame(op: 0xf0, [0x01]))
        XCTAssertEqual(r.sink.mediaToggles, 1)
        XCTAssertTrue(r.sink.events.last!.hasPrefix("Single click: "))
        r.sched.advance(by: 1000)
        r.session.onCtrlFrame(ringFrame(op: 0x15, [0x01, 0x01]))   // code 1, pressed
        XCTAssertEqual(r.sink.mediaToggles, 2)
        r.session.onCtrlFrame(ringFrame(op: 0x26, [0x05]))
        XCTAssertEqual(r.sink.gestureTexts.last, "button: PRESSED…")
    }

    func testFaultEvent() {
        let r = Rig()
        r.authenticate()
        let msg = Array("oops".utf8)
        r.session.onCtrlFrame(ringFrame(op: 0x18, [0x00, 0x2a, 0x00, 0x00, UInt8(msg.count)] + msg))
        XCTAssertEqual(r.sink.events.last, "FAULT(0x18) code=42 oops")
    }

    func testDisconnectResetsState() {
        let r = Rig()
        r.authenticate()
        r.session.onDisconnected()
        XCTAssertFalse(r.session.isConnected)
        XCTAssertFalse(r.session.isActive)
        XCTAssertEqual(r.sink.statuses.last, "disconnected")
        // can connect again
        r.session.toggleConnect()
        XCTAssertEqual(r.sink.statuses.last, "connecting…")
    }

    func testConnectNeedsRingAndCredentials() {
        let noCreds = Rig(credentials: false)
        noCreds.session.toggleConnect()
        XCTAssertEqual(noCreds.sink.toasts.last, "enter BIND KEY and USER ID in Settings")
        XCTAssertNil(noCreds.link.connectedTo)

        let noRing = RingConfig(plain: MemoryStore(), secret: MemoryStore())
        let sched = ManualScheduler()
        let lib = RingLibrary(store: MemoryStore(), files: FakeFiles(), scheduler: sched)
        let s = RingSession(config: noRing, gestures: RingGestures(scheduler: sched), library: lib)
        let sink = FakeSink()
        s.sink = sink
        s.toggleConnect()
        XCTAssertEqual(sink.toasts.last, "select a ring first")
    }

    func testToggleWhileActiveDisconnects() {
        let r = Rig()
        r.session.toggleConnect()
        r.session.toggleConnect()
        XCTAssertEqual(r.link.disconnectCalls, 1)
    }
}
