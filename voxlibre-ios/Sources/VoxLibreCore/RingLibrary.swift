import Foundation

/// A recording (on the ring and/or downloaded to the phone).
struct Rec: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeOpus: Int64
    let durationMs: Int?
    let onRing: Bool
    let savedLocal: Bool
}

/// Outbound BLE commands, served by `RingSession`.
protocol LibraryNet: AnyObject {
    var isConnected: Bool { get }
    func sendList()
    func sendRead(_ name: String)
    func sendDelete(_ name: String)
}

/// UI-facing outputs.
protocol LibraryOut: AnyObject {
    func log(_ m: String)
    func toast(_ m: String)
    func event(_ m: String)
    func libraryUpdated(_ items: [Rec])
}

/// The phone-side recordings folder.
protocol FileStore: AnyObject {
    /// Downloaded files whose name ends with `suffix`, with their size in bytes.
    func list(suffix: String) -> [(name: String, size: Int64)]
    func read(name: String) -> [UInt8]?
    func write(name: String, data: [UInt8]) throws
    /// Removes the file (and any derived cache entry of the same name).
    func remove(name: String)
}

/// Persisted per-recording state (lets the list survive offline).
struct IndexEntry: Codable, Equatable {
    var onRing: Bool = false
    var ringSize: Int64? = nil
    var dur: Int? = nil
}

/// Insertion-ordered name → size map (Java's `LinkedHashMap`).
struct OrderedFiles {
    private(set) var names: [String] = []
    private var sizes: [String: Int] = [:]

    var isEmpty: Bool { return names.isEmpty }

    mutating func put(_ name: String, _ size: Int) {
        if sizes[name] == nil { names.append(name) }
        sizes[name] = size
    }

    mutating func removeAll() {
        names = []
        sizes = [:]
    }

    mutating func putAll(_ other: OrderedFiles) {
        for n in other.names { put(n, other.sizes[n] ?? 0) }
    }

    func size(of name: String) -> Int? { return sizes[name] }
}

/// The recordings library (ported from `RingLibrary.java`): the on-ring file list, downloads and
/// the local, persisted index. Owns download orchestration (including the automatic .json duration
/// prefetch) and reconciles ring vs. phone state.
final class RingLibrary {
    weak var net: LibraryNet?
    weak var out: LibraryOut?

    private let store: KeyValueStore
    private let files: FileStore
    private let scheduler: Scheduler

    // ring state
    private(set) var ringFiles = OrderedFiles()
    private var collecting: OrderedFiles? = nil
    // durations parsed from .json, cached by id
    private var durById: [String: Int] = [:]
    // duration estimated from the .opus file when no .json was fetched (not persisted, like the WAV fallback)
    private var fallbackDurById: [String: Int] = [:]
    // automatic .json prefetch queue
    private var jsonQ: [String] = []
    private var autoJson = false
    // .json files already fetched on this connection (a file whose duration cannot be parsed
    // would otherwise be re-queued by every refresh, forever)
    private var jsonAttempted: Set<String> = []
    // in-flight download
    private var fileBuf: [UInt8] = []
    private var curFile: String? = nil
    private(set) var downloading = false

    private var recDebounce: ScheduledTask?

    init(store: KeyValueStore, files: FileStore, scheduler: Scheduler) {
        self.store = store
        self.files = files
        self.scheduler = scheduler
    }

    private var connected: Bool { return net?.isConnected ?? false }

    // MARK: - parsing helpers

    private static let recIdRegex = try! NSRegularExpression(pattern: "amsg_(\\d+)_mono")
    private static let anyFileRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9_]+_mono\\.(json|opus)")
    private static let opusFileRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9_]+_mono\\.opus")

    static func recId(_ n: String) -> String? {
        let ns = n as NSString
        guard let m = recIdRegex.firstMatch(in: n, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func firstMatch(_ re: NSRegularExpression, in s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    /// The .json is a stream of comma-separated objects (neither a single object nor an array):
    ///   {"record":[...]},{"duration":["<start>","<end>"]},{"record":[...]}
    /// Wrap in [] and take index 1 of the object that carries "duration" as milliseconds.
    static func parseDuration(_ bytes: [UInt8]) -> Int? {
        var body = bytes
        let junk: Set<UInt8> = [0x00, 0x2C, 0x20, 0x0A, 0x0D, 0x09]   // NUL , space \n \r \t
        while let last = body.last, junk.contains(last) {
            body.removeLast()   // stray NULs / trailing comma / whitespace after the last object
        }
        let text = "[" + Bytes.utf8(body) + "]"
        guard let data = text.data(using: .utf8),
              let events = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [Any] else { return nil }
        for e in events {
            guard let obj = e as? [String: Any], let dur = obj["duration"] as? [Any], dur.count >= 2 else { continue }
            if let s = dur[1] as? String, let ms = Int(s) { return ms }
            if let n = dur[1] as? NSNumber { return n.intValue }
        }
        return nil
    }

    // MARK: - persisted index

    private func loadIdx() -> [String: IndexEntry] {
        let json = store.get("lib")
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let idx = try? JSONDecoder().decode([String: IndexEntry].self, from: data) else { return [:] }
        return idx
    }

    private func saveIdx(_ idx: [String: IndexEntry]) {
        guard let data = try? JSONEncoder().encode(idx) else { return }
        store.set("lib", String(decoding: data, as: UTF8.self))
    }

    // MARK: - reconcile ring vs. phone

    func refreshLibrary() {
        var idx = loadIdx()
        if connected {
            // reconcile ring state: ringFiles = current list
            for k in Array(idx.keys) { idx[k]?.onRing = false }
            for name in ringFiles.names {
                guard let id = RingLibrary.recId(name) else { continue }
                var o = idx[id] ?? IndexEntry()
                o.onRing = true
                if name.hasSuffix(".opus") { o.ringSize = Int64(ringFiles.size(of: name) ?? 0) }
                if let dur = durById[id] { o.dur = dur }
                idx[id] = o
            }
            saveIdx(idx)
        }
        // local scan
        var localSz: [String: Int64] = [:]
        for f in files.list(suffix: "_mono.opus") {
            if let id = RingLibrary.recId(f.name) { localSz[id] = f.size }
        }
        // union (index + local), newest on top
        var idSet = Set(idx.keys)
        idSet.formUnion(localSz.keys)
        let ids = idSet
            .compactMap { id -> (Int64, String)? in Int64(id).map { ($0, id) } }
            .sorted { $0.0 > $1.0 }
            .map { $0.1 }

        var list: [Rec] = []
        for id in ids {
            let name = "amsg_" + id + "_mono.opus"
            let saved = localSz[id] != nil
            let o = idx[id]
            let onRing = o?.onRing ?? false
            if !saved && !onRing {
                // gone from ring and not on phone -> drop
                idx.removeValue(forKey: id)
                continue
            }
            let ringSize = o?.ringSize ?? -1
            var dur = durById[id]
            if dur == nil, let d = o?.dur {
                dur = d
                durById[id] = d   // cache so auto-json skips it
            }
            if dur == nil && saved {
                if let cached = fallbackDurById[id] {
                    dur = cached
                } else if let bytes = files.read(name: name) {
                    let est = OpusFraming.durationMs(from: bytes)
                    if est > 0 {
                        fallbackDurById[id] = est
                        dur = est
                    }
                }
            }
            let size = saved ? (localSz[id] ?? 0) : ringSize
            list.append(Rec(id: id, name: name, sizeOpus: size, durationMs: dur, onRing: onRing, savedLocal: saved))
        }
        saveIdx(idx)   // persist the cleanup of removed entries
        out?.libraryUpdated(list)
        scheduler.after(ms: 0) { [weak self] in self?.autoQueueMissing() }
    }

    func deleteLocal(_ id: String) {
        files.remove(name: "amsg_" + id + "_mono.opus")
        files.remove(name: "amsg_" + id + "_mono.wav")
        fallbackDurById.removeValue(forKey: id)
        out?.log("deleted local " + id)
        out?.toast("deleted from phone")
        refreshLibrary()
    }

    // MARK: - automatic duration prefetch

    private func autoQueueMissing() {
        for n in ringFiles.names where n.hasSuffix(".json") {
            if let id = RingLibrary.recId(n), durById[id] == nil, !jsonQ.contains(n), !jsonAttempted.contains(n) {
                jsonQ.append(n)
            }
        }
        pumpJson()
    }

    private func pumpJson() {
        guard !downloading, !jsonQ.isEmpty, connected else { return }
        autoJson = true
        let name = jsonQ.removeFirst()
        jsonAttempted.insert(name)
        reqFile(name)
    }

    private func parseDur(_ name: String, _ c: [UInt8]) {
        guard let id = RingLibrary.recId(name) else { return }
        if let ms = RingLibrary.parseDuration(c) {
            durById[id] = ms
            out?.log("duration \(id)=\(ms)ms")
        } else {
            out?.log("duration parse failed for " + id)
        }
    }

    // MARK: - downloads

    func download(_ name: String) {
        reqFile(name)
    }

    private func reqFile(_ name: String) {
        curFile = name
        downloading = true
        fileBuf = []
        out?.log((autoJson ? "auto-json " : "DOWNLOAD ") + name)
        if !autoJson { out?.toast("downloading " + name) }
        net?.sendRead(name)
    }

    private func saveFile() {
        if let name = curFile {
            if name.hasSuffix(".json") { parseDur(name, fileBuf) }
            if !autoJson {
                do {
                    try files.write(name: name, data: fileBuf)
                    out?.log("SAVED \(name) (\(fileBuf.count)B)")
                    out?.toast("saved: " + name)
                } catch {
                    out?.log("save error: \(error)")
                }
            }
        }
        downloading = false
    }

    // MARK: - ring list

    func requestList() {
        collecting = OrderedFiles()
        net?.sendList()
    }

    func manualRefresh() {
        guard connected else { out?.toast("connect first"); return }
        guard !downloading else { out?.toast("download in progress"); return }
        out?.log("manual list refresh")
        out?.toast("refreshing…")
        requestList()
    }

    func deleteRing(_ id: String) {
        guard connected else { out?.toast("connect first"); return }
        let names = ringFiles.names.filter { RingLibrary.recId($0) == id }
        guard !names.isEmpty else { out?.toast("not in the ring list"); return }
        for n in names {
            out?.log("DELETE on ring: 0x17 [02] " + n)
            net?.sendDelete(n)
        }
        out?.toast("deleting \(id)…")
        scheduler.after(ms: 900) { [weak self] in
            guard let self = self else { return }
            if self.connected && !self.downloading { self.requestList() }
        }
    }

    /// Fed by the protocol when a download-stream chunk arrives (DATA characteristic).
    func onFileData(_ chunk: [UInt8]) {
        if downloading { fileBuf.append(contentsOf: chunk) }
    }

    /// Recording-related control opcodes, dispatched by the protocol (RX already logged).
    func onCtrl(op: Int, _ d: [UInt8]) {
        if op == 0x11 {
            let asc = Bytes.latin1(d)
            if let m = RingLibrary.firstMatch(RingLibrary.anyFileRegex, in: asc) {
                let size = d.count >= 5 ? Bytes.u16(d, 3) : 0
                if collecting != nil {
                    collecting?.put(m, size)
                } else {
                    ringFiles.put(m, size)
                }
                recDebounce?.cancel()
                recDebounce = scheduler.after(ms: 500) { [weak self] in self?.listSettled() }
            }
        } else if op == 0x13 {
            let asc = Bytes.latin1(d)
            let f = RingLibrary.firstMatch(RingLibrary.opusFileRegex, in: asc) ?? "?"
            if f != "?" { ringFiles.put(f, 0) }
            out?.event("BUTTON → new recording: " + f)
            out?.log("BUTTON/recording: " + f)
            refreshLibrary()
            if !downloading { requestList() }
        } else if op == 0x17 && d.count >= 2 && d[0] == 0x02 {
            let nl = Int(d[1])
            let nm = d.count >= 2 + nl ? Bytes.latin1(d[2..<(2 + nl)]) : "?"
            out?.log("delete OK on ring: " + nm)
        } else if op == 0x17 && d.count >= 2 {
            let n = Bytes.u16(d, 0)
            var sb = "queue(\(n)):"
            var o = 2
            var i = 0
            while i < n && o + 5 <= d.count {
                let id = Bytes.u32(d, o)
                sb += " #\(id)(st\(d[o + 4]))"
                i += 1
                o += 6
            }
            out?.log(sb)
        } else if op == 0x12 && d.count >= 1 && d[0] == 0x02 && downloading {
            out?.log("transfer complete \(curFile ?? "?") (\(fileBuf.count)B)")
            let wasAuto = autoJson
            saveFile()
            autoJson = false
            if wasAuto {
                // auto-json: no per-item rebuild; refresh only when the queue drains
                if jsonQ.isEmpty { refreshLibrary() } else { pumpJson() }
            } else {
                refreshLibrary()
                if connected { requestList() }
            }
        }
    }

    /// 500 ms after the last list entry: the ring list is complete.
    private func listSettled() {
        if let c = collecting {
            ringFiles.removeAll()
            ringFiles.putAll(c)
            collecting = nil
        }
        refreshLibrary()
    }

    /// Reset transient download/prefetch state on disconnect.
    /// (The Android original left `downloading` set here, which wedged the library until the
    /// app was restarted whenever the link dropped mid-download.)
    func onDisconnected() {
        jsonQ.removeAll()
        jsonAttempted.removeAll()
        autoJson = false
        downloading = false
        fileBuf = []
        collecting = nil
        recDebounce?.cancel()
    }
}
