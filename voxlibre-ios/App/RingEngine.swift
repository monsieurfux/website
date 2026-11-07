import Foundation
import SwiftUI

struct LogLine: Identifiable {
    let id: Int
    let text: String
    let unmapped: Bool
}

/// Log lines live in their own object so a busy protocol log does not re-render every screen.
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    private var nextID = 0

    func append(_ text: String, unmapped: Bool) {
        lines.append(LogLine(id: nextID, text: text, unmapped: unmapped))
        nextID += 1
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
    }

    func clear() {
        lines = []
    }

    var joined: String {
        return lines.map { $0.text }.joined(separator: "\n")
    }
}

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Facade over the ring modules for the UI (replaces Android's `RingEngine` + `RingViewModel`).
/// Wires `RingConfig`, `RingSession`, `RingLibrary`, `RingGestures`, `BLETransport` and
/// `OpusAudio` together and publishes their state for SwiftUI. Everything runs on the main queue.
final class RingEngine: ObservableObject, RingSink, LibraryOut, GestureSink, AudioSink {
    // MARK: published UI state
    @Published var statusText = "disconnected"
    @Published var connected = false
    @Published var model = ""
    @Published var fw = ""
    @Published var hw = ""
    @Published var sn = ""
    @Published var battPct = -1
    @Published var battVolt = 0
    @Published var battSt = 0
    @Published var rssiHost = 0
    @Published var storFree: Int64 = -1
    @Published var storTot: Int64 = 0
    @Published var eventText = ""
    @Published var gestureText = ""
    @Published var recordings: [Rec] = []
    @Published var toastItem: ToastItem?
    @Published var mediaToggle = false
    @Published var onlyUnmapped = false
    @Published var wordWrap = false
    @Published var configured = false
    @Published var ringName = ""
    @Published var bluetoothProblem: String?
    @Published var discovered: [DiscoveredRing] = []
    @Published var playingName: String?
    @Published var isPlaying = false

    let logStore = LogStore()

    // MARK: modules
    private let config: RingConfig
    private let library: RingLibrary
    private let gestures: RingGestures
    private let session: RingSession
    private let transport: BLETransport
    private let audio: OpusAudio
    private let timestamp: DateFormatter

    init() {
        let plain = UserDefaultsStore()
        let secret = KeychainStore()
        let scheduler = MainScheduler()
        let fileStore = LocalFileStore()
        let cfg = RingConfig(plain: plain, secret: secret)
        let gest = RingGestures(scheduler: scheduler)
        let lib = RingLibrary(store: plain, files: fileStore, scheduler: scheduler)
        let sess = RingSession(config: cfg, gestures: gest, library: lib)
        let tr = BLETransport()
        let au = OpusAudio(files: fileStore)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm:ss.SSS"

        config = cfg
        library = lib
        gestures = gest
        session = sess
        transport = tr
        audio = au
        timestamp = fmt

        // wiring (all stored properties are initialized, `self` is usable)
        cfg.logger = { [weak self] m in self?.log(m) }
        gest.sink = self
        lib.net = sess
        lib.out = self
        sess.sink = self
        sess.link = tr
        tr.session = sess
        tr.onLog = { [weak self] m in self?.log(m) }
        tr.onDiscovered = { [weak self] list in self?.discovered = list }
        tr.onBluetoothProblem = { [weak self] problem in self?.bluetoothProblem = problem }
        au.sink = self

        configured = cfg.isConfigured
        ringName = cfg.peripheralName
        refreshLibrary()
    }

    // MARK: - settings / ring selection

    var savedBindKey: String { return config.bindKey }
    var savedUserId: String { return config.userId }
    var savedMacOverride: String { return config.macOverride }
    var ringMacFromDevice: String { return config.deviceMac }
    var hasCredentials: Bool { return config.hasCredentials }

    func saveSettings(bindKey: String, userId: String, macOverride: String) {
        config.setBindKey(bindKey)
        config.setUserId(userId)
        config.setMacOverride(macOverride)
    }

    func startDiscovery() { transport.startDiscovery() }
    func stopDiscovery() { transport.stopDiscovery() }

    /// Remembers the chosen ring; with `connect` it also starts connecting right away.
    func selectRing(_ ring: DiscoveredRing, connect: Bool) {
        config.setPeripheral(id: ring.id.uuidString, name: ring.name)
        configured = true
        ringName = ring.name
        transport.stopDiscovery()
        if connect && statusText == "disconnected" { session.toggleConnect() }
    }

    // MARK: - actions

    func toggleConnect() { session.toggleConnect() }
    func refreshLibrary() { library.refreshLibrary() }
    func manualRefresh() { library.manualRefresh() }
    func download(_ name: String) { library.download(name) }
    func deleteRing(_ id: String) { library.deleteRing(id) }
    func deleteLocal(_ id: String) {
        if playingName == "amsg_" + id + "_mono.opus" { audio.stop() }
        library.deleteLocal(id)
    }
    var isDownloading: Bool { return library.downloading }

    func play(_ name: String) { audio.play(name: name) }
    func stopPlay() { audio.stop() }

    func setMedia(_ on: Bool) {
        mediaToggle = on
        gestures.setMediaToggle(on)
    }

    func showToast(_ text: String) {
        let item = ToastItem(text: text)
        toastItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toastItem == item { self?.toastItem = nil }
        }
    }

    // MARK: - RingSink
    func status(_ text: String) {
        statusText = text
        connected = session.isConnected
    }

    func device(model: String, fw: String, hw: String, sn: String) {
        self.model = model
        self.fw = fw
        self.hw = hw
        self.sn = sn
    }

    func telem(batt: Int, volt: Int, st: Int, rssi: Int, free: Int64, tot: Int64) {
        battPct = batt
        battVolt = volt
        battSt = st
        rssiHost = rssi
        storFree = free
        storTot = tot
    }

    // MARK: - shared outputs (RingSink + LibraryOut)
    func event(_ text: String) { eventText = text }
    func toast(_ text: String) { showToast(text) }
    func log(_ m: String) { logRaw(m, unmapped: false) }

    func logRaw(_ m: String, unmapped: Bool) {
        NSLog("VoxLibre: %@", m)
        logStore.append(timestamp.string(from: Date()) + "  " + m, unmapped: unmapped)
    }

    // MARK: - LibraryOut
    func libraryUpdated(_ items: [Rec]) { recordings = items }

    // MARK: - GestureSink
    func gesture(_ text: String) { gestureText = text }
    func mediaPlayPause() { audio.togglePlayback() }

    // MARK: - AudioSink
    func playbackChanged(playing: Bool, name: String?) {
        isPlaying = playing
        playingName = name
    }
}
