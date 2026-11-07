import XCTest
@testable import VoxLibreCore

final class GestureTests: XCTestCase {
    private func make() -> (RingGestures, ManualScheduler, FakeSink) {
        let sched = ManualScheduler()
        let sink = FakeSink()
        let g = RingGestures(scheduler: sched)
        g.sink = sink
        // Callers keep `sink` alive through the returned tuple (the gestures only hold it weakly).
        return (g, sched, sink)
    }

    func testSingleGesture() {
        let (g, sched, sink) = make()
        g.feed26(1)                 // t=0
        sched.advance(by: 100)
        g.feed26(2)                 // t=100
        XCTAssertEqual(sink.gestureTexts, ["button: PRESSED…"])
        sched.advance(by: 300)      // t=400: release (lastTick 100 + 300)
        XCTAssertEqual(sink.gestureTexts.count, 1)
        sched.advance(by: 399)      // t=799
        XCTAssertEqual(sink.gestureTexts.count, 1)
        sched.advance(by: 1)        // t=800: single-click window over
        XCTAssertEqual(sink.gestureTexts.last, "Last gesture: SINGLE")
    }

    func testDoubleGesture() {
        let (g, sched, sink) = make()
        g.feed26(1)                 // t=0, release due at 300
        sched.advance(by: 350)      // release → pendingSingle (single due at 700)
        g.feed26(2)                 // t=350, second press, release due at 650
        sched.advance(by: 300)      // t=650: release → DOUBLE
        XCTAssertEqual(sink.gestureTexts.last, "Last gesture: DOUBLE")
        sched.advance(by: 2000)     // the cancelled single must never fire
        XCTAssertFalse(sink.gestureTexts.contains("Last gesture: SINGLE"))
        XCTAssertEqual(sink.gestureTexts.filter { $0 == "button: PRESSED…" }.count, 2)
    }

    func testHoldGesture() {
        let (g, sched, sink) = make()
        for i in 0..<8 {            // ticks at t = 0, 100, … 700
            g.feed26(i)
            if i < 7 { sched.advance(by: 100) }
        }
        sched.advance(by: 300)      // release at 700 + 300
        XCTAssertEqual(sink.gestureTexts.last, "Last gesture: HOLD  (700ms, 8 ticks)")
        sched.advance(by: 2000)
        XCTAssertFalse(sink.gestureTexts.contains("Last gesture: SINGLE"))
    }

    func testTickLogShowsCounterDeltaAndRate() {
        let (g, sched, sink) = make()
        g.feed26(250)
        sched.advance(by: 100)
        g.feed26(4)                 // wraps: 250 → 4 is Δ=10
        XCTAssertTrue(sink.logs.contains("RX [ctrl] op=0x26 val=4 (0x4) Δ=10 dt=100ms ~10.0Hz"))
    }

    func testResetCancelsPendingGesture() {
        let (g, sched, sink) = make()
        g.feed26(1)
        g.reset()
        sched.advance(by: 5000)
        XCTAssertEqual(sink.gestureTexts, ["button: PRESSED…"])
    }

    func testMediaToggleOffByDefaultThenDebounced() {
        let (g, sched, sink) = make()
        g.singleClick()
        XCTAssertEqual(sink.mediaToggles, 0)
        XCTAssertTrue(sink.logs.contains("single click (play/pause feature off)"))

        g.setMediaToggle(true)
        g.singleClick()
        XCTAssertEqual(sink.mediaToggles, 1)
        sched.advance(by: 399)
        g.singleClick()             // within 400 ms: debounced
        XCTAssertEqual(sink.mediaToggles, 1)
        XCTAssertTrue(sink.logs.contains("click ignored (debounce)"))
        sched.advance(by: 1)
        g.singleClick()
        XCTAssertEqual(sink.mediaToggles, 2)
    }
}
