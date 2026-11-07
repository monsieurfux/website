import Foundation
import XCTest
@testable import VoxLibreCore

/// Virtual-time scheduler: nothing runs until `advance(by:)`.
final class ManualScheduler: Scheduler {
    private struct Item {
        let due: Int
        let order: Int
        let task: ScheduledTask
        let work: () -> Void
    }

    private var now = 0
    private var counter = 0
    private var items: [Item] = []

    func nowMs() -> Int { return now }

    @discardableResult
    func after(ms: Int, _ work: @escaping () -> Void) -> ScheduledTask {
        let task = ScheduledTask(onCancel: {})
        counter += 1
        items.append(Item(due: now + ms, order: counter, task: task, work: work))
        return task
    }

    /// Moves the clock forward, running every due, non-cancelled task in order.
    func advance(by ms: Int) {
        let target = now + ms
        while true {
            let due = items.filter { $0.due <= target && !$0.task.isCancelled }
                .sorted { ($0.due, $0.order) < ($1.due, $1.order) }
            guard let next = due.first else { break }
            items.removeAll { $0.order == next.order }
            now = max(now, next.due)
            next.work()
        }
        now = target
        items.removeAll { $0.task.isCancelled }
    }
}

final class FakeLink: RingLink {
    var connectedTo: String?
    var disconnectCalls = 0
    var authWrites: [[UInt8]] = []
    var ctrlWrites: [[UInt8]] = []
    var enableControlCalls = 0

    func connect(peripheralID: String) { connectedTo = peripheralID }
    func disconnect() { disconnectCalls += 1 }
    func writeAuth(_ frame: [UInt8]) { authWrites.append(frame) }
    func writeCtrl(_ frame: [UInt8]) { ctrlWrites.append(frame) }
    func enableControlChannels() { enableControlCalls += 1 }
}

final class FakeSink: RingSink, LibraryOut, GestureSink {
    var statuses: [String] = []
    var devices: [(model: String, fw: String, hw: String, sn: String)] = []
    var telems: [(batt: Int, volt: Int, st: Int, rssi: Int, free: Int64, tot: Int64)] = []
    var events: [String] = []
    var toasts: [String] = []
    var logs: [String] = []
    var gestureTexts: [String] = []
    var mediaToggles = 0
    var libraries: [[Rec]] = []

    func status(_ text: String) { statuses.append(text) }
    func device(model: String, fw: String, hw: String, sn: String) { devices.append((model, fw, hw, sn)) }
    func telem(batt: Int, volt: Int, st: Int, rssi: Int, free: Int64, tot: Int64) {
        telems.append((batt, volt, st, rssi, free, tot))
    }
    func event(_ text: String) { events.append(text) }
    func toast(_ text: String) { toasts.append(text) }
    func log(_ m: String) { logs.append(m) }
    func logRaw(_ m: String, unmapped: Bool) { logs.append(m + (unmapped ? " [unmapped]" : "")) }
    func gesture(_ text: String) { gestureTexts.append(text) }
    func mediaPlayPause() { mediaToggles += 1 }
    func libraryUpdated(_ items: [Rec]) { libraries.append(items) }
}

final class FakeFiles: FileStore {
    var data: [String: [UInt8]] = [:]

    func list(suffix: String) -> [(name: String, size: Int64)] {
        return data.keys.filter { $0.hasSuffix(suffix) }.sorted().map { (name: $0, size: Int64(data[$0]!.count)) }
    }
    func read(name: String) -> [UInt8]? { return data[name] }
    func write(name: String, data d: [UInt8]) throws { data[name] = d }
    func remove(name: String) { data.removeValue(forKey: name) }
}

final class FakeNet: LibraryNet {
    var isConnected = true
    var lists = 0
    var reads: [String] = []
    var deletes: [String] = []

    func sendList() { lists += 1 }
    func sendRead(_ name: String) { reads.append(name) }
    func sendDelete(_ name: String) { deletes.append(name) }
}

func hexBytes(_ s: String, file: StaticString = #file, line: UInt = #line) -> [UInt8] {
    guard let b = Bytes.fromHex(s) else {
        XCTFail("bad hex: \(s)", file: file, line: line)
        return []
    }
    return b
}

/// Builds a ring→app frame (same layout the app sends).
func ringFrame(op: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var enc = FrameEncoder()
    return enc.encode(op: op, payload: payload)
}
