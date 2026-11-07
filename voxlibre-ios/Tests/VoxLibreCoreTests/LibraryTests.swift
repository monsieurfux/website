import XCTest
@testable import VoxLibreCore

final class LibraryTests: XCTestCase {
    private final class LibRig {
        let store: MemoryStore
        let files: FakeFiles
        let sched: ManualScheduler
        let net = FakeNet()
        let out = FakeSink()
        let lib: RingLibrary

        init(store sharedStore: MemoryStore? = nil) {
            let st = sharedStore ?? MemoryStore()
            let f = FakeFiles()
            let s = ManualScheduler()
            store = st
            files = f
            sched = s
            lib = RingLibrary(store: st, files: f, scheduler: s)
            lib.net = net
            lib.out = out
        }

        /// 0x11 list entry: [?][?][?][sizeHi][sizeLo] + ascii name
        func listEntry(_ name: String, size: Int) {
            let d: [UInt8] = [0, 0, 0, UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)] + Array(name.utf8)
            lib.onCtrl(op: 0x11, d)
        }
    }

    private let durationJSON = Array(#"{"record":["a"]},{"duration":["0","12345"]},{"record":["b"]}"#.utf8)

    func testRecId() {
        XCTAssertEqual(RingLibrary.recId("amsg_1700000100_mono.opus"), "1700000100")
        XCTAssertEqual(RingLibrary.recId("amsg_5_mono.json"), "5")
        XCTAssertNil(RingLibrary.recId("something_else.opus"))
    }

    func testParseDuration() {
        XCTAssertEqual(RingLibrary.parseDuration(durationJSON), 12345)
        XCTAssertEqual(RingLibrary.parseDuration(Array(#"{"duration":[0,987]}"#.utf8)), 987)
        // trailing comma / NUL padding (org.json tolerated this)
        XCTAssertEqual(RingLibrary.parseDuration(Array(#"{"duration":["0","77"]},"#.utf8) + [0, 0]), 77)
        XCTAssertNil(RingLibrary.parseDuration(Array(#"{"record":[]}"#.utf8)))
        XCTAssertNil(RingLibrary.parseDuration(Array("not json".utf8)))
        XCTAssertNil(RingLibrary.parseDuration([]))
    }

    func testListBuildsSortedRecordingsAndPrefetchesDurations() {
        let r = LibRig()
        r.lib.requestList()
        XCTAssertEqual(r.net.lists, 1)
        r.listEntry("amsg_1700000050_mono.opus", size: 500)
        r.listEntry("amsg_1700000100_mono.json", size: 40)
        r.listEntry("amsg_1700000100_mono.opus", size: 1024)
        XCTAssertTrue(r.out.libraries.isEmpty)       // nothing until the list settles (500 ms debounce)

        r.sched.advance(by: 500)
        let recs = r.out.libraries.last!
        XCTAssertEqual(recs.map { $0.id }, ["1700000100", "1700000050"])   // newest first
        XCTAssertEqual(recs[0].sizeOpus, 1024)
        XCTAssertEqual(recs[1].sizeOpus, 500)
        XCTAssertTrue(recs.allSatisfy { $0.onRing && !$0.savedLocal })
        XCTAssertNil(recs[0].durationMs)

        // the .json for the newest recording is fetched automatically
        XCTAssertEqual(r.net.reads, ["amsg_1700000100_mono.json"])
        XCTAssertTrue(r.lib.downloading)
        r.lib.onFileData(Array(durationJSON[0..<10]))
        r.lib.onFileData(Array(durationJSON[10...]))
        r.lib.onCtrl(op: 0x12, [0x02])               // transfer complete
        XCTAssertFalse(r.lib.downloading)
        XCTAssertTrue(r.files.data.isEmpty)           // auto-json is not kept on the phone
        XCTAssertEqual(r.out.libraries.last!.first!.durationMs, 12345)
        XCTAssertEqual(r.net.reads.count, 1)          // queue drained, no more reads
    }

    func testDownloadSavesFileAndMarksSynced() {
        let r = LibRig()
        r.lib.requestList()
        r.listEntry("amsg_42_mono.opus", size: 8)
        r.sched.advance(by: 500)

        r.lib.download("amsg_42_mono.opus")
        XCTAssertEqual(r.net.reads.last, "amsg_42_mono.opus")
        XCTAssertEqual(r.out.toasts.last, "downloading amsg_42_mono.opus")
        r.lib.onFileData([1, 2, 3])
        r.lib.onFileData([4, 5])
        let listsBefore = r.net.lists
        r.lib.onCtrl(op: 0x12, [0x02])

        XCTAssertEqual(r.files.data["amsg_42_mono.opus"], [1, 2, 3, 4, 5])
        XCTAssertEqual(r.out.toasts.last, "saved: amsg_42_mono.opus")
        let rec = r.out.libraries.last!.first!
        XCTAssertTrue(rec.onRing)
        XCTAssertTrue(rec.savedLocal)
        XCTAssertEqual(rec.sizeOpus, 5)
        XCTAssertEqual(r.net.lists, listsBefore + 1)   // list is requested again after a download
    }

    func testChunksOutsideADownloadAreIgnored() {
        let r = LibRig()
        r.lib.onFileData([9, 9, 9])
        r.lib.download("amsg_1_mono.opus")
        r.lib.onFileData([1])
        r.lib.onCtrl(op: 0x12, [0x02])
        XCTAssertEqual(r.files.data["amsg_1_mono.opus"], [1])
    }

    func testIndexSurvivesRestartAndOffline() {
        let r = LibRig()
        r.lib.requestList()
        r.listEntry("amsg_1700000050_mono.opus", size: 500)
        r.listEntry("amsg_1700000100_mono.opus", size: 1024)
        r.sched.advance(by: 500)

        // "app restart": fresh library over the same persisted store, ring not connected
        let r2 = LibRig(store: r.store)
        r2.net.isConnected = false
        r2.lib.refreshLibrary()
        let recs = r2.out.libraries.last!
        XCTAssertEqual(recs.map { $0.id }, ["1700000100", "1700000050"])
        XCTAssertTrue(recs.allSatisfy { $0.onRing })
        XCTAssertEqual(recs[0].sizeOpus, 1024)
    }

    func testRecordingGoneFromRingIsDroppedUnlessSaved() {
        let r = LibRig()
        r.files.data["amsg_2_mono.opus"] = [0, 1, 7]
        r.lib.requestList()
        r.listEntry("amsg_1_mono.opus", size: 10)
        r.listEntry("amsg_2_mono.opus", size: 3)
        r.sched.advance(by: 500)
        XCTAssertEqual(Set(r.out.libraries.last!.map { $0.id }), ["1", "2"])

        r.lib.requestList()                           // ring now only lists #2
        r.listEntry("amsg_2_mono.opus", size: 3)
        r.sched.advance(by: 500)
        let recs = r.out.libraries.last!
        XCTAssertEqual(recs.map { $0.id }, ["2"])
        XCTAssertTrue(recs[0].savedLocal)
    }

    func testLocalDurationFallbackFromOpusPackets() {
        let r = LibRig()
        r.files.data["amsg_3_mono.opus"] = [0, 2, 1, 1, 1, 2, 2, 2]   // two packets → 120 ms
        r.net.isConnected = false
        r.lib.refreshLibrary()
        let rec = r.out.libraries.last!.first!
        XCTAssertEqual(rec.durationMs, 120)
        XCTAssertTrue(rec.savedLocal)
        XCTAssertFalse(rec.onRing)
    }

    func testDeleteLocalRemovesOpusAndCache() {
        let r = LibRig()
        r.files.data["amsg_9_mono.opus"] = [0, 1, 1]
        r.files.data["amsg_9_mono.wav"] = [1, 2, 3]
        r.net.isConnected = false
        r.lib.deleteLocal("9")
        XCTAssertTrue(r.files.data.isEmpty)
        XCTAssertEqual(r.out.toasts.last, "deleted from phone")
        XCTAssertTrue(r.out.libraries.last!.isEmpty)
    }

    func testDeleteOnRingSendsEveryFileOfTheRecordingAndRelists() {
        let r = LibRig()
        r.lib.requestList()
        r.listEntry("amsg_7_mono.json", size: 3)
        r.listEntry("amsg_7_mono.opus", size: 3)
        r.listEntry("amsg_8_mono.opus", size: 3)
        r.sched.advance(by: 500)
        // the list settling kicked off the automatic duration fetch of amsg_7's .json; let it finish
        XCTAssertEqual(r.net.reads, ["amsg_7_mono.json"])
        r.lib.onCtrl(op: 0x12, [0x02])               // (empty body: duration unparsable)
        XCTAssertFalse(r.lib.downloading)
        r.sched.advance(by: 10)
        XCTAssertEqual(r.net.reads, ["amsg_7_mono.json"])   // an unparsable .json is not fetched again
        let listsBefore = r.net.lists
        r.lib.deleteRing("7")
        XCTAssertEqual(r.net.deletes, ["amsg_7_mono.json", "amsg_7_mono.opus"])
        r.sched.advance(by: 900)
        XCTAssertEqual(r.net.lists, listsBefore + 1)

        r.lib.deleteRing("999")
        XCTAssertEqual(r.out.toasts.last, "not in the ring list")
    }

    func testManualRefreshGuards() {
        let r = LibRig()
        r.net.isConnected = false
        r.lib.manualRefresh()
        XCTAssertEqual(r.out.toasts.last, "connect first")
        r.net.isConnected = true
        r.lib.download("amsg_1_mono.opus")
        r.lib.manualRefresh()
        XCTAssertEqual(r.out.toasts.last, "download in progress")
    }

    func testDisconnectMidDownloadDoesNotWedgeTheLibrary() {
        let r = LibRig()
        r.lib.download("amsg_1_mono.opus")
        XCTAssertTrue(r.lib.downloading)
        r.lib.onDisconnected()
        XCTAssertFalse(r.lib.downloading)
        r.lib.manualRefresh()
        XCTAssertEqual(r.out.toasts.last, "refreshing…")
    }

    func testNewRecordingButtonEvent() {
        let r = LibRig()
        let d: [UInt8] = [0, 0] + Array("amsg_77_mono.opus".utf8)
        let listsBefore = r.net.lists
        r.lib.onCtrl(op: 0x13, d)
        XCTAssertEqual(r.out.events.last, "BUTTON → new recording: amsg_77_mono.opus")
        XCTAssertEqual(r.net.lists, listsBefore + 1)
        XCTAssertEqual(r.out.libraries.last!.first!.id, "77")
    }
}
