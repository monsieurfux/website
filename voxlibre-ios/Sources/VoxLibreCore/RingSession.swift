import Foundation

/// The GATT/transport side, implemented by `BLETransport` (CoreBluetooth) in the app and by a
/// fake in the tests. Frames passed in are already encoded; frames coming out are raw.
protocol RingLink: AnyObject {
    func connect(peripheralID: String)
    func disconnect()
    func writeAuth(_ frame: [UInt8])
    func writeCtrl(_ frame: [UInt8])
    /// Subscribe CTRL-notify (+ DATA when present), then call `RingSession.onControlReady()`.
    func enableControlChannels()
}

/// Device-status + UI outputs.
protocol RingSink: AnyObject {
    func status(_ text: String)
    func device(model: String, fw: String, hw: String, sn: String)
    func telem(batt: Int, volt: Int, st: Int, rssi: Int, free: Int64, tot: Int64)
    func event(_ text: String)
    func toast(_ text: String)
    func log(_ m: String)
    func logRaw(_ m: String, unmapped: Bool)
}

/// The Timon/URING wire protocol: connection lifecycle, AA55 framing, the nested HMAC auth
/// handshake and telemetry/device-status decoding (ported from `RingProtocol.java`).
///
/// Recording-related control opcodes are handed to `RingLibrary`; button input to
/// `RingGestures`; device/telemetry/status and logs go up through `RingSink`. Also serves the
/// library's outbound BLE commands (list/read/delete).
final class RingSession: LibraryNet {
    /// Opcodes the app understands; anything else is flagged "unmapped" in the log.
    static let knownCtrl: Set<Int> = [
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x25, 0x26, 0x2a, 0x2d, 0x30, 0xf0, 0xf2, 0xfa,
    ]

    weak var sink: RingSink?
    weak var link: RingLink?

    private let config: RingConfig
    private let gestures: RingGestures
    private let library: RingLibrary

    private var encoder = FrameEncoder()
    private var step = 0
    private(set) var isConnected = false   // authenticated
    private(set) var isActive = false      // connection initiated (connecting or up)

    // device/telemetry state (decoded from 0xf2 / 0x14)
    private var model = "?"
    private var fwVer = "?"
    private var hwVer = "?"
    private var battPct = -1
    private var battVolt = 0
    private var battSt = 0
    private var rssiHost = 0
    private var storFree: Int64 = -1
    private var storTot: Int64 = 0

    init(config: RingConfig, gestures: RingGestures, library: RingLibrary) {
        self.config = config
        self.gestures = gestures
        self.library = library
    }

    // MARK: - connection

    func toggleConnect() {
        if !isActive {
            guard config.isConfigured else {
                sink?.toast("select a ring first")
                sink?.status("disconnected")
                return
            }
            guard config.hasCredentials else {
                sink?.toast("enter BIND KEY and USER ID in Settings")
                sink?.status("disconnected")
                return
            }
            isActive = true
            sink?.status("connecting…")
            sink?.log("=== connecting \(config.peripheralName) (\(config.peripheralID)) ===")
            link?.connect(peripheralID: config.peripheralID)
        } else {
            sink?.log("disconnecting")
            link?.disconnect()
        }
    }

    // MARK: - writes

    private func wAuth(_ op: UInt8, _ d: [UInt8], _ lb: String) {
        sink?.log("TX [auth] op=0x\(String(op, radix: 16)) \(lb) \(Bytes.hex(d))")
        link?.writeAuth(encoder.encode(op: op, payload: d))
    }

    private func wCtrl(_ op: UInt8, _ d: [UInt8], _ lb: String) {
        sink?.log("TX [ctrl] op=0x\(String(op, radix: 16)) \(lb)")
        link?.writeCtrl(encoder.encode(op: op, payload: d))
    }

    private func startTelemetry() {
        wCtrl(0x30, [0x01], "init")
        wCtrl(0x25, [], "status")
        library.requestList()
        wCtrl(0x2a, [0, 0], "telemetry")
    }

    // MARK: - LibraryNet (outbound file commands)

    func sendList() {
        wCtrl(0x11, [], "list")
    }

    func sendRead(_ name: String) {
        let nm = Array(name.utf8)
        var d: [UInt8] = [1, UInt8(truncatingIfNeeded: nm.count)]
        d.append(contentsOf: nm)
        d.append(contentsOf: [0, 0, 0, 0, 0])
        wCtrl(0x12, d, "read " + name)
    }

    func sendDelete(_ name: String) {
        let nm = Array(name.utf8)
        var p: [UInt8] = [0x02, UInt8(truncatingIfNeeded: nm.count)]
        p.append(contentsOf: nm)
        wCtrl(0x17, p, "delete " + name)
    }

    private func refreshInfo() {
        sink?.device(model: has(model) ? model : "", fw: has(fwVer) ? fwVer : "",
                     hw: has(hwVer) ? hwVer : "", sn: config.sn)
    }

    private func refreshTelem() {
        sink?.telem(batt: battPct, volt: battVolt, st: battSt, rssi: rssiHost, free: storFree, tot: storTot)
    }

    private func has(_ s: String) -> Bool {
        return !s.isEmpty && s != "?"
    }

    // MARK: - transport events

    func onConnected() {
        sink?.status("connected, negotiating…")
    }

    /// AUTH notifications enabled: begin the handshake.
    func onAuthReady() {
        step = 0
        wAuth(0x82, [0x05], "proto")
    }

    func onAuthFrame(_ v: [UInt8]) {
        handleAuth(op: Frame.op(v), data: Frame.data(v))
    }

    func onCtrlFrame(_ v: [UInt8]) {
        handleCtrl(op: Frame.op(v), d: Frame.data(v))
    }

    /// Download stream (DATA characteristic).
    func onData(_ v: [UInt8]) {
        library.onFileData(v)
    }

    /// CTRL+DATA notifications enabled: telemetry can start.
    func onControlReady() {
        sink?.log("ready: telemetry+list")
        startTelemetry()
    }

    func onDisconnected() {
        isConnected = false
        isActive = false
        sink?.status("disconnected")
        gestures.reset()
        library.onDisconnected()
        library.refreshLibrary()
    }

    // MARK: - auth

    private func handleAuth(op: Int, data: [UInt8]) {
        sink?.log("RX [auth] op=0x\(String(op, radix: 16)) \(Bytes.hex(data))")
        if op == 0x80 && data.count > 10 {
            config.parseDeviceInfo(data)
            refreshInfo()
        }
        if op == 0x82, let ch = RingCrypto.parseChallenge(data) {
            let id = config.identity
            if id.mac.isEmpty {
                sink?.log("WARNING: ring MAC unknown (not in 0x80 frame, no override set) – auth will fail")
            }
            let ok = RingCrypto.verifyRing(ch, identity: id)
            sink?.log("challenge nonce=\(ch.nonce) verifyRing=\(ok)")
            wAuth(0x82, RingCrypto.appResponse(nonce: ch.nonce, identity: id), "app response")
            step = 99
            return
        }
        if step == 99 && op == 0x82 && data.count >= 1 && data[0] == 0x03 {
            sink?.log("APP-AUTH ACCEPTED")
            isConnected = true
            sink?.status("authenticated")
            refreshInfo()
            refreshTelem()
            library.refreshLibrary()
            link?.enableControlChannels()
            return
        }
        if step == 0 {
            step = 1
            wAuth(0x80, [], "device info")
        } else if step == 1 {
            step = 2
            wAuth(0x81, RingCrypto.userIdPayload(config.userId), "userId")
        } else if step == 2 {
            step = 3
            wAuth(0x82, [0x01], "request challenge")
        } else if step == 99 {
            sink?.log("auth: unexpected reply after app response (not 0x82/03)")
        }
    }

    // MARK: - control channel

    private func handleCtrl(op: Int, d: [UInt8]) {
        if op == 0x26 && d.count >= 1 {
            gestures.feed26(Int(d[0]))
            return
        }
        sink?.logRaw("RX [ctrl] op=0x\(String(op, radix: 16)) \(Bytes.hex(d))",
                     unmapped: !RingSession.knownCtrl.contains(op))
        if op == 0x14, let s = Telemetry.decodeStorage(d) {
            storFree = s.free
            storTot = s.total
            refreshTelem()
        } else if op == 0xfa {
            let t: Int64 = d.count >= 4 ? Bytes.u32(d, 0) : 0
            var line = "ring RTC = \(t)"
            if t > 1_000_000_000 { line += " (\(Date(timeIntervalSince1970: TimeInterval(t))))" }
            sink?.log(line)
        } else if op == 0x2a {
            // metrics; battery comes from 0xf2
        } else if op == 0xf2, let s = Telemetry.decodeStatus(d) {
            hwVer = s.hwVer
            fwVer = s.fwVer
            if let m = s.model { model = m }
            battPct = s.battPct
            battVolt = s.voltMv
            battSt = s.battStatus
            rssiHost = s.hostRssi
            refreshInfo()
            refreshTelem()
        } else if op == 0xf0 {
            let single = d.count >= 1 && d[0] == 0x01
            sink?.event((single ? "Single click" : "Gesture 0xf0") + ": " + Bytes.hex(d))
            if single { gestures.singleClick() }
        } else if op == 0x15 && d.count >= 2 {
            let code = Int(d[0])
            let pressed = d[1] != 0
            sink?.log("BUTTON(0x15) code=\(code) pressed=\(pressed)")
            if code == 0x01 && pressed { gestures.singleClick() }
        } else if op == 0x16 {
            sink?.log("heartbeat(0x16)")
        } else if op == 0x18, let f = Telemetry.decodeFault(d) {
            sink?.event("FAULT(0x18) code=\(f.code)" + (f.message.isEmpty ? "" : " " + f.message))
            sink?.log("deviceFault code=\(f.code) \(f.message)")
        } else if op == 0x11 || op == 0x13 || op == 0x17 || op == 0x12 {
            library.onCtrl(op: op, d)   // recordings list / new recording / delete ack / transfer complete
        }
    }
}
